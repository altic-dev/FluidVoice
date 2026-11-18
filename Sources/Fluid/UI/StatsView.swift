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
                VStack(spacing: self.theme.metrics.spacing.lg) {
                    self.todayHeaderCard

                    StatsActivityView(snapshot: self.stats)

                    FluidHairline()

                    VStack(spacing: 0) {
                        FluidGroupHeader(title: "All-time impact", hint: "From your saved history")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: self.theme.metrics.spacing.lg)], spacing: self.theme.metrics.spacing.lg) {
                            self.timeSavedCard
                            self.totalWordsCard
                            self.streakCard
                            self.transcriptionsCard
                            self.fluidIntelligenceCard
                            self.keystrokesCard
                        }
                    }

                    StatsHighlightsView(snapshot: self.stats)

                    // Reset Button
                    self.resetSection
                }
                .fluidPageContent(width: .overview)
            }
        }
        .fluidCanvas()
        .fluidPageActions {
            Button("Share my stats", systemImage: "square.and.arrow.up") { self.showShareSheet = true }
                .disabled(self.statsStore.snapshot == nil)
                .help("Make an image of your stats to post or send")
        }
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
        StatCard(title: "Estimated time saved") {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.stats.formattedTimeSaved(typingWPM: self.settings.userTypingWPM))
                    .fluidText(.metric)
                    .foregroundStyle(self.theme.look.text)

                Button {
                    self.editingWPM = "\(self.settings.userTypingWPM)"
                    self.showWPMEditor = true
                } label: {
                    Label("Based on \(self.settings.userTypingWPM) WPM typing", systemImage: "pencil")
                        .fluidText(.label)
                }
                .fluidGlassAction(quiet: true)
                .help("Change your typing speed")
            }
        }
        .popover(isPresented: self.$showWPMEditor) {
            self.wpmEditorPopover
        }
    }

    private var wpmEditorPopover: some View {
        let look = self.theme.look
        return VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text("Your Typing Speed")
                .fluidText(.rowTitle)
                .foregroundStyle(look.text)

            HStack {
                TextField("WPM", text: self.$editingWPM)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.center)

                Text("words per minute")
                    .fluidText(.label)
                    .foregroundStyle(look.secondaryText)
            }

            Text("Average typing: 40 WPM\nProfessional: 65-75 WPM")
                .fluidText(.label)
                .foregroundStyle(look.tertiaryText)

            HStack(spacing: self.theme.metrics.spacing.sm) {
                Button("Cancel") {
                    self.showWPMEditor = false
                }
                .fluidAction()

                Button("Save") {
                    if let wpm = Int(editingWPM), wpm > 0 {
                        self.settings.userTypingWPM = wpm
                    }
                    self.showWPMEditor = false
                }
                .fluidAction(.primary)
            }
        }
        .padding(self.theme.metrics.spacing.lg)
        .frame(width: 220)
    }

    // MARK: - Total Words Card

    private var totalWordsCard: some View {
        StatCard(title: "Total words") {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.formatNumber(self.stats.totalWords))
                    .fluidText(.metric)
                    .foregroundStyle(self.theme.look.text)

                let today = self.historyStore.wordsToday
                if today > 0 {
                    Text("+\(self.formatNumber(today)) today")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.secondaryText)
                } else {
                    Text("Start dictating")
                        .fluidText(.label)
                        .foregroundStyle(self.theme.look.secondaryText)
                }
            }
        }
    }

    // MARK: - Streak Card

    private var streakCard: some View {
        StatCard(title: "Current streak") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(self.stats.currentStreak)")
                        .fluidText(.metric)
                        .foregroundStyle(self.theme.look.text)

                    Text(self.stats.currentStreak == 1 ? "day" : "days")
                        .fluidText(.body)
                        .foregroundStyle(self.theme.look.secondaryText)
                }

                Text("Best: \(self.stats.bestStreak) days")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
        }
    }

    // MARK: - Transcriptions Card

    private var fluidIntelligenceCard: some View {
        StatCard(title: "Fluid Intelligence") {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.formatNumber(self.stats.fluidFixedWords))
                    .fluidText(.metric)
                    .foregroundStyle(self.theme.look.text)

                Text(self.stats.fluidFixedWords == 0 ? "Words fixed by Smart mode show up here" : "words fixed for you by Smart mode")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
        }
    }

    private var keystrokesCard: some View {
        StatCard(title: "Keystrokes saved") {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.formatNumber(self.stats.totalCharacters))
                    .fluidText(.metric)
                    .foregroundStyle(self.theme.look.text)

                Text("keys you never had to press")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
        }
    }

    private var transcriptionsCard: some View {
        StatCard(title: "Transcriptions") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(self.historyStore.entries.count)")
                    .fluidText(.metric)
                    .foregroundStyle(self.theme.look.text)

                Text("Avg: \(self.stats.averageWordsPerTranscription) words each")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
        }
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        HStack {
            Spacer()

            Button("Reset All Stats") {
                self.showResetConfirmation = true
            }
            .fluidGlassAction(quiet: true)
            .disabled(self.historyStore.entries.isEmpty)

            Spacer()
        }
        .padding(.top, self.theme.metrics.spacing.sm)
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

/// One all-time number: what it counts on top, the number and a short note under it.
private struct StatCard<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        FluidSurfaceCard(padding: self.theme.metrics.spacing.lg) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                Text(self.title)
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)

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
