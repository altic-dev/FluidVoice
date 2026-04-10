//
//  SettingsView.swift
//  fluid
//
//  App preferences and audio device settings
//

import AppKit
import AVFoundation
import PromiseKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private struct ShortcutRowContent {
        let icon: String
        let iconColor: Color
        let title: String
        let description: String
    }

    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService {
        self.appServices.asr
    }

    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared
    @Binding var appear: Bool
    @Binding var visualizerNoiseThreshold: Double
    @Binding var selectedInputUID: String
    @Binding var selectedOutputUID: String
    @Binding var inputDevices: [AudioDevice.Device]
    @Binding var outputDevices: [AudioDevice.Device]
    @Binding var accessibilityEnabled: Bool
    @Binding var hotkeyShortcut: HotkeyShortcut
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    @Binding var promptModeShortcut: HotkeyShortcut
    @Binding var promptModeShortcutEnabled: Bool
    @Binding var commandModeShortcut: HotkeyShortcut
    @Binding var rewriteShortcut: HotkeyShortcut
    @Binding var cancelRecordingShortcut: HotkeyShortcut
    @Binding var commandModeShortcutEnabled: Bool
    @Binding var rewriteShortcutEnabled: Bool
    @Binding var hotkeyManagerInitialized: Bool
    @Binding var pressAndHoldModeEnabled: Bool
    @Binding var enableStreamingPreview: Bool
    @Binding var copyToClipboard: Bool

    // CRITICAL FIX: Cache default device names to avoid CoreAudio calls during view body evaluation.
    // Querying AudioDevice.getDefaultInputDevice() in the view body triggers HALSystem::InitializeShell()
    // which races with SwiftUI's AttributeGraph metadata processing and causes EXC_BAD_ACCESS crashes.
    @State private var cachedDefaultInputName: String = ""
    @State private var cachedDefaultOutputName: String = ""

    // Analytics consent UI state (default ON; user can opt-out)
    @State private var shareAnonymousAnalytics: Bool = SettingsStore.shared.shareAnonymousAnalytics
    @State private var showAnalyticsPrivacy: Bool = false
    @State private var pendingAnalyticsValue: Bool? = nil
    @State private var showAreYouSureToStopAnalytics: Bool = false
    @State private var rollbackVersion: String = ""
    @State private var isRollingBack: Bool = false

    let hotkeyManager: GlobalHotkeyManager?
    let menuBarManager: MenuBarManager
    let startRecording: () -> Void
    let refreshDevices: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let revealAppInFinder: () -> Void
    let openApplicationsFolder: () -> Void

    private var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    private func isRecording(_ target: ShortcutRecordingTarget) -> Bool {
        self.activeShortcutRecordingTarget == target
    }

    private var analyticsToggleBinding: Binding<Bool> {
        Binding(
            get: {
                self.pendingAnalyticsValue ?? self.shareAnonymousAnalytics
            },
            set: { newValue in
                // User is trying to turn OFF → ask first
                if self.shareAnonymousAnalytics == true, newValue == false {
                    self.pendingAnalyticsValue = false
                    self.showAreYouSureToStopAnalytics = true

                    return
                }

                // Normal ON path
                self.shareAnonymousAnalytics = newValue
                self.applyAnalyticsConsentChange(newValue)
            }
        )
    }

    private var analyticsConfirmationBinding: Binding<Bool> {
        Binding(
            get: { self.showAreYouSureToStopAnalytics },
            set: { newValue in
                // Only open modal if we have a pending value
                if newValue {
                    if self.pendingAnalyticsValue != nil {
                        self.showAreYouSureToStopAnalytics = true
                    }
                } else {
                    // Closing the modal: reset pending state
                    self.showAreYouSureToStopAnalytics = false
                    self.pendingAnalyticsValue = nil
                }
            }
        )
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var launchAtStartupBinding: Binding<Bool> {
        Binding(
            get: { self.settings.launchAtStartupEnabled },
            set: { self.settings.setLaunchAtStartup($0) }
        )
    }

    private func dictationPromptSelectionBinding(for slot: SettingsStore.DictationShortcutSlot) -> Binding<String> {
        Binding(
            get: {
                switch self.settings.dictationPromptSelection(for: slot) {
                case .off:
                    return "__OFF__"
                case .default:
                    return "__DEFAULT__"
                case let .profile(id):
                    return id
                }
            },
            set: { newValue in
                switch newValue {
                case "__OFF__":
                    self.settings.setDictationPromptSelection(.off, for: slot)
                case "__DEFAULT__":
                    self.settings.setDictationPromptSelection(.default, for: slot)
                default:
                    self.settings.setDictationPromptSelection(.profile(newValue), for: slot)
                }
            }
        )
    }

    @ViewBuilder
    private func dictationPromptPicker(for slot: SettingsStore.DictationShortcutSlot) -> some View {
        let profiles = self.settings.promptProfiles(for: .dictate)
        HStack {
            Text("AI Prompt")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 30)
            Spacer()
            Picker("", selection: self.dictationPromptSelectionBinding(for: slot)) {
                Text("Off").tag("__OFF__")
                Text("Default").tag("__DEFAULT__")
                ForEach(profiles) { profile in
                    Text(profile.name.isEmpty ? "Untitled" : profile.name).tag(profile.id)
                }
            }
            .frame(width: 190)
        }
        .padding(.bottom, 4)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // App Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        // Section header
                        Label("App Settings", systemImage: "power")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(spacing: 16) {
                            // Launch at startup
                            self.settingsToggleRow(
                                title: "Launch at startup",
                                description: "Automatically start MedVoice when you log in",
                                footnote: self.settings.launchAtStartupStatusMessage,
                                errorMessage: self.settings.launchAtStartupErrorMessage,
                                isOn: self.launchAtStartupBinding
                            )
                            Divider().opacity(0.2)

                            // Hide from Dock & App Switcher
                            self.settingsToggleRow(
                                title: "Hide from Dock & App Switcher",
                                description: "Keep MedVoice in the menu bar only (hides Dock icon and Cmd+Tab entry)",
                                footnote: "Note: May require app restart to take effect.",
                                isOn: Binding(
                                    get: { SettingsStore.shared.hideFromDockAndAppSwitcher },
                                    set: { SettingsStore.shared.hideFromDockAndAppSwitcher = $0 }
                                )
                            )
                            Divider().opacity(0.2)

                            // Accent Color
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Accent Color")
                                            .font(.body)
                                        Text("Pick a preset accent color for the app.")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    HStack(spacing: 10) {
                                        ForEach(SettingsStore.AccentColorOption.allCases) { option in
                                            let isSelected = self.settings.accentColorOption == option
                                            Button {
                                                self.settings.accentColorOption = option
                                            } label: {
                                                Circle()
                                                    .fill(Color(hex: option.hex) ?? .gray)
                                                    .frame(width: 16, height: 16)
                                                    .overlay(
                                                        Circle()
                                                            .stroke(
                                                                isSelected ? self.theme.palette.accent : self.theme.palette.cardBorder.opacity(0.5),
                                                                lineWidth: isSelected ? 2 : 1
                                                            )
                                                    )
                                                    .padding(4)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(option.rawValue)
                                            .help(option.rawValue)
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(self.theme.palette.contentBackground)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(self.theme.palette.cardBorder.opacity(0.4), lineWidth: 1)
                                            )
                                    )
                                }
                            }
                            Divider().opacity(0.2)

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Transcription Sounds")
                                        .font(.body)
                                    Text("Choose which sound plays when recording starts. Select None to disable.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Picker("", selection: Binding(
                                    get: { SettingsStore.shared.transcriptionStartSound },
                                    set: { newValue in
                                        SettingsStore.shared.transcriptionStartSound = newValue
                                        TranscriptionSoundPlayer.shared.playPreview(sound: newValue)
                                    }
                                )) {
                                    ForEach(SettingsStore.TranscriptionStartSound.allCases) { option in
                                        Text(option.displayName).tag(option)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 170, alignment: .trailing)
                            }

                            if SettingsStore.shared.transcriptionStartSound != .none {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Volume")
                                            .font(.body)
                                        Text("Adjust the notification sound volume.")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Slider(
                                        value: Binding(
                                            get: { Double(SettingsStore.shared.transcriptionSoundVolume) },
                                            set: { SettingsStore.shared.transcriptionSoundVolume = Float($0) }
                                        ),
                                        in: 0...1,
                                        step: 0.05
                                    ) { editing in
                                        if !editing {
                                            TranscriptionSoundPlayer.shared.playPreviewAtVolume(
                                                SettingsStore.shared.transcriptionSoundVolume
                                            )
                                        }
                                    }
                                    .frame(width: 150)
                                }

                                self.settingsToggleRow(
                                    title: "Independent Volume",
                                    description: "Sound volume stays constant regardless of system volume. Mute is still respected.",
                                    footnote: "Temporarily changes system volume during playback, which may briefly affect other audio.",
                                    isOn: Binding(
                                        get: { SettingsStore.shared.transcriptionSoundIndependentVolume },
                                        set: { SettingsStore.shared.transcriptionSoundIndependentVolume = $0 }
                                    )
                                )
                            }

                            Divider().opacity(0.2)

                            // Automatic Updates
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Automatic Updates")
                                            .font(.body)
                                        Text("Check for updates automatically once per hour")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Binding(
                                        get: { SettingsStore.shared.autoUpdateCheckEnabled },
                                        set: { SettingsStore.shared.autoUpdateCheckEnabled = $0 }
                                    ))
                                    .toggleStyle(.switch)
                                    .tint(self.theme.palette.accent)
                                    .labelsHidden()
                                }

                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Beta Releases")
                                            .font(.body)
                                        Text("Opt in to preview builds that may be unstable")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Toggle("", isOn: Binding(
                                        get: { SettingsStore.shared.betaReleasesEnabled },
                                        set: { SettingsStore.shared.betaReleasesEnabled = $0 }
                                    ))
                                    .toggleStyle(.switch)
                                    .tint(self.theme.palette.accent)
                                    .labelsHidden()
                                }

                                if SettingsStore.shared.betaReleasesEnabled {
                                    Text("Beta opt-in enabled. Update checks include both stable and beta builds.")
                                        .font(.caption)
                                        .foregroundStyle(self.theme.palette.warning)
                                }

                                if let lastCheck = SettingsStore.shared.lastUpdateCheckDate {
                                    Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }

                                Text("Current version: \(self.currentAppVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            // Update Buttons
                            HStack(spacing: 10) {
                                Button("Check for Updates") {
                                    Task { @MainActor in
                                        do {
                                            let includePrerelease = SettingsStore.shared.betaReleasesEnabled
                                            try await SimpleUpdater.shared.checkAndUpdate(
                                                owner: "altic-dev",
                                                repo: "Fluid-oss",
                                                includePrerelease: includePrerelease
                                            )
                                            let ok = NSAlert()
                                            ok.messageText = "Update Found!"
                                            ok.informativeText = "A new version is available and will be installed now."
                                            ok.alertStyle = .informational
                                            ok.addButton(withTitle: "OK")
                                            ok.runModal()
                                        } catch {
                                            let msg = NSAlert()
                                            if let pmkError = error as? PMKError, pmkError.isCancelled {
                                                let isBeta = SettingsStore.shared.betaReleasesEnabled
                                                msg.messageText = isBeta ? "You're Up To Date (Beta)" : "You're Up To Date"
                                                msg.informativeText = isBeta
                                                    ? "You're already running the latest build available in the beta channel."
                                                    : "You're already running the latest version of MedVoice."
                                            } else {
                                                msg.messageText = "Update Check Failed"
                                                msg.informativeText = "Unable to check for updates. Please try again later.\n\nError: \(error.localizedDescription)"
                                            }
                                            msg.alertStyle = .informational
                                            msg.runModal()
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(self.theme.palette.accent)
                                .controlSize(.regular)

                                Button("Release Notes") {
                                    if let url = URL(string: "https://github.com/altic-dev/Fluid-oss/releases") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)

                                Button(self.rollbackVersion.isEmpty ? "Rollback" : "Rollback to \(self.rollbackVersion)") {
                                    guard !self.isRollingBack else { return }

                                    let infoText = self.rollbackVersion.isEmpty ? "your previously installed version" : self.rollbackVersion
                                    let targetVersion = self.rollbackVersion
                                    let confirm = NSAlert()
                                    confirm.messageText = "Rollback to \(infoText)?"
                                    confirm.informativeText = "This will restore a previous app version and relaunch MedVoice."
                                    confirm.alertStyle = .warning
                                    confirm.addButton(withTitle: "Rollback")
                                    confirm.addButton(withTitle: "Cancel")

                                    guard confirm.runModal() == .alertFirstButtonReturn else { return }

                                    self.isRollingBack = true
                                    Task {
                                        defer {
                                            Task { @MainActor in
                                                self.isRollingBack = false
                                            }
                                        }

                                        do {
                                            try await SimpleUpdater.shared.rollbackToLatestBackup()
                                            await MainActor.run {
                                                let success = NSAlert()
                                                success.messageText = "Rollback Successful"
                                                success.informativeText = "Rolled back to \(targetVersion). MedVoice will relaunch shortly."
                                                success.alertStyle = .informational
                                                success.addButton(withTitle: "Report Bug")
                                                success.addButton(withTitle: "OK")
                                                let response = success.runModal()
                                                if response == .alertFirstButtonReturn {
                                                    self.openIssueReportingPage()
                                                }
                                            }
                                        } catch {
                                            await MainActor.run {
                                                let fail = NSAlert()
                                                fail.messageText = "Rollback Failed"
                                                fail.informativeText = error.localizedDescription
                                                fail.alertStyle = .critical
                                                fail.addButton(withTitle: "OK")
                                                fail.runModal()
                                                self.refreshRollbackState()
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(self.rollbackVersion.isEmpty || self.isRollingBack)
                                .opacity(self.isRollingBack ? 0.7 : 1.0)

                                Button("Get Previous Builds") {
                                    self.openPreviousBuildPicker()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                            }
                            .padding(.top, 12)

                            if self.rollbackVersion.isEmpty {
                                Text("No rollback backup found.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Rollback target: \(self.rollbackVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                }

                // Microphone Permission Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Microphone Permission", systemImage: "mic.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(self.asr.micStatus == .authorized ? self.theme.palette.success : self.theme.palette.warning)
                                    .frame(width: 8, height: 8)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        self.asr.micStatus == .authorized ? "Microphone access granted" :
                                            self.asr.micStatus == .denied ? "Microphone access denied" :
                                            "Microphone access not determined"
                                    )
                                    .font(.body)
                                    .foregroundStyle(self.asr.micStatus == .authorized ? .primary : self.theme.palette.warning)

                                    if self.asr.micStatus != .authorized {
                                        Text("Microphone access is required for voice recording")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()

                                if self.asr.micStatus == .notDetermined {
                                    Button {
                                        self.asr.requestMicAccess()
                                    } label: {
                                        Label("Grant Access", systemImage: "mic.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(self.theme.palette.accent)
                                    .controlSize(.regular)
                                } else if self.asr.micStatus == .denied {
                                    Button {
                                        self.asr.openSystemSettingsForMic()
                                    } label: {
                                        Label("Open Settings", systemImage: "gear")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.regular)
                                }
                            }

                            if self.asr.micStatus != .authorized {
                                self.instructionsBox(
                                    title: "How to enable microphone access:",
                                    steps: self.asr.micStatus == .notDetermined
                                        ? ["Click **Grant Access** above", "Choose **Allow** in the system dialog"]
                                        : ["Click **Open Settings** above", "Find **MedVoice** in the microphone list", "Toggle **MedVoice ON** to allow access"]
                                )
                            }
                        }
                    }
                    .padding(16)
                }

                // Global Hotkey Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 8) {
                            Label("Global Hotkey", systemImage: "keyboard")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Spacer()

                            if self.accessibilityEnabled {
                                if self.isRecordingAnyShortcut {
                                    Text("Recording…")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                } else if self.hotkeyManagerInitialized {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.fluidGreen)
                                            .font(.caption)
                                        Text("Active")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("Initializing…")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if self.accessibilityEnabled {
                            VStack(alignment: .leading, spacing: 12) {
                                if self.isRecordingAnyShortcut {
                                    HStack(spacing: 8) {
                                        Image(systemName: "hand.point.up.left.fill")
                                            .foregroundStyle(.orange)
                                        Text("Press your new hotkey combination now…")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                } else if !self.hotkeyManagerInitialized {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                            .fixedSize()
                                        Text("Hotkey initializing…")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                // MARK: - Shortcuts Section

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Keyboard Shortcuts")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)

                                    Text("Changes usually apply immediately. If a new shortcut does not respond, restart MedVoice.")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "mic.fill",
                                            iconColor: .secondary,
                                            title: "Primary Dictation Shortcut",
                                            description: "Defaults to raw transcription, but can use Off, Default, or any custom prompt."
                                        ),
                                        shortcut: self.hotkeyShortcut,
                                        isRecording: self.isRecording(.primaryDictation),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.primaryDictation) ? self.shortcutRecordingMessage : nil,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new transcribe shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .primaryDictation
                                        }
                                    )
                                    self.dictationPromptPicker(for: .primary)
                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "text.bubble.fill",
                                            iconColor: .secondary,
                                            title: "Secondary Dictation Shortcut",
                                            description: "Defaults to Default cleanup, but can use Off, Default, or any custom prompt."
                                        ),
                                        shortcut: self.promptModeShortcut,
                                        isRecording: self.isRecording(.secondaryDictation),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.secondaryDictation) ? self.shortcutRecordingMessage : nil,
                                        isEnabled: self.$promptModeShortcutEnabled,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new prompt mode shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .secondaryDictation
                                        }
                                    )

                                    if self.promptModeShortcutEnabled {
                                        self.dictationPromptPicker(for: .secondary)
                                    }

                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "terminal.fill",
                                            iconColor: .secondary,
                                            title: "Command Mode",
                                            description: "Execute voice commands"
                                        ),
                                        shortcut: self.commandModeShortcut,
                                        isRecording: self.isRecording(.command),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.command) ? self.shortcutRecordingMessage : nil,
                                        isEnabled: self.$commandModeShortcutEnabled,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new command mode shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .command
                                        }
                                    )
                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "pencil.and.outline",
                                            iconColor: .secondary,
                                            title: "Edit Mode",
                                            description: "Select text and speak how to edit, or generate new content"
                                        ),
                                        shortcut: self.rewriteShortcut,
                                        isRecording: self.isRecording(.edit),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.edit) ? self.shortcutRecordingMessage : nil,
                                        isEnabled: self.$rewriteShortcutEnabled,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new write mode shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .edit
                                        }
                                    )
                                    Divider().opacity(0.2).padding(.vertical, 4)

                                    self.shortcutRow(
                                        content: .init(
                                            icon: "xmark.circle.fill",
                                            iconColor: .secondary,
                                            title: "Cancel Recording",
                                            description: "Cancel the current recording or dismiss the active recording overlay"
                                        ),
                                        shortcut: self.cancelRecordingShortcut,
                                        isRecording: self.isRecording(.cancel),
                                        isAnyRecordingActive: self.isRecordingAnyShortcut,
                                        recordingMessage: self.isRecording(.cancel) ? self.shortcutRecordingMessage : nil,
                                        onChangePressed: {
                                            DebugLogger.shared.debug("Starting to record new cancel shortcut", source: "SettingsView")
                                            self.shortcutRecordingMessage = nil
                                            self.activeShortcutRecordingTarget = .cancel
                                        }
                                    )
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(self.theme.palette.elevatedCardBackground)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(self.theme.palette.cardBorder.opacity(0.45), lineWidth: 1)
                                        )
                                )

                                // MARK: - Options Section

                                VStack(spacing: 12) {
                                    self.optionToggleRow(
                                        title: "Press and Hold Mode",
                                        description: "The shortcut only records while you hold it down, giving you quick push-to-talk style control.",
                                        isOn: self.$pressAndHoldModeEnabled
                                    )
                                    .onChange(of: self.pressAndHoldModeEnabled) { _, newValue in
                                        SettingsStore.shared.pressAndHoldMode = newValue
                                        self.hotkeyManager?.enablePressAndHoldMode(newValue)
                                    }
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Show Live Preview",
                                        description: "Display transcription text in real-time in the overlay as you speak.",
                                        isOn: self.$enableStreamingPreview
                                    )
                                    .onChange(of: self.enableStreamingPreview) { _, newValue in
                                        SettingsStore.shared.enableStreamingPreview = newValue
                                    }
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Copy to Clipboard",
                                        description: "Automatically copy transcribed text to clipboard as a backup.",
                                        isOn: self.$copyToClipboard
                                    )
                                    .onChange(of: self.copyToClipboard) { _, newValue in
                                        SettingsStore.shared.copyTranscriptionToClipboard = newValue
                                    }
                                    Divider().opacity(0.2)

                                    HStack(alignment: .center) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Text Insertion Mode")
                                                .font(.body)
                                            Text(SettingsStore.shared.textInsertionMode.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()

                                        Picker("", selection: Binding(
                                            get: { SettingsStore.shared.textInsertionMode },
                                            set: { SettingsStore.shared.textInsertionMode = $0 }
                                        )) {
                                            ForEach(SettingsStore.TextInsertionMode.allCases) { mode in
                                                Text(mode.displayName).tag(mode)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .frame(width: 170, alignment: .trailing)
                                    }
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Save Transcription History",
                                        description: "Save transcriptions for stats tracking. Disable for privacy.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.saveTranscriptionHistory },
                                            set: { SettingsStore.shared.saveTranscriptionHistory = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Weekends Don't Break Streak",
                                        description: "Skip Saturday and Sunday when calculating usage streaks. Perfect for weekday-only users.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.weekendsDontBreakStreak },
                                            set: { SettingsStore.shared.weekendsDontBreakStreak = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "GAAV Mode",
                                        description: "Remove first letter capitalization and trailing period. Useful for search queries, form fields, or casual text.\nFeature requested by MaxGaav.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.gaavModeEnabled },
                                            set: { SettingsStore.shared.gaavModeEnabled = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Pause Media During Transcription",
                                        description: "Automatically pause currently playing audio/video when transcription starts. Resumes only if MedVoice paused it.",
                                        isOn: Binding(
                                            get: { SettingsStore.shared.pauseMediaDuringTranscription },
                                            set: { SettingsStore.shared.pauseMediaDuringTranscription = $0 }
                                        )
                                    )
                                    Divider().opacity(0.2)

                                    self.optionToggleRow(
                                        title: "Share Anonymous Analytics",
                                        description: "Send anonymous usage and performance metrics to help improve MedVoice. Never includes transcription text or prompts.",
                                        isOn: self.analyticsToggleBinding
                                    )

                                    HStack {
                                        Button("What we collect") {
                                            self.showAnalyticsPrivacy = true
                                        }
                                        .buttonStyle(.link)

                                        Spacer()
                                    }
                                    .padding(.top, 6)
                                }
                                .padding(12)
                            }
                        } else {
                            // Hotkey disabled - accessibility not enabled
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(self.theme.palette.warning)
                                        .frame(width: 8, height: 8)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(self.theme.palette.warning)
                                            Text("Accessibility permissions required")
                                                .font(.body)
                                                .foregroundStyle(self.theme.palette.warning)
                                        }
                                        Text("Required for global hotkey functionality")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()

                                    Button("Open Accessibility Settings") {
                                        self.openAccessibilitySettings()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(self.theme.palette.accent)
                                    .controlSize(.regular)
                                }

                                self.instructionsBox(
                                    title: "Follow these steps to enable Accessibility:",
                                    steps: [
                                        "Click **Open Accessibility Settings** above",
                                        "In the Accessibility window, click the **+ button**",
                                        "Navigate to Applications and select **MedVoice**",
                                        "Click **Open**, then toggle **MedVoice ON** in the list",
                                    ],
                                    warningStyle: true
                                )

                                HStack(spacing: 10) {
                                    Button("Reveal in Finder") {
                                        self.revealAppInFinder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button("Open Applications") {
                                        self.openApplicationsFolder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(16)
                }

                // Audio Devices Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("Audio Devices", systemImage: "speaker.wave.2.fill")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Spacer()

                            Button {
                                self.refreshDevices()
                                // Update cached default device names on refresh
                                self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""
                                self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        // Info note about device syncing
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                                .font(.body)
                            Text("Audio devices are synced with macOS System Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Input Device")
                                    .font(.body)
                                Spacer()
                                Picker("", selection: self.$selectedInputUID) {
                                    // Handle empty state gracefully
                                    if self.inputDevices.isEmpty {
                                        Text("Loading...").tag("")
                                    } else {
                                        ForEach(self.inputDevices, id: \.uid) { dev in
                                            // Add "(System Default)" tag using cached name to avoid CoreAudio calls during layout
                                            let isSystemDefault = !self.cachedDefaultInputName.isEmpty && dev.name == self.cachedDefaultInputName
                                            Text(isSystemDefault ? "\(dev.name) (System Default)" : dev.name).tag(dev.uid)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .disabled(self.asr.isRunning) // Disable device changes during recording
                                .onChange(of: self.selectedInputUID) { oldUID, newUID in
                                    guard !newUID.isEmpty else { return }

                                    // Prevent device changes during active recording
                                    if self.asr.isRunning {
                                        DebugLogger.shared.warning("Cannot change input device during recording", source: "SettingsView")
                                        // Revert to previous value
                                        self.selectedInputUID = oldUID
                                        return
                                    }

                                    SettingsStore.shared.preferredInputDeviceUID = newUID
                                    // Only change system default if sync is enabled
                                    if SettingsStore.shared.syncAudioDevicesWithSystem {
                                        _ = AudioDevice.setDefaultInputDevice(uid: newUID)
                                    }
                                }
                                // Sync selection when devices load or change
                                .onChange(of: self.inputDevices) { _, newDevices in
                                    // Update cached default device name when device list changes
                                    self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""

                                    // If selection is empty or not found in new list, select first available
                                    if !newDevices.isEmpty {
                                        let currentValid = newDevices.contains { $0.uid == self.selectedInputUID }
                                        if !currentValid {
                                            if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid,
                                               newDevices.contains(where: { $0.uid == defaultUID })
                                            {
                                                self.selectedInputUID = defaultUID
                                            } else {
                                                self.selectedInputUID = newDevices.first?.uid ?? ""
                                            }
                                        }
                                    }
                                }
                            }

                            HStack {
                                Text("Output Device")
                                    .font(.body)
                                Spacer()
                                Picker("", selection: self.$selectedOutputUID) {
                                    // Handle empty state gracefully
                                    if self.outputDevices.isEmpty {
                                        Text("Loading...").tag("")
                                    } else {
                                        ForEach(self.outputDevices, id: \.uid) { dev in
                                            // Add "(System Default)" tag using cached name to avoid CoreAudio calls during layout
                                            let isSystemDefault = !self.cachedDefaultOutputName.isEmpty && dev.name == self.cachedDefaultOutputName
                                            Text(isSystemDefault ? "\(dev.name) (System Default)" : dev.name).tag(dev.uid)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 240)
                                .disabled(self.asr.isRunning) // Disable device changes during recording
                                .onChange(of: self.selectedOutputUID) { oldUID, newUID in
                                    guard !newUID.isEmpty else { return }

                                    // Prevent device changes during active recording
                                    if self.asr.isRunning {
                                        DebugLogger.shared.warning("Cannot change output device during recording", source: "SettingsView")
                                        // Revert to previous value
                                        self.selectedOutputUID = oldUID
                                        return
                                    }

                                    SettingsStore.shared.preferredOutputDeviceUID = newUID
                                    // Only change system default if sync is enabled
                                    if SettingsStore.shared.syncAudioDevicesWithSystem {
                                        _ = AudioDevice.setDefaultOutputDevice(uid: newUID)
                                    }
                                }
                                // Sync selection when devices load or change
                                .onChange(of: self.outputDevices) { _, newDevices in
                                    // Update cached default device name when device list changes
                                    self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""

                                    if !newDevices.isEmpty {
                                        let currentValid = newDevices.contains { $0.uid == self.selectedOutputUID }
                                        if !currentValid {
                                            if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                                               newDevices.contains(where: { $0.uid == prefUID })
                                            {
                                                self.selectedOutputUID = prefUID
                                            } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                                                      newDevices.contains(where: { $0.uid == defaultUID })
                                            {
                                                self.selectedOutputUID = defaultUID
                                            } else {
                                                self.selectedOutputUID = newDevices.first?.uid ?? ""
                                            }
                                        }
                                    }
                                }
                            }

                            // CRITICAL FIX: Use cached values instead of querying CoreAudio in view body.
                            // Querying AudioDevice here triggers HALSystem::InitializeShell() race condition.
                            if !self.cachedDefaultInputName.isEmpty && !self.cachedDefaultOutputName.isEmpty {
                                HStack {
                                    Spacer()
                                    Text("Default: \(self.cachedDefaultInputName) / \(self.cachedDefaultOutputName)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }

                            // REMOVED: Sync mode toggle
                            // Independent mode doesn't work for aggregate devices (Bluetooth, etc.)
                            // due to CoreAudio limitation (OSStatus -10851)
                            // Always use sync mode for reliability across all device types
                        }
                    }
                    .padding(16)
                }

                // Overlay Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Overlay", systemImage: "waveform")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Sensitivity")
                                        .font(.body)
                                    Text("Control how sensitive the audio visualizer is to sound input")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Reset") {
                                    self.visualizerNoiseThreshold = 0.4
                                    SettingsStore.shared.visualizerNoiseThreshold = self.visualizerNoiseThreshold
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            HStack(spacing: 10) {
                                Text("More")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)

                                Slider(value: self.$visualizerNoiseThreshold, in: 0.01...0.8, step: 0.01)
                                    .controlSize(.regular)

                                Text("Less")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .leading)

                                Text(String(format: "%.2f", self.visualizerNoiseThreshold))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 36)
                            }

                            Divider().padding(.vertical, 8)

                            // Overlay Position
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Overlay Position")
                                        .font(.body)
                                    Text("Where the recording indicator appears on screen")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Picker("", selection: self.$settings.overlayPosition) {
                                    ForEach(SettingsStore.OverlayPosition.allCases, id: \.self) { position in
                                        Text(position.displayName).tag(position)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 170, alignment: .trailing)
                            }

                            Divider().padding(.vertical, 8)

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Transcription Preview Length")
                                            .font(.body)
                                        Text("How many recent characters appear in the notch/pill preview")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text("\(self.settings.transcriptionPreviewCharLimit) chars")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 10) {
                                    Text("Less")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, alignment: .trailing)

                                    Slider(
                                        value: Binding(
                                            get: { Double(self.settings.transcriptionPreviewCharLimit) },
                                            set: { self.settings.transcriptionPreviewCharLimit = Int($0.rounded()) }
                                        ),
                                        in: Double(SettingsStore.transcriptionPreviewCharLimitRange.lowerBound)...Double(SettingsStore.transcriptionPreviewCharLimitRange.upperBound),
                                        step: Double(SettingsStore.transcriptionPreviewCharLimitStep)
                                    )
                                    .controlSize(.regular)

                                    Text("More")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, alignment: .leading)
                                }
                            }

                            // Bottom overlay specific settings (only show when bottom is selected)
                            if self.settings.overlayPosition == .bottom {
                                Divider().padding(.vertical, 4)

                                // Overlay Size
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Overlay Size")
                                            .font(.body)
                                        Text("How large the recording indicator appears")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Picker("", selection: self.$settings.overlaySize) {
                                        ForEach(SettingsStore.OverlaySize.allCases, id: \.self) { size in
                                            Text(size.displayName).tag(size)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 170, alignment: .trailing)
                                }

                                // Bottom Offset
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Bottom Offset")
                                            .font(.body)
                                        Text("Distance from bottom of screen")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    HStack(spacing: 6) {
                                        Slider(value: self.$settings.overlayBottomOffset, in: 20...500)
                                            .frame(width: 110)
                                            .controlSize(.small)

                                        Text("\(Int(self.settings.overlayBottomOffset)) px")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .frame(width: 54, alignment: .trailing)
                                    }
                                    .frame(width: 170, alignment: .trailing)
                                }
                            }

                            if self.asr.isRunning {
                                Text("Settings are disabled during active recording")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .italic()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                        }
                    }
                    .padding(16)
                }

                // Backup & Restore Card
                ThemedCard(style: .standard) {
                    self.backupUtilityRow()
                        .padding(16)
                }

                // Debug Settings Card
                ThemedCard(style: .standard) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Debug Settings", systemImage: "ladybug.fill")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        VStack(alignment: .leading, spacing: 8) {
                            self.settingsToggleRow(
                                title: "Show Debug Logs in App",
                                description: "File logs are always collected for diagnostics.",
                                isOn: Binding(
                                    get: { SettingsStore.shared.enableDebugLogs },
                                    set: { SettingsStore.shared.enableDebugLogs = $0 }
                                )
                            )

                            Divider().padding(.vertical, 8)

                            Button {
                                let url = FileLogger.shared.currentLogFileURL()
                                if FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } else {
                                    DebugLogger.shared.info("Log file not found at \(url.path)", source: "SettingsView")
                                }
                            } label: {
                                Label("Reveal Log File", systemImage: "doc.richtext")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

                            Text("The debug log contains detailed information about app operations and can help with troubleshooting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Crash diagnostics are written to Library/Logs/Fluid/Fluid.log by default.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            #if DEBUG
                            Divider().padding(.vertical, 8)

                            Button(role: .destructive) {
                                self.settings.resetOnboardingProgress()
                                DebugLogger.shared.info("Developer action: onboarding reset", source: "SettingsView")
                            } label: {
                                Label("Reset Onboarding (Dev)", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)

                            Text("Developer-only action. Immediately re-enters first-run onboarding flow.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            #endif
                        }
                    }
                    .padding(16)
                }
            }
            .padding(16)
        }
        .sheet(isPresented: self.$showAnalyticsPrivacy) {
            AnalyticsPrivacyView()
                .frame(minWidth: 520, minHeight: 520)
                .appTheme(self.theme)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: self.analyticsConfirmationBinding) {
            AnalyticsConfirmationView(
                onConfirm: {
                    if let pending = pendingAnalyticsValue {
                        self.shareAnonymousAnalytics = pending
                        self.applyAnalyticsConsentChange(pending)
                    }
                    self.pendingAnalyticsValue = nil
                    self.showAreYouSureToStopAnalytics = false
                },
                onCancel: {
                    self.pendingAnalyticsValue = nil
                    self.showAreYouSureToStopAnalytics = false
                }
            )
        }
        .onAppear {
            Task { @MainActor in
                // Ensure the shared audio startup gate is scheduled. Safe to call repeatedly.
                await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
                await AudioStartupGate.shared.waitUntilOpen()

                self.refreshDevices()

                // Sync input device selection after refresh
                if !self.inputDevices.isEmpty {
                    let inputValid = self.inputDevices.contains { $0.uid == self.selectedInputUID }
                    if !inputValid || self.selectedInputUID.isEmpty {
                        if let defaultUID = AudioDevice.getDefaultInputDevice()?.uid,
                           self.inputDevices.contains(where: { $0.uid == defaultUID })
                        {
                            self.selectedInputUID = defaultUID
                        } else {
                            self.selectedInputUID = self.inputDevices.first?.uid ?? ""
                        }
                    }
                }

                // Sync output device selection after refresh
                if !self.outputDevices.isEmpty {
                    let outputValid = self.outputDevices.contains { $0.uid == self.selectedOutputUID }
                    if !outputValid || self.selectedOutputUID.isEmpty {
                        if let prefUID = SettingsStore.shared.preferredOutputDeviceUID,
                           self.outputDevices.contains(where: { $0.uid == prefUID })
                        {
                            self.selectedOutputUID = prefUID
                        } else if let defaultUID = AudioDevice.getDefaultOutputDevice()?.uid,
                                  self.outputDevices.contains(where: { $0.uid == defaultUID })
                        {
                            self.selectedOutputUID = defaultUID
                        } else {
                            self.selectedOutputUID = self.outputDevices.first?.uid ?? ""
                        }
                    }
                }

                // CRITICAL FIX: Populate cached default device names after onAppear, not during view body evaluation.
                // This avoids the CoreAudio/SwiftUI AttributeGraph race condition that causes EXC_BAD_ACCESS.
                self.cachedDefaultInputName = AudioDevice.getDefaultInputDevice()?.name ?? ""
                self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                self.refreshRollbackState()
                self.settings.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)
            }
        }
        .onChange(of: self.visualizerNoiseThreshold) { _, newValue in
            SettingsStore.shared.visualizerNoiseThreshold = newValue
        }
    }

    private func refreshRollbackState() {
        self.rollbackVersion = SimpleUpdater.shared.latestRollbackVersion() ?? ""
    }

    private func openIssueReportingPage() {
        guard let url = URL(string: "https://github.com/altic-dev/Fluid-oss/issues/new/choose") else { return }
        NSWorkspace.shared.open(url)
    }

    private func exportBackup() {
        do {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = BackupService.shared.suggestedFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let document = BackupService.shared.makeBackupDocument()
            let data = try BackupService.shared.encode(document)
            try data.write(to: url, options: .atomic)

            self.presentInfoAlert(
                title: "Backup Exported",
                message: "Saved your MedVoice backup to:\n\(url.path)"
            )
        } catch {
            self.presentErrorAlert(
                title: "Backup Export Failed",
                message: error.localizedDescription
            )
        }
    }

    private func importBackup() {
        do {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let data = try Data(contentsOf: url)
            let document = try BackupService.shared.decode(data)

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short

            let confirm = NSAlert()
            confirm.messageText = "Import this backup?"
            confirm.informativeText = """
            This replaces your current settings, prompt profiles, and stats history.

            Exported: \(formatter.string(from: document.exportedAt))
            API keys are not included and will not be changed.
            """
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Import")
            confirm.addButton(withTitle: "Cancel")

            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            try BackupService.shared.restore(document)
            self.syncLocalSettingsAfterBackupRestore()

            self.presentInfoAlert(
                title: "Backup Imported",
                message: "Your settings, prompt profiles, and stats were restored successfully."
            )
        } catch {
            self.presentErrorAlert(
                title: "Backup Import Failed",
                message: error.localizedDescription
            )
        }
    }

    private func syncLocalSettingsAfterBackupRestore() {
        self.shareAnonymousAnalytics = SettingsStore.shared.shareAnonymousAnalytics
        self.pendingAnalyticsValue = nil
        self.showAreYouSureToStopAnalytics = false
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openPreviousBuildPicker() {
        Task { @MainActor in
            do {
                let options = try await SimpleUpdater.shared.fetchRecentReleaseBuildOptions(
                    owner: "altic-dev",
                    repo: "Fluid-oss",
                    limit: 3,
                    includePrerelease: SettingsStore.shared.betaReleasesEnabled
                )
                self.presentPreviousBuildPicker(options)
            } catch {
                self.openAllReleasesPage()
            }
        }
    }

    private func presentPreviousBuildPicker(_ options: [SimpleUpdater.ReleaseBuildOption]) {
        guard !options.isEmpty else {
            self.openAllReleasesPage()
            return
        }

        let picker = NSAlert()
        picker.messageText = "Download Previous Build"
        picker.informativeText = "No local rollback backup was found. Choose a recent release build:"
        picker.alertStyle = .informational

        for option in options {
            picker.addButton(withTitle: option.version)
        }
        picker.addButton(withTitle: "All Releases")
        picker.addButton(withTitle: "Cancel")

        let response = picker.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let index = response.rawValue - first

        if index >= 0, index < options.count {
            NSWorkspace.shared.open(options[index].url)
            return
        }
        if index == options.count {
            self.openAllReleasesPage()
        }
    }

    private func openAllReleasesPage() {
        guard let url = URL(string: "https://github.com/altic-dev/Fluid-oss/releases") else { return }
        NSWorkspace.shared.open(url)
    }

    private func applyAnalyticsConsentChange(_ enabled: Bool) {
        SettingsStore.shared.shareAnonymousAnalytics = enabled
        AnalyticsService.shared.setEnabled(enabled)
        AnalyticsService.shared.capture(.analyticsConsentChanged, properties: ["enabled": enabled])
    }

    // MARK: - Helper Views

    private func settingsToggleRow(
        title: String,
        description: String,
        footnote: String? = nil,
        errorMessage: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .tint(self.theme.palette.accent)
                    .labelsHidden()
            }

            if let footnote = footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
        }
    }

    private func backupUtilityRow() -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text("Backup & Restore")
                    .font(.body)
                Text("Export or import settings, prompt profiles, history, and stats. API keys excluded.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                Button(action: self.exportBackup) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(self.theme.palette.accent)
                .controlSize(.regular)

                Button(action: self.importBackup) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }

    private func optionToggleRow(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(self.theme.palette.accent)
                .labelsHidden()
        }
    }

    private func instructionsBox(
        title: String,
        steps: [String],
        warningStyle: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(warningStyle ? self.theme.palette.warning : self.theme.palette.accent)
                    .font(.caption)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption)
                            .foregroundStyle(warningStyle ? self.theme.palette.warning : self.theme.palette.accent)
                            .fontWeight(.semibold)
                            .frame(width: 16, alignment: .trailing)
                        Text(.init(step))
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((warningStyle ? self.theme.palette.warning : self.theme.palette.accent).opacity(0.12))
        )
    }

    @ViewBuilder
    private func shortcutRow(
        content: ShortcutRowContent,
        shortcut: HotkeyShortcut,
        isRecording: Bool,
        isAnyRecordingActive: Bool,
        recordingMessage: String? = nil,
        isEnabled: Binding<Bool>? = nil,
        onChangePressed: @escaping () -> Void
    ) -> some View {
        let enabledValue = isEnabled?.wrappedValue ?? true

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: content.icon)
                    .foregroundStyle(content.iconColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title)
                        .font(.body)
                    Text(content.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let isEnabled {
                    Toggle("", isOn: isEnabled)
                        .toggleStyle(.switch)
                        .tint(self.theme.palette.accent)
                        .labelsHidden()
                }
            }

            HStack(spacing: 10) {
                Color.clear
                    .frame(width: 20)

                if isRecording && enabledValue {
                    Text("Press shortcut...")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.orange.opacity(0.2))
                        )
                } else {
                    Text(shortcut.displayString)
                        .font(.caption.monospaced().weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(.quaternary.opacity(0.5))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .stroke(.primary.opacity(0.15), lineWidth: 1)
                                )
                        )
                }

                Button("Change") {
                    onChangePressed()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isAnyRecordingActive || !enabledValue)

                if isRecording, let recordingMessage, !recordingMessage.isEmpty {
                    Text(recordingMessage)
                        .font(.caption)
                        .foregroundStyle(self.theme.palette.warning)
                }
            }
        }
        .opacity(enabledValue ? 1 : 0.7)
    }
}

