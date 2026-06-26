//
//  TranscriptionHistoryStore.swift
//  Fluid
//
//  Persistence manager for Transcription Mode history
//

import Combine
import Foundation

// MARK: - Transcription History Entry Model

struct TranscriptionHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let rawText: String
    let processedText: String
    let appName: String
    let windowTitle: String
    let characterCount: Int
    let wasAIProcessed: Bool
    let processingModel: String?
    /// Non-nil when AI post-processing was configured but failed and we fell
    /// back to typing the raw transcription. The string carries the error
    /// message for display / debugging.
    let aiProcessingError: String?
    let audio: DictationAudioMetadata?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        processedText: String,
        appName: String,
        windowTitle: String,
        wasAIProcessed: Bool,
        processingModel: String? = nil,
        aiProcessingError: String? = nil,
        audio: DictationAudioMetadata? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.processedText = processedText
        self.appName = appName
        self.windowTitle = windowTitle
        self.characterCount = processedText.count
        self.wasAIProcessed = wasAIProcessed
        self.processingModel = processingModel
        self.aiProcessingError = aiProcessingError
        self.audio = audio
    }

    private init(
        id: UUID,
        timestamp: Date,
        rawText: String,
        processedText: String,
        appName: String,
        windowTitle: String,
        characterCount: Int,
        wasAIProcessed: Bool,
        processingModel: String?,
        aiProcessingError: String?,
        audio: DictationAudioMetadata?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.processedText = processedText
        self.appName = appName
        self.windowTitle = windowTitle
        self.characterCount = characterCount
        self.wasAIProcessed = wasAIProcessed
        self.processingModel = processingModel
        self.aiProcessingError = aiProcessingError
        self.audio = audio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.rawText = try container.decode(String.self, forKey: .rawText)
        self.processedText = try container.decode(String.self, forKey: .processedText)
        self.appName = try container.decode(String.self, forKey: .appName)
        self.windowTitle = try container.decode(String.self, forKey: .windowTitle)
        self.characterCount = try container.decode(Int.self, forKey: .characterCount)
        self.wasAIProcessed = try container.decode(Bool.self, forKey: .wasAIProcessed)
        self.processingModel = try container.decodeIfPresent(String.self, forKey: .processingModel)
        self.aiProcessingError = try container.decodeIfPresent(String.self, forKey: .aiProcessingError)
        self.audio = try container.decodeIfPresent(DictationAudioMetadata.self, forKey: .audio)
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, rawText, processedText, appName, windowTitle
        case characterCount, wasAIProcessed, processingModel, aiProcessingError, audio
    }

    /// Preview text for list display (first 80 chars)
    var previewText: String {
        let text = self.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 80 {
            return String(text.prefix(77)) + "..."
        }
        return text
    }

    /// Relative time string for display
    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self.timestamp, relativeTo: Date())
    }

    /// Full formatted date string
    var fullDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self.timestamp)
    }

    var hasAudioMetadata: Bool {
        self.audio != nil
    }

    func replacingAudio(_ audio: DictationAudioMetadata?) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            id: self.id,
            timestamp: self.timestamp,
            rawText: self.rawText,
            processedText: self.processedText,
            appName: self.appName,
            windowTitle: self.windowTitle,
            characterCount: self.characterCount,
            wasAIProcessed: self.wasAIProcessed,
            processingModel: self.processingModel,
            aiProcessingError: self.aiProcessingError,
            audio: audio
        )
    }
}

// MARK: - Transcription History Store

