import Combine
import Darwin
import Foundation

enum MeetingCoordinatorState: Equatable {
    case idle
    case preparing(MeetingSessionID)
    case recording(MeetingSessionID)
    case recordingDegraded(MeetingSessionID)
    case stopping(MeetingSessionID)
    case processing(MeetingSessionID, MeetingProcessingStage)
    case completed(MeetingSessionID)
    case interrupted(MeetingSessionID)
    case failed(MeetingSessionID?, MeetingSessionFailure)
}

struct MeetingAudioActivityLease: Equatable, Sendable {
    var id: UUID
}

@MainActor
protocol MeetingAudioActivityArbitrating: AnyObject {
    func acquireMeetingCapture() throws -> MeetingAudioActivityLease
    func release(_ lease: MeetingAudioActivityLease)
}

@MainActor
final class AudioActivityArbiter: MeetingAudioActivityArbitrating {
    private let asrServiceProvider: @MainActor () throws -> ASRService
    private var meetingLease: MeetingAudioActivityLease?
    private var sharedActivityLease: ASRActivityLease?
    private weak var activeASRService: ASRService?

    init(asrServiceProvider: @escaping @MainActor () throws -> ASRService) {
        self.asrServiceProvider = asrServiceProvider
    }

    func acquireMeetingCapture() throws -> MeetingAudioActivityLease {
        guard self.meetingLease == nil else { throw MeetingCoordinatorError.recordingAlreadyActive }
        let asrService = try self.asrServiceProvider()
        let sharedLease = try asrService.acquireExclusiveActivity(.meeting)
        let lease = MeetingAudioActivityLease(id: UUID())
        self.activeASRService = asrService
        self.sharedActivityLease = sharedLease
        self.meetingLease = lease
        return lease
    }

    func release(_ lease: MeetingAudioActivityLease) {
        guard self.meetingLease == lease else { return }
        if let sharedActivityLease = self.sharedActivityLease {
            self.activeASRService?.releaseExclusiveActivity(sharedActivityLease)
        }
        self.activeASRService = nil
        self.sharedActivityLease = nil
        self.meetingLease = nil
    }
}

