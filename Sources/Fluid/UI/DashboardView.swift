import AppKit
import AVFoundation
import SwiftUI

/// Uses available detail width, not window width (the sidebar can resize independently).
struct DashboardLayout {
    static let inset = FluidPageLayout.inset
    static let gap: CGFloat = 28
    static let maximumWidth: CGFloat = 1440
    static let actionWidth: CGFloat = 300
    let contentWidth: CGFloat

    init(width: CGFloat) {
        self.contentWidth = max(0, min(width, Self.maximumWidth) - Self.inset * 2)
    }

    var hasActionColumn: Bool { self.contentWidth >= 640 + Self.gap + Self.actionWidth }
    var mainWidth: CGFloat { self.hasActionColumn ? self.contentWidth - Self.gap - Self.actionWidth : self.contentWidth }
    var hasHorizontalActions: Bool { !self.hasActionColumn && self.contentWidth >= 620 }
    func setupColumns(count: Int) -> Int {
        guard count > 0 else { return 1 }
        return self.contentWidth >= CGFloat(count) * 280 + CGFloat(count - 1) * 10 ? count : 1
    }

    func statisticColumns(count: Int) -> Int {
        if self.mainWidth >= CGFloat(count) * 160 + 40 { return count }
        return count == 4 && self.mainWidth >= 360 ? 2 : 1
    }
}

struct DashboardSetupStatus {
    enum Requirement: CaseIterable { case voiceModel, microphone, typingAccess }
    let voiceModelReady: Bool
    let microphoneReady: Bool
    let typingAccessReady: Bool

    var missing: [Requirement] {
        Requirement.allCases.filter {
            switch $0 {
            case .voiceModel: !self.voiceModelReady
            case .microphone: !self.microphoneReady
            case .typingAccess: !self.typingAccessReady
            }
        }
    }
}

/// Home reuses the history and stats snapshots; no polling or duplicate aggregation.
struct DashboardView: View {
    @ObservedObject var asr: ASRService
    @Binding var selectedSidebarItem: SidebarItem?
    let accessibilityEnabled: Bool
    let openAccessibilitySettings: () -> Void
    let openFluidIntelligenceDemo: () -> Void
    let openShortcutSettings: () -> Void

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
            let layout = DashboardLayout(width: geometry.size.width)
            Group {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        self.header
                        self.finishSetup(layout: layout)
                        if layout.hasActionColumn {
                            HStack(alignment: .top, spacing: 28) {
                                self.mainColumn(layout: layout)
                                    .frame(maxWidth: .infinity)
                                self.quickActions(horizontal: false)
                                    .frame(width: DashboardLayout.actionWidth)
                            }
                        } else {
                            self.mainColumn(layout: layout)
                            self.quickActions(horizontal: layout.hasHorizontalActions)
                        }
                    }
                    .padding(DashboardLayout.inset)
                    .frame(maxWidth: DashboardLayout.maximumWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .onChange(of: self.stats.snapshot?.hasFluidIntelligenceUse, initial: true) { _, hasUsed in
            if hasUsed == true { self.settings.recordFluidIntelligenceUse(output: "existing successful use") }
        }
    }

