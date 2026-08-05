import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

nonisolated protocol MeetingCaptureControlling: Sendable {
    func start(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration,
        sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void
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

    func start(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration,
        sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void
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
            runtime = try await ScreenCaptureMeetingRuntime.make(
                application: application,
                microphone: configuration.microphone,
                applicationWriter: applicationWriter,
                microphoneWriter: microphoneWriter,
                eventHandler: eventHandler
            )
        case .inRoom:
            guard let microphoneWriter = writersByKind[.microphone] else {
                throw MeetingCaptureError.microphoneUnavailable
            }
            runtime = try InRoomMicrophoneCaptureRuntime(
                microphone: configuration.microphone,
                writer: microphoneWriter,
                eventHandler: eventHandler
            )
        }

        do {
            try await runtime.start()
        } catch {
            try? await runtime.stop()
            _ = await Self.stopWriters(writers)
            throw error
        }

        self.activeCapture = ActiveCapture(
            sessionID: session.id,
            runtime: runtime,
            writers: writers
        )
        return MeetingCaptureStartResult(tracks: tracks, firstPresentationTime: nil)
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
            return result
        } catch {
            self.activeCapture = nil
            self.stopTask = nil
            throw error
        }
    }

    func shutdownForTermination() async {
        guard let sessionID = self.activeCapture?.sessionID else { return }
        _ = try? await self.stop(sessionID: sessionID)
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
                chunks: []
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
            chunks: []
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

    private nonisolated static func preflightStorage(at directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity < 512 * 1024 * 1024 {
            throw MeetingCaptureError.insufficientDiskSpace
        }
    }
}

private nonisolated protocol MeetingCaptureRuntime: AnyObject, Sendable {
    func start() async throws
    func stop() async throws
}

private final nonisolated class ScreenCaptureMeetingRuntime: NSObject, MeetingCaptureRuntime, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable
{
    private let stream: SCStream
    private let applicationWriter: MeetingAudioChunkWriter
    private let microphoneWriter: MeetingAudioChunkWriter
    private let eventHandler: @Sendable (MeetingCaptureEvent) -> Void
    private let stateLock = NSLock()
    private var delegateProxy: ScreenCaptureRuntimeDelegateProxy?
    private var stopping = false
    private var unexpectedStopReported = false

    private init(
        stream: SCStream,
        applicationWriter: MeetingAudioChunkWriter,
        microphoneWriter: MeetingAudioChunkWriter,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void
    ) {
        self.stream = stream
        self.applicationWriter = applicationWriter
        self.microphoneWriter = microphoneWriter
        self.eventHandler = eventHandler
        super.init()
    }

    static func make(
        application: MeetingApplicationIdentity,
        microphone: MeetingMicrophoneIdentity,
        applicationWriter: MeetingAudioChunkWriter,
        microphoneWriter: MeetingAudioChunkWriter,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void
    ) async throws -> ScreenCaptureMeetingRuntime {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw MeetingCaptureError.screenCapturePermissionDenied(error.localizedDescription)
        }
        guard let runningApplication = content.applications.first(where: { candidate in
            if let processID = application.processID {
                return candidate.processID == processID
            }
            return candidate.bundleIdentifier == application.bundleIdentifier
        }) else {
            throw MeetingCaptureError.applicationUnavailable(application.displayName)
        }
        let display = application.displayID.flatMap { displayID in
            content.displays.first(where: { $0.displayID == displayID })
        } ?? content.displays.first
        guard let display else { throw MeetingCaptureError.noCaptureDisplay }

        let filter = SCContentFilter(
            display: display,
            including: [runningApplication],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphone.captureDeviceID

        let placeholder = ScreenCaptureRuntimeDelegateProxy()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: placeholder)
        let runtime = ScreenCaptureMeetingRuntime(
            stream: stream,
            applicationWriter: applicationWriter,
            microphoneWriter: microphoneWriter,
            eventHandler: eventHandler
        )
        placeholder.owner = runtime
        runtime.delegateProxy = placeholder
        try stream.addStreamOutput(
            runtime,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(
                label: "com.fluidvoice.meeting.screencapture.application",
                qos: .userInteractive
            )
        )
        try stream.addStreamOutput(
            runtime,
            type: .microphone,
            sampleHandlerQueue: DispatchQueue(
                label: "com.fluidvoice.meeting.screencapture.microphone",
                qos: .userInteractive
            )
        )
        return runtime
    }

    func start() async throws {
        do {
            try await self.stream.startCapture()
        } catch {
            throw MeetingCaptureError.captureStartFailed(error.localizedDescription)
        }
    }

    func stop() async throws {
        self.markStopping()
        let result = await withCheckedContinuation { continuation in
            let completion = MeetingOneShotCompletion(continuation)
            self.stream.stopCapture { error in
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
        self.stateLock.lock()
        self.stopping = true
        self.stateLock.unlock()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        self.stateLock.lock()
        let shouldAccept = !self.stopping
        self.stateLock.unlock()
        guard shouldAccept else { return }
        switch outputType {
        case .audio:
            self.applicationWriter.enqueue(sampleBuffer)
        case .microphone:
            self.microphoneWriter.enqueue(sampleBuffer)
        case .screen:
            break
        @unknown default:
            break
        }
    }

    func handleStreamStop(error: Error) {
        self.stateLock.lock()
        let wasStopping = self.stopping
        let shouldReport = !wasStopping && !self.unexpectedStopReported
        if shouldReport {
            self.unexpectedStopReported = true
            self.stopping = true
        }
        self.stateLock.unlock()
        guard shouldReport else { return }
        self.eventHandler(.interrupted(
            kind: .captureStoppedUnexpectedly,
            trackID: nil,
            detail: error.localizedDescription
        ))
    }
}

private final nonisolated class ScreenCaptureRuntimeDelegateProxy: NSObject, SCStreamDelegate, @unchecked Sendable {
    weak var owner: ScreenCaptureMeetingRuntime?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.owner?.handleStreamStop(error: error)
    }
}

private final nonisolated class InRoomMicrophoneCaptureRuntime: NSObject, MeetingCaptureRuntime,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let writer: MeetingAudioChunkWriter
    private let controlQueue = DispatchQueue(label: "com.fluidvoice.meeting.inroom.control")
    private let stateLock = NSLock()
    private let eventHandler: @Sendable (MeetingCaptureEvent) -> Void
    private var stopping = false
    private var emittedUnexpectedStop = false
    private var notificationObservers: [NSObjectProtocol] = []

    init(
        microphone: MeetingMicrophoneIdentity,
        writer: MeetingAudioChunkWriter,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void
    ) throws {
        self.writer = writer
        self.eventHandler = eventHandler
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
