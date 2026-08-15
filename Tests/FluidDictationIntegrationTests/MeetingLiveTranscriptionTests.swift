@testable import FluidVoice_Debug
import CoreMedia
import Foundation
import XCTest

final class MeetingLiveTimeConversionTests: XCTestCase {
    func testZeroOriginPassesPTSThrough() {
        let pts = CMTime(value: 5, timescale: 1)
        let origin = CMTime(value: 0, timescale: 1)
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: origin), 5, accuracy: 0.001)
    }

    func testNonZeroOriginSubtracts() {
        let pts = CMTime(value: 7, timescale: 1)
        let origin = CMTime(value: 2, timescale: 1)
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: origin), 5, accuracy: 0.001)
    }

    func testPTSBeforeOriginClampsToZero() {
        let pts = CMTime(value: 1, timescale: 1)
        let origin = CMTime(value: 4, timescale: 1)
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: pts, origin: origin), 0, accuracy: 0.001)
    }

    func testInvalidTimesReturnZero() {
        XCTAssertEqual(MeetingLiveTimeConversion.sessionSeconds(pts: .invalid, origin: .zero), 0)
    }

    func testOriginBoxKeepsTheEarliestPTS() {
        let box = MeetingLiveOriginBox()
        XCTAssertEqual(box.establish(CMTime(value: 5, timescale: 1)), CMTime(value: 5, timescale: 1))
        // A later-arriving but earlier PTS (out-of-order tee delivery) still wins.
        XCTAssertEqual(box.establish(CMTime(value: 2, timescale: 1)), CMTime(value: 2, timescale: 1))
        XCTAssertEqual(box.establish(CMTime(value: 9, timescale: 1)), CMTime(value: 2, timescale: 1))
    }
}

final class MeetingLiveTranscriptSnapshotTests: XCTestCase {
    private func utterance(_ speaker: MeetingLiveSpeaker, _ text: String, start: TimeInterval, end: TimeInterval) -> MeetingLiveUtterance {
        MeetingLiveUtterance(id: UUID(), speaker: speaker, text: text, start: start, end: end)
    }

    func testInsertingKeepsUtterancesSortedByStart() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "second", start: 5, end: 6))
        snapshot = snapshot.inserting(self.utterance(.them, "first", start: 1, end: 2))
        snapshot = snapshot.inserting(self.utterance(.you, "third", start: 8, end: 9))
        XCTAssertEqual(snapshot.utterances.map(\.text), ["first", "second", "third"])
    }

    /// A later-arriving finalize whose audio started earlier must still sort before an
    /// already-published utterance with a later start — engines finalize independently.
    func testLaterArrivingEarlierStartSortsFirst() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.them, "arrived first, starts late", start: 10, end: 12))
        snapshot = snapshot.inserting(self.utterance(.you, "arrived second, starts early", start: 3, end: 4))
        XCTAssertEqual(snapshot.utterances.first?.text, "arrived second, starts early")
    }

    func testGrowingPartialsReplaceRatherThanConcatenate() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial("hel", for: .you)
        snapshot = snapshot.settingPartial("hello", for: .you)
        snapshot = snapshot.settingPartial("hello there", for: .you)
        XCTAssertEqual(snapshot.partials[.you], "hello there")
    }

    func testEmptyPartialClearsTheSlot() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial("hello", for: .them)
        snapshot = snapshot.settingPartial("", for: .them)
        XCTAssertNil(snapshot.partials[.them])
    }

    func testPartialsForEachSpeakerAreIndependent() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial("you partial", for: .you)
        snapshot = snapshot.settingPartial("them partial", for: .them)
        XCTAssertEqual(snapshot.partials[.you], "you partial")
        XCTAssertEqual(snapshot.partials[.them], "them partial")
    }
}

final class MeetingLiveBoundedQueueTests: XCTestCase {
    func testEnqueueUnderCapacityNeverDrops() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 4)
        for value in 0..<4 {
            XCTAssertFalse(queue.enqueue(value))
        }
        XCTAssertEqual(queue.drainAll(), [0, 1, 2, 3])
    }

    func testSaturationDropsTheOldestElement() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 3)
        for value in 0..<3 { _ = queue.enqueue(value) }
        let dropped = queue.enqueue(3)
        XCTAssertTrue(dropped)
        // 0 was the oldest; it must be gone, newest (3) must be present.
        XCTAssertEqual(queue.drainAll(), [1, 2, 3])
    }

    func testDrainClearsTheQueue() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 4)
        _ = queue.enqueue(1)
        _ = queue.drainAll()
        XCTAssertEqual(queue.drainAll(), [])
    }

    func testHeavySaturationNeverGrowsPastCapacity() {
        let queue = MeetingLiveBoundedQueue<Int>(capacity: 4)
        for value in 0..<1000 { _ = queue.enqueue(value) }
        let drained = queue.drainAll()
        XCTAssertEqual(drained.count, 4)
        XCTAssertEqual(drained, [996, 997, 998, 999])
    }
}

