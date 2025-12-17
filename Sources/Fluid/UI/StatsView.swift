import SwiftUI

struct StatsView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    @State private var showResetConfirmation: Bool = false
    @State private var showWPMEditor: Bool = false
    @State private var editingWPM: String = ""
    @State private var chartDays: Int = 7 // Toggle between 7 and 30

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // Header row: Time Saved + Total Words
                HStack(spacing: 16) {
                    self.timeSavedCard
                    self.totalWordsCard
                }

                // Second row: Streak + Transcriptions
                HStack(spacing: 16) {
                    self.streakCard
                    self.transcriptionsCard
                }

                // Activity Chart
                self.activityChartCard

                // Milestones
                self.milestonesCard

                // Insights
                self.insightsCard

                // Personal Records
                self.recordsCard

                // Reset Button
                self.resetSection
            }
            .padding(20)
        }
    }

    // MARK: - Time Saved Card

    private var timeSavedCard: some View {
        StatCard(title: "TIME SAVED", icon: "clock.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.historyStore.formattedTimeSaved(typingWPM: self.settings.userTypingWPM))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Button {
                    self.editingWPM = "\(self.settings.userTypingWPM)"
                    self.showWPMEditor = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Based on \(self.settings.userTypingWPM) WPM typing")
                            .font(.system(size: 11))
                        Image(systemName: "pencil")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .popover(isPresented: self.$showWPMEditor) {
            self.wpmEditorPopover
        }
    }

    private var wpmEditorPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Typing Speed")
                .font(.system(size: 13, weight: .semibold))

            HStack {
                TextField("WPM", text: self.$editingWPM)
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
                    self.showWPMEditor = false
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    if let wpm = Int(editingWPM), wpm > 0 {
                        self.settings.userTypingWPM = wpm
                    }
                    self.showWPMEditor = false
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
                Text(self.formatNumber(self.historyStore.totalWords))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                let today = self.historyStore.wordsToday
                if today > 0 {
                    Text("+\(self.formatNumber(today)) today")
                        .font(.system(size: 11))
                        .foregroundStyle(self.theme.palette.success)
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
                    Text("\(self.historyStore.currentStreak)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(self.historyStore.currentStreak > 0 ? self.theme.palette.warning : .primary)

                    Text(self.historyStore.currentStreak == 1 ? "day" : "days")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text("Best: \(self.historyStore.bestStreak) days")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transcriptions Card

    private var transcriptionsCard: some View {
        StatCard(title: "TRANSCRIPTIONS", icon: "doc.text.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(self.historyStore.entries.count)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Avg: \(self.historyStore.averageWordsPerTranscription) words each")
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

                Picker("", selection: self.$chartDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            let data = self.historyStore.dailyWordCounts(days: self.chartDays)
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
                HStack(alignment: .bottom, spacing: self.chartDays == 7 ? 8 : 2) {
                    ForEach(Array(data.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: 4) {
                            // Bar (avoid division by zero)
                            let height = (item.words > 0 && maxWords > 0) ? CGFloat(item.words) / CGFloat(maxWords) *
                                80 : 2
                            RoundedRectangle(cornerRadius: 3)
                                .fill(item.words > 0 ? self.theme.palette.accent : Color.secondary.opacity(0.2))
                                .frame(width: self.chartDays == 7 ? 30 : 8, height: max(2, height))

                            // Label (only for 7-day view)
                            if self.chartDays == 7 {
                                Text(self.dayLabel(item.date))
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

                    Text("\(self.formatNumber(totalPeriod)) words")
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
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.08), lineWidth: 1)))
    }

    // MARK: - Milestones Card

    private var milestonesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("MILESTONES", systemImage: "flag.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(self.historyStore.totalMilestonesAchieved)/\(self.historyStore.totalMilestonesPossible)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(self.theme.palette.accent)
            }

            VStack(alignment: .leading, spacing: 10) {
                // Word milestones
                self.milestoneRow(
                    title: "Words",
                    milestones: self.historyStore.wordMilestones
                )

                // Transcription milestones
                self.milestoneRow(
                    title: "Transcriptions",
                    milestones: self.historyStore.transcriptionMilestones
                )

                // Streak milestones
                self.milestoneRow(
                    title: "Streak",
                    milestones: self.historyStore.streakMilestones
                )
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.08), lineWidth: 1)))
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
                        .foregroundStyle(milestone.achieved ? self.theme.palette.success : Color.secondary.opacity(0.4))

                    Text(milestone.label)
                        .font(.system(size: 10, weight: milestone.achieved ? .semibold : .regular))
                        .foregroundStyle(milestone.achieved ? .primary : .secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(milestone.achieved ? self.theme.palette.success.opacity(0.1) : Color.clear))
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
                GridItem(.flexible(), spacing: 12),
            ], spacing: 12) {
                // Top Apps
                self.insightItem(
                    icon: "app.fill",
                    title: "Top Apps",
                    value: self.historyStore.topAppsFormatted(limit: 3).joined(separator: ", "),
                    fallback: "No data yet"
                )

                // AI Enhancement Rate
                self.insightItem(
                    icon: "sparkles",
                    title: "AI Enhanced",
                    value: "\(self.historyStore.aiEnhancementRate)%",
                    fallback: "0%"
                )

                // Peak Hours
                self.insightItem(
                    icon: "clock.fill",
                    title: "Peak Time",
                    value: self.historyStore.peakHourFormatted,
                    fallback: "N/A"
                )

                // Avg Length
                self.insightItem(
                    icon: "ruler.fill",
                    title: "Avg Length",
                    value: "\(self.historyStore.averageWordsPerTranscription) words",
                    fallback: "0 words"
                )
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.08), lineWidth: 1)))
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
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary.opacity(0.3)))
    }

    // MARK: - Personal Records Card

    private var recordsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("PERSONAL RECORDS", systemImage: "trophy.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                self.recordItem(
                    title: "Longest Transcription",
                    value: "\(self.historyStore.longestTranscriptionWords) words"
                )

                self.recordItem(
                    title: "Most Words in a Day",
                    value: "\(self.formatNumber(self.historyStore.mostWordsInDay)) words"
                )

                self.recordItem(
                    title: "Most in a Day",
                    value: "\(self.historyStore.mostTranscriptionsInDay) transcriptions"
                )
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.08), lineWidth: 1)))
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
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(self.theme.palette.accent.opacity(0.08)))
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        HStack {
            Spacer()

            Button {
                self.showResetConfirmation = true
            } label: {
                Label("Reset All Stats", systemImage: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(self.historyStore.entries.isEmpty ? 0.3 : 0.7)
            .disabled(self.historyStore.entries.isEmpty)

            Spacer()
        }
        .padding(.top, 8)
        .alert("Reset All Stats", isPresented: self.$showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset Everything", role: .destructive) {
                self.historyStore.clearAllHistory()
            }
        } message: {
            Text("This will permanently delete all \(self.historyStore.entries.count) transcriptions and reset all statistics. This action cannot be undone.")
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
            Label(self.title, systemImage: self.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            self.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.08), lineWidth: 1)))
    }
}

#Preview {
    StatsView()
        .frame(width: 600, height: 800)
        .environment(\.theme, AppTheme.dark)
}
