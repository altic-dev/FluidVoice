import AppKit
import AVFoundation
import SwiftUI

/// Home reuses the history and stats snapshots; no polling or duplicate aggregation.
struct DashboardView: View {
    @ObservedObject var asr: ASRService
    @Binding var selectedSidebarItem: SidebarItem?
    let accessibilityEnabled: Bool
    let openAccessibilitySettings: () -> Void
    let openShortcutSettings: () -> Void
    let replayOnboarding: () -> Void

    @ObservedObject private var history = TranscriptionHistoryStore.shared
    @ObservedObject private var stats = StatsSnapshotStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var contentState = NotchContentState.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var statsOwner = UUID()
    @State private var greeting = "Welcome back."
    @State private var statisticsHovered = false
    @FocusState private var statisticsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var busy: Bool { self.asr.isRunning || self.asr.isStarting || self.contentState.isProcessing }
    private var shortcut: String { self.settings.primaryDictationShortcutDisplayString }

    var body: some View {
        GeometryReader { geometry in
            Group {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        self.header
                        if geometry.size.width >= 900 {
                            HStack(alignment: .top, spacing: 28) {
                                self.mainColumn
                                    .frame(maxWidth: .infinity)
                                self.quickActions
                                    .frame(width: min(300, (geometry.size.width - 76) * 0.25))
                            }
                        } else {
                            self.mainColumn
                            self.quickActions
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 1440, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(self.theme.palette.contentBackground)
        .onAppear {
            self.stats.activate(self.statsOwner)
            let hour = Calendar.current.component(.hour, from: Date())
            let salutation = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
            let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
            self.greeting = name.isEmpty ? "\(salutation)." : "\(salutation), \(name)."
        }
        .onDisappear { self.stats.deactivate(self.statsOwner) }
    }

    private var header: some View {
        Text(self.greeting)
            .font(.fluidSystem(size: 34, weight: .regular, design: .serif))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 28) {
            self.statistics
            self.recents
            self.learningCenter
        }
    }

    private var statistics: some View {
        let today = self.history.todaySummary
        let streak = self.stats.snapshot?.usingWeekdays(self.settings.weekendsDontBreakStreak).currentStreak
        return Button { self.selectedSidebarItem = .stats } label: {
            HStack(alignment: .top, spacing: 20) {
                self.stat("Today", value: today.words.formatted(), detail: "words dictated")
                Divider()
                self.stat("Time saved", value: today.words == 0 ? "0m" : today.formattedTimeSaved(typingWPM: self.settings.userTypingWPM), detail: "estimated today")
                Divider()
                self.stat("Streak", value: streak.map { "\($0) \($0 == 1 ? "day" : "days")" } ?? "—", detail: "keep it going")
                // Quiet proof that Smart mode earns its keep; absent until it has fixed something.
                if let fixed = self.stats.snapshot?.fluidFixedWords, fixed > 0 {
                    Divider()
                    self.stat("Fluid Intelligence", value: fixed.formatted(), detail: "words fixed for you")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Text("View stats")
                    Image(systemName: "chevron.right").font(.fluidSystem(size: 9, weight: .semibold))
                }
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.accent)
                .opacity(self.statisticsHovered ? 1 : 0)
                .offset(x: self.statisticsHovered || self.reduceMotion ? 0 : -4)
            }
            // Keyboard focus reuses the hover border instead of the heavy system ring,
            // which otherwise lands on this card every time the dashboard opens.
            .dashboardTile(hovered: self.statisticsHovered || self.statisticsFocused, horizontalPadding: 20, verticalPadding: 18, cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .focused(self.$statisticsFocused)
        .focusEffectDisabled()
        .disabled(self.busy)
        .onHover { self.statisticsHovered = $0 && !self.busy }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.15), value: self.statisticsHovered)
        .help("Open your full stats")
        .accessibilityHint("Opens the Stats page")
    }

    private func stat(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(self.theme.typography.caption).foregroundStyle(.secondary)
            Text(value).font(.fluidSystem(size: 27, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(self.theme.typography.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent dictations").font(self.theme.typography.sectionTitle)
                Spacer()
                Button("View all") { self.selectedSidebarItem = .history }
                    .buttonStyle(.plain).foregroundStyle(self.theme.palette.accent)
                    .disabled(self.busy)
            }
            ThemedCard(style: .subtle, padding: 0) {
                if self.history.isLoading && self.history.entries.isEmpty {
                    ProgressView("Loading history…").frame(maxWidth: .infinity).padding(32)
                } else if self.history.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "text.bubble").font(.fluidSystem(size: 24)).foregroundStyle(self.theme.palette.accent)
                        Text("Your words start here").font(self.theme.typography.bodyStrong)
                        Text("Your recent dictations will appear here after you speak.")
                            .font(self.theme.typography.bodySmall).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(self.history.entries.prefix(4))) { entry in
                            DashboardRecentRow(entry: entry)
                            if entry.id != self.history.entries.prefix(4).last?.id {
                                Divider().opacity(0.4).padding(.horizontal, 18)
                            }
                        }
                    }
                }
            }
        }
    }

    private var learningCenter: some View {
        let lessons: [(title: String, icon: String, complete: Bool, detail: String, action: () -> Void)] = [
            ("Voice model", "waveform", self.asr.modelsExistOnDisk || self.asr.isAsrReady, "Pick your engine", { self.selectedSidebarItem = .voiceEngine }),
            ("Microphone", "mic", self.asr.micStatus == .authorized, "Set up voice input", {
                if self.asr.micStatus == .notDetermined { self.asr.requestMicAccess() } else { self.asr.openSystemSettingsForMic() }
            }),
            ("Typing access", "keyboard", self.accessibilityEnabled, "Dictate in any app", self.openAccessibilitySettings),
            ("AI cleanup", "sparkles", DictationAIPostProcessingGate.isProviderConfigured(), "Optional polish", { self.selectedSidebarItem = .aiEnhancements }),
        ]
        let completed = lessons.filter(\.complete).count

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Learning center").font(self.theme.typography.sectionTitle)
                Text("\(completed) of \(lessons.count) ready")
                    .font(self.theme.typography.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Replay onboarding", systemImage: "arrow.counterclockwise", action: self.replayOnboarding)
                    .buttonStyle(.plain).font(self.theme.typography.caption)
                    .foregroundStyle(.secondary).disabled(self.busy)
            }
            // Fills the row and wraps on narrow windows instead of leaving a gap or scrolling sideways.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(lessons, id: \.title) { lesson in
                    DashboardLessonCard(title: lesson.title, detail: lesson.detail, icon: lesson.icon, complete: lesson.complete, action: lesson.action)
                        .disabled(self.busy)
                }
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Quick actions").font(self.theme.typography.sectionTitle)
            if !self.shortcut.isEmpty {
                VStack(spacing: 18) {
                    Text("YOUR SHORTCUT")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                        .tracking(1.4).foregroundStyle(.secondary)
                    self.shortcutKey
                    if self.settings.primaryDictationShortcuts.count > 1 {
                        Text("+\(self.settings.primaryDictationShortcuts.count - 1) more")
                            .font(self.theme.typography.caption).foregroundStyle(.secondary)
                    }
                    Button(action: self.openShortcutSettings) {
                        HStack(spacing: 6) {
                            Text("Change shortcut")
                            Image(systemName: "arrow.up.right").font(.fluidSystem(size: 10, weight: .medium))
                        }
                        .font(self.theme.typography.captionStrong)
                    }
                    .buttonStyle(.plain).foregroundStyle(self.theme.palette.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24).padding(.horizontal, 14)
                .background {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(LinearGradient(colors: [self.theme.palette.accent.opacity(0.12), self.theme.palette.cardBackground], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(self.theme.palette.accent.opacity(0.13), lineWidth: 1))
                .disabled(self.busy)
            }
            DashboardQuickAction(title: "Add a word", detail: "Names, terms, your vocabulary", icon: "text.book.closed", tint: self.theme.palette.accent) {
                self.selectedSidebarItem = .customDictionary
            }
            .disabled(self.busy)
            DashboardQuickAction(title: "Cleanup styles", detail: "Shape how your words read", icon: "wand.and.stars", tint: self.theme.palette.accent) {
                self.selectedSidebarItem = .cleanupStyles
            }
            .disabled(self.busy)
            HStack(spacing: 12) {
                Image(systemName: "note.text").font(.fluidSystem(size: 20))
                    .frame(width: 36, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Notepad").font(self.theme.typography.bodySmallStrong)
                    Text("Coming soon").font(self.theme.typography.caption)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(self.theme.palette.cardBorder.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            .accessibilityElement(children: .combine)
        }
        .padding(20)
        .background(self.reduceTransparency ? self.theme.palette.cardBackground : self.theme.palette.accent.opacity(0.025), in: RoundedRectangle(cornerRadius: 24))
        .background {
            if !self.reduceTransparency {
                RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial)
            }
        }
    }

    @ViewBuilder
    private var shortcutKey: some View {
        let button = Button(action: self.openShortcutSettings) {
            Text(self.settings.primaryDictationShortcuts.first?.displayString ?? "Off")
                .font(.fluidSystem(size: 25, weight: .medium))
                .lineLimit(2).minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(width: 126, height: 92)
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .help("\(self.shortcut) — Change your dictation shortcuts")
        .accessibilityLabel("Dictation shortcuts: \(self.shortcut)")
        if #available(macOS 26, *), !self.reduceTransparency {
            button.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18))
        } else {
            button.background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(self.theme.palette.cardBorder, lineWidth: 1))
        }
    }
}

