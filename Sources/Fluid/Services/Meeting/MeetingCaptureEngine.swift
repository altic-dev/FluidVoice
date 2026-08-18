import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

nonisolated protocol MeetingCaptureControlling: Sendable {
    func start(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration,
        sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    ) async throws -> MeetingCaptureStartResult

    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult
    func shutdownForTermination() async
}

actor MeetingCaptureEngine: MeetingCaptureControlling {
    private struct ActiveCapture: @unchecked Sendable {
        var sessionID: MeetingSessionID
        var runtime: any MeetingCaptureRuntime
        var writers: [MeetingAudioChunkWriter]
    }

    private var activeCapture: ActiveCapture?
    private var startingSessionID: MeetingSessionID?
    private var stopTask: Task<MeetingCaptureStopResult, Error>?
    private var displaySleepAssertionID: IOPMAssertionID?
    private var terminating = false

    func start(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration,
        sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)? = nil
    ) async throws -> MeetingCaptureStartResult {
        try configuration.validate()
        guard self.activeCapture == nil, self.startingSessionID == nil, self.stopTask == nil else {
            throw MeetingCaptureError.captureAlreadyActive
        }
        self.startingSessionID = session.id
        defer { self.startingSessionID = nil }
        try Self.preflightStorage(at: sessionDirectory)
        try await Self.ensureMicrophonePermission()

        let tracks = Self.makeTracks(session: session, configuration: configuration)
        let writers = try tracks.map { track in
            try MeetingAudioChunkWriter(
                track: track,
                sessionDirectory: sessionDirectory,
                chunkDuration: configuration.chunkDuration,
                eventHandler: eventHandler
            )
        }
        let writersByKind = Dictionary(uniqueKeysWithValues: zip(tracks.map(\.kind), writers))

        let runtime: any MeetingCaptureRuntime
        switch configuration.mode {
        case .onlineCall:
            guard let application = configuration.application,
                  let applicationWriter = writersByKind[.applicationAudio],
                  let microphoneWriter = writersByKind[.microphone]
            else { throw MeetingCaptureError.applicationNotSelected }

            let decision = MeetingCapturePathDecider.decide(
                mode: configuration.mode,
                microphone: configuration.microphone,
                outputRoute: Self.currentOutputRouteSnapshot()
            )
            switch decision {
            case let .screenCaptureKit(reason):
                DebugLogger.shared.log(
                    "Meeting voice-processing capture declined: \(reason)",
                    source: "MeetingCaptureEngine"
                )
                eventHandler(.interrupted(kind: .voiceProcessingDeclined, trackID: nil, detail: reason))
                runtime = try await ScreenCaptureMeetingRuntime.make(
                    application: application,
                    microphone: configuration.microphone,
                    includeMicrophone: true,
                    applicationWriter: applicationWriter,
                    microphoneWriter: microphoneWriter,
                    eventHandler: eventHandler,
                    liveAudioHandler: liveAudioHandler
                )
            case .voiceProcessing:
                runtime = try await VoiceProcessingMeetingRuntime.make(
                    application: application,
                    microphone: configuration.microphone,
                    applicationWriter: applicationWriter,
                    microphoneWriter: microphoneWriter,
                    eventHandler: eventHandler,
                    liveAudioHandler: liveAudioHandler
                )
            }
        case .inRoom:
            guard let microphoneWriter = writersByKind[.microphone] else {
                throw MeetingCaptureError.microphoneUnavailable
            }
            runtime = try InRoomMicrophoneCaptureRuntime(
                microphone: configuration.microphone,
                writer: microphoneWriter,
                eventHandler: eventHandler,
                liveAudioHandler: liveAudioHandler
            )
        }

        do {
            try await runtime.start()
        } catch {
            try? await runtime.stop()
            _ = await Self.stopWriters(writers)
            throw error
        }

        // The actor is reentrant across the awaits above; termination may have arrived meanwhile.
        if self.terminating {
            try? await runtime.stop()
            _ = await Self.stopWriters(writers)
            throw MeetingCaptureError.captureStartFailed("The app is shutting down.")
        }
        self.displaySleepAssertionID = Self.acquireDisplaySleepAssertion()
        self.activeCapture = ActiveCapture(
            sessionID: session.id,
            runtime: runtime,
            writers: writers
        )
        // Re-snapshot: a VPIO commit during start() promotes provenance on the writer's own track.
        let settledTracks = await withTaskGroup(of: MeetingAudioTrack.self, returning: [MeetingAudioTrack].self) { group in
            for writer in writers {
                group.addTask { await writer.snapshot() }
            }
            var result: [MeetingAudioTrack] = []
            for await track in group { result.append(track) }
            return result.sorted { $0.kind.rawValue < $1.kind.rawValue }
        }
        return MeetingCaptureStartResult(
            tracks: settledTracks,
            firstPresentationTime: nil,
            captureScope: runtime.captureScope
        )
    }

    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult {
        if let stopTask = self.stopTask {
            return try await stopTask.value
        }
        guard let activeCapture = self.activeCapture else {
            throw MeetingCaptureError.noActiveCapture
        }
        guard activeCapture.sessionID == sessionID else {
            throw MeetingCaptureError.wrongActiveSession
        }

        let task = Task<MeetingCaptureStopResult, Error> {
            let runtimeFailure: Error?
            do {
                try await activeCapture.runtime.stop()
                runtimeFailure = nil
            } catch {
                runtimeFailure = error
            }
            let tracks = await Self.stopWriters(activeCapture.writers)
            let result = MeetingCaptureStopResult(tracks: tracks, stoppedAt: Date())
            if let runtimeFailure {
                throw MeetingCaptureError.captureStopFailed(
                    runtimeFailure.localizedDescription,
                    partialResult: result
                )
            }
            return result
        }
        self.stopTask = task
        do {
            let result = try await task.value
            self.activeCapture = nil
            self.stopTask = nil
            self.releaseDisplaySleepAssertion()
            return result
        } catch {
            self.activeCapture = nil
            self.stopTask = nil
            self.releaseDisplaySleepAssertion()
            throw error
        }
    }

    func shutdownForTermination() async {
        self.terminating = true
        guard let sessionID = self.activeCapture?.sessionID else {
            self.releaseDisplaySleepAssertion()
            return
        }
        _ = try? await self.stop(sessionID: sessionID)
    }

    private func releaseDisplaySleepAssertion() {
        guard let assertionID = self.displaySleepAssertionID else { return }
        self.displaySleepAssertionID = nil
        IOPMAssertionRelease(assertionID)
    }

    private nonisolated static func acquireDisplaySleepAssertion() -> IOPMAssertionID? {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "FluidVoice meeting recording" as CFString,
            &assertionID
        )
        return result == kIOReturnSuccess ? assertionID : nil
    }

    private nonisolated static func stopWriters(_ writers: [MeetingAudioChunkWriter]) async -> [MeetingAudioTrack] {
        await withTaskGroup(of: MeetingAudioTrack.self, returning: [MeetingAudioTrack].self) { group in
            for writer in writers {
                group.addTask { await writer.stop() }
            }
            var tracks: [MeetingAudioTrack] = []
            for await track in group {
                tracks.append(track)
            }
            return tracks.sorted { $0.kind.rawValue < $1.kind.rawValue }
        }
    }

    private nonisolated static func makeTracks(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration
    ) -> [MeetingAudioTrack] {
        var tracks: [MeetingAudioTrack] = []
        if let application = configuration.application {
            tracks.append(MeetingAudioTrack(
                id: UUID(),
                kind: .applicationAudio,
                sourceIdentifier: application.bundleIdentifier,
                sourceDisplayName: application.displayName,
                format: nil,
                timebase: session.timebase,
                health: .waiting,
                chunks: [],
                captureMethod: .screenCaptureKit
            ))
        }
        tracks.append(MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: configuration.microphone.captureDeviceID,
            sourceDisplayName: configuration.microphone.displayName,
            format: nil,
            timebase: session.timebase,
            health: .waiting,
            chunks: [],
            captureMethod: configuration.mode == .onlineCall ? .screenCaptureKit : .avCaptureSession
        ))
        return tracks
    }

    private nonisolated static func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            guard granted else { throw MeetingCaptureError.microphonePermissionDenied }
        case .denied, .restricted:
            throw MeetingCaptureError.microphonePermissionDenied
        @unknown default:
            throw MeetingCaptureError.microphonePermissionDenied
        }
    }

    static func currentOutputRouteSnapshot() -> MeetingOutputRouteSnapshot {
        guard let device = AudioDevice.getDefaultOutputDevice() else {
            return MeetingOutputRouteSnapshot(deviceExists: false, isBluetooth: false, isBuiltIn: false, isHeadphonesDataSource: false)
        }
        return MeetingOutputRouteSnapshot(
            deviceExists: true,
            isBluetooth: device.isBluetooth,
            isBuiltIn: device.isBuiltIn,
            isHeadphonesDataSource: AudioDevice.outputDataSourceIsHeadphones(device.id)
        )
    }

    private nonisolated static func preflightStorage(at directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity < 512 * 1024 * 1024 {
            throw MeetingCaptureError.insufficientDiskSpace
        }
    }
}

nonisolated protocol MeetingCaptureRuntime: AnyObject, Sendable {
    /// The ScreenCaptureKit scope actually in effect. `nil` for runtimes with no SCK stream.
    var captureScope: MeetingCaptureScope? { get }
    func start() async throws
    func stop() async throws
}

/// A candidate window for `.window`-scoped capture, in a shape independent of ScreenCaptureKit
/// so the selection logic can be unit tested with plain values.
nonisolated struct MeetingWindowCandidate: Sendable, Equatable {
    var windowID: UInt32
    var title: String?
    var frame: CGRect
    var layer: Int
    /// Index within `SCShareableContent.windows`, which is ordered front-to-back.
    var zOrderIndex: Int
}

