import Combine
import Foundation
import SQLite3

// These doubles prevent the standalone test executable from touching app audio or settings.
struct DictationAudioMetadata: Codable, Equatable, Sendable {
    let fileName: String
    let durationMilliseconds: Int
    let byteCount: Int
    let sampleRate: Int
    let channels: Int
    let model: String?
}

final class DictationAudioHistoryStore {
    static let shared = DictationAudioHistoryStore()
    var usageBytes: Int64 = 0
    var orphanSweeps = 0
    var usageMeasurements = 0
    var deletedFileNames: [String] = []
    @discardableResult func deleteAudio(fileName: String) -> Int64 {
        self.deletedFileNames.append(fileName)
        return 0
    }

    func deleteAllAudioFiles() {}
    func audioUsageBytes() -> Int64 {
        self.usageMeasurements += 1
        return self.usageBytes
    }

    func deleteUnreferencedAudioFiles(referencedFileNames: Set<String>) -> (fileCount: Int, byteCount: Int64) {
        self.orphanSweeps += 1
        return (0, 0)
    }
}

@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var audioHistoryBudgetBytes: Int64 { 1_000_000 }
    var weekendsDontBreakStreak: Bool { false }
}

final class DebugLogger {
    static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
    func warning(_ message: String, source: String) {}
    func debug(_ message: String, source: String) {}
}

/// Stands in for an older app instance that saves legacy history while a load is running.
final class RewritingDefaults: UserDefaults {
    var replacement: Data?

    override func data(forKey name: String) -> Data? {
        let snapshot = super.data(forKey: name)
        if let replacement {
            self.replacement = nil
            super.set(replacement, forKey: name)
        }
        return snapshot
    }
}

@main struct HistoryPersistenceBoundaryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fluid-history-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "fluid-history-tests-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Unable to create isolated history defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "TranscriptionHistoryEntries"
        let audio = DictationAudioMetadata(
            fileName: "test.wav",
            durationMilliseconds: 1000,
            byteCount: 32_000,
            sampleRate: 16_000,
            channels: 1,
            model: "test"
        )
        let legacy = (0..<8400).map { index in
            TranscriptionHistoryEntry(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                rawText: "Raw \(index)",
                processedText: String(repeating: "Test dictation \(index). ", count: 12),
                appName: "Test",
                windowTitle: "Test",
                wasAIProcessed: true,
                processingModel: "test",
                transcriptionDurationMilliseconds: 50,
                aiProcessingDurationMilliseconds: 100,
                aiTokensPerSecond: 500,
                audio: index == 0 ? audio : nil
            )
        }
        // Simulate history written before stars existed, including legacy backups.
        guard var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [[String: Any]] else {
            preconditionFailure("Expected legacy history to encode as an array of objects")
        }
        for index in legacyJSON.indices {
            legacyJSON[index].removeValue(forKey: "isStarred")
        }
        try defaults.set(JSONSerialization.data(withJSONObject: legacyJSON), forKey: key)
        let url = root.appendingPathComponent("history.sqlite3")
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: url)
        let store = TranscriptionHistoryStore(writer: writer)
        // No actor suspension: these mutations necessarily precede startup loading.
        let newID = UUID()
        store.addEntry(id: newID, rawText: "new", processedText: "New dictation", appName: "Test", windowTitle: "Test")
        store.toggleStar(id: newID)
        store.attachAudio(audio, to: newID)
        store.deleteEntry(id: legacy[1].id)
        try await store.waitUntilLoaded()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1), "Startup stats must include merged pending edits")
        await store.finishPendingWrites()
        precondition(defaults.data(forKey: key) == nil, "Retire legacy only after successful import")
        precondition(store.entries.count == 8400)
        precondition(store.entries.first(where: { $0.id == newID })?.audio == audio)
        precondition(store.entries.first(where: { $0.id == newID })?.isStarred == true)
        precondition(store.entries.filter(\.isStarred).count == 1, "Legacy entries must default to unstarred")
        precondition(!store.entries.contains(where: { $0.id == legacy[1].id }))
        let reloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(reloaded == store.entries, "Migration, metadata and concurrent startup edits must round-trip")
        print("PASS: 8,400-entry migration, exact round-trip, startup insert/audio/delete")

        // Reject a write touching any old entry. A new dictation and its audio must only update their row.
        try self.sql(url, "CREATE TRIGGER reject_old BEFORE INSERT ON history WHEN NEW.id != '\(newID.uuidString)' BEGIN SELECT RAISE(FAIL, 'unrelated row rewritten'); END")
        let enqueueStart = ProcessInfo.processInfo.systemUptime
        store.attachAudio(audio, to: newID)
        store.toggleStar(id: newID)
        store.toggleStar(id: newID)
        let enqueueMs = (ProcessInfo.processInfo.systemUptime - enqueueStart) * 1000
        await store.finishPendingWrites()
        await Task.yield()
        precondition(store.persistenceError == nil, "Updating one row must not rewrite unrelated history")
        let afterStar = try await writer.load()
        precondition(afterStar == store.entries, "Rapid star toggles and audio updates must persist in order")
        print("PASS: single-row audio update; main actor enqueue \(enqueueMs) ms")
        try self.sql(url, "DROP TRIGGER reject_old")

        try self.sql(url, "CREATE TRIGGER reject_all BEFORE INSERT ON history BEGIN SELECT RAISE(FAIL, 'test disk failure'); END")
        let failedID = UUID()
        store.addEntry(id: failedID, rawText: "pending", processedText: "Unsaved", appName: "Test", windowTitle: "Test")
        await store.finishPendingWrites()
        for _ in 0..<10 {
            await Task.yield()
        }
        precondition(store.persistenceError != nil)
        precondition(store.entries.contains(where: { $0.id == failedID }))
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 3, transcriptions: 2), "A disk error must not drop in-memory stats")
        let afterFailure = try await writer.load()
        precondition(!afterFailure.contains(where: { $0.id == failedID }))
        store.retryPersistence()
        await store.finishPendingWrites()
        let afterFailedReplacement = try await writer.load()
        precondition(afterFailedReplacement == afterFailure, "Failed replacement must roll back its initial DELETE")
        try self.sql(url, "DROP TRIGGER reject_all")
        store.retryPersistence()
        await store.finishPendingWrites()
        for _ in 0..<10 {
            await Task.yield()
        }
        precondition(store.persistenceError == nil)
        let afterRetry = try await writer.load()
        precondition(afterRetry.contains(where: { $0.id == failedID }))
        print("PASS: failed write stays in memory, surfaces error, retry restores complete snapshot")

        store.clearAllHistory()
        store.attachAudio(audio, to: newID)
        await store.finishPendingWrites()
        let afterClear = try await writer.load()
        precondition(afterClear.isEmpty, "Late audio must not resurrect deleted entries")
        // Imported legacy history is retired, so nothing is left to resurrect cleared history.
        // Legacy history written later is new to the database and is imported (see testLegacyImportAcrossBuilds).
        precondition(defaults.data(forKey: key) == nil)
        let afterRestart = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(afterRestart.isEmpty, "Cleared history must stay cleared after restart")
        print("PASS: clear, late audio and restart cannot resurrect history")

        let badURL = root.appendingPathComponent("bad.sqlite3")
        let source = try JSONEncoder().encode([legacy[0]])
        defaults.set(source, forKey: key)
        _ = try TranscriptionHistoryDatabase(url: badURL)
        try self.sql(badURL, "INSERT INTO history VALUES ('\(UUID().uuidString)', x'00')")
        let badStore = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: badURL))
        do {
            try await badStore.waitUntilLoaded()
            preconditionFailure("An unreadable saved row must fail visibly")
        } catch {}
        precondition(!badStore.isLoading && badStore.persistenceError != nil)
        precondition(defaults.data(forKey: key) == source, "A failed load must keep legacy history")
        try self.sql(badURL, "DELETE FROM history WHERE id != '\(legacy[0].id.uuidString)'")
        badStore.retryPersistence()
        try await badStore.waitUntilLoaded()
        precondition(badStore.entries == [legacy[0]])
        precondition(defaults.data(forKey: key) == nil)
        print("PASS: unreadable saved history preserves legacy source, exits loading and supports retry")

        let restoreStore = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: url))
        restoreStore.restore(from: [legacy[3]])
        try await restoreStore.waitUntilLoaded()
        await restoreStore.finishPendingWrites()
        guard let restored = restoreStore.entries.first,
              let revision = restored.searchRevision
        else { preconditionFailure("Restore must set a search revision") }
        precondition(revision > (legacy[3].searchRevision ?? 1), "Restore must invalidate the previous search record")
        var expectedRestore = legacy[3]
        expectedRestore.searchRevision = revision
        precondition(restoreStore.entries == [expectedRestore], "Restore must preserve every field except the search revision")
        let afterRestore = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(afterRestore == [expectedRestore], "The new search revision and original content must round-trip")
        restoreStore.restore(from: [legacy[3]])
        await restoreStore.finishPendingWrites()
        guard let nextRevision = restoreStore.entries.first?.searchRevision else {
            preconditionFailure("Repeated restore must preserve a search revision")
        }
        precondition(nextRevision > revision, "Restoring an older backup must advance past the currently indexed revision")
        expectedRestore.searchRevision = nextRevision
        let afterRepeatedRestore = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(afterRepeatedRestore == [expectedRestore], "Repeated restore changes only the persisted search revision")
        print("PASS: restore during loading replaces both memory and disk")
        try await self.testTodaySummary(root: root, defaults: defaults, audio: audio)
        try await self.testStars(root: root, defaults: defaults, audio: audio)
        try await self.testLegacyImportAcrossBuilds(root: root, audio: audio)
    }

    /// The database is shared by every build on the Mac, but each bundle and each older
    /// version keeps legacy history in its own defaults. Neither may lose unimported entries.
    @MainActor static func testLegacyImportAcrossBuilds(root: URL, audio: DictationAudioMetadata) async throws {
        let key = "TranscriptionHistoryEntries"
        let suites = (0..<3).map { "fluid-history-legacy-\($0)-\(UUID())" }
        defer { suites.forEach { UserDefaults().removePersistentDomain(forName: $0) } }
        guard let debugDefaults = UserDefaults(suiteName: suites[0]),
              let releaseDefaults = UserDefaults(suiteName: suites[1]),
              let upgradeDefaults = UserDefaults(suiteName: suites[2])
        else { preconditionFailure("Unable to create isolated history defaults") }
        func entry(_ seconds: TimeInterval, _ text: String, starred: Bool = false) -> TranscriptionHistoryEntry {
            TranscriptionHistoryEntry(
                timestamp: Date(timeIntervalSince1970: seconds),
                rawText: text,
                processedText: text,
                appName: "Test",
                windowTitle: "Test",
                wasAIProcessed: false,
                isStarred: starred
            )
        }

        // Another build created the database first and recorded its own (empty) import.
        let sharedURL = root.appendingPathComponent("shared.sqlite3")
        let debugLoad = try await TranscriptionHistoryWriter(defaults: debugDefaults, url: sharedURL).load()
        precondition(debugLoad.isEmpty)
        let release = [entry(2, "release two"), entry(1, "release one")]
        try releaseDefaults.set(JSONEncoder().encode(release), forKey: key)
        let releaseLoad = try await TranscriptionHistoryWriter(defaults: releaseDefaults, url: sharedURL).load()
        precondition(releaseLoad == release, "History another build never imported must be imported, not deleted")
        precondition(releaseDefaults.data(forKey: key) == nil, "Legacy history is retired once it is in the database")
        print("PASS: legacy history is imported when another build created the database first")

        // Upgrade, star an entry, run an older version that writes legacy history again, upgrade.
        let upgradeURL = root.appendingPathComponent("upgrade.sqlite3")
        let original = entry(1, "before downgrade")
        try upgradeDefaults.set(JSONEncoder().encode([original]), forKey: key)
        let upgradeWriter = TranscriptionHistoryWriter(defaults: upgradeDefaults, url: upgradeURL)
        _ = try await upgradeWriter.load()
        var starred = original
        starred.isStarred = true
        let starError = await withCheckedContinuation { continuation in
            upgradeWriter.write(upserts: [starred]) { continuation.resume(returning: $0) }
        }
        precondition(starError == nil)
        let downgraded = entry(2, "dictated after downgrade")
        try upgradeDefaults.set(JSONEncoder().encode([downgraded, original]), forKey: key)
        let reupgraded = try await TranscriptionHistoryWriter(defaults: upgradeDefaults, url: upgradeURL).load()
        precondition(reupgraded == [downgraded, starred], "Re-upgrading must add new legacy entries and keep newer database rows")
        precondition(upgradeDefaults.data(forKey: key) == nil)
        print("PASS: entries written by an older version after upgrading are merged without overwriting database rows")

        // Unreadable legacy data is kept for recovery without blocking saved history.
        let unreadable = Data("invalid JSON".utf8)
        upgradeDefaults.set(unreadable, forKey: key)
        let store = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: upgradeDefaults, url: upgradeURL))
        try await store.waitUntilLoaded()
        precondition(store.entries == [downgraded, starred], "Unreadable legacy history must not block saved history")
        let newID = UUID()
        store.addEntry(id: newID, rawText: "new", processedText: "New dictation", appName: "Test", windowTitle: "Test")
        await store.finishPendingWrites()
        let restarted = try await TranscriptionHistoryWriter(defaults: upgradeDefaults, url: upgradeURL).load()
        precondition(restarted.map(\.id) == [newID, downgraded.id, original.id], "New dictations must persist beside unreadable legacy history")
        precondition(upgradeDefaults.data(forKey: key) == unreadable, "Unreadable legacy history must never be deleted")
        print("PASS: unreadable legacy history is preserved without blocking saved history or new dictations")

        // Unimported legacy history may own audio the loaded entries do not reference, so usage over
        // budget must neither sweep that audio as orphaned nor delete new recordings to pay for it.
        let audioStore = DictationAudioHistoryStore.shared
        audioStore.usageBytes = 2_000_000
        defer { audioStore.usageBytes = 0 }
        let sweeps = audioStore.orphanSweeps
        let measurements = audioStore.usageMeasurements
        let deletions = audioStore.deletedFileNames.count
        store.attachAudio(audio, to: newID)
        for _ in 0..<200 where audioStore.usageMeasurements == measurements {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(audioStore.usageMeasurements > measurements, "Attaching audio must measure usage against the budget")
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(store.entries.first { $0.id == newID }?.audio == audio, "A new recording must not pay for legacy audio")
        store.pruneAudioToBudget()
        precondition(store.entries.first { $0.id == newID }?.audio == audio, "Lowering the budget must not delete recordings while legacy history remains")
        precondition(audioStore.deletedFileNames.count == deletions, "Unimported legacy history must block deleting recordings")
        precondition(audioStore.orphanSweeps == sweeps, "Unimported legacy history must block the orphaned audio sweep")
        upgradeDefaults.removeObject(forKey: key)
        store.pruneAudioToBudget()
        precondition(audioStore.orphanSweeps == sweeps + 1, "Fully imported history must allow the orphaned audio sweep")
        precondition(audioStore.deletedFileNames.dropFirst(deletions) == [audio.fileName], "Fully imported history must allow pruning recordings to the budget")
        precondition(store.entries.allSatisfy { $0.audio == nil })
        print("PASS: unimported legacy history defers audio budget pruning until it is imported")

        // An older instance saves a newer legacy array after this load read the key.
        let racingSuite = "fluid-history-legacy-race-\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: racingSuite) }
        guard let racingDefaults = RewritingDefaults(suiteName: racingSuite) else {
            preconditionFailure("Unable to create isolated history defaults")
        }
        let racingURL = root.appendingPathComponent("racing.sqlite3")
        let first = entry(1, "imported")
        let concurrent = entry(2, "saved by the older instance during load")
        try racingDefaults.set(JSONEncoder().encode([first]), forKey: key)
        let rewritten = try JSONEncoder().encode([concurrent, first])
        racingDefaults.replacement = rewritten
        let racedStore = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: racingDefaults, url: racingURL))
        try await racedStore.waitUntilLoaded()
        precondition(racedStore.entries == [first])
        let racedSweeps = audioStore.orphanSweeps
        racedStore.pruneAudioToBudget()
        precondition(audioStore.orphanSweeps == racedSweeps, "Legacy history retained for the next load must block the orphaned audio sweep")
        precondition(racingDefaults.data(forKey: key) == rewritten, "Legacy history rewritten during a load must not be retired")
        let nextLoad = try await TranscriptionHistoryWriter(defaults: racingDefaults, url: racingURL).load()
        precondition(nextLoad == [concurrent, first], "The next load must import the rewritten legacy history")
        precondition(racingDefaults.data(forKey: key) == nil)
        print("PASS: legacy history rewritten during a load is kept and imported on the next load")

        // A database written by 1.6.10-1.6.11 still carries the old import marker.
        let markedURL = root.appendingPathComponent("marked.sqlite3")
        try self.sql(markedURL, "CREATE TABLE history (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try self.sql(markedURL, "CREATE TABLE metadata (key TEXT PRIMARY KEY)")
        try self.sql(markedURL, "INSERT INTO metadata(key) VALUES ('legacy_imported')")
        let markedSuite = "fluid-history-legacy-marked-\(UUID())"
        defer { UserDefaults().removePersistentDomain(forName: markedSuite) }
        guard let markedDefaults = UserDefaults(suiteName: markedSuite) else {
            preconditionFailure("Unable to create isolated history defaults")
        }
        let unimported = [entry(2, "never imported two"), entry(1, "never imported one")]
        try markedDefaults.set(JSONEncoder().encode(unimported), forKey: key)
        let markedLoad = try await TranscriptionHistoryWriter(defaults: markedDefaults, url: markedURL).load()
        precondition(markedLoad == unimported, "An old import marker must not skip legacy history")
        precondition(markedDefaults.data(forKey: key) == nil)
        print("PASS: legacy history is imported into a database carrying the old import marker")

        // Only unreadable legacy bytes are skipped; a failed import still fails the load.
        let source = try JSONEncoder().encode([entry(3, "import fails")])
        markedDefaults.set(source, forKey: key)
        try self.sql(markedURL, "CREATE TRIGGER reject_import BEFORE INSERT ON history BEGIN SELECT RAISE(FAIL, 'test disk failure'); END")
        do {
            _ = try await TranscriptionHistoryWriter(defaults: markedDefaults, url: markedURL).load()
            preconditionFailure("A failed legacy import must fail the load")
        } catch {}
        precondition(markedDefaults.data(forKey: key) == source, "A failed legacy import must keep legacy history")
        print("PASS: a failed legacy import fails the load and keeps legacy history")
    }

    @MainActor static func testStars(root: URL, defaults: UserDefaults, audio: DictationAudioMetadata) async throws {
        let url = root.appendingPathComponent("stars.sqlite3")
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: url)
        let store = TranscriptionHistoryStore(writer: writer)
        try await store.waitUntilLoaded()
        let older = TranscriptionHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1),
            rawText: "Original phrasing",
            processedText: "Reusable prompt",
            appName: "Editor",
            windowTitle: "Reference",
            wasAIProcessed: true,
            audio: audio,
            isStarred: true
        )
        let newer = TranscriptionHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 2),
            rawText: "Another prompt",
            processedText: "Another prompt",
            appName: "Test",
            windowTitle: "Test",
            wasAIProcessed: false
        )
        store.restore(from: [older, newer])
        precondition(store.search(query: "").map(\.id) == [newer.id, older.id], "Stars must preserve chronological order")
        precondition(store.search(query: "", pinnedFirst: true).map(\.id) == [older.id, newer.id], "History displays pins first")
        precondition(store.search(query: "prompt", pinnedFirst: true).map(\.id) == [older.id, newer.id], "Pin ordering applies after text filtering")
        precondition(store.search(query: "Another", pinnedFirst: true).map(\.id) == [newer.id], "Pins must not bypass the search filter")
        let storedOrder = store.entries
        let selectedID = store.selectedEntryID
        store.toggleStar(id: newer.id)
        precondition(store.search(query: "", pinnedFirst: true).map(\.id) == [newer.id, older.id], "Multiple pins retain newest-first order")
        store.toggleStar(id: older.id)
        precondition(store.search(query: "", pinnedFirst: true).map(\.id) == [newer.id, older.id], "Unpin returns the entry to its date position")
        store.toggleStar(id: newer.id)
        store.toggleStar(id: older.id)
        precondition(store.entries == storedOrder && store.selectedEntryID == selectedID, "Pinning must preserve persisted chronology, all metadata, and selection")
        precondition(store.search(query: " ", starredOnly: true).map(\.id) == [older.id])
        for query in ["PROMPT", "Original", "Editor", "Reference"] {
            precondition(store.search(query: query, starredOnly: true).map(\.id) == [older.id], "Search must intersect with stars across every field")
        }
        precondition(store.search(query: "Another", starredOnly: true).isEmpty)
        precondition(older.replacingAudio(nil).isStarred, "Audio removal must preserve the star")
        let backup = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: JSONEncoder().encode(store.makeBackupPayload()))
        store.toggleStar(id: older.id)
        await store.finishPendingWrites()
        let unstarred = try await writer.load()
        precondition(!unstarred.contains(where: \.isStarred), "Removing a star must survive restart")
        store.restore(from: backup)
        await store.finishPendingWrites()
        let restored = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        let normalizedRestore = restored.map { entry in
            var entry = entry
            entry.searchRevision = backup.first(where: { $0.id == entry.id })?.searchRevision
            return entry
        }
        precondition(normalizedRestore == backup, "Backup restore must retain stars and metadata while refreshing search revisions")
        store.selectEntryFromSearch(id: older.id)
        guard let firstRequest = store.searchSelectionRequest else {
            preconditionFailure("Selecting a search result must create a request")
        }
        store.selectEntryFromSearch(id: older.id)
        guard let repeatedRequest = store.searchSelectionRequest else {
            preconditionFailure("Selecting the same result again must create a request")
        }
        precondition(firstRequest != repeatedRequest, "Repeated clicks on the same result must create a fresh bounded request")
        store.consumeSearchSelectionRequest(firstRequest)
        precondition(store.searchSelectionRequest == repeatedRequest, "A stale consumer must not clear the latest search request")
        store.consumeSearchSelectionRequest(repeatedRequest)
        precondition(store.searchSelectionRequest == nil, "The active consumer clears its request")
        store.selectedEntryID = older.id
        store.toggleStar(id: older.id)
        precondition(store.searchSelectionRequest == nil, "Unstar is a local edit, not a sidebar reveal")
        store.deleteEntry(id: older.id)
        precondition(store.selectedEntryID == newer.id, "Deleting the selected row retains the existing store fallback")
        precondition(store.searchSelectionRequest == nil, "Delete fallback must not reset History filters")
        store.toggleStar(id: older.id)
        await store.finishPendingWrites()
        let afterDelete = try await writer.load()
        precondition(afterDelete == restored.filter { $0.id == newer.id }, "A stale star action must not resurrect a deleted entry")
        print("PASS: star filtering/search, chronology, audio preservation, unstar/restart, backup restore, deletion and bounded explicit search requests")
    }

    @MainActor static func testTodaySummary(root: URL, defaults: UserDefaults, audio: DictationAudioMetadata) async throws {
        let formatter = ISO8601DateFormatter()
        guard var now = formatter.date(from: "2026-03-08T18:00:00Z"),
              let losAngeles = TimeZone(identifier: "America/Los_Angeles"),
              let plusFourteen = TimeZone(secondsFromGMT: 14 * 3600)
        else { preconditionFailure("Invalid calendar fixtures") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = losAngeles
        var clockReads = 0
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: root.appendingPathComponent("summary.sqlite3"))
        let store = TranscriptionHistoryStore(
            writer: writer,
            summaryNow: {
                clockReads += 1
                return now
            },
            summaryCalendar: { calendar }
        )
        try await store.waitUntilLoaded()
        await store.waitForTodaySummary()
        guard let day = calendar.dateInterval(of: .day, for: now) else {
            preconditionFailure("Missing fixture day")
        }
        precondition(day.duration == 23 * 3600, "Fixture must exercise a DST-shortened day")
        func entry(_ timestamp: Date, _ text: String) -> TranscriptionHistoryEntry {
            TranscriptionHistoryEntry(
                timestamp: timestamp,
                rawText: text,
                processedText: text,
                appName: "Test",
                windowTitle: "Test",
                wasAIProcessed: false
            )
        }
        let yesterday = entry(day.start.addingTimeInterval(-1), "not today")
        let first = entry(day.start, "  one\t two\nthree  ")
        let last = entry(day.end.addingTimeInterval(-1), "four")
        let tomorrow = entry(day.end, "next day")
        store.restore(from: [yesterday, first, last, tomorrow])
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 4, transcriptions: 2), "Preserve word splitting and half-open local-day boundaries")
        let reads = clockReads
        let unchangedEntries = store.entries
        for _ in 0..<10_000 {
            precondition(store.todaySummary.words == 4)
        }
        precondition(clockReads == reads, "Rendering must not query clock or schedule a recount")
        store.attachAudio(audio, to: first.id)
        await store.waitForTodaySummary()
        precondition(clockReads == reads, "Audio-only metadata must not invalidate text stats")
        precondition(store.entries.map(\.processedText) == unchangedEntries.map(\.processedText))
        precondition(store.selectedEntryID == unchangedEntries.first?.id, "Summary work must not change selection")
        store.deleteEntry(id: UUID())
        store.deleteEntries(ids: [])
        await store.waitForTodaySummary()
        precondition(clockReads == reads, "No-op deletions must not schedule work")
        print("PASS: constant-time stats reads, exact whitespace/DST boundaries, audio-only non-effects")

        let additionID = UUID()
        store.addEntry(id: additionID, timestamp: now, rawText: "new text", processedText: "new text", appName: "Test", windowTitle: "Test")
        store.deleteEntry(id: first.id)
        store.deleteEntries(ids: [last.id])
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1))
        store.addEntry(timestamp: now, rawText: "", processedText: " \n ", appName: "Test", windowTitle: "Test")
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1))

        // Bulk replacement followed by rapid changes must only publish the latest history.
        store.restore(from: Array(repeating: first, count: 10_000))
        await Task.yield()
        store.restore(from: [yesterday, first, last, tomorrow])
        store.deleteEntries(ids: [first.id, last.id])
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 0, transcriptions: 0), "Never apply a stale bulk-rebuild result")
        var replacedFromSubscriber = false
        let subscription = store.$todaySummary.sink { summary in
            guard summary.words == 3, !replacedFromSubscriber else { return }
            replacedFromSubscriber = true
            store.restore(from: [yesterday, tomorrow])
        }
        store.restore(from: [first])
        await store.waitForTodaySummary()
        precondition(replacedFromSubscriber && store.todaySummary == .init(words: 0, transcriptions: 0), "Reentrant changes must not be lost during publication")
        subscription.cancel()
        print("PASS: insert/delete/bulk-delete/empty input and rapid replacement converge to latest snapshot")

        now = day.end.addingTimeInterval(1)
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1), "Midnight must refresh without a dictation")
        now = day.end.addingTimeInterval(12 * 3600)
        calendar.timeZone = plusFourteen
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 0, transcriptions: 0), "Timezone changes must redefine today")
        now = yesterday.timestamp
        calendar.timeZone = losAngeles
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1), "Clock moving backward must refresh")
        let settledReads = clockReads
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        precondition(clockReads == settledReads + 1, "Activation within same day must not rebuild")
        store.clearAllHistory()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 0, transcriptions: 0))
        await store.finishPendingWrites()
        print("PASS: day/timezone/backward-clock changes, unchanged-day no-op, and clear")
    }

    static func sql(_ url: URL, _ command: String) throws {
        var handle: OpaquePointer?
        precondition(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        // A writer released by the previous load may still be closing its connection.
        sqlite3_busy_timeout(handle, 2000)
        precondition(sqlite3_exec(handle, command, nil, nil, nil) == SQLITE_OK)
    }
}