    private var header: some View {
        Text(self.greeting)
            .font(.fluidSystem(size: 34, weight: .regular, design: .serif))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func mainColumn(layout: DashboardLayout) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            self.statistics(layout: layout)
            if self.stats.snapshot != nil, FluidIntelligenceInvitation.shouldShow(
                available: PrivateAIProviderFeature.shared.isAvailable,
                dismissed: self.settings.fluidIntelligenceInvitationDismissed,
                hasUsed: self.settings.hasUsedFluidIntelligence || self.stats.snapshot?.hasFluidIntelligenceUse == true
            ) {
                self.intelligenceInvitation
            }
            self.recents
        }
    }

    private func statistics(layout: DashboardLayout) -> some View {
        let today = self.history.todaySummary
        let streak = self.stats.snapshot?.usingWeekdays(self.settings.weekendsDontBreakStreak).currentStreak
        let fixed = self.stats.snapshot?.fluidFixedWords ?? 0
        return Button { self.selectedSidebarItem = .stats } label: {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .leading), count: layout.statisticColumns(count: fixed > 0 ? 4 : 3)), alignment: .leading, spacing: 20) {
                self.stat("Today", value: today.words.formatted(), detail: "words dictated")
                self.stat("Time saved", value: today.words == 0 ? "0m" : today.formattedTimeSaved(typingWPM: self.settings.userTypingWPM), detail: "estimated today")
                self.stat("Streak", value: streak.map { "\($0) \($0 == 1 ? "day" : "days")" } ?? "—", detail: "keep it going")
                // Quiet proof that Smart mode earns its keep; absent until it has fixed something.
                if fixed > 0 {
                    self.stat("Fluid Intelligence", value: fixed.formatted(), detail: "words fixed for you")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
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

    private struct SetupItem {
        let title: String
        let icon: String
        let detail: String
        let action: () -> Void
    }

    private func setupItem(for requirement: DashboardSetupStatus.Requirement) -> SetupItem {
        switch requirement {
        case .voiceModel:
            .init(title: "Voice model", icon: "waveform", detail: "Pick your engine", action: { self.selectedSidebarItem = .voiceEngine })
        case .microphone:
            .init(title: "Microphone", icon: "mic", detail: "Set up voice input", action: {
                if self.asr.micStatus == .notDetermined { self.asr.requestMicAccess() } else { self.asr.openSystemSettingsForMic() }
            })
        case .typingAccess:
            .init(title: "Typing access", icon: "keyboard", detail: "Dictate in any app", action: self.openAccessibilitySettings)
        }
    }

    @ViewBuilder
    private func finishSetup(layout: DashboardLayout) -> some View {
        let missing = DashboardSetupStatus(
            voiceModelReady: self.asr.modelsExistOnDisk || self.asr.isAsrReady,
            microphoneReady: self.asr.micStatus == .authorized,
            typingAccessReady: self.accessibilityEnabled
        ).missing
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Finish setup").font(self.theme.typography.sectionTitle)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: layout.setupColumns(count: missing.count)), alignment: .leading, spacing: 10) {
                    ForEach(missing, id: \.self) { requirement in
                        let item = self.setupItem(for: requirement)
                        DashboardSetupCard(title: item.title, detail: item.detail, icon: item.icon, action: item.action)
                            .disabled(self.busy)
                    }
                }
            }
        }
    }

    private func quickActions(horizontal: Bool) -> some View {
        let layout = horizontal
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
        return VStack(alignment: .leading, spacing: 18) {
            Text("Make it yours").font(self.theme.typography.sectionTitle)
            FluidGlassControlGroup {
                layout {
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
                            .fluidGlassAction()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16).padding(.horizontal, 14)
                        .disabled(self.busy)
                        .frame(width: horizontal ? 220 : nil)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        DashboardQuickAction(title: "Vocabulary", detail: "Names & terms", icon: "text.book.closed") {
                            self.selectedSidebarItem = .customDictionary
                        }
                        .disabled(self.busy)
                        Divider().padding(.leading, 46).padding(.trailing, 12)
                        DashboardQuickAction(title: "Writing style", detail: "Make it sound like you", icon: "wand.and.stars") {
                            self.selectedSidebarItem = .cleanupStyles
                        }
                        .disabled(self.busy)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(20)
        .background(self.reduceTransparency ? self.theme.palette.cardBackground : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 24))
        .background {
            if !self.reduceTransparency {
                RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial)
            }
        }
    }

    private var intelligenceInvitation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Try Fluid Intelligence", systemImage: "sparkles")
                        .font(self.theme.typography.sectionTitle)
                    Text("Turn spoken thoughts into lists, emails, and polished paragraphs.")
                        .font(self.theme.typography.bodySmall).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button { self.settings.fluidIntelligenceInvitationDismissed = true } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Fluid Intelligence invitation")
                .help("Hide this invitation. You can still try it from Help.")
            }
            Button("Try it", systemImage: "arrow.up.right", action: self.openFluidIntelligenceDemo)
                .fluidGlassAction(prominent: true)
                .disabled(self.busy || DictationPromptTestCoordinator.shared.isActive)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(self.theme.palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(self.theme.palette.accent.opacity(0.18)))
    }

    @ViewBuilder
    private var shortcutKey: some View {
        let button = Button(action: self.openShortcutSettings) {
            Text(self.settings.primaryDictationShortcuts.first?.displayString ?? "Off")
                .font(.fluidSystem(size: 25, weight: .medium))
                .lineLimit(2).minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(width: 126, height: 64)
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
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 12) {
                Image(systemName: self.icon)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(self.title).font(self.theme.typography.bodySmallStrong).lineLimit(1)
                    Text(self.detail).font(self.theme.typography.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.fluidSystem(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .background(Color.primary.opacity(self.hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { self.hovered = $0 && self.isEnabled }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.15), value: self.hovered)
    }
}

private struct DashboardSetupCard: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 12) {
                FluidIconTile(icon: self.icon, tint: self.theme.palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(self.title).font(self.theme.typography.bodySmallStrong).lineLimit(1)
                    Text(self.detail).font(self.theme.typography.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Set up")
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.accent)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardTile(hovered: self.hovered)
        }
        .buttonStyle(.plain)
        .onHover { self.hovered = $0 && self.isEnabled }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.15), value: self.hovered)
        .accessibilityLabel("\(self.title), \(self.detail)")
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