/// Pure selection logic for Phase 1c window-scoped capture: excludes panels/menubar items
/// (non-zero layer) and slivers (sub-200x100), then ranks titled-frontmost-largest-stablest.
nonisolated enum MeetingWindowSelector {
    static let minimumWidth: CGFloat = 200
    static let minimumHeight: CGFloat = 100

    static func selectWindow(from candidates: [MeetingWindowCandidate]) -> MeetingWindowCandidate? {
        candidates
            .filter { $0.layer == 0 && $0.frame.width >= self.minimumWidth && $0.frame.height >= self.minimumHeight }
            .sorted(by: self.isRanked)
            .first
    }

    /// True when `lhs` should be preferred over `rhs`: non-empty title, then frontmost
    /// (lower z-order), then larger area, then windowID ascending as the stable tiebreak.
    private static func isRanked(_ lhs: MeetingWindowCandidate, _ rhs: MeetingWindowCandidate) -> Bool {
        let lhsHasTitle = lhs.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let rhsHasTitle = rhs.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if lhsHasTitle != rhsHasTitle { return lhsHasTitle }
        if lhs.zOrderIndex != rhs.zOrderIndex { return lhs.zOrderIndex < rhs.zOrderIndex }
        let lhsArea = lhs.frame.width * lhs.frame.height
        let rhsArea = rhs.frame.width * rhs.frame.height
        if lhsArea != rhsArea { return lhsArea > rhsArea }
        return lhs.windowID < rhs.windowID
    }
}

private final nonisolated class ScreenCaptureMeetingRuntime: NSObject, MeetingCaptureRuntime, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    private struct BuiltStream {
        let stream: SCStream
        let delegateProxy: ScreenCaptureRuntimeDelegateProxy
        let scope: MeetingCaptureScope
    }

    /// Delays before each of the (up to 3) rebuild attempts following an unexpected stream stop.
    private static let rebuildDelays: [TimeInterval] = [0.5, 1.0, 2.0]

    private let application: MeetingApplicationIdentity
    private let microphone: MeetingMicrophoneIdentity
    /// Immutable for the runtime's lifetime: a rebuild never drops/adds the mic.
    private let includeMicrophone: Bool
    private let applicationWriter: MeetingAudioChunkWriter
    private let microphoneWriter: MeetingAudioChunkWriter
    private let eventHandler: @Sendable (MeetingCaptureEvent) -> Void
    private let liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    private let stateLock = NSLock()
    private var stream: SCStream
    private var scope: MeetingCaptureScope
    private var delegateProxy: ScreenCaptureRuntimeDelegateProxy?
    private var stopping = false
    private var rebuilding = false
    private var pendingStream: SCStream?
    private var pendingStreamFailed = false

    var captureScope: MeetingCaptureScope? {
        self.stateLock.withLock { self.scope }
    }

    private init(
        stream: SCStream,
        scope: MeetingCaptureScope,
        application: MeetingApplicationIdentity,
        microphone: MeetingMicrophoneIdentity,
        includeMicrophone: Bool,
        applicationWriter: MeetingAudioChunkWriter,
        microphoneWriter: MeetingAudioChunkWriter,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    ) {
        self.stream = stream
        self.scope = scope
        self.application = application
        self.microphone = microphone
        self.includeMicrophone = includeMicrophone
        self.applicationWriter = applicationWriter
        self.microphoneWriter = microphoneWriter
        self.eventHandler = eventHandler
        self.liveAudioHandler = liveAudioHandler
        super.init()
    }

    static func make(
        application: MeetingApplicationIdentity,
        microphone: MeetingMicrophoneIdentity,
        includeMicrophone: Bool = true,
        applicationWriter: MeetingAudioChunkWriter,
        microphoneWriter: MeetingAudioChunkWriter,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    ) async throws -> ScreenCaptureMeetingRuntime {
        let built = try await Self.buildStream(application: application, microphone: microphone, includeMicrophone: includeMicrophone)
        let runtime = ScreenCaptureMeetingRuntime(
            stream: built.stream,
            scope: built.scope,
            application: application,
            microphone: microphone,
            includeMicrophone: includeMicrophone,
            applicationWriter: applicationWriter,
            microphoneWriter: microphoneWriter,
            eventHandler: eventHandler,
            liveAudioHandler: liveAudioHandler
        )
        built.delegateProxy.owner = runtime
        runtime.delegateProxy = built.delegateProxy
        try runtime.attachOutputs(to: built.stream)
        return runtime
    }

    /// Resolves the shareable content, filter, configuration and stream. Re-invoked both for the
    /// initial `make` and for every rebuild attempt after an unexpected stream stop.
    private static func buildStream(
        application: MeetingApplicationIdentity,
        microphone: MeetingMicrophoneIdentity,
        includeMicrophone: Bool
    ) async throws -> BuiltStream {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw MeetingCaptureError.screenCapturePermissionDenied(error.localizedDescription)
        }
        let byProcessID = application.processID.flatMap { processID in
            content.applications.first(where: { $0.processID == processID })
        }
        // The saved PID goes stale when the app relaunches; the bundle match keeps rebuilds working.
        guard let runningApplication = byProcessID ?? content.applications.first(where: {
            $0.bundleIdentifier == application.bundleIdentifier
        }) else {
            throw MeetingCaptureError.applicationUnavailable(application.displayName)
        }

        let filter: SCContentFilter
        let scope: MeetingCaptureScope
        if let window = Self.selectWindow(for: runningApplication, in: content) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            scope = .window
        } else {
            let display = application.displayID.flatMap { displayID in
                content.displays.first(where: { $0.displayID == displayID })
            } ?? content.displays.first
            guard let display else { throw MeetingCaptureError.noCaptureDisplay }
            filter = SCContentFilter(display: display, including: [runningApplication], exceptingWindows: [])
            scope = .display
        }

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        MeetingScreenCaptureAudioSettings.apply(to: configuration, microphone: microphone, includeMicrophone: includeMicrophone)

        let delegateProxy = ScreenCaptureRuntimeDelegateProxy()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegateProxy)
        return BuiltStream(stream: stream, delegateProxy: delegateProxy, scope: scope)
    }

    /// Maps the app's own windows to selection candidates and picks one via `MeetingWindowSelector`.
    /// Deliberately does not require `isOnScreen` (unreliable for other-Space/hidden windows).
    /// Window titles are PII and must never be logged or persisted.
    private static func selectWindow(
        for runningApplication: SCRunningApplication,
        in content: SCShareableContent
    ) -> SCWindow? {
        let ownedWindows = content.windows.enumerated().filter { _, window in
            window.owningApplication?.processID == runningApplication.processID
        }
        let candidates = ownedWindows.map { index, window in
            MeetingWindowCandidate(
                windowID: window.windowID,
                title: window.title,
                frame: window.frame,
                layer: window.windowLayer,
                zOrderIndex: index
            )
        }
        guard let winner = MeetingWindowSelector.selectWindow(from: candidates) else { return nil }
        return ownedWindows.first(where: { _, window in window.windowID == winner.windowID })?.element
    }

    private func attachOutputs(to stream: SCStream) throws {
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(
                label: "com.fluidvoice.meeting.screencapture.application",
                qos: .userInteractive
            )
        )
        guard self.includeMicrophone else { return }
        try stream.addStreamOutput(
            self,
            type: .microphone,
            sampleHandlerQueue: DispatchQueue(
                label: "com.fluidvoice.meeting.screencapture.microphone",
                qos: .userInteractive
            )
        )
    }

    func start() async throws {
        let currentStream = self.stateLock.withLock { self.stream }
        do {
            try await currentStream.startCapture()
        } catch {
            throw MeetingCaptureError.captureStartFailed(error.localizedDescription)
        }
    }

    func stop() async throws {
        self.markStopping()
        let (currentStream, streamAlreadyDead) = self.stateLock.withLock { (self.stream, self.rebuilding) }
        // Mid-rebuild the current stream already stopped on its own; stopCapture would only time out.
        guard !streamAlreadyDead else { return }
        let result = await withCheckedContinuation { continuation in
            let completion = MeetingOneShotCompletion(continuation)
            currentStream.stopCapture { error in
                if let error {
                    completion.resume(.failure(error.localizedDescription))
                } else {
                    completion.resume(.success)
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
                completion.resume(.failure("Timed out while stopping system-audio capture."))
            }
        }
        if case let .failure(detail) = result {
            throw MeetingCaptureRuntimeError.stopFailed(detail)
        }
    }

    private func markStopping() {
        self.stateLock.withLock { self.stopping = true }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        let shouldAccept = self.stateLock.withLock { !self.stopping && stream === self.stream }
        guard shouldAccept else { return }
        switch outputType {
        case .audio:
            self.applicationWriter.enqueue(sampleBuffer)
            self.liveAudioHandler?(.applicationAudio, sampleBuffer)
        case .microphone:
            self.microphoneWriter.enqueue(sampleBuffer)
            self.liveAudioHandler?(.microphone, sampleBuffer)
        case .screen:
            break
        @unknown default:
            break
        }
    }

    func handleStreamStop(_ stoppedStream: SCStream, error: Error) {
        let shouldRebuild = self.stateLock.withLock { () -> Bool in
            if stoppedStream === self.pendingStream {
                self.pendingStreamFailed = true
                return false
            }
            guard !self.stopping, !self.rebuilding, stoppedStream === self.stream else { return false }
            self.rebuilding = true
            return true
        }
        guard shouldRebuild else { return }
        self.eventHandler(.interrupted(kind: .sourceLost, trackID: nil, detail: error.localizedDescription))
        self.runRebuildLoop(triggeringError: error)
    }

    /// Attempts up to `rebuildDelays.count` rebuilds of the stream, checking `stopping` before and
    /// after each delay so a concurrent user-initiated `stop()` aborts the loop promptly. On success
    /// the stream reference is swapped under the lock and writers keep running untouched (they rotate
    /// chunks on the PTS gap on their own). On exhaustion this reports the terminal failure exactly as
    /// the non-recoverable path did before this change.
    private func runRebuildLoop(triggeringError: Error) {
        Task { [weak self] in
            guard let self else { return }
            var lastError = triggeringError
            for delay in Self.rebuildDelays {
                if self.stateLock.withLock({ self.stopping }) { self.finishRebuilding(); return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if self.stateLock.withLock({ self.stopping }) { self.finishRebuilding(); return }

                do {
                    let built = try await Self.buildStream(
                        application: self.application, microphone: self.microphone, includeMicrophone: self.includeMicrophone
                    )
                    if self.stateLock.withLock({ self.stopping }) { self.finishRebuilding(); return }
                    built.delegateProxy.owner = self
                    try self.attachOutputs(to: built.stream)
                    self.stateLock.withLock {
                        self.pendingStream = built.stream
                        self.pendingStreamFailed = false
                    }
                    try await built.stream.startCapture()

                    let swapped = self.stateLock.withLock { () -> Bool in
                        defer { self.pendingStream = nil }
                        guard !self.stopping, !self.pendingStreamFailed else { return false }
                        self.stream = built.stream
                        self.scope = built.scope
                        self.delegateProxy = built.delegateProxy
                        self.rebuilding = false
                        return true
                    }
                    guard swapped else {
                        try? await built.stream.stopCapture()
                        if self.stateLock.withLock({ self.stopping }) {
                            self.finishRebuilding()
                            return
                        }
                        continue
                    }
                    self.eventHandler(.interrupted(kind: .sourceRecovered, trackID: nil, detail: nil))
                    return
                } catch {
                    self.stateLock.withLock { self.pendingStream = nil }
                    lastError = error
                    continue
                }
            }
            self.reportRebuildExhausted(triggeringError: lastError)
        }
    }

    private func finishRebuilding() {
        self.stateLock.withLock { self.rebuilding = false }
    }

    private func reportRebuildExhausted(triggeringError: Error) {
        let shouldReport = self.stateLock.withLock { () -> Bool in
            self.rebuilding = false
            guard !self.stopping else { return false }
            self.stopping = true
            return true
        }
        guard shouldReport else { return }
        self.eventHandler(.interrupted(
            kind: .captureStoppedUnexpectedly,
            trackID: nil,
            detail: triggeringError.localizedDescription
        ))
    }
}

private final nonisolated class ScreenCaptureRuntimeDelegateProxy: NSObject, SCStreamDelegate, @unchecked Sendable {
    weak var owner: ScreenCaptureMeetingRuntime?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.owner?.handleStreamStop(stream, error: error)
    }
}

