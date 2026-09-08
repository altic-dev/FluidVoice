import Foundation

@main
struct StatsSnapshotTests {
    static func main() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func date(_ day: Int, month: Int = 9) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
        }
        func entry(_ day: Int, text: String, app: String = "Notes", ai: Bool = false, month: Int = 9) -> TranscriptionHistoryEntry {
            TranscriptionHistoryEntry(timestamp: date(day, month: month), rawText: "raw must not count", processedText: text,
                                      appName: app, windowTitle: "", wasAIProcessed: ai)
        }
        let entries = [entry(7, text: "one  two\nthree", ai: true), entry(7, text: "four", app: ""),
                       entry(6, text: "five six"), entry(4, text: "seven"), entry(3, text: "eight")]
        let original = entries
        let snapshot = try StatsSnapshot.build(entries: entries, now: date(7), calendar: calendar)
        precondition(entries == original, "Summary must not mutate history")
        precondition(snapshot.totalWords == 8 && snapshot.totalTranscriptions == 5)
        precondition(snapshot.averageWordsPerTranscription == 1 && snapshot.aiEnhancementRate == 20)
        precondition(snapshot.currentStreak == 2 && snapshot.bestStreak == 2)
        precondition(snapshot.usingWeekdays(true).currentStreak == 3 && snapshot.usingWeekdays(true).bestStreak == 3)
        precondition(snapshot.currentStreak == 2, "Settings projection must not alter cached summary")
        precondition(snapshot.longestTranscriptionWords == 3 && snapshot.mostWordsInDay == 4 && snapshot.mostTranscriptionsInDay == 2)
        precondition(snapshot.dailyWordCounts(days: 7).count == 7 && snapshot.activity.count == 30)
        precondition(snapshot.activity.last!.words == 4 && snapshot.activity.reduce(0) { $0 + $1.words } == 8)
        precondition(snapshot.topAppsFormatted(limit: 3) == ["Notes", "Unknown"])
        precondition(snapshot.formattedTimeSaved(typingWPM: 0) == "< 1m")
        precondition(snapshot.formattedTimeSaved(typingWPM: 200) == "< 1m")
        let empty = try StatsSnapshot.build(entries: [], now: date(7), calendar: calendar)
        precondition(empty.totalWords == 0 && empty.currentStreak == 0 && empty.bestStreak == 0 && empty.peakHourFormatted == "N/A")
        precondition(empty.totalMilestonesAchieved == 0 && empty.totalMilestonesPossible == 18)
        let stale = try StatsSnapshot.build(entries: entries, now: date(10), calendar: calendar)
        precondition(stale.currentStreak == 0 && stale.weekdayCurrentStreak == 0 && stale.bestStreak == 2)
        let weekend = try StatsSnapshot.build(entries: [entry(3, text: "x"), entry(4, text: "x"), entry(6, text: "x")], now: date(6), calendar: calendar)
        precondition(weekend.weekdayCurrentStreak == 2 && weekend.weekdayBestStreak == 2)
        let dst = try StatsSnapshot.build(entries: [entry(7, text: "a", month: 3), entry(8, text: "b", month: 3), entry(9, text: "c", month: 3)], now: date(9, month: 3), calendar: calendar)
        precondition(dst.currentStreak == 3 && dst.bestStreak == 3, "Streaks must use calendar days across DST")
        let large = Array(repeating: entry(7, text: String(repeating: "word ", count: 100)), count: 9000)
        let start = Date()
        let big = try StatsSnapshot.build(entries: large, now: date(7), calendar: calendar)
        precondition(big.totalWords == 900000 && big.longestTranscriptionWords == 100 && big.activity.count == 30)
        print("9,000-entry / 900,000-word summary: \(Int(Date().timeIntervalSince(start) * 1000)) ms off-main workload")
        let cancelled = Task.detached {
            try await Task.sleep(nanoseconds: 50_000_000)
            return try StatsSnapshot.build(entries: large, now: Date(), calendar: Calendar.current)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled worker must not return a snapshot") } catch is CancellationError {}
        try await self.testStore(entries: entries)
        print("PASS: totals, records, chart bounds, immutable input, settings projection, empty, stale, weekends, DST, large history and cancellation")
    }

    @MainActor
    static func testStore(entries: [TranscriptionHistoryEntry]) async throws {
        let history = TranscriptionHistoryStore()
        let store = StatsSnapshotStore(history: history)
        let first = UUID()
        let second = UUID()
        history.entries = entries
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(store.snapshot == nil && !store.isUpdating, "Hidden Stats must not aggregate")
        store.activate(first)
        for _ in 0..<100 {
            if !store.isUpdating { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(store.snapshot?.totalWords == 8 && !store.isUpdating)
        store.deactivate(first)
        store.activate(first)
        precondition(!store.isUpdating, "Reopening unchanged Stats must use the cache")
        history.entries = Array(repeating: entries[0], count: 1000)
        history.entries = [entries[1]]
        for _ in 0..<100 {
            if !store.isUpdating { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(store.snapshot?.totalWords == 1, "Only newest publisher value may win")
        store.activate(second)
        store.deactivate(first)
        history.entries = entries
        for _ in 0..<100 {
            if !store.isUpdating { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(store.snapshot?.totalWords == 8, "One window closing must not cancel another")
        history.entries = Array(repeating: entries[0], count: 1000)
        store.deactivate(second)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!store.isUpdating && store.snapshot?.totalWords == 8, "Hidden cancelled work cannot publish")
        history.entries = []
        precondition(store.snapshot == nil, "Reset must discard old totals immediately")
        store.activate(first)
        for _ in 0..<100 {
            if !store.isUpdating { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(store.snapshot?.totalWords == 0 && store.snapshot?.totalTranscriptions == 0)
        precondition(history.entries.isEmpty, "Stats must never write to history")
        store.deactivate(first)
        print("PASS: hidden inactivity, cache reuse, rapid replacement, multiple windows, cancellation, reset and no history writes")
    }
}