private struct DashboardRecentRow: View {
    let entry: TranscriptionHistoryEntry
    @Environment(\.theme) private var theme
    @State private var copied = false
    @State private var copyRevision = 0
    @State private var hovered = false

    var body: some View {
        Button {
            guard let text = self.entry.clipboardText else { return }
            ClipboardAudit.record("ui_copy_begin")
            NSPasteboard.general.clearContents()
            self.copied = NSPasteboard.general.setString(text, forType: .string)
            ClipboardAudit.record("ui_copy_end")
            self.copyRevision += 1
        } label: {
            HStack(spacing: 12) {
                HistoryAppIcon(appName: self.entry.appName)
                VStack(alignment: .leading, spacing: 5) {
                    Text(self.entry.previewText).font(self.theme.typography.bodySmall).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(self.entry.appName.isEmpty ? "Unknown app" : self.entry.appName)
                        Text("·")
                        Text(self.entry.timestamp, style: .date)
                    }
                    .font(self.theme.typography.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if self.copied {
                    Text("Copied").font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.accent)
                }
                Image(systemName: self.copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(self.copied ? self.theme.palette.accent : self.theme.palette.secondaryText)
            }
            .padding(18)
            .background(self.theme.palette.accent.opacity(self.hovered ? 0.06 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(self.entry.clipboardText == nil)
        .onHover { self.hovered = $0 && self.entry.clipboardText != nil }
        .help(self.copied ? "Copied" : "Click anywhere to copy dictation")
        .accessibilityLabel(self.copied ? "Copied dictation" : "Copy dictation")
        .accessibilityValue(self.entry.previewText)
        .task(id: self.copyRevision) {
            guard self.copyRevision > 0 else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            self.copied = false
        }
    }
}

private struct DashboardQuickAction: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 12) {
                DashboardIconTile(icon: self.icon, tint: self.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(self.title).font(self.theme.typography.bodySmallStrong)
                    Text(self.detail).font(self.theme.typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.fluidSystem(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(self.hovered ? 1 : 0)
                    .offset(x: self.hovered || self.reduceMotion ? 0 : -4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardTile(hovered: self.hovered)
        }
        .buttonStyle(.plain)
        .onHover { self.hovered = $0 && self.isEnabled }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.15), value: self.hovered)
    }
}

private struct DashboardLessonCard: View {
    let title: String
    let detail: String
    let icon: String
    let complete: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 12) {
                DashboardIconTile(icon: self.icon, tint: self.theme.palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(self.title).font(self.theme.typography.bodySmallStrong)
                    Text(self.detail).font(self.theme.typography.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }
                Spacer(minLength: 0)
                if self.complete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.fluidSystem(size: 13))
                        .foregroundStyle(self.theme.palette.success)
                } else {
                    Text("Set up")
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.theme.palette.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardTile(hovered: self.hovered)
        }
        .buttonStyle(.plain)
        .onHover { self.hovered = $0 && self.isEnabled }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.15), value: self.hovered)
        .accessibilityLabel("\(self.title), \(self.complete ? "configured" : self.detail)")
    }
}