private final nonisolated class InRoomMicrophoneCaptureRuntime: NSObject, MeetingCaptureRuntime,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
    var captureScope: MeetingCaptureScope? { nil }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let writer: MeetingAudioChunkWriter
    private let controlQueue = DispatchQueue(label: "com.fluidvoice.meeting.inroom.control")
    private let stateLock = NSLock()
    private let eventHandler: @Sendable (MeetingCaptureEvent) -> Void
    private let liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    private var stopping = false
    private var emittedUnexpectedStop = false
    private var notificationObservers: [NSObjectProtocol] = []

    init(
        microphone: MeetingMicrophoneIdentity,
        writer: MeetingAudioChunkWriter,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    ) throws {
        self.writer = writer
        self.eventHandler = eventHandler
        self.liveAudioHandler = liveAudioHandler
        super.init()
        guard let device = AVCaptureDevice(uniqueID: microphone.captureDeviceID) else {
            throw MeetingCaptureError.microphoneUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        self.session.beginConfiguration()
        defer { self.session.commitConfiguration() }
        guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
            throw MeetingCaptureError.microphoneUnavailable
        }
        self.session.addInput(input)
        self.session.addOutput(self.output)
        self.output.setSampleBufferDelegate(
            self,
            queue: DispatchQueue(label: "com.fluidvoice.meeting.inroom.samples", qos: .userInteractive)
        )
        self.observeSessionLifecycle()
    }

    deinit {
        for observer in self.notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() async throws {
        let started = await withCheckedContinuation { continuation in
            self.controlQueue.async { [session] in
                session.startRunning()
                continuation.resume(returning: session.isRunning)
            }
        }
        guard started else { throw MeetingCaptureError.captureStartFailed("The microphone did not start.") }
    }

    func stop() async throws {
        self.stateLock.withLock { self.stopping = true }
        let result = await withCheckedContinuation { continuation in
            let completion = MeetingOneShotCompletion(continuation)
            self.controlQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
                completion.resume(.success)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
                completion.resume(.failure("Timed out while stopping microphone capture."))
            }
        }
        if case let .failure(detail) = result {
            throw MeetingCaptureRuntimeError.stopFailed(detail)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        self.stateLock.lock()
        let shouldAccept = !self.stopping
        self.stateLock.unlock()
        guard shouldAccept else { return }
        self.writer.enqueue(sampleBuffer)
        self.liveAudioHandler?(.microphone, sampleBuffer)
    }

    private func observeSessionLifecycle() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AVCaptureSession.runtimeErrorNotification,
            AVCaptureSession.wasInterruptedNotification,
            AVCaptureSession.didStopRunningNotification,
        ]
        self.notificationObservers = names.map { name in
            center.addObserver(forName: name, object: self.session, queue: nil) { [weak self] notification in
                self?.handleUnexpectedSessionEvent(notification)
            }
        }
    }

    private func handleUnexpectedSessionEvent(_ notification: Notification) {
        let shouldEmit = self.stateLock.withLock { () -> Bool in
            guard !self.stopping, !self.emittedUnexpectedStop else { return false }
            self.emittedUnexpectedStop = true
            return true
        }
        guard shouldEmit else { return }
        let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
            ?? "Microphone capture stopped unexpectedly."
        self.eventHandler(.interrupted(
            kind: .captureStoppedUnexpectedly,
            trackID: nil,
            detail: detail
        ))
    }
}

/// Single-resume continuation box; resuming twice is a safe no-op.
private final nonisolated class MeetingOneShotValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

/// Reusable AVCaptureSession mic component: `wasInterrupted` restarts only if still not running; runtime errors get ONE bounded restart.
final nonisolated class MeetingAVCaptureMicrophoneComponent: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private static let interruptionEndedWaitSeconds: Double = 3
    private static let restartSupervisionSeconds: Double = 3
    private static let stopTimeoutSeconds: Double = 3

    let deviceUID: String?
    let deviceName: String

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let controlQueue = DispatchQueue(label: "com.fluidvoice.meeting.avcapture.control")
    private let stateLock = NSLock()
    private let onSample: @Sendable (CMSampleBuffer) -> Void
    private let onTerminalStop: @Sendable (String) -> Void
    private var stopping = false
    private var emittedTerminalStop = false
    private var runtimeErrorRestarted = false
    private var didStopRunningRestarted = false
    private var interruptionEndWaiters: [MeetingOneShotValue<Void>] = []

    init(
        microphone: MeetingMicrophoneIdentity,
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
        onTerminalStop: @escaping @Sendable (String) -> Void
    ) throws {
        self.deviceUID = microphone.coreAudioUID
        self.deviceName = microphone.displayName
        self.onSample = onSample
        self.onTerminalStop = onTerminalStop
        super.init()
        guard let device = AVCaptureDevice(uniqueID: microphone.captureDeviceID) else {
            throw MeetingCaptureError.microphoneUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        self.session.beginConfiguration()
        defer { self.session.commitConfiguration() }
        guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
            throw MeetingCaptureError.microphoneUnavailable
        }
        self.session.addInput(input)
        self.session.addOutput(self.output)
        self.output.setSampleBufferDelegate(
            self,
            queue: DispatchQueue(label: "com.fluidvoice.meeting.avcapture.samples", qos: .userInteractive)
        )
        self.observeSessionLifecycle()
    }

    deinit {
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    private var observers: [NSObjectProtocol] = []

    /// Bounded retry at 0.5/1/2s on `startRunning` failure plus a supervised overall timeout.
    func start() async throws {
        for (attempt, delay) in ([0] + Self.startRetryDelays).enumerated() {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if self.stateLock.withLock({ self.stopping }) { throw CancellationError() }
            let started = await MeetingSupervisedTimeout.run(seconds: Self.startSupervisionSeconds) { [session] in
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    let box = MeetingOneShotValue<Bool>(continuation)
                    self.controlQueue.async {
                        session.startRunning()
                        box.resume(session.isRunning)
                    }
                }
            }
            if started == true { return }
        }
        throw MeetingCaptureError.captureStartFailed("The microphone did not start.")
    }

    private static let startRetryDelays: [Double] = [0.5, 1.0, 2.0]
    private static let startSupervisionSeconds: Double = 4

    func stop() async throws {
        self.stateLock.lock()
        self.stopping = true
        let waiters = self.interruptionEndWaiters
        self.interruptionEndWaiters = []
        self.stateLock.unlock()
        waiters.forEach { $0.resume(()) }

        let result = await withCheckedContinuation { continuation in
            let completion = MeetingOneShotCompletion(continuation)
            self.controlQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
                completion.resume(.success)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.stopTimeoutSeconds) {
                completion.resume(.failure("Timed out while stopping microphone capture."))
            }
        }
        if case let .failure(detail) = result {
            throw MeetingCaptureRuntimeError.stopFailed(detail)
        }
    }

    /// `onComplete(false)` means the supervision window elapsed before `stop()` finished.
    func stopDetached(supervisedSeconds: Double, onComplete: @escaping @Sendable (Bool) -> Void) {
        Task { [weak self] in
            guard let self else { onComplete(false); return }
            let completed = await MeetingSupervisedTimeout.run(seconds: supervisedSeconds) {
                try? await self.stop()
                return true
            }
            onComplete(completed == true)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        self.stateLock.lock()
        let shouldAccept = !self.stopping
        self.stateLock.unlock()
        guard shouldAccept else { return }
        self.onSample(sampleBuffer)
    }

    private func observeSessionLifecycle() {
        let center = NotificationCenter.default
        self.observers = [
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification, object: self.session, queue: nil
            ) { [weak self] _ in self?.handleInterruptionBegan() },
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification, object: self.session, queue: nil
            ) { [weak self] _ in self?.handleInterruptionEnded() },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: self.session, queue: nil
            ) { [weak self] note in self?.handleRuntimeError(note) },
            center.addObserver(
                forName: AVCaptureSession.didStopRunningNotification, object: self.session, queue: nil
            ) { [weak self] _ in self?.handleDidStopRunning() },
        ]
    }

    private func handleInterruptionBegan() {
        Task { [weak self] in
            guard let self else { return }
            await self.waitForInterruptionEnd(timeoutSeconds: Self.interruptionEndedWaitSeconds)
            guard !(self.stateLock.withLock({ self.stopping })) else { return }
            if !self.session.isRunning {
                await self.attemptSupervisedRestart(
                    reason: "Route settled after an interruption but the microphone did not resume."
                )
            }
        }
    }

    private func waitForInterruptionEnd(timeoutSeconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = MeetingOneShotValue<Void>(continuation)
            self.stateLock.lock()
            self.interruptionEndWaiters.append(box)
            self.stateLock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
                box.resume(())
            }
        }
    }

    private func handleInterruptionEnded() {
        self.stateLock.lock()
        let waiters = self.interruptionEndWaiters
        self.interruptionEndWaiters = []
        self.stateLock.unlock()
        waiters.forEach { $0.resume(()) }
    }

    private func handleRuntimeError(_ notification: Notification) {
        let shouldRestart = self.stateLock.withLock { () -> Bool in
            guard !self.stopping, !self.runtimeErrorRestarted else { return false }
            self.runtimeErrorRestarted = true
            return true
        }
        let detail = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
            ?? "Microphone capture reported a runtime error."
        guard shouldRestart else {
            self.emitTerminalStopIfNeeded(detail: detail)
            return
        }
        Task { [weak self] in await self?.attemptSupervisedRestart(reason: detail) }
    }

    private func handleDidStopRunning() {
        let shouldRestart = self.stateLock.withLock { () -> Bool in
            guard !self.stopping, !self.didStopRunningRestarted else { return false }
            self.didStopRunningRestarted = true
            return true
        }
        guard shouldRestart else {
            self.emitTerminalStopIfNeeded(detail: "Microphone capture stopped unexpectedly.")
            return
        }
        Task { [weak self] in
            await self?.attemptSupervisedRestart(reason: "Microphone capture stopped unexpectedly.")
        }
    }

    private func attemptSupervisedRestart(reason: String) async {
        guard !(self.stateLock.withLock({ self.stopping })) else { return }
        let restarted = await MeetingSupervisedTimeout.run(seconds: Self.restartSupervisionSeconds) { [session] in
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let box = MeetingOneShotValue<Bool>(continuation)
                self.controlQueue.async {
                    guard !session.isRunning else { box.resume(true); return }
                    session.startRunning()
                    box.resume(session.isRunning)
                }
            }
        }
        guard restarted != true, !(self.stateLock.withLock({ self.stopping })) else { return }
        self.emitTerminalStopIfNeeded(detail: reason)
    }

    private func emitTerminalStopIfNeeded(detail: String) {
        let shouldEmit = self.stateLock.withLock { () -> Bool in
            guard !self.stopping, !self.emittedTerminalStop else { return false }
            self.emittedTerminalStop = true
            return true
        }
        guard shouldEmit else { return }
        self.onTerminalStop(detail)
    }
}

