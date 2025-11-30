//
//  TranscriptionHistoryStore.swift
//  Fluid
//
//  Persistence manager for Transcription Mode history
//

import Foundation
import Combine

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
    
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        processedText: String,
        appName: String,
        windowTitle: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.processedText = processedText
        self.appName = appName
        self.windowTitle = windowTitle
        self.characterCount = processedText.count
        self.wasAIProcessed = rawText != processedText
    }
    
    /// Preview text for list display (first 80 chars)
    var previewText: String {
        let text = processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 80 {
            return String(text.prefix(77)) + "..."
        }
        return text
    }
    
    /// Relative time string for display
    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }
    
    /// Full formatted date string
    var fullDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

// MARK: - Transcription History Store

@MainActor
final class TranscriptionHistoryStore: ObservableObject {
    static let shared = TranscriptionHistoryStore()
    
    private let defaults = UserDefaults.standard
    private let maxEntries = 1000
    
    private enum Keys {
        static let transcriptionHistory = "TranscriptionHistoryEntries"
    }
    
    @Published private(set) var entries: [TranscriptionHistoryEntry] = []
    @Published var selectedEntryID: UUID?
    
    private init() {
        loadEntries()
    }
    
    // MARK: - Public Methods
    
    /// Get selected entry
    var selectedEntry: TranscriptionHistoryEntry? {
        guard let id = selectedEntryID else { return nil }
        return entries.first(where: { $0.id == id })
    }
    
    /// Add a new transcription entry
    func addEntry(
        rawText: String,
        processedText: String,
        appName: String,
        windowTitle: String
    ) {
        // Skip empty transcriptions
        guard !processedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let entry = TranscriptionHistoryEntry(
            rawText: rawText,
            processedText: processedText,
            appName: appName,
            windowTitle: windowTitle
        )
        
        // Insert at beginning (newest first)
        entries.insert(entry, at: 0)
        
        // Trim old entries if over limit
        trimOldEntries()
        saveEntries()
        
        DebugLogger.shared.debug("Added transcription to history (total: \(entries.count))", source: "TranscriptionHistoryStore")
    }
    
    /// Delete a specific entry
    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        
        // Clear selection if deleted
        if selectedEntryID == id {
            selectedEntryID = entries.first?.id
        }
        