@MainActor
final class TranscriptionHistoryStore: ObservableObject {
    static let shared = TranscriptionHistoryStore()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let transcriptionHistory = "TranscriptionHistoryEntries"
    }

    @Published private(set) var entries: [TranscriptionHistoryEntry] = []
    @Published var selectedEntryID: UUID?

    private init() {
        self.loadEntries()
    }

    // MARK: - Public Methods

    /// Get selected entry
    var selectedEntry: TranscriptionHistoryEntry? {
        guard let id = selectedEntryID else { return nil }
        return self.entries.first(where: { $0.id == id })
    }

    /// Add a new transcription entry
    func addEntry(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        processedText: String,
        appName: String,
        windowTitle: String,
        wasAIProcessed: Bool? = nil,
        processingModel: String? = nil,
        aiProcessingError: String? = nil,
        audio: DictationAudioMetadata? = nil
    ) {
        // Skip empty transcriptions
        guard !processedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let entry = TranscriptionHistoryEntry(
            id: id,
            timestamp: timestamp,
            rawText: rawText,
            processedText: processedText,
            appName: appName,
            windowTitle: windowTitle,
            wasAIProcessed: wasAIProcessed ?? (processingModel != nil && aiProcessingError == nil),
            processingModel: processingModel,
            aiProcessingError: aiProcessingError,
            audio: audio
        )

        // Insert at beginning (newest first)
        self.entries.insert(entry, at: 0)

        self.saveEntries()
        if audio != nil {
            self.pruneAudioToBudget()
        }

        DebugLogger.shared.debug("Added transcription to history (total: \(self.entries.count))", source: "TranscriptionHistoryStore")
    }

    /// Delete a specific entry
    func deleteEntry(id: UUID) {
        if let audio = self.entries.first(where: { $0.id == id })?.audio {
            DictationAudioHistoryStore.shared.deleteAudio(fileName: audio.fileName)
        }
        self.entries.removeAll { $0.id == id }

        // Clear selection if deleted
        if self.selectedEntryID == id {
            self.selectedEntryID = self.entries.first?.id
        }

        self.saveEntries()
    }

    /// Delete multiple entries
    func deleteEntries(ids: Set<UUID>) {
        for entry in self.entries where ids.contains(entry.id) {
            if let audio = entry.audio {
                DictationAudioHistoryStore.shared.deleteAudio(fileName: audio.fileName)
            }
        }
        self.entries.removeAll { ids.contains($0.id) }

        if let selected = selectedEntryID, ids.contains(selected) {
            self.selectedEntryID = self.entries.first?.id
        }

        self.saveEntries()
    }

    /// Clear all history
    func clearAllHistory() {
        DictationAudioHistoryStore.shared.deleteAllAudioFiles()
        self.entries.removeAll()
        self.selectedEntryID = nil
        self.saveEntries()

        DebugLogger.shared.info("Cleared all transcription history", source: "TranscriptionHistoryStore")
    }

    /// Search entries by text content
    func search(query: String) -> [TranscriptionHistoryEntry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return self.entries
        }

        let lowercased = query.lowercased()
        return self.entries.filter { entry in
            entry.rawText.lowercased().contains(lowercased) ||
                entry.processedText.lowercased().contains(lowercased) ||
                entry.appName.lowercased().contains(lowercased) ||
                entry.windowTitle.lowercased().contains(lowercased)
        }
    }

    /// Get entries filtered by date range
    func entriesInRange(from startDate: Date, to endDate: Date) -> [TranscriptionHistoryEntry] {
        self.entries.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }

    /// Get total character count across all entries
    var totalCharacterCount: Int {
        self.entries.reduce(0) { $0 + $1.characterCount }
    }

    /// Get count of AI-processed entries
    var aiProcessedCount: Int {
        self.entries.filter { $0.wasAIProcessed }.count
    }

    func makeBackupPayload() -> [TranscriptionHistoryEntry] {
        self.entries
    }

    func restore(from payload: [TranscriptionHistoryEntry]) {
        self.entries = payload.sorted { $0.timestamp > $1.timestamp }
        self.selectedEntryID = self.entries.first?.id
        self.saveEntries()
    }

    func attachAudio(_ audio: DictationAudioMetadata, to entryID: UUID) {
        guard let index = self.entries.firstIndex(where: { $0.id == entryID }) else {
            DictationAudioHistoryStore.shared.deleteAudio(fileName: audio.fileName)
            return
        }
        self.entries[index] = self.entries[index].replacingAudio(audio)
        self.saveEntries()
        self.pruneAudioToBudget()
    }

    @discardableResult
    func deleteAllSavedAudio() -> Int {
        let removedCount = self.entries.filter { $0.audio != nil }.count
        DictationAudioHistoryStore.shared.deleteAllAudioFiles()
        self.entries = self.entries.map { $0.replacingAudio(nil) }
        self.saveEntries()
        DebugLogger.shared.info("Deleted saved dictation audio (\(removedCount) entries)", source: "TranscriptionHistoryStore")
        return removedCount
    }

    @discardableResult
    func pruneAudioToBudget() -> Int {
        let budgetBytes = SettingsStore.shared.audioHistoryBudgetBytes
        guard budgetBytes > 0 else {
            return self.deleteAllSavedAudio()
        }

        var currentBytes = DictationAudioHistoryStore.shared.audioUsageBytes()
        guard currentBytes > budgetBytes else { return 0 }

        var updatedEntries = self.entries
        let referencedFileNames = Set(updatedEntries.compactMap { $0.audio?.fileName })
        let orphanedAudio = DictationAudioHistoryStore.shared.deleteUnreferencedAudioFiles(referencedFileNames: referencedFileNames)
        if orphanedAudio.fileCount > 0 {
            currentBytes = max(0, currentBytes - orphanedAudio.byteCount)
            DebugLogger.shared.info("Pruned orphaned dictation audio (\(orphanedAudio.fileCount) files)", source: "TranscriptionHistoryStore")
        }
        guard currentBytes > budgetBytes else { return 0 }

        var prunedCount = 0
        for index in updatedEntries.indices.reversed() {
            guard let audio = updatedEntries[index].audio else { continue }
            let removedBytes = DictationAudioHistoryStore.shared.deleteAudio(fileName: audio.fileName)
            currentBytes = max(0, currentBytes - removedBytes)
            updatedEntries[index] = updatedEntries[index].replacingAudio(nil)
            prunedCount += 1
            if currentBytes <= budgetBytes {
                break
            }
        }

        if prunedCount > 0 {
            self.entries = updatedEntries
            self.saveEntries()
            DebugLogger.shared.info("Pruned saved dictation audio (\(prunedCount) entries)", source: "TranscriptionHistoryStore")
        }
        return prunedCount
    }

    // MARK: - Private Methods

    private func loadEntries() {
        guard let data = defaults.data(forKey: Keys.transcriptionHistory),
              let decoded = try? JSONDecoder().decode([TranscriptionHistoryEntry].self, from: data)
        else {
            self.entries = []
            return
        }
        self.entries = decoded
    }

    private func saveEntries() {
        if let encoded = try? JSONEncoder().encode(entries) {
            self.defaults.set(encoded, forKey: Keys.transcriptionHistory)
        }
        objectWillChange.send()
    }
}

