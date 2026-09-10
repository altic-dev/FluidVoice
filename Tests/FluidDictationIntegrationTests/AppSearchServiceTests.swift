@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The query side of the sidebar search.
@MainActor
final class AppSearchServiceTests: XCTestCase {
    private struct Row {
        let id: UUID
        let date: Date
    }

    // MARK: - Ranking

    func testHitsAreOrderedByScoreThenNewestAndUnknownRowsAreDropped() {
        let old = Row(id: UUID(), date: Date(timeIntervalSince1970: 100))
        let new = Row(id: UUID(), date: Date(timeIntervalSince1970: 200))
        let best = Row(id: UUID(), date: Date(timeIntervalSince1970: 0))
        let rows = Dictionary(uniqueKeysWithValues: [old, new, best].map { ($0.id, $0) })
        let hits = [
            SearchIndex.Hit(id: old.id, score: 1),
            SearchIndex.Hit(id: UUID(), score: 9),
            SearchIndex.Hit(id: new.id, score: 1),
            SearchIndex.Hit(id: best.id, score: 2),
        ]

        let ordered = AppSearchService.ranked(hits, rows: rows, date: \.date) { row in
            AppSearchHit(kind: .history, target: .history(row.id), title: "", snippet: "", date: row.date)
        }

        XCTAssertEqual(ordered.map(\.target), [.history(best.id), .history(new.id), .history(old.id)])
    }

    // MARK: - Stale results

    /// Two keystrokes in quick succession: only the second one's answer may land.
    func testANewerQueryReplacesOneStillDebouncing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSearchServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AppSearchService(index: SearchIndex(root: FluidZeppelinRoot(root: root)))

        service.query = "launch at startup"
        service.query = "accent color"
        try await Task.sleep(for: .milliseconds(600))

        let settings = try XCTUnwrap(service.groups.first { $0.kind == .settings })
        XCTAssertTrue(settings.hits.contains { $0.target == .settings(.accentColor) })
        XCTAssertFalse(settings.hits.contains { $0.target == .settings(.launchAtStartup) })

        service.query = "   "
        XCTAssertTrue(service.groups.isEmpty)
    }

    func testChangingQueryImmediatelyInvalidatesPublishedResults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSearchServiceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AppSearchService(index: SearchIndex(root: FluidZeppelinRoot(root: root)))

        service.query = "launch at startup"
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(service.groups.isEmpty)

        service.query = "accent color"

        XCTAssertTrue(service.groups.isEmpty)
    }

    func testTranscriptSearchSelectionTargetsItsDetailCard() {
        let id = UUID()

        XCTAssertEqual(MeetingTranscriptionScrollTarget.selectedDetail(id), .detail(id))
        XCTAssertNil(MeetingTranscriptionScrollTarget.selectedDetail(nil))
    }

    // MARK: - Snippets

    func testSnippetMarksEveryQueryWordIncludingByPrefix() {
        let snippet = AppSearchSnippet.make("Two meetings today.\nOne Meeting tomorrow.", query: "meeting")
        let marked = snippet.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(snippet[$0.range].characters) }

        XCTAssertEqual(String(snippet.characters), "Two meetings today. One Meeting tomorrow.")
        XCTAssertEqual(marked, ["meeting", "Meeting"])
    }

    func testSnippetWindowsAroundTheFirstMatchWithEllipses() {
        let filler = String(repeating: "word ", count: 60)
        let snippet = String(AppSearchSnippet.make(filler + "harbour lights " + filler, query: "harbour").characters)

        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("harbour lights"))
        XCTAssertLessThan(snippet.count, AppSearchSnippet.window + 4)
    }

    func testSnippetWithNoMatchStartsAtTheBeginning() {
        let snippet = String(AppSearchSnippet.make("short text", query: "zzz").characters)
        XCTAssertEqual(snippet, "short text")
    }

    func testInMemoryMatchRequiresEveryWord() {
        XCTAssertTrue(AppSearchService.matches("acc col", ["Accent Color"]))
        XCTAssertFalse(AppSearchService.matches("accent blue", ["Accent Color"]))
        XCTAssertTrue(AppSearchService.matches("cafe", ["café"]))
    }
}