private struct DashboardIconTile: View {
    let icon: String
    let tint: Color

    var body: some View {
        Image(systemName: self.icon)
            .font(.fluidSystem(size: 15, weight: .medium))
            .foregroundStyle(self.tint)
            .frame(width: 34, height: 34)
            .background(
                LinearGradient(colors: [self.tint.opacity(0.18), self.tint.opacity(0.07)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(self.tint.opacity(0.16), lineWidth: 1))
    }
}

private struct DashboardTileModifier: ViewModifier {
    let hovered: Bool
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
        content
            .padding(.horizontal, self.horizontalPadding)
            .padding(.vertical, self.verticalPadding)
            .background(self.theme.palette.cardBackground, in: shape)
            .overlay(shape.fill(Color.primary.opacity(self.hovered ? 0.04 : 0)))
            .overlay(shape.strokeBorder(self.theme.palette.cardBorder.opacity(self.hovered ? 0.9 : 0.45), lineWidth: 1))
            .contentShape(shape)
    }
}

private extension View {
    /// One surface for every small dashboard card so they hover and read as a set.
    func dashboardTile(
        hovered: Bool,
        horizontalPadding: CGFloat = 12,
        verticalPadding: CGFloat = 11,
        cornerRadius: CGFloat = 14
    ) -> some View {
        modifier(DashboardTileModifier(
            hovered: hovered,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            cornerRadius: cornerRadius
        ))
    }
}
