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

            let flag = SettingsStore.shared.meetingVPIOMicCapture
            let decision = MeetingCapturePathDecider.decide(
                flag: flag,
                mode: configuration.mode,
                microphone: configuration.microphone,
                outputRoute: Self.currentOutputRouteSnapshot()
            )
            switch decision {
            case let .screenCaptureKit(reason):
                if flag {
                    DebugLogger.shared.log(
                        "Meeting voice-processing capture declined: \(reason)",
                        source: "MeetingCaptureEngine"
                    )
                    eventHandler(.interrupted(kind: .voiceProcessingDeclined, trackID: nil, detail: reason))
                }
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
    /// Immutable for the runtime's lifetime: a mid-run flag flip never drops/adds the mic.
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

/// Pure decision table. Role is deliberately NOT consulted — `.unknown` everywhere on this branch.
nonisolated enum MeetingCapturePathDecider {
    static func decide(
        flag: Bool,
        mode: MeetingCaptureMode,
        microphone: MeetingMicrophoneIdentity,
        outputRoute: MeetingOutputRouteSnapshot
    ) -> MeetingCapturePathDecision {
        guard flag else {
            return .screenCaptureKit(reason: "Voice-processing meeting capture is disabled in Settings.")
        }
        guard mode == .onlineCall else {
            return .screenCaptureKit(reason: "Voice-processing capture only applies to online-call recordings.")
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
    private let onViolation: @Sendable () -> Void
    private let lock = NSLock()
    private var defaultOutputToken: AudioObjectPropertyListenerBlock?
    private var serviceRestartedToken: AudioObjectPropertyListenerBlock?
    private var dataSourceToken: AudioObjectPropertyListenerBlock?
    private var dataSourceDeviceID: AudioObjectID?

    init?(onViolation: @escaping @Sendable () -> Void) {
        self.onViolation = onViolation
        guard self.register() else { return nil }
    }

    deinit {
        self.unregister()
    }

    private func predicateFails() -> Bool {
        MeetingCapturePathDecider.outputRouteDeclineReason(MeetingCaptureEngine.currentOutputRouteSnapshot()) != nil
    }

    private func reevaluate() {
        if self.predicateFails() { self.onViolation() }
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
            self.onViolation()
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

/// Owns a VPIO `MeetingMicrophoneCapture` plus an app-audio-only `ScreenCaptureMeetingRuntime`.
/// On any failure before commit, aborts cleanly and falls back to today's app+mic SCStream path
/// using the SAME writers — the fallback never sees a byte or event from the aborted attempt.
private final nonisolated class VoiceProcessingMeetingRuntime: MeetingCaptureRuntime, @unchecked Sendable {
    private static let totalStartDeadlineSeconds: Double = 10
    private static let firstBufferDeadlineSeconds: Double = 2

    private let application: MeetingApplicationIdentity
    private let microphone: MeetingMicrophoneIdentity
    private let applicationWriter: MeetingAudioChunkWriter
    private let microphoneWriter: MeetingAudioChunkWriter
    private let eventHandler: @Sendable (MeetingCaptureEvent) -> Void
    private let liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    private let micCapture = MeetingMicrophoneCapture()
    private let gate = MeetingVoiceProcessingCommitGate()
    private let stateLock = NSLock()

    private var appOnlyRuntime: ScreenCaptureMeetingRuntime?
    private var fallbackRuntime: ScreenCaptureMeetingRuntime?
    private var promoted = false
    private var committed = false
    private var interrupted = false
    private var watchdogTask: Task<Void, Never>?
    private var outputRouteListener: MeetingOutputRouteListener?

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
        self.microphone = microphone
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
            if self.stateLock.withLock({ self.promoted }) { throw error }
            self.gate.abort()
            self.outputRouteListener = nil
            await self.micCapture.stop()
            await self.stopAppOnlyIfStarted()
            let fallback = try await ScreenCaptureMeetingRuntime.make(
                application: self.application,
                microphone: self.microphone,
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
        let outcome = try await self.micCapture.start(
            microphone: self.microphone,
            onSample: { sample in
                switch gate.offer(sample) {
                case .passthrough:
                    microphoneWriter.enqueue(sample)
                    liveAudioHandler?(.microphone, sample)
                case .buffered, .aborted:
                    break
                }
            },
            onEvent: { [weak self] event in
                self?.handleMicEvent(event)
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
            microphone: self.microphone,
            includeMicrophone: false,
            applicationWriter: self.applicationWriter,
            microphoneWriter: self.microphoneWriter,
            eventHandler: self.eventHandler,
            liveAudioHandler: self.liveAudioHandler
        )
        try await appOnly.start()
        self.stateLock.withLock { self.appOnlyRuntime = appOnly }

        self.outputRouteListener = MeetingOutputRouteListener { [weak self] in
            self?.interrupt(detail: "Output switched to Bluetooth/headphones — voice-processing capture cannot continue.")
        }
        guard self.outputRouteListener != nil else {
            throw MeetingCaptureError.captureStartFailed("Could not register the output-route listener.")
        }

        guard var batch = self.gate.beginCommitFlush() else {
            throw MeetingCaptureError.captureStartFailed("Voice-processing commit gate aborted before commit.")
        }
        // Promote provenance BEFORE the gate flushes a single VPIO byte; after this point a failure
        // must fail the start outright — falling back would mix provenance on promoted writers.
        self.stateLock.withLock { self.promoted = true }
        let settled = await self.micCapture.settledConfiguration()
        try await self.microphoneWriter.updateTrackMetadata { track in
            track.captureMethod = .voiceProcessing
            track.voiceProcessingConfig = settled
        }
        while true {
            await self.flushBatch(batch)
            guard let next = self.gate.continueCommitFlush() else { break }
            batch = next
        }
        self.stateLock.withLock { self.committed = true }
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

    private func waitForBufferProgress(timeoutSeconds: Double) async -> Bool {
        let baseline = await self.micCapture.statistics().buffersEmitted
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await self.micCapture.statistics().buffersEmitted > baseline { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func startWatchdog() {
        self.watchdogTask = Task { [weak self] in
            guard let self else { return }
            var lastCount = await self.micCapture.statistics().buffersEmitted
            var lastProgress = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                let current = await self.micCapture.statistics()
                if current.buffersEmitted != lastCount {
                    lastCount = current.buffersEmitted
                    lastProgress = Date()
                    continue
                }
                if MeetingVoiceProcessingWatchdog.isStalled(secondsSinceLastEmittedBuffer: Date().timeIntervalSince(lastProgress)) {
                    self.interrupt(detail: "No microphone audio emitted for 10s (drops=\(current.droppedPostCapCount), conversionFailures=\(current.conversionFailures)).")
                    return
                }
            }
        }
    }

    /// Terminal pre-commit events abort the attempt; non-terminal ones are swallowed by the gate.
    private func handleMicEvent(_ event: MeetingMicrophoneCaptureEvent) {
        guard self.gate.isCommitted else {
            switch event {
            case .engineStopped:
                self.gate.offerTerminalEventPreCommit()
            case .defaultInputChanged:
                if let requestedUID = self.microphone.coreAudioUID,
                   AudioDevice.getDefaultInputDevice()?.uid != requestedUID
                {
                    self.gate.offerTerminalEventPreCommit()
                }
            case .configurationChanged, .overload:
                break
            }
            return
        }
        switch event {
        case .configurationChanged:
            self.eventHandler(.interrupted(
                kind: .voiceProcessingConfigurationChanged, trackID: nil,
                detail: "Voice-processing engine configuration changed."
            ))
            Task { [weak self] in
                guard let self else { return }
                if await !self.waitForBufferProgress(timeoutSeconds: Self.firstBufferDeadlineSeconds) {
                    self.interrupt(detail: "No microphone audio resumed after a configuration change.")
                }
            }
        case .defaultInputChanged:
            guard let requestedUID = self.microphone.coreAudioUID else { return }
            if AudioDevice.getDefaultInputDevice()?.uid != requestedUID {
                self.interrupt(detail: "The default input device changed away from the requested microphone.")
            }
        case .overload:
            self.eventHandler(.interrupted(kind: .voiceProcessingOverload, trackID: nil, detail: "Voice-processing microphone reported an overload."))
        case .engineStopped:
            self.interrupt(detail: "The voice-processing microphone engine stopped unexpectedly.")
        }
    }

    private func interrupt(detail: String) {
        let shouldEmit = self.stateLock.withLock { () -> Bool in
            guard self.committed, !self.interrupted else { return false }
            self.interrupted = true
            return true
        }
        guard shouldEmit else { return }
        self.eventHandler(.interrupted(kind: .captureStoppedUnexpectedly, trackID: nil, detail: detail))
    }

    func stop() async throws {
        self.watchdogTask?.cancel()
        self.watchdogTask = nil
        self.outputRouteListener = nil

        if let fallback = self.stateLock.withLock({ self.fallbackRuntime }) {
            try await fallback.stop()
            return
        }
        guard self.stateLock.withLock({ self.committed }) else {
            self.gate.abort()
            await self.micCapture.stop()
            await self.stopAppOnlyIfStarted()
            return
        }

        // Quiesce first: stats must not be snapshotted while the tap can still emit, and stop-time
        // churn must not poison the drift record (capture.stop tears down observers before the tap).
        await self.micCapture.stop()
        let statsSnapshot = await self.micCapture.statistics()
        let drift = MeetingClockDriftRecord(
            cumulativeAbsorbedSeconds: statsSnapshot.cumulativeAbsorbedCorrectionSeconds,
            elapsedValidHostSeconds: MeetingVoiceProcessingDriftSnapshot.elapsedValidHostSeconds(statsSnapshot),
            eligible: MeetingVoiceProcessingDriftSnapshot.isEligible(statsSnapshot)
        )
        try await self.microphoneWriter.updateTrackMetadata { track in track.clockDrift = drift }

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