final class MeetingLiveEchoFilterTests: XCTestCase {
    func testMicUtteranceMatchingRecentThemTextIsSuppressed() {
        let them = [
            MeetingLiveUtterance(
                id: UUID(), speaker: .them,
                text: "let's push the release to next Tuesday afternoon",
                start: 10, end: 14
            ),
        ]
        let recent = MeetingLiveEchoFilter.recentThemText(from: them, before: 15, windowSeconds: 20)
        let shouldSuppress = MeetingLiveEchoFilter.shouldSuppress(
            micText: "let's push the release to next Tuesday afternoon",
            recentThemText: recent
        )
        XCTAssertTrue(shouldSuppress)
    }

    func testGenuineLocalUtteranceIsNotSuppressed() {
        let them = [
            MeetingLiveUtterance(id: UUID(), speaker: .them, text: "let's push the release to next Tuesday", start: 10, end: 14),
        ]
        let recent = MeetingLiveEchoFilter.recentThemText(from: them, before: 15, windowSeconds: 20)
        let shouldSuppress = MeetingLiveEchoFilter.shouldSuppress(
            micText: "I think we should grab lunch after this call",
            recentThemText: recent
        )
        XCTAssertFalse(shouldSuppress)
    }

    func testThemTextOutsideTheWindowIsExcluded() {
        let them = [
            MeetingLiveUtterance(id: UUID(), speaker: .them, text: "let's push the release to next Tuesday afternoon", start: 0, end: 2),
        ]
        let recent = MeetingLiveEchoFilter.recentThemText(from: them, before: 100, windowSeconds: 20)
        XCTAssertTrue(recent.isEmpty)
        XCTAssertFalse(MeetingLiveEchoFilter.shouldSuppress(micText: "let's push the release to next Tuesday afternoon", recentThemText: recent))
    }
}

final class MeetingLiveMemoryGateTests: XCTestCase {
    func testBelowThresholdDisablesLive() {
        let oneGigabyte: UInt64 = 1 * 1_024 * 1_024 * 1_024
        XCTAssertFalse(MeetingLiveTranscriptionCoordinator.isMemorySufficient(physicalMemory: oneGigabyte))
    }

    func testAtOrAboveThresholdAllowsLive() {
        XCTAssertTrue(MeetingLiveTranscriptionCoordinator.isMemorySufficient(
            physicalMemory: MeetingLiveTranscriptionCoordinator.minimumPhysicalMemoryBytes
        ))
        XCTAssertTrue(MeetingLiveTranscriptionCoordinator.isMemorySufficient(physicalMemory: 64 * 1_024 * 1_024 * 1_024))
    }
}

final class MeetingLiveProvisionalContainmentTests: XCTestCase {
    /// Provisional live text must never reach the exporter: it only ever reads `MeetingSession`,
    /// and live utterances are never written into `session.transcriptSegments`.
    func testExportedTranscriptNeverContainsLiveOnlyText() {
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "mic-1", coreAudioUID: nil, displayName: "Test Mic")
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Standup", microphone: microphone)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: configuration, timebase: timebase)

        let speakerID = UUID()
        session.speakers = [
            MeetingSessionSpeaker(
                id: speakerID, displayName: "Speaker 1", diarizationClusterID: nil,
                trackKind: .microphone, isLocalUser: true, identityCandidates: []
            ),
        ]
        session.transcriptSegments = [
            MeetingTranscriptSegment(
                id: UUID(),
                start: MeetingMediaTime(value: 0, timescale: 1),
                end: MeetingMediaTime(value: 1, timescale: 1),
                sourceTrackID: UUID(),
                speakerID: speakerID,
                text: "FINAL_TRANSCRIPT_TEXT",
                revision: 0,
                status: .final,
                overlap: .none,
                completeness: .complete
            ),
        ]

        // A live snapshot exists in memory alongside the session, as it would during recording,
        // but nothing ever threads it into the exporter or the session's segments.
        let liveSnapshot = MeetingLiveTranscriptSnapshot.empty
            .inserting(MeetingLiveUtterance(id: UUID(), speaker: .you, text: "PROVISIONAL_LIVE_ONLY_TEXT", start: 0, end: 1))
            .settingPartial("PROVISIONAL_PARTIAL_ONLY_TEXT", for: .them)

        let exported = MeetingTranscriptExporter.text(for: session, includeEchoes: true)
        XCTAssertTrue(exported.contains("FINAL_TRANSCRIPT_TEXT"))
        XCTAssertFalse(exported.contains("PROVISIONAL_LIVE_ONLY_TEXT"))
        XCTAssertFalse(exported.contains("PROVISIONAL_PARTIAL_ONLY_TEXT"))
        XCTAssertFalse(session.transcriptSegments.contains { $0.text.contains("PROVISIONAL") })
        XCTAssertFalse(liveSnapshot.utterances.isEmpty, "sanity: the live snapshot really did hold provisional content")
    }
}