// MARK: - Filler Words Editor

struct FillerWordsEditor: View {
    @State private var fillerWords: [String] = SettingsStore.shared.fillerWords
    @State private var newWord: String = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filler words to remove:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Word chips
            FlowLayout(spacing: 6) {
                ForEach(self.fillerWords, id: \.self) { word in
                    HStack(spacing: 4) {
                        Text(word)
                            .font(.caption)
                        Button {
                            self.removeWord(word)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quaternary)
                    )
                }
            }

            // Add new word
            HStack(spacing: 8) {
                TextField("Add word", text: self.$newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onSubmit { self.addWord() }

                Button("Add") { self.addWord() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(self.newWord.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()

                Button("Reset") {
                    self.fillerWords = SettingsStore.defaultFillerWords
                    SettingsStore.shared.fillerWords = self.fillerWords
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func addWord() {
        let word = self.newWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !self.fillerWords.contains(word) else { return }
        self.fillerWords.append(word)
        SettingsStore.shared.fillerWords = self.fillerWords
        self.newWord = ""
    }

    private func removeWord(_ word: String) {
        self.fillerWords.removeAll { $0 == word }
        SettingsStore.shared.fillerWords = self.fillerWords
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    struct Cache {
        var sizes: [CGSize] = []
        var positions: [CGPoint] = []
        var containerSize: CGSize = .zero
        var lastWidth: CGFloat = 0
    }

    var spacing: CGFloat = 8

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: Array(repeating: .zero, count: subviews.count))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        self.arrangeSubviews(proposal: proposal, subviews: subviews, cache: &cache)
        return cache.containerSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        self.arrangeSubviews(proposal: proposal, subviews: subviews, cache: &cache)
        for (index, position) in cache.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let proposedWidth = proposal.width ?? 0
        let maxWidth = proposedWidth > 0 ? proposedWidth : 260
        let needsLayout = cache.positions.count != subviews.count || cache.lastWidth != maxWidth

        if needsLayout {
            cache.positions = []
            cache.positions.reserveCapacity(subviews.count)
            cache.sizes = Array(repeating: .zero, count: subviews.count)
        }

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let size: CGSize
            if needsLayout {
                size = subviews[index].sizeThatFits(.unspecified)
                cache.sizes[index] = size
            } else {
                size = cache.sizes[index]
            }

            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + self.spacing
                rowHeight = 0
            }
            if needsLayout {
                cache.positions.append(CGPoint(x: x, y: y))
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + self.spacing
        }

        cache.containerSize = CGSize(width: maxWidth, height: y + rowHeight)
        cache.lastWidth = maxWidth
    }
}

// MARK: - Analytics modal confirmation

struct AnalyticsConfirmationView: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.theme) private var theme

    private var contactInfoText: AttributedString {
        var text = AttributedString(
            "If you have any concerns we would love to hear about it, please email alticdev@gmail.com or file an issue in our GitHub."
        )

        if let emailRange = text.range(of: "alticdev@gmail.com") {
            text[emailRange].link = URL(string: "mailto:alticdev@gmail.com")
            text[emailRange].foregroundColor = self.theme.palette.accent
        }

        if let githubRange = text.range(of: "GitHub") {
            text[githubRange].link = URL(string: "https://github.com/JonGerrand/MedVoice")
            text[githubRange].foregroundColor = self.theme.palette.accent
        }

        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Are you sure you want to stop sharing anonymous analytics?")
                .font(.headline)

            Text("By sharing anonymous usage data, you help us build the features you care about most. We never collect personal information (Audio, Transcription text etc), ever. Your support simply helps us make MedVoice better for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.theme.palette.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)
                )

            Text(self.contactInfoText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Divider()

            HStack {
                Spacer()

                Button("Cancel") {
                    self.onCancel()
                }

                Button("Yes") {
                    self.onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