// MARK: - Stats Computation Extension

extension TranscriptionHistoryStore {
    struct TodaySummary {
        let words: Int
        let transcriptions: Int

        func timeSavedMinutes(typingWPM: Int = 40, speakingWPM: Int = 150) -> Double {
            guard typingWPM > 0 && speakingWPM > 0 else { return 0 }

            let words = Double(self.words)
            let typingTime = words / Double(typingWPM)
            let speakingTime = words / Double(speakingWPM)

            return max(0, typingTime - speakingTime)
        }

        func formattedTimeSaved(typingWPM: Int = 40) -> String {
            let minutes = self.timeSavedMinutes(typingWPM: typingWPM)

            if minutes < 1 {
                return "< 1m"
            } else if minutes < 60 {
                return "\(Int(minutes))m"
            } else {
                let hours = Int(minutes) / 60
                let mins = Int(minutes) % 60
                if mins == 0 {
                    return "\(hours)h"
                }
                return "\(hours)h \(mins)m"
            }
        }
    }

    // MARK: - Word Counting

    /// Count words in a string (handles multiple spaces, newlines)
    private func wordCount(in text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let words = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return words.count
    }

    /// Total words across all transcriptions
    var totalWords: Int {
        self.entries.reduce(0) { $0 + self.wordCount(in: $1.processedText) }
    }

