@testable import FluidVoice_Debug
import XCTest

final class CustomDictionaryManualEntryTests: XCTestCase {
    func testKeepsWhitespaceOnlyReplacements() {
        XCTAssertEqual(CustomDictionaryManualEntry.sanitizedReplacement("\n"), "\n")
        XCTAssertEqual(CustomDictionaryManualEntry.sanitizedReplacement(" "), " ")
        XCTAssertEqual(CustomDictionaryManualEntry.sanitizedReplacement("\t"), "\t")
        XCTAssertEqual(CustomDictionaryManualEntry.sanitizedReplacement(""), "")
        XCTAssertEqual(CustomDictionaryManualEntry.sanitizedReplacement("  FluidVoice \n"), "FluidVoice")
    }

    func testRendersWhitespaceReplacementsVisibly() {
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText("\n"), "⏎")
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText(" "), "␣")
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText("\t"), "⇥")
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText(" \n"), "␣⏎")
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText("FluidVoice"), "FluidVoice")
        XCTAssertEqual(CustomDictionaryManualEntry.replacementDisplayText(""), "")
    }
}
