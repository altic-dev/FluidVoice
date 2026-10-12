import CryptoKit
import Darwin
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

    func testLowerAndEqualRevisionsCannotReplaceNewerIndexedText() async throws {
        let latest = Self.record("latest harbour manuscript", revision: 9)
        try await self.index.reconcile(.history, with: [latest])
        for revision: UInt64 in [1, 9] {
            let stale = SearchIndexRecord(id: latest.id, revision: revision, timestamp: latest.timestamp, text: "obsolete lighthouse manuscript")
            let report = try await self.index.reconcile(.history, with: [stale])
            XCTAssertEqual(report, .init(upserted: 0, deleted: 0))
            let current = try await self.ids(.history, query: "harb")
            let replaced = try await self.ids(.history, query: "lighth")
            XCTAssertEqual(current, [latest.id])
            XCTAssertTrue(replaced.isEmpty)
        }
    }

    func testReconcilingOneKindDoesNotDeleteOrReplaceOtherNamespaces() async throws {
        let history = Self.record("harbour history")
        let transcript = SearchIndexRecord(id: history.id, revision: 17, timestamp: history.timestamp, text: "lighthouse transcript")
        let chat = SearchIndexRecord(id: history.id, revision: 30, timestamp: history.timestamp, text: "mountain chat")
        try await self.index.reconcile(.history, with: [history])
        try await self.index.reconcile(.transcripts, with: [transcript])
        try await self.index.reconcile(.chats, with: [chat])
        let report = try await self.index.reconcile(.history, with: [])
        XCTAssertEqual(report, .init(upserted: 0, deleted: 1))
        let historyCount = try await self.count(.history)
        let transcripts = try await self.ids(.transcripts, query: "lighth")
        let chats = try await self.ids(.chats, query: "mount")
        XCTAssertEqual(historyCount, 0)
        XCTAssertEqual(transcripts, [history.id])
        XCTAssertEqual(chats, [history.id])
    }

    func testSealedRecordOnlyNamespaceReopensWithoutBackfillAndKeepsPrefixMatches() async throws {
        XCTAssertNil(SearchIndex.spec.vectorSpace)
        XCTAssertTrue(SearchIndex.spec.attributes.isEmpty)
        let directory = self.root.appendingPathComponent("sealed", isDirectory: true)
        let records = [Self.record("meeting notes from monday"), Self.record("harbour lights at dusk")]
        let initialRoot = FluidZeppelinRoot(root: directory)
        let initial = SearchIndex(root: initialRoot)
        do {
            try await initial.reconcile(.history, with: records)
            let store = try await initial.namespace(.history)
            _ = try await store.seal()
            let sealed = try await store.stats()
            XCTAssertEqual(sealed.activeRowCount, 0, "Record-only rows must leave the active segment when sealed")
        } catch {
            await initialRoot.closeAll()
            throw error
        }
        await initialRoot.closeAll()

        // Distinct roots and actor handles exercise the actual reopen path, not
        // the cached namespace task from the first reconcile.
        for _ in 0..<3 {
            let reopenedRoot = FluidZeppelinRoot(root: directory)
            let reopened = SearchIndex(root: reopenedRoot)
            do {
                let report = try await reopened.reconcile(.history, with: records)
                XCTAssertEqual(report, .init(upserted: 0, deleted: 0))
                for typed in ["mee", "meetin", "notes mo"] {
                    let hits = try await reopened.query(.history, text: typed, limit: 10)
                    XCTAssertEqual(Set(hits.map(\.id)), [records[0].id])
                }
                let store = try await reopened.namespace(.history)
                let sealed = try await store.stats()
                XCTAssertEqual(sealed.activeRowCount, 0, "An unchanged reopen must not create a fresh active backfill")
            } catch {
                await reopenedRoot.closeAll()
                throw error
            }
            await reopenedRoot.closeAll()
        }
    }

    func testReopenedIndexAppliesInsertDeleteAndRestoredRevisionWithoutRevivingOldText() async throws {
        let directory = self.root.appendingPathComponent("revisions", isDirectory: true)
        let kept = Self.record("original harbour text", revision: 6)
        let removed = Self.record("removed lighthouse text", revision: 4)
        let initialRoot = FluidZeppelinRoot(root: directory)
        let initial = SearchIndex(root: initialRoot)
        do {
            try await initial.reconcile(.history, with: [kept, removed])
            let store = try await initial.namespace(.history)
            _ = try await store.seal()
        } catch {
            await initialRoot.closeAll()
            throw error
        }
        await initialRoot.closeAll()

        let reopenedRoot = FluidZeppelinRoot(root: directory)
        let reopened = SearchIndex(root: reopenedRoot)
        do {
            let restored = SearchIndexRecord(id: kept.id, revision: 7, timestamp: kept.timestamp, text: "restored mountain text")
            let inserted = Self.record("new river text")
            let report = try await reopened.reconcile(.history, with: [restored, inserted])
            XCTAssertEqual(report, .init(upserted: 2, deleted: 1))
            let restoredHits = try await reopened.query(.history, text: "mount", limit: 10)
            let insertedHits = try await reopened.query(.history, text: "riv", limit: 10)
            let oldHits = try await reopened.query(.history, text: "harbour", limit: 10)
            let deletedHits = try await reopened.query(.history, text: "lighthouse", limit: 10)
            XCTAssertEqual(Set(restoredHits.map(\.id)), [kept.id])
            XCTAssertEqual(Set(insertedHits.map(\.id)), [inserted.id])
            XCTAssertTrue(oldHits.isEmpty)
            XCTAssertTrue(deletedHits.isEmpty)
        } catch {
            await reopenedRoot.closeAll()
            throw error
        }
        await reopenedRoot.closeAll()
    }

    func testUnchangedLegacyBackfillSealsOnceAndSmallSubsequentWritesStayActive() async throws {
        let directory = self.root.appendingPathComponent("maintenance", isDirectory: true)
        let records = (0..<260).map { Self.record("maintenance harbour entry \($0)") }
        let legacyRoot = FluidZeppelinRoot(root: directory)
        let legacy = SearchIndex(root: legacyRoot, maintenanceActiveRowLimit: nil)
        do {
            try await legacy.reconcile(.history, with: records)
            let store = try await legacy.namespace(.history)
            let stats = try await store.stats()
            XCTAssertEqual(stats.activeRowCount, 260)
        } catch {
            await legacyRoot.closeAll()
            throw error
        }
        await legacyRoot.closeAll()

        let maintainedRoot = FluidZeppelinRoot(root: directory)
        let maintained = SearchIndex(root: maintainedRoot)
        do {
            let backfill = try await maintained.reconcile(.history, with: records)
            XCTAssertEqual(backfill, .init(upserted: 0, deleted: 0), "Sealing must not relabel unchanged records as new writes")
            let store = try await maintained.namespace(.history)
            let first = try await store.stats()
            XCTAssertEqual(first.activeRowCount, 0)
            XCTAssertGreaterThan(first.segmentBytes, 0)
            let repeated = try await maintained.reconcile(.history, with: records)
            let second = try await store.stats()
            XCTAssertEqual(repeated, .init(upserted: 0, deleted: 0))
            XCTAssertEqual(second.segmentBytes, first.segmentBytes, "An unchanged snapshot must not create another segment")
            XCTAssertEqual(second.activeRowCount, 0)

            let added = Self.record("one additional river entry")
            let insertion = try await maintained.reconcile(.history, with: records + [added])
            let smallWrite = try await store.stats()
            XCTAssertEqual(insertion, .init(upserted: 1, deleted: 0))
            XCTAssertEqual(smallWrite.activeRowCount, 1, "Do not seal after every dictation")
            let hits = try await maintained.query(.history, text: "additional riv", limit: 10)
            XCTAssertEqual(Set(hits.map(\.id)), [added.id])
        } catch {
            await maintainedRoot.closeAll()
            throw error
        }
        await maintainedRoot.closeAll()
    }

    func testFailedSealingPreservesSearchableRecordsAndRetriesOnNextSnapshot() async throws {
        let directory = self.root.appendingPathComponent("maintenance-failure", isDirectory: true)
        let namespace = directory.appendingPathComponent(SearchIndexKind.history.rawValue, isDirectory: true)
        let database = FluidZeppelinRoot(root: directory)
        let records = (0..<260).map { Self.record("permission harbour entry \($0)") }
        let legacy = SearchIndex(root: database, maintenanceActiveRowLimit: nil)
        do {
            try await legacy.reconcile(.history, with: records)
            // The live WAL handle stays writable; immutable segment publication
            // needs a new directory entry and must fail under these permissions.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: namespace.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: namespace.path) }
            let permissionProbe = namespace.appendingPathComponent("permission-probe")
            var deniesCreation = false
            do {
                try Data([0]).write(to: permissionProbe, options: .withoutOverwriting)
            } catch {
                deniesCreation = true
            }
            if !deniesCreation {
                try? FileManager.default.removeItem(at: permissionProbe)
                throw XCTSkip("The test runner can create files despite private directory permissions")
            }
            let maintained = SearchIndex(root: database)
            let report = try await maintained.reconcile(.history, with: records)
            XCTAssertEqual(report, .init(upserted: 0, deleted: 0), "Maintenance failure must not fail an otherwise successful reconcile")
            let store = try await maintained.namespace(.history)
            let failedStats = try await store.stats()
            XCTAssertEqual(failedStats.activeRowCount, 260)
            let hits = try await maintained.query(.history, text: "permission harb", limit: 300)
            XCTAssertEqual(Set(hits.map(\.id)), Set(records.map(\.id)))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: namespace.path)
            let retry = try await maintained.reconcile(.history, with: records)
            let retriedStats = try await store.stats()
            XCTAssertEqual(retry, .init(upserted: 0, deleted: 0))
            XCTAssertEqual(retriedStats.activeRowCount, 0)
            let restoredHits = try await maintained.query(.history, text: "permission harb", limit: 300)
            XCTAssertEqual(Set(restoredHits.map(\.id)), Set(records.map(\.id)))
        } catch {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: namespace.path)
            await database.closeAll()
            throw error
        }
        await database.closeAll()
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
            history.retryLoadingIfNeeded()
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

    func testSearchRetryNeverRewritesSuccessfullyLoadedHistory() async throws {
        try await self.withFixture { fixture in
            let saved = self.entry("saved history must remain untouched")
            try fixture.defaults.set(JSONEncoder().encode([saved]), forKey: "TranscriptionHistoryEntries")
            let history = TranscriptionHistoryStore(writer: fixture.writer)
            try await history.waitUntilLoaded()
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(fixture.historyURL.path, &connection), SQLITE_OK)
            let database = try XCTUnwrap(connection)
            defer { sqlite3_close(database) }
            // retryPersistence's loaded branch deletes every row before rewriting.
            // Make that unintended operation fail instead of merely comparing IDs.
            XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER reject_history_rewrite BEFORE DELETE ON history BEGIN SELECT RAISE(ABORT, 'unexpected history rewrite'); END", nil, nil, nil), SQLITE_OK)
            history.retryLoadingIfNeeded()
            await history.finishPendingWrites()
            XCTAssertNil(history.persistenceError)
            let writeError = await fixture.writer.drain()
            XCTAssertNil(writeError)
            let rows = try await fixture.writer.load()
            XCTAssertEqual(rows.map(\.id), [saved.id])
            XCTAssertEqual(history.entries.map(\.id), [saved.id])
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

    func testFirstSearchPreparationWaitsForLoadedHistoryAndSuppressesSelfRefresh() async throws {
        try await self.withFixture { fixture in
            let saved = self.entry("first query authoritative history")
            try fixture.defaults.set(JSONEncoder().encode([saved]), forKey: "TranscriptionHistoryEntries")
            let history = TranscriptionHistoryStore(writer: fixture.writer)
            try await history.waitUntilLoaded()
            let probe = SearchReconcileProbe(gatedCallCount: 3)
            var refreshCount = 0
            let coordinator = SearchIndexCoordinator(
                index: fixture.index,
                reconcile: { kind, records in try await probe.reconcile(kind, records: records) },
                refresh: { refreshCount += 1 }
            )
            var prepared = false
            let preparation = Task { try await coordinator.prepareForSearch(historyStore: history); prepared = true }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while await probe.calls().count < 3, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let calls = await probe.calls()
                XCTAssertEqual(calls.count, 3)
                guard calls.count == 3 else { throw SearchReconcileProbe.Failure.unavailable }
                let indexedHistory = try XCTUnwrap(calls.first { $0.kind == .history })
                XCTAssertEqual(indexedHistory.records.map(\.id), [saved.id])
                XCTAssertEqual(indexedHistory.records.first?.text, saved.searchRecord.text)
                XCTAssertFalse(prepared, "The first query cannot run against an unfinished history snapshot")
                XCTAssertEqual(refreshCount, 0)
                await probe.releaseAll()
                let completionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !prepared, ContinuousClock.now < completionDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertTrue(prepared)
                guard prepared else { throw SearchReconcileProbe.Failure.unavailable }
                try await preparation.value
                XCTAssertEqual(refreshCount, 0, "Seeding the first search must not cancel and restart its own query")
            } catch {
                await probe.releaseAll()
                await coordinator.stop()
                _ = await preparation.result
                throw error
            }
            await coordinator.stop()
        }
    }
}