/// Bounds wall-clock time even when `operation` ignores cancellation; a late operation finishes detached, result discarded.
nonisolated enum MeetingSupervisedTimeout {
    static func run<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let completion = MeetingOneShotValue<T?>(continuation)
            Task {
                let result = await operation()
                completion.resume(result)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + max(0, seconds)) {
                completion.resume(nil)
            }
        }
    }
}

/// Per-era acceptance fence, wrapping each sample callback in `beginSample()`/`defer { endSample() }`.
final nonisolated class MeetingEraAcceptanceFence: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var inFlight = 0
    private var drainWaiters: [MeetingOneShotValue<Void>] = []

    func beginSample() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.accepting else { return false }
        self.inFlight += 1
        return true
    }

    func endSample() {
        self.lock.lock()
        self.inFlight -= 1
        let shouldNotify = !self.accepting && self.inFlight == 0
        let waiters = shouldNotify ? self.drainWaiters : []
        if shouldNotify { self.drainWaiters = [] }
        self.lock.unlock()
        waiters.forEach { $0.resume(()) }
    }

    func quiesce() async {
        let alreadyDrained: Bool = self.lock.withLock {
            self.accepting = false
            return self.inFlight == 0
        }
        guard !alreadyDrained else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = MeetingOneShotValue<Void>(continuation)
            let pending: Bool = self.lock.withLock {
                guard self.inFlight > 0 else { return false }
                self.drainWaiters.append(box)
                return true
            }
            if !pending { box.resume(()) }
        }
    }
}

private nonisolated enum MeetingOneShotResult: Sendable {
    case success
    case failure(String)
}

private final nonisolated class MeetingOneShotCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MeetingOneShotResult, Never>?

    init(_ continuation: CheckedContinuation<MeetingOneShotResult, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: MeetingOneShotResult) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<MeetingOneShotResult, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}

private nonisolated enum MeetingCaptureRuntimeError: LocalizedError {
    case stopFailed(String)

    var errorDescription: String? {
        switch self {
        case let .stopFailed(detail):
            return detail
        }
    }
}

nonisolated enum MeetingCaptureError: LocalizedError {
    case captureAlreadyActive
    case noActiveCapture
    case wrongActiveSession
    case applicationNotSelected
    case applicationUnavailable(String)
    case noCaptureDisplay
    case microphoneUnavailable
    case microphonePermissionDenied
    case screenCapturePermissionDenied(String)
    case insufficientDiskSpace
    case captureStartFailed(String)
    case captureStopFailed(String, partialResult: MeetingCaptureStopResult)
    case unsupportedAudioFormat
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .captureAlreadyActive:
            return "Another meeting recording is already active."
        case .noActiveCapture:
            return "There is no active meeting recording."
        case .wrongActiveSession:
            return "A different meeting recording is active."
        case .applicationNotSelected:
            return "Choose the application that contains the online meeting."
        case let .applicationUnavailable(name):
            return "\(name) is no longer available to record."
        case .noCaptureDisplay:
            return "No display is available for meeting-audio capture."
        case .microphoneUnavailable:
            return "The selected microphone is unavailable."
        case .microphonePermissionDenied:
            return "Microphone permission is required to record this meeting."
        case let .screenCapturePermissionDenied(detail):
            return "Screen & System Audio permission is required. \(detail)"
        case .insufficientDiskSpace:
            return "At least 512 MB of free space is required to start recording."
        case let .captureStartFailed(detail):
            return "Meeting recording could not start. \(detail)"
        case let .captureStopFailed(detail, _):
            return "Meeting recording could not stop cleanly. \(detail)"
        case .unsupportedAudioFormat:
            return "The selected audio source uses an unsupported format."
        case let .writerFailed(detail):
            return "Meeting audio could not be saved. \(detail)"
        }
    }
}

