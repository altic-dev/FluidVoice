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
    enum Requirement: CaseIterable { case voiceModel, microphone, typingAccess, screenCapture }
    let voiceModelReady: Bool
    let microphoneReady: Bool
    let typingAccessReady: Bool
    let screenCaptureReady: Bool

    var missing: [Requirement] {
        Requirement.allCases.filter {
            switch $0 {
            case .voiceModel: !self.voiceModelReady
            case .microphone: !self.microphoneReady
            case .typingAccess: !self.typingAccessReady
            case .screenCapture: !self.screenCaptureReady
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
    @StateObject private var recommendations: DashboardRecommendationsController
    @StateObject private var screenPermission = DictationScreenPermissionController()
    @State private var screenPermissionRequestTask: Task<Void, Never>?
    @State private var statsOwner = UUID()
    @State private var greeting = "Welcome back."
    @FocusState private var statisticsFocused: Bool

    init(
        asr: ASRService,
        selectedSidebarItem: Binding<SidebarItem?>,
        accessibilityEnabled: Bool,
        openAccessibilitySettings: @escaping () -> Void,
        openFluidIntelligenceDemo: @escaping () -> Void,
        openShortcutSettings: @escaping () -> Void,
        recommendations: DashboardRecommendationsController? = nil
    ) {
        self.asr = asr
        self._selectedSidebarItem = selectedSidebarItem
        self.accessibilityEnabled = accessibilityEnabled
        self.openAccessibilitySettings = openAccessibilitySettings
        self.openFluidIntelligenceDemo = openFluidIntelligenceDemo
        self.openShortcutSettings = openShortcutSettings
        self._recommendations = StateObject(wrappedValue: recommendations ?? DashboardRecommendationsController(asr: asr))
    }

    private var busy: Bool { self.asr.isRunning || self.asr.isStarting || self.contentState.isProcessing }
    private var shortcut: String { self.settings.primaryDictationShortcutDisplayString }
    private var supportsScreenContext: Bool { PrivateAIProviderFeature.shared.isAvailable && CPUArchitecture.isAppleSilicon }

    var body: some View {
        GeometryReader { geometry in
            let layout = DashboardLayout(width: geometry.size.width)
            Group {
                ScrollView {
                    VStack(alignment: .leading, spacing: DashboardLayout.gap) {
                        self.header
                        self.finishSetup(layout: layout)
                        if layout.hasActionColumn {
                            HStack(alignment: .top, spacing: DashboardLayout.gap) {
                                self.mainColumn(layout: layout)
                                    .frame(maxWidth: .infinity)
                                self.actionColumn(horizontal: false)
                                    .frame(width: DashboardLayout.actionWidth)
                            }
                        } else {
                            self.mainColumn(layout: layout)
                            self.actionColumn(horizontal: layout.hasHorizontalActions)
                        }
                    }
                    .padding(DashboardLayout.inset)
                    .frame(maxWidth: DashboardLayout.maximumWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .fluidCanvas()
        .onAppear {
            self.stats.activate(self.statsOwner)
            let hour = Calendar.current.component(.hour, from: Date())
            let salutation = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
            let name = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
            self.greeting = name.isEmpty ? "\(salutation)." : "\(salutation), \(name)."
        }
        .task { if self.supportsScreenContext { await self.screenPermission.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard self.supportsScreenContext else { return }
            Task { await self.screenPermission.refresh() }
        }
        .onChange(of: self.busy) { _, busy in
            if busy { self.screenPermissionRequestTask?.cancel() }
        }
        .onDisappear {
            self.recommendations.operation.cancel()
            self.stats.deactivate(self.statsOwner)
            self.screenPermissionRequestTask?.cancel()
        }
        .onChange(of: self.stats.snapshot?.hasFluidIntelligenceUse, initial: true) { _, hasUsed in
            if hasUsed == true { self.settings.recordFluidIntelligenceUse(output: "existing successful use") }
        }
    }

    private var header: some View {
        FluidPageHeader(title: self.greeting)
    }

    private func mainColumn(layout: DashboardLayout) -> some View {
        VStack(alignment: .leading, spacing: DashboardLayout.gap) {
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
        let spacing = self.theme.metrics.spacing
        return Button { self.selectedSidebarItem = .stats } label: {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing.xl, alignment: .leading), count: layout.statisticColumns(count: fixed > 0 ? 4 : 3)), alignment: .leading, spacing: spacing.xl) {
                self.stat("Today", value: today.words.formatted(), detail: "words dictated")
                self.stat("Time saved", value: today.words == 0 ? "0m" : today.formattedTimeSaved(typingWPM: self.settings.userTypingWPM), detail: "estimated today")
                self.stat("Streak", value: streak.map { "\($0) \($0 == 1 ? "day" : "days")" } ?? "—", detail: "keep it going")
                // Quiet proof that Smart mode earns its keep; absent until it has fixed something.
                if fixed > 0 {
                    self.stat("Fluid Intelligence", value: fixed.formatted(), detail: "words fixed for you")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        // Keyboard focus shows as the hover fill instead of the heavy system ring,
        // which otherwise lands on this card every time the dashboard opens.
        .fluidCardButton(padding: spacing.xl, isHighlighted: self.statisticsFocused)
        .focused(self.$statisticsFocused)
        .focusEffectDisabled()
        .disabled(self.busy)
        .help("Open your full stats")
        .accessibilityHint("Opens the Stats page")
    }

    private func stat(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Text(title).fluidText(.label).foregroundStyle(self.theme.look.secondaryText)
            Text(value).fluidText(.metric).foregroundStyle(self.theme.look.text).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).fluidText(.label).foregroundStyle(self.theme.look.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            FluidGroupHeader(title: "Recent dictations") {
                Button("View all") { self.selectedSidebarItem = .history }
                    .fluidGlassAction(quiet: true)
                    .disabled(self.busy)
            }
            FluidSettingsGroup {
                if self.history.isLoading && self.history.entries.isEmpty {
                    FluidSettingsBlock {
                        ProgressView("Loading history…").controlSize(.small).frame(maxWidth: .infinity)
                    }
                } else if self.history.entries.isEmpty {
                    FluidSettingsRow(title: "Your words start here", description: "Your recent dictations will appear here after you speak.")
                } else {
                    ForEach(Array(self.history.entries.prefix(4))) { entry in
                        DashboardRecentRow(entry: entry)
                    }
                }
            }
        }
    }

    private struct SetupItem {
        let title: String
        let icon: String
        let detail: String
        var actionTitle = "Set up"
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
        case .screenCapture:
            .init(
                title: "Screen Capture",
                icon: "display",
                detail: "Optional · Helps with Edit Mode and on-screen context.",
                actionTitle: self.screenPermission.requiresSettings ? "Open settings" : "Set up",
                action: self.requestScreenAccess
            )
        }
    }

    @ViewBuilder
    private func finishSetup(layout: DashboardLayout) -> some View {
        let missing = DashboardSetupStatus(
            voiceModelReady: self.asr.modelsExistOnDisk || self.asr.isAsrReady,
            microphoneReady: self.asr.micStatus == .authorized,
            typingAccessReady: self.accessibilityEnabled,
            screenCaptureReady: !self.supportsScreenContext || !self.screenPermission.hasChecked || self.screenPermission.isAllowed
        ).missing
        if !missing.isEmpty {
            let gap = self.theme.metrics.spacing.sm
            VStack(alignment: .leading, spacing: 0) {
                FluidGroupHeader(title: "Finish setup")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: layout.setupColumns(count: missing.count)), alignment: .leading, spacing: gap) {
                    ForEach(missing, id: \.self) { requirement in
                        let item = self.setupItem(for: requirement)
                        DashboardSetupCard(title: item.title, detail: item.detail, icon: item.icon, actionTitle: item.actionTitle, action: item.action)
                            .disabled(self.busy || (requirement == .screenCapture && self.screenPermission.isRequesting))
                    }
                }
            }
        }
    }

    private func requestScreenAccess() {
        guard !self.busy, self.screenPermissionRequestTask == nil else { return }
        if self.screenPermission.requiresSettings {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        self.screenPermissionRequestTask = Task {
            defer { self.screenPermissionRequestTask = nil }
            await self.screenPermission.requestIfNeeded { !self.busy && !Task.isCancelled }
        }
    }

    private func actionColumn(horizontal: Bool) -> some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            self.quickActions(horizontal: horizontal)
            DashboardRecommendationsView(asr: self.asr, controller: self.recommendations)
        }
    }

    private func quickActions(horizontal: Bool) -> some View {
        let spacing = self.theme.metrics.spacing
        let layout = horizontal
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 0))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        return FluidSettingsGroup(title: "Make it yours", separated: false) {
            layout {
                if !self.shortcut.isEmpty {
                    VStack(spacing: spacing.md) {
                        Text("Your shortcut")
                            .fluidText(.label)
                            .foregroundStyle(self.theme.look.tertiaryText)
                        self.shortcutKey
                        if self.settings.primaryDictationShortcuts.count > 1 {
                            Text("+\(self.settings.primaryDictationShortcuts.count - 1) more")
                                .fluidText(.label)
                                .foregroundStyle(self.theme.look.tertiaryText)
                        }
                        Button("Change shortcut", action: self.openShortcutSettings)
                            .fluidAction()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, spacing.xl)
                    .padding(.horizontal, FluidSettingsLayout.rowInset)
                    .disabled(self.busy)
                    .frame(width: horizontal ? 220 : nil)
                    FluidHairline(axis: horizontal ? .vertical : .horizontal)
                }
                VStack(alignment: .leading, spacing: 0) {
                    DashboardQuickAction(title: "Vocabulary", detail: "Names & terms", icon: "text.book.closed") {
                        self.selectedSidebarItem = .customDictionary
                    }
                    .disabled(self.busy)
                    FluidHairline().padding(.leading, FluidSettingsLayout.rowInset)
                    DashboardQuickAction(title: "Writing style", detail: "Make it sound like you", icon: "wand.and.stars") {
                        self.selectedSidebarItem = .cleanupStyles
                    }
                    .disabled(self.busy)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var intelligenceInvitation: some View {
        let spacing = self.theme.metrics.spacing
        return FluidSurfaceCard(padding: spacing.xl) {
            VStack(alignment: .leading, spacing: spacing.md) {
                HStack(alignment: .top, spacing: spacing.md) {
                    VStack(alignment: .leading, spacing: spacing.xs) {
                        Text("Try Fluid Intelligence")
                            .fluidText(.groupTitle)
                            .foregroundStyle(self.theme.look.text)
                        Text("Turn spoken thoughts into lists, emails, and polished paragraphs.")
                            .fluidText(.body)
                            .foregroundStyle(self.theme.look.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: spacing.md)
                    Button { self.settings.fluidIntelligenceInvitationDismissed = true } label: {
                        Image(systemName: "xmark")
                            .font(.fluidSystem(size: 12, weight: .semibold))
                    }
                    .fluidGlassAction(circular: true, quiet: true)
                    .accessibilityLabel("Dismiss Fluid Intelligence invitation")
                    .help("Hide this invitation. You can still try it from Help.")
                }
                Button("Try it", action: self.openFluidIntelligenceDemo)
                    .fluidAction(.primary)
                    .disabled(self.busy || DictationPromptTestCoordinator.shared.isActive)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The shortcut as a key. It opens the same shortcut settings as the button under it.
    private var shortcutKey: some View {
        Button(action: self.openShortcutSettings) {
            Text(self.settings.primaryDictationShortcuts.first?.displayString ?? "Off")
                .fluidText(.itemTitle)
                .foregroundStyle(self.theme.look.text)
                .lineLimit(2).minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .frame(width: 126, height: 64)
        }
        .fluidCardButton(padding: 0)
        .help("\(self.shortcut) — Change your dictation shortcuts")
        .accessibilityLabel("Dictation shortcuts: \(self.shortcut)")
    }
}

private struct DashboardRecentRow: View {
    let entry: TranscriptionHistoryEntry
    @Environment(\.theme) private var theme
    @State private var copied = false
    @State private var copyRevision = 0

    var body: some View {
        let look = self.theme.look
        let spacing = self.theme.metrics.spacing
        Button {
            guard let text = self.entry.clipboardText else { return }
            ClipboardAudit.record("ui_copy_begin")
            NSPasteboard.general.clearContents()
            self.copied = NSPasteboard.general.setString(text, forType: .string)
            ClipboardAudit.record("ui_copy_end")
            self.copyRevision += 1
        } label: {
            HStack(spacing: spacing.md) {
                HistoryAppIcon(appName: self.entry.appName)
                VStack(alignment: .leading, spacing: spacing.xs) {
                    Text(self.entry.previewText)
                        .fluidText(.body)
                        .foregroundStyle(look.text)
                        .lineLimit(2)
                    Text("\(self.entry.appName.isEmpty ? "Unknown app" : self.entry.appName) · \(self.entry.timestamp.formatted(date: .long, time: .omitted))")
                        .fluidText(.label)
                        .foregroundStyle(look.tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // A tick means "selected" in this look, so a copy says so in words.
                if self.copied {
                    Text("Copied")
                        .fluidText(.label)
                        .foregroundStyle(look.secondaryText)
                } else {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(look.tertiaryText)
                }
            }
            .padding(.horizontal, FluidSettingsLayout.rowInset)
            .padding(.vertical, FluidSettingsLayout.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .fluidSelectableRow(isSelected: false)
        .disabled(self.entry.clipboardText == nil)
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

/// A row that opens another page: what it is on the left, a chevron on the right.
private struct DashboardQuickAction: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let look = self.theme.look
        Button(action: self.action) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                FluidGlyphTile(systemImage: self.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.title).fluidText(.rowTitle).foregroundStyle(look.text).lineLimit(1)
                    Text(self.detail).fluidText(.label).foregroundStyle(look.tertiaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.fluidSystem(size: 10, weight: .semibold))
                    .foregroundStyle(look.tertiaryText)
            }
            .padding(.horizontal, FluidSettingsLayout.rowInset)
            .padding(.vertical, FluidSettingsLayout.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .fluidSelectableRow(isSelected: false)
    }
}

/// One thing left to set up. The whole card is the button; the pill names the action.
private struct DashboardSetupCard: View {
    let title: String
    let detail: String
    let icon: String
    var actionTitle = "Set up"
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let look = self.theme.look
        Button(action: self.action) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                FluidGlyphTile(systemImage: self.icon, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.title).fluidText(.rowTitle).foregroundStyle(look.text).lineLimit(1)
                    Text(self.detail).fluidText(.label).foregroundStyle(look.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                FluidActionLabel(title: self.actionTitle)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .fluidCardButton(padding: self.theme.metrics.spacing.md)
        .accessibilityLabel("\(self.title), \(self.detail)")
    }
}