    /// Summary for today's activity, calculated in one pass.
    var todaySummary: TodaySummary {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let totals = self.entries.reduce(into: (words: 0, transcriptions: 0)) { result, entry in
            guard calendar.isDate(entry.timestamp, inSameDayAs: today) else { return }
            result.words += self.wordCount(in: entry.processedText)
            result.transcriptions += 1
        }
        return TodaySummary(words: totals.words, transcriptions: totals.transcriptions)
    }

    /// Words transcribed today
    var wordsToday: Int {
        self.todaySummary.words
    }

    /// Number of transcriptions recorded today
    var transcriptionsToday: Int {
        self.todaySummary.transcriptions
    }

    /// Average words per transcription
    var averageWordsPerTranscription: Int {
        guard !self.entries.isEmpty else { return 0 }
        return self.totalWords / self.entries.count
    }

    // MARK: - Time Saved Calculation

    /// Calculate time saved in minutes
    /// - Parameters:
    ///   - typingWPM: User's typing speed (default 40)
    ///   - speakingWPM: Average speaking speed (default 150)
    func timeSavedMinutes(typingWPM: Int = 40, speakingWPM: Int = 150) -> Double {
        guard typingWPM > 0 && speakingWPM > 0 else { return 0 }

        let words = Double(totalWords)
        let typingTime = words / Double(typingWPM) // minutes to type
        let speakingTime = words / Double(speakingWPM) // minutes to speak

        return max(0, typingTime - speakingTime)
    }

    /// Formatted time saved string (e.g., "2h 45m" or "45m")
    func formattedTimeSaved(typingWPM: Int = 40) -> String {
        let minutes = self.timeSavedMinutes(typingWPM: typingWPM)

        if minutes < 1 {
            return "< 1m"
        } else if minutes < 60 {
            return "\(Int(minutes))m"
        } else {
            let hours = Int(minutes) / 60
            let mins = Int(minutes) % 60
            if mins == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(mins)m"
        }
    }

    // MARK: - Today Time Saved

    /// Calculate time saved today in minutes
    /// - Parameters:
    ///   - typingWPM: User's typing speed (default 40)
    ///   - speakingWPM: Average speaking speed (default 150)
    func timeSavedTodayMinutes(typingWPM: Int = 40, speakingWPM: Int = 150) -> Double {
        self.todaySummary.timeSavedMinutes(typingWPM: typingWPM, speakingWPM: speakingWPM)
    }

    /// Formatted time saved today string (e.g., "2h 45m" or "45m")
    func formattedTimeSavedToday(typingWPM: Int = 40) -> String {
        self.todaySummary.formattedTimeSaved(typingWPM: typingWPM)
    }

    // MARK: - Streak Calculation

    /// Get unique days with activity (sorted newest first)
    private var activeDays: [Date] {
        let calendar = Calendar.current
        var uniqueDays = Set<Date>()

        for entry in self.entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            uniqueDays.insert(day)
        }

