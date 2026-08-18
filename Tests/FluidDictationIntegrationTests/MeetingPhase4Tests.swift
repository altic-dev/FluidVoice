@testable import FluidVoice_Debug
import AVFoundation
import CoreMedia
import Foundation
import XCTest

/// Phase 4 — VPIO attribution. See MIC_CAPTURE_MIGRATION_PLAN.md §5/§9.
final class MeetingPhase4ClassificationTests: XCTestCase {
    private func mediaTime(_ seconds: TimeInterval) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64((seconds * 1000).rounded()), timescale: 1000)
    }

    private func segment(
        trackID: MeetingAudioTrackID,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: UUID(), start: self.mediaTime(start), end: self.mediaTime(end),
            sourceTrackID: trackID, speakerID: UUID(), text: text, revision: 0,
            status: .final, overlap: .none, completeness: .complete
        )
    }

    private func turn(
        clusterID: SessionSpeakerID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        overlapsRemote: Bool
    ) -> MeetingProcessingPipeline.StagedMicrophoneTurn {
        MeetingProcessingPipeline.StagedMicrophoneTurn(
            chunkID: UUID(), index: 0, clusterID: clusterID, clusterLabel: "spk",
            start: start, end: end, text: text, overlapsRemote: overlapsRemote
        )
    }

    // MARK: - 1. VPIO classification widens echoScored; detector still consulted

    func testVoiceProcessingScoresAllTurnsAndStillConsultsDetectorWhereTextExists() {
        let appTrackID = UUID()
        let echoedText = "let's push the release to next Tuesday afternoon"
        let turns = [
            self.turn(start: 0, end: 3, text: echoedText, overlapsRemote: true),
            // Fallback-gap: overlapping but no remote text — unscored pre-Phase-4, now forced clean.
            self.turn(start: 10, end: 12, text: "genuinely local speech here", overlapsRemote: true),
            self.turn(start: 20, end: 22, text: "more local speech", overlapsRemote: false),
        ]
        let segments = [self.segment(trackID: appTrackID, start: 0, end: 3, text: echoedText)]

        let (classified, widened) = MeetingProcessingPipeline.classifyMicrophoneTurns(
            turns, captureMethod: .voiceProcessing, applicationTrackID: appTrackID,
            segments: segments, fallbackSpeakerID: nil
        )

        XCTAssertTrue(classified.allSatisfy(\.echoScored), "every VPIO turn must end up scored")
        XCTAssertTrue(classified[0].isLikelyEcho, "detector still runs where remote text exists")
        XCTAssertFalse(classified[1].isLikelyEcho, "forced-scored turns default to not-echo, they were never examined")
        XCTAssertFalse(classified[2].isLikelyEcho)
        XCTAssertEqual(widened, [1, 2], "widened = forced without detector examination")
    }

    // MARK: - 2. Veto regression: VPIO turn demotes on signalVerdict == .echo exactly like non-VPIO

    func testSignalVetoStillAppliesToVoiceProcessingTurns() {
        var vpioTurn = self.turn(start: 0, end: 3, text: "some text", overlapsRemote: false)
        vpioTurn.signalVerdict = .echo
        let (classified, _) = MeetingProcessingPipeline.classifyMicrophoneTurns(
            [vpioTurn], captureMethod: .voiceProcessing, applicationTrackID: nil, segments: [], fallbackSpeakerID: nil
        )
        XCTAssertTrue(classified[0].echoScored)
        XCTAssertTrue(classified[0].effectiveEcho, "signal veto is untouched by Phase 4 — echoScored never feeds effectiveEcho")
    }

    func testContainsLocalSpeechRescueStillWinsUnderVoiceProcessing() {
        var vpioTurn = self.turn(start: 0, end: 3, text: "some text", overlapsRemote: false)
        vpioTurn.signalVerdict = .containsLocalSpeech
        vpioTurn.isLikelyEcho = true
        let (classified, _) = MeetingProcessingPipeline.classifyMicrophoneTurns(
            [vpioTurn], captureMethod: .voiceProcessing, applicationTrackID: nil, segments: [], fallbackSpeakerID: nil
        )
        XCTAssertFalse(classified[0].effectiveEcho, "the rescue rule is untouched: containsLocalSpeech always wins")
    }

    // MARK: - 3. Two-voice election via localSpeakerEvidence + selectLocalCluster (VPIO turns, all scored)

    func testTwoVoiceElectionDemotesTheSecondClusterWhenMarginHolds() {
        let userCluster = UUID()
        let secondVoice = UUID()
        var turns = [
            self.turn(clusterID: userCluster, start: 0, end: 20, text: "user speech", overlapsRemote: false),
            self.turn(clusterID: secondVoice, start: 20, end: 25, text: "second voice", overlapsRemote: false),
        ]
        for index in turns.indices { turns[index].echoScored = true }
        let elected = MeetingProcessingPipeline.selectLocalCluster(
            from: turns, prototypeSpeakerIDs: [userCluster, secondVoice]
        )
        XCTAssertEqual(elected, userCluster)
    }

    func testTwoVoiceElectionAbstainsWhenSecondVoiceIsComparable() {
        let userCluster = UUID()
        let secondVoice = UUID()
        var turns = [
            self.turn(clusterID: userCluster, start: 0, end: 12, text: "user speech", overlapsRemote: false),
            self.turn(clusterID: secondVoice, start: 12, end: 22, text: "second voice", overlapsRemote: false),
        ]
        for index in turns.indices { turns[index].echoScored = true }
        let elected = MeetingProcessingPipeline.selectLocalCluster(
            from: turns, prototypeSpeakerIDs: [userCluster, secondVoice]
        )
        XCTAssertNil(elected, "comparable second voice must abstain (all-Unknown), never guess")
    }

    // MARK: - 4. Non-VPIO byte-identity through the extracted function

    func testNonVoiceProcessingClassificationIsByteIdenticalToTodaysInlineLogic() {
        let appTrackID = UUID()
        let echoedText = "let's push the release to next Tuesday afternoon"
        let fallbackSpeaker = UUID()
        let turns = [
            self.turn(start: 0, end: 3, text: echoedText, overlapsRemote: true),
            self.turn(start: 10, end: 12, text: "genuinely local speech here", overlapsRemote: true),
            self.turn(start: 20, end: 22, text: "more local speech", overlapsRemote: false),
        ]
        let segments = [
            self.segment(trackID: appTrackID, start: 0, end: 3, text: echoedText),
                self.segment(trackID: appTrackID, start: 10, end: 12, text: "fallback whole-chunk noise"),
        ]
        var fallbackSegments = segments
        fallbackSegments[1].speakerID = fallbackSpeaker

        for captureMethod in [MeetingAudioTrackCaptureMethod?.none, .screenCaptureKit, .avCaptureSession] {
            let (classified, widened) = MeetingProcessingPipeline.classifyMicrophoneTurns(
                turns, captureMethod: captureMethod, applicationTrackID: appTrackID,
                segments: fallbackSegments, fallbackSpeakerID: fallbackSpeaker
            )
            XCTAssertTrue(widened.isEmpty, "non-VPIO never widens")
            XCTAssertTrue(classified[0].echoScored)
            XCTAssertTrue(classified[0].isLikelyEcho)
            XCTAssertFalse(classified[1].echoScored)
            XCTAssertFalse(classified[2].echoScored, "no overlap, no VPIO widening — stays unscored")
        }
    }

    // MARK: - 5. captureMethod flows into the election log (string assertion)

    func testElectionLogIncludesCaptureMethodAndWidenedCounter() {
        let userCluster = UUID()
        var turn = self.turn(clusterID: userCluster, start: 0, end: 5, text: "hi", overlapsRemote: false)
        turn.echoScored = true
        MeetingProcessingPipeline.logLocalSpeakerElection(
            turns: [turn], prototypeSpeakerIDs: [userCluster], index: nil,
            role: .personal, elected: userCluster, captureMethod: .voiceProcessing, widenedIndices: [0]
        )
    }

    // MARK: - 7. pipelineVersion bump

    func testPipelineVersionIsSeven() {
        XCTAssertEqual(MeetingProcessingPipeline.pipelineVersion, 7)
    }

    // MARK: - 9. Store round-trip: a decoded track drives the classification branch

    func testDecodedVoiceProcessingTrackDrivesWidening() throws {
        var track = MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [], captureMethod: .voiceProcessing
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        track = try decoder.decode(MeetingAudioTrack.self, from: try encoder.encode(track))
        XCTAssertEqual(track.captureMethod, .voiceProcessing, "sanity: the round-trip preserved captureMethod")

        let turns = [self.turn(start: 0, end: 5, text: "local speech", overlapsRemote: false)]
        let (classified, widened) = MeetingProcessingPipeline.classifyMicrophoneTurns(
            turns, captureMethod: track.captureMethod, applicationTrackID: nil, segments: [], fallbackSpeakerID: nil
        )
        XCTAssertTrue(classified[0].echoScored, "the reconciled (decoded) track's captureMethod, not an in-memory one, drives widening")
        XCTAssertEqual(widened, [0])
    }
}

