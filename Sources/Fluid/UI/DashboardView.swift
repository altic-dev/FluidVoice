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
        return HStack(alignment: .top, spacing: 20) {
            self.stat("Today", value: today.words.formatted(), detail: "words dictated")
            Divider()
            self.stat("Time saved", value: today.words == 0 ? "0m" : today.formattedTimeSaved(typingWPM: self.settings.userTypingWPM), detail: "estimated today")
            Divider()
            self.stat("Streak", value: streak.map { "\($0) \($0 == 1 ? "day" : "days")" } ?? "—", detail: "keep it going")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 16)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Learning center").font(self.theme.typography.sectionTitle)
                Spacer()
                Button("Replay onboarding", systemImage: "arrow.counterclockwise", action: self.replayOnboarding)
                    .buttonStyle(.plain).font(self.theme.typography.caption)
                    .foregroundStyle(.secondary).disabled(self.busy)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    self.lesson("Voice model", icon: "waveform", complete: self.asr.modelsExistOnDisk || self.asr.isAsrReady, detail: "Choose your engine") { self.selectedSidebarItem = .voiceEngine }
                    self.lesson("Microphone", icon: "mic", complete: self.asr.micStatus == .authorized, detail: "Set up voice input") {
                        if self.asr.micStatus == .notDetermined { self.asr.requestMicAccess() } else { self.asr.openSystemSettingsForMic() }
                    }
                    self.lesson("Typing access", icon: "keyboard", complete: self.accessibilityEnabled, detail: "Dictate in any app", action: self.openAccessibilitySettings)
                    self.lesson("AI cleanup", icon: "sparkles", complete: DictationAIPostProcessingGate.isProviderConfigured(), detail: "Optional · polish text") { self.selectedSidebarItem = .aiEnhancements }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.visible)
        }
    }

    private func lesson(_ title: String, icon: String, complete: Bool, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: icon).font(.fluidSystem(size: 22, weight: .medium)).foregroundStyle(self.theme.palette.accent)
                    Spacer()
                    if complete {
                        Image(systemName: "checkmark.circle.fill").font(.fluidSystem(size: 12)).foregroundStyle(self.theme.palette.success)
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(self.theme.typography.bodySmallStrong)
                    Text(detail).font(self.theme.typography.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16).frame(width: 154, alignment: .leading)
            .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).disabled(self.busy)
        .accessibilityLabel("\(title), \(complete ? "configured" : detail)")
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
                Image(systemName: self.icon)
                    .font(.fluidSystem(size: 19, weight: .medium))
                    .foregroundStyle(self.tint)
                    .frame(width: 40, height: 44)
                    .background(self.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(self.title).font(self.theme.typography.bodySmallStrong)
                    Text(self.detail).font(self.theme.typography.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(self.tint.opacity(self.hovered ? 0.4 : 0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { self.hovered = $0 && self.isEnabled }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.15), value: self.hovered)
    }
}
