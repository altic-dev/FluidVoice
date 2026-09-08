import Foundation

/// A bounded, read-only summary. No transcription text is retained in the result.
nonisolated struct StatsSnapshot: Sendable {
    var totalWords = 0
    var totalTranscriptions = 0
    var aiProcessedCount = 0
    var longestTranscriptionWords = 0
    var mostWordsInDay = 0
    var mostTranscriptionsInDay = 0
    var currentStreak = 0
    var bestStreak = 0
    var weekdayCurrentStreak = 0
    var weekdayBestStreak = 0
    var peakHourFormatted = "N/A"
    var topApps: [String] = []
    var activity: [(date: Date, words: Int)] = []

    var averageWordsPerTranscription: Int {
        self.totalTranscriptions == 0 ? 0 : self.totalWords / self.totalTranscriptions
    }

    var aiEnhancementRate: Int {
        self.totalTranscriptions == 0 ? 0 : self.aiProcessedCount * 100 / self.totalTranscriptions
    }

    func formattedTimeSaved(typingWPM: Int) -> String {
        let minutes = typingWPM > 0 ? max(0, Double(self.totalWords) / Double(typingWPM) - Double(self.totalWords) / 150) : 0
        if minutes < 1 { return "< 1m" }
        if minutes < 60 { return "\(Int(minutes))m" }
        let hours = Int(minutes) / 60
        let remainder = Int(minutes) % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    func dailyWordCounts(days: Int) -> [(date: Date, words: Int)] {
        Array(self.activity.suffix(max(0, days)))
    }

    func topAppsFormatted(limit: Int) -> [String] {
        Array(self.topApps.prefix(max(0, limit)))
    }

    var wordMilestones: [(target: Int, achieved: Bool, label: String)] {
        [(1000, "1K"), (10_000, "10K"), (50_000, "50K"), (100_000, "100K"), (500_000, "500K"), (1_000_000, "1M")]
            .map { ($0.0, self.totalWords >= $0.0, $0.1) }
    }

    var transcriptionMilestones: [(target: Int, achieved: Bool, label: String)] {
        [(50, "50"), (100, "100"), (500, "500"), (1000, "1K"), (5000, "5K"), (10_000, "10K")]
            .map { ($0.0, self.totalTranscriptions >= $0.0, $0.1) }
    }

    var streakMilestones: [(target: Int, achieved: Bool, label: String)] {
        [(7, "7 days"), (14, "14 days"), (30, "30 days"), (60, "60 days"), (100, "100 days"), (365, "1 year")]
            .map { ($0.0, self.bestStreak >= $0.0, $0.1) }
    }

    var totalMilestonesAchieved: Int {
        self.wordMilestones.filter(\.achieved).count + self.transcriptionMilestones.filter(\.achieved).count
            + self.streakMilestones.filter(\.achieved).count
    }

    let totalMilestonesPossible = 18

    func usingWeekdays(_ enabled: Bool) -> Self {
        var result = self
        if enabled {
            result.currentStreak = self.weekdayCurrentStreak
            result.bestStreak = self.weekdayBestStreak
        }
        return result
    }

    static func build(entries: [TranscriptionHistoryEntry], now: Date, calendar: Calendar) throws -> Self {
        var result = Self()
        var dayWords: [Date: Int] = [:]
        var dayCounts: [Date: Int] = [:]
        var appCounts: [String: Int] = [:]
        var hours = Array(repeating: 0, count: 24)
        result.totalTranscriptions = entries.count
        for (index, entry) in entries.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let words = entry.processedText.components(separatedBy: .whitespacesAndNewlines).lazy.filter { !$0.isEmpty }.count
            let day = calendar.startOfDay(for: entry.timestamp)
            dayWords[day, default: 0] += words
            dayCounts[day, default: 0] += 1
            appCounts[entry.appName.isEmpty ? "Unknown" : entry.appName, default: 0] += 1
            hours[calendar.component(.hour, from: entry.timestamp)] += 1
            result.totalWords += words
            result.longestTranscriptionWords = max(result.longestTranscriptionWords, words)
            if entry.wasAIProcessed { result.aiProcessedCount += 1 }
        }
        try Task.checkCancellation()
        result.mostWordsInDay = dayWords.values.max() ?? 0
        result.mostTranscriptionsInDay = dayCounts.values.max() ?? 0
        result.topApps = appCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(5).map(\.key)
        let today = calendar.startOfDay(for: now)
        result.activity = (0..<30).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (date, dayWords[date, default: 0])
        }
        let days = dayCounts.keys.sorted(by: >)
        (result.currentStreak, result.bestStreak) = try Self.streaks(days: days, today: today, calendar: calendar, weekdays: false)
        (result.weekdayCurrentStreak, result.weekdayBestStreak) = try Self.streaks(days: days, today: today, calendar: calendar, weekdays: true)
        if !entries.isEmpty, let hour = hours.indices.max(by: { hours[$0] < hours[$1] }) {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "h a"
            if let start = calendar.date(from: DateComponents(hour: hour)),
               let end = calendar.date(byAdding: .hour, value: 1, to: start)
            {
                result.peakHourFormatted = "\(formatter.string(from: start))-\(formatter.string(from: end))"
            }
        }
        return result
    }

    private static func previousDay(_ day: Date, calendar: Calendar, weekdays: Bool) -> Date? {
        var date = day
        for _ in 0..<7 {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { return nil }
            if !weekdays || !calendar.isDateInWeekend(previous) { return previous }
            date = previous
        }
        return nil
    }

    private static func streaks(days: [Date], today: Date, calendar: Calendar, weekdays: Bool) throws -> (Int, Int) {
        let days = weekdays ? days.filter { !calendar.isDateInWeekend($0) } : days
        guard let first = days.first else { return (0, 0) }
        let latest = weekdays && calendar.isDateInWeekend(today)
            ? Self.previousDay(today, calendar: calendar, weekdays: true) : today
        let recent = latest.map { first == $0 || first == Self.previousDay($0, calendar: calendar, weekdays: weekdays) } ?? false
        var initialRun = 1
        var run = 1
        var best = 1
        var initial = true
        for index in 1..<days.count {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if days[index] == Self.previousDay(days[index - 1], calendar: calendar, weekdays: weekdays) {
                run += 1
                if initial { initialRun += 1 }
            } else {
                initial = false
                run = 1
            }
            best = max(best, run)
        }
        return (recent ? initialRun : 0, best)
    }
}
