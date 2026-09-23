@testable import FluidVoice_Debug
import Foundation
import SQLite3
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
        try Set(await self.index.query(kind, text: query, limit: 50).map(\.id))
    }

    private func count(_ kind: SearchIndexKind) async throws -> Int {
        try Int(await self.index.namespace(kind).count().count)
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

/// Exercises startup through the real history writer, coordinator and Zeppelin queries.
@MainActor
final class SearchIndexCoordinatorTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let writer: TranscriptionHistoryWriter
        let index: SearchIndex

        var historyURL: URL {
            self.root.appendingPathComponent("history.sqlite3")
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchIndexCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        let suite = "SearchIndexCoordinatorTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: root.appendingPathComponent("history.sqlite3"))
        let fixture = Fixture(
            root: root,
            defaults: defaults,
            writer: writer,
            index: SearchIndex(root: FluidZeppelinRoot(root: root.appendingPathComponent("search")))
        )
        do {
            try await body(fixture)
        } catch {
            _ = await writer.drain()
            throw error
        }
        _ = await writer.drain()
    }

    private func entry(_ text: String) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            rawText: text, processedText: text, appName: "Test", windowTitle: "Test", wasAIProcessed: false
        )
    }

    private func indexedIDs(_ index: SearchIndex) async throws -> Set<UUID> {
        // Inspect membership directly: reconciliation can delete the last record
        // between a separate count and lexical query, which rejects an empty index.
        let store = try await index.namespace(.history)
        var ids = Set<UUID>()
        for try await document in store.documents(fields: []) {
            ids.insert(document.id.uuid)
        }
        return ids
    }

    private func waitForIndexedIDs(_ expected: Set<UUID>, in index: SearchIndex) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var actual = try await self.indexedIDs(index)
        while actual != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            actual = try await self.indexedIDs(index)
        }
        XCTAssertEqual(actual, expected)
    }

    func testSlowStartupKeepsExistingIndexUntilHistoryLoads() async throws {
        try await self.withFixture { fixture in
            let saved = self.entry("startup saved dictation")
            let stale = self.entry("startup stale index record")
            try fixture.defaults.set(JSONEncoder().encode([saved]), forKey: "TranscriptionHistoryEntries")
            try await fixture.index.reconcile(.history, with: [saved.searchRecord, stale.searchRecord])

            // The initial migration needs a write lock. Hold it longer than the 250 ms debounce.
            _ = try TranscriptionHistoryDatabase(url: fixture.historyURL)
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(fixture.historyURL.path, &connection), SQLITE_OK)
            let database = try XCTUnwrap(connection)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
            defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }

            let history = TranscriptionHistoryStore(writer: fixture.writer)
            let coordinator = SearchIndexCoordinator(index: fixture.index)
            defer { withExtendedLifetime(coordinator) {} }
            coordinator.start(historyStore: history)

            try await Task.sleep(for: .milliseconds(700))
            XCTAssertTrue(history.isLoading, "The fixture must keep loading beyond the debounce")
            let duringLoad = try await self.indexedIDs(fixture.index)
            XCTAssertEqual(duringLoad, [saved.id, stale.id], "An incomplete startup snapshot must not delete indexed history")

            XCTAssertEqual(sqlite3_exec(database, "COMMIT", nil, nil, nil), SQLITE_OK)
            try await history.waitUntilLoaded()
            try await self.waitForIndexedIDs([saved.id], in: fixture.index)
        }
    }

    func testFailedLoadAndEditsPreserveIndexUntilRetryMergesCompleteHistory() async throws {
        try await self.withFixture { fixture in
            let saved = self.entry("startup saved dictation")
            let deleted = self.entry("startup deleted while unavailable")
            let stale = self.entry("startup stale index record")
            let pending = self.entry("startup new dictation")
            fixture.defaults.set(Data("invalid JSON".utf8), forKey: "TranscriptionHistoryEntries")
            try await fixture.index.reconcile(.history, with: [saved, deleted, stale].map(\.searchRecord))

            let history = TranscriptionHistoryStore(writer: fixture.writer)
            let coordinator = SearchIndexCoordinator(index: fixture.index)
            defer { withExtendedLifetime(coordinator) {} }
            coordinator.start(historyStore: history)
            do {
                try await history.waitUntilLoaded()
                XCTFail("The corrupt history fixture must fail to load")
            } catch {}
            XCTAssertFalse(history.isLoading)
            XCTAssertNotNil(history.persistenceError)

            try await Task.sleep(for: .milliseconds(700))
            let afterFailure = try await self.indexedIDs(fixture.index)
            XCTAssertEqual(afterFailure, [saved.id, deleted.id, stale.id])

            history.addEntry(
                id: pending.id,
                timestamp: pending.timestamp,
                rawText: pending.rawText,
                processedText: pending.processedText,
                appName: pending.appName,
                windowTitle: pending.windowTitle
            )
            history.deleteEntry(id: deleted.id)
            try await Task.sleep(for: .milliseconds(700))
            let afterEdits = try await self.indexedIDs(fixture.index)
            XCTAssertEqual(afterEdits, [saved.id, deleted.id, stale.id], "Edits after a failed load are still an incomplete snapshot")

            try fixture.defaults.set(JSONEncoder().encode([saved, deleted]), forKey: "TranscriptionHistoryEntries")
            history.retryPersistence()
            try await history.waitUntilLoaded()
            XCTAssertNil(history.persistenceError)
            XCTAssertEqual(Set(history.entries.map(\.id)), [saved.id, pending.id])
            try await self.waitForIndexedIDs([saved.id, pending.id], in: fixture.index)
            await history.finishPendingWrites()
        }
    }

    func testSuccessfulEmptyLoadDeletesStaleIndexRecords() async throws {
        try await self.withFixture { fixture in
            let stale = self.entry("startup stale index record")
            try await fixture.index.reconcile(.history, with: [stale.searchRecord])
            let history = TranscriptionHistoryStore(writer: fixture.writer)
            let coordinator = SearchIndexCoordinator(index: fixture.index)
            defer { withExtendedLifetime(coordinator) {} }
            coordinator.start(historyStore: history)

            try await history.waitUntilLoaded()
            XCTAssertTrue(history.entries.isEmpty)
            try await self.waitForIndexedIDs([], in: fixture.index)
        }
    }

    func testClearingLoadedHistoryDeletesIndexedRecords() async throws {
        try await self.withFixture { fixture in
            let saved = self.entry("startup saved dictation")
            try fixture.defaults.set(JSONEncoder().encode([saved]), forKey: "TranscriptionHistoryEntries")
            try await fixture.index.reconcile(.history, with: [saved.searchRecord])
            // The isolated history has no audio; never clear the user's shared audio directory.
            let history = TranscriptionHistoryStore(writer: fixture.writer, deleteAllAudioFiles: {})
            let coordinator = SearchIndexCoordinator(index: fixture.index)
            defer { withExtendedLifetime(coordinator) {} }
            coordinator.start(historyStore: history)

            try await history.waitUntilLoaded()
            try await Task.sleep(for: .milliseconds(700))
            let beforeClear = try await self.indexedIDs(fixture.index)
            XCTAssertEqual(beforeClear, [saved.id])
            history.clearAllHistory()
            try await self.waitForIndexedIDs([], in: fixture.index)
            await history.finishPendingWrites()
        }
    }

    /// A restore can put different text under an id the index already holds. The
    /// restored entry therefore has to carry a higher revision than the indexed one,
    /// or reconcile keeps serving the text from before the restore.
    func testRestoringDifferentTextUnderAnIndexedEntryReplacesIt() async throws {
        try await self.withFixture { fixture in
            let saved = self.entry("startup saved dictation")
            try fixture.defaults.set(JSONEncoder().encode([saved]), forKey: "TranscriptionHistoryEntries")
            try await fixture.index.reconcile(.history, with: [saved.searchRecord])
            let history = TranscriptionHistoryStore(writer: fixture.writer, deleteAllAudioFiles: {})
            let coordinator = SearchIndexCoordinator(index: fixture.index)
            defer { withExtendedLifetime(coordinator) {} }
            coordinator.start(historyStore: history)
            try await history.waitUntilLoaded()

            history.restore(from: [TranscriptionHistoryEntry(
                id: saved.id,
                timestamp: saved.timestamp,
                rawText: "startup restored dictation",
                processedText: "startup restored dictation",
                appName: "Test",
                windowTitle: "Test",
                wasAIProcessed: false
            )])

            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var restored = try await fixture.index.query(.history, text: "restored", limit: 50).map(\.id)
            while restored.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                restored = try await fixture.index.query(.history, text: "restored", limit: 50).map(\.id)
            }
            XCTAssertEqual(restored, [saved.id])
            let stale = try await fixture.index.query(.history, text: "saved", limit: 50)
            XCTAssertTrue(stale.isEmpty, "The text from before the restore must not survive in the index")
            await history.finishPendingWrites()
        }
    }

    func testSubscribingAfterLoadingIndexesCurrentSnapshot() async throws {
        try await self.withFixture { fixture in
            let saved = self.entry("startup saved dictation")
            let stale = self.entry("startup stale index record")
            try fixture.defaults.set(JSONEncoder().encode([saved]), forKey: "TranscriptionHistoryEntries")
            try await fixture.index.reconcile(.history, with: [stale.searchRecord])
            let history = TranscriptionHistoryStore(writer: fixture.writer)
            try await history.waitUntilLoaded()

            let coordinator = SearchIndexCoordinator(index: fixture.index)
            defer { withExtendedLifetime(coordinator) {} }
            coordinator.start(historyStore: history)
            try await self.waitForIndexedIDs([saved.id], in: fixture.index)
        }
    }
}