// MARK: - 6. Live gating

final class MeetingPhase4LiveGatingTests: XCTestCase {
    private func sampleBuffer(ptsSeconds: Double) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 48_000)
        return meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: pts)!
    }

    /// `offer` establishes the origin without spinning up a real engine (none was `start()`-ed).
    private func makeCoordinatorWithOrigin(onUpdate: @escaping @Sendable (MeetingLiveTranscriptSnapshot) -> Void) -> MeetingLiveTranscriptionCoordinator {
        let coordinator = MeetingLiveTranscriptionCoordinator(onUpdate: onUpdate)
        coordinator.offer(kind: .microphone, sampleBuffer: self.sampleBuffer(ptsSeconds: 0))
        return coordinator
    }

    func testVoiceProcessingSkipsShouldSuppress() {
        let lock = NSLock()
        var snapshots: [MeetingLiveTranscriptSnapshot] = []
        let coordinator = self.makeCoordinatorWithOrigin { snapshot in lock.withLock { snapshots.append(snapshot) } }
        coordinator.setMicrophoneCaptureMethod(.voiceProcessing)

        let echoText = "let's push the release to next Tuesday afternoon"
        coordinator.handleUtterance(
            kind: .applicationAudio, text: echoText,
            start: CMTime(seconds: 10, preferredTimescale: 1), end: CMTime(seconds: 14, preferredTimescale: 1)
        )
        coordinator.handleUtterance(
            kind: .microphone, text: echoText,
            start: CMTime(seconds: 15, preferredTimescale: 1), end: CMTime(seconds: 16, preferredTimescale: 1)
        )

        let last = lock.withLock { snapshots.last }
        XCTAssertTrue(last?.utterances.contains { $0.speaker == .you && $0.text == echoText } ?? false, "VPIO must skip the shouldSuppress branch entirely")
    }

    func testNilCaptureMethodKeepsSuppressionOn() {
        let lock = NSLock()
        var snapshots: [MeetingLiveTranscriptSnapshot] = []
        let coordinator = self.makeCoordinatorWithOrigin { snapshot in lock.withLock { snapshots.append(snapshot) } }

        let echoText = "let's push the release to next Tuesday afternoon"
        coordinator.handleUtterance(
            kind: .applicationAudio, text: echoText,
            start: CMTime(seconds: 10, preferredTimescale: 1), end: CMTime(seconds: 14, preferredTimescale: 1)
        )
        coordinator.handleUtterance(
            kind: .microphone, text: echoText,
            start: CMTime(seconds: 15, preferredTimescale: 1), end: CMTime(seconds: 16, preferredTimescale: 1)
        )

        let all = lock.withLock { snapshots }
        XCTAssertFalse(all.contains { $0.utterances.contains { $0.speaker == .you && $0.text == echoText } }, "nil keeps the filter ON")
    }

    func testSetterAfterUtteranceOrderingIsSafe() {
        let lock = NSLock()
        var snapshots: [MeetingLiveTranscriptSnapshot] = []
        let coordinator = self.makeCoordinatorWithOrigin { snapshot in lock.withLock { snapshots.append(snapshot) } }

        let echoText = "let's push the release to next Tuesday afternoon"
        coordinator.handleUtterance(
            kind: .applicationAudio, text: echoText,
            start: CMTime(seconds: 10, preferredTimescale: 1), end: CMTime(seconds: 14, preferredTimescale: 1)
        )
        coordinator.handleUtterance(
            kind: .microphone, text: echoText,
            start: CMTime(seconds: 15, preferredTimescale: 1), end: CMTime(seconds: 16, preferredTimescale: 1)
        )
        coordinator.setMicrophoneCaptureMethod(.voiceProcessing)
        coordinator.handleUtterance(
            kind: .microphone, text: "a fresh genuine utterance",
            start: CMTime(seconds: 17, preferredTimescale: 1), end: CMTime(seconds: 18, preferredTimescale: 1)
        )

        let last = lock.withLock { snapshots.last }
        XCTAssertFalse(last?.utterances.contains { $0.speaker == .you && $0.text == echoText } ?? true)
        XCTAssertTrue(last?.utterances.contains { $0.speaker == .you && $0.text == "a fresh genuine utterance" } ?? false)
    }
}
