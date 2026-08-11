@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingRecoveryTests: XCTestCase {
    // MARK: - Fixtures

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfiguration(title: String = "Test") -> MeetingCaptureConfiguration {
        MeetingCaptureConfiguration(
            mode: .inRoom,
            title: title,
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic")
        )
    }

    private func makeTimebase() -> MeetingTimebaseMetadata {
        MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
    }

    private func makeFinalizedChunk(
        sequence: Int = 0,
        path: String = "tracks/microphone/chunk_0.caf"
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: path,
            presentationStart: MeetingMediaTime(value: 0, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: 1000, timescale: 1000),
            discontinuities: [],
            sha256: "abc123",
            byteCount: 128,
            finalizationState: .finalized
        )
    }

    private func makeMicrophoneTrack(chunks: [MeetingAudioChunk]) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "mic-1",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: self.makeTimebase(),
            health: .waiting,
            chunks: chunks
        )
    }

    private func makeSession(
        state: MeetingSessionState,
        startedAt: Date = Date(timeIntervalSinceNow: -3600),
        endedAt: Date? = nil,
        audioTracks: [MeetingAudioTrack] = [],
        failures: [MeetingSessionFailure] = [],
        processingAttempts: [MeetingProcessingAttempt] = [],
        recoveryResolvedAt: Date? = nil
    ) -> MeetingSession {
        var session = MeetingSession(configuration: self.makeConfiguration(), startedAt: startedAt, timebase: self.makeTimebase())
        session.state = state
        session.endedAt = endedAt
        session.audioTracks = audioTracks
        session.failures = failures
        session.processingAttempts = processingAttempts
        session.recoveryResolvedAt = recoveryResolvedAt
        session.updatedAt = startedAt
        return session
    }

    // MARK: - Test 1: loadRecoverable classification

    func testLoadRecoverableClassification() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])

        let recording = self.makeSession(state: .recording, audioTracks: [track])
        let stopping = self.makeSession(state: .stopping, audioTracks: [track])
        let processing = self.makeSession(state: .processing, endedAt: Date(), audioTracks: [track])
        let interrupted = self.makeSession(state: .interrupted, endedAt: Date(), audioTracks: [track])
        let completed = self.makeSession(state: .completed, endedAt: Date(), audioTracks: [track])
        let recoverableFailed = self.makeSession(
            state: .failed,
            endedAt: Date(),
            audioTracks: [track],
            failures: [MeetingSessionFailure(id: UUID(), occurredAt: Date(), domain: .capture, code: "x", message: "m", recoverable: true)]
        )
        let unrecoverableFailed = self.makeSession(
            state: .failed,
            endedAt: Date(),
            audioTracks: [track],
            failures: [MeetingSessionFailure(id: UUID(), occurredAt: Date(), domain: .persistence, code: "x", message: "m", recoverable: false)]
        )
        let dismissedInterrupted = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [track],
            recoveryResolvedAt: Date()
        )

        for session in [recording, stopping, processing, interrupted, completed, recoverableFailed, unrecoverableFailed, dismissedInterrupted] {
            do { try await store.create(session) } catch {
                XCTFail("create failed for state \(session.state): \(error)")
                throw error
            }
        }

        let recoverable = try await store.loadRecoverable()
        let ids = Set(recoverable.map(\.id))

        XCTAssertTrue(ids.contains(recording.id))
        XCTAssertTrue(ids.contains(stopping.id))
        XCTAssertTrue(ids.contains(processing.id))
        XCTAssertTrue(ids.contains(interrupted.id))
        XCTAssertTrue(ids.contains(recoverableFailed.id))
        XCTAssertFalse(ids.contains(completed.id))
        XCTAssertFalse(ids.contains(unrecoverableFailed.id))
        XCTAssertFalse(ids.contains(dismissedInterrupted.id))
    }

    // MARK: - Test 2: multi-session restore

    func testMultiSessionRestoreSelectsNewestViableAndDefersOthers() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let now = Date()
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])

        let older = self.makeSession(
            state: .interrupted,
            startedAt: now.addingTimeInterval(-600),
            endedAt: now.addingTimeInterval(-590),
            audioTracks: [track]
        )
        let newer = self.makeSession(
            state: .recording,
            startedAt: now.addingTimeInterval(-60),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let emptyPreparing = self.makeSession(state: .preparing, startedAt: now.addingTimeInterval(-30))

        for session in [older, newer, emptyPreparing] {
            try await store.create(session)
        }

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()

        XCTAssertEqual(coordinator.activeSession?.id, newer.id)
        XCTAssertEqual(coordinator.state, .interrupted(newer.id))

        let persistedOlder = try await store.load(id: older.id)
        XCTAssertEqual(persistedOlder?.state, .interrupted)
        XCTAssertTrue(persistedOlder?.processingAttempts.isEmpty == true)
        XCTAssertEqual(persistedOlder?.events.count, older.events.count)

        let persistedPreparing = try await store.load(id: emptyPreparing.id)
        XCTAssertEqual(persistedPreparing?.state, .failed)
        XCTAssertEqual(persistedPreparing?.failures.last?.recoverable, false)
        XCTAssertEqual(persistedPreparing?.audioTracks.isEmpty, true)

        // Idempotent within the same launch: a second ensureRestored is a no-op.
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, newer.id)

        // Dismiss the active recovery and simulate the next launch with a fresh coordinator.
        try coordinator.resetForNewMeeting()
        for _ in 0..<100 {
            if let persisted = try await store.load(id: newer.id), persisted.recoveryResolvedAt != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let coordinator2 = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator2.ensureRestored()
        XCTAssertEqual(coordinator2.activeSession?.id, older.id)
        XCTAssertEqual(coordinator2.state, .interrupted(older.id))
    }

    // MARK: - Test 3: dismissal persists recoveryResolvedAt

    func testDismissalPersistsRecoveryResolvedAt() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let session = self.makeSession(state: .interrupted, endedAt: Date(), audioTracks: [track])
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        try coordinator.resetForNewMeeting()

        var persisted: MeetingSession?
        for _ in 0..<40 {
            persisted = try await store.load(id: session.id)
            if persisted?.recoveryResolvedAt != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(persisted?.recoveryResolvedAt)

        let coordinator2 = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator2.ensureRestored()
        XCTAssertNil(coordinator2.activeSession)
        XCTAssertEqual(coordinator2.state, .idle)
    }

    // MARK: - Test 4: retry hygiene

    func testRetryProcessingClosesStaleAttemptAndRejectsWhileProcessing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let staleAttempt = MeetingProcessingAttempt(
            id: UUID(),
            startedAt: Date().addingTimeInterval(-120),
            completedAt: nil,
            stage: .transcribing,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: nil,
            asrModel: nil,
            diarizationModel: nil,
            lastCompletedTrackID: nil,
            errorCode: nil
        )
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [track],
            processingAttempts: [staleAttempt]
        )
        try await store.create(session)

        let processing = GatedProcessingController()
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: processing,
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.processingAttempts.count, 1)

        let retryTask = Task { try await coordinator.retryProcessing() }

        for _ in 0..<40 {
            if case .processing = coordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = coordinator.state else {
            XCTFail("retryProcessing did not reach .processing state")
            return
        }

        let midFlightAttempts = coordinator.activeSession?.processingAttempts ?? []
        XCTAssertEqual(midFlightAttempts.count, 2)
        XCTAssertEqual(midFlightAttempts.filter { $0.completedAt == nil }.count, 1)
        XCTAssertNotNil(midFlightAttempts.first(where: { $0.id == staleAttempt.id })?.completedAt)

        do {
            _ = try await coordinator.retryProcessing()
            XCTFail("Expected retryProcessing to throw while already processing")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                XCTFail("Expected .activityInProgress, got \(error)")
                return
            }
        }

        processing.openGate()
        let finalSession = try await retryTask.value
        XCTAssertEqual(finalSession.state, .completed)
        XCTAssertEqual(finalSession.processingAttempts.count, 2)
        XCTAssertTrue(finalSession.processingAttempts.allSatisfy { $0.completedAt != nil })
    }

    // MARK: - Test 5: launch race

    func testStartRecordingAwaitsRestoreBeforeCapturing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let recorder = EventRecorder()
        let gatedStore = GatedRecoverableStore(inner: realStore, recorder: recorder)

        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        capture.onStart = { await recorder.record("capture.start") }

        let coordinator = MeetingSessionCoordinator(
            store: gatedStore,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )

        let startTask = Task { try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Race")) }

        for _ in 0..<40 {
            if await recorder.events.contains("restore.loadRecoverable.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsBeforeGate = await recorder.events
        XCTAssertTrue(eventsBeforeGate.contains("restore.loadRecoverable.start"))
        XCTAssertFalse(eventsBeforeGate.contains("capture.start"))

        await gatedStore.openGate()
        _ = try await startTask.value

        let finalEvents = await recorder.events
        guard let restoreIndex = finalEvents.firstIndex(of: "restore.loadRecoverable.start"),
              let captureIndex = finalEvents.firstIndex(of: "capture.start")
        else {
            XCTFail("Expected both restore and capture events to be recorded")
            return
        }
        XCTAssertLessThan(restoreIndex, captureIndex)
    }

    // MARK: - Test 6: salvage current behavior pin

    func testMissingChunkFileIsRetainedAsFailedNotDropped() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let chunk = self.makeFinalizedChunk(path: "tracks/microphone/missing.caf")
        let track = self.makeMicrophoneTrack(chunks: [chunk])
        let session = self.makeSession(state: .interrupted, endedAt: Date(), audioTracks: [track])
        try await store.create(session)

        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let trackManifestDirectory = sessionDirectory
            .appendingPathComponent("tracks", isDirectory: true)
            .appendingPathComponent("microphone", isDirectory: true)
        try FileManager.default.createDirectory(at: trackManifestDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(track).write(to: trackManifestDirectory.appendingPathComponent("track.json", isDirectory: false))
        // Deliberately do not write the chunk's audio file, to simulate a missing chunk on disk.

        let loaded = try await store.load(id: session.id)
        let loadedChunk = loaded?.audioTracks.first(where: { $0.kind == .microphone })?.chunks.first

        XCTAssertNotNil(loadedChunk, "A manifest chunk whose file is missing must be retained, not dropped")
        XCTAssertEqual(loadedChunk?.id, chunk.id)
        XCTAssertEqual(loadedChunk?.finalizationState, .failed)
        XCTAssertEqual(loadedChunk?.byteCount, 0)
        XCTAssertEqual(loadedChunk?.sha256, "")
    }

    // MARK: - Test 7: pre-slice JSON without recoveryResolvedAt decodes

    func testPreSliceSessionJSONWithoutResolvedAtDecodes() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let url = dir.appendingPathComponent(session.id.uuidString).appendingPathComponent("session.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json.removeValue(forKey: "recoveryResolvedAt")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reloaded = try await store.load(id: session.id)
        XCTAssertNotNil(reloaded)
        XCTAssertNil(reloaded?.recoveryResolvedAt)
        let recoverable = try await store.loadRecoverable()
        XCTAssertTrue(recoverable.contains(where: { $0.id == session.id }))
    }

    // MARK: - Test 8: retry failure before the pipeline leaves a recoverable state

    func testRetryFailureLeavesRecoverableStateAndReleasesGuards() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThrowingDirectoryStore(wrapping: MeetingSessionStore(rootDirectory: dir))
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertNotNil(coordinator.activeSession)

        do {
            _ = try await coordinator.retryProcessing()
            XCTFail("Expected retryProcessing to throw")
        } catch {}

        guard case .failed = coordinator.state else {
            return XCTFail("Expected .failed after sessionDirectory throw, got \(coordinator.state)")
        }
    }
}