        return uniqueDays.sorted(by: >) // newest first
    }

    /// Current streak (consecutive days including today or yesterday)
    var currentStreak: Int {
        let calendar = Calendar.current
        let skipWeekends = SettingsStore.shared.weekendsDontBreakStreak

        // Filter out weekend days if setting is enabled (so weekend usage doesn't interfere)
        let days: [Date]
        if skipWeekends {
            days = self.activeDays.filter { !calendar.isDateInWeekend($0) }
        } else {
            days = self.activeDays
        }

        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return 0
        }

        // Find the most recent "valid" day (skip weekends if setting enabled)
        var checkDay = today
        if skipWeekends {
            // Find the last weekday (today or before)
            while calendar.isDateInWeekend(checkDay) {
                guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDay) else { break }
                checkDay = prev
            }
        }

        // Must have activity on a recent valid day to have an active streak
        guard let firstActiveDay = days.first else { return 0 }

        // Check if the first active day is recent enough (today, yesterday, or last valid weekday)
        let isRecent: Bool
        if skipWeekends {
            // Find previous weekday from today
            var lastValidDay = today
            while calendar.isDateInWeekend(lastValidDay) {
                guard let prev = calendar.date(byAdding: .day, value: -1, to: lastValidDay) else { break }
                lastValidDay = prev
            }
            // Allow one weekday gap (the previous weekday before lastValidDay)
            guard let prevWeekday = self.previousWeekday(before: lastValidDay, calendar: calendar) else {
                isRecent = firstActiveDay == lastValidDay
                return isRecent ? 1 : 0
            }
            isRecent = firstActiveDay == lastValidDay || firstActiveDay == prevWeekday
        } else {
            isRecent = firstActiveDay == today || firstActiveDay == yesterday
        }

        guard isRecent else { return 0 }

        var streak = 1
        var previousDay = firstActiveDay

        for day in days.dropFirst() {
            let expectedPrevious: Date?
            if skipWeekends {
                expectedPrevious = self.previousWeekday(before: previousDay, calendar: calendar)
            } else {
                expectedPrevious = calendar.date(byAdding: .day, value: -1, to: previousDay)
            }

            guard let expected = expectedPrevious else { break }

            if day == expected {
                streak += 1
                previousDay = day
            } else {
                break
            }
        }

        return streak
    }

    /// Helper: get the previous weekday (skipping weekends)
    private func previousWeekday(before date: Date, calendar: Calendar) -> Date? {
        var candidate = calendar.date(byAdding: .day, value: -1, to: date)
        while let c = candidate, calendar.isDateInWeekend(c) {
            candidate = calendar.date(byAdding: .day, value: -1, to: c)
        }
        return candidate
    }

    /// Best streak ever achieved
    var bestStreak: Int {
        let calendar = Calendar.current
        let skipWeekends = SettingsStore.shared.weekendsDontBreakStreak

        // Filter out weekend days if setting is enabled (so weekend usage doesn't interfere)
        let days: [Date]
        if skipWeekends {
            days = self.activeDays.filter { !calendar.isDateInWeekend($0) }.sorted()
        } else {
            days = self.activeDays.sorted() // oldest first for this calculation
        }

        guard !days.isEmpty else { return 0 }

        var maxStreak = 1
        var currentStreakCount = 1
        var previousDay = days[0]

        for day in days.dropFirst() {
            let expectedNext: Date?
            if skipWeekends {
                expectedNext = self.nextWeekday(after: previousDay, calendar: calendar)
            } else {
                expectedNext = calendar.date(byAdding: .day, value: 1, to: previousDay)
            }

            if let expected = expectedNext, day == expected {
                currentStreakCount += 1
                maxStreak = max(maxStreak, currentStreakCount)
            } else {
                currentStreakCount = 1
            }
            previousDay = day
        }

        return maxStreak
    }

    /// Helper: get the next weekday (skipping weekends)
    private func nextWeekday(after date: Date, calendar: Calendar) -> Date? {
        var candidate = calendar.date(byAdding: .day, value: 1, to: date)
        while let c = candidate, calendar.isDateInWeekend(c) {
            candidate = calendar.date(byAdding: .day, value: 1, to: c)
        }
        return candidate
    }

    // MARK: - Daily Activity Data (for charts)

    /// Daily word counts for the last N days
    func dailyWordCounts(days: Int) -> [(date: Date, words: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var result: [(date: Date, words: Int)] = []

        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }

            let dayEntries = self.entries.filter { calendar.isDate($0.timestamp, inSameDayAs: date) }
            let words = dayEntries.reduce(0) { $0 + self.wordCount(in: $1.processedText) }

            result.append((date: date, words: words))
        }

        return result.reversed() // oldest to newest for chart display
    }

    /// Daily transcription counts for the last N days
    func dailyTranscriptionCounts(days: Int) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var result: [(date: Date, count: Int)] = []

        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }

            let count = self.entries.filter { calendar.isDate($0.timestamp, inSameDayAs: date) }.count
            result.append((date: date, count: count))
        }

        return result.reversed()
    }

    // MARK: - Top Apps

    /// Most used apps (sorted by usage count)
    var topApps: [(app: String, count: Int)] {
        var appCounts: [String: Int] = [:]

        for entry in self.entries {
            let app = entry.appName.isEmpty ? "Unknown" : entry.appName
            appCounts[app, default: 0] += 1
        }

        return appCounts
            .map { (app: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// Top N apps formatted for display
    func topAppsFormatted(limit: Int = 5) -> [String] {
        self.topApps.prefix(limit).map { $0.app }
    }

    // MARK: - AI Enhancement Rate

    /// Percentage of transcriptions that were AI-enhanced (0-100)
    var aiEnhancementRate: Int {
        guard !self.entries.isEmpty else { return 0 }
        return (self.aiProcessedCount * 100) / self.entries.count
    }

    // MARK: - Peak Usage Hours

    /// Hour of day with most transcriptions (0-23)
    var peakHour: Int? {
        guard !self.entries.isEmpty else { return nil }

        let calendar = Calendar.current
        var hourCounts: [Int: Int] = [:]

        for entry in self.entries {
            let hour = calendar.component(.hour, from: entry.timestamp)
            hourCounts[hour, default: 0] += 1
        }

        return hourCounts.max(by: { $0.value < $1.value })?.key
    }

    /// Formatted peak hour range (e.g., "2-3 PM")
    var peakHourFormatted: String {
        guard let hour = peakHour else { return "N/A" }

        let formatter = DateFormatter()
        formatter.dateFormat = "h a"

        let calendar = Calendar.current
        var components = DateComponents()
        components.hour = hour

        guard let startDate = calendar.date(from: components),
              let endDate = calendar.date(byAdding: .hour, value: 1, to: startDate)
        else {
            return "N/A"
        }

        let startStr = formatter.string(from: startDate)
        let endStr = formatter.string(from: endDate)

        return "\(startStr)-\(endStr)"
    }

    // MARK: - Personal Records

    /// Longest single transcription (word count)
    var longestTranscriptionWords: Int {
        self.entries.map { self.wordCount(in: $0.processedText) }.max() ?? 0
    }

    /// Most words in a single day
    var mostWordsInDay: Int {
        let calendar = Calendar.current
        var dayTotals: [Date: Int] = [:]

        for entry in self.entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            dayTotals[day, default: 0] += self.wordCount(in: entry.processedText)
        }

        return dayTotals.values.max() ?? 0
    }

    /// Most transcriptions in a single day
    var mostTranscriptionsInDay: Int {
        let calendar = Calendar.current
        var dayCounts: [Date: Int] = [:]

        for entry in self.entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            dayCounts[day, default: 0] += 1
        }

        return dayCounts.values.max() ?? 0
    }

    // MARK: - Milestones

    /// Word count milestones and whether they've been achieved
    var wordMilestones: [(target: Int, achieved: Bool, label: String)] {
        let milestones = [
            (1000, "1K"),
            (10_000, "10K"),
            (50_000, "50K"),
            (100_000, "100K"),
            (500_000, "500K"),
            (1_000_000, "1M"),
        ]

        let total = self.totalWords
        return milestones.map { (target: $0.0, achieved: total >= $0.0, label: $0.1) }
    }

    /// Transcription count milestones
    var transcriptionMilestones: [(target: Int, achieved: Bool, label: String)] {
        let milestones = [
            (50, "50"),
            (100, "100"),
            (500, "500"),
            (1000, "1K"),
            (5000, "5K"),
            (10_000, "10K"),
        ]

        let total = self.entries.count
        return milestones.map { (target: $0.0, achieved: total >= $0.0, label: $0.1) }
    }

    /// Streak milestones
    var streakMilestones: [(target: Int, achieved: Bool, label: String)] {
        let milestones = [
            (7, "7 days"),
            (14, "14 days"),
            (30, "30 days"),
            (60, "60 days"),
            (100, "100 days"),
            (365, "1 year"),
        ]

        let best = self.bestStreak
        return milestones.map { (target: $0.0, achieved: best >= $0.0, label: $0.1) }
    }

    /// Total milestones achieved
    var totalMilestonesAchieved: Int {
        self.wordMilestones.filter { $0.achieved }.count +
            self.transcriptionMilestones.filter { $0.achieved }.count +
            self.streakMilestones.filter { $0.achieved }.count
    }

    /// Total possible milestones
    var totalMilestonesPossible: Int {
        self.wordMilestones.count + self.transcriptionMilestones.count + self.streakMilestones.count
    }
}
