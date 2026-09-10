@testable import FluidVoice_Debug
import Foundation
import XCTest
import ZeppelinEmbed

/// The sidebar search index.
///
/// `reconcile` is the only write path, so these tests pin the one property it must
/// have: after any call, the namespace equals the records handed in, whatever was
/// there before.
final class SearchIndexTests: XCTestCase {
    private var root: URL!
    private var index: SearchIndex!

    override func setUpWithError() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchIndexTests-\(UUID().uuidString)", isDirectory: true)
        self.index = SearchIndex(root: FluidZeppelinRoot(root: self.root))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.root)
        self.root = nil
        self.index = nil
    }

    private static func record(_ text: String, revision: UInt64 = 1) -> SearchIndexRecord {
        SearchIndexRecord(id: UUID(), revision: revision, timestamp: Date(), text: text)
    }

    private func ids(_ kind: SearchIndexKind, query: String) async throws -> Set<UUID> {
        Set(try await self.index.query(kind, text: query, limit: 50).map(\.id))
    }

    private func count(_ kind: SearchIndexKind) async throws -> Int {
        Int(try await self.index.namespace(kind).count().count)
    }

    // MARK: - Reconcile

    func testFirstReconcileIndexesEveryRowAndTheSecondWritesNothing() async throws {
        let records = (1...3).map { Self.record("meeting number \($0)") }

        let first = try await self.index.reconcile(.history, with: records)
        XCTAssertEqual(first, .init(upserted: 3, deleted: 0))
        let count = try await self.count(.history)
        XCTAssertEqual(count, 3)

        let second = try await self.index.reconcile(.history, with: records)
        XCTAssertEqual(second, .init(upserted: 0, deleted: 0))
    }

    /// Covers delete, clear, and the silent evictions at the transcript and chat caps:
    /// the index only ever sees "these are the rows now".
    func testRowsMissingFromTheStoreAreDeleted() async throws {
        let records = (1...4).map { Self.record("harbour lights \($0)") }
        try await self.index.reconcile(.transcripts, with: records)

        let kept = Array(records.prefix(2))
        let report = try await self.index.reconcile(.transcripts, with: kept)
        XCTAssertEqual(report, .init(upserted: 0, deleted: 2))
        let found = try await self.ids(.transcripts, query: "harbour")
        XCTAssertEqual(found, Set(kept.map(\.id)))

        let cleared = try await self.index.reconcile(.transcripts, with: [])
        XCTAssertEqual(cleared, .init(upserted: 0, deleted: 2))
        let count = try await self.count(.transcripts)
        XCTAssertEqual(count, 0)
    }

    func testAHigherRevisionReplacesTheTextAndAnEqualOneIsLeftAlone() async throws {
        let original = Self.record("first draft", revision: 10)
        try await self.index.reconcile(.chats, with: [original])

        let same = try await self.index.reconcile(.chats, with: [original])
        XCTAssertEqual(same.upserted, 0)

        let edited = SearchIndexRecord(
            id: original.id, revision: 11, timestamp: original.timestamp, text: "second draft"
        )
        let report = try await self.index.reconcile(.chats, with: [edited])
        XCTAssertEqual(report.upserted, 1)
        let old = try await self.ids(.chats, query: "first")
        XCTAssertTrue(old.isEmpty)
        let new = try await self.ids(.chats, query: "second")
        XCTAssertEqual(new, [original.id])
    }

    /// A damaged namespace is moved aside by `FluidZeppelinRoot`; the next reconcile
    /// then refills the empty one. Nothing is lost because the store still has it.
    func testAResetNamespaceIsRefilledByTheNextReconcile() async throws {
        let records = (1...3).map { Self.record("recoverable \($0)") }
        try await self.index.reconcile(.history, with: records)
        try await self.index.namespace(.history).close()

        let manifest = self.root
            .appendingPathComponent(SearchIndexKind.history.rawValue, isDirectory: true)
            .appendingPathComponent("manifest.ze")
        let original = try Data(contentsOf: manifest)
        try original.prefix(original.count / 2).write(to: manifest)

        // A fresh root, as after a relaunch: the cached handle above is gone.
        self.index = SearchIndex(root: FluidZeppelinRoot(root: self.root))
        let report = try await self.index.reconcile(.history, with: records)
        XCTAssertEqual(report, .init(upserted: 3, deleted: 0))
        let found = try await self.ids(.history, query: "recoverable")
        XCTAssertEqual(found, Set(records.map(\.id)))
    }

    // MARK: - Query

    /// The reason for zeppelin-embed 0.3.0: the last word is a prefix, and thanks to
    /// its two-way expansion the mid-word states of a stemmed word still match.
    func testTheLastWordMatchesAsAPrefixWhileTyping() async throws {
        let meeting = Self.record("meeting notes from monday")
        let other = Self.record("the harbour lights at dusk")
        try await self.index.reconcile(.history, with: [meeting, other])

        for typed in ["mee", "meet", "meeti", "meetin", "meeting", "notes mo"] {
            let found = try await self.ids(.history, query: typed)
            XCTAssertEqual(found, [meeting.id], "\"\(typed)\" should find the meeting entry")
        }
        let blank = try await self.index.query(.history, text: "   ", limit: 10)
        XCTAssertTrue(blank.isEmpty)
    }

    // MARK: - Records

    func testHistoryRecordHoldsThePastedTextNotTheRawTranscript() {
        let entry = TranscriptionHistoryEntry(
            rawText: "um the raw words",
            processedText: "The clean words.",
            appName: "Notes",
            windowTitle: "Ideas",
            wasAIProcessed: true
        )
        XCTAssertEqual(entry.searchRecord.text, "The clean words.\nNotes\nIdeas")
        XCTAssertEqual(entry.searchRecord.id, entry.id)
    }

    /// `text` is already the speaker segments joined, so they must not be indexed
    /// again on top of it.
    func testTranscriptRecordDoesNotDuplicateSpeakerSegments() {
        let entry = FileTranscriptionEntry(
            fileName: "standup.m4a",
            duration: 1,
            processingTime: 1,
            confidence: 1,
            text: "[00:00] Alice: hello there\n\n[00:05] Bob: hello back",
            speakerSegments: [
                SpeakerTranscriptSegment(speaker: "Alice", startSeconds: 0, endSeconds: 5, text: "hello there"),
                SpeakerTranscriptSegment(speaker: "Bob", startSeconds: 5, endSeconds: 9, text: "hello back"),
            ]
        )
        let text = entry.searchRecord.text
        XCTAssertEqual(text.components(separatedBy: "hello").count - 1, 2)
        XCTAssertTrue(text.hasPrefix("standup.m4a\n"))
    }

    func testChatRecordUsesTheUpdateTimeAsRevisionAndIncludesCommands() throws {
        let updated = Date(timeIntervalSince1970: 1_700_000_000.5)
        let session = ChatSession(
            title: "Disk space",
            updatedAt: updated,
            messages: [
                ChatMessage(role: .user, content: "how full is the disk"),
                ChatMessage(
                    role: .tool,
                    content: "",
                    toolCall: .init(id: "1", command: "df -h", workingDirectory: nil, purpose: nil)
                ),
            ]
        )
        let record = try XCTUnwrap(session.searchRecord)
        XCTAssertEqual(record.revision, 1_700_000_000_500)
        XCTAssertEqual(record.text, "Disk space\nhow full is the disk\ndf -h")
        XCTAssertNil(ChatSession(id: "not-a-uuid").searchRecord)
    }
}