private struct SearchBenchmarkRecord: Decodable {
    let id: UUID
    let revision: UInt64
    let timestampMilliseconds: Int64
    let text: String

    var record: SearchIndexRecord {
        SearchIndexRecord(id: self.id, revision: self.revision, timestamp: Date(timeIntervalSince1970: Double(self.timestampMilliseconds) / 1000), text: self.text)
    }
}

private actor SearchReconcileProbe {
    struct Call: Sendable {
        let kind: SearchIndexKind
        let records: [SearchIndexRecord]
    }

    enum Failure: Error { case unavailable }

    private var recorded: [Call] = []
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released = false
    private var active: [SearchIndexKind: Int] = [:]
    private var peak: [SearchIndexKind: Int] = [:]
    private let gatedCallCount: Int
    private let failingCalls: Set<Int>

    init(gatedCallCount: Int = 2, failingCalls: Set<Int> = []) {
        self.gatedCallCount = gatedCallCount
        self.failingCalls = failingCalls
    }

    func reconcile(_ kind: SearchIndexKind, records: [SearchIndexRecord]) async throws -> SearchIndex.ReconcileReport {
        let number = self.recorded.count
        self.recorded.append(Call(kind: kind, records: records))
        self.active[kind, default: 0] += 1
        self.peak[kind] = max(self.peak[kind, default: 0], self.active[kind, default: 0])
        defer { self.active[kind, default: 0] -= 1 }
        if !self.released, number < self.gatedCallCount {
            await withCheckedContinuation { self.gates[number] = $0 }
        }
        if self.failingCalls.contains(number) { throw Failure.unavailable }
        return .init(upserted: records.count, deleted: 0)
    }

    func calls() -> [Call] { self.recorded }
    func maximumConcurrentCalls(_ kind: SearchIndexKind) -> Int { self.peak[kind, default: 0] }
    func release(_ number: Int) { self.gates.removeValue(forKey: number)?.resume() }

    func releaseAll() {
        self.released = true
        let gates = self.gates.values
        self.gates.removeAll()
        for gate in gates {
            gate.resume()
        }
    }
}

