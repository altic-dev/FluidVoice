@testable import FluidVoice_Debug
import Foundation
import XCTest

final class HistoryCopyTests: XCTestCase {
    private func makeEntry(raw: String, processed: String, aiProcessed: Bool) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            rawText: raw,
            processedText: processed,
            appName: "Notes",
            windowTitle: "Draft",
            wasAIProcessed: aiProcessed
        )
    }

    func testTextPrefersProcessedText() {
        let entry = makeEntry(raw: " raw ", processed: " processed ", aiProcessed: true)
        XCTAssertEqual(HistoryCopy.text(for: entry), "processed")
    }

    func testTextFallsBackToRawWhenProcessedEmpty() {
        let entry = makeEntry(raw: " raw ", processed: "   ", aiProcessed: false)
        XCTAssertEqual(HistoryCopy.text(for: entry), "raw")
    }

    func testTextIsNilWhenBothEmpty() {
        let entry = makeEntry(raw: "  ", processed: "  ", aiProcessed: false)
        XCTAssertNil(HistoryCopy.text(for: entry))
    }

    func testItemProvidersEmptyForNilSelection() {
        XCTAssertTrue(HistoryCopy.itemProviders(for: nil).isEmpty)
    }

    func testItemProvidersEmptyForEmptyEntry() {
        let entry = makeEntry(raw: "  ", processed: "  ", aiProcessed: false)
        XCTAssertTrue(HistoryCopy.itemProviders(for: entry).isEmpty)
    }

    func testItemProvidersHasOneProviderForNonEmptyEntry() {
        let entry = makeEntry(raw: " raw ", processed: " processed ", aiProcessed: true)
        XCTAssertEqual(HistoryCopy.itemProviders(for: entry).count, 1)
    }
}
