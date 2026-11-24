import Combine
@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingSummaryInputTests: XCTestCase {
    func testSummaryInputPreservesTranscriptAndUsesSpeakerFormat() {
        let original = self.session(origin: 0, segmentStart: 0, segmentEnd: 1, gapStart: 2, gapEnd: 3)
        let input = MeetingSummaryInput.transcript(for: original)
        XCTAssertTrue(input.contains("Title: Timeline migration"))
        XCTAssertTrue(input.contains("----------\n**Speaker 1**: hello"))
        XCTAssertEqual(original.transcriptSegments.first?.text, "hello")
        XCTAssertNil(original.postProcessing)
    }

    /// A meeting is saved with whole-second dates. The summary text must not depend on the fractions
    /// the app still holds right after recording, or a summary made then is hidden after a restart.
    func testSummaryMadeRightAfterRecordingStillMatchesOnceTheMeetingIsReloaded() async throws {
        var live = self.session(origin: 0, segmentStart: 0, segmentEnd: 1, gapStart: 2, gapEnd: 3)
        live.startedAt = Date(timeIntervalSince1970: 1_700_000_000.7)
        live.endedAt = Date(timeIntervalSince1970: 1_700_001_800.3) // 29 min 59.6 s as recorded
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingSummaryInputTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        try await store.create(live)
        let loaded = try await store.load(id: live.id)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertNotEqual(reloaded.endedAt, live.endedAt, "The store keeps whole seconds; that is the difference under test")

        XCTAssertEqual(MeetingSummaryInput.transcript(for: live), MeetingSummaryInput.transcript(for: reloaded))
        XCTAssertEqual(
            MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: live)),
            MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: reloaded))
        )
        XCTAssertEqual(MeetingSummaryInput.contentFingerprint(for: live), MeetingSummaryInput.contentFingerprint(for: reloaded))
    }

    func testDurationLineIsUnchangedForMeetingsAlreadyOnWholeSeconds() {
        var session = self.session(origin: 0, segmentStart: 0, segmentEnd: 1, gapStart: 2, gapEnd: 3)
        session.startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        for (seconds, minutes) in [(0.0, 0), (59, 0), (60, 1), (1799, 29), (1800, 30), (2640, 44)] {
            session.endedAt = session.startedAt.addingTimeInterval(seconds)
            XCTAssertTrue(MeetingSummaryInput.transcript(for: session).contains("Duration: \(minutes) minutes\n"), "\(seconds) s")
        }
        session.endedAt = nil
        XCTAssertTrue(MeetingSummaryInput.transcript(for: session).contains("Duration: 0 minutes\n"))
        session.endedAt = session.startedAt.addingTimeInterval(-30)
        XCTAssertTrue(MeetingSummaryInput.transcript(for: session).contains("Duration: 0 minutes\n"), "A clock that went backwards still reads zero")
    }

    func testChangedTextOrSpeakerInvalidatesSavedSummary() {
        var session = self.session(origin: 0, segmentStart: 0, segmentEnd: 1, gapStart: 2, gapEnd: 3)
        let original = MeetingSummaryInput.contentFingerprint(for: session)
        session.transcriptSegments[0].text = "Corrected transcript"
        let corrected = MeetingSummaryInput.contentFingerprint(for: session)
        XCTAssertNotEqual(original, corrected)
        session.speakers[0].displayName = "Maya"
        XCTAssertNotEqual(corrected, MeetingSummaryInput.contentFingerprint(for: session))
    }

    func testRenamingKeepsContentFingerprintButUpdatesModelInput() {
        var session = self.session(origin: 0, segmentStart: 0, segmentEnd: 1, gapStart: 2, gapEnd: 3)
        let original = MeetingSummaryInput.contentFingerprint(for: session)
        for title in ["Weekly Sync", "A title\nwith a second line", ""] {
            session.title = title
            session.updatedAt = session.updatedAt.addingTimeInterval(1)
            XCTAssertEqual(MeetingSummaryInput.contentFingerprint(for: session), original)
            XCTAssertTrue(MeetingSummaryInput.transcript(for: session).hasPrefix("Title: \(title)\n"))
        }
    }

    @MainActor
    func testSummaryCannotRunOutsideExclusiveModelScope() async {
        do {
            _ = try await PrivateAIIntegrationService.summarizeMeeting("Example", style: "executive")
            XCTFail("An unowned request must not load or switch models")
        } catch {
            XCTAssertEqual(error.localizedDescription, MeetingModelResidencyError.staleGrant.localizedDescription)
        }
    }

    @MainActor
    func testSummarySurvivesClosingItsPresenterAndStillSupportsCancel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let meeting = self.session(origin: 0, segmentStart: 0, segmentEnd: 1, gapStart: 2, gapEnd: 3)
        try await store.create(meeting)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeetingSummaryURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let activity = MeetingSummaryActivityCoordinator()
        let generation = MeetingSummaryGeneration(
            store: store, remoteService: MeetingSummaryRemoteService(session: urlSession), activity: activity
        )
        let route = MeetingSummaryRoute(
            providerID: "fixture",
            providerName: "Fixture",
            modelID: "fixture-model",
            baseURL: "https://gateway.example/v1/",
            apiKey: "fixture-key",
            reasoning: nil,
            supportsTemperature: false
        )

        let saved = self.expectation(description: "summary saved after its presenter closes")
        let savedObservation = generation.$savedRevision.dropFirst().first().sink { _ in saved.fulfill() }
        defer { savedObservation.cancel() }
        do {
            let presenter = MeetingSummaryController(store: store)
            await presenter.refresh(session: meeting, kind: .actions)
            generation.summarize(session: meeting, kind: .actions, route: route, customPrompt: "")
            XCTAssertTrue(generation.isRunning)
            XCTAssertEqual(generation.request?.sessionID, meeting.id)
            XCTAssertEqual(generation.request?.kind, .actions)
            presenter.cancelModelOperation()
        }
        await self.fulfillment(of: [saved], timeout: 5)
        XCTAssertFalse(generation.isRunning)
        XCTAssertNil(activity.selectionLock)

        let reopened = MeetingSummaryController(store: store)
        await reopened.refresh(session: meeting, kind: .actions)
        XCTAssertEqual(reopened.output, "Release agreed")
        await reopened.refresh(session: meeting, kind: .executive)
        XCTAssertTrue(reopened.output.isEmpty)

        let cancelled = self.expectation(description: "explicit cancellation drains the summary")
        let cancelledObservation = generation.$isRunning.dropFirst(2).first().sink { _ in cancelled.fulfill() }
        defer { cancelledObservation.cancel() }
        generation.summarize(session: meeting, kind: .executive, route: route, customPrompt: "")
        generation.cancel()
        await self.fulfillment(of: [cancelled], timeout: 5)
        XCTAssertFalse(generation.isRunning)
        XCTAssertNil(activity.selectionLock)
        XCTAssertNil(generation.error)
        XCTAssertEqual(generation.savedRevision, 1)
        await reopened.refresh(session: meeting, kind: .executive)
        XCTAssertTrue(reopened.output.isEmpty)
    }

    private func session(
        origin: TimeInterval,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval,
        gapStart: TimeInterval,
        gapEnd: TimeInterval
    ) -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(
            mode: .inRoom,
            title: "Timeline migration",
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")
        )
        var session = MeetingSession(
            configuration: configuration,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 1,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: self.mediaTime(origin)
            )
        )
        let trackID = UUID()
        let speakerID = UUID()
        session.audioTracks = [MeetingAudioTrack(
            id: trackID,
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: session.timebase,
            health: .waiting,
            chunks: []
        )]
        session.speakers = [MeetingSessionSpeaker(
            id: speakerID,
            displayName: "Speaker 1",
            diarizationClusterID: "slot-0",
            trackKind: .microphone,
            isLocalUser: false,
            identityCandidates: []
        )]
        session.transcriptSegments = [MeetingTranscriptSegment(
            id: UUID(),
            start: self.mediaTime(segmentStart),
            end: self.mediaTime(segmentEnd),
            sourceTrackID: trackID,
            speakerID: speakerID,
            text: "hello",
            revision: 0,
            status: .final,
            overlap: .none,
            completeness: .complete
        )]
        session.transcriptCoverageGaps = [MeetingTranscriptCoverageGap(
            trackID: trackID,
            start: gapStart,
            end: gapEnd,
            reason: .processingFailed
        )]
        return session
    }

    private func mediaTime(_ seconds: TimeInterval) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64((seconds * 1000).rounded()), timescale: 1000)
    }
}

