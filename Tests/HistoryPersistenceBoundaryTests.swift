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
    @discardableResult func deleteAudio(fileName: String) -> Int64 { 0 }
    func deleteAllAudioFiles() {}
    func audioUsageBytes() -> Int64 { 0 }
    func deleteUnreferencedAudioFiles(referencedFileNames: Set<String>) -> (fileCount: Int, byteCount: Int64) { (0, 0) }
}

@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var audioHistoryBudgetBytes: Int64 { 1_000_000 }
    var weekendsDontBreakStreak: Bool { false }
}

final class DebugLogger {
    static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
    func debug(_ message: String, source: String) {}
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
        try defaults.set(JSONEncoder().encode(legacy), forKey: key)
        let url = root.appendingPathComponent("history.sqlite3")
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: url)
        let store = TranscriptionHistoryStore(writer: writer)
        // No actor suspension: these mutations necessarily precede startup loading.
        let newID = UUID()
        store.addEntry(id: newID, rawText: "new", processedText: "New dictation", appName: "Test", windowTitle: "Test")
        store.attachAudio(audio, to: newID)
        store.deleteEntry(id: legacy[1].id)
        try await store.waitUntilLoaded()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1), "Startup stats must include merged pending edits")
        await store.finishPendingWrites()
        precondition(defaults.data(forKey: key) == nil, "Retire legacy only after successful import")
        precondition(store.entries.count == 8400)
        precondition(store.entries.first(where: { $0.id == newID })?.audio == audio)
        precondition(!store.entries.contains(where: { $0.id == legacy[1].id }))
        let reloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(reloaded == store.entries, "Migration, metadata and concurrent startup edits must round-trip")
        print("PASS: 8,400-entry migration, exact round-trip, startup insert/audio/delete")

        // Reject a write touching any old entry. A new dictation and its audio must only update their row.
        try self.sql(url, "CREATE TRIGGER reject_old BEFORE INSERT ON history WHEN NEW.id != '\(newID.uuidString)' BEGIN SELECT RAISE(FAIL, 'unrelated row rewritten'); END")
        let enqueueStart = ProcessInfo.processInfo.systemUptime
        store.attachAudio(audio, to: newID)
        let enqueueMs = (ProcessInfo.processInfo.systemUptime - enqueueStart) * 1000
        await store.finishPendingWrites()
        await Task.yield()
        precondition(store.persistenceError == nil, "Updating one row must not rewrite unrelated history")
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
        try defaults.set(JSONEncoder().encode(legacy), forKey: key)
        let afterRestart = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(afterRestart.isEmpty, "Migration marker must prevent old history resurrection")
        print("PASS: clear, late audio, restart and stale legacy cannot resurrect history")

        let badURL = root.appendingPathComponent("bad.sqlite3")
        let badData = Data("invalid JSON".utf8)
        defaults.set(badData, forKey: key)
        let badStore = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: badURL))
        do {
            try await badStore.waitUntilLoaded()
            preconditionFailure("Corrupt legacy must fail visibly")
        } catch {}
        precondition(!badStore.isLoading && badStore.persistenceError != nil)
        precondition(defaults.data(forKey: key) == badData)
        try defaults.set(JSONEncoder().encode([legacy[0]]), forKey: key)
        badStore.retryPersistence()
        try await badStore.waitUntilLoaded()
        precondition(badStore.entries == [legacy[0]])
        print("PASS: corrupt migration preserves source, exits loading and supports retry")

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
        precondition(sqlite3_exec(handle, command, nil, nil, nil) == SQLITE_OK)
    }
}
