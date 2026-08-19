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

    private func partial(_ text: String, id: UUID = UUID(), start: TimeInterval = 0) -> MeetingLivePartial {
        MeetingLivePartial(id: id, text: text, start: start)
    }

    func testGrowingPartialsReplaceRatherThanConcatenate() {
        let id = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("hel", id: id), for: .you)
        snapshot = snapshot.settingPartial(self.partial("hello", id: id), for: .you)
        snapshot = snapshot.settingPartial(self.partial("hello there", id: id), for: .you)
        XCTAssertEqual(snapshot.partials[.you]?.text, "hello there")
    }

    func testEmptyPartialClearsTheSlot() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("hello"), for: .them)
        snapshot = snapshot.settingPartial(nil, for: .them)
        XCTAssertNil(snapshot.partials[.them])
    }

    func testPartialsForEachSpeakerAreIndependent() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("you partial"), for: .you)
        snapshot = snapshot.settingPartial(self.partial("them partial"), for: .them)
        XCTAssertEqual(snapshot.partials[.you]?.text, "you partial")
        XCTAssertEqual(snapshot.partials[.them]?.text, "them partial")
    }

    func testStalePartialAfterFinalizeIsDropped() {
        let id = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "final text", start: 0, end: 1))
        snapshot = snapshot.markingFinalized(id)
        snapshot = snapshot.settingPartial(self.partial("resurrected", id: id), for: .you)
        XCTAssertNil(snapshot.partials[.you])
    }

    func testEchoSuppressionFinalizesTurnWithoutUtterance() {
        let id = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(self.partial("in flight", id: id), for: .you)
        snapshot = snapshot.settingPartial(nil, for: .you).markingFinalized(id)
        XCTAssertNil(snapshot.partials[.you])
        XCTAssertTrue(snapshot.utterances.isEmpty)

        let late = snapshot.settingPartial(self.partial("late arrival", id: id), for: .you)
        XCTAssertNil(late.partials[.you], "a partial for an echo-suppressed turn must not resurrect")
    }

    func testFinalizedTurnIDCapEvictsOldestWithoutBreakingRecentDedup() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        var ids: [UUID] = []
        for index in 0..<100 {
            let id = UUID()
            ids.append(id)
            snapshot = snapshot.inserting(self.utterance(.you, "turn \(index)", start: TimeInterval(index), end: TimeInterval(index) + 1))
            snapshot = snapshot.markingFinalized(id)
        }
        let oldest = ids[0]
        let recent = ids[ids.count - 1]
        XCTAssertFalse(snapshot.finalizedTurnIDs.contains(oldest), "cap must evict the oldest id")
        let staleOldPartial = snapshot.settingPartial(self.partial("should not be dropped by cap logic", id: oldest), for: .you)
        XCTAssertNotNil(staleOldPartial.partials[.you], "an evicted id is no longer recognized as stale")

        let staleRecentPartial = snapshot.settingPartial(self.partial("still dropped", id: recent), for: .you)
        XCTAssertNil(staleRecentPartial.partials[.you], "a recently finalized id must still be recognized as stale")
    }
}

final class MeetingLiveBubbleComposerTests: XCTestCase {
    private func utterance(_ speaker: MeetingLiveSpeaker, _ text: String, start: TimeInterval, end: TimeInterval, id: UUID = UUID()) -> MeetingLiveUtterance {
        MeetingLiveUtterance(id: id, speaker: speaker, text: text, start: start, end: end)
    }

    func testFinalizedThenBottomPinnedPartialsOrderedByStart() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "hello", start: 0, end: 1))
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: UUID(), text: "them partial", start: 5), for: .them)
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: UUID(), text: "you partial", start: 3), for: .you)

        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(rows.map(\.text), ["hello", "you partial", "them partial"])
        XCTAssertEqual(rows.map(\.isPartial), [false, true, true])
        XCTAssertEqual(rows.map(\.showsLabel), [true, false, true])
    }

    func testShowsLabelIsFalseWhenSpeakerRepeatsAcrossPartial() {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.inserting(self.utterance(.you, "first", start: 0, end: 1))
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: UUID(), text: "still talking", start: 2), for: .you)

        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(rows.map(\.showsLabel), [true, false])
    }

    func testSolidifyKeepsRowIdentityStable() {
        let turnID = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot = snapshot.settingPartial(MeetingLivePartial(id: turnID, text: "in flight text", start: 0), for: .you)
        let partialRows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(partialRows.first?.id, turnID)
        XCTAssertEqual(partialRows.first?.isPartial, true)

        snapshot = snapshot.inserting(self.utterance(.you, "in flight text finalized", start: 0, end: 2, id: turnID))
            .settingPartial(nil, for: .you)
        let finalRows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(finalRows.first?.id, turnID)
        XCTAssertEqual(finalRows.first?.isPartial, false)
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
            .settingPartial(MeetingLivePartial(id: UUID(), text: "PROVISIONAL_PARTIAL_ONLY_TEXT", start: 0), for: .them)

        let exported = MeetingTranscriptExporter.text(for: session, includeEchoes: true)
        XCTAssertTrue(exported.contains("FINAL_TRANSCRIPT_TEXT"))
        XCTAssertFalse(exported.contains("PROVISIONAL_LIVE_ONLY_TEXT"))
        XCTAssertFalse(exported.contains("PROVISIONAL_PARTIAL_ONLY_TEXT"))
        XCTAssertFalse(session.transcriptSegments.contains { $0.text.contains("PROVISIONAL") })
        XCTAssertFalse(liveSnapshot.utterances.isEmpty, "sanity: the live snapshot really did hold provisional content")
    }
}
