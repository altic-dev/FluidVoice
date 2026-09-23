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

    func testChangedTextOrSpeakerInvalidatesSavedSummary() {
        var session = self.session(origin: 0, segmentStart: 0, segmentEnd: 1, gapStart: 2, gapEnd: 3)
        let original = MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session))
        session.transcriptSegments[0].text = "Corrected transcript"
        let corrected = MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session))
        XCTAssertNotEqual(original, corrected)
        session.speakers[0].displayName = "Maya"
        XCTAssertNotEqual(corrected, MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session)))
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
    private final class Activity: ASRActivityLeasing {
        var active: ASRActivityLease?
        var handoffs = 0
        var handbacks = 0
        var onHandback: (() -> Void)?
        var preparationError: Error?
        func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease {
            if let active { throw ASRActivityError.activityInProgress(active.activity) }
            let lease = ASRActivityLease(id: UUID(), activity: activity)
            self.active = lease
            return lease
        }

        func releaseExclusiveActivity(_ lease: ASRActivityLease) {
            if self.active == lease { self.active = nil }
        }

        func prepareMeetingAudioHandoff(_: ASRActivityLease) async throws {
            self.handoffs += 1
            if let preparationError { throw preparationError }
        }

        func completeMeetingAudioHandback(_ lease: ASRActivityLease) async {
            self.onHandback?()
            self.handbacks += 1
            self.releaseExclusiveActivity(lease)
        }
    }

    func testProcessingBlocksSummaryWithoutTouchingAudioAndStaleReleaseCannotUnlock() async throws {
        let gate = MeetingSummaryActivityCoordinator()
        let activity = Activity()
        let first = try XCTUnwrap(gate.beginProcessing())
        let second = try XCTUnwrap(gate.beginProcessing())
        gate.endProcessing(first)
        gate.endProcessing(first)
        do {
            try await gate.withSummary(activity: activity) { XCTFail("Must not begin") }
            XCTFail("Second processing token must still block")
        } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        XCTAssertEqual(activity.handoffs, 0)
        XCTAssertNil(activity.active)
        gate.endProcessing(second)
        try await gate.withSummary(activity: activity) {}
        XCTAssertEqual(activity.handbacks, 1)
    }

    func testSummaryBlocksProcessingAndDictationThroughHandback() async throws {
        let gate = MeetingSummaryActivityCoordinator()
        let activity = Activity()
        activity.onHandback = {
            XCTAssertNil(gate.beginProcessing())
            do {
                _ = try activity.acquireExclusiveActivity(.dictation)
                XCTFail("Handback must retain audio ownership")
            } catch { XCTAssertTrue(error is ASRActivityError) }
        }
        try await gate.withSummary(activity: activity) {
            XCTAssertNil(gate.beginProcessing())
            XCTAssertThrowsError(try activity.acquireExclusiveActivity(.dictation))
            do {
                try await gate.withSummary(activity: activity) { XCTFail("Must not overlap") }
                XCTFail("Second summary must fail")
            } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        }
        XCTAssertNil(activity.active)
        XCTAssertNotNil(gate.beginProcessing())
        XCTAssertNoThrow(try activity.acquireExclusiveActivity(.dictation))
    }

    func testFailureDrainsHandbackBeforeReleasingAdmission() async {
        let gate = MeetingSummaryActivityCoordinator()
        let activity = Activity()
        activity.onHandback = { XCTAssertNil(gate.beginProcessing()) }
        do {
            try await gate.withSummary(activity: activity) { throw MeetingModelResidencyError.staleGrant }
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        XCTAssertEqual(activity.handbacks, 1)
        XCTAssertNil(activity.active)
        XCTAssertNotNil(gate.beginProcessing())
    }

    func testCancellationUsesUncancelledJoinedHandback() async {
        let gate = MeetingSummaryActivityCoordinator()
        let activity = Activity()
        activity.onHandback = {
            XCTAssertFalse(Task.isCancelled)
            XCTAssertNil(gate.beginProcessing())
        }
        let task = Task {
            try await gate.withSummary(activity: activity) {
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(activity.handbacks, 1)
        XCTAssertNil(activity.active)
        XCTAssertNotNil(gate.beginProcessing())
    }

    func testPreparationFailureDrainsPartialHandoffWithoutRunningSummary() async {
        let gate = MeetingSummaryActivityCoordinator()
        let activity = Activity()
        activity.preparationError = MeetingModelResidencyError.busy
        activity.onHandback = {
            XCTAssertNil(gate.beginProcessing())
            XCTAssertFalse(Task.isCancelled)
        }
        do {
            try await gate.withSummary(activity: activity) { XCTFail("Preparation failed") }
            XCTFail("Expected failure")
        } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        XCTAssertEqual(activity.handoffs, 1)
        XCTAssertEqual(activity.handbacks, 1)
        XCTAssertNil(activity.active)
        XCTAssertNotNil(gate.beginProcessing())
    }

    func testRealASRLeaseRejectsSummaryWhileDictationOwnsAudio() async throws {
        let gate = MeetingSummaryActivityCoordinator()
        let asr = ASRService()
        let dictation = try asr.acquireExclusiveActivity(.dictation)
        defer { asr.releaseExclusiveActivity(dictation) }
        do {
            try await gate.withSummary(activity: asr) { XCTFail("Must not start") }
            XCTFail("Expected existing dictation to block summary")
        } catch { XCTAssertTrue(error is ASRActivityError) }
        XCTAssertEqual(asr.activeExclusiveActivity, .dictation)
        XCTAssertNotNil(gate.beginProcessing())
    }

    func testRealASRMeetingLeaseBlocksEveryCompetingAudioActivity() throws {
        let asr = ASRService()
        let summary = try asr.acquireExclusiveActivity(.meeting)
        let activities: [ASRExclusiveActivity] = [.dictation, .meeting, .fileTranscription, .localAPI, .modelMaintenance]
        for activity in activities {
            XCTAssertThrowsError(try asr.acquireExclusiveActivity(activity))
        }
        asr.releaseExclusiveActivity(ASRActivityLease(id: UUID(), activity: .meeting))
        XCTAssertEqual(asr.activeExclusiveActivity, .meeting)
        asr.releaseExclusiveActivity(summary)
        XCTAssertNil(asr.activeExclusiveActivity)
        let dictation = try asr.acquireExclusiveActivity(.dictation)
        asr.releaseExclusiveActivity(dictation)
    }

    func testActiveDictationRejectsSummaryWithoutReleasingItsLease() async throws {
        let gate = MeetingSummaryActivityCoordinator()
        let activity = Activity()
        let dictation = try activity.acquireExclusiveActivity(.dictation)
        do {
            try await gate.withSummary(activity: activity) { XCTFail("Must not start") }
            XCTFail("Expected activity rejection")
        } catch { XCTAssertTrue(error is ASRActivityError) }
        XCTAssertEqual(activity.active, dictation)
        XCTAssertEqual(activity.handbacks, 0)
        XCTAssertNotNil(gate.beginProcessing())
    }
}