        saveEntries()
    }
    
    /// Delete multiple entries
    func deleteEntries(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        
        if let selected = selectedEntryID, ids.contains(selected) {
            selectedEntryID = entries.first?.id
        }
        
        saveEntries()
    }
    
    /// Clear all history
    func clearAllHistory() {
        entries.removeAll()
        selectedEntryID = nil
        saveEntries()
        
        DebugLogger.shared.info("Cleared all transcription history", source: "TranscriptionHistoryStore")
    }
    
    /// Search entries by text content
    func search(query: String) -> [TranscriptionHistoryEntry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return entries
        }
        
        let lowercased = query.lowercased()
        return entries.filter { entry in
            entry.rawText.lowercased().contains(lowercased) ||
            entry.processedText.lowercased().contains(lowercased) ||
            entry.appName.lowercased().contains(lowercased) ||
            entry.windowTitle.lowercased().contains(lowercased)
        }
    }
    
    /// Get entries filtered by date range
    func entriesInRange(from startDate: Date, to endDate: Date) -> [TranscriptionHistoryEntry] {
        entries.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }
    
    /// Get total character count across all entries
    var totalCharacterCount: Int {
        entries.reduce(0) { $0 + $1.characterCount }
    }
    
    /// Get count of AI-processed entries
    var aiProcessedCount: Int {
        entries.filter { $0.wasAIProcessed }.count
    }
    
    // MARK: - Private Methods
    
    private func loadEntries() {
        guard let data = defaults.data(forKey: Keys.transcriptionHistory),
              let decoded = try? JSONDecoder().decode([TranscriptionHistoryEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }
    
    private func saveEntries() {
        if let encoded = try? JSONEncoder().encode(entries) {
            defaults.set(encoded, forKey: Keys.transcriptionHistory)
        }
        objectWillChange.send()
    }
    
    private func trimOldEntries() {
        if entries.count > maxEntries {
            // Keep most recent entries
            entries = Array(entries.prefix(maxEntries))
        }
    }
}

// MARK: - Stats Computation Extension

extension TranscriptionHistoryStore {
    
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
        entries.reduce(0) { $0 + wordCount(in: $1.processedText) }
    }
    
    /// Words transcribed today
    var wordsToday: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return entries
            .filter { calendar.isDate($0.timestamp, inSameDayAs: today) }
            .reduce(0) { $0 + wordCount(in: $1.processedText) }
    }
    
    /// Average words per transcription
    var averageWordsPerTranscription: Int {
        guard !entries.isEmpty else { return 0 }
        return totalWords / entries.count
    }
    
    // MARK: - Time Saved Calculation
    
    /// Calculate time saved in minutes
    /// - Parameters:
    ///   - typingWPM: User's typing speed (default 40)
    ///   - speakingWPM: Average speaking speed (default 150)
    func timeSavedMinutes(typingWPM: Int = 40, speakingWPM: Int = 150) -> Double {
        guard typingWPM > 0 && speakingWPM > 0 else { return 0 }
        
        let words = Double(totalWords)
        let typingTime = words / Double(typingWPM)  // minutes to type
        let speakingTime = words / Double(speakingWPM)  // minutes to speak
        
        return max(0, typingTime - speakingTime)
    }
    
    /// Formatted time saved string (e.g., "2h 45m" or "45m")
    func formattedTimeSaved(typingWPM: Int = 40) -> String {
        let minutes = timeSavedMinutes(typingWPM: typingWPM)
        
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
    
    // MARK: - Streak Calculation
    
    /// Get unique days with activity (sorted newest first)
    private var activeDays: [Date] {
        let calendar = Calendar.current
        var uniqueDays = Set<Date>()
        
        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            uniqueDays.insert(day)
        }
        
        return uniqueDays.sorted(by: >)  // newest first
    }
    
    /// Current streak (consecutive days including today or yesterday)
    var currentStreak: Int {
        let calendar = Calendar.current
        let days = activeDays
        
        guard !days.isEmpty else { return 0 }
        
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        
        // Must have activity today or yesterday to have an active streak
        guard let firstActiveDay = days.first,
              firstActiveDay == today || firstActiveDay == yesterday else {
            return 0
        }
        
        var streak = 1
        var previousDay = firstActiveDay
        
        for day in days.dropFirst() {
            let expectedPrevious = calendar.date(byAdding: .day, value: -1, to: previousDay)!
            
            if day == expectedPrevious {
                streak += 1
                previousDay = day
            } else {
                break
            }
        }
        
        return streak
    }
    
    /// Best streak ever achieved
    var bestStreak: Int {
        let calendar = Calendar.current
        let days = activeDays.sorted()  // oldest first for this calculation
        
        guard !days.isEmpty else { return 0 }
        
        var maxStreak = 1
        var currentStreakCount = 1
        var previousDay = days[0]
        
        for day in days.dropFirst() {
            let expectedNext = calendar.date(byAdding: .day, value: 1, to: previousDay)!
            
            if day == expectedNext {
                currentStreakCount += 1
                maxStreak = max(maxStreak, currentStreakCount)
            } else {
                currentStreakCount = 1
            }
            previousDay = day
        }
        
        return maxStreak
    }
    
    // MARK: - Daily Activity Data (for charts)
    
    /// Daily word counts for the last N days
    func dailyWordCounts(days: Int) -> [(date: Date, words: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        var result: [(date: Date, words: Int)] = []
        
        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            
            let dayEntries = entries.filter { calendar.isDate($0.timestamp, inSameDayAs: date) }
            let words = dayEntries.reduce(0) { $0 + wordCount(in: $1.processedText) }
            
            result.append((date: date, words: words))
        }
        
        return result.reversed()  // oldest to newest for chart display
    }
    
    /// Daily transcription counts for the last N days
    func dailyTranscriptionCounts(days: Int) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        var result: [(date: Date, count: Int)] = []
        
        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            
            let count = entries.filter { calendar.isDate($0.timestamp, inSameDayAs: date) }.count
            result.append((date: date, count: count))
        }
        
        return result.reversed()
    }
    
    // MARK: - Top Apps
    
    /// Most used apps (sorted by usage count)
    var topApps: [(app: String, count: Int)] {
        var appCounts: [String: Int] = [:]
        
        for entry in entries {
            let app = entry.appName.isEmpty ? "Unknown" : entry.appName
            appCounts[app, default: 0] += 1
        }
        
        return appCounts
            .map { (app: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }
    
    /// Top N apps formatted for display
    func topAppsFormatted(limit: Int = 5) -> [String] {
        topApps.prefix(limit).map { $0.app }
    }
    
    // MARK: - AI Enhancement Rate
    
    /// Percentage of transcriptions that were AI-enhanced (0-100)
    var aiEnhancementRate: Int {
        guard !entries.isEmpty else { return 0 }
        return (aiProcessedCount * 100) / entries.count
    }
    
    // MARK: - Peak Usage Hours
    
    /// Hour of day with most transcriptions (0-23)
    var peakHour: Int? {
        guard !entries.isEmpty else { return nil }
        
        let calendar = Calendar.current
        var hourCounts: [Int: Int] = [:]
        
        for entry in entries {
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
              let endDate = calendar.date(byAdding: .hour, value: 1, to: startDate) else {
            return "N/A"
        }
        
        let startStr = formatter.string(from: startDate)
        let endStr = formatter.string(from: endDate)
        
        return "\(startStr)-\(endStr)"
    }
    
    // MARK: - Personal Records
    
    /// Longest single transcription (word count)
    var longestTranscriptionWords: Int {
        entries.map { wordCount(in: $0.processedText) }.max() ?? 0
    }
    
    /// Most words in a single day
    var mostWordsInDay: Int {
        let calendar = Calendar.current
        var dayTotals: [Date: Int] = [:]
        
        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            dayTotals[day, default: 0] += wordCount(in: entry.processedText)
        }
        
        return dayTotals.values.max() ?? 0
    }
    
    /// Most transcriptions in a single day
    var mostTranscriptionsInDay: Int {
        let calendar = Calendar.current
        var dayCounts: [Date: Int] = [:]
        
        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            dayCounts[day, default: 0] += 1
        }
        
        return dayCounts.values.max() ?? 0
    }
    
    // MARK: - Milestones
    
    /// Word count milestones and whether they've been achieved
    var wordMilestones: [(target: Int, achieved: Bool, label: String)] {
        let milestones = [
            (1_000, "1K"),
            (10_000, "10K"),
            (50_000, "50K"),
            (100_000, "100K"),
            (500_000, "500K"),
            (1_000_000, "1M")
        ]
        
        let total = totalWords
        return milestones.map { (target: $0.0, achieved: total >= $0.0, label: $0.1) }
    }
    
    /// Transcription count milestones
    var transcriptionMilestones: [(target: Int, achieved: Bool, label: String)] {
        let milestones = [
            (50, "50"),
            (100, "100"),
            (500, "500"),
            (1_000, "1K"),
            (5_000, "5K"),
            (10_000, "10K")
        ]
        
        let total = entries.count
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
            (365, "1 year")
        ]
        
        let best = bestStreak
        return milestones.map { (target: $0.0, achieved: best >= $0.0, label: $0.1) }
    }
    
    /// Total milestones achieved
    var totalMilestonesAchieved: Int {
        wordMilestones.filter { $0.achieved }.count +
        transcriptionMilestones.filter { $0.achieved }.count +
        streakMilestones.filter { $0.achieved }.count
    }
    
    /// Total possible milestones
    var totalMilestonesPossible: Int {
        wordMilestones.count + transcriptionMilestones.count + streakMilestones.count
    }
}