@MainActor
final class SearchIndexCoordinatorSchedulingTests: XCTestCase {
    private func entry(_ text: String) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(rawText: text, processedText: text, appName: "Fixture", windowTitle: "Fixture", wasAIProcessed: false)
    }

    private func withProbe(failingCalls: Set<Int> = [], preparationTimeout: Duration = .seconds(20), _ body: (SearchIndexCoordinator, SearchReconcileProbe, () -> Int) async throws -> Void) async throws {
        let probe = SearchReconcileProbe(failingCalls: failingCalls)
        var refreshCount = 0
        let coordinator = SearchIndexCoordinator(
            reconcile: { kind, records in
                try await probe.reconcile(kind, records: records)
            },
            refresh: { refreshCount += 1 },
            preparationTimeout: preparationTimeout
        )
        do {
            try await body(coordinator, probe) { refreshCount }
        } catch {
            await probe.releaseAll()
            await coordinator.stop()
            throw error
        }
        await probe.releaseAll()
        await coordinator.stop()
    }

    private func waitForCalls(_ count: Int, in probe: SearchReconcileProbe) async throws {
        try await self.waitUntil { await probe.calls().count >= count }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await condition() else {
            XCTFail("A bounded search scheduling condition did not complete")
            throw SearchReconcileProbe.Failure.unavailable
        }
    }

    func testRapidSnapshotsKeepOneWorkerAndOnlyTheLatestSuccessor() async throws {
        try await self.withProbe { coordinator, probe, refreshCount in
            let first = self.entry("first snapshot")
            coordinator.submit(.history([first]))
            coordinator.flush()
            try await self.waitForCalls(1, in: probe)
            var latest = first
            for number in 0..<100 {
                latest = self.entry("latest snapshot \(number)")
                coordinator.submit(.history([latest]))
                coordinator.flush()
            }
            let before = await probe.calls()
            XCTAssertEqual(before.count, 1, "A blocked reconcile must not spawn a task chain")
            var completed = false
            var captureStarted = false
            let barrier = Task { captureStarted = true; try await coordinator.waitUntilCurrent(); completed = true }
            try await self.waitUntil { captureStarted }
            await probe.release(0)
            try await self.waitForCalls(2, in: probe)
            XCTAssertFalse(completed, "The current snapshot barrier must include the captured latest snapshot")
            XCTAssertEqual(refreshCount(), 0, "Do not refresh results from an intermediate snapshot")
            let calls = await probe.calls()
            XCTAssertEqual(calls.map { $0.records.map(\.id) }, [[first.id], [latest.id]])
            XCTAssertEqual(calls[1].records.first?.text, latest.searchRecord.text)
            await probe.release(1)
            try await self.waitUntil { completed }
            try await barrier.value
            try await self.waitUntil { refreshCount() == 1 }
            let peak = await probe.maximumConcurrentCalls(.history)
            XCTAssertEqual(peak, 1)
        }
    }

    func testCapturedBarrierIsNotExtendedByLaterSnapshots() async throws {
        try await self.withProbe { coordinator, probe, _ in
            coordinator.submit(.history([self.entry("captured snapshot")]))
            coordinator.flush()
            try await self.waitForCalls(1, in: probe)
            var completed = false
            var captureStarted = false
            let barrier = Task { captureStarted = true; try await coordinator.waitUntilCurrent(); completed = true }
            // Let the barrier capture generation one before sending generation two.
            try await self.waitUntil { captureStarted }
            coordinator.submit(.history([self.entry("later snapshot")]))
            await probe.release(0)
            try await self.waitForCalls(2, in: probe)
            try await self.waitUntil { completed }
            try await barrier.value
            await probe.release(1)
            try await coordinator.waitUntilCurrent()
        }
    }

    func testStopDropsQueuedSnapshotsCancelsWaitersAndDrainsCurrentWork() async throws {
        try await self.withProbe { coordinator, probe, refreshCount in
            coordinator.submit(.history([self.entry("running snapshot")]))
            coordinator.flush()
            try await self.waitForCalls(1, in: probe)
            coordinator.submit(.history([self.entry("queued snapshot")]))
            var barrierCancelled = false
            let barrier = Task {
                do {
                    try await coordinator.waitUntilCurrent()
                    XCTFail("Stop must cancel the barrier")
                } catch is CancellationError {
                    barrierCancelled = true
                } catch {
                    XCTFail("Unexpected barrier failure: \(error)")
                }
            }
            await Task.yield()
            var stopped = false
            let stop = Task { await coordinator.stop(); stopped = true }
            try await self.waitUntil { barrierCancelled }
            XCTAssertFalse(stopped, "Stop must await the actual in-flight write before closeAll")
            await probe.release(0)
            try await self.waitUntil { stopped }
            await stop.value
            await barrier.value
            coordinator.submit(.history([self.entry("after stop")]))
            coordinator.flush()
            do {
                try await coordinator.waitUntilCurrent()
                XCTFail("A stopped coordinator cannot reopen")
            } catch is CancellationError {}
            let calls = await probe.calls()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(refreshCount(), 0, "Late work must not refresh search during termination")
        }
    }

    func testFailedReconcileFinishesBarrierAndExplicitRetryUsesLatestSnapshot() async throws {
        try await self.withProbe(failingCalls: [0]) { coordinator, probe, refreshCount in
            coordinator.submit(.history([self.entry("failed first snapshot")]))
            coordinator.flush()
            try await self.waitForCalls(1, in: probe)
            let latest = self.entry("latest retry snapshot")
            coordinator.submit(.history([latest]))
            var failed = false
            let barrier = Task {
                do {
                    try await coordinator.waitUntilCurrent()
                    XCTFail("The first reconcile is intentionally unavailable")
                } catch SearchReconcileProbe.Failure.unavailable {
                    failed = true
                }
            }
            await Task.yield()
            await probe.release(0)
            try await self.waitUntil { failed }
            try await barrier.value
            XCTAssertEqual(refreshCount(), 0)
            var retried = false
            let retry = Task { try await coordinator.waitUntilCurrent(); retried = true }
            try await self.waitForCalls(2, in: probe)
            let calls = await probe.calls()
            XCTAssertEqual(calls[1].records.map(\.id), [latest.id], "Retry cannot replay an older snapshot over newer input")
            await probe.release(1)
            try await self.waitUntil { retried }
            try await retry.value
            try await self.waitUntil { refreshCount() == 1 }
        }
    }

    func testPreparationTimeoutFinishesPromptlyWithoutStartingAnotherWorker() async throws {
        try await self.withProbe(preparationTimeout: .milliseconds(50)) { coordinator, probe, _ in
            coordinator.submit(.history([self.entry("temporarily slow snapshot")]))
            coordinator.flush()
            try await self.waitForCalls(1, in: probe)
            let start = ContinuousClock.now
            do {
                try await coordinator.waitUntilCurrent()
                XCTFail("The blocked writer must exceed the injected preparation deadline")
            } catch SearchIndexCoordinator.PreparationError.timedOut {}
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            let before = await probe.calls()
            XCTAssertEqual(before.count, 1, "Timeout must not create another index worker")
            await probe.release(0)
            try await coordinator.waitUntilCurrent()
            let peak = await probe.maximumConcurrentCalls(.history)
            XCTAssertEqual(peak, 1)
        }
    }

    func testCancellingOneBarrierDoesNotCancelTheSharedIndexWorkerOrOtherWaiter() async throws {
        try await self.withProbe { coordinator, probe, _ in
            coordinator.submit(.history([self.entry("shared pending snapshot")]))
            coordinator.flush()
            try await self.waitForCalls(1, in: probe)
            var cancelled = false
            var survivorCompleted = false
            let first = Task {
                do {
                    try await coordinator.waitUntilCurrent()
                    XCTFail("This waiter was cancelled")
                } catch is CancellationError {
                    cancelled = true
                }
            }
            let survivor = Task { try await coordinator.waitUntilCurrent(); survivorCompleted = true }
            first.cancel()
            try await self.waitUntil { cancelled }
            try await first.value
            XCTAssertFalse(survivorCompleted)
            await probe.release(0)
            try await self.waitUntil { survivorCompleted }
            try await survivor.value
            let calls = await probe.calls()
            XCTAssertEqual(calls.count, 1)
        }
    }
}

