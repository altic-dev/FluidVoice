@testable import FluidVoice_Debug
import XCTest

@MainActor
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

    func testTransferImportPreservesWhitespaceOnlyReplacements() throws {
        let document = DictionaryTransferDocument(
            replacements: [DictionaryTransferReplacement(from: ["new line"], to: "\n")],
            customWords: []
        )

        let state = try DictionaryTransferService.importState(
            document: document,
            mode: .replace,
            currentReplacements: [],
            currentCustomWords: []
        )

        XCTAssertEqual(state.replacements.map(\.replacement), ["\n"])
        XCTAssertEqual(state.replacements.first?.triggers, ["new line"])
    }
}
