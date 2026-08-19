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

/// Matches ASRService's exclusive-activity lease API so the arbiter can depend on a protocol
/// instead of the concrete service (enables fakes in arbiter tests).
@MainActor
protocol ASRActivityLeasing: AnyObject {
    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease
    func releaseExclusiveActivity(_ lease: ASRActivityLease)
}

extension ASRService: ASRActivityLeasing {}

@MainActor
final class AudioActivityArbiter: MeetingAudioActivityArbitrating {
    private let asrServiceProvider: @MainActor () throws -> any ASRActivityLeasing
    private var meetingLease: MeetingAudioActivityLease?
    private var sharedActivityLease: ASRActivityLease?
    private weak var activeASRService: (any ASRActivityLeasing)?

    init(asrServiceProvider: @escaping @MainActor () throws -> any ASRActivityLeasing) {
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
    @Published private(set) var liveTranscript: MeetingLiveTranscriptSnapshot = .empty

    /// Sustained application-audio silence, in seconds, before the silence watchdog degrades the session.
    private static let silenceWatchdogThresholdSeconds: TimeInterval = 90
    /// How recently the microphone track must have had activity for the watchdog to treat it as "the
    /// user is talking into a silent meeting" rather than "nobody is in the meeting".
    private static let microphoneRecentActivityThresholdSeconds: TimeInterval = 15

    private let store: any MeetingSessionStoring
    private let capture: any MeetingCaptureControlling
    private let processing: any MeetingProcessingControlling
    private let audioArbiter: any MeetingAudioActivityArbitrating
    private let preferredMicrophoneUID: @MainActor () -> String?

    private enum DegradeReason { case silence, sourceLoss, sticky }

    private var degradeReason: DegradeReason?
    private var activityLease: MeetingAudioActivityLease?
    private var liveTranscriptionCoordinator: MeetingLiveTranscriptionCoordinator?
    private var captureGeneration: UUID?
    private var operationGeneration: UUID?
    private var stopTask: Task<MeetingSession, Error>? {
        willSet { if (newValue == nil) != (self.stopTask == nil) { self.objectWillChange.send() } }
    }
    private var interruptionTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var retryTask: Task<MeetingSession, Error>? {
        willSet { if (newValue == nil) != (self.retryTask == nil) { self.objectWillChange.send() } }
    }
    private var persistenceTail: Task<Void, Never>?
    private var persistenceGeneration = 0
    private var restoreTask: Task<Void, Never>?
    private var isDeleting = false {
        willSet { if newValue != self.isDeleting { self.objectWillChange.send() } }
    }
    private var isMutatingSession = false {
        willSet { if newValue != self.isMutatingSession { self.objectWillChange.send() } }
    }
    private var sweepPending = false
    private var retentionTimerTask: Task<Void, Never>?

    private enum TranscriptCorrection {
        case rename(speakerID: SessionSpeakerID, previousName: String)
        case reassign(segmentID: MeetingTranscriptSegmentID, previousSpeakerID: SessionSpeakerID?, previousRevision: Int)
        case merge(sourceID: SessionSpeakerID, targetID: SessionSpeakerID,
                   movedSegments: [(id: MeetingTranscriptSegmentID, previousRevision: Int)])
        case renameBatch([(speakerID: SessionSpeakerID, previousName: String)])
    }
    private var correctionUndoStacks: [MeetingSessionID: [TranscriptCorrection]] = [:]
    private static let correctionUndoStackCap = 50

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

    private var hasBlockingActivityTask: Bool {
        self.stopTask != nil || self.interruptionTask != nil || self.terminationTask != nil || self.retryTask != nil
    }

    /// True when no capture/stop/interruption/termination/retry activity is in flight and the
    /// session isn't mid-transition — safe for the UI to offer delete/retry/record-again actions.
    var isQuiescent: Bool {
        guard !self.hasBlockingActivityTask,
              !self.isRecording,
              !self.isProcessing,
              !self.isDeleting,
              !self.isMutatingSession
        else { return false }
        switch self.state {
        case .preparing, .stopping:
            return false
        default:
            return true
        }
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
        await self.ensureRestored()
        try configuration.validate()
        guard self.activeSession == nil, !self.hasBlockingActivityTask else {
            throw MeetingCoordinatorError.recordingAlreadyActive
        }
        guard !self.isMutatingSession else {
            throw MeetingCoordinatorError.maintenanceInProgress
        }

        let lease = try self.audioArbiter.acquireMeetingCapture()
        self.activityLease = lease
        let generation = UUID()
        self.captureGeneration = generation
        self.degradeReason = nil
        self.operationGeneration = generation
        let timebase = Self.makeTimebase()
        var session = MeetingSession(configuration: configuration, timebase: timebase)
        session.retention.retainAudioUntil = SettingsStore.shared.meetingAudioRetentionPolicy
            .retainUntil(startedAt: session.startedAt)
        self.activeSession = session
        self.state = .preparing(session.id)
        var captureStarted = false
        var captureStartAttempted = false

        let liveTranscriptionCoordinator = MeetingLiveTranscriptionCoordinator { [weak self] snapshot in
            // Common-modes trampoline, not the main dispatch queue: the queue is starved while the
            // user drags a window (event-tracking mode), which froze live captions mid-drag.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    self?.liveTranscript = snapshot
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        self.liveTranscriptionCoordinator = liveTranscriptionCoordinator
        self.liveTranscript = .empty
        liveTranscriptionCoordinator.start(mode: configuration.mode)

        do {
            try await self.store.create(session)
            let sessionDirectory = try await self.store.sessionDirectory(for: session.id)
            captureStartAttempted = true
            let startResult = try await self.capture.start(
                session: session,
                configuration: configuration,
                sessionDirectory: sessionDirectory,
                eventHandler: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleCaptureEvent(event, generation: generation)
                    }
                },
                liveAudioHandler: { [weak liveTranscriptionCoordinator] kind, sampleBuffer in
                    liveTranscriptionCoordinator?.offer(kind: kind, sampleBuffer: sampleBuffer)
                }
            )
            captureStarted = true
            guard self.operationGeneration == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            if let microphoneTrack = startResult.tracks.first(where: { $0.kind == .microphone }) {
                liveTranscriptionCoordinator.setMicrophoneCaptureMethod(microphoneTrack.captureMethod)
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
            Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
            return session
        } catch {
            await self.tearDownLiveTranscription()
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
            self.degradeReason = nil
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
        guard let activeSession else { throw MeetingCoordinatorError.noRecoverableAudio }
        return try await self.retryProcessing(sessionID: activeSession.id)
    }

    @discardableResult
    func retryProcessing(sessionID: MeetingSessionID) async throws -> MeetingSession {
        guard self.retryTask == nil else { throw MeetingCoordinatorError.activityInProgress }
        let task = Task { @MainActor [weak self] () throws -> MeetingSession in
            guard let self else { throw MeetingCoordinatorError.noActiveMeeting }
            return try await self.performRetryProcessing(sessionID: sessionID)
        }
        self.retryTask = task
        do {
            let session = try await task.value
            self.retryTask = nil
            return session
        } catch {
            self.retryTask = nil
            throw error
        }
    }

    private func performRetryProcessing(sessionID: MeetingSessionID) async throws -> MeetingSession {
        await self.ensureRestored()
        guard self.stopTask == nil,
              self.interruptionTask == nil,
              self.terminationTask == nil,
              !self.isProcessing,
              !self.isRecording,
              !self.isDeleting
        else { throw MeetingCoordinatorError.activityInProgress }
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.maintenanceInProgress }

        if self.activeSession?.id == sessionID {
            guard let session = self.activeSession, session.hasRetryableAudio else {
                throw MeetingCoordinatorError.noRecoverableAudio
            }
            return try await self.beginProcessingRetry(session)
        }

        if let offer = self.activeSession {
            guard offer.state == .interrupted || offer.state == .failed else {
                throw MeetingCoordinatorError.activityInProgress
            }
        }

        guard let session = try await self.store.load(id: sessionID) else {
            throw MeetingCoordinatorError.noActiveMeeting
        }
        // Re-validate: another operation may have started while we awaited the load above.
        guard self.stopTask == nil,
              self.interruptionTask == nil,
              self.terminationTask == nil,
              !self.isProcessing,
              !self.isRecording,
              !self.isDeleting
        else { throw MeetingCoordinatorError.activityInProgress }
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.maintenanceInProgress }
        guard session.hasRetryableAudio else { throw MeetingCoordinatorError.noRecoverableAudio }

        // Acquire before displacing/adopting so a throw here never strands activeSession mid-transition.
        if self.activityLease == nil {
            self.activityLease = try self.audioArbiter.acquireMeetingCapture()
        }

        // Target is valid — only now displace the passive recovery offer it replaces.
        if var offer = self.activeSession {
            guard offer.state == .interrupted || offer.state == .failed else {
                throw MeetingCoordinatorError.activityInProgress
            }
            offer.recoveryResolvedAt = Date()
            offer.updatedAt = Date()
            try? await self.store.save(offer)
            Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
            guard self.terminationTask == nil else { throw MeetingCoordinatorError.activityInProgress }
            self.activeSession = nil
            self.trackHealth = [:]
            self.state = .idle
        }

        self.activeSession = session
        self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
        return try await self.beginProcessingRetry(session)
    }

