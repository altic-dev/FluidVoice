@testable import FluidVoice_Debug
import XCTest

#if arch(arm64)

// `mergeAdjacentTurns` joins consecutive turns from the same speaker across short pauses.
// When clustering collapses to one label, that intentionally produces one longer segment;
// the tests below pin down both the merge rules and that interaction.

final class SpeakerTurnMergingTests: XCTestCase {
    private typealias Turn = SpeakerDiarizationService.SpeakerTurn

    private func turn(_ speaker: String, _ start: Double, _ end: Double) -> Turn {
        Turn(speakerLabel: speaker, startSeconds: start, endSeconds: end)
    }

    func testEmptyInput() {
        XCTAssertTrue(SpeakerDiarizationService.mergeAdjacentTurns([]).isEmpty)
    }

    func testSingleTurnIsUnchanged() {
        let input = [self.turn("Speaker 1", 0, 5)]
        let merged = SpeakerDiarizationService.mergeAdjacentTurns(input)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].startSeconds, 0)
        XCTAssertEqual(merged[0].endSeconds, 5)
    }

    func testSameSpeakerAcrossShortGapIsMerged() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 1", 5.5, 9),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].endSeconds, 9)
    }

    func testSameSpeakerAcrossLongGapStaysSeparate() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 1", 6.5, 9),
        ])
        XCTAssertEqual(merged.count, 2, "1.5s exceeds the 1.0s merge gap")
    }

    func testGapExactlyAtTheLimitIsMerged() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 1", 6.0, 9),
        ])
        XCTAssertEqual(merged.count, 1, "a gap of exactly maxGapSeconds still merges")
    }

    func testDifferentSpeakersAreNeverMerged() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 5),
            self.turn("Speaker 2", 5.1, 9),
        ])
        XCTAssertEqual(merged.count, 2)
    }

    /// The coupling itself: identical labels plus short pauses collapse a rapid exchange into
    /// one long block. With correct labels the same input stays separated.
    func testCollapsedLabelsWeldDialogueIntoOneSegment() {
        let rapidExchange: [(Double, Double)] = [
            (0, 3), (3.4, 6), (6.3, 9), (9.5, 12), (12.4, 15),
        ]

        let allOneSpeaker = rapidExchange.map { self.turn("Speaker 1", $0.0, $0.1) }
        let collapsed = SpeakerDiarizationService.mergeAdjacentTurns(allOneSpeaker)
        XCTAssertEqual(collapsed.count, 1, "one label + short pauses = one block")
        XCTAssertEqual(collapsed[0].durationSeconds, 15, accuracy: 0.001)

        let alternating = rapidExchange.enumerated().map {
            self.turn($0.offset % 2 == 0 ? "Speaker 1" : "Speaker 2", $0.element.0, $0.element.1)
        }
        let kept = SpeakerDiarizationService.mergeAdjacentTurns(alternating)
        XCTAssertEqual(kept.count, 5, "correct labels keep the exchange separated")
    }

    /// Regression: diarization segments can overlap at boundaries. A later
    /// same-speaker turn that ends inside the accumulated turn used to overwrite
    /// `endSeconds` with its own (earlier) end, dropping the trailing audio.
    func testOverlappingSameSpeakerTurnDoesNotShrinkMergedRange() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 10),
            self.turn("Speaker 1", 5, 8),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].startSeconds, 0)
        XCTAssertEqual(merged[0].endSeconds, 10, "a contained turn must not shrink the merged range")
    }

    /// A turn ending exactly at the accumulated end is the normal adjacent case
    /// and must still extend (or hold) the range to that boundary.
    func testTouchingSameSpeakerTurnExtendsToEnd() {
        let merged = SpeakerDiarizationService.mergeAdjacentTurns([
            self.turn("Speaker 1", 0, 10),
            self.turn("Speaker 1", 9.5, 12),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].endSeconds, 12)
    }

    func testOverlongRunIsCappedNotMergedIndefinitely() {
        var turns: [Turn] = []
        var t = 0.0
        while t < 25 * 60 {
            turns.append(self.turn("Speaker 1", t, t + 30))
            t += 30.5
        }
        let merged = SpeakerDiarizationService.mergeAdjacentTurns(turns)
        XCTAssertGreaterThan(merged.count, 1, "a run longer than the 20-minute cap must be split")
        for segment in merged {
            XCTAssertLessThanOrEqual(segment.durationSeconds, 20 * 60 + 60)
        }
    }
}

final class SpeakerTranscriptSegmentTests: XCTestCase {
    func testPlainTextIncludesMinuteTimestamp() {
        let segment = SpeakerTranscriptSegment(
            speaker: "Speaker 1",
            startSeconds: 65.9,
            endSeconds: 70,
            text: "Hello"
        )

        XCTAssertEqual(segment.plainText, "[1:05] Speaker 1: Hello")
    }

    func testPlainTextIncludesHourTimestamp() {
        let segment = SpeakerTranscriptSegment(
            speaker: "Speaker 2",
            startSeconds: 3_661,
            endSeconds: 3_670,
            text: "Still here"
        )

        XCTAssertEqual(segment.plainText, "[1:01:01] Speaker 2: Still here")
    }
}

#endif
