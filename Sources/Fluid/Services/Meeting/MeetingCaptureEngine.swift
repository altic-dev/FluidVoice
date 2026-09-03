import AppKit
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

nonisolated protocol MeetingCaptureControlling: Sendable {
    /// Any user-facing permission request must complete before the coordinator reserves
    /// the exclusive ASR meeting lease.
    func preflightPermissions() async throws

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

    func preflightPermissions() async throws {
        try await Self.requestMicrophonePermissionIfNeeded()
    }

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
        try Self.verifyMicrophonePermission()

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
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingCaptureEngine, queueRole: .actorControl, phase: .runtimeStop)
            #endif
            let runtimeFailure: Error?
            do {
                try await activeCapture.runtime.stop()
                runtimeFailure = nil
                #if DEBUG
                AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingCaptureEngine, queueRole: .actorControl, phase: .runtimeStop)
                #endif
            } catch {
                runtimeFailure = error
                #if DEBUG
                AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingCaptureEngine, queueRole: .actorControl, phase: .runtimeStop, status: -1)
                #endif
            }
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingCaptureEngine, queueRole: .actorControl, phase: .writerStop)
            #endif
            let tracks = await Self.stopWriters(activeCapture.writers)
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingCaptureEngine, queueRole: .actorControl, phase: .writerStop)
            #endif
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
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingCaptureEngine, queueRole: .actorControl, phase: .captureStop)
            #endif
            self.activeCapture = nil
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingCaptureEngine, queueRole: .actorControl, phase: .captureStop)
            #endif
            self.stopTask = nil
            self.releaseDisplaySleepAssertion()
            return result
        } catch {
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingCaptureEngine, queueRole: .actorControl, phase: .captureStop)
            #endif
            self.activeCapture = nil
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingCaptureEngine, queueRole: .actorControl, phase: .captureStop, status: -1)
            #endif
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

    private nonisolated static func requestMicrophonePermissionIfNeeded() async throws {
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

    private nonisolated static func verifyMicrophonePermission() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
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

    /// `preferredWindowID` — typically the window auto-detection found evidence in — wins outright
    /// when it is still among the eligible candidates; otherwise falls back to ranked selection.
    static func selectWindow(from candidates: [MeetingWindowCandidate], preferredWindowID: UInt32? = nil) -> MeetingWindowCandidate? {
        let eligible = candidates
            .filter { $0.layer == 0 && $0.frame.width >= self.minimumWidth && $0.frame.height >= self.minimumHeight }
        if let preferredWindowID, let preferred = eligible.first(where: { $0.windowID == preferredWindowID }) {
            return preferred
        }
        return eligible.sorted(by: self.isRanked).first
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
        let resolvedMicrophone = includeMicrophone
            ? try MeetingAVCaptureMicrophoneResolver.resolve(microphone)
            : microphone
        let built = try await Self.buildStream(
            application: application,
            microphone: resolvedMicrophone,
            includeMicrophone: includeMicrophone
        )
        let runtime = ScreenCaptureMeetingRuntime(
            stream: built.stream,
            scope: built.scope,
            application: application,
            microphone: resolvedMicrophone,
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
        if let window = Self.selectWindow(for: runningApplication, in: content, preferredWindowID: application.windowID) {
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
        in content: SCShareableContent,
        preferredWindowID: UInt32? = nil
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
        guard let winner = MeetingWindowSelector.selectWindow(from: candidates, preferredWindowID: preferredWindowID) else { return nil }
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
        #if DEBUG
        AudioTopologyDiagnostics.record(.phaseBegin, owner: .screenCapture, queueRole: .actorControl, phase: .screenCaptureStop)
        defer { AudioTopologyDiagnostics.record(.phaseEnd, owner: .screenCapture, queueRole: .actorControl, phase: .screenCaptureStop) }
        #endif
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
        let resolvedMicrophone = try MeetingAVCaptureMicrophoneResolver.resolve(microphone)
        guard let captureDeviceID = resolvedMicrophone.avCaptureDeviceID,
              let device = AVCaptureDevice(uniqueID: captureDeviceID)
        else {
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
        #if DEBUG
        AudioTopologyDiagnostics.record(.ownerWillDeinit, owner: .avCapture, queueRole: .callbackCurrent, phase: .avCaptureStop)
        #endif
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
        #if DEBUG
        AudioTopologyDiagnostics.record(.phaseBegin, owner: .avCapture, queueRole: .dedicatedControl, phase: .avCaptureStop)
        defer { AudioTopologyDiagnostics.record(.phaseEnd, owner: .avCapture, queueRole: .dedicatedControl, phase: .avCaptureStop) }
        #endif
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

/// Serializes an uninterruptible framework start with its retirement barrier.
/// `stop()` cannot complete until an already-enqueued `start()` has returned and
/// the stop operation has run behind it on the same queue.
final nonisolated class MeetingSerializedCaptureLifecycle: @unchecked Sendable {
    private let queue: DispatchQueue
    private let admissionLock = NSLock()
    private let startOperation: @Sendable () -> Bool
    private let stopOperation: @Sendable () -> Void
    private var nextOrdinal: UInt64 = 0
    private var retirementOrdinal: UInt64?

    init(
        label: String = "com.fluidvoice.meeting.avcapture.control",
        start: @escaping @Sendable () -> Bool,
        stop: @escaping @Sendable () -> Void
    ) {
        self.queue = DispatchQueue(label: label)
        self.startOperation = start
        self.stopOperation = stop
    }

    func start() async -> Bool {
        await withCheckedContinuation { continuation in
            let enqueued = self.admissionLock.withLock { () -> Bool in
                guard self.retirementOrdinal == nil else { return false }
                self.nextOrdinal &+= 1
                let startOrdinal = self.nextOrdinal
                // Enqueue while admission is locked. A competing stop therefore
                // either queues behind this admitted start or seals admission first.
                self.queue.async {
                    let mayRun = self.admissionLock.withLock {
                        self.retirementOrdinal.map { startOrdinal < $0 } ?? true
                    }
                    continuation.resume(returning: mayRun ? self.startOperation() : false)
                }
                return true
            }
            if !enqueued { continuation.resume(returning: false) }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            self.admissionLock.withLock {
                if self.retirementOrdinal == nil {
                    self.nextOrdinal &+= 1
                    self.retirementOrdinal = self.nextOrdinal
                }
                // The permanent seal and barrier enqueue are one atomic admission
                // operation, so no start can slip behind stopRunning.
                self.queue.async {
                    self.stopOperation()
                    continuation.resume()
                }
            }
        }
    }

    func perform(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            self.queue.async {
                work()
                continuation.resume()
            }
        }
    }
}

/// Reusable AVCaptureSession mic component: `wasInterrupted` restarts only if still not running; runtime errors get ONE serialized restart.
final nonisolated class MeetingAVCaptureMicrophoneComponent: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private static let interruptionEndedWaitSeconds: Double = 3

    let deviceUID: String?
    let deviceName: String

    private let session: AVCaptureSession
    private let output: AVCaptureAudioDataOutput
    private let lifecycle: MeetingSerializedCaptureLifecycle
    private let stateLock = NSLock()
    private let onSample: @Sendable (CMSampleBuffer) -> Void
    private let onTerminalStop: @Sendable (String) -> Void
    private var stopping = false
    private var fullyRetired = false
    private var emittedTerminalStop = false
    private var runtimeErrorRestarted = false
    private var didStopRunningRestarted = false
    private var deliveredSampleCount: UInt64 = 0
    private var interruptionEndWaiters: [MeetingOneShotValue<Void>] = []

    init(
        microphone: MeetingMicrophoneIdentity,
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
        onTerminalStop: @escaping @Sendable (String) -> Void
    ) throws {
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        self.session = session
        self.output = output
        self.lifecycle = MeetingSerializedCaptureLifecycle(
            start: {
                session.startRunning()
                return session.isRunning
            },
            stop: {
                if session.isRunning { session.stopRunning() }
                // `stopRunning()` only stops delivery; the session still owns its
                // input device until its graph is dismantled. VPIO must never be
                // enabled while those AVFoundation objects retain the device.
                output.setSampleBufferDelegate(nil, queue: nil)
                session.beginConfiguration()
                for sessionOutput in session.outputs { session.removeOutput(sessionOutput) }
                for sessionInput in session.inputs { session.removeInput(sessionInput) }
                session.commitConfiguration()
            }
        )
        self.deviceUID = microphone.coreAudioUID
        self.deviceName = microphone.displayName
        self.onSample = onSample
        self.onTerminalStop = onTerminalStop
        super.init()
        let resolvedMicrophone = try MeetingAVCaptureMicrophoneResolver.resolve(microphone)
        guard let captureDeviceID = resolvedMicrophone.avCaptureDeviceID,
              let device = AVCaptureDevice(uniqueID: captureDeviceID)
        else {
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
        #if DEBUG
        AudioTopologyDiagnostics.record(.ownerWillDeinit, owner: .avCapture, queueRole: .callbackCurrent, phase: .avCaptureStop)
        #endif
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    private var observers: [NSObjectProtocol] = []

    /// Runs `startRunning` on the serial control queue. This intentionally has no
    /// detached timeout: a timed-out AVFoundation call could otherwise finish after
    /// meeting ownership was released and collide with dictation.
    func start() async throws {
        for (attempt, delay) in ([0] + Self.startRetryDelays).enumerated() {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            if self.stateLock.withLock({ self.stopping }) { throw CancellationError() }
            if await self.startRunningOnControlQueue() { return }
        }
        throw MeetingCaptureError.captureStartFailed("The microphone did not start.")
    }

    private static let startRetryDelays: [Double] = [0.5, 1.0, 2.0]

    private func startRunningOnControlQueue() async -> Bool {
        await self.lifecycle.start()
    }

    func stop() async throws {
        #if DEBUG
        AudioTopologyDiagnostics.record(.phaseBegin, owner: .avCapture, queueRole: .dedicatedControl, phase: .avCaptureStop)
        defer { AudioTopologyDiagnostics.record(.phaseEnd, owner: .avCapture, queueRole: .dedicatedControl, phase: .avCaptureStop) }
        #endif
        let waiters = self.stateLock.withLock { () -> [MeetingOneShotValue<Void>] in
            self.stopping = true
            defer { self.interruptionEndWaiters = [] }
            return self.interruptionEndWaiters
        }
        waiters.forEach { $0.resume(()) }

        await self.lifecycle.stop()
        let observers = self.stateLock.withLock { () -> [NSObjectProtocol] in
            defer { self.observers.removeAll() }
            return self.observers
        }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        await self.lifecycle.perform { [self] in
            let proven = !self.session.isRunning
                && self.session.inputs.isEmpty
                && self.session.outputs.isEmpty
            self.stateLock.withLock { self.fullyRetired = proven }
        }
    }

    func isFullyRetired() -> Bool {
        self.stateLock.withLock { self.fullyRetired }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        self.stateLock.lock()
        let shouldAccept = !self.stopping
        if shouldAccept { self.deliveredSampleCount &+= 1 }
        self.stateLock.unlock()
        guard shouldAccept else { return }
        self.onSample(sampleBuffer)
    }

    func sampleCount() -> UInt64 {
        self.stateLock.withLock { self.deliveredSampleCount }
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
        let restarted = await self.startRunningOnControlQueue()
        guard !restarted, !(self.stateLock.withLock({ self.stopping })) else { return }
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

/// Identity fence for terminal callbacks. A retired candidate from an earlier
/// retry can share the transition generation but must never fail its successor.
final nonisolated class MeetingAVCaptureAttemptToken: @unchecked Sendable {}

nonisolated enum MeetingAVCaptureFailureAdmission {
    static func accepts(
        currentGeneration: UInt64,
        eventGeneration: UInt64,
        activeToken: MeetingAVCaptureAttemptToken?,
        eventToken: MeetingAVCaptureAttemptToken,
        stopRequested: Bool
    ) -> Bool {
        !stopRequested
            && currentGeneration == eventGeneration
            && activeToken === eventToken
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

nonisolated enum MeetingCaptureSourceCatalog {
    static let preferredFallbackBundleIdentifiers = [
        "us.zoom.xos",
        "com.google.Chrome",
        "com.microsoft.teams2",
    ]

    /// Manual setup keeps Zoom/Chrome/Teams fallback. Auto-detect must capture the
    /// detected app or fail — never a different meeting.
    static func resolveApplication(
        from applications: [MeetingApplicationIdentity],
        preferredBundleIdentifier: String?,
        requirePreferredApplication: Bool
    ) throws -> MeetingApplicationIdentity {
        if requirePreferredApplication {
            guard let preferredBundleIdentifier else {
                throw MeetingCaptureError.applicationNotSelected
            }
            guard let match = applications.first(where: { $0.bundleIdentifier == preferredBundleIdentifier }) else {
                throw MeetingCaptureError.applicationUnavailable(preferredBundleIdentifier)
            }
            return match
        }

        let preferredBundleIdentifiers = [preferredBundleIdentifier].compactMap { $0 }
            + Self.preferredFallbackBundleIdentifiers
        if let application = preferredBundleIdentifiers.lazy.compactMap({ bundleIdentifier in
            applications.first(where: { $0.bundleIdentifier == bundleIdentifier })
        }).first ?? applications.first {
            return application
        }
        throw MeetingCaptureError.applicationNotSelected
    }

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

    static func microphoneSnapshot() async -> MeetingMicrophoneCatalogSnapshot {
        await AudioTopologyListenerExecution.perform {
            let identities = AudioDevice.listInputDevicesRefreshingLiveness().compactMap { device -> MeetingMicrophoneIdentity? in
                guard device.isAlive, device.uid.isEmpty == false else { return nil }
                return MeetingMicrophoneIdentity(
                    captureDeviceID: device.uid,
                    coreAudioUID: device.uid,
                    displayName: device.name
                )
            }
            return MeetingMicrophoneCatalogSnapshot(
                identities: identities,
                defaultCoreAudioUID: AudioDevice.getDefaultInputDevice()?.uid
            )
        }
    }

    static func availableMicrophones() async -> [MeetingMicrophoneIdentity] {
        await self.microphoneSnapshot().identities
    }

    static func defaultMicrophone(preferredCoreAudioUID: String? = nil) async throws -> MeetingMicrophoneIdentity {
        let snapshot = await self.microphoneSnapshot()
        let microphones = snapshot.identities
        if let preferredCoreAudioUID,
           let preferred = microphones.first(where: { $0.coreAudioUID == preferredCoreAudioUID })
        {
            return preferred
        }
        guard let defaultUID = snapshot.defaultCoreAudioUID,
              let microphone = microphones.first(where: { $0.coreAudioUID == defaultUID })
        else { throw MeetingCaptureError.microphoneUnavailable }
        return microphone
    }
}

nonisolated struct MeetingMicrophoneCatalogSnapshot: Sendable, Equatable {
    var identities: [MeetingMicrophoneIdentity]
    var defaultCoreAudioUID: String?
}

nonisolated struct MeetingAVCaptureDeviceDescriptor: Equatable, Sendable {
    var uniqueID: String
    var displayName: String
}

/// Pure, fail-closed bridge from FluidVoice's stable Core Audio selection identity
/// to the AVCaptureDevice unique ID required by ScreenCaptureKit/AVCaptureSession.
nonisolated enum MeetingAVCaptureDeviceSelection {
    static func select(
        microphone: MeetingMicrophoneIdentity,
        candidates: [MeetingAVCaptureDeviceDescriptor]
    ) -> String? {
        func exact(_ identifier: String?) -> String? {
            guard let identifier, !identifier.isEmpty else { return nil }
            return candidates.first(where: { $0.uniqueID == identifier })?.uniqueID
        }

        if let explicit = exact(microphone.avCaptureDeviceID) { return explicit }
        if microphone.identitySchemaVersion == nil,
           let legacy = exact(microphone.captureDeviceID)
        {
            return legacy
        }
        if let coreAudio = exact(microphone.coreAudioUID) { return coreAudio }

        let normalizedName = Self.normalize(microphone.displayName)
        guard !normalizedName.isEmpty else { return nil }
        let nameMatches = candidates.filter { Self.normalize($0.displayName) == normalizedName }
        guard nameMatches.count == 1 else { return nil }
        return nameMatches[0].uniqueID
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

/// AVFoundation discovery is intentionally isolated here. Callers are capture adapters
/// that run only after the ASR meeting lease has drained dictation audio ownership.
nonisolated enum MeetingAVCaptureMicrophoneResolver {
    static func resolve(_ microphone: MeetingMicrophoneIdentity) throws -> MeetingMicrophoneIdentity {
        #if DEBUG
        AudioTopologyDiagnostics.record(.avfDiscoveryBegin, owner: .meetingCatalog, queueRole: .actorControl, phase: .catalog)
        #endif
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        #if DEBUG
        AudioTopologyDiagnostics.record(.avfDiscoveryEnd, owner: .meetingCatalog, queueRole: .actorControl, phase: .catalog, status: Int32(clamping: devices.count))
        #endif
        let descriptors = devices.map {
            MeetingAVCaptureDeviceDescriptor(uniqueID: $0.uniqueID, displayName: $0.localizedName)
        }
        guard let uniqueID = MeetingAVCaptureDeviceSelection.select(
            microphone: microphone,
            candidates: descriptors
        ) else {
            throw MeetingCaptureError.microphoneUnavailable
        }
        var resolved = microphone
        resolved.avCaptureDeviceID = uniqueID
        return resolved
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

nonisolated enum MeetingCaptureTransitionPolicy {
    static let allowsWithinSessionVoiceProcessingUpgrade = true
    static let maximumRouteRecoveryAttempts = 3
    static let recoveryDwellSeconds: Double = 2

    static func shouldAttemptVoiceProcessingRecovery(
        routeDrivenFallback: Bool,
        attempts: Int,
        microphone: MeetingMicrophoneIdentity,
        outputRoute: MeetingOutputRouteSnapshot
    ) -> Bool {
        MeetingVoiceProcessingUpgradeDwell.shouldArm(
            phaseIsAVCapture: true,
            dwellAlreadyArmed: false,
            quarantined: false,
            stopRequested: false,
            routeDrivenFallback: routeDrivenFallback,
            attempts: attempts,
            microphone: microphone,
            outputRoute: outputRoute
        )
    }
}

nonisolated enum MeetingVoiceProcessingUpgradeDwell {
    static var seconds: Double { MeetingCaptureTransitionPolicy.recoveryDwellSeconds }

    static func shouldArm(
        phaseIsAVCapture: Bool,
        dwellAlreadyArmed: Bool,
        quarantined: Bool,
        stopRequested: Bool,
        routeDrivenFallback: Bool,
        attempts: Int,
        microphone: MeetingMicrophoneIdentity,
        outputRoute: MeetingOutputRouteSnapshot
    ) -> Bool {
        guard MeetingCaptureTransitionPolicy.allowsWithinSessionVoiceProcessingUpgrade,
              phaseIsAVCapture,
              !dwellAlreadyArmed,
              !quarantined,
              !stopRequested,
              routeDrivenFallback,
              attempts < MeetingCaptureTransitionPolicy.maximumRouteRecoveryAttempts
        else { return false }
        return MeetingCapturePathDecider.decide(
            mode: .onlineCall,
            microphone: microphone,
            outputRoute: outputRoute
        ) == .voiceProcessing
    }
}

nonisolated enum MeetingVoiceProcessingUpgradeOwnership {
    enum Step: Equatable {
        case cancelWatchdog
        case fenceAndQuiesce
        case stopRunning
        case removeObservers
        case removeDelegate
        case removeSessionIO
        case clearRuntimeRef
        case clearLocalRef
        case electAndDecide
        case parkCandidate
        case constructVoiceProcessing
        case startVoiceProcessing
        case awaitFirstBuffer
        case commit
        case startWatchdog
    }

    static let stopOldFirstSequence: [Step] = [
        .cancelWatchdog,
        .fenceAndQuiesce,
        .stopRunning,
        .removeObservers,
        .removeDelegate,
        .removeSessionIO,
        .clearRuntimeRef,
        .clearLocalRef,
        .electAndDecide,
        .constructVoiceProcessing,
        .parkCandidate,
        .startVoiceProcessing,
        .awaitFirstBuffer,
        .commit,
        .startWatchdog,
    ]

    static func mayConstructVoiceProcessing(
        avCaptureRuntimeRef: Bool,
        avCaptureLocalRef: Bool,
        avCaptureRunning: Bool,
        teardownProven: Bool
    ) -> Bool {
        !avCaptureRuntimeRef && !avCaptureLocalRef && !avCaptureRunning && teardownProven
    }

    static func mayPhaseAVCapture(hasComponent: Bool, componentStopped: Bool) -> Bool {
        hasComponent && !componentStopped
    }

    enum TeardownFailureAction: Equatable {
        case quarantineAndFail
    }

    static let actionIfTeardownUnproven = TeardownFailureAction.quarantineAndFail

    enum RollbackStep: Equatable {
        case stopAndReleaseVoiceProcessing
        case elect
        case recreateAVCapture
        case awaitFirstBuffer
        case commitAVCapture
    }

    static let rollbackSequence: [RollbackStep] = [
        .stopAndReleaseVoiceProcessing,
        .elect,
        .recreateAVCapture,
        .awaitFirstBuffer,
        .commitAVCapture,
    ]

    static let watchdogRunsDuringIntentionalGap = false
}

nonisolated enum MeetingVoiceProcessingUpgradeCommit {
    static let publishedCaptureMethod: MeetingAudioTrackCaptureMethod = .voiceProcessing
    static let discardsOverlappingSamples = false

    enum Stage: Equatable {
        case beginSplice
        case appendVoiceProcessingEra
        case setCaptureMethod
        case publishMethodChanged
        case awaitAck
        case flushRing
        case phaseVPIO
        case startWatchdog
    }

    static let orderedStages: [Stage] = [
        .beginSplice,
        .appendVoiceProcessingEra,
        .setCaptureMethod,
        .publishMethodChanged,
        .awaitAck,
        .flushRing,
        .phaseVPIO,
        .startWatchdog,
    ]
}

nonisolated enum MeetingCaptureRouteReplay {
    enum Backend: Equatable {
        case vpio
        case avCapture
    }

    static func shouldReplay(dirty: Bool, stopRequested: Bool, backend: Backend?) -> Bool {
        dirty && !stopRequested && backend != nil
    }

    enum Action: Equatable {
        case downgradeFromVPIO
        case rebindAVCapture
        case none
    }

    static func action(backend: Backend, outputRouteDeclineReason: String?) -> Action {
        switch backend {
        case .vpio:
            return outputRouteDeclineReason == nil ? .none : .downgradeFromVPIO
        case .avCapture:
            return .rebindAVCapture
        }
    }
}

nonisolated enum MeetingVoiceProcessingUpgradeAdmission {
    static func isCurrent(
        currentGeneration: UInt64,
        eventGeneration: UInt64,
        stopRequested: Bool,
        phaseIsTransitioning: Bool
    ) -> Bool {
        !stopRequested && currentGeneration == eventGeneration && phaseIsTransitioning
    }

    static func canCommit(
        currentGeneration: UInt64,
        eventGeneration: UInt64,
        stopRequested: Bool,
        phaseIsTransitioning: Bool
    ) -> Bool {
        self.isCurrent(
            currentGeneration: currentGeneration,
            eventGeneration: eventGeneration,
            stopRequested: stopRequested,
            phaseIsTransitioning: phaseIsTransitioning
        )
    }
}

/// Sticky means the safe AVCapture backend remains selected; it does not mean a
/// disconnected physical microphone remains selected.
nonisolated enum MeetingAVCaptureRebindDecision {
    static func shouldRebind(activeCoreAudioUID: String?, electedCoreAudioUID: String?, forced: Bool) -> Bool {
        if forced { return true }
        guard let electedCoreAudioUID, !electedCoreAudioUID.isEmpty else { return false }
        return activeCoreAudioUID != electedCoreAudioUID
    }
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
            configuration.microphoneCaptureDeviceID = microphone.avCaptureDeviceID
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

/// Re-evaluates meeting capture on default-input, default-output, or output data-source change.
/// Registration failure at init means VPIO is not viable — fail closed. Re-registers everything on
/// `kAudioHardwarePropertyServiceRestarted`, since CoreAudio discards all prior listeners on reset.
private actor MeetingOutputRouteListener {
    private enum Lifecycle: Equatable {
        case idle
        case starting
        case ready
    }

    private let onChange: @Sendable () -> Void
    private var generation: UInt64 = 0
    private var dataSourceEpoch: UInt64 = 0
    private var active = false
    private var lifecycle: Lifecycle = .idle
    private var defaultInputDirty = false
    private var defaultOutputDirty = false
    private var serviceRestartDirty = false
    private var defaultInputToken: AudioObjectPropertyListenerBlock?
    private var defaultOutputToken: AudioObjectPropertyListenerBlock?
    private var serviceRestartedToken: AudioObjectPropertyListenerBlock?
    private var dataSourceToken: AudioObjectPropertyListenerBlock?
    private var dataSourceDeviceID: AudioObjectID?

    private init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    static func make(onChange: @escaping @Sendable () -> Void) async -> MeetingOutputRouteListener? {
        let listener = MeetingOutputRouteListener(onChange: onChange)
        guard await listener.start() else { return nil }
        return listener
    }

    private func start() async -> Bool {
        guard !self.active else { return true }
        self.generation &+= 1
        let generation = self.generation
        self.active = true
        self.lifecycle = .starting
        self.defaultInputDirty = false
        self.defaultOutputDirty = false
        self.serviceRestartDirty = false
        guard await self.registerSystemListeners(generation: generation),
              await self.attachDataSourceListener(generation: generation)
        else {
            if self.isCurrent(generation) {
                await self.stop()
            }
            return false
        }
        return await self.finishStarting(generation: generation)
    }

    private func registerSystemListeners(generation: UInt64) async -> Bool {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let defaultInAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let restartedAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultInToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
            AudioTopologyDiagnostics.record(.callbackBegin, owner: .meetingOutputRoute, objectID: sys, selector: kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery)
            defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .meetingOutputRoute, objectID: sys, selector: kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery) }
            #endif
            MeetingMicrophoneEventExecution.afterHALCallback {
                Task { await self?.handleDefaultInputChanged(generation: generation) }
            }
        }
        let defaultOutToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
            AudioTopologyDiagnostics.record(.callbackBegin, owner: .meetingOutputRoute, objectID: sys, selector: kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery)
            defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .meetingOutputRoute, objectID: sys, selector: kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery) }
            #endif
            MeetingMicrophoneEventExecution.afterHALCallback {
                Task { await self?.handleDefaultOutputChanged(generation: generation) }
            }
        }
        let restartedToken: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
            AudioTopologyDiagnostics.record(.callbackBegin, owner: .meetingOutputRoute, objectID: sys, selector: kAudioHardwarePropertyServiceRestarted, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery)
            defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .meetingOutputRoute, objectID: sys, selector: kAudioHardwarePropertyServiceRestarted, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery) }
            #endif
            MeetingMicrophoneEventExecution.afterHALCallback {
                Task { await self?.handleServiceRestart(generation: generation) }
            }
        }
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .meetingOutputRoute, objectID: sys, selector: defaultInAddr.mSelector, scope: defaultInAddr.mScope, element: defaultInAddr.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let defaultInputStatus = await AudioTopologyListenerExecution.add(objectID: sys, address: defaultInAddr, token: defaultInToken)
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .meetingOutputRoute, objectID: sys, selector: defaultInAddr.mSelector, scope: defaultInAddr.mScope, element: defaultInAddr.mElement, queueRole: .dedicatedControl, phase: .listener, status: defaultInputStatus)
        #endif
        guard defaultInputStatus == noErr, self.isCurrent(generation) else {
            if defaultInputStatus == noErr {
                _ = await AudioTopologyListenerExecution.remove(objectID: sys, address: defaultInAddr, token: defaultInToken)
            }
            return false
        }
        self.defaultInputToken = defaultInToken
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .meetingOutputRoute, objectID: sys, selector: defaultOutAddr.mSelector, scope: defaultOutAddr.mScope, element: defaultOutAddr.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let defaultStatus = await AudioTopologyListenerExecution.add(objectID: sys, address: defaultOutAddr, token: defaultOutToken)
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .meetingOutputRoute, objectID: sys, selector: defaultOutAddr.mSelector, scope: defaultOutAddr.mScope, element: defaultOutAddr.mElement, queueRole: .dedicatedControl, phase: .listener, status: defaultStatus)
        #endif
        guard defaultStatus == noErr else {
            _ = await AudioTopologyListenerExecution.remove(objectID: sys, address: defaultInAddr, token: defaultInToken)
            if self.generation == generation { self.defaultInputToken = nil }
            return false
        }
        guard self.isCurrent(generation) else {
            _ = await AudioTopologyListenerExecution.remove(objectID: sys, address: defaultInAddr, token: defaultInToken)
            _ = await AudioTopologyListenerExecution.remove(objectID: sys, address: defaultOutAddr, token: defaultOutToken)
            return false
        }
        self.defaultOutputToken = defaultOutToken
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .meetingOutputRoute, objectID: sys, selector: restartedAddr.mSelector, scope: restartedAddr.mScope, element: restartedAddr.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let restartedStatus = await AudioTopologyListenerExecution.add(objectID: sys, address: restartedAddr, token: restartedToken)
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .meetingOutputRoute, objectID: sys, selector: restartedAddr.mSelector, scope: restartedAddr.mScope, element: restartedAddr.mElement, queueRole: .dedicatedControl, phase: .listener, status: restartedStatus)
        #endif
        guard restartedStatus == noErr, self.isCurrent(generation) else {
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .meetingOutputRoute, objectID: sys, selector: defaultOutAddr.mSelector, scope: defaultOutAddr.mScope, element: defaultOutAddr.mElement, queueRole: .dedicatedControl, phase: .listener)
            #endif
            let cleanupStatus = await AudioTopologyListenerExecution.remove(objectID: sys, address: defaultOutAddr, token: defaultOutToken)
            _ = await AudioTopologyListenerExecution.remove(objectID: sys, address: defaultInAddr, token: defaultInToken)
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .meetingOutputRoute, objectID: sys, selector: defaultOutAddr.mSelector, scope: defaultOutAddr.mScope, element: defaultOutAddr.mElement, queueRole: .dedicatedControl, phase: .listener, status: cleanupStatus)
            #endif
            if self.generation == generation {
                self.defaultInputToken = nil
                self.defaultOutputToken = nil
            }
            if restartedStatus == noErr {
                _ = await AudioTopologyListenerExecution.remove(objectID: sys, address: restartedAddr, token: restartedToken)
            }
            return false
        }
        self.serviceRestartedToken = restartedToken
        return true
    }

    private func handleDefaultInputChanged(generation: UInt64) {
        guard self.isCurrent(generation) else { return }
        guard self.lifecycle == .ready else {
            self.defaultInputDirty = true
            return
        }
        self.onChange()
    }

    private func attachDataSourceListener(generation: UInt64) async -> Bool {
        guard self.isCurrent(generation) else { return false }
        guard let device = AudioDevice.getDefaultOutputDevice() else { return false }
        self.dataSourceEpoch &+= 1
        let epoch = self.dataSourceEpoch
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let token: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            #if DEBUG
            AudioTopologyDiagnostics.record(.callbackBegin, owner: .meetingOutputRoute, objectID: device.id, selector: kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery)
            defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .meetingOutputRoute, objectID: device.id, selector: kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementMain, queueRole: .mainDelivery) }
            #endif
            MeetingMicrophoneEventExecution.afterHALCallback {
                Task { await self?.handleDataSourceChanged(generation: generation, epoch: epoch) }
            }
        }
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .meetingOutputRoute, objectID: device.id, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let status = await AudioTopologyListenerExecution.add(objectID: device.id, address: address, token: token)
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .meetingOutputRoute, objectID: device.id, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
        #endif
        guard status == noErr else { return false }
        guard self.isCurrent(generation), self.dataSourceEpoch == epoch else {
            _ = await AudioTopologyListenerExecution.remove(objectID: device.id, address: address, token: token)
            return false
        }
        self.dataSourceToken = token
        self.dataSourceDeviceID = device.id
        return true
    }

    private func detachDataSourceListener() async {
        self.dataSourceEpoch &+= 1
        guard let deviceID = self.dataSourceDeviceID, let token = self.dataSourceToken else { return }
        self.dataSourceToken = nil
        self.dataSourceDeviceID = nil
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .meetingOutputRoute, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener)
        #endif
        let status = await AudioTopologyListenerExecution.remove(objectID: deviceID, address: address, token: token)
        #if DEBUG
        AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .meetingOutputRoute, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
        #endif
    }

    private func handleDefaultOutputChanged(generation: UInt64) async {
        guard self.isCurrent(generation) else { return }
        guard self.lifecycle == .ready else {
            self.defaultOutputDirty = true
            return
        }
        await self.detachDataSourceListener()
        guard self.isCurrent(generation) else { return }
        _ = await self.attachDataSourceListener(generation: generation)
        guard self.isCurrent(generation) else { return }
        self.onChange()
    }

    private func handleDataSourceChanged(generation: UInt64, epoch: UInt64) {
        guard self.isCurrent(generation), self.dataSourceEpoch == epoch else { return }
        self.onChange()
    }

    private func handleServiceRestart(generation: UInt64) async {
        guard self.isCurrent(generation) else { return }
        guard self.lifecycle == .ready else {
            self.serviceRestartDirty = true
            return
        }
        let oldTokens = self.detachAll(invalidateLifecycle: true)
        let replacementGeneration = self.generation
        self.active = true
        self.lifecycle = .starting
        self.defaultInputDirty = false
        self.defaultOutputDirty = false
        self.serviceRestartDirty = false
        await Self.remove(tokens: oldTokens)
        guard self.isCurrent(replacementGeneration) else { return }
        guard await self.registerSystemListeners(generation: replacementGeneration),
              await self.attachDataSourceListener(generation: replacementGeneration)
        else {
            if self.isCurrent(replacementGeneration) {
                await self.stop()
            }
            self.onChange()
            return
        }
        if await self.finishStarting(generation: replacementGeneration),
           self.generation == replacementGeneration
        {
            self.onChange()
        }
    }

    /// Listener callbacks may arrive after HAL installs a token but before the async add
    /// continuation commits ownership. Latch those callbacks while starting, then replay only
    /// after all three tokens are owned. A service restart takes precedence over a route refresh.
    private func finishStarting(generation: UInt64) async -> Bool {
        guard self.isCurrent(generation), self.lifecycle == .starting else { return false }
        self.lifecycle = .ready
        let restartWasDirty = self.serviceRestartDirty
        let inputWasDirty = self.defaultInputDirty
        let defaultWasDirty = self.defaultOutputDirty
        self.serviceRestartDirty = false
        self.defaultInputDirty = false
        self.defaultOutputDirty = false
        if restartWasDirty {
            await self.handleServiceRestart(generation: generation)
            return self.active && self.lifecycle == .ready
        }
        if inputWasDirty {
            self.handleDefaultInputChanged(generation: generation)
        }
        if defaultWasDirty {
            await self.handleDefaultOutputChanged(generation: generation)
        }
        return self.active && self.lifecycle == .ready
    }

    func stop() async {
        guard self.active || self.defaultInputToken != nil || self.defaultOutputToken != nil || self.serviceRestartedToken != nil || self.dataSourceToken != nil else { return }
        let tokens = self.detachAll(invalidateLifecycle: true)
        self.lifecycle = .idle
        self.defaultInputDirty = false
        self.defaultOutputDirty = false
        self.serviceRestartDirty = false
        await Self.remove(tokens: tokens)
    }

    private struct Tokens: @unchecked Sendable {
        let defaultInput: AudioObjectPropertyListenerBlock?
        let defaultOutput: AudioObjectPropertyListenerBlock?
        let serviceRestarted: AudioObjectPropertyListenerBlock?
        let dataSource: AudioObjectPropertyListenerBlock?
        let dataSourceDeviceID: AudioObjectID?
    }

    private func detachAll(invalidateLifecycle: Bool) -> Tokens {
        if invalidateLifecycle {
            self.active = false
            self.generation &+= 1
        }
        self.dataSourceEpoch &+= 1
        let tokens = Tokens(
            defaultInput: self.defaultInputToken,
            defaultOutput: self.defaultOutputToken,
            serviceRestarted: self.serviceRestartedToken,
            dataSource: self.dataSourceToken,
            dataSourceDeviceID: self.dataSourceDeviceID
        )
        self.defaultInputToken = nil
        self.defaultOutputToken = nil
        self.serviceRestartedToken = nil
        self.dataSourceToken = nil
        self.dataSourceDeviceID = nil
        return tokens
    }

    private static func remove(tokens: Tokens) async {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let defaultInAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let restartedAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyServiceRestarted,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let token = tokens.defaultInput {
            let status = await AudioTopologyListenerExecution.remove(objectID: sys, address: defaultInAddr, token: token)
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .meetingOutputRoute, objectID: sys, selector: defaultInAddr.mSelector, scope: defaultInAddr.mScope, element: defaultInAddr.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
            #endif
        }
        if let token = tokens.defaultOutput {
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .meetingOutputRoute, objectID: sys, selector: defaultOutAddr.mSelector, scope: defaultOutAddr.mScope, element: defaultOutAddr.mElement, queueRole: .dedicatedControl, phase: .listener)
            #endif
            let status = await AudioTopologyListenerExecution.remove(objectID: sys, address: defaultOutAddr, token: token)
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .meetingOutputRoute, objectID: sys, selector: defaultOutAddr.mSelector, scope: defaultOutAddr.mScope, element: defaultOutAddr.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
            #endif
        }
        if let token = tokens.serviceRestarted {
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .meetingOutputRoute, objectID: sys, selector: restartedAddr.mSelector, scope: restartedAddr.mScope, element: restartedAddr.mElement, queueRole: .dedicatedControl, phase: .listener)
            #endif
            let status = await AudioTopologyListenerExecution.remove(objectID: sys, address: restartedAddr, token: token)
            #if DEBUG
            AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .meetingOutputRoute, objectID: sys, selector: restartedAddr.mSelector, scope: restartedAddr.mScope, element: restartedAddr.mElement, queueRole: .dedicatedControl, phase: .listener, status: status)
            #endif
        }
        if let token = tokens.dataSource, let deviceID = tokens.dataSourceDeviceID {
            let address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = await AudioTopologyListenerExecution.remove(objectID: deviceID, address: address, token: token)
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        self.active && self.generation == generation
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

    static func elect(original: MeetingMicrophoneIdentity) async -> MeetingCaptureDeviceElection {
        let snapshot = await MeetingCaptureSourceCatalog.microphoneSnapshot()
        return Self.decide(
            original: original,
            catalog: snapshot.identities,
            defaultInputUID: snapshot.defaultCoreAudioUID
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
        let isSamePhysicalDevice = {
            if let originalUID = original.coreAudioUID, !originalUID.isEmpty,
               let matchedUID = matched.coreAudioUID, !matchedUID.isEmpty
            {
                return originalUID == matchedUID
            }
            return matched.captureDeviceID == original.captureDeviceID
        }()
        if isSamePhysicalDevice {
            var merged = matched
            merged.role = original.role
            merged.avCaptureDeviceID = original.avCaptureDeviceID
                ?? (original.identitySchemaVersion == nil ? original.captureDeviceID : nil)
            return MeetingCaptureDeviceElection(identity: merged, role: original.role)
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

/// Owns a swappable mic component (VPIO or AVCaptureSession) plus an app-audio-only SCStream that never stops across a swap.
private final nonisolated class VoiceProcessingMeetingRuntime: MeetingCaptureRuntime, @unchecked Sendable {
    private static let totalStartDeadlineSeconds: Double = 10
    private static let firstBufferDeadlineSeconds: Double = 2
    private static let downgradeSettleSeconds: Double = 0.75

    private enum Phase: Equatable {
        case starting
        case vpio
        case transitioning
        case committing
        case avCapture
        case failed
    }

    private enum DowngradeCommitDecision {
        case committed
        case stale
        case failed(String)
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
    private var transitionGeneration: UInt64 = 0
    private var pendingAVCaptureFailure: (generation: UInt64, detail: String)?
    private var avCaptureFailureToken: MeetingAVCaptureAttemptToken?
    private var routeChangeDirty = false
    private var stopRequested = false
    private var routeDrivenFallback = false
    private var voiceProcessingRecoveryAttempts = 0
    private var recoveryDwellTask: Task<Void, Never>?
    /// Parked before `start()` so stop/supersede can never lose ownership of it.
    private var pendingVoiceProcessingCapture: MeetingMicrophoneCapture?
    private var quarantined = false

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

    #if DEBUG
    deinit {
        AudioTopologyDiagnostics.record(.ownerWillDeinit, owner: .meetingCaptureEngine, queueRole: .callbackCurrent, phase: .runtimeStop)
    }
    #endif

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
            await staleListener?.stop()
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
        await self.startOutputRouteWatch()
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

    private func waitForBufferProgress(
        timeoutSeconds: Double,
        using component: MeetingAVCaptureMicrophoneComponent
    ) async -> Bool {
        let baseline = component.sampleCount()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if component.sampleCount() > baseline { return true }
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

    private func startAVCaptureWatchdog(
        generation: UInt64,
        component: MeetingAVCaptureMicrophoneComponent
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            var lastCount = component.sampleCount()
            var lastProgress = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                let stillOwnsComponent = self.stateLock.withLock {
                    self.phase == .avCapture
                        && self.transitionGeneration == generation
                        && self.avCaptureComponent === component
                }
                guard stillOwnsComponent else { return }
                let current = component.sampleCount()
                if current != lastCount {
                    lastCount = current
                    lastProgress = Date()
                    continue
                }
                if MeetingVoiceProcessingWatchdog.isStalled(
                    secondsSinceLastEmittedBuffer: Date().timeIntervalSince(lastProgress)
                ) {
                    self.beginAVCaptureRebind(
                        detail: "The active microphone stopped delivering audio buffers.",
                        forced: true
                    )
                    return
                }
            }
        }
        self.stateLock.withLock { self.watchdogTask = task }
    }

    /// Registered once: `handleRouteChange()` re-reads `phase` on every fire, so it never needs re-arming.
    private func startOutputRouteWatch() async {
        let listener = await MeetingOutputRouteListener.make { [weak self] in
            self?.handleRouteChange()
        }
        let retained = self.stateLock.withLock { () -> Bool in
            guard !self.stopRequested else { return false }
            self.outputRouteListener = listener
            return true
        }
        if !retained {
            await listener?.stop()
        }
    }

    private func handleRouteChange() {
        enum Action { case evaluateVPIO, evaluateAVCapture, none }
        let action = self.stateLock.withLock { () -> Action in
            switch self.phase {
            case .vpio:
                return .evaluateVPIO
            case .avCapture:
                // Claim the observation before releasing the lock. If recovery wins
                // the next lock acquisition, finishTransition() will replay it
                // against whichever backend commits.
                self.routeChangeDirty = true
                return .evaluateAVCapture
            case .transitioning, .committing:
                self.routeChangeDirty = true
                return .none
            case .starting, .failed:
                return .none
            }
        }
        switch action {
        case .evaluateVPIO:
            let reason = MeetingCapturePathDecider.outputRouteDeclineReason(MeetingCaptureEngine.currentOutputRouteSnapshot())
            if let reason {
                self.beginDowngradeTransition(
                    reason: "Output route changed: \(reason)",
                    routeDriven: true
                )
            }
        case .evaluateAVCapture:
            // The backend stays sticky, but the physical input must follow the live
            // system default when a headset is attached or removed.
            self.beginAVCaptureRebind(
                detail: "The default microphone route changed.",
                forced: false
            )
        case .none:
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
                self.beginDowngradeTransition(
                    reason: "The default input device changed away from the requested microphone.",
                    routeDriven: true
                )
            }
        case .overload:
            self.eventHandler(.interrupted(kind: .voiceProcessingOverload, trackID: nil, detail: "Voice-processing microphone reported an overload."))
        case .engineStopped:
            self.beginDowngradeTransition(reason: "The voice-processing microphone engine stopped unexpectedly.")
        }
    }

    private func handleAVCaptureFailureSignal(
        detail: String,
        generation: UInt64,
        token: MeetingAVCaptureAttemptToken
    ) {
        let shouldEmit = self.stateLock.withLock { () -> Bool in
            guard MeetingAVCaptureFailureAdmission.accepts(
                currentGeneration: self.transitionGeneration,
                eventGeneration: generation,
                activeToken: self.avCaptureFailureToken,
                eventToken: token,
                stopRequested: self.stopRequested
            ) else { return false }
            switch self.phase {
            case .transitioning, .committing:
                if self.pendingAVCaptureFailure == nil {
                    self.pendingAVCaptureFailure = (generation, detail)
                }
                return false
            case .avCapture:
                guard !self.interruptedThisEra else { return false }
                self.interruptedThisEra = true
                self.phase = .failed
                return true
            case .starting, .vpio, .failed:
                return false
            }
        }
        guard shouldEmit else { return }
        self.eventHandler(.interrupted(kind: .captureStoppedUnexpectedly, trackID: nil, detail: detail))
    }

    private func invalidateAVCaptureFailureToken(
        _ token: MeetingAVCaptureAttemptToken,
        generation: UInt64
    ) {
        self.stateLock.withLock {
            guard self.transitionGeneration == generation,
                  self.avCaptureFailureToken === token
            else { return }
            self.avCaptureFailureToken = nil
            if self.pendingAVCaptureFailure?.generation == generation {
                self.pendingAVCaptureFailure = nil
            }
        }
    }

    private func beginDowngradeTransition(reason: String, routeDriven: Bool = false) {
        self.beginDowngradeTransition(detail: reason, routeDriven: routeDriven)
    }

    private func beginDowngradeTransition(detail: String, routeDriven: Bool = false) {
        let watchdog = self.stateLock.withLock { () -> Task<Void, Never>? in
            guard self.phase == .vpio, !self.stopRequested else { return nil }
            self.phase = .transitioning
            self.transitionGeneration &+= 1
            let generation = self.transitionGeneration
            self.pendingAVCaptureFailure = nil
            self.routeChangeDirty = false
            self.routeDrivenFallback = routeDriven
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runDowngrade(detail: detail, generation: generation)
            }
            self.transitionTask = task
            defer { self.watchdogTask = nil }
            return self.watchdogTask
        }
        watchdog?.cancel()
    }

    private func runDowngrade(detail: String, generation: UInt64) async {
        try? await Task.sleep(nanoseconds: UInt64(Self.downgradeSettleSeconds * 1_000_000_000))
        guard self.ownsDowngradeTransition(generation) else {
            self.finishTransition(generation)
            return
        }

        let oldFence = self.stateLock.withLock { self.currentFence }
        var oldMicCapture: MeetingMicrophoneCapture? = self.stateLock.withLock { self.micCapture }
        await oldFence.quiesce()
        let statsSnapshot = await oldMicCapture!.statistics()
        let drift = MeetingClockDriftRecord(
            cumulativeAbsorbedSeconds: statsSnapshot.cumulativeAbsorbedCorrectionSeconds,
            elapsedValidHostSeconds: MeetingVoiceProcessingDriftSnapshot.elapsedValidHostSeconds(statsSnapshot),
            eligible: MeetingVoiceProcessingDriftSnapshot.isEligible(statsSnapshot)
        )
        // Hard lifetime barrier: VPIO, its tap, and its Core Audio listeners must be
        // completely gone before any AVFoundation discovery/session construction.
        await oldMicCapture!.stop()
        self.stateLock.withLock {
            if self.micCapture === oldMicCapture {
                self.micCapture = MeetingMicrophoneCapture()
            }
        }
        oldMicCapture = nil

        guard self.ownsDowngradeTransition(generation) else {
            self.finishTransition(generation)
            return
        }

        let elected = await MeetingCaptureDeviceElection.elect(original: self.originalMicrophone)
        guard self.ownsDowngradeTransition(generation) else {
            self.finishTransition(generation)
            return
        }
        let newFence = MeetingEraAcceptanceFence()
        let newGate = MeetingVoiceProcessingCommitGate()
        let microphoneWriter = self.microphoneWriter
        let liveAudioHandler = self.liveAudioHandler
        let failureToken = MeetingAVCaptureAttemptToken()
        guard self.stateLock.withLock({ () -> Bool in
            guard self.phase == .transitioning,
                  self.transitionGeneration == generation,
                  !self.stopRequested
            else { return false }
            self.avCaptureFailureToken = failureToken
            return true
        }) else {
            self.finishTransition(generation)
            return
        }
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
                    self?.handleAVCaptureFailureSignal(
                        detail: detail,
                        generation: generation,
                        token: failureToken
                    )
                }
            )
        } catch {
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            self.failPendingDowngrade(
                generation: generation,
                detail: "Microphone unavailable after a route change: \(error.localizedDescription)"
            )
            self.finishTransition(generation)
            return
        }

        do {
            try await component.start()
        } catch {
            // `stop()` is a true control-queue barrier: if startRunning was still
            // executing, retirement cannot finish (or release the meeting lease)
            // until it returns and stopRunning has run behind it.
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            try? await component.stop()
            self.failPendingDowngrade(
                generation: generation,
                detail: "Microphone unavailable after a route change: \(error.localizedDescription)"
            )
            self.finishTransition(generation)
            return
        }

        guard await self.waitForBufferProgress(
            timeoutSeconds: Self.firstBufferDeadlineSeconds,
            using: component
        ) else {
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            try? await component.stop()
            self.failPendingDowngrade(
                generation: generation,
                detail: "The replacement microphone started but delivered no audio buffers."
            )
            self.finishTransition(generation)
            return
        }

        // Promote the bounded gate before the runtime's point of no return. If its
        // cap was exhausted while AVCapture started, fail with no era/event side
        // effects. Once promoted, arrivals are retained uncapped and in order
        // while metadata and the coordinator acknowledgement complete.
        guard var pendingBatch = newGate.beginCommitFlush() else {
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            try? await component.stop()
            self.failPendingDowngrade(
                generation: generation,
                detail: "Microphone buffering overflowed before the route-change handoff could commit."
            )
            self.finishTransition(generation)
            return
        }

        // Point of no return. Before this lock succeeds, stop may cancel the
        // transition with no published method/era. After it succeeds, stop waits
        // for the complete metadata -> acknowledgement -> gate-flush transaction.
        let commitDecision = self.stateLock.withLock { () -> DowngradeCommitDecision in
            guard self.phase == .transitioning,
                  self.transitionGeneration == generation,
                  !self.stopRequested
            else { return .stale }
            if let failure = self.pendingAVCaptureFailure, failure.generation == generation {
                self.pendingAVCaptureFailure = nil
                self.phase = .failed
                return .failed(failure.detail)
            }
            self.currentFence = newFence
            self.avCaptureComponent = component
            self.phase = .committing
            self.interruptedThisEra = false
            return .committed
        }
        switch commitDecision {
        case .stale:
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            try? await component.stop()
            self.finishTransition(generation)
            return
        case let .failed(failureDetail):
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            try? await component.stop()
            self.eventHandler(.interrupted(
                kind: .captureStoppedUnexpectedly, trackID: nil, detail: failureDetail
            ))
            self.finishTransition(generation)
            return
        case .committed:
            break
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

        // Ack before flushing: readers must re-arm before any post-boundary sample reaches them.
        let ack = MeetingCaptureMethodChangeAck()
        self.eventHandler(.captureMethodChanged(trackID: self.microphoneWriter.trackID, method: .avCaptureSession, ack: ack))
        await ack.wait()

        while true {
            await self.flushBatch(pendingBatch)
            guard let next = newGate.continueCommitFlush() else { break }
            pendingBatch = next
        }

        let terminalFailure = self.stateLock.withLock { () -> String? in
            guard self.phase == .committing, self.transitionGeneration == generation else { return nil }
            if let failure = self.pendingAVCaptureFailure, failure.generation == generation {
                self.pendingAVCaptureFailure = nil
                self.interruptedThisEra = true
                self.phase = .failed
                return failure.detail
            }
            self.phase = .avCapture
            return nil
        }
        if let terminalFailure {
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            self.eventHandler(.interrupted(
                kind: .captureStoppedUnexpectedly, trackID: nil, detail: terminalFailure
            ))
        } else {
            self.startAVCaptureWatchdog(generation: generation, component: component)
        }

        self.finishTransition(generation)
        if terminalFailure == nil { self.armSafeVoiceProcessingRecoveryIfViable() }
    }

    private func beginAVCaptureRebind(detail: String, forced: Bool) {
        let watchdog = self.stateLock.withLock { () -> Task<Void, Never>? in
            guard self.phase == .avCapture,
                  self.avCaptureComponent != nil,
                  !self.stopRequested
            else { return nil }
            let previousGeneration = self.transitionGeneration
            self.phase = .transitioning
            self.transitionGeneration &+= 1
            let generation = self.transitionGeneration
            self.pendingAVCaptureFailure = nil
            self.routeChangeDirty = false
            if forced { self.routeDrivenFallback = false }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runAVCaptureRebind(
                    detail: detail,
                    forced: forced,
                    generation: generation,
                    previousGeneration: previousGeneration
                )
            }
            self.transitionTask = task
            defer { self.watchdogTask = nil }
            return self.watchdogTask
        }
        watchdog?.cancel()
    }

    private func runAVCaptureRebind(
        detail: String,
        forced: Bool,
        generation: UInt64,
        previousGeneration: UInt64
    ) async {
        try? await Task.sleep(nanoseconds: UInt64(Self.downgradeSettleSeconds * 1_000_000_000))
        guard self.ownsDowngradeTransition(generation),
              let oldComponent = self.stateLock.withLock({ self.avCaptureComponent })
        else {
            self.finishTransition(generation)
            return
        }

        // The settle window coalesces everything observed so far. Clear the dirty
        // bit immediately before the snapshot so only changes racing the snapshot
        // or the subsequent handoff need a replay.
        let readyToSnapshot = self.stateLock.withLock { () -> Bool in
            guard self.phase == .transitioning,
                  self.transitionGeneration == generation,
                  !self.stopRequested
            else { return false }
            self.routeChangeDirty = false
            return true
        }
        guard readyToSnapshot else {
            self.finishTransition(generation)
            return
        }
        let elected = await MeetingCaptureDeviceElection.elect(original: self.originalMicrophone)
        guard self.ownsDowngradeTransition(generation) else {
            self.finishTransition(generation)
            return
        }

        guard MeetingAVCaptureRebindDecision.shouldRebind(
            activeCoreAudioUID: oldComponent.deviceUID,
            electedCoreAudioUID: elected.identity.coreAudioUID,
            forced: forced
        ) else {
            let restored = self.stateLock.withLock { () -> (restored: Bool, replay: Bool) in
                guard self.phase == .transitioning,
                      self.transitionGeneration == generation,
                      !self.stopRequested,
                      self.avCaptureComponent === oldComponent
                else { return (false, false) }
                let replay = self.routeChangeDirty
                self.phase = .avCapture
                self.transitionGeneration = previousGeneration
                self.routeChangeDirty = false
                self.transitionTask = nil
                return (true, replay)
            }
            if restored.restored {
                self.startAVCaptureWatchdog(generation: previousGeneration, component: oldComponent)
                if restored.replay { self.handleRouteChange() }
                self.armSafeVoiceProcessingRecoveryIfViable()
            }
            return
        }

        DebugLogger.shared.log(
            "Meeting AVCapture input rebind: \(oldComponent.deviceName) -> \(elected.identity.displayName) (\(detail))",
            source: "MeetingCaptureEngine"
        )

        // This is the same ownership invariant as the VPIO downgrade: retire the
        // old producer completely before AVFoundation discovers or starts another.
        let oldFence = self.stateLock.withLock { self.currentFence }
        await oldFence.quiesce()
        try? await oldComponent.stop()

        guard self.ownsDowngradeTransition(generation) else {
            self.finishTransition(generation)
            return
        }

        let microphoneWriter = self.microphoneWriter
        let liveAudioHandler = self.liveAudioHandler
        var selectedElection: MeetingCaptureDeviceElection?
        var selectedFence: MeetingEraAcceptanceFence?
        var selectedGate: MeetingVoiceProcessingCommitGate?
        var selectedComponent: MeetingAVCaptureMicrophoneComponent?
        var selectedFailureToken: MeetingAVCaptureAttemptToken?
        var lastCandidateFailure = "The replacement microphone was unavailable."

        // CoreAudio and AVFoundation do not settle atomically during Bluetooth
        // removal. Re-elect once after a bounded delay instead of permanently
        // failing the meeting on a transient catalog mismatch.
        for (attempt, retryDelay) in [0.0, 0.75].enumerated() {
            if retryDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
            guard self.ownsDowngradeTransition(generation) else {
                self.finishTransition(generation)
                return
            }
            let candidateElection = attempt == 0
                ? elected
                : await MeetingCaptureDeviceElection.elect(original: self.originalMicrophone)
            guard self.ownsDowngradeTransition(generation) else {
                self.finishTransition(generation)
                return
            }
            self.stateLock.withLock {
                if self.transitionGeneration == generation { self.pendingAVCaptureFailure = nil }
            }

            let candidateFence = MeetingEraAcceptanceFence()
            let candidateGate = MeetingVoiceProcessingCommitGate()
            let failureToken = MeetingAVCaptureAttemptToken()
            let tokenInstalled = self.stateLock.withLock { () -> Bool in
                guard self.phase == .transitioning,
                      self.transitionGeneration == generation,
                      !self.stopRequested
                else { return false }
                self.avCaptureFailureToken = failureToken
                return true
            }
            guard tokenInstalled else {
                self.finishTransition(generation)
                return
            }
            let candidate: MeetingAVCaptureMicrophoneComponent
            do {
                candidate = try MeetingAVCaptureMicrophoneComponent(
                    microphone: candidateElection.identity,
                    onSample: { sample in
                        guard candidateFence.beginSample() else { return }
                        defer { candidateFence.endSample() }
                        switch candidateGate.offer(sample) {
                        case .passthrough:
                            microphoneWriter.enqueue(sample)
                            liveAudioHandler?(.microphone, sample)
                        case .buffered, .aborted:
                            break
                        }
                    },
                    onTerminalStop: { [weak self] failure in
                        self?.handleAVCaptureFailureSignal(
                            detail: failure,
                            generation: generation,
                            token: failureToken
                        )
                    }
                )
            } catch {
                self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
                lastCandidateFailure = error.localizedDescription
                continue
            }

            do {
                try await candidate.start()
            } catch {
                // Even a failed start is retired through the same serialized
                // barrier before another candidate is constructed.
                self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
                try? await candidate.stop()
                lastCandidateFailure = error.localizedDescription
                continue
            }

            guard await self.waitForBufferProgress(
                timeoutSeconds: Self.firstBufferDeadlineSeconds,
                using: candidate
            ) else {
                self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
                try? await candidate.stop()
                lastCandidateFailure = "The microphone started but delivered no audio buffers."
                continue
            }

            let candidateFailed = self.stateLock.withLock {
                self.pendingAVCaptureFailure?.generation == generation
            }
            if candidateFailed {
                lastCandidateFailure = self.stateLock.withLock {
                    self.pendingAVCaptureFailure?.detail ?? "The microphone stopped before commit."
                }
                self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
                try? await candidate.stop()
                continue
            }

            selectedElection = candidateElection
            selectedFence = candidateFence
            selectedGate = candidateGate
            selectedComponent = candidate
            selectedFailureToken = failureToken
            break
        }

        guard let elected = selectedElection,
              let newFence = selectedFence,
              let newGate = selectedGate,
              let component = selectedComponent,
              let failureToken = selectedFailureToken
        else {
            self.failPendingDowngrade(
                generation: generation,
                detail: "Microphone rebind failed after retry: \(lastCandidateFailure)"
            )
            self.finishTransition(generation)
            return
        }

        guard var pendingBatch = newGate.beginCommitFlush() else {
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            try? await component.stop()
            self.failPendingDowngrade(
                generation: generation,
                detail: "Microphone buffering overflowed before the input rebind could commit."
            )
            self.finishTransition(generation)
            return
        }

        let commitDecision = self.stateLock.withLock { () -> DowngradeCommitDecision in
            guard self.phase == .transitioning,
                  self.transitionGeneration == generation,
                  !self.stopRequested,
                  self.avCaptureComponent === oldComponent,
                  self.avCaptureFailureToken === failureToken
            else { return .stale }
            if let failure = self.pendingAVCaptureFailure, failure.generation == generation {
                self.pendingAVCaptureFailure = nil
                self.phase = .failed
                return .failed(failure.detail)
            }
            self.currentFence = newFence
            self.avCaptureComponent = component
            self.phase = .committing
            self.interruptedThisEra = false
            return .committed
        }
        switch commitDecision {
        case .stale:
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            try? await component.stop()
            self.finishTransition(generation)
            return
        case let .failed(failureDetail):
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            try? await component.stop()
            self.eventHandler(.interrupted(
                kind: .captureStoppedUnexpectedly, trackID: nil, detail: failureDetail
            ))
            self.finishTransition(generation)
            return
        case .committed:
            break
        }

        let boundary = await self.microphoneWriter.beginSplice()
        do {
            try await self.microphoneWriter.updateTrackMetadata { track in
                var eras = track.captureEras ?? [self.legacyEra(from: track)]
                if let boundary, boundary.seconds > (eras.last?.startSeconds ?? -.infinity) {
                    eras.append(MeetingCaptureEra(
                        method: .avCaptureSession,
                        deviceUID: elected.identity.coreAudioUID,
                        deviceName: elected.identity.displayName,
                        roleAtElection: elected.role,
                        startSeconds: boundary.seconds
                    ))
                }
                track.captureEras = eras
                track.captureMethod = .avCaptureSession
            }
        } catch {
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            await newFence.quiesce()
            try? await component.stop()
            let shouldEmit = self.stateLock.withLock { () -> Bool in
                guard self.phase == .committing, self.transitionGeneration == generation else { return false }
                self.phase = .failed
                self.interruptedThisEra = true
                return true
            }
            if shouldEmit {
                self.eventHandler(.interrupted(
                    kind: .captureStoppedUnexpectedly,
                    trackID: nil,
                    detail: "Could not persist the microphone rebind: \(error.localizedDescription)"
                ))
            }
            self.finishTransition(generation)
            return
        }

        // Re-arm live microphone segmentation before any sample from the new
        // physical source is released, even though the backend method is unchanged.
        let ack = MeetingCaptureMethodChangeAck()
        self.eventHandler(.captureMethodChanged(
            trackID: self.microphoneWriter.trackID,
            method: .avCaptureSession,
            ack: ack
        ))
        await ack.wait()

        while true {
            await self.flushBatch(pendingBatch)
            guard let next = newGate.continueCommitFlush() else { break }
            pendingBatch = next
        }

        let terminalFailure = self.stateLock.withLock { () -> String? in
            guard self.phase == .committing, self.transitionGeneration == generation else { return nil }
            if let failure = self.pendingAVCaptureFailure, failure.generation == generation {
                self.pendingAVCaptureFailure = nil
                self.interruptedThisEra = true
                self.phase = .failed
                return failure.detail
            }
            self.phase = .avCapture
            return nil
        }
        if let terminalFailure {
            self.invalidateAVCaptureFailureToken(failureToken, generation: generation)
            self.eventHandler(.interrupted(
                kind: .captureStoppedUnexpectedly, trackID: nil, detail: terminalFailure
            ))
        } else {
            self.startAVCaptureWatchdog(generation: generation, component: component)
        }
        self.finishTransition(generation)
        if terminalFailure == nil { self.armSafeVoiceProcessingRecoveryIfViable() }
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

    #if false
    // Retained only as source history during the transition rollout. Compiled out so
    // an AVCapture fallback cannot create a second VPIO owner in this meeting.
    /// `dwellArming` reserves the slot in the SAME critical section as the `dwellTask == nil` check.
    private func armUpgradeDwellIfViable() {
        guard MeetingCaptureTransitionPolicy.allowsWithinSessionVoiceProcessingUpgrade else { return }
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

        let elected = await MeetingCaptureDeviceElection.elect(original: self.originalMicrophone)
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
        // Sticky fallback intentionally does not schedule another VPIO owner.
    }

    private func drainAbortedCaptures() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.abortedCaptureDrain.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }
    }
    #endif

    // MARK: - Stop-first AVCapture -> VPIO recovery

    private func armSafeVoiceProcessingRecoveryIfViable() {
        let outputRoute = MeetingCaptureEngine.currentOutputRouteSnapshot()
        let task = self.stateLock.withLock { () -> Task<Void, Never>? in
            guard self.phase == .avCapture,
                  self.avCaptureComponent != nil,
                  self.recoveryDwellTask == nil,
                  !self.stopRequested,
                  !self.quarantined,
                  MeetingCaptureTransitionPolicy.shouldAttemptVoiceProcessingRecovery(
                      routeDrivenFallback: self.routeDrivenFallback,
                      attempts: self.voiceProcessingRecoveryAttempts,
                      microphone: self.originalMicrophone,
                      outputRoute: outputRoute
                  )
            else { return nil }
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(
                    MeetingVoiceProcessingUpgradeDwell.seconds * 1_000_000_000
                ))
                guard let self, !Task.isCancelled else { return }
                await self.beginSafeVoiceProcessingRecovery()
            }
            self.recoveryDwellTask = task
            return task
        }
        _ = task // retained by runtime; silence the intentional local discard
    }

    private func beginSafeVoiceProcessingRecovery() async {
        let elected = await MeetingCaptureDeviceElection.elect(original: self.originalMicrophone)
        let outputRoute = MeetingCaptureEngine.currentOutputRouteSnapshot()
        let started = self.stateLock.withLock { () -> Bool in
            self.recoveryDwellTask = nil
            guard self.phase == .avCapture,
                  self.avCaptureComponent != nil,
                  !self.stopRequested,
                  !self.quarantined,
                  MeetingCaptureTransitionPolicy.shouldAttemptVoiceProcessingRecovery(
                      routeDrivenFallback: self.routeDrivenFallback,
                      attempts: self.voiceProcessingRecoveryAttempts,
                      microphone: elected.identity,
                      outputRoute: outputRoute
                  )
            else { return false }
            self.phase = .transitioning
            self.transitionGeneration &+= 1
            let generation = self.transitionGeneration
            self.voiceProcessingRecoveryAttempts += 1
            self.routeChangeDirty = false
            self.pendingAVCaptureFailure = nil
            self.avCaptureFailureToken = nil
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runSafeVoiceProcessingRecovery(generation: generation)
            }
            self.transitionTask = task
            return true
        }
        if started {
            let watchdog = self.stateLock.withLock { () -> Task<Void, Never>? in
                defer { self.watchdogTask = nil }
                return self.watchdogTask
            }
            watchdog?.cancel()
        }
    }

    private func ownsSafeRecovery(_ generation: UInt64) -> Bool {
        self.stateLock.withLock {
            (self.phase == .transitioning || self.phase == .committing)
                && self.transitionGeneration == generation
                && !self.stopRequested
        }
    }

    private func runSafeVoiceProcessingRecovery(generation: UInt64) async {
        guard self.ownsSafeRecovery(generation) else {
            self.finishTransition(generation)
            return
        }

        let oldFence = self.stateLock.withLock { self.currentFence }
        var retiringComponent = self.stateLock.withLock { self.avCaptureComponent }
        guard retiringComponent != nil else {
            self.failPendingDowngrade(
                generation: generation,
                detail: "Voice-processing recovery had no active fallback microphone to retire."
            )
            self.finishTransition(generation)
            return
        }

        await oldFence.quiesce()
        do {
            try await retiringComponent?.stop()
        } catch {
            self.failSafeRecovery(
                generation: generation,
                detail: "Could not retire fallback microphone capture: \(error.localizedDescription)"
            )
            self.finishTransition(generation)
            return
        }
        guard retiringComponent?.isFullyRetired() == true else {
            self.failSafeRecovery(
                generation: generation,
                detail: "Fallback microphone teardown could not be proven; recovery was quarantined."
            )
            self.finishTransition(generation)
            return
        }

        // Remove every runtime strong reference, then drop the final local reference.
        // `MeetingAVCaptureMicrophoneComponent.stop()` has already dismantled the
        // session graph and removed observers on its serialized control queue.
        let cleared = self.stateLock.withLock { () -> Bool in
            guard self.phase == .transitioning,
                  self.transitionGeneration == generation,
                  self.avCaptureComponent === retiringComponent
            else { return false }
            self.avCaptureComponent = nil
            self.avCaptureFailureToken = nil
            self.pendingAVCaptureFailure = nil
            return true
        }
        retiringComponent = nil
        guard cleared, self.ownsSafeRecovery(generation) else {
            self.finishTransition(generation)
            return
        }

        let boundary = await self.microphoneWriter.beginSplice()
        guard self.ownsSafeRecovery(generation) else {
            self.finishTransition(generation)
            return
        }

        // Re-elect only after AVFoundation has released the old physical device.
        let elected = await MeetingCaptureDeviceElection.elect(original: self.originalMicrophone)
        guard self.ownsSafeRecovery(generation),
              MeetingCapturePathDecider.decide(
                  mode: .onlineCall,
                  microphone: elected.identity,
                  outputRoute: MeetingCaptureEngine.currentOutputRouteSnapshot()
              ) == .voiceProcessing
        else {
            await self.restoreAVCaptureAfterRecoveryFailure(
                generation: generation,
                boundary: boundary,
                detail: "The audio route changed before voice processing could restart."
            )
            return
        }

        // Optional by design: every rollback path explicitly drops the final local
        // reference after stop() and before constructing a fresh AVCaptureSession.
        var candidate: MeetingMicrophoneCapture? = MeetingMicrophoneCapture()
        let candidateGate = MeetingVoiceProcessingCommitGate()
        let candidateFence = MeetingEraAcceptanceFence()
        let microphoneWriter = self.microphoneWriter
        let liveAudioHandler = self.liveAudioHandler
        let parked = self.stateLock.withLock { () -> Bool in
            guard self.phase == .transitioning,
                  self.transitionGeneration == generation,
                  !self.stopRequested,
                  self.avCaptureComponent == nil
            else { return false }
            guard let candidate else { return false }
            self.pendingVoiceProcessingCapture = candidate
            self.micCapture = candidate
            return true
        }
        guard parked else {
            await candidate?.stop()
            candidate = nil
            self.finishTransition(generation)
            return
        }

        let outcome: MeetingMicrophoneBindingOutcome
        do {
            outcome = try await candidate!.start(
                microphone: elected.identity,
                authorizationPreflighted: true,
                onSample: { sample in
                    guard candidateFence.beginSample() else { return }
                    defer { candidateFence.endSample() }
                    switch candidateGate.offer(sample) {
                    case .passthrough:
                        microphoneWriter.enqueue(sample)
                        liveAudioHandler?(.microphone, sample)
                    case .buffered, .aborted:
                        break
                    }
                },
                onEvent: { [weak self, weak candidate] event in
                    guard let candidate else { return }
                    self?.handleMicEvent(event, owner: candidate)
                }
            )
        } catch {
            await self.retirePendingVoiceProcessingCapture(generation: generation)
            candidate = nil
            await self.restoreAVCaptureAfterRecoveryFailure(
                generation: generation,
                boundary: boundary,
                detail: "Voice processing could not restart: \(error.localizedDescription)"
            )
            return
        }
        if case .unavailable = outcome {
            await self.retirePendingVoiceProcessingCapture(generation: generation)
            candidate = nil
            await self.restoreAVCaptureAfterRecoveryFailure(
                generation: generation,
                boundary: boundary,
                detail: "Voice-processing microphone capture was unavailable."
            )
            return
        }

        guard self.ownsSafeRecovery(generation),
              await self.waitForBufferProgress(
                  timeoutSeconds: Self.firstBufferDeadlineSeconds,
                  using: candidate!
              ),
              self.ownsSafeRecovery(generation),
              MeetingCapturePathDecider.decide(
                  mode: .onlineCall,
                  microphone: elected.identity,
                  outputRoute: MeetingCaptureEngine.currentOutputRouteSnapshot()
              ) == .voiceProcessing
        else {
            await self.retirePendingVoiceProcessingCapture(generation: generation)
            candidate = nil
            await self.restoreAVCaptureAfterRecoveryFailure(
                generation: generation,
                boundary: boundary,
                detail: "Voice processing did not become ready on the settled audio route."
            )
            return
        }

        guard var pendingBatch = candidateGate.beginCommitFlush() else {
            await self.retirePendingVoiceProcessingCapture(generation: generation)
            candidate = nil
            await self.restoreAVCaptureAfterRecoveryFailure(
                generation: generation,
                boundary: boundary,
                detail: "Voice-processing buffering overflowed before recovery could commit."
            )
            return
        }
        let mayCommit = self.stateLock.withLock { () -> Bool in
            guard self.phase == .transitioning,
                  self.transitionGeneration == generation,
                  !self.stopRequested,
                  self.pendingVoiceProcessingCapture === candidate,
                  self.avCaptureComponent == nil,
                  self.pendingAVCaptureFailure == nil
            else { return false }
            self.phase = .committing
            return true
        }
        guard mayCommit else {
            await self.retirePendingVoiceProcessingCapture(generation: generation)
            candidate = nil
            self.finishTransition(generation)
            return
        }

        let settled = await candidate!.settledConfiguration()
        do {
            try await self.microphoneWriter.updateTrackMetadata { track in
                var eras = track.captureEras ?? [self.legacyEra(from: track)]
                if let boundary, boundary.seconds > (eras.last?.startSeconds ?? -.infinity) {
                    eras.append(MeetingCaptureEra(
                        method: .voiceProcessing,
                        deviceUID: elected.identity.coreAudioUID,
                        deviceName: elected.identity.displayName,
                        roleAtElection: elected.role,
                        startSeconds: boundary.seconds,
                        settledConfig: settled
                    ))
                }
                track.captureEras = eras
                track.captureMethod = .voiceProcessing
                track.voiceProcessingConfig = settled
            }
        } catch {
            await self.retirePendingVoiceProcessingCapture(generation: generation)
            candidate = nil
            await self.restoreAVCaptureAfterRecoveryFailure(
                generation: generation,
                boundary: boundary,
                detail: "Could not persist voice-processing recovery: \(error.localizedDescription)"
            )
            return
        }

        let ack = MeetingCaptureMethodChangeAck()
        self.eventHandler(.captureMethodChanged(
            trackID: self.microphoneWriter.trackID,
            method: .voiceProcessing,
            ack: ack
        ))
        await ack.wait()
        guard self.ownsSafeRecovery(generation) else {
            await self.retirePendingVoiceProcessingCapture(generation: generation)
            candidate = nil
            self.finishTransition(generation)
            return
        }

        while true {
            await self.flushBatch(pendingBatch)
            guard let next = candidateGate.continueCommitFlush() else { break }
            pendingBatch = next
        }

        let committed = self.stateLock.withLock { () -> Bool in
            guard self.phase == .committing,
                  self.transitionGeneration == generation,
                  !self.stopRequested,
                  self.pendingVoiceProcessingCapture === candidate,
                  self.pendingAVCaptureFailure == nil
            else { return false }
            self.currentFence = candidateFence
            self.gate = candidateGate
            self.pendingVoiceProcessingCapture = nil
            self.phase = .vpio
            self.routeDrivenFallback = false
            self.interruptedThisEra = false
            return true
        }
        guard committed else {
            await self.retirePendingVoiceProcessingCapture(generation: generation)
            candidate = nil
            self.finishTransition(generation)
            return
        }
        DebugLogger.shared.log(
            "Meeting microphone recovered voice processing on \(elected.identity.displayName).",
            source: "MeetingCaptureEngine"
        )
        self.startWatchdog()
        self.finishTransition(generation)
    }

    private func retirePendingVoiceProcessingCapture(generation: UInt64) async {
        let capture = self.stateLock.withLock { self.pendingVoiceProcessingCapture }
        await capture?.stop()
        self.stateLock.withLock {
            guard self.transitionGeneration == generation,
                  self.pendingVoiceProcessingCapture === capture
            else { return }
            self.pendingVoiceProcessingCapture = nil
            self.micCapture = MeetingMicrophoneCapture()
        }
    }

    private func restoreAVCaptureAfterRecoveryFailure(
        generation: UInt64,
        boundary: MeetingMediaTime?,
        detail: String
    ) async {
        guard self.ownsSafeRecovery(generation) else {
            self.finishTransition(generation)
            return
        }
        let elected = await MeetingCaptureDeviceElection.elect(original: self.originalMicrophone)
        guard self.ownsSafeRecovery(generation) else {
            self.finishTransition(generation)
            return
        }

        let fence = MeetingEraAcceptanceFence()
        let gate = MeetingVoiceProcessingCommitGate()
        let token = MeetingAVCaptureAttemptToken()
        let microphoneWriter = self.microphoneWriter
        let liveAudioHandler = self.liveAudioHandler
        let component: MeetingAVCaptureMicrophoneComponent
        do {
            component = try MeetingAVCaptureMicrophoneComponent(
                microphone: elected.identity,
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
                onTerminalStop: { [weak self] failure in
                    self?.handleAVCaptureFailureSignal(
                        detail: failure,
                        generation: generation,
                        token: token
                    )
                }
            )
        } catch {
            self.failSafeRecovery(
                generation: generation,
                detail: "\(detail) Fallback microphone recreation failed: \(error.localizedDescription)"
            )
            self.finishTransition(generation)
            return
        }

        let parked = self.stateLock.withLock { () -> Bool in
            guard self.phase == .transitioning || self.phase == .committing,
                  self.transitionGeneration == generation,
                  !self.stopRequested,
                  self.pendingVoiceProcessingCapture == nil,
                  self.avCaptureComponent == nil
            else { return false }
            self.phase = .transitioning
            self.avCaptureComponent = component
            self.avCaptureFailureToken = token
            self.pendingAVCaptureFailure = nil
            return true
        }
        guard parked else {
            try? await component.stop()
            self.finishTransition(generation)
            return
        }

        do {
            try await component.start()
        } catch {
            self.invalidateAVCaptureFailureToken(token, generation: generation)
            try? await component.stop()
            self.failSafeRecovery(
                generation: generation,
                detail: "\(detail) Fallback microphone could not start: \(error.localizedDescription)"
            )
            self.finishTransition(generation)
            return
        }
        guard self.ownsSafeRecovery(generation),
              await self.waitForBufferProgress(
                  timeoutSeconds: Self.firstBufferDeadlineSeconds,
                  using: component
              ),
              self.ownsSafeRecovery(generation),
              var pendingBatch = gate.beginCommitFlush()
        else {
            self.invalidateAVCaptureFailureToken(token, generation: generation)
            try? await component.stop()
            self.failSafeRecovery(
                generation: generation,
                detail: "\(detail) Fallback microphone delivered no audio."
            )
            self.finishTransition(generation)
            return
        }

        let promotion = self.stateLock.withLock { () -> DowngradeCommitDecision in
            guard self.phase == .transitioning,
                  self.transitionGeneration == generation,
                  !self.stopRequested,
                  self.avCaptureComponent === component,
                  self.avCaptureFailureToken === token
            else { return .stale }
            if let failure = self.pendingAVCaptureFailure, failure.generation == generation {
                return .failed(failure.detail)
            }
            self.phase = .committing
            return .committed
        }
        switch promotion {
        case .committed:
            break
        case .stale:
            self.invalidateAVCaptureFailureToken(token, generation: generation)
            try? await component.stop()
            self.finishTransition(generation)
            return
        case let .failed(failureDetail):
            self.invalidateAVCaptureFailureToken(token, generation: generation)
            try? await component.stop()
            self.failSafeRecovery(generation: generation, detail: failureDetail)
            self.finishTransition(generation)
            return
        }
        do {
            try await self.microphoneWriter.updateTrackMetadata { track in
                var eras = track.captureEras ?? [self.legacyEra(from: track)]
                if let boundary, boundary.seconds > (eras.last?.startSeconds ?? -.infinity) {
                    eras.append(MeetingCaptureEra(
                        method: .avCaptureSession,
                        deviceUID: elected.identity.coreAudioUID,
                        deviceName: elected.identity.displayName,
                        roleAtElection: elected.role,
                        startSeconds: boundary.seconds
                    ))
                }
                track.captureEras = eras
                track.captureMethod = .avCaptureSession
            }
        } catch {
            self.invalidateAVCaptureFailureToken(token, generation: generation)
            try? await component.stop()
            self.failSafeRecovery(
                generation: generation,
                detail: "\(detail) Fallback microphone metadata could not be saved."
            )
            self.finishTransition(generation)
            return
        }

        let ack = MeetingCaptureMethodChangeAck()
        self.eventHandler(.captureMethodChanged(
            trackID: self.microphoneWriter.trackID,
            method: .avCaptureSession,
            ack: ack
        ))
        await ack.wait()
        guard self.ownsSafeRecovery(generation) else {
            self.invalidateAVCaptureFailureToken(token, generation: generation)
            try? await component.stop()
            self.finishTransition(generation)
            return
        }
        while true {
            await self.flushBatch(pendingBatch)
            guard let next = gate.continueCommitFlush() else { break }
            pendingBatch = next
        }

        let commitDecision = self.stateLock.withLock { () -> DowngradeCommitDecision in
            guard self.phase == .committing,
                  self.transitionGeneration == generation,
                  !self.stopRequested,
                  self.avCaptureComponent === component,
                  self.avCaptureFailureToken === token
            else { return .stale }
            if let failure = self.pendingAVCaptureFailure, failure.generation == generation {
                return .failed(failure.detail)
            }
            self.currentFence = fence
            self.phase = .avCapture
            // Route-driven recovery remains eligible for a bounded retry. The
            // policy's attempt cap prevents churn while allowing transient HAL
            // settling failures after Bluetooth removal to recover echo control.
            self.interruptedThisEra = false
            return .committed
        }
        switch commitDecision {
        case .committed:
            break
        case .stale:
            self.invalidateAVCaptureFailureToken(token, generation: generation)
            try? await component.stop()
            self.finishTransition(generation)
            return
        case let .failed(failureDetail):
            self.invalidateAVCaptureFailureToken(token, generation: generation)
            try? await component.stop()
            self.failSafeRecovery(generation: generation, detail: failureDetail)
            self.finishTransition(generation)
            return
        }
        DebugLogger.shared.warning(
            "\(detail) Continued with fallback microphone capture.",
            source: "MeetingCaptureEngine"
        )
        self.startAVCaptureWatchdog(generation: generation, component: component)
        self.finishTransition(generation)
        self.armSafeVoiceProcessingRecoveryIfViable()
    }

    private func failSafeRecovery(generation: UInt64, detail: String) {
        let shouldEmit = self.stateLock.withLock { () -> Bool in
            guard self.transitionGeneration == generation, !self.stopRequested else { return false }
            self.pendingVoiceProcessingCapture = nil
            self.avCaptureComponent = nil
            self.avCaptureFailureToken = nil
            self.pendingAVCaptureFailure = nil
            self.quarantined = true
            self.phase = .failed
            self.interruptedThisEra = true
            return true
        }
        if shouldEmit {
            self.eventHandler(.interrupted(
                kind: .captureStoppedUnexpectedly,
                trackID: nil,
                detail: detail
            ))
        }
    }

    private func ownsDowngradeTransition(_ generation: UInt64) -> Bool {
        self.stateLock.withLock {
            self.phase == .transitioning
                && self.transitionGeneration == generation
                && !self.stopRequested
        }
    }

    private func failPendingDowngrade(generation: UInt64, detail: String) {
        let shouldEmit = self.stateLock.withLock { () -> Bool in
            guard self.phase == .transitioning,
                  self.transitionGeneration == generation,
                  !self.stopRequested
            else { return false }
            self.pendingAVCaptureFailure = nil
            self.phase = .failed
            self.interruptedThisEra = true
            return true
        }
        if shouldEmit {
            self.eventHandler(.interrupted(
                kind: .captureStoppedUnexpectedly, trackID: nil, detail: detail
            ))
        }
    }

    private func finishTransition(_ generation: UInt64) {
        let shouldReplayRouteChange = self.stateLock.withLock { () -> Bool in
            guard self.transitionGeneration == generation else { return false }
            self.transitionTask = nil
            guard (self.phase == .avCapture || self.phase == .vpio),
                  self.routeChangeDirty,
                  !self.stopRequested
            else { return false }
            self.routeChangeDirty = false
            return true
        }
        if shouldReplayRouteChange { self.handleRouteChange() }
    }

    func stop() async throws {
        let recoveryDwell = self.stateLock.withLock { () -> Task<Void, Never>? in
            self.stopRequested = true
            self.avCaptureFailureToken = nil
            self.pendingAVCaptureFailure = nil
            defer { self.recoveryDwellTask = nil }
            return self.recoveryDwellTask
        }
        recoveryDwell?.cancel()

        if let transitionTask = self.stateLock.withLock({ self.transitionTask }) {
            await transitionTask.value
        }
        let (watchdog, staleListener) = self.stateLock.withLock { () -> (Task<Void, Never>?, MeetingOutputRouteListener?) in
            defer { self.watchdogTask = nil; self.outputRouteListener = nil }
            return (self.watchdogTask, self.outputRouteListener)
        }
        watchdog?.cancel()
        await staleListener?.stop()

        if let fallback = self.stateLock.withLock({ self.fallbackRuntime }) {
            try await fallback.stop()
            return
        }

        let phase = self.stateLock.withLock { self.phase }
        guard phase == .vpio || phase == .avCapture else {
            let (gateToAbort, captureToStop) = self.stateLock.withLock { (self.gate, self.micCapture) }
            gateToAbort.abort()
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingMicrophone, queueRole: .actorControl, phase: .microphoneStop)
            #endif
            await captureToStop.stop()
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingMicrophone, queueRole: .actorControl, phase: .microphoneStop)
            #endif
            if let component = self.stateLock.withLock({ self.avCaptureComponent }) {
                try? await component.stop()
            }
            await self.stopAppOnlyIfStarted()
            return
        }

        if phase == .vpio {
            // Quiesce first — stats must not be snapshotted while the tap can still emit.
            let micCapture = self.stateLock.withLock { self.micCapture }
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingMicrophone, queueRole: .actorControl, phase: .microphoneStop)
            #endif
            await micCapture.stop()
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingMicrophone, queueRole: .actorControl, phase: .microphoneStop)
            #endif
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
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseBegin, owner: .avCapture, queueRole: .actorControl, phase: .avCaptureStop)
            #endif
            try? await component.stop()
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseEnd, owner: .avCapture, queueRole: .actorControl, phase: .avCaptureStop)
            #endif
        }

        if let appOnly = self.stateLock.withLock({ self.appOnlyRuntime }) {
            #if DEBUG
            AudioTopologyDiagnostics.record(.phaseBegin, owner: .screenCapture, queueRole: .actorControl, phase: .screenCaptureStop)
            defer { AudioTopologyDiagnostics.record(.phaseEnd, owner: .screenCapture, queueRole: .actorControl, phase: .screenCaptureStop) }
            #endif
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