@MainActor
final class MeetingSummaryActivityTests: XCTestCase {
    func testProcessingBlocksSummaryAndStaleReleaseCannotUnlock() async throws {
        let gate = MeetingSummaryActivityCoordinator(isMeetingActive: { false })
        var published: [Bool] = []
        let observation = gate.$isProcessing.removeDuplicates().sink { published.append($0) }
        defer { observation.cancel() }
        XCTAssertFalse(gate.isProcessing)
        let first = try XCTUnwrap(gate.beginProcessing())
        XCTAssertTrue(gate.isProcessing)
        let second = try XCTUnwrap(gate.beginProcessing())
        gate.endProcessing(first)
        XCTAssertTrue(gate.isProcessing)
        gate.endProcessing(first)
        XCTAssertTrue(gate.isProcessing)
        do {
            try await gate.withSummary { XCTFail("Must not begin") }
            XCTFail("Second processing token must still block")
        } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        XCTAssertFalse(gate.isSummarizing)
        gate.endProcessing(second)
        XCTAssertFalse(gate.isProcessing)
        XCTAssertEqual(published, [false, true, false])
        var ran = false
        try await gate.withSummary { ran = true }
        XCTAssertTrue(ran)
    }

    func testOnDeviceSummaryBlocksLocalLLMWorkButLeavesDictationAudioFree() async throws {
        let gate = MeetingSummaryActivityCoordinator(isMeetingActive: { false })
        let asr = ASRService()
        let selectionLock = try XCTUnwrap(gate.lockSelection())
        XCTAssertNil(gate.lockSelection(), "A second summary cannot replace the selected meeting's lock")
        gate.unlockSelection(UUID())
        XCTAssertEqual(gate.selectionLock, selectionLock, "An unrelated completion cannot unlock selection")
        try await gate.withSummary {
            XCTAssertTrue(gate.isSummarizing)
            XCTAssertNil(gate.beginProcessing(), "Local LLM cleanup must wait for the summary")
            let dictation = try asr.acquireExclusiveActivity(.dictation)
            asr.releaseExclusiveActivity(dictation)
            do {
                try await gate.withSummary { XCTFail("Must not overlap") }
                XCTFail("Second summary must fail")
            } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        }
        XCTAssertFalse(gate.isSummarizing)
        XCTAssertNil(asr.activeExclusiveActivity)
        gate.unlockSelection(selectionLock)
        XCTAssertNil(gate.selectionLock)
        let nextLock = try XCTUnwrap(gate.lockSelection())
        gate.unlockSelection(selectionLock)
        XCTAssertEqual(gate.selectionLock, nextLock, "A late old completion cannot unlock a new summary")
        gate.unlockSelection(nextLock)
        XCTAssertNotNil(gate.beginProcessing())
    }