private struct SearchBenchmarkStats: Codable {
    let activeRows: UInt64
    let residentOwnedBytes: UInt64
    let mappedBytes: UInt64
    let segmentBytes: UInt64
    let walBytes: UInt64
    let physicalFootprint: UInt64?

    init(_ stats: StoreStats) {
        self.activeRows = stats.activeRowCount
        self.residentOwnedBytes = stats.residentOwnedBytes
        self.mappedBytes = stats.mappedBytes
        self.segmentBytes = stats.segmentBytes
        self.walBytes = stats.walBytes
        self.physicalFootprint = stats.physicalFootprint
    }
}

private struct SearchBenchmarkReopen: Codable {
    let queryMilliseconds: Double
    let reconcileMilliseconds: Double
    let returnedHits: Int
    let beforeQueryPhysicalFootprintBytes: UInt64?
    let afterQueryPhysicalFootprintBytes: UInt64?
    let afterReconcilePhysicalFootprintBytes: UInt64?
    let stats: SearchBenchmarkStats
}

private struct SearchBenchmarkVariant: Codable {
    let label: String
    let recordCount: Int
    let openMilliseconds: Double
    let reconcileMilliseconds: Double
    let initialUpserts: Int
    let initialDeletes: Int
    let beforeOpenPhysicalFootprintBytes: UInt64?
    let afterOpenPhysicalFootprintBytes: UInt64?
    let afterReconcilePhysicalFootprintBytes: UInt64?
    let before: SearchBenchmarkStats
    let after: SearchBenchmarkStats
    let membershipSHA256: String
    let queryMembershipSHA256: [String: String]
    let reopens: [SearchBenchmarkReopen]
}