enum MeetingCaptureSourceCatalog {
    static func availableApplications() async throws -> [MeetingApplicationIdentity] {
        let content = try await SCShareableContent.current
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        return content.applications
            .filter { $0.bundleIdentifier != ownBundleIdentifier }
            .map { application in
                let applicationWindow = content.windows.first {
                    $0.owningApplication?.processID == application.processID
                }
                let displayID = applicationWindow.flatMap { window in
                    content.displays
                        .filter { $0.frame.intersects(window.frame) }
                        .max { lhs, rhs in
                            lhs.frame.intersection(window.frame).area < rhs.frame.intersection(window.frame).area
                        }?.displayID
                }
                return MeetingApplicationIdentity(
                    bundleIdentifier: application.bundleIdentifier,
                    processID: application.processID,
                    displayName: application.applicationName,
                    displayID: displayID
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func availableMicrophones() -> [MeetingMicrophoneIdentity] {
        let coreAudioDevices = AudioDevice.listInputDevices()
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { device in
            let sameName = coreAudioDevices.filter { $0.name == device.localizedName }
            return MeetingMicrophoneIdentity(
                captureDeviceID: device.uniqueID,
                coreAudioUID: sameName.count == 1 ? sameName[0].uid : nil,
                displayName: device.localizedName
            )
        }
    }

    static func defaultMicrophone(preferredCoreAudioUID: String? = nil) throws -> MeetingMicrophoneIdentity {
        let microphones = self.availableMicrophones()
        if let preferredCoreAudioUID,
           let preferred = microphones.first(where: { $0.coreAudioUID == preferredCoreAudioUID })
        {
            return preferred
        }
        guard let defaultDevice = AVCaptureDevice.default(for: .audio),
              let microphone = microphones.first(where: { $0.captureDeviceID == defaultDevice.uniqueID })
        else { throw MeetingCaptureError.microphoneUnavailable }
        return microphone
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !self.isNull, !self.isInfinite else { return 0 }
        return max(0, self.width) * max(0, self.height)
    }
}

nonisolated enum MeetingCapturePathDecision: Sendable, Equatable {
    case voiceProcessing
    case screenCaptureKit(reason: String)
}

/// Output-route facts the decision needs, as a plain value so `decide` is unit-testable headless.
nonisolated struct MeetingOutputRouteSnapshot: Sendable, Equatable {
    var deviceExists: Bool
    var isBluetooth: Bool
    var isBuiltIn: Bool
    var isHeadphonesDataSource: Bool
}

/// Pure decision table. Requires `role == .personal` — the election does too; role-blind VPIO
/// would capture cleanly but never attribute.
nonisolated enum MeetingCapturePathDecider {
    static func decide(
        mode: MeetingCaptureMode,
        microphone: MeetingMicrophoneIdentity,
        outputRoute: MeetingOutputRouteSnapshot
    ) -> MeetingCapturePathDecision {
        guard mode == .onlineCall else {
            return .screenCaptureKit(reason: "Voice-processing capture only applies to online-call recordings.")
        }
        guard microphone.role == .personal else {
            return .screenCaptureKit(reason: "Microphone role is not set to personal.")
        }
        guard let coreAudioUID = microphone.coreAudioUID, !coreAudioUID.isEmpty else {
            return .screenCaptureKit(reason: "The selected microphone has no CoreAudio device UID.")
        }
        if let reason = Self.outputRouteDeclineReason(outputRoute) {
            return .screenCaptureKit(reason: reason)
        }
        return .voiceProcessing
    }

    /// Shared with the mid-session output-route listener so the two never diverge.
    static func outputRouteDeclineReason(_ outputRoute: MeetingOutputRouteSnapshot) -> String? {
        guard outputRoute.deviceExists else { return "No default output device is available." }
        guard !outputRoute.isBluetooth else { return "The output device is Bluetooth." }
        guard outputRoute.isBuiltIn else { return "The output device is not the built-in speakers." }
        guard !outputRoute.isHeadphonesDataSource else { return "The output route is headphones." }
        return nil
    }
}

nonisolated enum MeetingScreenCaptureAudioSettings {
    static func apply(
        to configuration: SCStreamConfiguration,
        microphone: MeetingMicrophoneIdentity,
        includeMicrophone: Bool
    ) {
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = includeMicrophone
        if includeMicrophone {
            configuration.microphoneCaptureDeviceID = microphone.captureDeviceID
        }
    }
}

/// Buffers mic audio pre-commit; ring-cap exhaustion ABORTS rather than evicting-and-committing.
final nonisolated class MeetingVoiceProcessingCommitGate: @unchecked Sendable {
    enum SampleOutcome { case buffered, passthrough, aborted }

    private enum State { case buffering, flushing, committed, aborted }

    static let defaultRingCapBytes = 1_048_576 // ~5s of mono float32 @ 48kHz

    private let lock = NSLock()
    private var state: State = .buffering
    private var ring: [CMSampleBuffer] = []
    private var ringBytes = 0
    private let ringCapBytes: Int

    init(ringCapBytes: Int = MeetingVoiceProcessingCommitGate.defaultRingCapBytes) {
        self.ringCapBytes = ringCapBytes
    }

    func offer(_ sampleBuffer: CMSampleBuffer) -> SampleOutcome {
        self.lock.lock()
        defer { self.lock.unlock() }
        switch self.state {
        case .committed: return .passthrough
        case .aborted: return .aborted
        case .flushing:
            // Uncapped: aborting mid-flush would strand already-promoted provenance.
            self.ring.append(sampleBuffer)
            return .buffered
        case .buffering:
            // GetTotalSampleSize returns 0 without a per-sample size table; use the block buffer.
            let size = CMSampleBufferGetDataBuffer(sampleBuffer).map(CMBlockBufferGetDataLength) ?? 0
            guard self.ringBytes + size <= self.ringCapBytes else {
                self.state = .aborted
                self.ring.removeAll()
                self.ringBytes = 0
                return .aborted
            }
            self.ring.append(sampleBuffer)
            self.ringBytes += size
            return .buffered
        }
    }

    @discardableResult
    func offerTerminalEventPreCommit() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state == .buffering else { return false }
        self.state = .aborted
        self.ring.removeAll()
        self.ringBytes = 0
        return true
    }

    /// Point of no return: after this, terminal events and abort() are no-ops.
    func beginCommitFlush() -> [CMSampleBuffer]? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state == .buffering else { return nil }
        self.state = .flushing
        return self.takeRing()
    }

    /// nil means the ring drained and passthrough is live; else the next batch to flush in order.
    /// Serialized handoff: passthrough never starts while older buffers wait, so PTS order holds.
    func continueCommitFlush() -> [CMSampleBuffer]? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state == .flushing else { return nil }
        if self.ring.isEmpty {
            self.state = .committed
            return nil
        }
        return self.takeRing()
    }

    private func takeRing() -> [CMSampleBuffer] {
        let taken = self.ring
        self.ring.removeAll()
        self.ringBytes = 0
        return taken
    }

    func abort() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state == .buffering || self.state == .aborted else { return }
        self.state = .aborted
        self.ring.removeAll()
        self.ringBytes = 0
    }

    var isCommitted: Bool { self.lock.withLock { self.state == .committed } }
}

/// Emitted-only progress: dropped/failed buffers deliver no audio, so a dropped run trips this too.
nonisolated enum MeetingVoiceProcessingWatchdog {
    static let stalledThresholdSeconds: Double = 10

    static func isStalled(secondsSinceLastEmittedBuffer: Double) -> Bool {
        secondsSinceLastEmittedBuffer >= Self.stalledThresholdSeconds
    }
}

/// Re-evaluates the output-route predicate on default-output-device or data-source change.
/// Registration failure at init means VPIO is not viable — fail closed. Re-registers everything on
/// `kAudioHardwarePropertyServiceRestarted`, since CoreAudio discards all prior listeners on reset.
private final nonisolated class MeetingOutputRouteListener: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var defaultOutputToken: AudioObjectPropertyListenerBlock?
    private var serviceRestartedToken: AudioObjectPropertyListenerBlock?
    private var dataSourceToken: AudioObjectPropertyListenerBlock?
    private var dataSourceDeviceID: AudioObjectID?

    init?(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        guard self.register() else { return nil }
    }

    deinit {
        self.unregister()
    }

    private func reevaluate() {
        self.onChange()
    }

    @discardableResult
    private func register() -> Bool {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var restartedAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultOutToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reattachDataSourceListener()
            self?.reevaluate()
        }
        let restartedToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reregisterAfterServiceRestart()
        }
        guard AudioObjectAddPropertyListenerBlock(sys, &defaultOutAddr, DispatchQueue.main, defaultOutToken) == noErr else {
            return false
        }
        guard AudioObjectAddPropertyListenerBlock(sys, &restartedAddr, DispatchQueue.main, restartedToken) == noErr else {
            _ = AudioObjectRemovePropertyListenerBlock(sys, &defaultOutAddr, DispatchQueue.main, defaultOutToken)
            return false
        }
        self.defaultOutputToken = defaultOutToken
        self.serviceRestartedToken = restartedToken
        guard self.attachDataSourceListener() else {
            self.unregister()
            return false
        }
        return true
    }

    private func attachDataSourceListener() -> Bool {
        guard let device = AudioDevice.getDefaultOutputDevice() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reevaluate() }
        guard AudioObjectAddPropertyListenerBlock(device.id, &address, DispatchQueue.main, token) == noErr else { return false }
        self.dataSourceToken = token
        self.dataSourceDeviceID = device.id
        return true
    }

    private func detachDataSourceListener() {
        guard let deviceID = self.dataSourceDeviceID, let token = self.dataSourceToken else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, token)
        self.dataSourceToken = nil
        self.dataSourceDeviceID = nil
    }

    private func reattachDataSourceListener() {
        self.detachDataSourceListener()
        _ = self.attachDataSourceListener()
    }

    private func reregisterAfterServiceRestart() {
        self.unregister()
        guard self.register() else {
            self.onChange()
            return
        }
        self.reevaluate()
    }

    private func unregister() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var restartedAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let token = self.defaultOutputToken {
            _ = AudioObjectRemovePropertyListenerBlock(sys, &defaultOutAddr, DispatchQueue.main, token)
        }
        if let token = self.serviceRestartedToken {
            _ = AudioObjectRemovePropertyListenerBlock(sys, &restartedAddr, DispatchQueue.main, token)
        }
        self.defaultOutputToken = nil
        self.serviceRestartedToken = nil
        self.detachDataSourceListener()
    }
}

nonisolated enum MeetingVoiceProcessingDriftSnapshot {
    static func elapsedValidHostSeconds(_ stats: MeetingMicrophoneCaptureStats.Snapshot) -> Double {
        guard let first = stats.firstValidHostSeconds, let last = stats.lastValidHostSeconds, last > first else { return 0 }
        return last - first
    }

    /// Any re-anchor/step/config-change/dropped-run invalidates the single-epoch linear model.
    static func isEligible(_ stats: MeetingMicrophoneCaptureStats.Snapshot) -> Bool {
        stats.resyncCount == 0
            && stats.resyncClampCount == 0
            && stats.divergenceStepEventCount == 0
            && stats.configurationChangeEvents == 0
            && stats.droppedPostCapCount == 0
    }
}


/// Device election for a capture-side swap: prefers the system default input; role transfers only when it equals the saved/original device.
nonisolated struct MeetingCaptureDeviceElection: Sendable, Equatable {
    var identity: MeetingMicrophoneIdentity
    var role: MeetingMicrophoneRole

    static func elect(original: MeetingMicrophoneIdentity) -> MeetingCaptureDeviceElection {
        Self.decide(
            original: original,
            catalog: MeetingCaptureSourceCatalog.availableMicrophones(),
            defaultInputUID: AudioDevice.getDefaultInputDevice()?.uid
        )
    }

    /// Pure decision extracted from `elect(original:)` for hardware-free testing.
    static func decide(
        original: MeetingMicrophoneIdentity,
        catalog: [MeetingMicrophoneIdentity],
        defaultInputUID: String?
    ) -> MeetingCaptureDeviceElection {
        guard let defaultInputUID else {
            return MeetingCaptureDeviceElection(identity: original, role: original.role)
        }
        guard let matched = catalog.first(where: { $0.coreAudioUID == defaultInputUID }) else {
            return MeetingCaptureDeviceElection(identity: original, role: original.role)
        }
        if matched.captureDeviceID == original.captureDeviceID {
            return MeetingCaptureDeviceElection(identity: matched, role: original.role)
        }
        // A built-in mic is inherently the owner's; .unknown would block VPIO on upgrades.
        let role: MeetingMicrophoneRole = matched.coreAudioUID == "BuiltInMicrophoneDevice" ? .personal : .unknown
        return MeetingCaptureDeviceElection(
            identity: MeetingMicrophoneIdentity(
                captureDeviceID: matched.captureDeviceID,
                coreAudioUID: matched.coreAudioUID,
                displayName: matched.displayName,
                role: role
            ),
            role: role
        )
    }
}