    func testRunningDictationDoesNotBlockOnDeviceSummary() async throws {
        let gate = MeetingSummaryActivityCoordinator(isMeetingActive: { false })
        let asr = ASRService()
        let dictation = try asr.acquireExclusiveActivity(.dictation)
        defer { asr.releaseExclusiveActivity(dictation) }
        var ran = false
        try await gate.withSummary { ran = true }
        XCTAssertTrue(ran)
        XCTAssertEqual(asr.activeExclusiveActivity, .dictation)
    }

    func testActiveMeetingRejectsOnDeviceSummary() async {
        let gate = MeetingSummaryActivityCoordinator(isMeetingActive: { true })
        do {
            try await gate.withSummary { XCTFail("Must not start during a meeting") }
            XCTFail("Expected the meeting to block the summary")
        } catch { XCTAssertTrue(error is ASRActivityError) }
        XCTAssertFalse(gate.isSummarizing)
        XCTAssertNotNil(gate.beginProcessing())
    }

    func testRunningSummaryRejectsNewMeetingCapture() async {
        let arbiter = AudioActivityArbiter(
            asrServiceProvider: { throw MeetingCoordinatorError.dictationActive },
            isSummaryRunning: { true }
        )
        do {
            _ = try await arbiter.acquireMeetingCapture()
            XCTFail("Expected the summary to block meeting capture")
        } catch {
            guard case MeetingCoordinatorError.summaryInProgress = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testRemoteSummaryLeavesDictationAndProcessingAvailable() async throws {
        let gate = MeetingSummaryActivityCoordinator(isMeetingActive: { false })
        let asr = ASRService()
        try await gate.withRemoteSummary {
            let processing = try XCTUnwrap(gate.beginProcessing(), "Dictation must be able to finish during a cloud summary")
            gate.endProcessing(processing)
            let dictation = try asr.acquireExclusiveActivity(.dictation)
            asr.releaseExclusiveActivity(dictation)
            do {
                try await gate.withRemoteSummary { XCTFail("Must not overlap") }
                XCTFail("Second summary must fail")
            } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        }
        try await gate.withRemoteSummary {}
    }

    func testFailureReleasesSummaryAdmission() async {
        let gate = MeetingSummaryActivityCoordinator(isMeetingActive: { false })
        do {
            try await gate.withSummary { throw MeetingModelResidencyError.staleGrant }
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        XCTAssertFalse(gate.isSummarizing)
        XCTAssertNotNil(gate.beginProcessing())
    }

    func testCancellationReleasesSummaryAdmission() async {
        let gate = MeetingSummaryActivityCoordinator(isMeetingActive: { false })
        let selectionLock = gate.lockSelection()
        let task = Task {
            defer { if let selectionLock { gate.unlockSelection(selectionLock) } }
            try await gate.withSummary {
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(gate.selectionLock, "Cancellation eventually unlocks meeting selection")
        XCTAssertFalse(gate.isSummarizing)
        XCTAssertNotNil(gate.beginProcessing())
    }

    func testRealASRMeetingLeaseBlocksEveryCompetingAudioActivity() throws {
        let asr = ASRService()
        let meeting = try asr.acquireExclusiveActivity(.meeting)
        let activities: [ASRExclusiveActivity] = [.dictation, .meeting, .fileTranscription, .localAPI, .modelMaintenance]
        for activity in activities {
            XCTAssertThrowsError(try asr.acquireExclusiveActivity(activity))
        }
        asr.releaseExclusiveActivity(ASRActivityLease(id: UUID(), activity: .meeting))
        XCTAssertEqual(asr.activeExclusiveActivity, .meeting)
        asr.releaseExclusiveActivity(meeting)
        XCTAssertNil(asr.activeExclusiveActivity)
        let dictation = try asr.acquireExclusiveActivity(.dictation)
        asr.releaseExclusiveActivity(dictation)
    }

    func testALargeSummaryModelComesWithAWarningOnASixteenGBMacOnly() {
        // The 9B recommends 24 GB.
        XCTAssertEqual(
            MeetingSummaryOnDevice.memoryWarning(recommendedMemoryGB: 24, memoryGB: 16),
            "Recommended only for Macs with more than 16 GB of memory."
        )
        XCTAssertNil(MeetingSummaryOnDevice.memoryWarning(recommendedMemoryGB: 24, memoryGB: 18))
        XCTAssertNil(MeetingSummaryOnDevice.memoryWarning(recommendedMemoryGB: 24, memoryGB: 64))
    }

    func testASmallSummaryModelNeverWarns() {
        for memoryGB in [8, 16, 24] {
            XCTAssertNil(MeetingSummaryOnDevice.memoryWarning(recommendedMemoryGB: 8, memoryGB: memoryGB))
            XCTAssertNil(MeetingSummaryOnDevice.memoryWarning(recommendedMemoryGB: nil, memoryGB: memoryGB))
        }
    }
}