// MARK: - Test doubles

private final class ThrowingDirectoryStore: MeetingSessionStoring, @unchecked Sendable {
    private let wrapped: MeetingSessionStore
    var throwOnSessionDirectory = true

    init(wrapping wrapped: MeetingSessionStore) { self.wrapped = wrapped }

    func create(_ session: MeetingSession) async throws { try await self.wrapped.create(session) }
    func save(_ session: MeetingSession) async throws { try await self.wrapped.save(session) }
    func load(id: MeetingSessionID) async throws -> MeetingSession? { try await self.wrapped.load(id: id) }
    func loadAll() async throws -> [MeetingSession] { try await self.wrapped.loadAll() }
    func loadRecoverable() async throws -> [MeetingSession] { try await self.wrapped.loadRecoverable() }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL {
        if self.throwOnSessionDirectory { throw CocoaError(.fileWriteNoPermission) }
        return try await self.wrapped.sessionDirectory(for: id)
    }
}

private actor EventRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { self.events.append(event) }
}

private final class StubCaptureController: MeetingCaptureControlling, @unchecked Sendable {
    var startResult = MeetingCaptureStartResult(tracks: [], firstPresentationTime: nil)
    var onStart: (@Sendable () async -> Void)?

    func start(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration,
        sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void
    ) async throws -> MeetingCaptureStartResult {
        await self.onStart?()
        return self.startResult
    }

    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult {
        MeetingCaptureStopResult(tracks: [], stoppedAt: Date())
    }

