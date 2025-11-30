//
//  StatsView.swift
//  Fluid
//
//  Usage statistics dashboard with gamification elements
//

import SwiftUI

struct StatsView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    
    @State private var showResetConfirmation: Bool = false
    @State private var showWPMEditor: Bool = false
    @State private var editingWPM: String = ""
    @State private var chartDays: Int = 7  // Toggle between 7 and 30
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // Header row: Time Saved + Total Words
                HStack(spacing: 16) {
                    timeSavedCard
                    totalWordsCard
                }
                
                // Second row: Streak + Transcriptions
                HStack(spacing: 16) {
                    streakCard
                    transcriptionsCard
                }
                
                // Activity Chart
                activityChartCard
                
                // Milestones
                milestonesCard
                
                // Insights
                insightsCard
                
                // Personal Records
                recordsCard
                
                // Reset Button
                resetSection
            }
            .padding(20)
        }
    }
    
    // MARK: - Time Saved Card
    
    private var timeSavedCard: some View {
        StatCard(title: "TIME SAVED", icon: "clock.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text(historyStore.formattedTimeSaved(typingWPM: settings.userTypingWPM))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Button {
                    editingWPM = "\(settings.userTypingWPM)"
                    showWPMEditor = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Based on \(settings.userTypingWPM) WPM typing")
                            .font(.system(size: 11))
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .popover(isPresented: $showWPMEditor) {
            wpmEditorPopover
        }
    }
    
    private var wpmEditorPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Typing Speed")
                .font(.system(size: 13, weight: .semibold))
            
            HStack {
                TextField("WPM", text: $editingWPM)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)
                
                Text("words per minute")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            
            Text("Average typing: 40 WPM\nProfessional: 65-75 WPM")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            
            HStack {
                Button("Cancel") {
                    showWPMEditor = false
                }
                .buttonStyle(.bordered)
                
                Button("Save") {
                    if let wpm = Int(editingWPM), wpm > 0 {
                        settings.userTypingWPM = wpm
                    }
                    showWPMEditor = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 220)
    }
    
    // MARK: - Total Words Card
    
    private var totalWordsCard: some View {
        StatCard(title: "TOTAL WORDS", icon: "text.word.spacing") {
            VStack(alignment: .leading, spacing: 8) {
                Text(formatNumber(historyStore.totalWords))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                let today = historyStore.wordsToday
                if today > 0 {
                    Text("+\(formatNumber(today)) today")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.success)
                } else {
                    Text("Start dictating")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    // MARK: - Streak Card
    
    private var streakCard: some View {
        StatCard(title: "CURRENT STREAK", icon: "flame.fill") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(historyStore.currentStreak)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(historyStore.currentStreak > 0 ? theme.palette.warning : .primary)
                    
                    Text(historyStore.currentStreak == 1 ? "day" : "days")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                
                Text("Best: \(historyStore.bestStreak) days")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Transcriptions Card
    
    private var transcriptionsCard: some View {
        StatCard(title: "TRANSCRIPTIONS", icon: "doc.text.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(historyStore.entries.count)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text("Avg: \(historyStore.averageWordsPerTranscription) words each")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Activity Chart Card
    
    private var activityChartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("ACTIVITY", systemImage: "chart.bar.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Picker("", selection: $chartDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            
            let data = historyStore.dailyWordCounts(days: chartDays)
            let maxWords = data.map { $0.words }.max() ?? 0
            
            if maxWords == 0 {
                // Empty state
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No activity yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 30)
                    Spacer()
                }
            } else {
                // Bar chart
                HStack(alignment: .bottom, spacing: chartDays == 7 ? 8 : 2) {
                    ForEach(Array(data.enumerated()), id: \.offset) { index, item in
                        VStack(spacing: 4) {
                            // Bar (avoid division by zero)
                            let height = (item.words > 0 && maxWords > 0) ? CGFloat(item.words) / CGFloat(maxWords) * 80 : 2
                            RoundedRectangle(cornerRadius: 3)
                                .fill(item.words > 0 ? theme.palette.accent : Color.secondary.opacity(0.2))
                                .frame(width: chartDays == 7 ? 30 : 8, height: max(2, height))
                            
                            // Label (only for 7-day view)
                            if chartDays == 7 {
                                Text(dayLabel(item.date))
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                
                // Summary
                HStack {
                    let totalPeriod = data.reduce(0) { $0 + $1.words }
                    let activeDays = data.filter { $0.words > 0 }.count
                    
                    Text("\(formatNumber(totalPeriod)) words")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    
                    Text("across \(activeDays) active days")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
    
    // MARK: - Milestones Card
    
    private var milestonesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("MILESTONES", systemImage: "flag.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Text("\(historyStore.totalMilestonesAchieved)/\(historyStore.totalMilestonesPossible)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.accent)
            }
            
            VStack(alignment: .leading, spacing: 10) {
                // Word milestones
                milestoneRow(
                    title: "Words",
                    milestones: historyStore.wordMilestones
                )
                
                // Transcription milestones
                milestoneRow(
                    title: "Transcriptions",
                    milestones: historyStore.transcriptionMilestones
                )
                
                // Streak milestones
                milestoneRow(
                    title: "Streak",
                    milestones: historyStore.streakMilestones
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
    
    private func milestoneRow(title: String, milestones: [(target: Int, achieved: Bool, label: String)]) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            
            ForEach(Array(milestones.enumerated()), id: \.offset) { _, milestone in
                HStack(spacing: 3) {
                    Image(systemName: milestone.achieved ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(milestone.achieved ? theme.palette.success : Color.secondary.opacity(0.4))
                    
                    Text(milestone.label)
                        .font(.system(size: 10, weight: milestone.achieved ? .semibold : .regular))
                        .foregroundStyle(milestone.achieved ? .primary : .secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(milestone.achieved ? theme.palette.success.opacity(0.1) : Color.clear)
                )
            }
            
            Spacer()
        }
    }
    
    // MARK: - Insights Card
    
    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("INSIGHTS", systemImage: "lightbulb.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                // Top Apps
                insightItem(
                    icon: "app.fill",
                    title: "Top Apps",
                    value: historyStore.topAppsFormatted(limit: 3).joined(separator: ", "),
                    fallback: "No data yet"
                )
                
                // AI Enhancement Rate
                insightItem(
                    icon: "sparkles",
                    title: "AI Enhanced",
                    value: "\(historyStore.aiEnhancementRate)%",
                    fallback: "0%"
                )
                
                // Peak Hours
                insightItem(
                    icon: "clock.fill",
                    title: "Peak Time",
                    value: historyStore.peakHourFormatted,
                    fallback: "N/A"
                )
                
                // Avg Length
                insightItem(
                    icon: "ruler.fill",
                    title: "Avg Length",
                    value: "\(historyStore.averageWordsPerTranscription) words",
                    fallback: "0 words"
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
    
    private func insightItem(icon: String, title: String, value: String, fallback: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                
                Text(value.isEmpty ? fallback : value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.3))
        )
    }
    
    // MARK: - Personal Records Card
    
    private var recordsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("PERSONAL RECORDS", systemImage: "trophy.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                recordItem(
                    title: "Longest Transcription",
                    value: "\(historyStore.longestTranscriptionWords) words"
                )
                
                recordItem(
                    title: "Most Words in a Day",
                    value: "\(formatNumber(historyStore.mostWordsInDay)) words"
                )
                
                recordItem(
                    title: "Most in a Day",
                    value: "\(historyStore.mostTranscriptionsInDay) transcriptions"
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
    
    private func recordItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.palette.accent.opacity(0.08))
        )
    }
    
    // MARK: - Reset Section
    
    private var resetSection: some View {
        HStack {
            Spacer()
            
            Button {
                showResetConfirmation = true
            } label: {
                Label("Reset All Stats", systemImage: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(historyStore.entries.isEmpty ? 0.3 : 0.7)
            .disabled(historyStore.entries.isEmpty)
            
            Spacer()
        }
        .padding(.top, 8)
        .alert("Reset All Stats", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset Everything", role: .destructive) {
                historyStore.clearAllHistory()
            }
        } message: {
            Text("This will permanently delete all \(historyStore.entries.count) transcriptions and reset all statistics. This action cannot be undone.")
        }
    }
    
    // MARK: - Helpers
    
    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
    
    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}

// MARK: - Stat Card Component

private struct StatCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

#Preview {
    StatsView()
        .frame(width: 600, height: 800)
        .environment(\.theme, AppTheme.dark)
}

