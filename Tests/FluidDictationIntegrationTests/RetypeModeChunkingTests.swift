@testable import FluidVoice_Debug
import XCTest

// Regression tests for Retype Mode's character-by-character (chunkSize: 1) unicode
// chunking. `unicodeChunkEnd`'s surrogate-pair guard was written for the bulk path
// (chunkSize 200): on a boundary split it backs off by one unit, deferring the pair to
// the next chunk. At chunkSize 1 that backoff produced an *empty* chunk, which the
// `max(end, start + 1)` safety net then forced back to a 1-unit chunk anyway — silently
// splitting the surrogate pair into two lone-surrogate CGEvents.
// See PR review on https://github.com/altic-dev/FluidVoice/pull/562.

final class RetypeModeChunkingTests: XCTestCase {
    private func chunks(of text: String, chunkSize: Int) -> [[UInt16]] {
        let units = Array(text.utf16)
        var result: [[UInt16]] = []
        var start = 0
        while start < units.count {
            let end = TypingService.unicodeChunkEnd(in: units, start: start, chunkSize: chunkSize)
            result.append(Array(units[start..<end]))
            start = end
        }
        return result
    }

    func testChunkSizeOneKeepsSurrogatePairTogether() {
        // "a" + 🎉 (U+1F389, surrogate pair D83C DF89) + "b"
        let result = self.chunks(of: "a\u{1F389}b", chunkSize: 1)
        XCTAssertEqual(result, [
            [0x0061],
            [0xD83C, 0xDF89],
            [0x0062],
        ])
    }

    func testChunkSizeOneSplitsPlainCharactersIndividually() {
        let result = self.chunks(of: "abc", chunkSize: 1)
        XCTAssertEqual(result, [[0x0061], [0x0062], [0x0063]])
    }

    func testChunkSizeOneKeepsConsecutiveSurrogatePairsTogether() {
        // Two emoji back-to-back: 🎉 (D83C DF89) + 🎊 (D83C DF8A)
        let result = self.chunks(of: "\u{1F389}\u{1F38A}", chunkSize: 1)
        XCTAssertEqual(result, [
            [0xD83C, 0xDF89],
            [0xD83C, 0xDF8A],
        ])
    }

    func testNoLoneSurrogateHalfIsEverEmittedAtChunkSizeOne() {
        let samples = ["\u{1F389}", "a\u{1F389}", "\u{1F389}b", "a\u{1F389}b\u{1F38A}c", "\u{1F389}\u{1F38A}\u{1F38B}"]
        for text in samples {
            for chunk in self.chunks(of: text, chunkSize: 1) where chunk.count == 1 {
                let isLoneSurrogate = (0xD800...0xDFFF).contains(chunk[0])
                XCTAssertFalse(isLoneSurrogate, "Lone surrogate half emitted for \(text): \(chunk)")
            }
        }
    }

    func testBulkChunkSizeStillDefersSurrogatePairToNextChunkBoundary() {
        // Regression guard: the fix must not change the existing (already-correct)
        // bulk-path behavior of backing off before a boundary-straddling pair.
        let text = "aaa" + "\u{1F389}" + "bbb"
        let result = self.chunks(of: text, chunkSize: 4)
        XCTAssertEqual(result, [
            [0x0061, 0x0061, 0x0061],
            [0xD83C, 0xDF89, 0x0062, 0x0062],
            [0x0062],
        ])
    }

    // MARK: - Ramp boundary (slowTypeRampCharCount)

    func testZeroRampCharCountSkipsRampPhaseEntirely() {
        let units = Array("abc".utf16)
        XCTAssertEqual(TypingService.rampEnd(for: units, rampCharCount: 0), 0)
    }

    func testZeroRampCharCountDoesNotSplitLeadingSurrogatePair() {
        // Before the fix, a ramp length of 0 still floored to a 1-unit ramp slice —
        // if the text starts with an emoji, that 1-unit slice is a lone high surrogate.
        let units = Array("\u{1F389}bc".utf16)
        let rampEnd = TypingService.rampEnd(for: units, rampCharCount: 0)
        XCTAssertEqual(rampEnd, 0)
        XCTAssertTrue(Array(units[0..<rampEnd]).isEmpty)
    }

    func testPositiveRampCharCountStillChunksNormally() {
        let units = Array("abcdef".utf16)
        XCTAssertEqual(TypingService.rampEnd(for: units, rampCharCount: 3), 3)
    }

    func testPositiveRampCharCountDefersStraddlingSurrogatePairToSteadyPhase() {
        // "ab" + 🎉 (D83C DF89) + "cd": a ramp length of 3 would land mid-pair (right after
        // the high surrogate) without the guard in `unicodeChunkEnd`; it must back off to a
        // 2-unit ramp ("ab") instead, deferring the whole pair to the steady phase.
        let units = Array("ab\u{1F389}cd".utf16)
        let rampEnd = TypingService.rampEnd(for: units, rampCharCount: 3)
        XCTAssertEqual(Array(units[0..<rampEnd]), [0x0061, 0x0062])
    }
}