@MainActor
final class MeetingSessionCoordinator: ObservableObject {
    @Published private(set) var state: MeetingCoordinatorState = .idle
    @Published private(set) var activeSession: MeetingSession?
    @Published private(set) var latestCompletedSession: MeetingSession?
    @Published private(set) var trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth] = [:]

    private let store: any MeetingSessionStoring
    private let capture: any MeetingCaptureControlling
    private let processing: any MeetingProcessingControlling
    private let audioArbiter: any MeetingAudioActivityArbitrating
    private let preferredMicrophoneUID: @MainActor () -> String?

    private var activityLease: MeetingAudioActivityLease?
    private var captureGeneration: UUID?
    private var operationGeneration: UUID?
    private var stopTask: Task<MeetingSession, Error>?
    private var interruptionTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var persistenceTail: Task<Void, Never>?

    init(
        store: any MeetingSessionStoring,
        capture: any MeetingCaptureControlling,
        processing: any MeetingProcessingControlling,
        audioArbiter: any MeetingAudioActivityArbitrating,
        preferredMicrophoneUID: @escaping @MainActor () -> String? = { nil }
    ) {
        self.store = store
        self.capture = capture
        self.processing = processing
        self.audioArbiter = audioArbiter
        self.preferredMicrophoneUID = preferredMicrophoneUID
    }

    var currentSession: MeetingSession? {
        self.activeSession ?? self.latestCompletedSession
    }

    var isRecording: Bool {
        switch self.state {
        case .recording, .recordingDegraded:
            return true
        default:
            return false
        }
    }

    var isProcessing: Bool {
        if case .processing = self.state { return true }
        return false
    }

    var elapsedTime: TimeInterval {
        guard let session = self.activeSession else { return 0 }
        return max(0, (session.endedAt ?? Date()).timeIntervalSince(session.startedAt))
    }

    var sourceDisplayName: String {
        self.currentSession?.capturedApplication?.displayName
            ?? (self.currentSession?.mode == .inRoom ? "In-room meeting" : "Meeting audio")
    }

    var microphoneDisplayName: String {
        self.currentSession?.selectedMicrophone.displayName ?? "Microphone"
    }

    func defaultConfiguration(
        mode: MeetingCaptureMode,
        title: String
    ) async throws -> MeetingCaptureConfiguration {
        let microphone = try MeetingCaptureSourceCatalog.defaultMicrophone(
            preferredCoreAudioUID: self.preferredMicrophoneUID()
        )
        let application: MeetingApplicationIdentity?
        if mode == .onlineCall {
            let applications = try await MeetingCaptureSourceCatalog.availableApplications()
            let preferredBundleIdentifiers = [
                "us.zoom.xos",
                "com.google.Chrome",
                "com.microsoft.teams2",
            ]
            application = preferredBundleIdentifiers.lazy.compactMap { bundleIdentifier in
                applications.first(where: { $0.bundleIdentifier == bundleIdentifier })
            }.first ?? applications.first
            guard application != nil else { throw MeetingCaptureError.applicationNotSelected }
        } else {
            application = nil
        }
        return MeetingCaptureConfiguration(
            mode: mode,
            title: title,
            application: application,
            microphone: microphone
        )
    }

    @discardableResult
    func startRecording(configuration: MeetingCaptureConfiguration) async throws -> MeetingSession {
        try configuration.validate()
        guard self.activeSession == nil,
              self.stopTask == nil,
              self.interruptionTask == nil,
              self.terminationTask == nil
        else {
            throw MeetingCoordinatorError.recordingAlreadyActive
        }

        let lease = try self.audioArbiter.acquireMeetingCapture()
        self.activityLease = lease
        let generation = UUID()
        self.captureGeneration = generation
        self.operationGeneration = generation
        let timebase = Self.makeTimebase()
        var session = MeetingSession(configuration: configuration, timebase: timebase)
        self.activeSession = session
        self.state = .preparing(session.id)
        var captureStarted = false
        var captureStartAttempted = false

        do {
            try await self.store.create(session)
            let sessionDirectory = try await self.store.sessionDirectory(for: session.id)
            captureStartAttempted = true
            let startResult = try await self.capture.start(
                session: session,
                configuration: configuration,
                sessionDirectory: sessionDirectory
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleCaptureEvent(event, generation: generation)
                }
            }
            captureStarted = true
            guard self.operationGeneration == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            session.audioTracks = startResult.tracks
            if let firstPresentationTime = startResult.firstPresentationTime {
                session.timebase.firstPresentationTime = firstPresentationTime
            }
            session.state = .recording
            session.updatedAt = Date()
            self.activeSession = session
            self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
            self.state = .recording(session.id)
            try await self.store.save(session)
            return session
        } catch {
            if self.operationGeneration != generation {
                if captureStarted {
                    _ = try? await self.capture.stop(sessionID: session.id)
                }
                throw error
            }
            if captureStarted {
                do {
                    let stopResult = try await self.capture.stop(sessionID: session.id)
                    Self.apply(stopResult, to: &session)
                } catch let stopError {
                    if let partialResult = Self.partialStopResult(from: stopError) {
                        Self.apply(partialResult, to: &session)
                    } else {
                        await self.capture.shutdownForTermination()
                        session.endedAt = session.endedAt ?? Date()
                    }
                }
            }
            let hasRecoverableAudio = Self.hasRecoverableAudio(session)
            let failureDomain: MeetingFailureDomain = captureStarted
                ? .persistence
                : (captureStartAttempted ? .capture : .persistence)
            let failure = Self.failure(
                from: error,
                domain: failureDomain,
                recoverable: hasRecoverableAudio
            )
            session.state = .failed
            session.failures.append(failure)
            session.updatedAt = Date()
            try? await self.store.save(session)
            self.activeSession = hasRecoverableAudio ? session : nil
            self.trackHealth = hasRecoverableAudio
                ? Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
                : [:]
            self.captureGeneration = nil
            self.operationGeneration = nil
            self.state = .failed(session.id, failure)
            self.releaseActivityLease()
            throw error
        }
    }

    @discardableResult
    func stopAndTranscribe() async throws -> MeetingSession {
        if let stopTask = self.stopTask { return try await stopTask.value }
        guard let session = self.activeSession else { throw MeetingCoordinatorError.noActiveMeeting }
        guard self.interruptionTask == nil, self.terminationTask == nil else {
            throw MeetingCoordinatorError.activityInProgress
        }
        guard [.preparing, .recording, .recordingDegraded, .stopping].contains(session.state),
              let generation = self.operationGeneration
        else { throw MeetingCoordinatorError.activityInProgress }

        let task = Task { @MainActor [weak self] () throws -> MeetingSession in
            guard let self else { throw MeetingCoordinatorError.noActiveMeeting }
            return try await self.performStopAndTranscribe(generation: generation)
        }
        self.stopTask = task
        do {
            let session = try await task.value
            self.stopTask = nil
            return session
        } catch {
            self.stopTask = nil
            throw error
        }
    }

    @discardableResult
    func retryProcessing() async throws -> MeetingSession {
        guard var session = self.activeSession,
              self.interruptionTask == nil,
              self.terminationTask == nil,
              session.endedAt != nil,
              session.audioTracks.contains(where: { !$0.chunks.isEmpty })
        else { throw MeetingCoordinatorError.noRecoverableAudio }
        if self.activityLease == nil {
            self.activityLease = try self.audioArbiter.acquireMeetingCapture()
        }
        let generation = UUID()
        self.operationGeneration = generation
        session.state = .processing
        session.processingAttempts.append(Self.pendingProcessingAttempt())
        session.updatedAt = Date()
        self.activeSession = session
        try? await self.store.save(session)
        return try await self.process(session, generation: generation)
    }

    func renameSpeaker(id: SessionSpeakerID, to displayName: String) async throws {
        guard var session = self.currentSession else { throw MeetingCoordinatorError.noActiveMeeting }
        try session.renameSpeaker(id: id, to: displayName)
        try await self.store.save(session)
        if self.activeSession?.id == session.id {
            self.activeSession = session
        } else {
            self.latestCompletedSession = session
        }
    }

    func resetForNewMeeting() throws {
        guard !self.isRecording,
              !self.isProcessing,
              self.stopTask == nil,
              self.interruptionTask == nil,
              self.terminationTask == nil
        else {
            throw MeetingCoordinatorError.activityInProgress
        }
        self.activeSession = nil
        self.trackHealth = [:]
        self.state = .idle
    }

    func restoreRecoverableSessionIfNeeded() async {
        guard self.activeSession == nil else { return }
        guard var session = try? await self.store.loadRecoverable().first else { return }
        let expectedKinds: Set<MeetingAudioTrackKind> = session.mode == .onlineCall
            ? [.applicationAudio, .microphone]
            : [.microphone]
        guard Set(session.audioTracks.map(\.kind)) == expectedKinds else {
            let failure = Self.failure(
                from: MeetingCoordinatorError.noRecoverableAudio,
                domain: .persistence,
                recoverable: false
            )
            session.state = .failed
            session.failures.append(failure)
            session.updatedAt = Date()
            try? await self.store.save(session)
            self.activeSession = session
            self.state = .failed(session.id, failure)
            return
        }

        if session.state == .failed,
           Self.hasRecoverableAudio(session),
           let failure = session.failures.last,
           failure.recoverable
        {
            self.activeSession = session
            self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
            self.state = .failed(session.id, failure)
            return
        }

        let previousState = session.state
        session.state = .interrupted
        if session.endedAt == nil {
            session.endedAt = session.audioTracks
                .compactMap(\.health.lastSampleAt)
                .max() ?? session.updatedAt
        }
        session.events.append(MeetingSessionEvent(
            id: UUID(),
            occurredAt: Date(),
            kind: .captureStoppedUnexpectedly,
            trackID: nil,
            detail: previousState == .processing
                ? "FluidVoice restarted before transcription completed."
                : "FluidVoice restarted before capture finalized."
        ))
        if session.audioTracks.contains(where: { track in
            track.chunks.contains { $0.finalizationState == .finalized }
        }), !session.processingAttempts.contains(where: { $0.completedAt == nil }) {
            session.processingAttempts.append(Self.pendingProcessingAttempt())
        }
        session.updatedAt = Date()
        try? await self.store.save(session)
        self.activeSession = session
        self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
        self.state = .interrupted(session.id)
    }

    func shutdownForTermination() async {
        if let terminationTask = self.terminationTask {
            await terminationTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performShutdownForTermination()
        }
        self.terminationTask = task
        await task.value
    }

    private func performShutdownForTermination() async {
        self.captureGeneration = nil
        self.operationGeneration = nil
        self.stopTask?.cancel()
        self.interruptionTask?.cancel()

        guard var session = self.activeSession else {
            await self.capture.shutdownForTermination()
            self.releaseActivityLease()
            return
        }

        let wasCapturing = [.preparing, .recording, .recordingDegraded, .stopping].contains(session.state)
        if wasCapturing {
            self.state = .stopping(session.id)
            do {
                let stopResult = try await self.capture.stop(sessionID: session.id)
                Self.apply(stopResult, to: &session)
            } catch {
                if let partialResult = Self.partialStopResult(from: error) {
                    Self.apply(partialResult, to: &session)
                } else {
                    await self.capture.shutdownForTermination()
                    session.endedAt = session.endedAt ?? Date()
                }
                session.failures.append(Self.failure(from: error, domain: .capture, recoverable: true))
            }
        } else {
            await self.capture.shutdownForTermination()
        }

        session.state = .interrupted
        if !session.events.contains(where: { $0.kind == .appTermination }) {
            session.events.append(MeetingSessionEvent(
                id: UUID(),
                occurredAt: Date(),
                kind: .appTermination,
                trackID: nil,
                detail: wasCapturing
                    ? "Capture stopped at app termination; transcription is pending."
                    : "Transcription paused at app termination and will resume next launch."
            ))
        }
        if session.audioTracks.contains(where: { track in
            track.chunks.contains { $0.finalizationState == .finalized }
        }), !session.processingAttempts.contains(where: { $0.completedAt == nil }) {
            session.processingAttempts.append(Self.pendingProcessingAttempt())
        }
        session.updatedAt = Date()
        await self.flushQueuedPersistence()
        try? await self.store.save(session)
        self.activeSession = session
        self.state = .interrupted(session.id)
        self.releaseActivityLease()
    }

    private func performStopAndTranscribe(generation: UUID) async throws -> MeetingSession {
        guard var session = self.activeSession else { throw MeetingCoordinatorError.noActiveMeeting }
        self.state = .stopping(session.id)
        session.state = .stopping
        session.updatedAt = Date()
        self.activeSession = session
        await self.flushQueuedPersistence()
        // Capture finalization takes priority over persistence availability.
        try? await self.store.save(session)

        let stopResult: MeetingCaptureStopResult
        do {
            stopResult = try await self.capture.stop(sessionID: session.id)
        } catch {
            await self.handleStopFailure(error, session: session, generation: generation)
            throw error
        }
        guard self.operationGeneration == generation, !Task.isCancelled else {
            throw CancellationError()
        }
        self.captureGeneration = nil
        Self.apply(stopResult, to: &session)
        session.state = .processing
        session.processingAttempts.append(Self.pendingProcessingAttempt())
        session.updatedAt = Date()
        self.activeSession = session
        self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
        try? await self.store.save(session)
        return try await self.process(session, generation: generation)
    }

    private func process(_ inputSession: MeetingSession, generation: UUID) async throws -> MeetingSession {
        var session = inputSession
        let sessionDirectory = try await self.store.sessionDirectory(for: session.id)
        do {
            let result = try await self.processing.process(
                session: session,
                sessionDirectory: sessionDirectory
            ) { [weak self] stage in
                self?.updateProcessingStage(stage, generation: generation)
            }
            guard self.operationGeneration == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            session.speakers = result.speakers
            session.transcriptSegments = result.segments
            session.processingAttempts.removeAll {
                $0.completedAt == nil && $0.id != result.attempt.id
            }
            if let index = session.processingAttempts.lastIndex(where: { $0.id == result.attempt.id }) {
                session.processingAttempts[index] = result.attempt
            } else {
                session.processingAttempts.append(result.attempt)
            }
            session.state = .completed
            session.updatedAt = Date()
            await self.flushQueuedPersistence()
            try await self.store.save(session)
            self.activeSession = nil
            self.latestCompletedSession = session
            self.state = .completed(session.id)
            self.operationGeneration = nil
            self.releaseActivityLease()
            return session
        } catch {
            guard self.operationGeneration == generation else {
                throw error
            }
            if error is CancellationError {
                session.state = .interrupted
                session.updatedAt = Date()
                await self.flushQueuedPersistence()
                try? await self.store.save(session)
                self.activeSession = session
                self.state = .interrupted(session.id)
                self.operationGeneration = nil
                self.releaseActivityLease()
                throw error
            }
            let failure = Self.failure(from: error, domain: .processing, recoverable: true)
            if let lastIndex = session.processingAttempts.indices.last {
                session.processingAttempts[lastIndex].errorCode = failure.code
                session.processingAttempts[lastIndex].completedAt = Date()
            }
            session.failures.append(failure)
            session.state = .failed
            session.updatedAt = Date()
            await self.flushQueuedPersistence()
            try? await self.store.save(session)
            self.activeSession = session
            self.state = .failed(session.id, failure)
            self.operationGeneration = nil
            self.releaseActivityLease()
            throw error
        }
    }

    private func updateProcessingStage(_ stage: MeetingProcessingStage, generation: UUID) {
        guard self.operationGeneration == generation, var session = self.activeSession else { return }
        session.state = .processing
        if let lastIndex = session.processingAttempts.indices.last {
            session.processingAttempts[lastIndex].stage = stage
        }
        session.updatedAt = Date()
        self.activeSession = session
        self.state = .processing(session.id, stage)
        self.enqueuePersistence(session)
    }

    private func handleCaptureEvent(_ event: MeetingCaptureEvent, generation: UUID) {
        guard self.captureGeneration == generation, var session = self.activeSession else { return }
        switch event {
        case let .trackHealth(trackID, health):
            guard let index = session.audioTracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.audioTracks[index].health = health
            self.trackHealth[session.audioTracks[index].kind] = health
            if health.status == .degraded {
                session.state = .recordingDegraded
                self.state = .recordingDegraded(session.id)
            }
        case let .chunkFinalized(trackID, chunk, format):
            guard let index = session.audioTracks.firstIndex(where: { $0.id == trackID }) else { return }
            if !session.audioTracks[index].chunks.contains(where: { $0.id == chunk.id }) {
                session.audioTracks[index].chunks.append(chunk)
            }
            session.audioTracks[index].format = format
            if let currentFirstPresentationTime = session.timebase.firstPresentationTime {
                session.timebase.firstPresentationTime = min(currentFirstPresentationTime, chunk.presentationStart)
            } else {
                session.timebase.firstPresentationTime = chunk.presentationStart
            }
        case let .interrupted(kind, trackID, detail):
            session.events.append(MeetingSessionEvent(
                id: UUID(),
                occurredAt: Date(),
                kind: kind,
                trackID: trackID,
                detail: detail
            ))
            if kind == .captureStoppedUnexpectedly {
                session.state = .interrupted
                self.state = .interrupted(session.id)
                session.updatedAt = Date()
                self.activeSession = session
                self.captureGeneration = nil
                self.operationGeneration = nil
                self.enqueuePersistence(session)
                self.beginUnexpectedStop(sessionID: session.id)
                return
            } else if session.state == .recording {
                session.state = .recordingDegraded
                self.state = .recordingDegraded(session.id)
            }
        }
        session.updatedAt = Date()
        self.activeSession = session
        self.enqueuePersistence(session)
    }

    private func beginUnexpectedStop(sessionID: MeetingSessionID) {
        guard self.interruptionTask == nil, self.terminationTask == nil else { return }
        self.interruptionTask = Task { @MainActor [weak self] in
            await self?.finishUnexpectedStop(sessionID: sessionID)
        }
    }

    private func finishUnexpectedStop(sessionID: MeetingSessionID) async {
        guard var session = self.activeSession, session.id == sessionID else {
            self.interruptionTask = nil
            return
        }
        do {
            let stopResult = try await self.capture.stop(sessionID: sessionID)
            Self.apply(stopResult, to: &session)
        } catch {
            if let partialResult = Self.partialStopResult(from: error) {
                Self.apply(partialResult, to: &session)
            } else {
                await self.capture.shutdownForTermination()
                session.endedAt = session.endedAt ?? Date()
            }
            session.failures.append(Self.failure(from: error, domain: .capture, recoverable: true))
        }
        guard self.terminationTask == nil, !Task.isCancelled else { return }

        session.state = .interrupted
        if session.audioTracks.contains(where: { track in
            track.chunks.contains { $0.finalizationState == .finalized }
        }), !session.processingAttempts.contains(where: { $0.completedAt == nil }) {
            session.processingAttempts.append(Self.pendingProcessingAttempt())
        }
        session.updatedAt = Date()
        await self.flushQueuedPersistence()
        try? await self.store.save(session)
        self.activeSession = session
        self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
        self.state = .interrupted(session.id)
        self.releaseActivityLease()
        self.interruptionTask = nil
    }

    private func handleStopFailure(
        _ error: Error,
        session inputSession: MeetingSession,
        generation: UUID
    ) async {
        guard self.operationGeneration == generation else { return }
        var session = inputSession
        self.captureGeneration = nil
        self.operationGeneration = nil
        if let partialResult = Self.partialStopResult(from: error) {
            Self.apply(partialResult, to: &session)
        } else {
            await self.capture.shutdownForTermination()
            session.endedAt = session.endedAt ?? Date()
        }
        let failure = Self.failure(from: error, domain: .capture, recoverable: true)
        session.failures.append(failure)
        session.events.append(MeetingSessionEvent(
            id: UUID(),
            occurredAt: Date(),
            kind: .captureStoppedUnexpectedly,
            trackID: nil,
            detail: error.localizedDescription
        ))
        session.state = .interrupted
        if session.audioTracks.contains(where: { track in
            track.chunks.contains { $0.finalizationState == .finalized }
        }), !session.processingAttempts.contains(where: { $0.completedAt == nil }) {
            session.processingAttempts.append(Self.pendingProcessingAttempt())
        }
        session.updatedAt = Date()
        await self.flushQueuedPersistence()
        try? await self.store.save(session)
        self.activeSession = session
        self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
        self.state = .interrupted(session.id)
        self.releaseActivityLease()
    }

    private func enqueuePersistence(_ session: MeetingSession) {
        let previous = self.persistenceTail
        let store = self.store
        self.persistenceTail = Task {
            _ = await previous?.value
            try? await store.save(session)
        }
    }

    private func flushQueuedPersistence() async {
        _ = await self.persistenceTail?.value
        self.persistenceTail = nil
    }

    private func releaseActivityLease() {
        guard let lease = self.activityLease else { return }
        self.audioArbiter.release(lease)
        self.activityLease = nil
    }

    private static func makeTimebase() -> MeetingTimebaseMetadata {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return MeetingTimebaseMetadata(
            startedHostTime: mach_absolute_time(),
            machTimebaseNumerator: info.numer,
            machTimebaseDenominator: info.denom,
            firstPresentationTime: nil
        )
    }

    private static func pendingProcessingAttempt() -> MeetingProcessingAttempt {
        MeetingProcessingAttempt(
            id: UUID(),
            startedAt: Date(),
            completedAt: nil,
            stage: .pending,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: nil,
            asrModel: nil,
            diarizationModel: nil,
            lastCompletedTrackID: nil,
            errorCode: nil
        )
    }

    private static func apply(_ stopResult: MeetingCaptureStopResult, to session: inout MeetingSession) {
        session.audioTracks = stopResult.tracks
        session.endedAt = stopResult.stoppedAt
        session.timebase.firstPresentationTime = self.firstPresentationTime(in: stopResult.tracks)
    }

    private static func partialStopResult(from error: Error) -> MeetingCaptureStopResult? {
        guard let captureError = error as? MeetingCaptureError else { return nil }
        switch captureError {
        case let .captureStopFailed(_, partialResult):
            return partialResult
        default:
            return nil
        }
    }

    private static func hasRecoverableAudio(_ session: MeetingSession) -> Bool {
        session.endedAt != nil && session.audioTracks.contains { track in
            track.chunks.contains {
                $0.finalizationState == .finalized && $0.byteCount > 0
            }
        }
    }

    private static func firstPresentationTime(in tracks: [MeetingAudioTrack]) -> MeetingMediaTime? {
        tracks.flatMap(\.chunks).map(\.presentationStart).min()
    }

    private static func failure(
        from error: Error,
        domain: MeetingFailureDomain,
        recoverable: Bool
    ) -> MeetingSessionFailure {
        let nsError = error as NSError
        return MeetingSessionFailure(
            id: UUID(),
            occurredAt: Date(),
            domain: domain,
            code: "\(nsError.domain).\(nsError.code)",
            message: error.localizedDescription,
            recoverable: recoverable
        )
    }
}

enum MeetingCoordinatorError: LocalizedError {
    case recordingAlreadyActive
    case noActiveMeeting
    case noRecoverableAudio
    case activityInProgress
    case dictationActive

    var errorDescription: String? {
        switch self {
        case .recordingAlreadyActive:
            return "Another meeting recording is already active."
        case .noActiveMeeting:
            return "There is no active meeting."
        case .noRecoverableAudio:
            return "This meeting has no finalized audio to retry."
        case .activityInProgress:
            return "Stop the active meeting activity first."
        case .dictationActive:
            return "Stop dictation before starting a meeting recording."
        }
    }
}