    func shutdownForTermination() async {}
}

@MainActor
private final class StubProcessingController: MeetingProcessingControlling {
    func process(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        MeetingProcessingResult(
            speakers: [],
            segments: [],
            attempt: MeetingProcessingAttempt(
                id: UUID(),
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: nil,
                asrModel: nil,
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            )
        )
    }
}

/// Blocks `process(...)` until `openGate()` is called, so tests can inspect mid-flight state.
@MainActor
private final class GatedProcessingController: MeetingProcessingControlling {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func openGate() {
        self.isOpen = true
        self.continuation?.resume()
        self.continuation = nil
    }

    func process(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        // Mirrors the real pipeline's convention of reusing the still-open attempt's id.
        let attemptID = session.processingAttempts.last(where: { $0.completedAt == nil })?.id ?? UUID()
        if !self.isOpen {
            await withCheckedContinuation { self.continuation = $0 }
        }
        return MeetingProcessingResult(
            speakers: [],
            segments: [],
            attempt: MeetingProcessingAttempt(
                id: attemptID,
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: nil,
                asrModel: nil,
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            )
        )
    }
}

@MainActor
private final class StubArbiter: MeetingAudioActivityArbitrating {
    func acquireMeetingCapture() throws -> MeetingAudioActivityLease { MeetingAudioActivityLease(id: UUID()) }
    func release(_ lease: MeetingAudioActivityLease) {}
}

/// Wraps a real `MeetingSessionStore`, suspending `loadRecoverable()` until `openGate()` is
/// called — used to prove `startRecording` waits for the launch restore barrier.
private actor GatedRecoverableStore: MeetingSessionStoring {
    private let inner: MeetingSessionStore
    private let recorder: EventRecorder
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(inner: MeetingSessionStore, recorder: EventRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func openGate() {
        self.isOpen = true
        self.continuation?.resume()
        self.continuation = nil
    }

    func create(_ session: MeetingSession) async throws { try await self.inner.create(session) }
    func save(_ session: MeetingSession) async throws { try await self.inner.save(session) }
    func load(id: MeetingSessionID) async throws -> MeetingSession? { try await self.inner.load(id: id) }
    func loadAll() async throws -> [MeetingSession] { try await self.inner.loadAll() }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL { try await self.inner.sessionDirectory(for: id) }

    func loadRecoverable() async throws -> [MeetingSession] {
        await self.recorder.record("restore.loadRecoverable.start")
        if !self.isOpen {
            await withCheckedContinuation { self.continuation = $0 }
        }
        return try await self.inner.loadRecoverable()
    }
}