/// Pure discard rule extracted from the upgrade's ring-flush for hardware-free testing.
nonisolated enum MeetingUpgradeRingDiscard {
    static func discardingSamples(atOrBehind boundary: CMTime?, from samples: [CMSampleBuffer]) -> [CMSampleBuffer] {
        guard let boundary else { return samples }
        return samples.filter { CMSampleBufferGetPresentationTimeStamp($0) > boundary }
    }
}

/// Owns a swappable mic component (VPIO or AVCaptureSession) plus an app-audio-only SCStream that never stops across a swap.
private final nonisolated class VoiceProcessingMeetingRuntime: MeetingCaptureRuntime, @unchecked Sendable {
    private static let totalStartDeadlineSeconds: Double = 10
    private static let firstBufferDeadlineSeconds: Double = 2
    private static let downgradeSettleSeconds: Double = 0.75
    private static let upgradeSettleSeconds: Double = 0.75
    private static let upgradeDwellSeconds: Double = 10
    private static let maxUpgradeAttemptsPerSession = 3
    private static let upgradeBackoffBaseSeconds: Double = 5
    private static let oldProducerStopSupervisionSeconds: Double = 0.3

    private enum Phase: Equatable {
        case starting
        case vpio
        case transitioning
        case avCapture
        case failed
    }

    private let application: MeetingApplicationIdentity
    private let originalMicrophone: MeetingMicrophoneIdentity
    private let applicationWriter: MeetingAudioChunkWriter
    private let microphoneWriter: MeetingAudioChunkWriter
    private let eventHandler: @Sendable (MeetingCaptureEvent) -> Void
    private let liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    private let stateLock = NSLock()

    private var micCapture = MeetingMicrophoneCapture()
    private var gate = MeetingVoiceProcessingCommitGate()
    private var avCaptureComponent: MeetingAVCaptureMicrophoneComponent?
    private var currentFence = MeetingEraAcceptanceFence()
    private var interruptedThisEra = false

    private var appOnlyRuntime: ScreenCaptureMeetingRuntime?
    private var fallbackRuntime: ScreenCaptureMeetingRuntime?
    private var phase: Phase = .starting
    private var watchdogTask: Task<Void, Never>?
    private var outputRouteListener: MeetingOutputRouteListener?
    private var transitionTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var dwellArming = false
    private var stopRequested = false
    private var quarantined = false
    private var upgradeAttempts = 0
    private let abortedCaptureDrain = DispatchGroup()

    var captureScope: MeetingCaptureScope? {
        if let fallback = self.stateLock.withLock({ self.fallbackRuntime }) { return fallback.captureScope }
        return self.stateLock.withLock { self.appOnlyRuntime?.captureScope }
    }

    private init(
        application: MeetingApplicationIdentity,
        microphone: MeetingMicrophoneIdentity,
        applicationWriter: MeetingAudioChunkWriter,
        microphoneWriter: MeetingAudioChunkWriter,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    ) {
        self.application = application
        self.originalMicrophone = microphone
        self.applicationWriter = applicationWriter
        self.microphoneWriter = microphoneWriter
        self.eventHandler = eventHandler
        self.liveAudioHandler = liveAudioHandler
    }

    static func make(
        application: MeetingApplicationIdentity,
        microphone: MeetingMicrophoneIdentity,
        applicationWriter: MeetingAudioChunkWriter,
        microphoneWriter: MeetingAudioChunkWriter,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    ) async throws -> VoiceProcessingMeetingRuntime {
        VoiceProcessingMeetingRuntime(
            application: application,
            microphone: microphone,
            applicationWriter: applicationWriter,
            microphoneWriter: microphoneWriter,
            eventHandler: eventHandler,
            liveAudioHandler: liveAudioHandler
        )
    }

    func start() async throws {
        do {
            try await Self.withDeadline(seconds: Self.totalStartDeadlineSeconds) { [self] in
                try await self.runStartSequence()
            }
        } catch {
            // Deadline expiry during the fallback leg fails cleanly; never begin a further attempt.
            await self.cleanupAfterStartFailure()
            throw error
        }
    }

    private func runStartSequence() async throws {
        do {
            try await self.attemptVoiceProcessingStart()
        } catch {
            if error is CancellationError { throw error }
            if self.stateLock.withLock({ self.phase != .starting }) { throw error }
            let (gateToAbort, captureToStop, staleListener) = self.stateLock.withLock {
                () -> (MeetingVoiceProcessingCommitGate, MeetingMicrophoneCapture, MeetingOutputRouteListener?) in
                defer { self.outputRouteListener = nil }
                return (self.gate, self.micCapture, self.outputRouteListener)
            }
            _ = staleListener // released here, outside the lock
            gateToAbort.abort()
            await captureToStop.stop()
            await self.stopAppOnlyIfStarted()
            let fallback = try await ScreenCaptureMeetingRuntime.make(
                application: self.application,
                microphone: self.originalMicrophone,
                includeMicrophone: true,
                applicationWriter: self.applicationWriter,
                microphoneWriter: self.microphoneWriter,
                eventHandler: self.eventHandler,
                liveAudioHandler: self.liveAudioHandler
            )
            // Assigned before start() so a cancelled/failed start can still be found and stopped.
            self.stateLock.withLock { self.fallbackRuntime = fallback }
            try await fallback.start()
        }
    }

    private func attemptVoiceProcessingStart() async throws {
        let microphoneWriter = self.microphoneWriter
        let liveAudioHandler = self.liveAudioHandler
        let gate = self.gate
        let fence = self.currentFence
        let capture = self.stateLock.withLock { self.micCapture }
        let outcome = try await capture.start(
            microphone: self.originalMicrophone,
            onSample: { sample in
                guard fence.beginSample() else { return }
                defer { fence.endSample() }
                switch gate.offer(sample) {
                case .passthrough:
                    microphoneWriter.enqueue(sample)
                    liveAudioHandler?(.microphone, sample)
                case .buffered, .aborted:
                    break
                }
            },
            onEvent: { [weak self] event in
                self?.handleMicEvent(event, owner: capture)
            }
        )
        if case .unavailable = outcome {
            throw MeetingCaptureError.captureStartFailed("Voice-processing microphone capture was unavailable.")
        }

        guard await self.waitForBufferProgress(timeoutSeconds: Self.firstBufferDeadlineSeconds) else {
            throw MeetingCaptureError.captureStartFailed("No microphone audio was captured within 2s.")
        }

        let appOnly = try await ScreenCaptureMeetingRuntime.make(
            application: self.application,
            microphone: self.originalMicrophone,
            includeMicrophone: false,
            applicationWriter: self.applicationWriter,
            microphoneWriter: self.microphoneWriter,
            eventHandler: self.eventHandler,
            liveAudioHandler: self.liveAudioHandler
        )
        try await appOnly.start()
        self.stateLock.withLock { self.appOnlyRuntime = appOnly }

        guard var batch = self.gate.beginCommitFlush() else {
            throw MeetingCaptureError.captureStartFailed("Voice-processing commit gate aborted before commit.")
        }
        // Promote provenance BEFORE the gate flushes a single VPIO byte; after this point a failure
        // must fail the start outright — falling back would mix provenance on promoted writers.
        self.stateLock.withLock { self.phase = .vpio }
        let settled = await self.micCapture.settledConfiguration()
        try await self.microphoneWriter.updateTrackMetadata { track in
            track.captureMethod = .voiceProcessing
            track.voiceProcessingConfig = settled
            track.captureEras = [MeetingCaptureEra(
                method: .voiceProcessing,
                deviceUID: self.originalMicrophone.coreAudioUID,
                deviceName: self.originalMicrophone.displayName,
                roleAtElection: self.originalMicrophone.role,
                startSeconds: 0,
                settledConfig: settled
            )]
        }
        while true {
            await self.flushBatch(batch)
            guard let next = self.gate.continueCommitFlush() else { break }
            batch = next
        }
        self.startOutputRouteWatch()
        self.startWatchdog()
    }

    private func stopAppOnlyIfStarted() async {
        if let appOnly = self.stateLock.withLock({ self.appOnlyRuntime }) {
            try? await appOnly.stop()
            self.stateLock.withLock { self.appOnlyRuntime = nil }
        }
    }

    private func cleanupAfterStartFailure() async {
        if let fallback = self.stateLock.withLock({ self.fallbackRuntime }) {
            try? await fallback.stop()
        }
        await self.micCapture.stop()
        await self.stopAppOnlyIfStarted()
    }

    /// Paced flush: the writer's pending budget is 24 slots, a full 5s ring is ~50 buffers.
    private func flushBatch(_ samples: [CMSampleBuffer]) async {
        for (index, sample) in samples.enumerated() {
            self.microphoneWriter.enqueue(sample)
            self.liveAudioHandler?(.microphone, sample)
            if index % 4 == 3 {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    private func waitForBufferProgress(timeoutSeconds: Double, using capture: MeetingMicrophoneCapture? = nil) async -> Bool {
        let capture = capture ?? self.stateLock.withLock { self.micCapture }
        let baseline = await capture.statistics().buffersEmitted
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await capture.statistics().buffersEmitted > baseline { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func startWatchdog() {
        let task = Task { [weak self] in
            guard let self else { return }
            let capture = self.stateLock.withLock { self.micCapture }
            var lastCount = await capture.statistics().buffersEmitted
            var lastProgress = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard self.stateLock.withLock({ self.phase == .vpio && self.micCapture === capture }) else { return }
                let current = await capture.statistics()
                if current.buffersEmitted != lastCount {
                    lastCount = current.buffersEmitted
                    lastProgress = Date()
                    continue
                }
                if MeetingVoiceProcessingWatchdog.isStalled(secondsSinceLastEmittedBuffer: Date().timeIntervalSince(lastProgress)) {
                    self.beginDowngradeTransition(reason: "No microphone audio emitted for 10s (drops=\(current.droppedPostCapCount), conversionFailures=\(current.conversionFailures)).")
                    return
                }
            }
        }
        self.stateLock.withLock { self.watchdogTask = task }
    }

    /// Registered once: `handleRouteChange()` re-reads `phase` on every fire, so it never needs re-arming.
    private func startOutputRouteWatch() {
        let listener = MeetingOutputRouteListener { [weak self] in
            self?.handleRouteChange()
        }
        self.stateLock.withLock { self.outputRouteListener = listener }
    }

    private func handleRouteChange() {
        let currentPhase = self.stateLock.withLock { self.phase }
        switch currentPhase {
        case .vpio:
            let reason = MeetingCapturePathDecider.outputRouteDeclineReason(MeetingCaptureEngine.currentOutputRouteSnapshot())
            if let reason {
                self.beginDowngradeTransition(reason: "Output route changed: \(reason)")
            }
        case .avCapture:
            self.armUpgradeDwellIfViable()
        default:
            break
        }
    }

    private func handleMicEvent(_ event: MeetingMicrophoneCaptureEvent, owner: MeetingMicrophoneCapture) {
        let (phase, isOwner) = self.stateLock.withLock { (self.phase, self.micCapture === owner) }
        guard isOwner else { return }
        guard phase != .starting else {
            switch event {
            case .engineStopped:
                self.gate.offerTerminalEventPreCommit()
            case .defaultInputChanged:
                if let requestedUID = self.originalMicrophone.coreAudioUID,
                   AudioDevice.getDefaultInputDevice()?.uid != requestedUID
                {
                    self.gate.offerTerminalEventPreCommit()
                }
            case .configurationChanged, .overload:
                break
            }
            return
        }
        guard phase == .vpio else { return }
        switch event {
        case .configurationChanged:
            self.eventHandler(.interrupted(
                kind: .voiceProcessingConfigurationChanged, trackID: nil,
                detail: "Voice-processing engine configuration changed."
            ))
            Task { [weak self] in
                guard let self else { return }
                if await !self.waitForBufferProgress(timeoutSeconds: Self.firstBufferDeadlineSeconds) {
                    self.beginDowngradeTransition(detail: "No microphone audio resumed after a configuration change.")
                }
            }
        case .defaultInputChanged:
            guard let requestedUID = self.originalMicrophone.coreAudioUID else { return }
            if AudioDevice.getDefaultInputDevice()?.uid != requestedUID {
                self.beginDowngradeTransition(reason: "The default input device changed away from the requested microphone.")
            }
        case .overload:
            self.eventHandler(.interrupted(kind: .voiceProcessingOverload, trackID: nil, detail: "Voice-processing microphone reported an overload."))
        case .engineStopped:
            self.beginDowngradeTransition(reason: "The voice-processing microphone engine stopped unexpectedly.")
        }
    }

    private func handleAVCaptureFailureSignal(detail: String) {
        guard self.stateLock.withLock({ self.phase == .avCapture }) else { return }
        let shouldEmit = self.stateLock.withLock { () -> Bool in
            guard !self.interruptedThisEra else { return false }
            self.interruptedThisEra = true
            self.phase = .failed
            return true
        }
        guard shouldEmit else { return }
        self.eventHandler(.interrupted(kind: .captureStoppedUnexpectedly, trackID: nil, detail: detail))
    }

    private func beginDowngradeTransition(reason: String) {
        self.beginDowngradeTransition(detail: reason)
    }

    private func beginDowngradeTransition(detail: String) {
        let shouldStart = self.stateLock.withLock { () -> Bool in
            guard self.phase == .vpio, !self.stopRequested else { return false }
            self.phase = .transitioning
            return true
        }
        guard shouldStart else { return }
        let cancellables = self.stateLock.withLock { () -> [Task<Void, Never>?] in
            defer { self.dwellTask = nil; self.watchdogTask = nil }
            return [self.dwellTask, self.watchdogTask]
        }
        cancellables.forEach { $0?.cancel() }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDowngrade(detail: detail)
        }
        self.stateLock.withLock { self.transitionTask = task }
    }

    private func runDowngrade(detail: String) async {
        try? await Task.sleep(nanoseconds: UInt64(Self.downgradeSettleSeconds * 1_000_000_000))
        guard !(self.stateLock.withLock({ self.stopRequested })) else {
            self.finishTransition()
            return
        }

        let oldFence = self.stateLock.withLock { self.currentFence }
        let oldMicCapture = self.stateLock.withLock { self.micCapture }
        await oldFence.quiesce()
        let statsSnapshot = await oldMicCapture.statistics()
        let drift = MeetingClockDriftRecord(
            cumulativeAbsorbedSeconds: statsSnapshot.cumulativeAbsorbedCorrectionSeconds,
            elapsedValidHostSeconds: MeetingVoiceProcessingDriftSnapshot.elapsedValidHostSeconds(statsSnapshot),
            eligible: MeetingVoiceProcessingDriftSnapshot.isEligible(statsSnapshot)
        )
        // Detached, supervised: releases the HAL device before the new client opens it, without blocking the swap.
        oldMicCapture.stopDetachedSupervised(seconds: Self.oldProducerStopSupervisionSeconds) { [weak self] completedInTime in
            guard let self, !completedInTime else { return }
            self.stateLock.withLock { self.quarantined = true }
        }

        guard !(self.stateLock.withLock({ self.stopRequested })) else {
            self.finishTransition()
            return
        }

        let elected = MeetingCaptureDeviceElection.elect(original: self.originalMicrophone)
        let newFence = MeetingEraAcceptanceFence()
        let newGate = MeetingVoiceProcessingCommitGate()
        let microphoneWriter = self.microphoneWriter
        let liveAudioHandler = self.liveAudioHandler
        let component: MeetingAVCaptureMicrophoneComponent
        do {
            component = try MeetingAVCaptureMicrophoneComponent(
                microphone: elected.identity,
                onSample: { sample in
                    guard newFence.beginSample() else { return }
                    defer { newFence.endSample() }
                    switch newGate.offer(sample) {
                    case .passthrough:
                        microphoneWriter.enqueue(sample)
                        liveAudioHandler?(.microphone, sample)
                    case .buffered, .aborted:
                        break
                    }
                },
                onTerminalStop: { [weak self] detail in
                    self?.handleAVCaptureFailureSignal(detail: detail)
                }
            )
            try await component.start()
        } catch {
            self.stateLock.withLock { self.phase = .failed }
            self.eventHandler(.interrupted(
                kind: .captureStoppedUnexpectedly, trackID: nil,
                detail: "Microphone unavailable after a route change: \(error.localizedDescription)"
            ))
            self.finishTransition()
            return
        }

        if self.stateLock.withLock({ self.stopRequested }) {
            try? await component.stop()
            self.finishTransition()
            return
        }

        let boundary = await self.microphoneWriter.beginSplice()

        // A nil or non-monotonic boundary would misattribute audio; skip the era record instead.
        var recordedNewEra = false
        try? await self.microphoneWriter.updateTrackMetadata { [weak self] track in
            guard let self else { return }
            var eras = track.captureEras ?? [self.legacyEra(from: track)]
            if var last = eras.popLast() {
                last.clockDrift = drift
                eras.append(last)
            }
            if let boundary, boundary.seconds > (eras.last?.startSeconds ?? -.infinity) {
                eras.append(MeetingCaptureEra(
                    method: .avCaptureSession,
                    deviceUID: elected.identity.coreAudioUID,
                    deviceName: elected.identity.displayName,
                    roleAtElection: elected.role,
                    startSeconds: boundary.seconds
                ))
                recordedNewEra = true
            }
            track.captureEras = eras
            // Multi-era: a track-level-only reader sees the conservative (AVCapture) value.
            track.captureMethod = .avCaptureSession
            track.clockDrift = drift
        }
        if !recordedNewEra {
            DebugLogger.shared.warning(
                "Meeting downgrade: no valid splice boundary (nil or non-monotonic) — the AVCapture era was not recorded; turns after this point stay attributed to the prior era.",
                source: "MeetingCaptureEngine"
            )
        }

        self.stateLock.withLock {
            self.currentFence = newFence
            self.avCaptureComponent = component
            self.phase = .avCapture
            self.interruptedThisEra = false
        }

        // Ack before flushing: readers must re-arm before any post-boundary sample reaches them.
        let ack = MeetingCaptureMethodChangeAck()
        self.eventHandler(.captureMethodChanged(trackID: self.microphoneWriter.trackID, method: .avCaptureSession, ack: ack))
        await ack.wait()

        if var batch = newGate.beginCommitFlush() {
            while true {
                await self.flushBatch(batch)
                guard let next = newGate.continueCommitFlush() else { break }
                batch = next
            }
        }

        self.finishTransition()
        self.armUpgradeDwellIfViable()
    }

    private func legacyEra(from track: MeetingAudioTrack) -> MeetingCaptureEra {
        MeetingCaptureEra(
            method: track.captureMethod ?? .voiceProcessing,
            deviceUID: self.originalMicrophone.coreAudioUID,
            deviceName: self.originalMicrophone.displayName,
            roleAtElection: self.originalMicrophone.role,
            startSeconds: 0,
            settledConfig: track.voiceProcessingConfig,
            clockDrift: track.clockDrift
        )
    }

    /// `dwellArming` reserves the slot in the SAME critical section as the `dwellTask == nil` check.
    private func armUpgradeDwellIfViable() {
        guard self.stateLock.withLock({
            guard self.phase == .avCapture, self.dwellTask == nil, !self.dwellArming, !self.quarantined,
                  !self.stopRequested, self.upgradeAttempts < Self.maxUpgradeAttemptsPerSession
            else { return false }
            self.dwellArming = true
            return true
        }) else { return }
        let decision = MeetingCapturePathDecider.decide(
            mode: .onlineCall,
            microphone: self.originalMicrophone,
            outputRoute: MeetingCaptureEngine.currentOutputRouteSnapshot()
        )
        guard case .voiceProcessing = decision else {
            self.stateLock.withLock { self.dwellArming = false }
            return
        }

        let attemptIndex = self.stateLock.withLock { self.upgradeAttempts }
        let backoffSeconds = attemptIndex == 0 ? 0 : Self.upgradeBackoffBaseSeconds * pow(2, Double(attemptIndex - 1))
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            try? await Task.sleep(nanoseconds: UInt64(Self.upgradeDwellSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.stateLock.withLock { self.dwellTask = nil }
            guard !(self.stateLock.withLock({ self.stopRequested })), self.stateLock.withLock({ self.phase == .avCapture }) else { return }
            let stillViable = MeetingCapturePathDecider.decide(
                mode: .onlineCall,
                microphone: self.originalMicrophone,
                outputRoute: MeetingCaptureEngine.currentOutputRouteSnapshot()
            )
            guard case .voiceProcessing = stillViable else { return }
            await self.attemptUpgrade()
        }
        self.stateLock.withLock { self.dwellTask = task; self.dwellArming = false }
    }

    private func attemptUpgrade() async {
        let shouldStart = self.stateLock.withLock { () -> Bool in
            guard self.phase == .avCapture, !self.stopRequested else { return false }
            self.phase = .transitioning
            self.upgradeAttempts += 1
            return true
        }
        guard shouldStart else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runUpgrade()
        }
        self.stateLock.withLock { self.transitionTask = task }
        await task.value
    }

    private func runUpgrade() async {
        try? await Task.sleep(nanoseconds: UInt64(Self.upgradeSettleSeconds * 1_000_000_000))
        guard !(self.stateLock.withLock({ self.stopRequested })) else {
            self.finishTransition()
            return
        }
        guard case .voiceProcessing = MeetingCapturePathDecider.decide(
            mode: .onlineCall, microphone: self.originalMicrophone,
            outputRoute: MeetingCaptureEngine.currentOutputRouteSnapshot()
        ) else {
            self.stateLock.withLock { self.phase = .avCapture }
            self.finishTransition()
            return
        }

        let elected = MeetingCaptureDeviceElection.elect(original: self.originalMicrophone)
        let candidateMicCapture = MeetingMicrophoneCapture()
        let candidateGate = MeetingVoiceProcessingCommitGate()
        let candidateFence = MeetingEraAcceptanceFence()

        let outcome: MeetingMicrophoneBindingOutcome
        do {
            outcome = try await candidateMicCapture.start(
                microphone: elected.identity,
                onSample: { sample in
                    guard candidateFence.beginSample() else { return }
                    defer { candidateFence.endSample() }
                    _ = candidateGate.offer(sample) // ring-gated: AVCapture stays authoritative
                },
                onEvent: { [weak self] event in
                    self?.handleMicEvent(event, owner: candidateMicCapture)
                }
            )
        } catch {
            self.abortUpgrade(candidateMicCapture: candidateMicCapture, reason: error.localizedDescription)
            return
        }
        if case .unavailable = outcome {
            self.abortUpgrade(candidateMicCapture: candidateMicCapture, reason: "Voice-processing microphone capture was unavailable.")
            return
        }
        guard await self.waitForBufferProgress(timeoutSeconds: Self.firstBufferDeadlineSeconds, using: candidateMicCapture) else {
            self.abortUpgrade(candidateMicCapture: candidateMicCapture, reason: "No microphone audio was captured within 2s.")
            return
        }
        guard !(self.stateLock.withLock({ self.stopRequested })) else {
            self.abortUpgrade(candidateMicCapture: candidateMicCapture, reason: nil)
            return
        }
        guard case .voiceProcessing = MeetingCapturePathDecider.decide(
            mode: .onlineCall, microphone: self.originalMicrophone,
            outputRoute: MeetingCaptureEngine.currentOutputRouteSnapshot()
        ) else {
            self.abortUpgrade(candidateMicCapture: candidateMicCapture, reason: "Route changed back before the upgrade committed.")
            return
        }

        // Fence AVCapture's own acceptance so exactly one producer feeds the post-boundary chunk.
        let oldFence = self.stateLock.withLock { self.currentFence }
        let oldComponent = self.stateLock.withLock { self.avCaptureComponent }
        await oldFence.quiesce()

        let boundary = await self.microphoneWriter.beginSplice()
        let boundaryTime = boundary.map { CMTime(value: $0.value, timescale: $0.timescale) }

        guard let ring = candidateGate.beginCommitFlush() else {
            self.abortUpgrade(candidateMicCapture: candidateMicCapture, reason: "Voice-processing commit gate aborted before commit.")
            return
        }
        // Discard ring samples at/behind the boundary — else every upgrade duplicates ~2s.
        var pendingRing = MeetingUpgradeRingDiscard.discardingSamples(atOrBehind: boundaryTime, from: ring)

        let settled = await candidateMicCapture.settledConfiguration()
        // A nil or non-monotonic boundary would misattribute audio; skip the era record instead.
        var recordedNewEra = false
        try? await self.microphoneWriter.updateTrackMetadata { track in
            var eras = track.captureEras ?? []
            if let boundary, boundary.seconds > (eras.last?.startSeconds ?? -.infinity) {
                eras.append(MeetingCaptureEra(
                    method: .voiceProcessing,
                    deviceUID: elected.identity.coreAudioUID,
                    deviceName: elected.identity.displayName,
                    roleAtElection: elected.role,
                    startSeconds: boundary.seconds,
                    settledConfig: settled
                ))
                recordedNewEra = true
            }
            track.captureEras = eras
            track.captureMethod = .avCaptureSession // still multi-era: conservative legacy value
            track.voiceProcessingConfig = settled
        }
        if !recordedNewEra {
            DebugLogger.shared.warning(
                "Meeting upgrade: no valid splice boundary (nil or non-monotonic) — the voice-processing era was not recorded; turns after this point stay attributed to the prior era.",
                source: "MeetingCaptureEngine"
            )
        }

        // Awaited: the MainActor hop (filter re-arm, history entry) must land before the gate opens.
        let ack = MeetingCaptureMethodChangeAck()
        self.eventHandler(.captureMethodChanged(trackID: self.microphoneWriter.trackID, method: .voiceProcessing, ack: ack))
        await ack.wait()

        self.stateLock.withLock {
            self.currentFence = candidateFence
            self.micCapture = candidateMicCapture
            self.gate = candidateGate
            self.phase = .vpio
            self.interruptedThisEra = false
            self.upgradeAttempts = 0
            self.avCaptureComponent = nil
        }

        while true {
            await self.flushBatch(pendingRing)
            guard let next = candidateGate.continueCommitFlush() else { break }
            pendingRing = next
        }

        self.startWatchdog()

        if let oldComponent {
            oldComponent.stopDetached(supervisedSeconds: Self.oldProducerStopSupervisionSeconds) { [weak self] completedInTime in
                guard let self, !completedInTime else { return }
                self.stateLock.withLock { self.quarantined = true }
            }
        }

        self.finishTransition()
    }

    private func abortUpgrade(candidateMicCapture: MeetingMicrophoneCapture, reason: String?) {
        if let reason {
            DebugLogger.shared.log("Meeting VPIO upgrade aborted: \(reason)", source: "MeetingCaptureEngine")
        }
        // Tracked in `abortedCaptureDrain` so stop() can wait it out instead of leaking it.
        self.abortedCaptureDrain.enter()
        candidateMicCapture.stopDetachedSupervised(seconds: Self.oldProducerStopSupervisionSeconds) { [weak self] _ in
            self?.abortedCaptureDrain.leave()
        }
        self.stateLock.withLock { self.phase = .avCapture }
        self.finishTransition()
        self.armUpgradeDwellIfViable()
    }

    private func drainAbortedCaptures() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.abortedCaptureDrain.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }
    }

    private func finishTransition() {
        self.stateLock.withLock { self.transitionTask = nil }
    }

    func stop() async throws {
        let dwell = self.stateLock.withLock { () -> Task<Void, Never>? in
            self.stopRequested = true
            defer { self.dwellTask = nil }
            return self.dwellTask
        }
        dwell?.cancel()

        if let transitionTask = self.stateLock.withLock({ self.transitionTask }) {
            await transitionTask.value
        }
        await self.drainAbortedCaptures()
        let (watchdog, staleListener) = self.stateLock.withLock { () -> (Task<Void, Never>?, MeetingOutputRouteListener?) in
            defer { self.watchdogTask = nil; self.outputRouteListener = nil }
            return (self.watchdogTask, self.outputRouteListener)
        }
        watchdog?.cancel()
        _ = staleListener // released here, outside the lock

        if let fallback = self.stateLock.withLock({ self.fallbackRuntime }) {
            try await fallback.stop()
            return
        }

        let phase = self.stateLock.withLock { self.phase }
        guard phase == .vpio || phase == .avCapture else {
            let (gateToAbort, captureToStop) = self.stateLock.withLock { (self.gate, self.micCapture) }
            gateToAbort.abort()
            await captureToStop.stop()
            if let component = self.stateLock.withLock({ self.avCaptureComponent }) {
                try? await component.stop()
            }
            await self.stopAppOnlyIfStarted()
            return
        }

        if phase == .vpio {
            // Quiesce first — stats must not be snapshotted while the tap can still emit.
            let micCapture = self.stateLock.withLock { self.micCapture }
            await micCapture.stop()
            let statsSnapshot = await micCapture.statistics()
            let drift = MeetingClockDriftRecord(
                cumulativeAbsorbedSeconds: statsSnapshot.cumulativeAbsorbedCorrectionSeconds,
                elapsedValidHostSeconds: MeetingVoiceProcessingDriftSnapshot.elapsedValidHostSeconds(statsSnapshot),
                eligible: MeetingVoiceProcessingDriftSnapshot.isEligible(statsSnapshot)
            )
            try? await self.microphoneWriter.updateTrackMetadata { track in
                track.clockDrift = drift
                if var eras = track.captureEras, var last = eras.popLast() {
                    last.clockDrift = drift
                    eras.append(last)
                    track.captureEras = eras
                }
            }
        } else if let component = self.stateLock.withLock({ self.avCaptureComponent }) {
            try? await component.stop()
        }

        if let appOnly = self.stateLock.withLock({ self.appOnlyRuntime }) {
            try await appOnly.stop()
        }
    }

    private static func withDeadline<T>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MeetingCaptureError.captureStartFailed("Voice-processing capture start exceeded \(Int(seconds))s.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MeetingCaptureError.captureStartFailed("Voice-processing capture start produced no result.")
            }
            return result
        }
    }
}
