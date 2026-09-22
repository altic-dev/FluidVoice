import SwiftUI

struct StatsView: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared
    @ObservedObject private var statsStore = StatsSnapshotStore.shared
    @State private var statsOwner = UUID()
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    @State private var showResetConfirmation: Bool = false
    @State private var showShareSheet = false
    @State private var showWPMEditor: Bool = false
    @State private var editingWPM: String = ""
    private var stats: StatsSnapshot {
        (self.statsStore.snapshot ?? StatsSnapshot()).usingWeekdays(self.settings.weekendsDontBreakStreak)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if self.statsStore.snapshot == nil {
                ProgressView("Loading statistics…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                VStack(spacing: 16) {
                    HStack {
                        Spacer()
                        Button("Share my stats", systemImage: "square.and.arrow.up") { self.showShareSheet = true }
                            .fluidGlassAction()
                            .help("Make an image of your stats to post or send")
                    }

                    self.todayHeaderCard

                    StatsActivityView(snapshot: self.stats)

                    Divider()
                        .opacity(0.4)

                    HStack {
                        Text("All-time impact")
                            .font(self.theme.typography.sectionTitle)
                        Spacer()
                        Text("From your saved history")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                        self.timeSavedCard
                        self.totalWordsCard
                        self.streakCard
                        self.transcriptionsCard
                        self.fluidIntelligenceCard
                        self.keystrokesCard
                    }

                    StatsHighlightsView(snapshot: self.stats)

                    // Reset Button
                    self.resetSection
                }
                .padding(20)
            }
        }
        .background(self.theme.palette.accent.opacity(0.018))
        .sheet(isPresented: self.$showShareSheet) {
            StatsShareSheet(content: self.shareContent) { self.showShareSheet = false }
        }
        .onAppear { self.statsStore.activate(self.statsOwner) }
        .onDisappear { self.statsStore.deactivate(self.statsOwner) }
    }

    private var shareContent: StatsShareContent {
        StatsShareContent(
            totalWords: self.stats.totalWords,
            timeSaved: self.stats.formattedTimeSaved(typingWPM: self.settings.userTypingWPM),
            currentStreak: self.stats.currentStreak,
            totalTranscriptions: self.stats.totalTranscriptions,
            keystrokesSaved: self.stats.totalCharacters,
            aiPolishRate: self.stats.aiEnhancementRate,
            talkingWordsPerMinute: self.stats.talkingWordsPerMinute,
            biggestDayWords: self.stats.mostWordsInDay,
            longestDictationWords: self.stats.longestTranscriptionWords,
            activity: self.stats.dailyWordCounts(days: 30).map(\.words)
        )
    }

    // MARK: - Today Header

    private var todayHeaderCard: some View {
        let summary = self.historyStore.todaySummary
        return StatsTodayHero(
            words: summary.words,
            sessions: summary.transcriptions,
            savedMinutes: summary.timeSavedMinutes(typingWPM: self.settings.userTypingWPM),
            streak: self.stats.currentStreak,
            activity: self.stats.dailyWordCounts(days: 7)
        )
    }

    // MARK: - Time Saved Card

    private var timeSavedCard: some View {
        StatCard(title: "ESTIMATED TIME SAVED", icon: "clock.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.stats.formattedTimeSaved(typingWPM: self.settings.userTypingWPM))
                    .font(.fluidSystem(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Button {
                    self.editingWPM = "\(self.settings.userTypingWPM)"
                    self.showWPMEditor = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Based on \(self.settings.userTypingWPM) WPM typing")
                            .font(.fluidSystem(size: 11))
                        Image(systemName: "pencil")
                            .font(.fluidSystem(size: 9))
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
                .font(.fluidSystem(size: 13, weight: .semibold))

            HStack {
                TextField("WPM", text: self.$editingWPM)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)

                Text("words per minute")
                    .font(.fluidSystem(size: 12))
                    .foregroundStyle(.secondary)
            }

            Text("Average typing: 40 WPM\nProfessional: 65-75 WPM")
                .font(.fluidSystem(size: 10))
                .foregroundStyle(.tertiary)

            HStack {
                Button("Cancel") {
                    self.showWPMEditor = false
                }
                .fluidGlassAction()

                Button("Save") {
                    if let wpm = Int(editingWPM), wpm > 0 {
                        self.settings.userTypingWPM = wpm
                    }
                    self.showWPMEditor = false
                }
                .fluidGlassAction(prominent: true)
            }
        }
        .padding(16)
        .frame(width: 220)
    }

    // MARK: - Total Words Card

    private var totalWordsCard: some View {
        StatCard(title: "TOTAL WORDS", icon: "text.word.spacing") {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.formatNumber(self.stats.totalWords))
                    .font(.fluidSystem(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                let today = self.historyStore.wordsToday
                if today > 0 {
                    Text("+\(self.formatNumber(today)) today")
                        .font(.fluidSystem(size: 11))
                        .foregroundStyle(self.theme.palette.success)
                } else {
                    Text("Start dictating")
                        .font(.fluidSystem(size: 11))
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
                    Text("\(self.stats.currentStreak)")
                        .font(.fluidSystem(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(self.stats.currentStreak > 0 ? self.theme.palette.warning : .primary)

                    Text(self.stats.currentStreak == 1 ? "day" : "days")
                        .font(.fluidSystem(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text("Best: \(self.stats.bestStreak) days")
                    .font(.fluidSystem(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transcriptions Card

    private var fluidIntelligenceCard: some View {
        StatCard(title: "FLUID INTELLIGENCE", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.formatNumber(self.stats.fluidFixedWords))
                    .font(.fluidSystem(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(self.stats.fluidFixedWords == 0 ? "Words fixed by Smart mode show up here" : "words fixed for you by Smart mode")
                    .font(.fluidSystem(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keystrokesCard: some View {
        StatCard(title: "KEYSTROKES SAVED", icon: "keyboard") {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.formatNumber(self.stats.totalCharacters))
                    .font(.fluidSystem(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("keys you never had to press")
                    .font(.fluidSystem(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transcriptionsCard: some View {
        StatCard(title: "TRANSCRIPTIONS", icon: "doc.text.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(self.historyStore.entries.count)")
                    .font(.fluidSystem(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Avg: \(self.stats.averageWordsPerTranscription) words each")
                    .font(.fluidSystem(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        HStack {
            Spacer()

            Button {
                self.showResetConfirmation = true
            } label: {
                Label("Reset All Stats", systemImage: "trash")
                    .font(.fluidSystem(size: 12, weight: .medium))
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
        number.formatted(.number)
    }

    private func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated))
    }
}

// MARK: - Stat Card Component

private struct StatCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        ThemedCard(style: .standard, padding: 16, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 10) {
                Label(self.title, systemImage: self.icon)
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                self.content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    StatsView()
        .frame(width: 600, height: 800)
        .environment(\.theme, AppTheme.dark)
}
