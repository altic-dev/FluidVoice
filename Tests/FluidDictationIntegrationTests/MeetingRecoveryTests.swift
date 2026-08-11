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

    // MARK: - Transcript correction fixtures

    private func makeSpeaker(
        id: SessionSpeakerID = UUID(),
        name: String = "Speaker",
        trackKind: MeetingAudioTrackKind = .microphone,
        isLocalUser: Bool = false
    ) -> MeetingSessionSpeaker {
        MeetingSessionSpeaker(
            id: id,
            displayName: name,
            diarizationClusterID: nil,
            trackKind: trackKind,
            isLocalUser: isLocalUser,
            identityCandidates: []
        )
    }

    private func makeTranscriptSegment(
        sourceTrackID: MeetingAudioTrackID,
        speakerID: SessionSpeakerID?
    ) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: UUID(),
            start: MeetingMediaTime(value: 0, timescale: 1000),
            end: MeetingMediaTime(value: 1000, timescale: 1000),
            sourceTrackID: sourceTrackID,
            speakerID: speakerID,
            text: "Hello",
            revision: 1,
            status: .final,
            overlap: .none,
            completeness: .complete
        )
    }

    /// A session with two same-track, non-local speakers and one segment on the first speaker —
    /// enough to exercise rename/reassign/merge without tripping their guards.
    private func makeCorrectionSession(
        state: MeetingSessionState
    ) -> (session: MeetingSession, speakerA: SessionSpeakerID, speakerB: SessionSpeakerID, segmentID: MeetingTranscriptSegmentID) {
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        var session = self.makeSession(state: state, endedAt: Date(), audioTracks: [track])
        let speakerA = self.makeSpeaker(name: "Speaker A")
        let speakerB = self.makeSpeaker(name: "Speaker B")
        let segment = self.makeTranscriptSegment(sourceTrackID: track.id, speakerID: speakerA.id)
        session.speakers = [speakerA, speakerB]
        session.transcriptSegments = [segment]
        return (session, speakerA.id, speakerB.id, segment.id)
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

    // MARK: - Test 9: store delete removes directory + index, idempotent, resurrection-proof

    func testStoreDeleteRemovesSessionIdempotently() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path))

        try await store.delete(id: session.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))

        try await store.delete(id: session.id) // idempotent

        do {
            try await store.save(session)
            XCTFail("Expected save after delete to throw")
        } catch {}

        do {
            _ = try await store.sessionDirectory(for: session.id)
            XCTFail("Expected sessionDirectory after delete to throw")
        } catch {}

        let all = try await store.loadAll()
        XCTAssertFalse(all.contains(where: { $0.id == session.id }))
    }

    // MARK: - Test 10: retry-by-id on a non-active history session

    func testRetryByIDOnNonActiveHistorySessionCompletes() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
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
        XCTAssertEqual(coordinator.activeSession?.id, session.id)
        try coordinator.resetForNewMeeting()

        for _ in 0..<40 {
            if let persisted = try await store.load(id: session.id), persisted.recoveryResolvedAt != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(coordinator.activeSession)

        let result = try await coordinator.retryProcessing(sessionID: session.id)
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(coordinator.latestCompletedSession?.id, session.id)
        XCTAssertEqual(coordinator.state, .completed(session.id))
        XCTAssertNil(coordinator.activeSession)
    }

    // MARK: - Test 11: retry-by-id displaces a passive recovery offer

    func testRetryByIDDisplacesPassiveOffer() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let now = Date()
        let older = self.makeSession(
            state: .interrupted,
            startedAt: now.addingTimeInterval(-600),
            endedAt: now.addingTimeInterval(-590),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let newer = self.makeSession(
            state: .interrupted,
            startedAt: now.addingTimeInterval(-60),
            endedAt: now.addingTimeInterval(-50),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(older)
        try await store.create(newer)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, newer.id)

        let result = try await coordinator.retryProcessing(sessionID: older.id)
        XCTAssertEqual(result.id, older.id)
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(coordinator.latestCompletedSession?.id, older.id)

        let persistedOffer = try await store.load(id: newer.id)
        XCTAssertNotNil(persistedOffer?.recoveryResolvedAt)
    }

    // MARK: - Test 12: retry-by-id refused while recording, and while another retry is in-flight

    func testRetryByIDRefusedWhileRecordingAndWhileRetryInFlight() async throws {
        let recordingDir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: recordingDir) }
        let recordingStore = MeetingSessionStore(rootDirectory: recordingDir)
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let recordingCoordinator = MeetingSessionCoordinator(
            store: recordingStore,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        let recordingSession = try await recordingCoordinator.startRecording(configuration: self.makeConfiguration())
        do {
            _ = try await recordingCoordinator.retryProcessing(sessionID: recordingSession.id)
            XCTFail("Expected retryProcessing to throw while recording")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        let retryDir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: retryDir) }
        let retryStore = MeetingSessionStore(rootDirectory: retryDir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await retryStore.create(session)
        let gatedProcessing = GatedProcessingController()
        let retryCoordinator = MeetingSessionCoordinator(
            store: retryStore,
            capture: StubCaptureController(),
            processing: gatedProcessing,
            audioArbiter: StubArbiter()
        )
        await retryCoordinator.ensureRestored()
        let retryTask = Task { try await retryCoordinator.retryProcessing(sessionID: session.id) }

        for _ in 0..<40 {
            if case .processing = retryCoordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = retryCoordinator.state else {
            return XCTFail("First retry did not reach .processing")
        }

        do {
            _ = try await retryCoordinator.retryProcessing(sessionID: session.id)
            XCTFail("Expected second retryProcessing to throw while first is in-flight")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        gatedProcessing.openGate()
        let finalSession = try await retryTask.value
        XCTAssertEqual(finalSession.state, .completed)
    }

    // MARK: - Test 13: deleteSession on the active recovery offer

    func testDeleteSessionOnActiveRecoveryOffer() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
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
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        try await coordinator.deleteSession(id: session.id)

        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    // MARK: - Test 14: deleteSession refused mid-processing

    func testDeleteSessionRefusedMidProcessing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let gatedProcessing = GatedProcessingController()
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: gatedProcessing,
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        let retryTask = Task { try await coordinator.retryProcessing() }

        for _ in 0..<40 {
            if case .processing = coordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = coordinator.state else {
            return XCTFail("retryProcessing did not reach .processing")
        }

        do {
            try await coordinator.deleteSession(id: session.id)
            XCTFail("Expected deleteSession to throw while processing")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        gatedProcessing.openGate()
        _ = try await retryTask.value
    }

    // MARK: - Test 15: delete-resurrection guard

    func testStoreDeleteResurrectionGuard() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        try await store.delete(id: session.id)

        do {
            try await store.save(session)
            XCTFail("Expected save after delete to throw")
        } catch {}

        let sessionDirectory = try await store.existingSessionDirectory(for: session.id)
        XCTAssertNil(sessionDirectory)
    }

    // MARK: - Test 16: recordAgain from a passive offer

    func testRecordAgainFromPassiveOfferSucceeds() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        let newSession = try await coordinator.recordAgain(
            from: session.id,
            configuration: self.makeConfiguration(title: "Again")
        )
        XCTAssertNotEqual(newSession.id, session.id)
        XCTAssertEqual(coordinator.activeSession?.id, newSession.id)
        guard case .recording = coordinator.state else {
            return XCTFail("Expected .recording after recordAgain, got \(coordinator.state)")
        }

        var persistedOld: MeetingSession?
        for _ in 0..<40 {
            persistedOld = try await store.load(id: session.id)
            if persistedOld?.recoveryResolvedAt != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(persistedOld?.recoveryResolvedAt)
    }

    func testRecordAgainFromPassiveOfferRestoresOnCaptureFailure() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let capture = StubCaptureController()
        capture.startError = MeetingCaptureError.applicationNotSelected
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        do {
            _ = try await coordinator.recordAgain(from: session.id, configuration: self.makeConfiguration(title: "Again"))
            XCTFail("Expected recordAgain to throw when capture start fails")
        } catch {}

        XCTAssertEqual(coordinator.activeSession?.id, session.id)
        XCTAssertEqual(coordinator.activeSession?.state, .interrupted)
        XCTAssertEqual(coordinator.state, .interrupted(session.id))

        let persistedOld = try await store.load(id: session.id)
        XCTAssertNil(persistedOld?.recoveryResolvedAt)
    }

    // MARK: - Slice 3: checkpoint fixtures

    private func makeCheckpoint(
        sessionID: MeetingSessionID = UUID(),
        completedTrackID: MeetingAudioTrackID = UUID(),
        trackFingerprints: [MeetingAudioTrackID: [MeetingProcessingCheckpoint.ChunkFingerprint]] = [:]
    ) -> MeetingProcessingCheckpoint {
        MeetingProcessingCheckpoint(
            version: MeetingProcessingCheckpoint.currentVersion,
            sessionID: sessionID,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: "apple",
            asrModel: "base",
            languageCode: "en",
            completedTrackID: completedTrackID,
            trackFingerprints: trackFingerprints,
            speakers: [],
            segments: [],
            remoteSpeech: [MeetingProcessingCheckpoint.SpeechInterval(start: 0, end: 1.5)],
            speakerIDByKey: ["remote-cluster:x": UUID()],
            nextRemoteSpeaker: 2,
            nextMicrophoneSpeaker: 1
        )
    }

    // MARK: - Slice 3, test 1: checkpoint round-trip

    func testCheckpointRoundTripEncodesAndDecodesEqual() throws {
        let checkpoint = self.makeCheckpoint(trackFingerprints: [
            UUID(): [MeetingProcessingCheckpoint.ChunkFingerprint(id: UUID(), byteCount: 100, sha256: "abc")],
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(checkpoint)
        let decoded = try decoder.decode(MeetingProcessingCheckpoint.self, from: data)
        XCTAssertEqual(decoded, checkpoint)
    }

    // MARK: - Slice 3, test 2: checkpoint validity matrix

    func testCheckpointValidityMatrix() throws {
        let session = self.makeSession(state: .interrupted, endedAt: Date())
        let trackID = UUID()
        let fingerprint = MeetingProcessingCheckpoint.ChunkFingerprint(id: UUID(), byteCount: 128, sha256: "abc123")
        let fingerprints: [MeetingAudioTrackID: [MeetingProcessingCheckpoint.ChunkFingerprint]] = [trackID: [fingerprint]]
        let checkpoint = self.makeCheckpoint(sessionID: session.id, completedTrackID: trackID, trackFingerprints: fingerprints)

        func isValid(
            pipelineVersion: Int = MeetingProcessingPipeline.pipelineVersion,
            provider: String = "apple",
            model: String = "base",
            language: String = "en",
            completedTrackID: MeetingAudioTrackID = trackID,
            expectedFingerprints: [MeetingAudioTrackID: [MeetingProcessingCheckpoint.ChunkFingerprint]] = fingerprints,
            session: MeetingSession = session
        ) -> Bool {
            checkpoint.isValid(
                session: session,
                pipelineVersion: pipelineVersion,
                provider: provider,
                model: model,
                language: language,
                completedTrackID: completedTrackID,
                expectedFingerprints: expectedFingerprints
            )
        }

        XCTAssertTrue(isValid())
        XCTAssertFalse(isValid(pipelineVersion: MeetingProcessingPipeline.pipelineVersion + 1))
        XCTAssertFalse(isValid(provider: "other"))
        XCTAssertFalse(isValid(model: "other"))
        XCTAssertFalse(isValid(language: "fr"))
        XCTAssertFalse(isValid(completedTrackID: UUID()))
        var otherSession = session
        otherSession.id = UUID()
        XCTAssertFalse(isValid(session: otherSession))

        var mutatedByteCount = fingerprints
        mutatedByteCount[trackID]?[0].byteCount = 999
        XCTAssertFalse(isValid(expectedFingerprints: mutatedByteCount))

        var mutatedSha = fingerprints
        mutatedSha[trackID]?[0].sha256 = "different"
        XCTAssertFalse(isValid(expectedFingerprints: mutatedSha))

        var extraChunk = fingerprints
        extraChunk[trackID]?.append(MeetingProcessingCheckpoint.ChunkFingerprint(id: UUID(), byteCount: 1, sha256: "x"))
        XCTAssertFalse(isValid(expectedFingerprints: extraChunk))

        XCTAssertFalse(isValid(expectedFingerprints: [trackID: []]))

        var versionMismatch = checkpoint
        versionMismatch.version = MeetingProcessingCheckpoint.currentVersion + 1
        XCTAssertFalse(versionMismatch.isValid(
            session: session,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            provider: "apple",
            model: "base",
            language: "en",
            completedTrackID: trackID,
            expectedFingerprints: fingerprints
        ))
    }

    // MARK: - Slice 3, test 3: coordinator deletes checkpoint after success

    func testCoordinatorDeletesCheckpointAfterProcessingSuccess() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let checkpointURL = sessionDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
        try Data("{}".utf8).write(to: checkpointURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        let result = try await coordinator.retryProcessing()

        XCTAssertEqual(result.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
    }

    // MARK: - Slice 3, test 4: checkpoint survives a failed retry

    func testCheckpointSurvivesProcessingFailure() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let checkpointURL = sessionDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
        try Data("{}".utf8).write(to: checkpointURL)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: ThrowingProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        do {
            _ = try await coordinator.retryProcessing()
            XCTFail("Expected retryProcessing to throw")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))
    }

    // MARK: - Slice 3, test 5: skipped-chunk event and chunk failure marking

    func testSkippedChunksProduceEventAndMarkChunksFailed() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let chunk = self.makeFinalizedChunk(sequence: 0, path: "tracks/microphone/chunk_0.caf")
        // A second finalized chunk keeps the skip count below the total, so the
        // success+skip combination this test asserts is actually realizable.
        let survivingChunk = self.makeFinalizedChunk(sequence: 1, path: "tracks/microphone/chunk_1.caf")
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [chunk, survivingChunk])]
        )
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: SkippedChunkProcessingController(skippedChunkIDs: [chunk.id]),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        let result = try await coordinator.retryProcessing()

        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.events.contains {
            $0.detail == "1 audio chunk(s) could not be read and were skipped."
        })
        let persistedChunk = result.audioTracks.first?.chunks.first(where: { $0.id == chunk.id })
        XCTAssertEqual(persistedChunk?.finalizationState, .failed)
        let persistedSurvivor = result.audioTracks.first?.chunks.first(where: { $0.id == survivingChunk.id })
        XCTAssertEqual(persistedSurvivor?.finalizationState, .finalized)

        let reloaded = try await store.load(id: session.id)
        let reloadedChunk = reloaded?.audioTracks.first?.chunks.first(where: { $0.id == chunk.id })
        XCTAssertEqual(reloadedChunk?.finalizationState, .failed)
    }

    // MARK: - Slice 3, test 6: unreadable-chunk classification

    // MARK: - Regression: arbiter failure during history retry must not strand activeSession

    func testRetryByIDArbiterFailureDoesNotStrandActiveSession() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let now = Date()
        let older = self.makeSession(
            state: .interrupted,
            startedAt: now.addingTimeInterval(-600),
            endedAt: now.addingTimeInterval(-590),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let newer = self.makeSession(
            state: .interrupted,
            startedAt: now.addingTimeInterval(-60),
            endedAt: now.addingTimeInterval(-50),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(older)
        try await store.create(newer)

        let arbiter = ThrowOnceArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: arbiter
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, newer.id)

        do {
            _ = try await coordinator.retryProcessing(sessionID: older.id)
            XCTFail("Expected retryProcessing to throw when the arbiter refuses the lease")
        } catch {}

        // Not wedged: the passive offer was never displaced/adopted, so state and activeSession
        // stay consistent with each other instead of activeSession != nil with state == .idle.
        XCTAssertEqual(coordinator.activeSession?.id, newer.id)
        XCTAssertEqual(coordinator.state, .interrupted(newer.id))

        // A subsequent recording is not permanently blocked by a stranded activeSession.
        try coordinator.resetForNewMeeting()
        for _ in 0..<40 {
            if let persisted = try await store.load(id: newer.id), persisted.recoveryResolvedAt != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // `older` was never resolved (the failed retry targeted it but never adopted it); clear
        // it too so a fresh coordinator's restore scan has nothing left to re-offer.
        try await store.delete(id: older.id)
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let workingCoordinator = MeetingSessionCoordinator(
            store: store,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        let started = try await workingCoordinator.startRecording(configuration: self.makeConfiguration(title: "Recovered"))
        guard case .recording = workingCoordinator.state else {
            return XCTFail("Expected .recording, got \(workingCoordinator.state)")
        }
        XCTAssertEqual(workingCoordinator.activeSession?.id, started.id)
    }

    // MARK: - Regression: deleteSession re-checks quiescence after the persistence flush

    func testDeleteSessionBlocksRetryUntilComplete() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedDeleteStore(inner: realStore, recorder: recorder)
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        let deleteTask = Task { try await coordinator.deleteSession(id: session.id) }

        for _ in 0..<40 {
            if await recorder.events.contains("store.delete.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsSoFar = await recorder.events
        XCTAssertTrue(eventsSoFar.contains("store.delete.start"))

        do {
            _ = try await coordinator.retryProcessing(sessionID: session.id)
            XCTFail("Expected retryProcessing to throw while deleteSession is mid-flight")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        await gatedStore.openGate()
        try await deleteTask.value

        XCTAssertNil(coordinator.activeSession)
        let reloaded = try? await realStore.load(id: session.id)
        XCTAssertNil(reloaded)
    }

    func testReadSamplesThrowsAudioUnreadableForGarbageFile() throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("garbage.m4a", isDirectory: false)
        try Data((0..<256).map { _ in UInt8.random(in: 0...255) }).write(to: url)

        XCTAssertThrowsError(
            try MeetingProcessingPipeline.readSamples(fileURL: url, startSeconds: 0, endSeconds: nil)
        ) { error in
            guard case MeetingProcessingError.audioUnreadable = error else {
                XCTFail("Expected .audioUnreadable, got \(error)")
                return
            }
        }
    }

    // MARK: - Transcript corrections: persistence, undo, gating

    func testEachCorrectionOpOnHistorySessionPersists() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, segmentID) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed A")
        var reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded?.speakers.first(where: { $0.id == speakerA })?.displayName, "Renamed A")

        _ = try await coordinator.reassignSegment(sessionID: session.id, segmentID: segmentID, to: speakerB)
        reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded?.transcriptSegments.first(where: { $0.id == segmentID })?.speakerID, speakerB)

        _ = try await coordinator.mergeSpeakers(sessionID: session.id, source: speakerB, into: speakerA)
        reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded?.speakers.first(where: { $0.id == speakerB })?.mergedIntoSpeakerID, speakerA)
        XCTAssertEqual(reloaded?.transcriptSegments.first(where: { $0.id == segmentID })?.speakerID, speakerA)

        // A history-scoped correction never adopts the session into a coordinator slot.
        XCTAssertNil(coordinator.activeSession)
        XCTAssertNil(coordinator.latestCompletedSession)
    }

    func testUndoRestoresExactPriorStateForEachCorrectionType() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, segmentID) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
        var undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.speakers, session.speakers)
        XCTAssertEqual(undone.transcriptSegments, session.transcriptSegments)

        _ = try await coordinator.reassignSegment(sessionID: session.id, segmentID: segmentID, to: speakerB)
        undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.speakers, session.speakers)
        XCTAssertEqual(undone.transcriptSegments, session.transcriptSegments)

        _ = try await coordinator.mergeSpeakers(sessionID: session.id, source: speakerA, into: speakerB)
        undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.speakers, session.speakers)
        XCTAssertEqual(undone.transcriptSegments, session.transcriptSegments)

        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testFailedCorrectionSaveLeavesNoUndoEntryAndDiskUnchanged() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.throwOnNextSave()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        do {
            _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
            XCTFail("Expected the save failure to propagate")
        } catch {}

        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
        let reloaded = try await realStore.load(id: session.id)
        XCTAssertEqual(reloaded?.speakers.first(where: { $0.id == speakerA })?.displayName, "Speaker A")
    }

    func testFailedUndoSaveRePushesCorrectionAndCanUndoStaysTrue() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))

        await gatedStore.throwOnNextSave()
        do {
            _ = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
            XCTFail("Expected the undo save failure to propagate")
        } catch {}

        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))
        let reloaded = try await realStore.load(id: session.id)
        XCTAssertEqual(reloaded?.speakers.first(where: { $0.id == speakerA })?.displayName, "Renamed")

        let undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.speakers.first(where: { $0.id == speakerA })?.displayName, "Speaker A")
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testCorrectionRefusedWhileProcessingSameSession() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .interrupted)
        try await store.create(session)

        let processing = GatedProcessingController()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: processing, audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        let retryTask = Task { try await coordinator.retryProcessing(sessionID: session.id) }

        for _ in 0..<40 {
            if case .processing = coordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = coordinator.state else {
            return XCTFail("retryProcessing did not reach .processing")
        }

        do {
            _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
            XCTFail("Expected correction to throw while processing")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        processing.openGate()
        _ = try await retryTask.value
    }

    func testSecondCorrectionRefusedWhileFirstInFlight() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let firstTask = Task { try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "First") }

        for _ in 0..<40 {
            if await recorder.events.contains("store.save.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsSoFar = await recorder.events
        XCTAssertTrue(eventsSoFar.contains("store.save.start"))

        do {
            _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerB, to: "Second")
            XCTFail("Expected the second correction to throw while the first is in flight")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        await gatedStore.openGate()
        _ = try await firstTask.value
    }

    func testRetryByIDRefusedWhileCorrectionIsParked() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .interrupted)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        // Restore first (it saves the reclassified session itself) so closing the gate below
        // only blocks the correction's save, not ensureRestored's own.
        await coordinator.ensureRestored()
        await gatedStore.closeGate()

        let correctionTask = Task { try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Held") }

        for _ in 0..<40 {
            if await recorder.events.contains("store.save.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsAfterParking = await recorder.events
        XCTAssertTrue(eventsAfterParking.contains("store.save.start"))

        do {
            _ = try await coordinator.retryProcessing(sessionID: session.id)
            XCTFail("Expected retryProcessing to throw while a correction is parked")
        } catch let error as MeetingCoordinatorError {
            // O3: the mutation gate, not real activity, is the blocker here.
            guard case .maintenanceInProgress = error else {
                return XCTFail("Expected .maintenanceInProgress, got \(error)")
            }
        }

        await gatedStore.openGate()
        _ = try await correctionTask.value
    }

    func testDeleteSessionRefusedWhileCorrectionInFlightAndCorrectionRefusedWhileDeleting() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        // Part 1: deleteSession refused while a correction is in flight.
        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let correctionTask = Task { try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Held") }
        for _ in 0..<40 {
            if await recorder.events.contains("store.save.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsAfterParking = await recorder.events
        XCTAssertTrue(eventsAfterParking.contains("store.save.start"))

        do {
            try await coordinator.deleteSession(id: session.id)
            XCTFail("Expected deleteSession to throw while a correction is in flight")
        } catch let error as MeetingCoordinatorError {
            guard case .maintenanceInProgress = error else {
                return XCTFail("Expected .maintenanceInProgress, got \(error)")
            }
        }

        await gatedStore.openGate()
        _ = try await correctionTask.value

        // Part 2: correction refused while a delete is mid-flight (isDeleting).
        let deleteGateStore = GatedDeleteStore(inner: realStore, recorder: recorder)
        let deleteCoordinator = MeetingSessionCoordinator(
            store: deleteGateStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let deleteTask = Task { try await deleteCoordinator.deleteSession(id: session.id) }
        for _ in 0..<40 {
            if await recorder.events.contains("store.delete.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsAfterDeleteStart = await recorder.events
        XCTAssertTrue(eventsAfterDeleteStart.contains("store.delete.start"))

        do {
            _ = try await deleteCoordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "During delete")
            XCTFail("Expected correction to throw while deleteSession is mid-flight")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        await deleteGateStore.openGate()
        try await deleteTask.value
    }

    // MARK: - Regression: correction flushes a queued stale-copy persistence before mutating

    func testCorrectionFlushesQueuedPersistenceBeforeMutating() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .interrupted)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        // Dismiss the active offer: enqueues a stale-copy persistence write stamping recoveryResolvedAt.
        try coordinator.resetForNewMeeting()

        let corrected = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
        XCTAssertEqual(corrected.speakers.first(where: { $0.id == speakerA })?.displayName, "Renamed")

        let reloaded = try await store.load(id: session.id)
        XCTAssertNotNil(reloaded?.recoveryResolvedAt)
        XCTAssertEqual(reloaded?.speakers.first(where: { $0.id == speakerA })?.displayName, "Renamed")
    }

    func testUndoStackClearedByRetryProcessing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .interrupted)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()

        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))

        _ = try await coordinator.retryProcessing(sessionID: session.id)
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testArbiterThrowingRetryLeavesUndoStackIntact() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .interrupted)
        try await store.create(session)

        let arbiter = ThrowOnceArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: arbiter
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))

        do {
            _ = try await coordinator.retryProcessing()
            XCTFail("Expected retryProcessing to throw when the arbiter refuses the lease")
        } catch {}

        XCTAssertTrue(
            coordinator.canUndoCorrection(sessionID: session.id),
            "a lease failure before the undo stack is cleared must leave the prior correction undoable"
        )
    }

    func testUndoStackCapsAt50Entries() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        for index in 0..<51 {
            _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Name \(index)")
        }

        var undoCount = 0
        while coordinator.canUndoCorrection(sessionID: session.id) {
            _ = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
            undoCount += 1
        }
        XCTAssertEqual(undoCount, 50)
    }

    // MARK: - Audio retention & delete audio

    private func withRetentionPolicy<T>(
        _ policy: MeetingAudioRetentionPolicy,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let previous = SettingsStore.shared.meetingAudioRetentionPolicy
        SettingsStore.shared.meetingAudioRetentionPolicy = policy
        // Belt-and-suspenders: a mid-test crash still restores the developer's real setting.
        self.addTeardownBlock { SettingsStore.shared.meetingAudioRetentionPolicy = previous }
        defer { SettingsStore.shared.meetingAudioRetentionPolicy = previous }
        return try await body()
    }

    func testDeleteAudioClearsFilesAndChunksKeepsTranscriptIdempotent() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let tracksURL = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)
        let checkpointURL = sessionDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
        try Data("{}".utf8).write(to: checkpointURL)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let result = try await coordinator.deleteAudio(sessionID: session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tracksURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("session.json").path))
        XCTAssertNotNil(result.retention.audioDeletedAt)
        XCTAssertTrue(result.audioTracks.allSatisfy { $0.chunks.isEmpty })
        XCTAssertFalse(result.hasRetryableAudio)
        XCTAssertEqual(result.transcriptSegments.count, session.transcriptSegments.count)

        // Idempotent: a second call is a no-op, not a throw. (The reloaded copy round-trips
        // through ISO8601 seconds-precision, so compare with a sub-second tolerance.)
        let second = try await coordinator.deleteAudio(sessionID: session.id)
        let firstDeletedAt = try XCTUnwrap(result.retention.audioDeletedAt)
        let secondDeletedAt = try XCTUnwrap(second.retention.audioDeletedAt)
        XCTAssertEqual(secondDeletedAt.timeIntervalSince1970, firstDeletedAt.timeIntervalSince1970, accuracy: 1.0)
    }

    func testSweepHealsLeftoverAudioAfterManifestFirstCrash() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let tracksURL = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracksURL.path))

        // Simulate the crash window: the cleared manifest was saved, but file removal never ran —
        // leave an actual leftover file behind (an empty recreated tracks/ is not a leftover).
        var cleared = session
        for index in cleared.audioTracks.indices { cleared.audioTracks[index].chunks = [] }
        cleared.retention.audioDeletedAt = Date()
        try await store.save(cleared)
        try Data("leftover".utf8).write(to: tracksURL.appendingPathComponent("stray.caf", isDirectory: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracksURL.path))

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.sweepExpiredAudio()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tracksURL.path))
    }

    /// O9: a `tracks/` directory recreated empty by `store.save`/`sessionDirectory` is not a
    /// leftover from the manifest-first crash window and must not trigger a heal.
    func testSweepDoesNotHealAnEmptyRecreatedTracksDirectory() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let tracksURL = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)

        var cleared = session
        for index in cleared.audioTracks.indices { cleared.audioTracks[index].chunks = [] }
        cleared.retention.audioDeletedAt = Date()
        try await store.save(cleared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracksURL.path))
        let contentsBeforeSweep = try FileManager.default.contentsOfDirectory(atPath: tracksURL.path)
        XCTAssertTrue(contentsBeforeSweep.isEmpty)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.sweepExpiredAudio()

        XCTAssertTrue(FileManager.default.fileExists(atPath: tracksURL.path), "an empty tracks/ dir is not a leftover to heal")
    }

    func testAudioDeletedAtIsAuthoritativeAcrossLoadAndRecoverable() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let session = self.makeSession(state: .interrupted, endedAt: Date(), audioTracks: [track])
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let tracksURL = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)

        // Simulate the crash window: the cleared manifest was saved, but tracks/ removal never ran.
        var cleared = session
        for index in cleared.audioTracks.indices { cleared.audioTracks[index].chunks = [] }
        cleared.retention.audioDeletedAt = Date()
        try await store.save(cleared)

        // Recreate the leftover track.json with the OLD (pre-clear) chunks — store.load's
        // reconciliation must not re-import from it once audioDeletedAt is set.
        let trackManifestDirectory = tracksURL.appendingPathComponent("microphone", isDirectory: true)
        try FileManager.default.createDirectory(at: trackManifestDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(track).write(to: trackManifestDirectory.appendingPathComponent("track.json", isDirectory: false))

        let reloaded = try await store.load(id: session.id)
        XCTAssertTrue(
            reloaded?.audioTracks.allSatisfy { $0.chunks.isEmpty } == true,
            "audioDeletedAt must be authoritative: never re-import a leftover manifest's chunks"
        )

        let recoverable = try await store.loadRecoverable()
        XCTAssertFalse(
            recoverable.contains(where: { $0.id == session.id }),
            "a session with audio already deleted must never be offered as recoverable, even though it's otherwise .interrupted"
        )
    }

    func testSweepEligibilityMatrix() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let past = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let future = Date()

        let completedPast = self.makeSession(
            state: .completed, startedAt: past, endedAt: past,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let completedFuture = self.makeSession(
            state: .completed, startedAt: future, endedAt: future,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let interruptedUnresolvedPast = self.makeSession(
            state: .interrupted, startedAt: past, endedAt: past,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let failedResolvedPast = self.makeSession(
            state: .failed, startedAt: past, endedAt: past,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])],
            recoveryResolvedAt: Date()
        )
        let failedUnresolvedPast = self.makeSession(
            state: .failed, startedAt: past, endedAt: past,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        for session in [completedPast, completedFuture, interruptedUnresolvedPast, failedResolvedPast, failedUnresolvedPast] {
            try await store.create(session)
        }

        try await self.withRetentionPolicy(.days7) {
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.sweepExpiredAudio()

            let reloadedCompletedPast = try await store.load(id: completedPast.id)
            let reloadedCompletedFuture = try await store.load(id: completedFuture.id)
            let reloadedInterrupted = try await store.load(id: interruptedUnresolvedPast.id)
            let reloadedFailedResolved = try await store.load(id: failedResolvedPast.id)
            let reloadedFailedUnresolved = try await store.load(id: failedUnresolvedPast.id)

            XCTAssertNotNil(reloadedCompletedPast?.retention.audioDeletedAt, "completed + past deadline must be swept")
            XCTAssertNil(reloadedCompletedFuture?.retention.audioDeletedAt, "completed + future deadline must be kept")
            XCTAssertNil(reloadedInterrupted?.retention.audioDeletedAt, "unresolved interrupted must never be swept")
            XCTAssertNotNil(reloadedFailedResolved?.retention.audioDeletedAt, "failed + resolved + past deadline must be swept")
            XCTAssertNil(reloadedFailedUnresolved?.retention.audioDeletedAt, "failed + unresolved + past deadline must never be swept")
        }
    }

    func testNeverPolicySweepsNothingAndAfterTranscriptionSweepsImmediately() async throws {
        let dir1 = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir1) }
        let store1 = MeetingSessionStore(rootDirectory: dir1)
        let veryOld = self.makeSession(
            state: .completed,
            startedAt: Date(timeIntervalSinceNow: -365 * 24 * 60 * 60),
            endedAt: Date(timeIntervalSinceNow: -365 * 24 * 60 * 60),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store1.create(veryOld)
        try await self.withRetentionPolicy(.never) {
            let coordinator = MeetingSessionCoordinator(
                store: store1, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.sweepExpiredAudio()
            let reloaded = try await store1.load(id: veryOld.id)
            XCTAssertNil(reloaded?.retention.audioDeletedAt)
        }

        let dir2 = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let store2 = MeetingSessionStore(rootDirectory: dir2)
        let justCompleted = self.makeSession(
            state: .completed, startedAt: Date(), endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store2.create(justCompleted)
        try await self.withRetentionPolicy(.afterTranscription) {
            let coordinator = MeetingSessionCoordinator(
                store: store2, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.sweepExpiredAudio()
            let reloaded = try await store2.load(id: justCompleted.id)
            XCTAssertNotNil(reloaded?.retention.audioDeletedAt)
        }
    }

    func testRetentionIsAppliedRetroactivelyFromCurrentPolicy() async throws {
        // 10 days old: past the 7-day deadline, still under the 30-day one.
        let endedAt = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        for (policy, expectSwept) in [(MeetingAudioRetentionPolicy.days30, false), (.days7, true)] {
            let dir = self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = MeetingSessionStore(rootDirectory: dir)
            let session = self.makeSession(
                state: .completed, startedAt: endedAt, endedAt: endedAt,
                audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
            )
            try await store.create(session)

            try await self.withRetentionPolicy(policy) {
                let coordinator = MeetingSessionCoordinator(
                    store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
                )
                await coordinator.sweepExpiredAudio()
                let reloaded = try await store.load(id: session.id)
                if expectSwept {
                    XCTAssertNotNil(reloaded?.retention.audioDeletedAt, "\(policy) should sweep a 10-day-old session")
                } else {
                    XCTAssertNil(reloaded?.retention.audioDeletedAt, "\(policy) should keep a 10-day-old session")
                }
            }
        }
    }

    func testAfterTranscriptionPolicyDeletesAudioThroughRealProcessSuccessPath() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted, endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let tracksURL = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracksURL.path))

        try await self.withRetentionPolicy(.afterTranscription) {
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.ensureRestored()
            let result = try await coordinator.retryProcessing()
            XCTAssertEqual(result.state, .completed)

            // process()'s success path enqueues sweepExpiredAudio as a detached Task; poll for it.
            var reloaded: MeetingSession?
            for _ in 0..<80 {
                reloaded = try await store.load(id: session.id)
                if reloaded?.retention.audioDeletedAt != nil { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotNil(reloaded?.retention.audioDeletedAt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: tracksURL.path))
        }
    }

    func testDeleteAudioRefusedWhileProcessing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted, endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let gatedProcessing = GatedProcessingController()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: gatedProcessing, audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        let retryTask = Task { try await coordinator.retryProcessing() }

        for _ in 0..<40 {
            if case .processing = coordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = coordinator.state else {
            return XCTFail("retryProcessing did not reach .processing")
        }

        do {
            _ = try await coordinator.deleteAudio(sessionID: session.id)
            XCTFail("Expected deleteAudio to throw while processing")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        gatedProcessing.openGate()
        _ = try await retryTask.value
    }

    func testSweepPendingFlagRunsOnceTheMutationGateReleases() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        // Force the session past its retention deadline so a run of the sweep deletes its audio.
        var expired = session
        expired.startedAt = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        expired.endedAt = expired.startedAt
        try await realStore.create(expired)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        try await self.withRetentionPolicy(.days7) {
            let correctionTask = Task { try await coordinator.renameSpeaker(sessionID: expired.id, speakerID: speakerA, to: "Held") }

            for _ in 0..<40 {
                if await recorder.events.contains("store.save.start") { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let hasSaveStarted = await recorder.events.contains("store.save.start")
            XCTAssertTrue(hasSaveStarted)

            await coordinator.sweepExpiredAudio() // gate held: must be a no-op right now, marks pending instead
            let reloadedWhileHeld = try await realStore.load(id: expired.id)
            XCTAssertNil(reloadedWhileHeld?.retention.audioDeletedAt, "the sweep must not run while the gate is held")

            await gatedStore.openGate()
            _ = try await correctionTask.value

            // The correction's gate release reschedules the pending sweep as a detached Task; poll for it.
            var reloadedAfterRelease: MeetingSession?
            for _ in 0..<80 {
                reloadedAfterRelease = try await realStore.load(id: expired.id)
                if reloadedAfterRelease?.retention.audioDeletedAt != nil { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotNil(reloadedAfterRelease?.retention.audioDeletedAt, "a pending sweep must run once the mutation gate is released")
        }
    }

    func testDeleteAudioLeavesSessionFailingTheFreshLoadExportGuard() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        _ = try await coordinator.deleteAudio(sessionID: session.id)

        // Mirrors MeetingTranscriptionView.exportAudio's fresh-load guard: it reloads via
        // store.load and refuses to export when either condition below holds.
        let fresh = try await store.load(id: session.id)
        let hasFinalizedAudio = (fresh?.audioTracks ?? []).flatMap(\.chunks).contains {
            $0.finalizationState == .finalized && $0.byteCount > 0
        }
        XCTAssertNotNil(fresh?.retention.audioDeletedAt)
        XCTAssertFalse(hasFinalizedAudio)
    }

    // MARK: - ASR activity arbiter

    func testArbiterDoubleAcquireThrowsRecordingAlreadyActive() throws {
        let leasing = FakeASRActivityLeasing()
        let arbiter = AudioActivityArbiter { leasing }

        _ = try arbiter.acquireMeetingCapture()
        XCTAssertThrowsError(try arbiter.acquireMeetingCapture()) { error in
            guard case MeetingCoordinatorError.recordingAlreadyActive = error else {
                return XCTFail("Expected .recordingAlreadyActive, got \(error)")
            }
        }
        XCTAssertEqual(leasing.acquireCount, 1)
    }

    func testArbiterReleaseThenReacquireSucceeds() throws {
        let leasing = FakeASRActivityLeasing()
        let arbiter = AudioActivityArbiter { leasing }

        let lease = try arbiter.acquireMeetingCapture()
        arbiter.release(lease)
        XCTAssertEqual(leasing.releaseCount, 1)

        let reacquired = try arbiter.acquireMeetingCapture()
        XCTAssertNotEqual(lease, reacquired)
        XCTAssertEqual(leasing.acquireCount, 2)
    }

    func testArbiterReleaseWithStaleLeaseIsNoOp() throws {
        let leasing = FakeASRActivityLeasing()
        let arbiter = AudioActivityArbiter { leasing }

        let lease = try arbiter.acquireMeetingCapture()
        arbiter.release(MeetingAudioActivityLease(id: UUID())) // stale, not the held lease
        XCTAssertEqual(leasing.releaseCount, 0, "a stale lease must not release the real ASR activity")

        arbiter.release(lease)
        XCTAssertEqual(leasing.releaseCount, 1)
    }

    func testArbiterProviderThrowingLeavesCoordinatorStateUntouched() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let arbiter = AudioActivityArbiter { throw MeetingCoordinatorError.dictationActive }
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: arbiter
        )

        do {
            _ = try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Blocked"))
            XCTFail("Expected startRecording to throw when the ASR provider is unavailable")
        } catch {}

        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(coordinator.state, .idle)
    }

    // MARK: - Final-review regressions (O1/O2/O3/O4/O5/O10)

    /// O1: `resetForNewMeeting` enqueues a fire-and-forget save stamping `recoveryResolvedAt`;
    /// a sweep that races it must flush that queued write before reading sessions from disk, or
    /// it sees the pre-stamp copy and skips a session that's actually eligible.
    func testSweepFlushesQueuedPersistenceBeforeReadingSessionsOnDisk() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let session = self.makeSession(state: .interrupted, endedAt: Date(timeIntervalSinceNow: -10), audioTracks: [track])
        try await realStore.create(session)

        try await self.withRetentionPolicy(.afterTranscription) {
            let recorder = EventRecorder()
            let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
            let coordinator = MeetingSessionCoordinator(
                store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.ensureRestored()
            XCTAssertEqual(coordinator.activeSession?.id, session.id)

            await gatedStore.closeGate()
            let saveCountBeforeReset = await recorder.events.filter { $0 == "store.save.start" }.count
            // Enqueues the recoveryResolvedAt stamp (parked at the gate) and schedules a sweep.
            try coordinator.resetForNewMeeting()

            for _ in 0..<40 {
                let count = await recorder.events.filter { $0 == "store.save.start" }.count
                if count > saveCountBeforeReset { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            await gatedStore.openGate()

            var persisted: MeetingSession?
            for _ in 0..<60 {
                persisted = try await realStore.load(id: session.id)
                if persisted?.retention.audioDeletedAt != nil { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotNil(persisted?.recoveryResolvedAt, "the queued stamp must have landed")
            XCTAssertNotNil(persisted?.retention.audioDeletedAt, "the sweep must have seen the stamped copy, not a stale one")
            XCTAssertTrue(persisted?.audioTracks.allSatisfy { $0.chunks.isEmpty } ?? false)
        }
    }

    /// O3: when the mutation gate (not real capture/stop/retry activity) is the only blocker,
    /// startRecording must surface the more honest `.maintenanceInProgress`.
    func testStartRecordingThrowsMaintenanceInProgressWhileGateHeld() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let correctionTask = Task { try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Held") }
        for _ in 0..<40 {
            if await recorder.events.contains("store.save.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        do {
            _ = try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Blocked"))
            XCTFail("Expected startRecording to throw while the mutation gate is held")
        } catch let error as MeetingCoordinatorError {
            guard case .maintenanceInProgress = error else {
                return XCTFail("Expected .maintenanceInProgress, got \(error)")
            }
        }

        await gatedStore.openGate()
        _ = try await correctionTask.value
    }

    /// O2: termination must not spin forever behind a parked correction/audio-mutation save;
    /// it waits a bounded amount of time and then proceeds regardless.
    func testShutdownForTerminationCompletesWhileCorrectionIsParked() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let correctionTask = Task { try? await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Held") }
        for _ in 0..<40 {
            if await recorder.events.contains("store.save.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // The gate never opens here; returning at all (instead of hanging) is the assertion.
        await coordinator.shutdownForTermination()

        await gatedStore.openGate()
        _ = try? await correctionTask.value
    }

    /// O10: the retention timer is scheduled when a future deadline exists and cleared otherwise.
    func testHasScheduledRetentionSweepReflectsTimerState() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let session = self.makeSession(state: .completed, endedAt: Date(), audioTracks: [track])
        try await store.create(session)

        try await self.withRetentionPolicy(.days7) {
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.sweepExpiredAudio()
            XCTAssertTrue(coordinator.hasScheduledRetentionSweep, "a 7-day deadline is in the future and should be scheduled")
        }

        try await self.withRetentionPolicy(.never) {
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.sweepExpiredAudio()
            XCTAssertFalse(coordinator.hasScheduledRetentionSweep, "policy .never has no deadline to schedule against")
        }
    }

    /// O5: renaming a speaker to its current name must be a true no-op — no save, no undo entry.
    func testNoOpRenameDoesNotPushUndoOrTouchStore() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let before = try await store.load(id: session.id)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        let currentName = try XCTUnwrap(before?.speakers.first(where: { $0.id == speakerA })?.displayName)

        let result = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: currentName)
        XCTAssertEqual(result, before)
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))

        let reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded, before)
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
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
        try await self.wrapped.existingSessionDirectory(for: id)
    }
    func delete(id: MeetingSessionID) async throws { try await self.wrapped.delete(id: id) }
    func deleteAudioFiles(for id: MeetingSessionID) async throws { try await self.wrapped.deleteAudioFiles(for: id) }
}

private actor EventRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { self.events.append(event) }
}

private final class StubCaptureController: MeetingCaptureControlling, @unchecked Sendable {
    var startResult = MeetingCaptureStartResult(tracks: [], firstPresentationTime: nil)
    var startError: Error?
    var onStart: (@Sendable () async -> Void)?

    func start(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration,
        sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void
    ) async throws -> MeetingCaptureStartResult {
        await self.onStart?()
        if let startError { throw startError }
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

private struct ProcessingFailure: Error {}

@MainActor
private final class ThrowingProcessingController: MeetingProcessingControlling {
    func process(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        throw ProcessingFailure()
    }
}

@MainActor
private final class SkippedChunkProcessingController: MeetingProcessingControlling {
    private let skippedChunkIDs: [MeetingAudioChunkID]

    init(skippedChunkIDs: [MeetingAudioChunkID]) {
        self.skippedChunkIDs = skippedChunkIDs
    }

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
            ),
            skippedChunkIDs: self.skippedChunkIDs
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

/// Records acquire/release calls without touching a real ASRService.
@MainActor
private final class FakeASRActivityLeasing: ASRActivityLeasing {
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private var activeLease: ASRActivityLease?

    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease {
        self.acquireCount += 1
        guard self.activeLease == nil else {
            throw ASRActivityError.activityInProgress(activity)
        }
        let lease = ASRActivityLease(id: UUID(), activity: activity)
        self.activeLease = lease
        return lease
    }

    func releaseExclusiveActivity(_ lease: ASRActivityLease) {
        guard self.activeLease == lease else { return }
        self.releaseCount += 1
        self.activeLease = nil
    }
}

/// Throws on the first `acquireMeetingCapture()` call, then succeeds on every subsequent call.
@MainActor
private final class ThrowOnceArbiter: MeetingAudioActivityArbitrating {
    private var hasThrown = false
    func acquireMeetingCapture() throws -> MeetingAudioActivityLease {
        guard self.hasThrown else {
            self.hasThrown = true
            throw MeetingCoordinatorError.dictationActive
        }
        return MeetingAudioActivityLease(id: UUID())
    }
    func release(_ lease: MeetingAudioActivityLease) {}
}

/// Wraps a real `MeetingSessionStore`, suspending `delete(id:)` until `openGate()` is called —
/// used to hold `deleteSession` mid-flight so a racing retry can be observed.
private actor GatedDeleteStore: MeetingSessionStoring {
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
    func loadRecoverable() async throws -> [MeetingSession] { try await self.inner.loadRecoverable() }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL { try await self.inner.sessionDirectory(for: id) }
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
        try await self.inner.existingSessionDirectory(for: id)
    }
    func delete(id: MeetingSessionID) async throws {
        await self.recorder.record("store.delete.start")
        if !self.isOpen {
            await withCheckedContinuation { self.continuation = $0 }
        }
        try await self.inner.delete(id: id)
    }
    func deleteAudioFiles(for id: MeetingSessionID) async throws { try await self.inner.deleteAudioFiles(for: id) }
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
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
        try await self.inner.existingSessionDirectory(for: id)
    }
    func delete(id: MeetingSessionID) async throws { try await self.inner.delete(id: id) }
    func deleteAudioFiles(for id: MeetingSessionID) async throws { try await self.inner.deleteAudioFiles(for: id) }

    func loadRecoverable() async throws -> [MeetingSession] {
        await self.recorder.record("restore.loadRecoverable.start")
        if !self.isOpen {
            await withCheckedContinuation { self.continuation = $0 }
        }
        return try await self.inner.loadRecoverable()
    }
}

/// Wraps a real `MeetingSessionStore`; `save(_:)` records a "store.save.start" event, then either
/// throws a queued failure or (until `openGate()`) suspends — used to test performCorrection's
/// commit-only-on-save discipline and the single-in-flight-correction gate.
private actor GatedThrowingSaveStore: MeetingSessionStoring {
    private let inner: MeetingSessionStore
    private let recorder: EventRecorder
    private var isOpen = true
    private var continuation: CheckedContinuation<Void, Never>?
    private var throwOnNextSaveCount = 0

    init(inner: MeetingSessionStore, recorder: EventRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func throwOnNextSave(_ count: Int = 1) { self.throwOnNextSaveCount = count }
    func closeGate() { self.isOpen = false }
    func openGate() {
        self.isOpen = true
        self.continuation?.resume()
        self.continuation = nil
    }

    func create(_ session: MeetingSession) async throws { try await self.inner.create(session) }

    func save(_ session: MeetingSession) async throws {
        await self.recorder.record("store.save.start")
        if self.throwOnNextSaveCount > 0 {
            self.throwOnNextSaveCount -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        if !self.isOpen {
            await withCheckedContinuation { self.continuation = $0 }
        }
        try await self.inner.save(session)
    }

    func load(id: MeetingSessionID) async throws -> MeetingSession? { try await self.inner.load(id: id) }
    func loadAll() async throws -> [MeetingSession] { try await self.inner.loadAll() }
    func loadRecoverable() async throws -> [MeetingSession] { try await self.inner.loadRecoverable() }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL { try await self.inner.sessionDirectory(for: id) }
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
        try await self.inner.existingSessionDirectory(for: id)
    }
    func delete(id: MeetingSessionID) async throws { try await self.inner.delete(id: id) }
    func deleteAudioFiles(for id: MeetingSessionID) async throws { try await self.inner.deleteAudioFiles(for: id) }
}

// MARK: - MeetingProcessingSerializationGate (REL-010)

private struct GateTimeoutError: Error {}

final class MeetingProcessingSerializationGateTests: XCTestCase {
    /// Races `gate.acquire()` against a timeout so a regression that re-introduces a deadlock
    /// fails the test instead of hanging the whole suite.
    private func acquireOrTimeout(
        _ gate: MeetingProcessingSerializationGate,
        timeoutNanoseconds: UInt64 = 500_000_000
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await gate.acquire() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw GateTimeoutError()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func testSecondAcquireWaitsUntilFirstRelease() async throws {
        let gate = MeetingProcessingSerializationGate()
        try await gate.acquire()

        let recorder = EventRecorder()
        let waiter = Task {
            try await gate.acquire()
            await recorder.record("acquired")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let eventsBeforeRelease = await recorder.events
        XCTAssertTrue(eventsBeforeRelease.isEmpty, "second acquire must not resume before release")

        await gate.release()
        try await waiter.value
        let eventsAfterRelease = await recorder.events
        XCTAssertEqual(eventsAfterRelease, ["acquired"])
    }

    func testThreeWaitersResumeInFIFOOrder() async throws {
        let gate = MeetingProcessingSerializationGate()
        try await gate.acquire()

        let recorder = EventRecorder()
        let waiter1 = Task { try await gate.acquire(); await recorder.record("1") }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter2 = Task { try await gate.acquire(); await recorder.record("2") }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter3 = Task { try await gate.acquire(); await recorder.record("3") }
        try await Task.sleep(nanoseconds: 20_000_000)

        await gate.release()
        try await waiter1.value
        await gate.release()
        try await waiter2.value
        await gate.release()
        try await waiter3.value

        let events = await recorder.events
        XCTAssertEqual(events, ["1", "2", "3"])
    }

    func testCancelledWaiterThrowsAndDoesNotStrandTheLeaseForLaterWaiters() async throws {
        let gate = MeetingProcessingSerializationGate()
        try await gate.acquire()

        let cancelledWaiter = Task { try await gate.acquire() }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelledWaiter.cancel()

        do {
            try await cancelledWaiter.value
            XCTFail("Expected the cancelled waiter to throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let laterWaiter = Task { try await gate.acquire() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.release() // still holding the original lease; must go to laterWaiter, not the cancelled one
        try await laterWaiter.value // no deadlock: the cancelled waiter didn't strand the lease
    }

    func testReleaseWithNoWaitersResetsForFreshAcquire() async throws {
        let gate = MeetingProcessingSerializationGate()
        try await gate.acquire()
        await gate.release()

        try await self.acquireOrTimeout(gate)
    }

    func testPreCancelledAcquireThrowsImmediatelyAndLeavesGateFreeForNextAcquire() async throws {
        let gate = MeetingProcessingSerializationGate()
        let task = Task<Void, Error> { try await gate.acquire() }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected a pre-cancelled acquire to throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        // The cancelled acquire never took the lease: a fresh acquire must proceed unblocked.
        try await self.acquireOrTimeout(gate)
        await gate.release()
    }

    /// Races a waiter's cancellation against the moment `release()` hands it the lease — the
    /// exact window a stale tombstone could otherwise strand. Kept behavioral (no introspection
    /// of the gate's private tombstone set): a fresh acquire/release cycle afterward must still
    /// make progress within the timeout.
    func testCancelRacingHandoffLeavesGateUsableAfterward() async throws {
        let gate = MeetingProcessingSerializationGate()
        try await gate.acquire()

        let waiter = Task { try? await gate.acquire() }
        try await Task.sleep(nanoseconds: 20_000_000)

        await gate.release()
        waiter.cancel()
        _ = await waiter.value
        await gate.release() // frees the lease regardless of which side of the race the waiter landed on

        try await self.acquireOrTimeout(gate)
        await gate.release()
    }
}