extension SearchIndexTests {
    /// Exercises the real coordinator's snapshot construction and index updates,
    /// using synthetic finished dictations only. No audio, preferences or real stores.
    @MainActor
    func testOptInSequentialDictationMemoryGrowth() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLUIDVOICE_SEARCH_APPEND_MEMORY_REPORT"], !path.isEmpty else {
            throw XCTSkip("Supply an external JSON report path for the incremental memory simulation")
        }
        let database = FluidZeppelinRoot(root: self.root.appendingPathComponent("append-memory", isDirectory: true))
        let index = SearchIndex(root: database)
        let coordinator = SearchIndexCoordinator(index: index, refresh: {}, preparationTimeout: .seconds(120))
        var entries = (0..<12_880).map { number in
            TranscriptionHistoryEntry(
                rawText: "not indexed",
                processedText: "seedhistory item\(number) " + String(repeating: "meeting project update planning notes ", count: 5),
                appName: "Synthetic fixture",
                windowTitle: "Search memory simulation",
                wasAIProcessed: false
            )
        }
        var samples: [SearchAppendMemorySample] = []
        var timings: [Double] = []
        var peak: UInt64 = 0
        var samplerTicks = 0
        var sampler: Task<Void, Never>?
        do {
            coordinator.submit(.history(entries))
            try await coordinator.waitUntilCurrent()
            _ = try await index.query(.history, text: "seedhistory", limit: 50)
            let store = try await index.namespace(.history)
            try samples.append(await self.appendMemorySample("prepared baseline", added: 0, sourceRows: entries.count, store: store))
            peak = Self.physicalFootprint() ?? 0
            sampler = Task {
                // Bound diagnostic storage/work even if native recovery is slow.
                while !Task.isCancelled, samplerTicks < 20_000 {
                    peak = max(peak, Self.physicalFootprint() ?? 0)
                    samplerTicks += 1
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                }
            }
            for added in 1...1024 {
                entries.append(TranscriptionHistoryEntry(
                    rawText: "not indexed",
                    processedText: "appendmarker update\(added) " + String(repeating: "finished dictation project followup ", count: added % 8 + 1),
                    appName: "Synthetic fixture",
                    windowTitle: "Sequential additions",
                    wasAIProcessed: false
                ))
                let started = ContinuousClock.now
                coordinator.submit(.history(entries))
                try await coordinator.waitUntilCurrent()
                timings.append(Self.milliseconds(since: started))
                if added % 32 == 0 || added == 1 || added == 255 || added == 257 {
                    let hits = try await index.query(.history, text: "appendmarker update\(added)", limit: 50)
                    XCTAssertTrue(hits.contains { $0.id == entries.last?.id })
                    try samples.append(await self.appendMemorySample("sequential", added: added, sourceRows: entries.count, store: store))
                }
                if added % 256 == 0 {
                    let stats = try await store.stats()
                    XCTAssertEqual(stats.activeRowCount, 0)
                    print("Search append simulation: \(added) additions indexed and sealed")
                }
            }
            // A rapid event burst must keep only the latest successor snapshot.
            for added in 1025...1280 {
                entries.append(TranscriptionHistoryEntry(
                    rawText: "not indexed",
                    processedText: "burstmarker update\(added) " + String(repeating: "rapid finished history update ", count: 6),
                    appName: "Synthetic fixture",
                    windowTitle: "Burst additions",
                    wasAIProcessed: false
                ))
                coordinator.submit(.history(entries))
            }
            try await coordinator.waitUntilCurrent()
            try samples.append(await self.appendMemorySample("burst drained", added: 1280, sourceRows: entries.count, store: store))
            let burstStats = try await store.stats()
            XCTAssertEqual(burstStats.activeRowCount, 0)
            // More words require more memory even with the same row-count limit.
            for added in 1281...1408 {
                entries.append(TranscriptionHistoryEntry(
                    rawText: "not indexed",
                    processedText: "longmarker update\(added) " + String(repeating: "longer dictation contains discussion of project details and followup actions ", count: 220),
                    appName: "Synthetic fixture",
                    windowTitle: "Long additions",
                    wasAIProcessed: false
                ))
                coordinator.submit(.history(entries))
                try await coordinator.waitUntilCurrent()
                if added % 32 == 0 {
                    try samples.append(await self.appendMemorySample("long entries", added: added, sourceRows: entries.count, store: store))
                }
            }
            try await Task.sleep(for: .milliseconds(300))
            try samples.append(await self.appendMemorySample("settled", added: 1408, sourceRows: entries.count, store: store))
            var actual = Set<UUID>()
            for try await row in store.documents(fields: []) {
                actual.insert(row.id.uuid)
            }
            XCTAssertEqual(actual, Set(entries.map(\.id)))
            let latest = try await index.query(.history, text: "longmarker update1408", limit: 50)
            XCTAssertTrue(latest.contains { $0.id == entries.last?.id })
            sampler?.cancel()
            await sampler?.value
            await coordinator.stop()
            await database.closeAll()
            let closed = Self.physicalFootprint()
            let reopenedRoot = FluidZeppelinRoot(root: self.root.appendingPathComponent("append-memory", isDirectory: true))
            let reopened = SearchIndex(root: reopenedRoot)
            let reopenStart = ContinuousClock.now
            let reopenedHits = try await reopened.query(.history, text: "longmarker update1408", limit: 50)
            let reopenMilliseconds = Self.milliseconds(since: reopenStart)
            XCTAssertTrue(reopenedHits.contains { $0.id == entries.last?.id })
            let reopenedStore = try await reopened.namespace(.history)
            try samples.append(await self.appendMemorySample("reopened", added: 1408, sourceRows: entries.count, store: reopenedStore))
            await reopenedRoot.closeAll()
            let sorted = timings.sorted()
            let report = SearchAppendMemoryReport(
                initialRows: 12_880,
                addedRows: 1408,
                peakPhysicalFootprintBytes: peak,
                closedPhysicalFootprintBytes: closed,
                samplerTicks: samplerTicks,
                medianUpdateMilliseconds: sorted[sorted.count / 2],
                p95UpdateMilliseconds: sorted[Int(Double(sorted.count - 1) * 0.95)],
                reopenMilliseconds: reopenMilliseconds,
                samples: samples
            )
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output, options: .withoutOverwriting)
            print("Search append memory report: \(output.path)")
        } catch {
            sampler?.cancel()
            await sampler?.value
            await coordinator.stop()
            await database.closeAll()
            throw error
        }
    }

    private func appendMemorySample(_ phase: String, added: Int, sourceRows: Int, store: ZeppelinStore) async throws -> SearchAppendMemorySample {
        let stats = try await store.stats()
        return SearchAppendMemorySample(
            phase: phase,
            addedRows: added,
            sourceRows: sourceRows,
            processPhysicalFootprintBytes: Self.physicalFootprint(),
            index: SearchBenchmarkStats(stats),
            cacheBytes: stats.cacheBytes,
            queryPoolBytes: stats.queryPoolBytes,
            openFiles: stats.openFiles
        )
    }

    /// Explicitly supplied JSON is an exported private copy, never a production
    /// store. Both variants modify only unique test roots. Reports omit all text.
    func testOptInCopiedRealHistoryReopenBenchmark() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let recordsPath = environment["FLUIDVOICE_SEARCH_BENCHMARK_RECORDS"],
              let outputPath = environment["FLUIDVOICE_SEARCH_BENCHMARK_OUTPUT"]
        else { throw XCTSkip("Supply private record JSON and a report directory to run the search reopen benchmark") }
        let input = URL(fileURLWithPath: recordsPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
        XCTAssertLessThanOrEqual((attributes[.size] as? NSNumber)?.intValue ?? Int.max, 256 * 1024 * 1024)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 256 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let records = try JSONDecoder().decode([SearchBenchmarkRecord].self, from: Data(contentsOf: input)).map(\.record)
        XCTAssertTrue((10_000...20_000).contains(records.count), "Use the real approximately 13k-record corpus")
        let expectedIDs = Set(records.map(\.id))
        XCTAssertEqual(expectedIDs.count, records.count)
        guard (10_000...20_000).contains(records.count), expectedIDs.count == records.count else {
            throw CocoaError(.coderInvalidValue)
        }
        let queries = ["the", "meeting", "mo", "project", "update"]
        let labels: [String]
        if let variant = environment["FLUIDVOICE_SEARCH_BENCHMARK_VARIANT"] {
            guard ["baseline", "optimized"].contains(variant) else { throw CocoaError(.coderInvalidValue) }
            labels = [variant]
        } else {
            labels = ["baseline", "optimized"]
        }
        var variants: [SearchBenchmarkVariant] = []
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        for label in labels {
            let directory = self.root.appendingPathComponent(label, isDirectory: true)
            if let sourcePath = environment["FLUIDVOICE_SEARCH_BENCHMARK_SOURCE_INDEX"] {
                // Optional frozen index copy permits unchanged legacy-backfill
                // timing. The provided source directory is never opened/written.
                try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath, isDirectory: true), to: directory)
            }
            let result = try await self.benchmarkVariant(label, directory: directory, records: records, queries: queries)
            XCTAssertEqual(result.membershipSHA256, Self.membershipHash(expectedIDs))
            if label == "optimized" { XCTAssertEqual(result.after.activeRows, 0) }
            if let baseline = variants.first {
                XCTAssertEqual(result.queryMembershipSHA256, baseline.queryMembershipSHA256, "Sealing must preserve all matching IDs; top-50 score ties may legitimately reorder")
                XCTAssertEqual(result.initialUpserts, baseline.initialUpserts)
                XCTAssertEqual(result.initialDeletes, baseline.initialDeletes)
            }
            variants.append(result)
            if label == "optimized", let preparedPath = environment["FLUIDVOICE_SEARCH_BENCHMARK_EXPORT_PREPARED_INDEX"] {
                // An explicitly requested private fixture for a fresh-process
                // reopen measurement; never exported by ordinary test runs.
                let destination = URL(fileURLWithPath: preparedPath, isDirectory: true)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: directory, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            }
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = output.appendingPathComponent("search-index-benchmark-\(UUID().uuidString).json")
        try encoder.encode(variants).write(to: report, options: .withoutOverwriting)
        print("Search index benchmark report: \(report.path)")
    }

    private func benchmarkVariant(_ label: String, directory: URL, records: [SearchIndexRecord], queries: [String]) async throws -> SearchBenchmarkVariant {
        let root = FluidZeppelinRoot(root: directory)
        let index = SearchIndex(root: root, maintenanceActiveRowLimit: label == "baseline" ? nil : 256)
        let beforeOpenFootprint = Self.physicalFootprint()
        let start = ContinuousClock.now
        let store: ZeppelinStore
        let before: StoreStats
        let report: SearchIndex.ReconcileReport
        let openMilliseconds: Double
        let afterOpenFootprint: UInt64?
        let reconcileMilliseconds: Double
        let afterReconcileFootprint: UInt64?
        let after: StoreStats
        var membership = Set<UUID>()
        var queryHashes: [String: String] = [:]
        do {
            store = try await index.namespace(.history)
            openMilliseconds = Self.milliseconds(since: start)
            afterOpenFootprint = Self.physicalFootprint()
            before = try await store.stats()
            let reconcileStart = ContinuousClock.now
            report = try await index.reconcile(.history, with: records)
            reconcileMilliseconds = Self.milliseconds(since: reconcileStart)
            afterReconcileFootprint = Self.physicalFootprint()
            after = try await store.stats()
            for try await document in store.documents(fields: []) {
                membership.insert(document.id.uuid)
            }
            // Full membership avoids mistaking a different ordering of equal
            // BM25 scores at the result limit for a lost document.
            for query in queries {
                let hits = try await index.query(.history, text: query, limit: records.count)
                queryHashes[query] = Self.membershipHash(Set(hits.map(\.id)))
            }
        } catch {
            await root.closeAll()
            throw error
        }
        await root.closeAll()
        var reopens: [SearchBenchmarkReopen] = []
        for iteration in 0..<5 {
            let freshRoot = FluidZeppelinRoot(root: directory)
            let fresh = SearchIndex(root: freshRoot, maintenanceActiveRowLimit: label == "baseline" ? nil : 256)
            do {
                let beforeQueryFootprint = Self.physicalFootprint()
                let queryStart = ContinuousClock.now
                // This first query opens the namespace; no cached actor/handle
                // from a prior iteration can hide startup WAL replay.
                let hits = try await fresh.query(.history, text: queries[iteration % queries.count], limit: 50)
                let queryMilliseconds = Self.milliseconds(since: queryStart)
                let afterQueryFootprint = Self.physicalFootprint()
                let reconcileStart = ContinuousClock.now
                let unchanged = try await fresh.reconcile(.history, with: records)
                let reconcileMilliseconds = Self.milliseconds(since: reconcileStart)
                let afterReconcileFootprint = Self.physicalFootprint()
                XCTAssertEqual(unchanged, .init(upserted: 0, deleted: 0))
                let freshStore = try await fresh.namespace(.history)
                let stats = try await freshStore.stats()
                let count = try await freshStore.count().count
                XCTAssertEqual(count, UInt64(records.count))
                reopens.append(SearchBenchmarkReopen(
                    queryMilliseconds: queryMilliseconds,
                    reconcileMilliseconds: reconcileMilliseconds,
                    returnedHits: hits.count,
                    beforeQueryPhysicalFootprintBytes: beforeQueryFootprint,
                    afterQueryPhysicalFootprintBytes: afterQueryFootprint,
                    afterReconcilePhysicalFootprintBytes: afterReconcileFootprint,
                    stats: SearchBenchmarkStats(stats)
                ))
            } catch {
                await freshRoot.closeAll()
                throw error
            }
            await freshRoot.closeAll()
        }
        return SearchBenchmarkVariant(
            label: label,
            recordCount: records.count,
            openMilliseconds: openMilliseconds,
            reconcileMilliseconds: reconcileMilliseconds,
            initialUpserts: report.upserted,
            initialDeletes: report.deleted,
            beforeOpenPhysicalFootprintBytes: beforeOpenFootprint,
            afterOpenPhysicalFootprintBytes: afterOpenFootprint,
            afterReconcilePhysicalFootprintBytes: afterReconcileFootprint,
            before: SearchBenchmarkStats(before),
            after: SearchBenchmarkStats(after),
            membershipSHA256: Self.membershipHash(membership),
            queryMembershipSHA256: queryHashes,
            reopens: reopens
        )
    }

    private static func membershipHash(_ ids: Set<UUID>) -> String {
        let input = ids.map(\.uuidString).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

private struct SearchAppendMemorySample: Codable {
    let phase: String
    let addedRows: Int
    let sourceRows: Int
    let processPhysicalFootprintBytes: UInt64?
    let index: SearchBenchmarkStats
    let cacheBytes: UInt64
    let queryPoolBytes: UInt64
    let openFiles: UInt64
}

private struct SearchAppendMemoryReport: Codable {
    let initialRows: Int
    let addedRows: Int
    let peakPhysicalFootprintBytes: UInt64
    let closedPhysicalFootprintBytes: UInt64?
    let samplerTicks: Int
    let medianUpdateMilliseconds: Double
    let p95UpdateMilliseconds: Double
    let reopenMilliseconds: Double
    let samples: [SearchAppendMemorySample]
}