    private func beginProcessingRetry(_ inputSession: MeetingSession) async throws -> MeetingSession {
        var session = inputSession
        if self.activityLease == nil {
            self.activityLease = try self.audioArbiter.acquireMeetingCapture()
        }
        let generation = UUID()
        self.operationGeneration = generation
        session.state = .processing
        self.state = .processing(session.id, .pending)
        // Close out zombie attempts left behind by a previous crash before starting a fresh one.
        let closedAt = Date()
        for index in session.processingAttempts.indices where session.processingAttempts[index].completedAt == nil {
            session.processingAttempts[index].completedAt = closedAt
        }
        session.processingAttempts.append(Self.pendingProcessingAttempt())
        session.updatedAt = Date()
        self.activeSession = session
        try? await self.store.save(session)
        // Processing regenerates the transcript; only clear the undo stack once retry actually
        // proceeds so a lease/save failure above leaves the prior correction undoable.
        self.correctionUndoStacks[session.id] = nil
        return try await self.process(session, generation: generation)
    }

    func deleteSession(id: MeetingSessionID) async throws {
        await self.ensureRestored()
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.maintenanceInProgress }
        guard self.isQuiescent else { throw MeetingCoordinatorError.activityInProgress }
        self.isDeleting = true
        defer { self.isDeleting = false }
        await self.flushQueuedPersistence()
        // Re-check: the flush await gives a racing operation a window to start.
        guard !self.hasBlockingActivityTask else { throw MeetingCoordinatorError.activityInProgress }
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.maintenanceInProgress }
        try await self.store.delete(id: id)
        self.correctionUndoStacks[id] = nil
        if self.activeSession?.id == id {
            self.activeSession = nil
            self.trackHealth = [:]
            self.state = .idle
        }
        if self.latestCompletedSession?.id == id {
            self.latestCompletedSession = nil
            if self.state == .completed(id) {
                self.state = .idle
            }
        }
    }

    @discardableResult
    func recordAgain(
        from sourceID: MeetingSessionID,
        configuration: MeetingCaptureConfiguration
    ) async throws -> MeetingSession {
        await self.ensureRestored()
        guard !self.hasBlockingActivityTask,
              !self.isProcessing,
              !self.isRecording,
              !self.isDeleting
        else { throw MeetingCoordinatorError.activityInProgress }
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.maintenanceInProgress }
        if let snapshot = self.activeSession, snapshot.id == sourceID {
            guard snapshot.state == .interrupted || snapshot.state == .failed else {
                throw MeetingCoordinatorError.activityInProgress
            }
            return try await self.recordAgainFromActiveOffer(snapshot, configuration: configuration)
        }
        return try await self.recordAgainFromHistory(sourceID: sourceID, configuration: configuration)
    }

    private func recordAgainFromActiveOffer(
        _ snapshot: MeetingSession,
        configuration: MeetingCaptureConfiguration
    ) async throws -> MeetingSession {
        self.activeSession = nil
        self.trackHealth = [:]
        self.state = .idle
        do {
            let newSession = try await self.startRecording(configuration: configuration)
            var resolved = snapshot
            resolved.recoveryResolvedAt = Date()
            resolved.updatedAt = Date()
            try? await self.store.save(resolved)
            Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
            return newSession
        } catch {
            if self.activeSession == nil {
                self.activeSession = snapshot
                self.trackHealth = Dictionary(uniqueKeysWithValues: snapshot.audioTracks.map { ($0.kind, $0.health) })
                self.state = snapshot.state == .interrupted
                    ? .interrupted(snapshot.id)
                    : .failed(snapshot.id, snapshot.failures.last ?? Self.failure(from: error, domain: .capture, recoverable: true))
            }
            throw error
        }
    }

    private func recordAgainFromHistory(
        sourceID: MeetingSessionID,
        configuration: MeetingCaptureConfiguration
    ) async throws -> MeetingSession {
        let newSession = try await self.startRecording(configuration: configuration)
        if var source = try? await self.store.load(id: sourceID) {
            source.recoveryResolvedAt = Date()
            source.updatedAt = Date()
            do {
                try await self.store.save(source)
                Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
            } catch {
                DebugLogger.shared.log("recordAgain: could not stamp recoveryResolvedAt for \(sourceID): \(error)")
            }
        }
        return newSession
    }

    // MARK: - Transcript corrections

    /// Gate → resolve → guard → mutate copy → save → commit (inverse pushed only after save).
    /// Active-slot targets also check the generations: closes the `.preparing` window that
    /// `!isProcessing && !isRecording` alone would miss.
    private func assertSafeToMutate(sessionID: MeetingSessionID) throws {
        guard !self.hasBlockingActivityTask, !self.isDeleting
        else { throw MeetingCoordinatorError.activityInProgress }
        if self.activeSession?.id == sessionID {
            guard self.captureGeneration == nil, self.operationGeneration == nil
            else { throw MeetingCoordinatorError.activityInProgress }
        } else if self.isProcessing, case let .processing(processingID, _) = self.state, processingID == sessionID {
            throw MeetingCoordinatorError.activityInProgress
        }
    }

    private func performCorrection(
        sessionID: MeetingSessionID,
        mutate: (inout MeetingSession) throws -> TranscriptCorrection
    ) async throws -> MeetingSession {
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.activityInProgress }
        self.isMutatingSession = true
        defer { self.releaseMutationGate() }

        await self.ensureRestored()
        await self.flushQueuedPersistence()

        var target = try await self.resolveSession(sessionID)

        // Re-check after the awaits above: another operation may have started while we waited.
        try self.assertSafeToMutate(sessionID: sessionID)

        let before = target
        let inverse = try mutate(&target)
        guard target != before else { return target }
        try await self.store.save(target)

        var stack = self.correctionUndoStacks[sessionID] ?? []
        stack.append(inverse)
        if stack.count > Self.correctionUndoStackCap {
            stack.removeFirst(stack.count - Self.correctionUndoStackCap)
        }
        self.correctionUndoStacks[sessionID] = stack

        self.refreshSlots(with: target)
        return target
    }

    private func resolveSession(_ id: MeetingSessionID) async throws -> MeetingSession {
        if let active = self.activeSession, active.id == id { return active }
        if let completed = self.latestCompletedSession, completed.id == id { return completed }
        if let loaded = try await self.store.load(id: id) { return loaded }
        throw MeetingCoordinatorError.noActiveMeeting
    }

    private func refreshSlots(with session: MeetingSession) {
        if self.activeSession?.id == session.id { self.activeSession = session }
        if self.latestCompletedSession?.id == session.id { self.latestCompletedSession = session }
    }

    @discardableResult
    func renameSpeaker(sessionID: MeetingSessionID, speakerID: SessionSpeakerID, to displayName: String) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID) { session in
            let previousName = session.speakers.first(where: { $0.id == speakerID })?.displayName ?? ""
            try session.renameSpeaker(id: speakerID, to: displayName)
            return .rename(speakerID: speakerID, previousName: previousName)
        }
    }

    @discardableResult
    func renameSpeakers(sessionID: MeetingSessionID, names: [SessionSpeakerID: String]) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID) { session in
            var applied: [(speakerID: SessionSpeakerID, previousName: String)] = []
            for (speakerID, name) in names {
                guard let existing = session.speakers.first(where: { $0.id == speakerID }),
                      existing.mergedIntoSpeakerID == nil else { continue }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != existing.displayName else { continue }
                try session.renameSpeaker(id: speakerID, to: trimmed)
                applied.append((speakerID, existing.displayName))
            }
            return .renameBatch(applied)
        }
    }

    @discardableResult
    func reassignSegment(
        sessionID: MeetingSessionID,
        segmentID: MeetingTranscriptSegmentID,
        to speakerID: SessionSpeakerID
    ) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID) { session in
            guard let segment = session.transcriptSegments.first(where: { $0.id == segmentID }) else {
                throw MeetingDomainError.segmentNotFound
            }
            let previousSpeakerID = segment.speakerID
            let previousRevision = segment.revision
            try session.reassignSegment(id: segmentID, to: speakerID)
            return .reassign(segmentID: segmentID, previousSpeakerID: previousSpeakerID, previousRevision: previousRevision)
        }
    }

    @discardableResult
    func mergeSpeakers(sessionID: MeetingSessionID, source: SessionSpeakerID, into targetID: SessionSpeakerID) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID) { session in
            let movedSegments = session.transcriptSegments
                .filter { $0.speakerID == source }
                .map { (id: $0.id, previousRevision: $0.revision) }
            try session.mergeSpeakers(source, into: targetID)
            return .merge(sourceID: source, targetID: targetID, movedSegments: movedSegments)
        }
    }

    @discardableResult
    func undoTranscriptCorrection(sessionID: MeetingSessionID) async throws -> MeetingSession {
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.activityInProgress }
        self.isMutatingSession = true
        defer { self.releaseMutationGate() }

        await self.ensureRestored()
        await self.flushQueuedPersistence()

        guard var stack = self.correctionUndoStacks[sessionID], let correction = stack.popLast() else {
            throw MeetingCoordinatorError.noCorrectionToUndo
        }

        var target = try await self.resolveSession(sessionID)

        try self.assertSafeToMutate(sessionID: sessionID)

        guard Self.applyInverse(correction, to: &target) else {
            // Inverse target no longer exists: drop the stale entry, never save a no-op.
            self.correctionUndoStacks[sessionID] = stack
            throw MeetingCoordinatorError.noCorrectionToUndo
        }
        // Deliberate: undo bumps updatedAt like any other mutation rather than restoring the prior value.
        target.updatedAt = Date()

        do {
            try await self.store.save(target)
        } catch {
            stack.append(correction)
            self.correctionUndoStacks[sessionID] = stack
            throw error
        }
        self.correctionUndoStacks[sessionID] = stack

        self.refreshSlots(with: target)
        return target
    }

    func canUndoCorrection(sessionID: MeetingSessionID) -> Bool {
        !(self.correctionUndoStacks[sessionID]?.isEmpty ?? true)
    }

    /// Not a transcript correction: does not push onto `correctionUndoStacks`.
    @discardableResult
    func renameSession(sessionID: MeetingSessionID, to title: String) async throws -> MeetingSession {
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.activityInProgress }
        self.isMutatingSession = true
        defer { self.releaseMutationGate() }

        await self.ensureRestored()
        await self.flushQueuedPersistence()

        var target = try await self.resolveSession(sessionID)

        try self.assertSafeToMutate(sessionID: sessionID)

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MeetingDomainError.emptyMeetingTitle }
        guard target.title != trimmed else { return target }

        target.title = trimmed
        target.updatedAt = Date()
        try await self.store.save(target)

        self.refreshSlots(with: target)
        return target
    }

    // MARK: - Audio retention

    /// Manifest-first: cleared manifest saved before file removal, so a crash between the two
    /// leaves a leftover `tracks/` that the sweep heals. Undo stack survives (audio-independent).
    @discardableResult
    func deleteAudio(sessionID: MeetingSessionID) async throws -> MeetingSession {
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.activityInProgress }
        self.isMutatingSession = true
        defer { self.releaseMutationGate() }

        await self.ensureRestored()
        await self.flushQueuedPersistence()

        var target = try await self.resolveSession(sessionID)

        try self.assertSafeToMutate(sessionID: sessionID)

        target = try await self.applyAudioDeletion(to: target)

        self.refreshSlots(with: target)
        return target
    }

    /// Shared by deleteAudio and the sweep — the sweep already holds the gate, so it must not
    /// call the public guard-throwing API.
    private func applyAudioDeletion(to inputTarget: MeetingSession) async throws -> MeetingSession {
        var target = inputTarget
        guard target.retention.audioDeletedAt == nil else { return target }
        for index in target.audioTracks.indices {
            target.audioTracks[index].chunks = []
        }
        target.retention.audioDeletedAt = Date()
        target.updatedAt = Date()
        try await self.store.save(target)
        do {
            try await self.store.deleteAudioFiles(for: target.id)
        } catch {
            DebugLogger.shared.warning(
                "Failed to remove audio files for \(target.id) after save; sweep will heal it later: \(error)",
                source: "MeetingSessionCoordinator"
            )
        }
        return target
    }

    private func releaseMutationGate() {
        self.isMutatingSession = false
        // A sweep re-armed during termination would race the app's exit.
        guard self.sweepPending else { return }
        self.sweepPending = false
        guard self.terminationTask == nil else { return }
        Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
    }

    /// Skips (pending) while another mutation holds the gate; the releasing op reschedules it.
    func sweepExpiredAudio() async {
        guard !self.isMutatingSession else {
            self.sweepPending = true
            return
        }
        self.isMutatingSession = true
        defer { self.releaseMutationGate() }

        // A queued tail save landing after our deletes would resurrect the audio manifest.
        await self.flushQueuedPersistence()

        let sessions: [MeetingSession]
        do {
            sessions = try await self.store.loadAll()
        } catch {
            DebugLogger.shared.warning(
                "Retention sweep could not load sessions; leaving the current timer as-is: \(error)",
                source: "MeetingSessionCoordinator"
            )
            return
        }
        let policy = SettingsStore.shared.meetingAudioRetentionPolicy
        let now = Date()
        var nextDeadline: Date?

        for session in sessions {
            await self.healLeftoverAudio(for: session)

            guard session.retention.audioDeletedAt == nil else { continue }
            guard Self.isSweepEligible(session) else { continue }
            guard let deadline = policy.deadline(endedAt: session.endedAt, startedAt: session.startedAt) else { continue }

            guard deadline <= now else {
                if nextDeadline.map({ deadline < $0 }) ?? true { nextDeadline = deadline }
                continue
            }
            guard self.isSafeToSweep(sessionID: session.id) else {
                // Contended, not expired: retry soon.
                nextDeadline = min(nextDeadline ?? .distantFuture, Date().addingTimeInterval(60))
                continue
            }

            do {
                let target = try await self.applyAudioDeletion(to: session)
                self.refreshSlots(with: target)
            } catch {
                DebugLogger.shared.warning(
                    "Retention sweep failed for \(session.id): \(error)",
                    source: "MeetingSessionCoordinator"
                )
            }
        }

        self.scheduleRetentionTimer(nextDeadline: nextDeadline)
    }

    /// An empty recreated `tracks/` is not crash-window residue — heal only real content.
    private func healLeftoverAudio(for session: MeetingSession) async {
        guard session.retention.audioDeletedAt != nil,
              let directory = try? await self.store.existingSessionDirectory(for: session.id)
        else { return }
        let tracksPath = directory.appendingPathComponent("tracks", isDirectory: true).path
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: tracksPath), !contents.isEmpty
        else { return }
        try? await self.store.deleteAudioFiles(for: session.id)
    }

    /// A quiescent active slot (resolved offer, parked completed session) is safe to sweep.
    private func isSafeToSweep(sessionID: MeetingSessionID) -> Bool {
        guard self.activeSession?.id == sessionID else { return true }
        return !self.hasBlockingActivityTask && !self.isProcessing && !self.isRecording && !self.isDeleting
    }

    private static func isSweepEligible(_ session: MeetingSession) -> Bool {
        switch session.state {
        case .completed:
            return true
        case .failed, .interrupted:
            // Dismissed wrecks don't keep audio forever; unresolved ones are never swept.
            return session.recoveryResolvedAt != nil
        default:
            return false
        }
    }

    /// Exposed for tests only: whether a future-deadline sweep is currently scheduled.
    var hasScheduledRetentionSweep: Bool { self.retentionTimerTask != nil }

    private func scheduleRetentionTimer(nextDeadline: Date?) {
        self.retentionTimerTask?.cancel()
        guard let nextDeadline else {
            self.retentionTimerTask = nil
            return
        }
        // Daily bound: protects the UInt64 conversion and self-heals miscomputed deadlines.
        let delaySeconds = min(max(0, nextDeadline.timeIntervalSinceNow), 86_400)
        self.retentionTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.sweepExpiredAudio()
        }
    }

    /// False when the inverse's target no longer exists; caller must not save or re-push.
    private static func applyInverse(_ correction: TranscriptCorrection, to session: inout MeetingSession) -> Bool {
        switch correction {
        case let .rename(speakerID, previousName):
            guard let index = session.speakers.firstIndex(where: { $0.id == speakerID }) else { return false }
            session.speakers[index].displayName = previousName
            return true
        case let .reassign(segmentID, previousSpeakerID, previousRevision):
            guard let index = session.transcriptSegments.firstIndex(where: { $0.id == segmentID }) else { return false }
            session.transcriptSegments[index].speakerID = previousSpeakerID
            session.transcriptSegments[index].revision = previousRevision
            return true
        case let .merge(sourceID, _, movedSegments):
            guard let index = session.speakers.firstIndex(where: { $0.id == sourceID }) else { return false }
            session.speakers[index].mergedIntoSpeakerID = nil
            let previousRevisionByID = Dictionary(uniqueKeysWithValues: movedSegments.map { ($0.id, $0.previousRevision) })
            for segmentIndex in session.transcriptSegments.indices {
                guard let previousRevision = previousRevisionByID[session.transcriptSegments[segmentIndex].id] else { continue }
                session.transcriptSegments[segmentIndex].speakerID = sourceID
                session.transcriptSegments[segmentIndex].revision = previousRevision
            }
            return true
        case let .renameBatch(entries):
            var restored = false
            for entry in entries {
                guard let index = session.speakers.firstIndex(where: { $0.id == entry.speakerID }) else { continue }
                session.speakers[index].displayName = entry.previousName
                restored = true
            }
            return restored
        }
    }

    func resetForNewMeeting() throws {
        guard !self.isRecording,
              !self.isProcessing,
              !self.hasBlockingActivityTask,
              !self.isDeleting
        else {
            throw MeetingCoordinatorError.activityInProgress
        }
        guard !self.isMutatingSession else {
            throw MeetingCoordinatorError.maintenanceInProgress
        }
        if var session = self.activeSession,
           session.state == .interrupted || session.state == .failed
        {
            session.recoveryResolvedAt = Date()
            session.updatedAt = Date()
            self.enqueuePersistence(session)
            Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
        }
        self.activeSession = nil
        self.trackHealth = [:]
        self.state = .idle
    }

    func ensureRestored() async {
        if let restoreTask {
            await restoreTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreRecoverableSessionIfNeeded()
        }
        self.restoreTask = task
        await task.value
    }

    private func restoreRecoverableSessionIfNeeded() async {
        guard self.activeSession == nil else { return }
        let recoverable: [MeetingSession]
        do {
            recoverable = try await self.store.loadRecoverable()
        } catch {
            DebugLogger.shared.log("Meeting recovery scan failed; will retry next ensureRestored: \(error)")
            self.restoreTask = nil
            return
        }
        guard !recoverable.isEmpty else { return }

        var viable: [MeetingSession] = []
        for session in recoverable {
            let expectedKinds: Set<MeetingAudioTrackKind> = session.mode == .onlineCall
                ? [.applicationAudio, .microphone]
                : [.microphone]
            let hasExpectedTracks = Set(session.audioTracks.map(\.kind)) == expectedKinds
            if hasExpectedTracks, session.hasFinalizedAudio {
                viable.append(session)
                continue
            }
            // Non-viable sessions never occupy the active slot; a session already marked
            // .failed keeps its existing failure history instead of gaining a new one.
            if session.state == .failed {
                // Non-viable and already failed: nothing to offer now or later — resolve it
                // so it stops being rescanned. Audio stays on disk, reachable from history.
                if session.recoveryResolvedAt == nil {
                    var resolved = session
                    resolved.recoveryResolvedAt = Date()
                    resolved.updatedAt = Date()
                    try? await self.store.save(resolved)
                }
                continue
            }
            var failedSession = session
            failedSession.state = .failed
            if session.hasFinalizedAudio, failedSession.endedAt == nil {
                let backfilled = session.audioTracks
                    .compactMap(\.health.lastSampleAt)
                    .max() ?? session.updatedAt
                failedSession.endedAt = max(backfilled, session.startedAt)
            }
            let failure = Self.nonViableRecoveryFailure(for: session)
            if failedSession.failures.last?.code != failure.code {
                failedSession.failures.append(failure)
            }
            failedSession.updatedAt = Date()
            do { try await self.store.save(failedSession) } catch {
                DebugLogger.shared.log("Failed to persist non-viable recovery classification for \(session.id): \(error)")
            }
        }
        guard !viable.isEmpty else { return }

        let active = viable.sorted { lhs, rhs in
            lhs.startedAt != rhs.startedAt
                ? lhs.startedAt < rhs.startedAt
                : lhs.id.uuidString < rhs.id.uuidString
        }.last!

        for session in viable {
            guard session.id == active.id else {
                guard session.state != .interrupted, session.state != .failed else { continue }
                let updated = Self.markRecoverableInterrupted(session)
                do { try await self.store.save(updated) } catch {
                    DebugLogger.shared.log("Failed to persist deferred recovery for \(session.id): \(error)")
                }
                continue
            }
            if session.state == .failed,
               let failure = session.failures.last,
               failure.recoverable
            {
                // Preserve today's behavior: a failed-but-recoverable session is re-offered as-is.
                self.activeSession = session
                self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
                self.state = .failed(session.id, failure)
            } else {
                let updated = Self.markRecoverableInterrupted(session)
                try? await self.store.save(updated)
                self.activeSession = updated
                self.trackHealth = Dictionary(uniqueKeysWithValues: updated.audioTracks.map { ($0.kind, $0.health) })
                self.state = .interrupted(updated.id)
            }
        }
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
        // Bounded: termination must never hang on a stuck mutation save.
        for _ in 0..<100 {
            guard self.isMutatingSession else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await self.restoreTask?.value
        self.captureGeneration = nil
        self.degradeReason = nil
        self.operationGeneration = nil
        self.stopTask?.cancel()
        self.interruptionTask?.cancel()
        self.retryTask?.cancel()

        guard var session = self.activeSession else {
            await self.flushQueuedPersistence()
            await self.capture.shutdownForTermination()
            await self.tearDownLiveTranscription()
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
        await self.tearDownLiveTranscription()

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
        if Self.shouldQueuePendingAttempt(for: session) {
            session.processingAttempts.append(Self.pendingProcessingAttempt())
        }
        session.updatedAt = Date()
        await self.flushQueuedPersistence()
        do {
            try await self.store.save(session)
        } catch MeetingSessionStoreError.sessionDeleted {
            // Deleted mid-shutdown: don't resurrect it as an interrupted offer.
            self.activeSession = nil
            self.trackHealth = [:]
            self.state = .idle
            self.releaseActivityLease()
            return
        } catch {
            // Preserve today's behavior: reinstall as interrupted despite the save failure.
        }
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
        await self.tearDownLiveTranscription()
        guard self.operationGeneration == generation, !Task.isCancelled else {
            throw CancellationError()
        }
        self.captureGeneration = nil
        self.degradeReason = nil
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
        do {
            let sessionDirectory = try await self.store.sessionDirectory(for: session.id)
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
            if !result.skippedChunkIDs.isEmpty {
                session.events.append(MeetingSessionEvent(
                    id: UUID(),
                    occurredAt: Date(),
                    kind: .writerFailure,
                    trackID: nil,
                    detail: "\(result.skippedChunkIDs.count) audio chunk(s) could not be read and were skipped."
                ))
                let skipped = Set(result.skippedChunkIDs)
                for trackIndex in session.audioTracks.indices {
                    for chunkIndex in session.audioTracks[trackIndex].chunks.indices
                        where skipped.contains(session.audioTracks[trackIndex].chunks[chunkIndex].id)
                    {
                        session.audioTracks[trackIndex].chunks[chunkIndex].finalizationState = .failed
                    }
                }
            }
            session.state = .completed
            session.updatedAt = Date()
            await self.flushQueuedPersistence()
            try await self.store.save(session)
            self.removeCheckpoint(sessionDirectory: sessionDirectory)
            self.activeSession = nil
            self.latestCompletedSession = session
            self.state = .completed(session.id)
            self.operationGeneration = nil
            self.releaseActivityLease()
            // afterTranscription policy deletes here; sweep failures are logged, never affect this result.
            Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
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
            var health = health
            let kind = session.audioTracks[index].kind
            let watchdogTripped = kind == .applicationAudio && health.status != .degraded
                && (health.silentForSeconds ?? 0) >= Self.silenceWatchdogThresholdSeconds
                && (self.trackHealth[.microphone]?.silentForSeconds).map {
                    $0 < Self.microphoneRecentActivityThresholdSeconds
                } == true
            if watchdogTripped {
                health.status = .degraded
                health.detail = "No meeting audio is being captured while your microphone is active."
            }
            session.audioTracks[index].health = health
            self.trackHealth[kind] = health
            if health.status == .degraded {
                session.state = .recordingDegraded
                self.state = .recordingDegraded(session.id)
                // Writer-reported degrades stay sticky; only watchdog degrades may self-restore.
                self.degradeReason = watchdogTripped ? (self.degradeReason ?? .silence) : .sticky
            } else if kind == .applicationAudio, session.state == .recordingDegraded,
                      self.degradeReason == .silence,
                      (health.silentForSeconds ?? 0) < Self.silenceWatchdogThresholdSeconds,
                      !session.audioTracks.contains(where: { $0.id != trackID && $0.health.status == .degraded })
            {
                session.state = .recording
                self.state = .recording(session.id)
                self.degradeReason = nil
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
        case let .captureMethodChanged(trackID, method, ack):
            // Resumed after this lands, before the upgrade opens the gate. Downgrades pass `ack: nil`.
            defer { ack?.resume() }
            guard let index = session.audioTracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.audioTracks[index].captureMethod = method
            if session.audioTracks[index].kind == .microphone {
                self.liveTranscriptionCoordinator?.setMicrophoneCaptureMethod(method)
                self.liveTranscriptionCoordinator?.resetMicrophoneUtterance()
            }
            session.events.append(MeetingSessionEvent(
                id: UUID(),
                occurredAt: Date(),
                kind: .microphoneChanged,
                trackID: trackID,
                detail: "Microphone capture switched to \(method.rawValue)."
            ))
            // Only clear degradation this change plausibly caused — never a sticky one.
            if session.state == .recordingDegraded,
               self.degradeReason == nil || self.degradeReason == .sourceLoss || self.degradeReason == .silence,
               !session.audioTracks.contains(where: { $0.health.status == .degraded })
            {
                session.state = .recording
                self.state = .recording(session.id)
                self.degradeReason = nil
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
                self.degradeReason = nil
                self.operationGeneration = nil
                self.enqueuePersistence(session)
                self.beginUnexpectedStop(sessionID: session.id)
                return
            } else if kind == .sourceRecovered, session.state == .recordingDegraded,
                      self.degradeReason == .sourceLoss,
                      !session.audioTracks.contains(where: { $0.health.status == .degraded })
            {
                session.state = .recording
                self.state = .recording(session.id)
                self.degradeReason = nil
            } else if kind != .sourceRecovered, session.state == .recording {
                session.state = .recordingDegraded
                self.state = .recordingDegraded(session.id)
                self.degradeReason = kind == .sourceLost ? (self.degradeReason ?? .sourceLoss) : .sticky
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
        await self.tearDownLiveTranscription()
        guard self.terminationTask == nil, !Task.isCancelled else { return }

        session.state = .interrupted
        if Self.shouldQueuePendingAttempt(for: session) {
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
        self.degradeReason = nil
        self.operationGeneration = nil
        if let partialResult = Self.partialStopResult(from: error) {
            Self.apply(partialResult, to: &session)
        } else {
            await self.capture.shutdownForTermination()
            session.endedAt = session.endedAt ?? Date()
        }
        await self.tearDownLiveTranscription()
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
        if Self.shouldQueuePendingAttempt(for: session) {
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
        self.persistenceGeneration += 1
        let previous = self.persistenceTail
        let store = self.store
        self.persistenceTail = Task {
            _ = await previous?.value
            try? await store.save(session)
        }
    }

    private func flushQueuedPersistence() async {
        while let tail = self.persistenceTail {
            let generation = self.persistenceGeneration
            _ = await tail.value
            if self.persistenceGeneration == generation {
                self.persistenceTail = nil
                return
            }
        }
    }

    /// Must complete before any code path that calls into `processing.process`, so both live
    /// engines' CoreML models are released before the batch pipeline's `ensureAsrReady()` loads.
    private func tearDownLiveTranscription() async {
        guard let coordinator = self.liveTranscriptionCoordinator else { return }
        self.liveTranscriptionCoordinator = nil
        await coordinator.stop()
        self.liveTranscript = .empty
    }

    private func releaseActivityLease() {
        guard let lease = self.activityLease else { return }
        self.audioArbiter.release(lease)
        self.activityLease = nil
    }

    /// Only called after the completed session save succeeds; on failure the checkpoint stays so a
    /// retry can resume from it.
    private func removeCheckpoint(sessionDirectory: URL) {
        let url = sessionDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            DebugLogger.shared.warning(
                "Failed to remove meeting checkpoint after completion: \(error)",
                source: "MeetingSessionCoordinator"
            )
        }
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

    private static func shouldQueuePendingAttempt(for session: MeetingSession) -> Bool {
        session.hasFinalizedAudio
            && !session.processingAttempts.contains(where: { $0.completedAt == nil })
    }

    private static func nonViableRecoveryFailure(for session: MeetingSession) -> MeetingSessionFailure {
        let hasAudio = session.hasFinalizedAudio
        let message: String
        if session.audioTracks.isEmpty {
            message = "Recording never started — no audio was captured."
        } else if hasAudio {
            message = "Some tracks are missing, but captured audio was preserved."
        } else {
            message = "No finalized audio survived."
        }
        return Self.failure(
            from: MeetingCoordinatorError.noRecoverableAudio,
            domain: .persistence,
            recoverable: hasAudio,
            message: message
        )
    }

    private static func markRecoverableInterrupted(_ inputSession: MeetingSession) -> MeetingSession {
        var session = inputSession
        let previousState = session.state
        session.state = .interrupted
        if session.endedAt == nil {
            session.endedAt = session.audioTracks
                .compactMap(\.health.lastSampleAt)
                .max() ?? session.updatedAt
        }
        if previousState != .interrupted {
            session.events.append(MeetingSessionEvent(
                id: UUID(),
                occurredAt: Date(),
                kind: .captureStoppedUnexpectedly,
                trackID: nil,
                detail: previousState == .processing
                    ? "FluidVoice restarted before transcription completed."
                    : "FluidVoice restarted before capture finalized."
            ))
        }
        if Self.shouldQueuePendingAttempt(for: session) {
            session.processingAttempts.append(Self.pendingProcessingAttempt())
        }
        session.updatedAt = Date()
        return session
    }

    private static func hasRecoverableAudio(_ session: MeetingSession) -> Bool {
        session.endedAt != nil && session.hasFinalizedAudio
    }

    private static func firstPresentationTime(in tracks: [MeetingAudioTrack]) -> MeetingMediaTime? {
        tracks.flatMap(\.chunks).map(\.presentationStart).min()
    }

    private static func failure(
        from error: Error,
        domain: MeetingFailureDomain,
        recoverable: Bool,
        message: String? = nil
    ) -> MeetingSessionFailure {
        let nsError = error as NSError
        return MeetingSessionFailure(
            id: UUID(),
            occurredAt: Date(),
            domain: domain,
            code: "\(nsError.domain).\(nsError.code)",
            message: message ?? error.localizedDescription,
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
    case noCorrectionToUndo
    case maintenanceInProgress

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
        case .noCorrectionToUndo:
            return "There is nothing to undo."
        case .maintenanceInProgress:
            return "FluidVoice is tidying up meeting storage. Try again in a moment."
        }
    }
}
