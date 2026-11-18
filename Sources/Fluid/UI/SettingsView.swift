//
//  SettingsView.swift
//  fluid
//
//  App preferences and audio device settings
//

import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService {
        self.appServices.asr
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var updater = SimpleUpdater.shared
    let selectedSection: SettingsSection
    let searchResults: [SettingsSearchResult]
    let searchScrollRequest: Int
    @ObservedObject var microphonePreferenceCoordinator: MicrophonePreferenceCoordinator
    @Binding var appear: Bool
    @Binding var visualizerNoiseThreshold: Double
    @Binding var selectedInputUID: String
    @Binding var selectedOutputUID: String
    @Binding var inputDevices: [AudioDevice.Device]
    @Binding var outputDevices: [AudioDevice.Device]
    @Binding var accessibilityEnabled: Bool
    @Binding var primaryDictationShortcuts: [HotkeyShortcut]
    @Binding var activeShortcutRecordingTarget: ShortcutRecordingTarget?
    @Binding var shortcutRecordingMessage: String?
    @Binding var commandModeShortcut: HotkeyShortcut?
    @Binding var rewriteShortcut: HotkeyShortcut
    @Binding var cancelRecordingShortcut: HotkeyShortcut?
    @Binding var pasteLastTranscriptionShortcut: HotkeyShortcut?
    @Binding var commandModeShortcutEnabled: Bool
    @Binding var rewriteShortcutEnabled: Bool
    @Binding var pasteLastTranscriptionShortcutEnabled: Bool
    @Binding var hotkeyManagerInitialized: Bool
    @Binding var hotkeyMode: HotkeyActivationMode
    @Binding var enableStreamingPreview: Bool
    @Binding var copyToClipboard: Bool

    // CRITICAL FIX: Cache default device names to avoid CoreAudio calls during view body evaluation.
    // Querying AudioDevice.getDefaultInputDevice() in the view body triggers HALSystem::InitializeShell()
    // which races with SwiftUI's AttributeGraph metadata processing and causes EXC_BAD_ACCESS crashes.
    @State private var cachedDefaultInputUID: String = ""
    @State private var cachedDefaultOutputName: String = ""

    // Detailed analytics consent UI state (default ON; daily activity remains enabled)
    @State private var shareDetailedAnalytics: Bool = SettingsStore.shared.shareDetailedAnalytics
    @State private var showAnalyticsPrivacy: Bool = false
    @State private var pendingDetailedAnalyticsValue: Bool? = nil
    @State private var showDetailedAnalyticsConfirmation: Bool = false
    @State private var rollbackVersion: String = ""
    @State private var isRollingBack: Bool = false
    @State private var rollbackOptions: [SimpleUpdater.ReleaseBuildOption] = []
    @State private var selectedRollbackVersion = ""
    @State private var isLoadingRollbackVersions = false
    @State private var rollbackVersionsLoaded = false
    @State private var rollbackVersionsError: String?
    @State private var audioHistoryBudgetText: String = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    @State private var audioHistoryUsageBytes: Int64 = 0
    @State private var draggedMicrophoneUID: String?
    @State private var hoveredMicrophoneUID: String?
    @State private var searchScrollCoordinator = SettingsSearchScrollCoordinator()

    let hotkeyManager: GlobalHotkeyManager?
    let menuBarManager: MenuBarManager
    let startRecording: () -> Void
    let refreshDevices: () -> Void
    let openAccessibilitySettings: () -> Void
    let restartApp: () -> Void
    let revealAppInFinder: () -> Void
    let openApplicationsFolder: () -> Void

    private func isRecording(_ target: ShortcutRecordingTarget) -> Bool {
        self.activeShortcutRecordingTarget == target
    }

    private var detailedAnalyticsToggleBinding: Binding<Bool> {
        Binding(
            get: {
                self.pendingDetailedAnalyticsValue ?? self.shareDetailedAnalytics
            },
            set: { newValue in
                // User is trying to turn OFF → ask first
                if self.shareDetailedAnalytics, !newValue {
                    self.pendingDetailedAnalyticsValue = false
                    self.showDetailedAnalyticsConfirmation = true

                    return
                }

                // Normal ON path
                self.shareDetailedAnalytics = newValue
                self.applyAnalyticsConsentChange(newValue)
            }
        )
    }

    private var detailedAnalyticsConfirmationBinding: Binding<Bool> {
        Binding(
            get: { self.showDetailedAnalyticsConfirmation },
            set: { newValue in
                // Only open modal if we have a pending value
                if newValue {
                    if self.pendingDetailedAnalyticsValue != nil {
                        self.showDetailedAnalyticsConfirmation = true
                    }
                } else {
                    // Closing the modal: reset pending state
                    self.showDetailedAnalyticsConfirmation = false
                    self.pendingDetailedAnalyticsValue = nil
                }
            }
        )
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var appDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    private var launchAtStartupBinding: Binding<Bool> {
        Binding(
            get: { self.settings.launchAtStartupEnabled },
            set: { self.settings.setLaunchAtStartup($0) }
        )
    }

    private typealias DictationRouting = DictationShortcutRouting<HotkeyShortcut, SettingsStore.DictationPromptSelection>

    private func dictationStyleTitle(_ style: SettingsStore.DictationPromptSelection) -> String {
        switch style {
        case .off: "Basic — No cleanup"
        case .default: SettingsStore.DictationModeLabels.externalDefault
        case .privateAI: SettingsStore.DictationModeLabels.smartWithModel
        case let .profile(id):
            self.settings.promptProfiles(for: .dictate).first(where: { $0.id == id }).map { $0.name.isEmpty ? "Untitled" : $0.name } ?? "Default"
        }
    }

    private func dictationStylePicker(for package: DictationRouting.Package, routing: DictationRouting) -> some View {
        let profiles = self.settings.promptProfiles(for: .dictate)
        let privateAIAvailable = PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
        let title = self.dictationStyleTitle(package.style)
        return Menu {
            Section("ON-DEVICE") {
                self.dictationStyleOption(.off, for: package, routing: routing)
                if PrivateFeatures.privateAIProvider {
                    self.dictationStyleOption(.privateAI, for: package, routing: routing, isAvailable: privateAIAvailable)
                }
            }
            Section("CUSTOM STYLES") {
                self.dictationStyleOption(.default, for: package, routing: routing)
                ForEach(profiles) { profile in
                    self.dictationStyleOption(.profile(profile.id), for: package, routing: routing)
                }
            }
        } label: {
            Text(title).lineLimit(1)
        }
        .fluidDropdownStyle()
        .disabled(self.isRecordingAnyShortcut)
        .accessibilityLabel("Cleanup style for \(package.key.displayString)")
        .accessibilityValue(title)
    }

    private func dictationStyleOption(
        _ style: SettingsStore.DictationPromptSelection,
        for package: DictationRouting.Package,
        routing: DictationRouting,
        isAvailable: Bool = true
    ) -> some View {
        let blocker = routing.blocker(moving: package, to: style)
        let name = self.dictationStyleTitle(style)
        let label = switch blocker {
        case let .taken(by: owner)?: "\(name) · used by \(owner.displayString)"
        case .mainKeysOnly?: "\(name) · keyboard keys only"
        case nil: name
        }
        let isSelected = Binding(
            get: { style == package.style },
            set: { isOn in if isOn { self.setDictationStyle(style, for: package) } }
        )
        return Toggle(label, isOn: isSelected)
            .disabled(!isAvailable || blocker != nil)
    }

    var body: some View {
        SettingsPersistentScrollView(
            theme: self.theme,
            colorScheme: self.colorScheme,
            searchScrollCoordinator: self.searchScrollCoordinator,
            searchScrollTarget: self.selectedSectionSearchResults.first?.target,
            searchScrollRequest: self.searchScrollRequest
        ) {
            VStack(spacing: 16) {
                if self.selectedSection == .fluidMeet {
                    // The page title already names FluidMeet, so the group carries no title of its own.
                    FluidSettingsGroup {
                        self.switchRow(
                            title: "Enable FluidMeet",
                            description: "Record and transcribe meetings. Turning this off hides FluidMeet and stops meeting detection. Your saved meetings are kept.",
                            footnote: self.appServices.hasActiveMeetingSessionActivity
                                ? "Finish the current meeting recording or processing before turning FluidMeet off." : nil,
                            isOn: Binding(
                                get: { self.settings.fluidMeetEnabled },
                                set: { self.appServices.setFluidMeetEnabled($0) }
                            )
                        )
                        .disabled(self.appServices.hasActiveMeetingSessionActivity)
                    }
                    .settingsSearchTarget(.fluidMeet)
                }

                self.generalPage
                    .shownInSettingsSection(.general, selectedSection: self.selectedSection)

                // Shortcuts needs Accessibility; without it the page shows how to turn it on.
                if self.selectedSection == .shortcuts {
                    if self.accessibilityEnabled {
                        self.shortcutsPage
                    } else {
                        self.accessibilityAccessGroup
                            .settingsSearchTarget(.globalHotkey)
                            .shownInSettingsSection(.shortcuts, selectedSection: self.selectedSection)
                    }
                }

                self.dictationPage
                    .shownInSettingsSection(.dictation, selectedSection: self.selectedSection)
                }

                // Shortcuts page, or dictation behavior. Without Accessibility access the
                // shortcuts page shows the permission card instead.
                if self.selectedSection == .shortcuts, self.accessibilityEnabled {
                    self.shortcutsPage
                } else {
                    ThemedCard(style: .standard) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 8) {
                                Label(self.selectedSection == .shortcuts ? "Shortcuts" : "Dictation behavior", systemImage: self.selectedSection == .shortcuts ? "keyboard" : "mic")
                                    .font(.fluidSystem(.headline))
                                    .foregroundStyle(.primary)

                                Spacer()
                            }
                            .settingsSearchTarget(self.selectedSection == .shortcuts ? .globalHotkey : .dictation)

                            if self.accessibilityEnabled {
                                VStack(alignment: .leading, spacing: 12) {
                                    if self.selectedSection == .dictation {
                                        // MARK: - Options Section

                                    // MARK: - Shortcuts Section

                                    VStack(alignment: .leading, spacing: 16) {
                                        self.dictationShortcutPackages
                                            .settingsSearchTarget(.primaryDictationShortcuts)
                                        self.shortcutGroupDivider
                                        self.shortcutGroup {
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
                                                },
                                                onRemovePressed: {
                                                    if self.activeShortcutRecordingTarget == .command {
                                                        self.shortcutRecordingMessage = nil
                                                        self.activeShortcutRecordingTarget = nil
                                                    }
                                                    self.commandModeShortcut = nil
                                                    self.commandModeShortcutEnabled = false
                                                }
                                            )
                                            .settingsSearchTarget(.commandModeShortcut)
                                            self.shortcutGroupDivider

                                            self.shortcutRow(
                                                content: .init(
                                                    icon: "pencil.and.outline",
                                                    iconColor: .secondary,
                                                    title: "Edit Mode",
                                                    description: "Speak to edit selected text or write new text"
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
                                            .settingsSearchTarget(.editModeShortcut)
                                        }
                                        self.shortcutGroupDivider
                                        self.shortcutGroup {
                                            self.shortcutRow(
                                                content: .init(
                                                    icon: "xmark.circle.fill",
                                                    iconColor: .secondary,
                                                    title: "Cancel Recording",
                                                    description: "Stop without pasting"
                                                ),
                                                shortcut: self.cancelRecordingShortcut,
                                                isRecording: self.isRecording(.cancel),
                                                isAnyRecordingActive: self.isRecordingAnyShortcut,
                                                recordingMessage: self.isRecording(.cancel) ? self.shortcutRecordingMessage : nil,
                                                onChangePressed: {
                                                    DebugLogger.shared.debug("Starting to record new cancel shortcut", source: "SettingsView")
                                                    self.shortcutRecordingMessage = nil
                                                    self.activeShortcutRecordingTarget = .cancel
                                                },
                                                onRemovePressed: { self.cancelRecordingShortcut = nil }
                                            )
                                            .settingsSearchTarget(.cancelRecordingShortcut)
                                            self.shortcutGroupDivider

                                            self.shortcutRow(
                                                content: .init(
                                                    icon: "arrow.down.doc",
                                                    iconColor: .secondary,
                                                    title: "Paste Last Transcription",
                                                    description: "Insert your last dictation again"
                                                ),
                                                shortcut: self.pasteLastTranscriptionShortcut,
                                                isRecording: self.isRecording(.pasteLast),
                                                isAnyRecordingActive: self.isRecordingAnyShortcut,
                                                recordingMessage: self.isRecording(.pasteLast) ? self.shortcutRecordingMessage : nil,
                                                isEnabled: self.$pasteLastTranscriptionShortcutEnabled,
                                                onChangePressed: {
                                                    DebugLogger.shared.debug("Starting to record new paste last transcription shortcut", source: "SettingsView")
                                                    self.shortcutRecordingMessage = nil
                                                    self.activeShortcutRecordingTarget = .pasteLast
                                                },
                                                onRemovePressed: {
                                                    if self.activeShortcutRecordingTarget == .pasteLast {
                                                        self.shortcutRecordingMessage = nil
                                                        self.activeShortcutRecordingTarget = nil
                                                    }
                                                    self.pasteLastTranscriptionShortcut = nil
                                                    self.pasteLastTranscriptionShortcutEnabled = false
                                                }
                                            )
                                            .settingsSearchTarget(.pasteLastTranscriptionShortcut)
                                            self.shortcutGroupDivider
                                            self.shortcutRow(
                                                content: .init(
                                                    icon: "person.2.wave.2",
                                                    iconColor: .secondary,
                                                    title: "Start / Stop Meeting",
                                                    description: self.settings.fluidMeetEnabled
                                                        ? "Pick sources, record, or stop a meeting"
                                                        : "Turn on FluidMeet to use this shortcut"
                                                ),
                                                shortcut: self.settings.meetingRecordingHotkeyShortcut,
                                                isRecording: self.isRecording(.meeting),
                                                isAnyRecordingActive: self.isRecordingAnyShortcut,
                                                recordingMessage: self.isRecording(.meeting) ? self.shortcutRecordingMessage : nil,
                                                onChangePressed: {
                                                    self.shortcutRecordingMessage = nil
                                                    self.activeShortcutRecordingTarget = .meeting
                                                },
                                                onRemovePressed: {
                                                    if self.activeShortcutRecordingTarget == .meeting {
                                                        self.shortcutRecordingMessage = nil
                                                        self.activeShortcutRecordingTarget = nil
                                                    }
                                                    self.settings.meetingRecordingHotkeyShortcut = nil
                                                }
                                            )
                                            .settingsSearchTarget(.meetingRecordingShortcut)
                                        }
                                    }
                                }
                                if self.selectedSection == .dictation {
                                    // MARK: - Options Section

                                    VStack(spacing: 12) {
                                        HStack(alignment: .center) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Activation Mode")
                                                    .font(self.theme.typography.bodyStrong)
                                                    .foregroundStyle(self.settingsTitleText)
                                                Text(self.hotkeyMode.description)
                                                    .font(self.theme.typography.bodySmall)
                                                    .foregroundStyle(self.settingsSecondaryText)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                            FluidDropdownPicker("Activation mode", selectedTitle: self.hotkeyMode.displayName, selection: self.$hotkeyMode) {
                                                ForEach(HotkeyActivationMode.allCases) { mode in
                                                    Text(mode.displayName).tag(mode)
                                                }
                                            }
                                            .fluidDropdownStyle()
                                            .frame(width: 170, alignment: .trailing)
                                        }
                                        .onChange(of: self.hotkeyMode) { _, newValue in
                                            SettingsStore.shared.hotkeyMode = newValue
                                            self.hotkeyManager?.setHotkeyMode(newValue)
                                        }
                                        .settingsSearchTarget(.activationMode)
                                        Divider().opacity(0.2)

                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Transcription Sounds")
                                                    .font(self.theme.typography.bodyStrong)
                                                    .foregroundStyle(self.settingsTitleText)
                                                Text("Choose a recording sound. Paired sounds preview start and stop.")
                                                    .fixedSize(horizontal: false, vertical: true)
                                                    .font(self.theme.typography.bodySmall)
                                                    .foregroundStyle(self.settingsSecondaryText)
                                            }

                                            Spacer()

                                            FluidDropdownPicker("Transcription sound", selectedTitle: SettingsStore.shared.transcriptionStartSound.displayName, selection: Binding(
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
                                            .fluidDropdownStyle()
                                            .frame(width: 170, alignment: .trailing)
                                        }
                                        .settingsSearchTarget(.transcriptionSounds)

                                        if SettingsStore.shared.transcriptionStartSound != .none {
                                            HStack {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("Activation Mode")
                                                        .font(self.theme.typography.bodyStrong)
                                                        .foregroundStyle(self.settingsTitleText)
                                                    Text(self.hotkeyMode.description)
                                                        .font(self.theme.typography.bodySmall)
                                                        .foregroundStyle(self.settingsSecondaryText)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)

                                                FluidDropdownPicker("Activation mode", selectedTitle: self.hotkeyMode.displayName, selection: self.$hotkeyMode) {
                                                    ForEach(HotkeyActivationMode.allCases) { mode in
                                                        Text(mode.displayName).tag(mode)
                                                    }
                                                }
                                                .fluidDropdownStyle()
                                                .frame(width: 170, alignment: .trailing)
                                            }
                                            .onChange(of: self.hotkeyMode) { _, newValue in
                                                SettingsStore.shared.hotkeyMode = newValue
                                                self.hotkeyManager?.setHotkeyMode(newValue)
                                            }
                                            .settingsSearchTarget(.activationMode)
                                            Divider().opacity(0.2)

                                            HStack {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("Transcription Sounds")
                                                        .font(self.theme.typography.bodyStrong)
                                                        .foregroundStyle(self.settingsTitleText)
                                                    Text("Choose a recording sound. Paired sounds preview start and stop.")
                                                        .fixedSize(horizontal: false, vertical: true)
                                                        .font(self.theme.typography.bodySmall)
                                                        .foregroundStyle(self.settingsSecondaryText)
                                                }

                                                Spacer()

                                                FluidDropdownPicker("Transcription sound", selectedTitle: SettingsStore.shared.transcriptionStartSound.displayName, selection: Binding(
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
                                                .fluidDropdownStyle()
                                                .frame(width: 170, alignment: .trailing)
                                            }
                                            .settingsSearchTarget(.transcriptionSounds)

                                            if SettingsStore.shared.transcriptionStartSound != .none {
                                                HStack {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text("Volume")
                                                            .font(self.theme.typography.bodyStrong)
                                                            .foregroundStyle(self.settingsTitleText)
                                                        Text("Adjust the recording sound cue volume.")
                                                            .font(self.theme.typography.bodySmall)
                                                            .foregroundStyle(self.settingsSecondaryText)
                                                            .fixedSize(horizontal: false, vertical: true)
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
                                            .settingsSearchTarget(.copyToClipboard)
                                            Divider().opacity(0.2)

                                            HStack(alignment: .center) {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("Text Insertion Mode")
                                                        .font(self.theme.typography.bodyStrong)
                                                        .foregroundStyle(self.settingsTitleText)
                                                    Text(SettingsStore.shared.textInsertionMode.description)
                                                        .font(self.theme.typography.bodySmall)
                                                        .foregroundStyle(self.settingsSecondaryText)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)

                                                FluidDropdownPicker("Text insertion", selectedTitle: SettingsStore.shared.textInsertionMode.displayName, selection: Binding(
                                                    get: { SettingsStore.shared.textInsertionMode },
                                                    set: { SettingsStore.shared.textInsertionMode = $0 }
                                                )) {
                                                    ForEach(SettingsStore.TextInsertionMode.allCases) { mode in
                                                        Text(mode.displayName).tag(mode)
                                                    }
                                                }
                                                .fluidDropdownStyle()
                                                .fixedSize(horizontal: true, vertical: false)
                                                .frame(minWidth: 170, alignment: .trailing)
                                            }
                                            .settingsSearchTarget(.textInsertionMode)
                                            Divider().opacity(0.2)

                                            self.optionToggleRow(
                                                title: "Save Transcription History",
                                                description: "Save transcriptions for stats tracking. Disable for privacy.",
                                                isOn: Binding(
                                                    get: { SettingsStore.shared.saveTranscriptionHistory },
                                                    set: {
                                                        SettingsStore.shared.saveTranscriptionHistory = $0
                                                        self.refreshAudioHistoryUsage()
                                                    }
                                                )
                                            )
                                            .settingsSearchTarget(.transcriptionHistory)
                                            Divider().opacity(0.2)

                                            self.optionToggleRow(
                                                title: "Save Audio With History",
                                                description: "Store actual microphone audio locally with dictation history. Disabled by default.",
                                                isOn: Binding(
                                                    get: { SettingsStore.shared.saveAudioWithTranscriptionHistory },
                                                    set: {
                                                        SettingsStore.shared.saveAudioWithTranscriptionHistory = $0
                                                        self.refreshAudioHistoryUsage()
                                                    }
                                                )
                                            )
                                            .disabled(!SettingsStore.shared.saveTranscriptionHistory)
                                            .settingsSearchTarget(.audioHistory)

                                            if SettingsStore.shared.saveTranscriptionHistory,
                                               SettingsStore.shared.saveAudioWithTranscriptionHistory
                                            {
                                                self.audioHistoryControls()
                                                    .padding(.top, 2)
                                                    .settingsSearchTarget(.audioStorage)
                                                Divider().opacity(0.2)
                                            } else {
                                                Divider().opacity(0.2)
                                            }

                                            self.optionToggleRow(
                                                title: "Weekends Don't Break Streak",
                                                description: "Skip Saturday and Sunday when calculating usage streaks. Perfect for weekday-only users.",
                                                isOn: Binding(
                                                    get: { SettingsStore.shared.weekendsDontBreakStreak },
                                                    set: { SettingsStore.shared.weekendsDontBreakStreak = $0 }
                                                )
                                            )
                                            .settingsSearchTarget(.usageStreak)
                                            Divider().opacity(0.2)

                                            self.optionToggleRow(
                                                title: "Skip Silent Recordings",
                                                description: "Avoid transcription when a recording up to four seconds contains only clear silence. Disabled by default to preserve quiet speech.",
                                                isOn: Binding(
                                                    get: { SettingsStore.shared.skipSilentRecordingsEnabled },
                                                    set: { SettingsStore.shared.skipSilentRecordingsEnabled = $0 }
                                                )
                                            )
                                            .settingsSearchTarget(.skipSilentRecordings)
                                            Divider().opacity(0.2)

                                            self.optionToggleRow(
                                                title: "Pause Media During Transcription",
                                                description: "Automatically pause currently playing audio/video when transcription starts. Resumes only if FluidVoice paused it.",
                                                isOn: Binding(
                                                    get: { SettingsStore.shared.pauseMediaDuringTranscription },
                                                    set: { SettingsStore.shared.pauseMediaDuringTranscription = $0 }
                                                )
                                            )
                                            .settingsSearchTarget(.pauseMedia)
                                            Divider().opacity(0.2)

                                            DictionarySuggestionsSettingsRow()
                                                .settingsSearchTarget(.dictionarySuggestions)
                                            Divider().opacity(0.2)

                                            self.optionToggleRow(
                                                title: "Share Detailed Anonymous Analytics",
                                                description: "Share anonymous daily feature, insertion performance, onboarding, and model metrics. " +
                                                    "When off, FluidVoice still records the anonymous daily activity signal and, in beta builds, daily ASR and Fluid Intelligence timing summaries. " +
                                                    "Never includes transcription text or prompts.",
                                                isOn: self.detailedAnalyticsToggleBinding
                                            )
                                            .settingsSearchTarget(.analyticsPrivacy)

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
                                                    .font(self.theme.typography.bodyStrong)
                                                    .foregroundStyle(self.theme.palette.warning)
                                            }
                                            Text("Required for global hotkey functionality")
                                                .font(self.theme.typography.bodySmall)
                                                .foregroundStyle(self.settingsSecondaryText)
                                                .fixedSize(horizontal: false, vertical: true)
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
                                            "Select **\(self.appDisplayName)**; use **Reveal in Finder** below if needed",
                                            "Click **Open**, then toggle **\(self.appDisplayName) ON** in the list",
                                        ],
                                        warningStyle: true
                                    )

                                    HStack(spacing: 10) {
                                        Button("Reveal in Finder") {
                                            self.revealAppInFinder()
                                        }
                                        .fluidOutlinedButton()
                                        .controlSize(.small)

                                        Button("Open Applications") {
                                            self.openApplicationsFolder()
                                        }
                                        .fluidOutlinedButton()
                                        .controlSize(.small)
                                    }
                                }
                                .settingsSearchTarget(.accessibilityPermission)
                            }
                        }
                        .padding(16)
                    }
                    .shownInSettingsSection(self.selectedSection == .shortcuts ? .shortcuts : .dictation, selectedSection: self.selectedSection)
                }

                if self.selectedSection == .dictationFormatting {
                    self.formattingPage
                }

                // The page title already says these are notifications, so the group has no title.
                FluidSettingsGroup {
                    self.switchRow(
                        title: "AI Enhancement Failures",
                        description: "Notify when AI Enhancement fails and raw transcription is typed.",
                        isOn: Binding(
                            get: { SettingsStore.shared.notifyAIProcessingFailures },
                            set: { SettingsStore.shared.notifyAIProcessingFailures = $0 }
                        )
                    )
                    .settingsSearchTarget(.aiEnhancementFailures)

                    self.switchRow(
                        title: "Microphone Changes",
                        description: "Show an alert when FluidVoice changes or loses its microphone.",
                        isOn: Binding(
                            get: { self.settings.showMicrophoneChangeAlerts },
                            set: { enabled in
                                self.settings.showMicrophoneChangeAlerts = enabled
                                if enabled == false {
                                    MicrophoneChangeOverlayController.shared.hide()
                                }
                            }
                        )
                    )
                    .settingsSearchTarget(.microphoneChanges)

                    self.switchRow(
                        title: "Paste Check",
                        description: "Show a card when FluidVoice can't confirm that pasted text landed.",
                        isOn: Binding(
                            get: { self.settings.showPasteCheckAlerts },
                            set: { self.settings.showPasteCheckAlerts = $0 }
                        )
                    )
                    .settingsSearchTarget(.pasteCheck)
                }
                .shownInSettingsSection(.notifications, selectedSection: self.selectedSection)

                // Audio devices: the microphone order FluidVoice tries, and where sound plays.
                VStack(alignment: .leading, spacing: FluidSettingsLayout.groupSpacing) {
                    FluidSettingsGroup(
                        title: "Microphones",
                        hint: "Tried from top to bottom",
                        footnote: "Drag to reorder; unavailable devices keep their place. This order applies only to FluidVoice and does not change your macOS input."
                    ) {
                        self.microphonePriorityRows
                        if self.selectedInputDevice?.isBluetooth == true {
                            FluidSettingsBlock {
                                Label(
                                    "Bluetooth microphone mode can reduce headphone playback quality. Prefer a wired, USB, or display microphone when available.",
                                    systemImage: "exclamationmark.triangle"
                                )
                                .fluidText(.body)
                                .foregroundStyle(self.theme.look.text)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        FluidSettingsBlock {
                            HStack(spacing: self.theme.metrics.spacing.sm) {
                                Button("Refresh") {
                                    self.refreshDevices()
                                    // Update cached default device names on refresh
                                    let defaultInput = AudioDevice.getDefaultInputDevice()
                                    self.cachedDefaultInputUID = defaultInput?.uid ?? ""
                                    self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
                                }
                                .fluidAction()
                                if self.settings.suppressedMicrophoneUIDs.isEmpty == false {
                                    Button("Restore Removed") {
                                        self.settings.restoreRemovedMicrophones(with: self.inputDevices)
                                        self.refreshActiveInputSelection()
                                    }
                                    .fluidAction()
                                    .disabled(self.isMicrophonePriorityEditingDisabled)
                                }
                            }
                        }
                    }
                    .settingsSearchTarget(.inputDevicePriority)
                    .onChange(of: self.inputDevices) { _, newDevices in
                        let defaultInput = AudioDevice.getDefaultInputDevice()
                        self.cachedDefaultInputUID = defaultInput?.uid ?? ""
                        guard newDevices.isEmpty == false else { return }
                        if let selectedInput = self.appServices.microphonePreferenceCoordinator
                            .reconcileMicrophoneSelection(
                                availableInputs: newDevices,
                                defaultInputUID: self.cachedDefaultInputUID
                            )
                        {
                            self.selectedInputUID = selectedInput.uid
                        }
                    }

                    FluidSettingsGroup(title: "Output") {
                        FluidSettingsRow(title: "Output Device") {
                            FluidDropdownPicker(
                                "Output device",
                                selectedTitle: self.outputDevices.first(where: { $0.uid == self.selectedOutputUID }).map { $0.name == self.cachedDefaultOutputName ? "\($0.name) (System Default)" : $0.name } ?? "Loading...",
                                selection: self.$selectedOutputUID
                            ) {
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
                            .fluidDropdownStyle()
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
                                _ = AudioDevice.setDefaultOutputDevice(uid: newUID)
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
                        .settingsSearchTarget(.outputDevice)
                    }
                }
                .shownInSettingsSection(.audio, selectedSection: self.selectedSection)

                // Overlay: its look (bottom overlay only), where and how it shows, and the visualizer.
                VStack(alignment: .leading, spacing: FluidSettingsLayout.groupSpacing) {
                    if self.settings.overlayPosition == .bottom {
                        FluidSettingsGroup(title: "Look") {
                            self.overlayMaterialSettings
                        }
                    }

                    FluidSettingsGroup(
                        title: "Placement & Behavior",
                        footnote: self.asr.isRunning ? "Settings are disabled during active recording." : nil
                    ) {
                        FluidSettingsRow(title: "Overlay Position", description: "Where the recording indicator appears on screen.") {
                            FluidDropdownPicker("Overlay position", selectedTitle: self.settings.overlayPosition.displayName, selection: self.$settings.overlayPosition) {
                                ForEach(SettingsStore.OverlayPosition.allCases, id: \.self) { position in
                                    Text(position.displayName).tag(position)
                                }
                            }
                            .fluidDropdownStyle()
                            .frame(width: 170, alignment: .trailing)
                        }
                        .settingsSearchTarget(.overlayPosition)

                        FluidSettingsRow(
                            title: self.settings.overlayPosition == .bottom ? "Dictation Overlay Size" : "Notch Style",
                            description: self.settings.overlayPosition == .bottom
                                ? "How large the recording indicator appears."
                                : "Choose the regular notch or the compact layout."
                        ) {
                            if self.settings.overlayPosition == .bottom {
                                FluidDropdownPicker("Overlay size", selectedTitle: self.settings.overlaySize.displayName, selection: self.$settings.overlaySize) {
                                    ForEach(SettingsStore.OverlaySize.allCases, id: \.self) { size in
                                        Text(size.displayName).tag(size)
                                    }
                                }
                                .fluidDropdownStyle()
                                .frame(width: 170, alignment: .trailing)
                            } else {
                                FluidDropdownPicker(
                                    "Notch presentation",
                                    selectedTitle: self.settings.notchPresentationMode.displayName,
                                    selection: self.$settings.notchPresentationMode
                                ) {
                                    ForEach(SettingsStore.NotchPresentationMode.allCases, id: \.self) { mode in
                                        Text(mode.displayName).tag(mode)
                                    }
                                }
                                .fluidDropdownStyle()
                                .frame(width: 170, alignment: .trailing)
                            }
                        }
                        .settingsSearchTarget(.overlayStyle)

                        if self.settings.overlayPosition == .bottom {
                            FluidSettingsRow(title: "Bottom Offset", description: "Distance from the bottom of the screen.") {
                                HStack(spacing: 6) {
                                    Slider(value: self.$settings.overlayBottomOffset, in: 20...500)
                                        .tint(self.theme.look.switchOn)
                                        .controlSize(.small)
                                        .frame(width: 110)
                                        .accessibilityLabel("Bottom offset")
                                    Text("\(Int(self.settings.overlayBottomOffset)) px")
                                        .fluidText(.label)
                                        .monospacedDigit()
                                        .foregroundStyle(self.theme.look.secondaryText)
                                        .frame(width: 54, alignment: .trailing)
                                }
                                .frame(width: 170, alignment: .trailing)
                            }
                            .settingsSearchTarget(.bottomOffset)
                        }

                        self.switchRow(
                            title: "Live Preview",
                            description: "Show transcription text in the overlay while you speak.",
                            isOn: self.$enableStreamingPreview
                        )
                        .onChange(of: self.enableStreamingPreview) { _, newValue in
                            SettingsStore.shared.enableStreamingPreview = newValue
                        }
                        .settingsSearchTarget(.livePreview)

                        FluidSettingsRow(title: "Meeting Overlay", description: "Choose the display used when your next meeting starts.") {
                            FluidDropdownPicker(
                                "Meeting overlay",
                                selectedTitle: self.settings.meetingOverlayPreference == .pill ? "Pill" : "Captions",
                                selection: self.$settings.meetingOverlayPreference
                            ) {
                                ForEach(MeetingOverlayPreference.allCases, id: \.self) { preference in
                                    Text(preference == .pill ? "Pill" : "Captions").tag(preference)
                                }
                            }
                            .fluidDropdownStyle()
                            .frame(width: 170, alignment: .trailing)
                        }
                    }

                    FluidSettingsGroup(title: "Visualizer") {
                        VStack(spacing: 0) {
                            FluidSettingsRow(title: "Sensitivity", description: "How strongly the visualizer reacts to sound.") {
                                Button("Reset") {
                                    self.visualizerNoiseThreshold = 0.4
                                    SettingsStore.shared.visualizerNoiseThreshold = self.visualizerNoiseThreshold
                                }
                                .fluidAction()
                            }
                            self.overlaySliderLine(low: "More", high: "Less", value: String(format: "%.2f", self.visualizerNoiseThreshold)) {
                                Slider(value: self.$visualizerNoiseThreshold, in: 0.01...0.8, step: 0.01)
                                    .accessibilityLabel("Sensitivity")
                            }
                        }
                        .settingsSearchTarget(.overlaySensitivity)

                        VStack(spacing: 0) {
                            FluidSettingsRow(
                                title: "Transcription Preview Length",
                                description: "How many recent characters appear in the notch or pill preview."
                            ) {
                                Text("\(self.settings.transcriptionPreviewCharLimit) chars")
                                    .fluidText(.label)
                                    .monospacedDigit()
                                    .foregroundStyle(self.theme.look.secondaryText)
                            }
                            self.overlaySliderLine(low: "Less", high: "More", value: nil) {
                                Slider(
                                    value: Binding(
                                        get: { Double(self.settings.transcriptionPreviewCharLimit) },
                                        set: { self.settings.transcriptionPreviewCharLimit = Int($0.rounded()) }
                                    ),
                                    in: Double(SettingsStore.transcriptionPreviewCharLimitRange.lowerBound)...Double(SettingsStore.transcriptionPreviewCharLimitRange.upperBound),
                                    step: Double(SettingsStore.transcriptionPreviewCharLimitStep)
                                )
                                .accessibilityLabel("Transcription preview length")
                            }
                        }
                        .settingsSearchTarget(.transcriptionPreviewLength)
                    }
                }
                .shownInSettingsSection(.overlay, selectedSection: self.selectedSection)

                // Data & Diagnostics: backups of your data, and logs for troubleshooting.
                VStack(alignment: .leading, spacing: FluidSettingsLayout.groupSpacing) {
                    FluidSettingsGroup(title: "Backup") {
                        self.backupUtilityRow()
                    }
                    .settingsSearchTarget(.backupAndRestore)

                    FluidSettingsGroup(
                        title: "Logs",
                        footnote: "Crash diagnostics are written to Library/Logs/Fluid/Fluid.log by default."
                    ) {
                        self.switchRow(
                            title: "Show Debug Logs in App",
                            description: "File logs are always collected for diagnostics.",
                            isOn: Binding(
                                get: { SettingsStore.shared.enableDebugLogs },
                                set: { SettingsStore.shared.enableDebugLogs = $0 }
                            )
                        )
                        FluidSettingsRow(
                            title: "Debug Log",
                            description: "Detailed information about what the app did, to help with troubleshooting."
                        ) {
                            Button("Reveal in Finder") {
                                let url = FileLogger.shared.currentLogFileURL()
                                if FileManager.default.fileExists(atPath: url.path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                } else {
                                    DebugLogger.shared.info("Log file not found at \(url.path)", source: "SettingsView")
                                }
                            }
                            .fluidAction()
                        }
                    }
                    .settingsSearchTarget(.debugLogs)
                }
                .shownInSettingsSection(.dataAndDiagnostics, selectedSection: self.selectedSection)

                // Experimental: features still being tried out.
                VStack(alignment: .leading, spacing: FluidSettingsLayout.groupSpacing) {
                    FluidSettingsGroup {
                        self.returnToStartingFieldToggle
                        DictionaryMatcherExperimentSettings()
                            .disabled(self.asr.isRunningOrStarting)
                            .settingsSearchTarget(.dictionaryMatcherExperiments)
                        self.switchRow(
                            title: "Faster Long Dictation",
                            description: "For long recordings, reuse completed live windows and process only the remaining tail when you stop.",
                            footnote: "Parakeet only. Falls back to normal transcription if reuse is unavailable or fails.",
                            isOn: Binding(
                                get: { SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled },
                                set: { SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled = $0 }
                            )
                        )
                        .settingsSearchTarget(.fasterLongDictation)
                        self.overlayClosingAnimationSetting
                        self.switchRow(
                            title: "Show Performance in History",
                            description: "Display transcription time, cleanup time, and Fluid Intelligence speed.",
                            isOn: Binding(
                                get: { SettingsStore.shared.showHistoryPerformanceMetrics },
                                set: { SettingsStore.shared.showHistoryPerformanceMetrics = $0 }
                            )
                        )
                        .settingsSearchTarget(.historyPerformance)
                    }

                    if PrivateAIProviderFeature.shared.isAvailable {
                        FluidSettingsGroup(title: "Fluid Intelligence") {
                            DictationScreenContextSettings(settings: self.settings, isBusy: self.asr.isRunningOrStarting)
                        }
                        .settingsSearchTarget(.dictationScreenContext)
                    }
                }
                .shownInSettingsSection(.experimental, selectedSection: self.selectedSection)
            }
            .padding(.bottom, 28)
            // Settings read best at a fixed width; a bigger popup adds margin, not longer rows.
            .fluidPageContent(width: .form, alignment: .center)
            .settingsSearchTarget(self.selectedSection.searchTarget)
            .environment(\.settingsSearchPresentation, self.settingsSearchPresentation)
        }
        .id(self.selectedSection)
        .sheet(isPresented: self.$showAnalyticsPrivacy) {
            AnalyticsPrivacyView()
                .frame(minWidth: 520, minHeight: 520)
                .appTheme(self.theme)
        }
        .sheet(isPresented: self.detailedAnalyticsConfirmationBinding) {
            AnalyticsConfirmationView(
                onConfirm: {
                    if let pending = pendingDetailedAnalyticsValue {
                        self.shareDetailedAnalytics = pending
                        self.applyAnalyticsConsentChange(pending)
                    }
                    self.pendingDetailedAnalyticsValue = nil
                    self.showDetailedAnalyticsConfirmation = false
                },
                onCancel: {
                    self.pendingDetailedAnalyticsValue = nil
                    self.showDetailedAnalyticsConfirmation = false
                }
            )
        }
        .task(id: self.selectedSection) {
            await self.prepareSelectedSection()
        }
        .onChange(of: self.visualizerNoiseThreshold) { _, newValue in
            SettingsStore.shared.visualizerNoiseThreshold = newValue
        }
    }

    private func openIssueReportingPage() {
        guard let url = URL(string: "https://github.com/altic-dev/Fluid-oss/issues/new/choose") else { return }
        NSWorkspace.shared.open(url)
    }

    private func exportBackup() {
        Task { await self.performBackupExport() }
    }

    private func performBackupExport() async {
        do {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = BackupService.shared.suggestedFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let document = try await BackupService.shared.makeBackupDocument()
            let data = try BackupService.shared.encode(document)
            try data.write(to: url, options: .atomic)

            self.presentInfoAlert(
                title: "Backup Exported",
                message: "Saved your FluidVoice backup to:\n\(url.path)"
            )
        } catch {
            self.presentErrorAlert(
                title: "Backup Export Failed",
                message: error.localizedDescription
            )
        }
    }

    private func importBackup() {
        Task { await self.performBackupImport() }
    }

    static func backupImportConfirmation(exportedAt: Date, fileTranscriptCount: Int?) -> NSAlert {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var changes = "This replaces your current settings, prompt profiles, and stats history."
        if let fileTranscriptCount {
            changes += fileTranscriptCount == 0
                ? " This backup has no file transcripts. Importing it will clear your saved file transcripts."
                : " The file transcripts in this backup will replace your saved file transcripts."
        }

        let confirm = NSAlert()
        confirm.messageText = "Import this backup?"
        confirm.informativeText = """
        \(changes)

        Exported: \(formatter.string(from: exportedAt))
        API keys are not included and will not be changed.
        """
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Import")
        confirm.addButton(withTitle: "Cancel")
        return confirm
    }

    private func performBackupImport() async {
        do {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]

            guard panel.runModal() == .OK, let url = panel.url else { return }

            let data = try Data(contentsOf: url)
            let document = try BackupService.shared.decode(data)

            let confirm = Self.backupImportConfirmation(
                exportedAt: document.exportedAt, fileTranscriptCount: document.fileTranscriptionHistory?.count
            )
            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            try await BackupService.shared.restore(document)
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
        self.shareDetailedAnalytics = SettingsStore.shared.shareDetailedAnalytics
        self.pendingDetailedAnalyticsValue = nil
        self.showDetailedAnalyticsConfirmation = false
        self.refreshAudioHistoryUsage()
    }

    private func refreshAudioHistoryUsage() {
        self.audioHistoryUsageBytes = DictationAudioHistoryStore.shared.audioUsageBytes()
        self.audioHistoryBudgetText = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    }

    private func applyAudioHistoryBudget() {
        let normalized = self.audioHistoryBudgetText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value > 0 else {
            self.presentErrorAlert(title: "Invalid Budget", message: "Enter a positive number of GB.")
            self.refreshAudioHistoryUsage()
            return
        }

        let newBudget = max(0.1, value)
        let newBudgetBytes = DictationAudioHistoryStore.bytes(forGigabytes: newBudget)
        if self.audioHistoryUsageBytes > newBudgetBytes {
            let confirm = NSAlert()
            confirm.messageText = "Prune saved audio?"
            confirm.informativeText = """
            This budget is below current audio usage. FluidVoice will delete the oldest saved audio first and keep transcript history.
            """
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: "Apply and Prune")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else {
                self.refreshAudioHistoryUsage()
                return
            }
        }

        SettingsStore.shared.audioHistoryBudgetGB = newBudget
        Task { @MainActor in
            let pruned = await TranscriptionHistoryStore.shared.pruneAudioToBudget()
            self.refreshAudioHistoryUsage()
            if pruned > 0 {
                self.presentInfoAlert(title: "Audio Pruned", message: "Deleted oldest saved audio from \(pruned) history entries.")
            }
        }
    }

    private func deleteSavedAudio() {
        let confirm = NSAlert()
        confirm.messageText = "Delete saved audio?"
        confirm.informativeText = "This removes saved dictation audio only. Transcript history stays intact."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Delete Audio")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let removed = TranscriptionHistoryStore.shared.deleteAllSavedAudio()
        self.refreshAudioHistoryUsage()
        self.presentInfoAlert(title: "Audio Deleted", message: "Removed audio from \(removed) history entries.")
    }

    private func exportAudioZip() {
        do {
            guard TranscriptionHistoryStore.shared.entries.contains(where: {
                DictationAudioHistoryStore.shared.audioFileExists(for: $0)
            }) else {
                throw DictationAudioHistoryError.noAudioEntries
            }

            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = DictationAudioHistoryStore.shared.suggestedAudioExportFilename()

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try DictationAudioHistoryStore.shared.exportAudioArchive(
                entries: TranscriptionHistoryStore.shared.entries,
                to: url
            )
            self.presentInfoAlert(title: "Audio Export Saved", message: "Saved your dictation audio export to:\n\(url.path)")
        } catch {
            self.presentErrorAlert(title: "Audio Export Failed", message: error.localizedDescription)
        }
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

    private func applyAnalyticsConsentChange(_ enabled: Bool) {
        SettingsStore.shared.shareDetailedAnalytics = enabled
        AnalyticsService.shared.setDetailedAnalyticsEnabled(enabled)
    }

    // MARK: - Helper Views

    private func backupUtilityRow() -> some View {
        FluidSettingsRow(
            title: "Settings, Profiles, History & Stats",
            description: "Export them to a file, or import a backup. API keys are left out."
        ) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Button("Export", action: self.exportBackup)
                    .fluidAction()
                Button("Import", action: self.importBackup)
                    .fluidAction()
            }
            .fixedSize()
        }
    }

    /// Saved audio use against its budget, with the budget field beside it.
    private var audioStorageRow: some View {
        HStack(alignment: .center, spacing: self.theme.metrics.spacing.md + 2) {
            VStack(alignment: .leading, spacing: 5) {
                LegacyHistoryRecoveryControls()
                Text("Audio Storage")
                    .fluidText(.rowTitle)
                    .foregroundStyle(self.theme.look.text)
                Text(
                    "Audio history: \(DictationAudioHistoryStore.formattedGigabytes(self.audioHistoryUsageBytes)) of \(Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)) GB"
                )
                .fluidText(.body)
                .foregroundStyle(self.theme.look.secondaryText)
                ProgressView(value: self.audioHistoryUsageFraction())
                    .progressViewStyle(.linear)
                    .tint(self.theme.look.switchOn)
                    .frame(maxWidth: 220)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Budget")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
                TextField("4", text: self.$audioHistoryBudgetText)
                    .textFieldStyle(.plain)
                    .fluidText(.body)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 8)
                    .frame(width: 58, height: 28)
                    .fluidDropdownSurface(cornerRadius: 8)
                    .accessibilityLabel("Audio budget in gigabytes")
                Text("GB")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
                Button("Apply") { self.applyAudioHistoryBudget() }
                    .fluidAction()
            }
            .fixedSize()
        }
        .padding(.horizontal, FluidSettingsLayout.rowInset)
        .padding(.vertical, FluidSettingsLayout.rowVerticalPadding)
    }

    private var audioExportRow: some View {
        FluidSettingsRow(title: "Export Audio", description: "ZIP with manifest.jsonl and WAV audio.") {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Button("Export ZIP") { self.exportAudioZip() }
                    .fluidAction()
                Button("Delete Audio", role: .destructive) { self.deleteSavedAudio() }
                    .fluidAction()
                    .disabled(self.audioHistoryUsageBytes <= 0)
            }
            .fixedSize()
        }
    }

    private static func audioBudgetText(for value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private func audioHistoryUsageFraction() -> Double {
        let budget = SettingsStore.shared.audioHistoryBudgetBytes
        guard budget > 0 else { return 0 }
        return min(1, Double(self.audioHistoryUsageBytes) / Double(budget))
    }

    private var dictationRouting: DictationRouting {
        let profiles = self.settings.promptProfiles(for: .dictate)
        func rank(_ style: SettingsStore.DictationPromptSelection) -> Int {
            switch style {
            case .off: 0
            case .privateAI: 1
            case .default: 2
            case let .profile(id): 3 + (profiles.firstIndex(where: { $0.id == id }) ?? profiles.count)
            }
        }
        let styleKeys = self.settings.dictationPromptShortcutAssignments()
            .filter { $0.selection != .privateAI || PrivateFeatures.privateAIProvider }
            .sorted { rank($0.selection) < rank($1.selection) }
            .map { (style: $0.selection, key: $0.shortcut) }
        return DictationRouting(
            mainKeys: self.primaryDictationShortcuts,
            mainStyle: self.settings.dictationPromptSelection(for: .primary),
            styleKeys: styleKeys,
            keyCanMoveToStyle: { !$0.isMouseShortcut && !$0.requiresModifierForRecording }
        )
    }

    // MARK: - Shortcuts page

    private static var shortcutsGroupInset: CGFloat { FluidSettingsLayout.rowInset }
    private static let dictationStyleColumnWidth: CGFloat = 184
    private static let dictationAutoSendColumnWidth: CGFloat = 64

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: FluidSettingsLayout.groupSpacing) {
            if !self.hotkeyManagerInitialized {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).fixedSize()
                    Text("Shortcuts are starting…")
                        .fluidText(.body)
                        .foregroundStyle(self.theme.look.secondaryText)
                }
            }
            self.shortcutsSection(
                title: "Dictation",
                hint: "Hold or tap a key to dictate",
                footnote: "Auto-send presses your send key after your text is inserted."
            ) {
                self.dictationShortcutRows
            }
            .settingsSearchTarget(.primaryDictationShortcuts)

            self.shortcutsSection(title: "While You Dictate") {
                self.whileDictatingRows
            }

            self.shortcutsSection(title: "Actions") {
                self.actionShortcutRows
            }
        }
        .padding(.top, 4)
        .settingsSearchTarget(.globalHotkey)
        .shownInSettingsSection(.shortcuts, selectedSection: self.selectedSection)
    }

    private func shortcutsSection<Content: View>(
        title: String,
        hint: String? = nil,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Shortcuts draws its own lines, so a row can span the table or carry its warning.
        let rows = content()
        return FluidSettingsGroup(title: title, hint: hint, footnote: footnote, separated: false) { rows }
    }

    /// Hairline between rows, inset from the leading edge like system settings lists.
    private var shortcutsRowDivider: some View {
        FluidHairline().padding(.leading, Self.shortcutsGroupInset)
    }

    @ViewBuilder
    private var dictationShortcutRows: some View {
        let routing = self.dictationRouting
        let addTarget = ShortcutRecordingTarget.primaryDictation(.add)
        return self.shortcutGroup {
            ForEach(Array(routing.packages.enumerated()), id: \.offset) { index, package in
                if index > 0 { self.shortcutGroupDivider }
                self.dictationPackageRow(package, routing: routing)
            }
            if self.isRecording(addTarget) {
                self.shortcutControls(
                    shortcut: nil,
                    isRecording: true,
                    title: "New dictation shortcut",
                    onEdit: {},
                    onRemove: nil
                )
                self.shortcutRecordingWarning
            } else {
                Button {
                    self.shortcutRecordingMessage = nil
                    self.activeShortcutRecordingTarget = addTarget
                } label: {
                    Label("Add dictation shortcut", systemImage: "plus")
                }
                .buttonStyle(FluidHoverIconButtonStyle())
                .disabled(self.isRecordingAnyShortcut)
            }
        }
    }

    @ViewBuilder
    private func dictationPackageRow(_ package: DictationRouting.Package, routing: DictationRouting) -> some View {
        if let target = self.recordingTarget(for: package) {
            let isRecording = self.isRecording(target)
            VStack(alignment: .leading, spacing: 6) {
                self.shortcutControls(
                    shortcut: package.key,
                    isRecording: isRecording,
                    title: package.key.displayString,
                    onEdit: {
                        self.shortcutRecordingMessage = nil
                        self.activeShortcutRecordingTarget = target
                    },
                    onRemove: { self.removeDictationPackage(package) }
                )
                if isRecording {
                    self.shortcutRecordingWarning
                } else {
                    HStack(spacing: 12) {
                        self.dictationStylePicker(for: package, routing: routing)
                        self.autoSendToggle(for: package.key)
                    }
                }
            }
            .fluidText(.label)
            .foregroundStyle(self.theme.look.tertiaryText)
            .lineLimit(1)
            .padding(.horizontal, Self.shortcutsGroupInset)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityHidden(true)
        }
        ForEach(Array(packages.enumerated()), id: \.offset) { index, package in
            if index > 0 { self.shortcutsRowDivider }
            self.dictationPackageRow(package, routing: routing)
        }
        if !packages.isEmpty { self.shortcutsRowDivider }
        if self.isRecording(addTarget) {
            VStack(alignment: .leading, spacing: 6) {
                ShortcutKeyField(
                    shortcut: nil,
                    title: "New dictation",
                    isRecording: true,
                    isLocked: false,
                    onToggleRecording: { self.toggleRecording(addTarget) }
                )
                self.shortcutRecordingWarning(isRecording: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.shortcutsGroupInset)
            .padding(.vertical, 9)
        } else {
            Button {
                self.toggleRecording(addTarget)
            } label: {
                Label("Add shortcut", systemImage: "plus")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.text)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .padding(.horizontal, Self.shortcutsGroupInset)
            }
            .fluidSelectableRow(isSelected: false)
            .disabled(self.isRecordingAnyShortcut)
        }
    }

    @ViewBuilder
    private var shortcutRecordingWarning: some View {
        if let message = self.shortcutRecordingMessage, !message.isEmpty {
            Text(message).font(self.theme.typography.bodySmall).foregroundStyle(self.theme.palette.warning)
        }
    }

    private func recordingTarget(for package: DictationRouting.Package) -> ShortcutRecordingTarget? {
        switch package.source {
        case let .main(index): .primaryDictation(.replace(index))
        case .style: self.settings.dictationPromptConfigurationKey(for: package.style).map { .dictationPrompt($0) }
        }
    }

    private func setDictationStyleShortcut(_ key: HotkeyShortcut?, for style: SettingsStore.DictationPromptSelection) {
        var configuration = self.settings.dictationPromptConfiguration(for: style)
        configuration.shortcut = key
        self.settings.setDictationPromptConfiguration(configuration, for: style)
    }

    private func setDictationStyle(_ style: SettingsStore.DictationPromptSelection, for package: DictationRouting.Package) {
        if style == .privateAI, !PrivateAIProviderPromptFormat.isAvailable(settings: self.settings) { return }
        let before = self.dictationRouting
        var after = before
        guard after.move(package, to: style) else { return }
        let keepsAutoSend = self.settings.autoSendEnabled(for: package.key)
        func owns(_ routing: DictationRouting, _ entry: (style: SettingsStore.DictationPromptSelection, key: HotkeyShortcut)) -> Bool {
            routing.styleKeys.contains { $0.style == entry.style && $0.key == entry.key }
        }
        // Save the key in its new place before clearing the old one, so auto-send is never pruned.
        for entry in after.styleKeys where !owns(before, entry) {
            self.setDictationStyleShortcut(entry.key, for: entry.style)
        }
        if after.mainKeys != before.mainKeys {
            self.settings.primaryDictationShortcuts = after.mainKeys
            self.primaryDictationShortcuts = after.mainKeys
        }
        for entry in before.styleKeys where !owns(after, entry) {
            self.setDictationStyleShortcut(nil, for: entry.style)
        }
        if after.mainStyle != before.mainStyle {
            self.settings.setDictationPromptSelection(after.mainStyle, for: .primary)
        }
        if keepsAutoSend { self.settings.setAutoSendEnabled(true, for: package.key) }
        NotificationCenter.default.post(name: .dictationPromptShortcutsChanged, object: nil)
    }

    private func removeDictationPackage(_ package: DictationRouting.Package) {
        // Dictation must always have a key, so the last shortcut stays.
        guard self.dictationRouting.packages.count > 1 else { return }
        switch package.source {
        case let .main(index):
            guard self.primaryDictationShortcuts.indices.contains(index), self.primaryDictationShortcuts[index] == package.key else { return }
            self.primaryDictationShortcuts.remove(at: index)
        case .style:
            self.setDictationStyleShortcut(nil, for: package.style)
            NotificationCenter.default.post(name: .dictationPromptShortcutsChanged, object: nil)
        }
    }

    private func autoSendToggle(for shortcut: HotkeyShortcut) -> some View {
        Toggle("Auto-send", isOn: Binding(
            get: { self.settings.autoSendEnabled(for: shortcut) },
            set: { self.settings.setAutoSendEnabled($0, for: shortcut) }
        ))
        .fluidSwitch()
        .fixedSize()
        .disabled(self.isRecordingAnyShortcut)
        .accessibilityLabel("Auto-send for \(shortcut.displayString)")
        .help("Insert dictation, then press your send key after 1 second. Press Escape to cancel sending.")
    }
}

private extension SettingsView {
    var overlayClosingAnimationSetting: some View {
        self.switchRow(
            title: "Animate overlay closing",
            description: "Off closes immediately. Turn on to try the closing transition.",
            isOn: self.$settings.overlayClosingAnimationEnabled
        )
    }

    var overlayMaterialSettings: some View {
        OverlayAppearanceEditor()
    }

    var isRecordingAnyShortcut: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    var selectedSectionSearchResults: [SettingsSearchResult] {
        self.searchResults.filter { $0.section == self.selectedSection }
    }

    var settingsSearchPresentation: SettingsSearchPresentation? {
        guard let primaryTarget = self.selectedSectionSearchResults.first?.target else { return nil }
        return SettingsSearchPresentation(
            matchedTargets: Set(self.selectedSectionSearchResults.map(\.target)),
            primaryTarget: primaryTarget,
            scrollCoordinator: self.searchScrollCoordinator
        )
    }

    /// One row per microphone in priority order, or one line saying there are none.
    @ViewBuilder
    var microphonePriorityRows: some View {
        if self.settings.microphonePriority.isEmpty {
            FluidSettingsRow(
                title: self.inputDevices.isEmpty ? "No microphones available" : "No microphones in priority"
            )
        } else {
            ForEach(Array(self.settings.microphonePriority.enumerated()), id: \.element.uid) { index, entry in
                self.microphonePriorityRow(entry, rank: index + 1)
            }
        }
    }

    func microphonePriorityRow(
        _ entry: SettingsStore.MicrophonePriorityEntry,
        rank: Int
    ) -> some View {
        let connectedDevice = self.inputDevices.first { $0.uid == entry.uid }
        let isAvailable = connectedDevice.map {
            self.appServices.microphonePreferenceCoordinator.isInputDeviceAvailable($0)
        } ?? false
        let isActive = entry.uid == self.microphonePreferenceCoordinator.confirmedActiveInputUID && isAvailable
        let isHovered = self.hoveredMicrophoneUID == entry.uid

        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.fluidSystem(size: 11, weight: .semibold))
                .foregroundStyle(self.theme.look.tertiaryText.opacity(self.isMicrophonePriorityEditingDisabled ? 0.5 : 1))
                .frame(width: 18, height: 30)
                .contentShape(Rectangle())
                .onDrag {
                    self.draggedMicrophoneUID = entry.uid
                    return NSItemProvider(object: entry.uid as NSString)
                } preview: {
                    Image(systemName: "line.3.horizontal")
                        .font(.fluidSystem(size: 11, weight: .semibold))
                        .foregroundStyle(self.theme.look.text)
                        .frame(width: 30, height: 30)
                        .fluidLit(self.theme.look.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .allowsHitTesting(self.isMicrophonePriorityEditingDisabled == false)
                .accessibilityHidden(true)

            Text("\(rank).")
                .fluidText(.label)
                .foregroundStyle(self.theme.look.tertiaryText)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)

            Text(entry.name)
                .fluidText(.rowTitle)
                .foregroundStyle(isAvailable ? self.theme.look.text : self.theme.look.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            if isHovered {
                Button(role: .destructive) {
                    self.removeMicrophonePriorityEntry(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.fluidSystem(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(FluidHoverIconButtonStyle())
                .disabled(self.isMicrophonePriorityEditingDisabled)
                .help("Remove \(entry.name) from microphone priority")
                .accessibilityLabel("Remove \(entry.name)")
                .transition(.opacity)
            } else if isActive {
                // Which microphone FluidVoice is using right now, in words rather than a colored dot.
                FluidStatusLabel(text: "In use")
            } else if isAvailable == false {
                Text("Unavailable")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
        }
        .padding(.horizontal, FluidSettingsLayout.rowInset)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .opacity(isAvailable ? 1 : 0.62)
        .onHover { isHovering in
            let animation: Animation? = self.accessibilityReduceMotion ? nil : .easeOut(duration: 0.12)
            withAnimation(animation) {
                if isHovering {
                    self.hoveredMicrophoneUID = entry.uid
                } else if self.hoveredMicrophoneUID == entry.uid {
                    self.hoveredMicrophoneUID = nil
                }
            }
        }
        .onDrop(
            of: [UTType.plainText.identifier],
            delegate: MicrophonePriorityDropDelegate(
                targetUID: entry.uid,
                settings: self.settings,
                draggedUID: self.$draggedMicrophoneUID,
                reorderAnimation: self.accessibilityReduceMotion ? nil : .easeInOut(duration: 0.16),
                onDropCompleted: self.refreshActiveInputSelection
            )
        )
        .contextMenu {
            Button("Move Up") {
                self.settings.moveMicrophonePriority(uid: entry.uid, by: -1)
                self.refreshActiveInputSelection()
            }
            .disabled(self.isMicrophonePriorityEditingDisabled || rank == 1)

            Button("Move Down") {
                self.settings.moveMicrophonePriority(uid: entry.uid, by: 1)
                self.refreshActiveInputSelection()
            }
            .disabled(self.isMicrophonePriorityEditingDisabled || rank == self.settings.microphonePriority.count)

            Divider()

            Button("Remove from Priority", role: .destructive) {
                self.removeMicrophonePriorityEntry(entry)
            }
            .disabled(self.isMicrophonePriorityEditingDisabled)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Priority \(rank), \(entry.name)")
        .accessibilityValue(isActive ? "Active" : (isAvailable ? "Available" : "Unavailable"))
        .accessibilityAction(named: "Move up") {
            guard self.isMicrophonePriorityEditingDisabled == false, rank > 1 else { return }
            self.settings.moveMicrophonePriority(uid: entry.uid, by: -1)
            self.refreshActiveInputSelection()
        }
        .accessibilityAction(named: "Move down") {
            guard self.isMicrophonePriorityEditingDisabled == false,
                  rank < self.settings.microphonePriority.count
            else { return }
            self.settings.moveMicrophonePriority(uid: entry.uid, by: 1)
            self.refreshActiveInputSelection()
        }
        .accessibilityAction(named: "Remove from priority") {
            guard self.isMicrophonePriorityEditingDisabled == false else { return }
            self.removeMicrophonePriorityEntry(entry)
        }
    }

    var isMicrophonePriorityEditingDisabled: Bool {
        self.asr.isRunning || self.asr.isStarting
    }

    func refreshActiveInputSelection() {
        // Reuse the existing off-main hardware refresh so the green active
        // indicator and next capture resolve from live Core Audio.
        self.refreshDevices()
    }

    func removeMicrophonePriorityEntry(_ entry: SettingsStore.MicrophonePriorityEntry) {
        self.hoveredMicrophoneUID = nil
        self.settings.removeMicrophoneFromPriority(
            uid: entry.uid,
            isConnected: self.inputDevices.contains { $0.uid == entry.uid }
        )
        self.refreshActiveInputSelection()
    }

    var selectedInputDevice: AudioDevice.Device? {
        guard let confirmedUID = self.microphonePreferenceCoordinator.confirmedActiveInputUID else {
            return nil
        }
        return self.inputDevices.first { $0.uid == confirmedUID }
    }
}

private extension SettingsView {
    func prepareSelectedSection() async {
        do {
            try await Task.sleep(nanoseconds: self.accessibilityReduceMotion ? 120_000_000 : 240_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }
        switch self.selectedSection {
        case .general:
            self.refreshRollbackState()
            self.settings.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)
            await self.loadRollbackVersions()
        case .audio:
            await self.prepareAudioSettings()
        case .dictation:
            await self.refreshAudioHistoryUsageInBackground()
        case .fluidMeet, .dictationFormatting, .shortcuts, .notifications, .overlay, .dataAndDiagnostics, .experimental:
            break
        }
    }

    func prepareAudioSettings() async {
        // Keep Core Audio initialization out of the navigation transaction.
        await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
        await AudioStartupGate.shared.waitUntilOpen()
        guard !Task.isCancelled else { return }

        self.refreshDevices()

        if !self.inputDevices.isEmpty {
            let defaultInput = AudioDevice.getDefaultInputDevice()
            self.cachedDefaultInputUID = defaultInput?.uid ?? ""
            if let selectedInput = self.appServices.microphonePreferenceCoordinator
                .reconcileMicrophoneSelection(
                    availableInputs: self.inputDevices,
                    defaultInputUID: self.cachedDefaultInputUID
                )
            {
                self.selectedInputUID = selectedInput.uid
            }
        }

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

        // Cache hardware names outside body evaluation to avoid the Core Audio/AttributeGraph race.
        let defaultInput = AudioDevice.getDefaultInputDevice()
        self.cachedDefaultInputUID = defaultInput?.uid ?? ""
        self.cachedDefaultOutputName = AudioDevice.getDefaultOutputDevice()?.name ?? ""
    }

    func refreshAudioHistoryUsageInBackground() async {
        let usageBytes = await Task.detached(priority: .utility) {
            DictationAudioHistoryStore.shared.audioUsageBytes()
        }.value
        guard !Task.isCancelled else { return }

        self.audioHistoryUsageBytes = usageBytes
        self.audioHistoryBudgetText = Self.audioBudgetText(for: SettingsStore.shared.audioHistoryBudgetGB)
    }
}

private struct MicrophonePriorityDropDelegate: DropDelegate {
    let targetUID: String
    let settings: SettingsStore
    @Binding var draggedUID: String?
    let reorderAnimation: Animation?
    let onDropCompleted: () -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        self.draggedUID != nil
    }

    func dropEntered(info _: DropInfo) {
        guard let draggedUID = self.draggedUID,
              draggedUID != self.targetUID
        else { return }

        let entries = self.settings.microphonePriority
        guard let sourceIndex = entries.firstIndex(where: { $0.uid == draggedUID }),
              let targetIndex = entries.firstIndex(where: { $0.uid == self.targetUID })
        else { return }

        withAnimation(self.reorderAnimation) {
            self.settings.reorderMicrophonePriority(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        self.draggedUID = nil
        self.onDropCompleted()
        return true
    }
}

private extension View {
    @ViewBuilder
    func shownInSettingsSection(_ section: SettingsSection, selectedSection: SettingsSection) -> some View {
        if section == selectedSection {
            self
        }
    }
}

// MARK: - Filler Words Editor

struct FillerWordsEditor: View {
    @State private var fillerWords: [String] = SettingsStore.shared.fillerWords
    @State private var newWord: String = ""
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filler words to remove")
                .fluidText(.label)
                .foregroundStyle(self.theme.look.tertiaryText)

            FlowLayout(spacing: 6) {
                ForEach(self.fillerWords, id: \.self) { word in
                    HStack(spacing: 2) {
                        Text(word)
                            .fluidText(.body)
                            .foregroundStyle(self.theme.look.text)
                        Button {
                            self.removeWord(word)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.fluidSystem(size: 9, weight: .semibold))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(FluidHoverIconButtonStyle())
                        .accessibilityLabel("Remove \(word)")
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .padding(.vertical, 3)
                    .background(self.theme.look.quietFill, in: Capsule())
                }
            }

            HStack(spacing: 8) {
                TextField("Add word", text: self.$newWord)
                    .textFieldStyle(.plain)
                    .fluidText(.body)
                    .padding(.horizontal, 10)
                    .frame(width: 140, height: 28)
                    .fluidDropdownSurface(cornerRadius: 8)
                    .onSubmit { self.addWord() }

                Button("Add") { self.addWord() }
                    .fluidAction()
                    .disabled(self.newWord.trimmingCharacters(in: .whitespaces).isEmpty)

                Spacer()

                Button("Reset") {
                    self.fillerWords = SettingsStore.defaultFillerWords
                    SettingsStore.shared.fillerWords = self.fillerWords
                }
                .fluidAction()
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

// MARK: - Shortcuts: While You Dictate

private extension SettingsView {
    var spokenSendSettings: some View {
        Group {
            self.optionToggleRow(
                title: "Spoken Send",
                description: "Say the phrase and pause to stop dictation and send.",
                isOn: Binding(
                    get: { self.settings.spokenSendEnabled },
                    set: { self.settings.spokenSendEnabled = $0 }
                )
            )

            if self.settings.spokenSendEnabled {
                VStack(spacing: 10) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Send Phrase")
                                .font(self.theme.typography.bodyStrong)
                                .foregroundStyle(self.settingsTitleText)
                            Text("Say it at the end. Say “literal \(self.settings.spokenSendPhrase)” to dictate it normally.")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.settingsSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .fluidDropdownStyle(fillsWidth: true)
                    .frame(width: ShortcutKeyField.width)
                }

                self.shortcutsRowDivider

                self.shortcutsSettingRow(
                    title: "Spoken Send",
                    description: "Say the phrase and pause. It stops and sends by itself."
                ) {
                    self.shortcutsSwitch(
                        isOn: Binding(
                            get: { self.settings.spokenSendEnabled },
                            set: { self.settings.spokenSendEnabled = $0 }
                        ),
                        label: "Spoken Send"
                    )
                }

                if self.settings.spokenSendEnabled {
                    self.shortcutsRowDivider
                        .padding(.leading, Self.shortcutsSubRowIndent)

                    self.shortcutsSettingRow(
                        title: "Send Phrase",
                        description: "Say “literal \(self.settings.spokenSendPhrase)” to type it instead.",
                        indent: Self.shortcutsSubRowIndent
                    ) {
                        TextField(
                            "send it",
                            text: Binding(
                                get: { self.settings.spokenSendPhrase },
                                set: { self.settings.spokenSendPhrase = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .fluidText(.body)
                        .padding(.horizontal, 10)
                        .frame(width: ShortcutKeyField.width, height: ShortcutKeyField.height)
                        .fluidDropdownSurface(cornerRadius: 10)
                        .accessibilityLabel("Spoken Send phrase")
                    }

                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wait Before Sending")
                                .font(self.theme.typography.bodyStrong)
                                .foregroundStyle(self.settingsTitleText)
                            Text("How long to wait after you say the send phrase.")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.settingsSecondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        FluidDropdownPicker("Wait before sending", selectedTitle: self.settings.spokenSendWait.displayName, selection: Binding(
                            get: { self.settings.spokenSendWait },
                            set: { self.settings.spokenSendWait = $0 }
                        )) {
                            ForEach(SettingsStore.SpokenSendWait.allCases) { wait in
                                Text(wait.displayName).tag(wait)
                            }
                        }
                        .fluidDropdownStyle()
                        .frame(width: 170, alignment: .trailing)
                    }
                }
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send Key")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.settingsTitleText)
                    Text("The key Auto-send and Spoken Send press.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.settingsSecondaryText)
                }

                Spacer()

                FluidDropdownPicker("Send key", selectedTitle: self.settings.spokenSendKey.displayName, selection: Binding(
                    get: { self.settings.spokenSendKey },
                    set: { self.settings.spokenSendKey = $0 }
                )) {
                    ForEach(SettingsStore.SpokenSendKey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .fluidDropdownStyle()
                .frame(width: 170, alignment: .trailing)
            }
        }
    }

    /// A titled row in a Shortcuts group, with its control in the same trailing column as the shortcut keys.
    func shortcutsSettingRow<Control: View>(
        title: String,
        description: String,
        indent: CGFloat = 0,
        @ViewBuilder control: () -> Control
    ) -> some View {
        let control = control()
        return FluidSettingsRow(title: title, description: description, indent: indent) { control }
    }

    /// Same size as the Auto-send switches in the Dictation group above.
    func shortcutsSwitch(isOn: Binding<Bool>, label: String) -> some View {
        Toggle(label, isOn: isOn).fluidSwitch()
    }
}

/// Learning from corrections, and its two follow-up settings while it is on. Returns separate rows
/// so the group draws a line between each.
private struct DictionarySuggestionsSettingsRow: View {
    @ObservedObject private var settings = SettingsStore.shared

    /// Follow-up rows sit a little in, so they read as part of the switch above them.
    private static let subRowIndent: CGFloat = 18

    var body: some View {
        FluidSettingsRow(
            title: "Learn from my corrections",
            description: "If you retype a word FluidVoice got wrong, it asks to add the right spelling to your dictionary."
        ) {
            Toggle("Learn from my corrections", isOn: Binding(
                get: { self.settings.automaticDictionaryLearningEnabled },
                set: { enabled in
                    self.settings.automaticDictionaryLearningEnabled = enabled
                    if !enabled {
                        AutomaticDictionaryCorrectionTracker.shared.cancel()
                    }
                }
            ))
            .fluidSwitch()
        }
        .settingsSearchTarget(.dictionarySuggestions)

        // The threshold only matters while learning is on.
        if self.settings.automaticDictionaryLearningEnabled {
            FluidSettingsRow(
                title: "Ask after",
                description: "Wait until you've fixed the same word this many times. Pick 2 or 3 if it asks too often.",
                indent: Self.subRowIndent
            ) {
                FluidDropdownPicker(
                    "Ask after",
                    selectedTitle: self.settings.automaticDictionarySuggestionFrequency.displayName,
                    selection: self.$settings.automaticDictionarySuggestionFrequency
                ) {
                    ForEach(SettingsStore.AutomaticDictionarySuggestionFrequency.allCases) { frequency in
                        Text(frequency.displayName).tag(frequency)
                    }
                }
                .fluidDropdownStyle()
                .fixedSize()
            }

            FluidSettingsRow(
                title: "Prompt delay",
                description: "Wait this long after you stop editing. Shorter delays may ask while you're still correcting.",
                indent: Self.subRowIndent
            ) {
                FluidDropdownPicker(
                    "Prompt delay",
                    selectedTitle: self.settings.automaticDictionaryPromptDelay.displayName,
                    selection: self.$settings.automaticDictionaryPromptDelay
                ) {
                    ForEach(SettingsStore.AutomaticDictionaryPromptDelay.allCases) { delay in
                        Text(delay.displayName).tag(delay)
                    }
                }
                .fluidDropdownStyle()
                .fixedSize()
            }
        }
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
            text[emailRange].foregroundColor = self.theme.look.text
            text[emailRange].underlineStyle = .single
        }

        if let githubRange = text.range(of: "GitHub") {
            text[githubRange].link = URL(string: "https://github.com/altic-dev/FluidVoice")
            text[githubRange].foregroundColor = self.theme.look.text
            text[githubRange].underlineStyle = .single
        }

        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stop sharing detailed anonymous analytics?")
                .font(.fluidSystem(.headline))

            Text("We never collect audio, transcription text, prompts, or other personal information.")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Divider()

            HStack {
                Spacer()

                Button("Cancel") {
                    self.onCancel()
                }

                Button("Stop Detailed Analytics") {
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

private extension SettingsView {
    var returnToStartingFieldToggle: some View {
        self.switchRow(
            title: "Return to Starting Field",
            description: "Paste dictation into the field where you started recording, even if you switch apps.",
            footnote: "Off by default. When off, dictation follows your current cursor. Applies to dictation only.",
            isOn: Binding(
                get: { SettingsStore.shared.returnDictationToStartingField },
                set: { SettingsStore.shared.returnDictationToStartingField = $0 }
            )
        )
        .settingsSearchTarget(.returnToStartingField)
    }
}

private extension SettingsView {
    /// A titled setting with a switch, in the shared settings look.
    func switchRow(
        title: String,
        description: String? = nil,
        footnote: String? = nil,
        error: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        FluidSettingsRow(title: title, description: description, footnote: footnote, error: error) {
            Toggle(title, isOn: isOn)
                .fluidSwitch()
                .accessibilityLabel(title)
        }
    }

    /// A full-width slider under its row, with a word at each end and an optional value.
    private func overlaySliderLine(low: String, high: String, value: String?, @ViewBuilder slider: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(low)
                .fluidText(.label)
                .foregroundStyle(self.theme.look.secondaryText)
                .frame(width: 36, alignment: .leading)
            slider()
                .tint(self.theme.look.switchOn)
            Text(high)
                .fluidText(.label)
                .foregroundStyle(self.theme.look.secondaryText)
                .frame(width: 36, alignment: .trailing)
            if let value {
                Text(value)
                    .fluidText(.label)
                    .monospacedDigit()
                    .foregroundStyle(self.theme.look.tertiaryText)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.horizontal, FluidSettingsLayout.rowInset)
        .padding(.bottom, FluidSettingsLayout.rowVerticalPadding)
    }

    // MARK: - Dictation Formatting page

    /// Three groups whose first rows already say what they hold, so none needs a title of its own.
    private var formattingPage: some View {
        VStack(alignment: .leading, spacing: FluidSettingsLayout.groupSpacing) {
            FluidSettingsGroup {
                self.switchRow(
                    title: "Lowercase First Letter",
                    description: "Start each transcription with a lowercase letter.",
                    isOn: Binding(
                        get: { self.settings.gaavLowercaseFirstLetterEnabled },
                        set: { self.settings.gaavLowercaseFirstLetterEnabled = $0 }
                    )
                )
                self.switchRow(
                    title: "Remove Trailing Period",
                    description: "Drop a final period from transcriptions.",
                    isOn: Binding(
                        get: { self.settings.gaavRemoveTrailingPeriodEnabled },
                        set: { self.settings.gaavRemoveTrailingPeriodEnabled = $0 }
                    )
                )
                self.switchRow(
                    title: "Slash Commands & @ Formatting",
                    description: "Convert spoken slash commands and supported @ mentions into symbols.",
                    isOn: Binding(
                        get: { self.settings.literalDictationFormattingEnabled },
                        set: { self.settings.literalDictationFormattingEnabled = $0 }
                    )
                )
                self.switchRow(
                    title: "Space Between Dictations",
                    description: "Add spacing when consecutive dictations are joined.",
                    isOn: Binding(
                        get: { self.settings.continuousDictationSpacingEnabled },
                        set: { self.settings.continuousDictationSpacingEnabled = $0 }
                    )
                )
                self.switchRow(
                    title: "Smart Capitalization",
                    description: "Use text before the cursor to choose uppercase or lowercase.",
                    isOn: Binding(
                        get: { self.settings.contextAwareCapitalizationEnabled },
                        set: { self.settings.contextAwareCapitalizationEnabled = $0 }
                    )
                )
            }
            .settingsSearchTarget(.textFormatting)

            CustomDictionaryView(formattingOnly: true, revealTarget: .constant(nil))
                .settingsSearchTarget(.spokenFormatting)

            FluidSettingsGroup {
                self.switchRow(
                    title: "Remove Filler Words",
                    description: "Remove filler sounds like ‘um’, ‘uh’, and ‘er’ from transcriptions.",
                    isOn: Binding(
                        get: { self.settings.removeFillerWordsEnabled },
                        set: { self.settings.removeFillerWordsEnabled = $0 }
                    )
                )
                if self.settings.removeFillerWordsEnabled {
                    FluidSettingsBlock { FillerWordsEditor() }
                }
            }
            .settingsSearchTarget(.fillerWords)
        }
    }

    // MARK: - Dictation page

    private var dictationPage: some View {
        VStack(alignment: .leading, spacing: FluidSettingsLayout.groupSpacing) {
            if self.asr.micStatus != .authorized {
                // Only surface microphone permission when the user needs to act.
                self.microphoneAccessGroup
                    .settingsSearchTarget(.microphonePermission)
            }
            if self.accessibilityEnabled {
                self.dictationBehaviorGroups
            } else {
                self.accessibilityAccessGroup
            }
        }
    }

    private var microphoneAccessGroup: some View {
        FluidSettingsGroup {
            FluidSettingsRow(
                title: self.asr.micStatus == .denied ? "Microphone access is off" : "Microphone access isn't set up",
                description: "FluidVoice needs the microphone to hear you."
            ) {
                if self.asr.micStatus == .notDetermined {
                    Button("Grant Access") { self.asr.requestMicAccess() }
                        .fluidAction(.primary)
                } else if self.asr.micStatus == .denied {
                    Button("Open Settings") { self.asr.openSystemSettingsForMic() }
                        .fluidAction(.primary)
                }
            }
            self.accessSteps(
                self.asr.micStatus == .notDetermined
                    ? ["Click **Grant Access** above", "Choose **Allow** in the system dialog"]
                    : [
                        "Click **Open Settings** above",
                        "Find **\(self.appDisplayName)** in the microphone list",
                        "Turn **\(self.appDisplayName)** on to allow access",
                    ]
            )
        }
    }

    private var accessibilityAccessGroup: some View {
        FluidSettingsGroup {
            FluidSettingsRow(
                title: "Accessibility access is off",
                description: "FluidVoice needs it for keyboard shortcuts."
            ) {
                Button("Open Accessibility Settings") { self.openAccessibilitySettings() }
                    .fluidAction(.primary)
            }
            self.accessSteps([
                "Click **Open Accessibility Settings** above",
                "In the Accessibility window, click the **+ button**",
                "Select **\(self.appDisplayName)**; use **Reveal in Finder** below if needed",
                "Click **Open**, then turn **\(self.appDisplayName)** on in the list",
            ])
            FluidSettingsBlock {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Button("Reveal in Finder") { self.revealAppInFinder() }
                        .fluidAction()
                    Button("Open Applications") { self.openApplicationsFolder() }
                        .fluidAction()
                }
            }
        }
        .settingsSearchTarget(.accessibilityPermission)
    }

    /// Numbered steps for turning on a permission, under the row that asks for it.
    private func accessSteps(_ steps: [String]) -> some View {
        FluidSettingsBlock {
            VStack(alignment: .leading, spacing: 6) {
                Text("To turn it on:")
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.tertiaryText)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .fluidText(.label)
                            .foregroundStyle(self.theme.look.tertiaryText)
                            .frame(width: 16, alignment: .trailing)
                        Text(.init(step))
                            .fluidText(.body)
                            .foregroundStyle(self.theme.look.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dictationBehaviorGroups: some View {
        FluidSettingsGroup(title: "Sound") {
            FluidSettingsRow(
                title: "Transcription Sounds",
                description: "Choose a recording sound. Paired sounds preview start and stop."
            ) {
                FluidDropdownPicker("Transcription sound", selectedTitle: SettingsStore.shared.transcriptionStartSound.displayName, selection: Binding(
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
                .fluidDropdownStyle()
                .frame(width: 170, alignment: .trailing)
            }
            .settingsSearchTarget(.transcriptionSounds)

            if SettingsStore.shared.transcriptionStartSound != .none {
                FluidSettingsRow(title: "Volume", description: "Adjust the recording sound cue volume.") {
                    Slider(
                        value: Binding(
                            get: { Double(SettingsStore.shared.transcriptionSoundVolume) },
                            set: { SettingsStore.shared.transcriptionSoundVolume = Float($0) }
                        ),
                        in: 0...1,
                        step: 0.05
                    ) { editing in
                        if !editing {
                            TranscriptionSoundPlayer.shared.playPreviewAtVolume(SettingsStore.shared.transcriptionSoundVolume)
                        }
                    }
                    .tint(self.theme.look.switchOn)
                    .frame(width: 170)
                    .accessibilityLabel("Volume")
                }
            }
        }
        .settingsSearchTarget(.dictation)

        FluidSettingsGroup(title: "Typing") {
            FluidSettingsRow(
                title: "Text Insertion Mode",
                description: SettingsStore.shared.textInsertionMode.description
            ) {
                FluidDropdownPicker("Text insertion", selectedTitle: SettingsStore.shared.textInsertionMode.displayName, selection: Binding(
                    get: { SettingsStore.shared.textInsertionMode },
                    set: { SettingsStore.shared.textInsertionMode = $0 }
                )) {
                    ForEach(SettingsStore.TextInsertionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .fluidDropdownStyle()
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 170, alignment: .trailing)
            }
            .settingsSearchTarget(.textInsertionMode)

            self.switchRow(
                title: "Copy to Clipboard",
                description: "Copy transcribed text to the clipboard too, as a backup.",
                isOn: self.$copyToClipboard
            )
            .onChange(of: self.copyToClipboard) { _, newValue in
                SettingsStore.shared.copyTranscriptionToClipboard = newValue
            }
            .settingsSearchTarget(.copyToClipboard)
        }

        FluidSettingsGroup(title: "Recording") {
            self.switchRow(
                title: "Skip Silent Recordings",
                description: "Avoid transcription when a recording up to four seconds contains only clear silence. Off by default to preserve quiet speech.",
                isOn: Binding(
                    get: { SettingsStore.shared.skipSilentRecordingsEnabled },
                    set: { SettingsStore.shared.skipSilentRecordingsEnabled = $0 }
                )
            )
            .settingsSearchTarget(.skipSilentRecordings)

            self.switchRow(
                title: "Pause Media During Transcription",
                description: "Pause playing audio or video when transcription starts. It resumes only if FluidVoice paused it.",
                isOn: Binding(
                    get: { SettingsStore.shared.pauseMediaDuringTranscription },
                    set: { SettingsStore.shared.pauseMediaDuringTranscription = $0 }
                )
            )
            .settingsSearchTarget(.pauseMedia)
        }

        FluidSettingsGroup(title: "History & Stats") {
            self.switchRow(
                title: "Save Transcription History",
                description: "Save transcriptions for stats tracking. Turn off for privacy.",
                isOn: Binding(
                    get: { SettingsStore.shared.saveTranscriptionHistory },
                    set: {
                        SettingsStore.shared.saveTranscriptionHistory = $0
                        self.refreshAudioHistoryUsage()
                    }
                )
            )
            .settingsSearchTarget(.transcriptionHistory)

            self.switchRow(
                title: "Save Audio With History",
                description: "Keep the microphone audio on this Mac with your dictation history. Off by default.",
                isOn: Binding(
                    get: { SettingsStore.shared.saveAudioWithTranscriptionHistory },
                    set: {
                        SettingsStore.shared.saveAudioWithTranscriptionHistory = $0
                        self.refreshAudioHistoryUsage()
                    }
                )
            )
            .disabled(!SettingsStore.shared.saveTranscriptionHistory)
            .settingsSearchTarget(.audioHistory)

            if SettingsStore.shared.saveTranscriptionHistory, SettingsStore.shared.saveAudioWithTranscriptionHistory {
                self.audioStorageRow
                    .settingsSearchTarget(.audioStorage)
                self.audioExportRow
            }

            self.switchRow(
                title: "Weekends Don't Break Streak",
                description: "Skip Saturday and Sunday when counting usage streaks.",
                isOn: Binding(
                    get: { SettingsStore.shared.weekendsDontBreakStreak },
                    set: { SettingsStore.shared.weekendsDontBreakStreak = $0 }
                )
            )
            .settingsSearchTarget(.usageStreak)
        }

        FluidSettingsGroup(title: "Dictionary") {
            DictionarySuggestionsSettingsRow()
        }

        FluidSettingsGroup(title: "Privacy") {
            FluidSettingsRow(
                title: "Share Detailed Anonymous Analytics",
                description: "Share anonymous daily feature, insertion performance, onboarding, and model metrics. " +
                    "When off, FluidVoice still records the anonymous daily activity signal and, in beta builds, daily ASR and Fluid Intelligence timing summaries. " +
                    "Never includes transcription text or prompts."
            ) {
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Button("What we collect") { self.showAnalyticsPrivacy = true }
                        .fluidAction()
                    Toggle("Share Detailed Anonymous Analytics", isOn: self.detailedAnalyticsToggleBinding)
                        .fluidSwitch()
                }
                .fixedSize()
            }
            .settingsSearchTarget(.analyticsPrivacy)
        }
    }

    // MARK: - General page

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: FluidSettingsLayout.groupSpacing) {
            FluidSettingsGroup(title: "Startup") {
                self.switchRow(
                    title: "Launch at startup",
                    description: "Start FluidVoice when you log in.",
                    footnote: self.settings.launchAtStartupStatusMessage,
                    error: self.settings.launchAtStartupErrorMessage,
                    isOn: self.launchAtStartupBinding
                )
                .settingsSearchTarget(.launchAtStartup)

                self.switchRow(
                    title: "Show window when launched at login",
                    description: "When off, FluidVoice starts quietly in the menu bar at login. Opening the app yourself always shows the window.",
                    isOn: Binding(
                        get: { SettingsStore.shared.showMainWindowAtLoginLaunch },
                        set: { SettingsStore.shared.showMainWindowAtLoginLaunch = $0 }
                    )
                )
                .settingsSearchTarget(.showWindowAtLogin)
            }

            FluidSettingsGroup(title: "Appearance") {
                self.switchRow(
                    title: "Hide from Dock & App Switcher",
                    description: "Keep FluidVoice in the menu bar only, without a Dock icon or a Cmd+Tab entry.",
                    footnote: "May need a restart to take effect.",
                    isOn: Binding(
                        get: { SettingsStore.shared.hideFromDockAndAppSwitcher },
                        set: { SettingsStore.shared.hideFromDockAndAppSwitcher = $0 }
                    )
                )
                .settingsSearchTarget(.dockVisibility)

                FluidSettingsRow(title: "Accent Color", description: "Tints the soft light at the top of each page.") {
                    self.accentColorSwatches
                }
                .settingsSearchTarget(.accentColor)
            }

            self.updatesGroup
        }
    }

    /// The accent color's own values are colors, so this is the one place colors show on the page.
    private var accentColorSwatches: some View {
        HStack(spacing: 2) {
            ForEach(SettingsStore.AccentColorOption.allCases) { option in
                let isSelected = self.settings.customAccentColorHex == nil && self.settings.accentColorOption == option
                Button {
                    self.settings.accentColorOption = option
                } label: {
                    self.accentSwatch(
                        Circle().fill(LinearGradient(colors: FluidLookTint.preset(option).colors, startPoint: .topLeading, endPoint: .bottomTrailing)),
                        isSelected: isSelected
                    )
                }
                .buttonStyle(FluidHoverIconButtonStyle())
                .accessibilityLabel(option.rawValue)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(option.rawValue)
            }

            let isCustom = self.settings.customAccentColorHex != nil
            Button {
                AccentColorPanelTarget.shared.open(with: self.settings.accentColor)
            } label: {
                self.accentSwatch(
                    Circle()
                        .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .overlay(Circle().fill(self.settings.accentColor).frame(width: 7, height: 7).opacity(isCustom ? 1 : 0)),
                    isSelected: isCustom
                )
            }
            .buttonStyle(FluidHoverIconButtonStyle())
            .accessibilityLabel("Custom")
            .accessibilityAddTraits(isCustom ? .isSelected : [])
            .help("Custom")
        }
    }

    /// A swatch with a ring around the chosen one.
    private func accentSwatch(_ swatch: some View, isSelected: Bool) -> some View {
        swatch
            .frame(width: 16, height: 16)
            .padding(3)
            .overlay(Circle().strokeBorder(isSelected ? self.theme.look.text : .clear, lineWidth: 1.5))
            .frame(width: 26, height: 26)
    }

    private var updatesGroup: some View {
        FluidSettingsGroup(title: "Updates") {
            FluidSettingsRow(title: "Version \(self.currentAppVersion)", description: self.lastUpdateCheckLabel) {
                self.updateActions
            }

            if self.updater.isCheckingForUpdates || self.updater.isUpdateInProgress || self.updater.availableUpdateVersion != nil {
                FluidSettingsBlock { self.updateCheckStatus }
            }

            self.switchRow(
                title: "Automatic update checks",
                description: "Check for new versions once per hour.",
                isOn: Binding(
                    get: { self.settings.autoUpdateCheckEnabled },
                    set: { self.settings.autoUpdateCheckEnabled = $0 }
                )
            )
            self.switchRow(
                title: "Show update pop-ups",
                description: "When off, available updates still appear in the top bar and here.",
                isOn: Binding(
                    get: { self.settings.showUpdatePopups },
                    set: { self.settings.showUpdatePopups = $0 }
                )
            )
            self.switchRow(
                title: "Include beta releases",
                description: "Check stable and preview releases. Preview builds may be less reliable.",
                isOn: Binding(
                    get: { self.settings.betaReleasesEnabled },
                    set: { self.settings.betaReleasesEnabled = $0 }
                )
            )
            self.rollbackControls
        }
        .settingsSearchTarget(.automaticUpdates)
    }

    private var lastUpdateCheckLabel: String {
        self.settings.lastUpdateCheckDate.map {
            "Checked " + $0.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        } ?? "Not checked yet"
    }

    /// "View Update" is the page's one main action, and only while an update is waiting.
    private var updateActions: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Button(self.updateActionTitle) {
                if self.updater.availableUpdateVersion != nil {
                    self.updater.showAvailableUpdate()
                } else {
                    self.updater.checkForUpdatesManually()
                }
            }
            .fluidAction(self.updater.availableUpdateVersion != nil ? .primary : .secondary)
            .disabled(self.updater.isCheckingForUpdates || self.updater.isUpdateInProgress || self.isRollingBack)

            if self.updater.availableUpdateVersion != nil {
                Button("Check Again") { self.updater.checkForUpdatesManually() }
                    .fluidAction()
                    .disabled(self.updater.isCheckingForUpdates || self.updater.isUpdateInProgress || self.isRollingBack)
            }

            Button("Release Notes") {
                if let url = URL(string: "https://github.com/altic-dev/Fluid-oss/releases") {
                    NSWorkspace.shared.open(url)
                }
            }
            .fluidAction()
        }
        .fixedSize()
    }

    private var updateActionTitle: String {
        if self.updater.isUpdateInProgress { return "Installing…" }
        if self.updater.isCheckingForUpdates { return "Checking…" }
        return self.updater.availableUpdateVersion == nil ? "Check for Updates" : "View Update"
    }

    @ViewBuilder private var updateCheckStatus: some View {
        if self.updater.isCheckingForUpdates || self.updater.isUpdateInProgress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(self.updater.isUpdateInProgress ? "Installing an update…" : "Checking for updates…")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
        } else if let version = self.updater.availableUpdateVersion {
            Label("Version \(version) is available", systemImage: "arrow.down.circle")
                .fluidText(.rowTitle)
                .foregroundStyle(self.theme.look.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rollbackControls: some View {
        FluidSettingsRow(
            title: "Roll back",
            description: "Choose an earlier version. FluidVoice will restart.",
            footnote: self.rollbackStatusNote
        ) {
            VStack(alignment: .trailing, spacing: self.theme.metrics.spacing.xs) {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    FluidDropdownPicker(
                        "Rollback version",
                        selectedTitle: self.selectedRollbackTitle,
                        selection: self.$selectedRollbackVersion
                    ) {
                        Text("Choose a version").tag("")
                        if !self.rollbackVersion.isEmpty {
                            Text("\(self.rollbackVersion) · Saved on this Mac").tag("local")
                        }
                        ForEach(self.rollbackOptions, id: \.version) { option in
                            Text(option.version).tag(option.version)
                        }
                    }
                    .fluidDropdownStyle()
                    .disabled(self.isRollingBack || self.updater.isUpdateInProgress)
                    Button(self.isRollingBack ? "Rolling Back…" : "Roll Back") {
                        self.restorePreviousVersion()
                    }
                    .fluidAction()
                    .disabled(self.selectedRollbackVersion.isEmpty || self.isRollingBack || self.updater.isUpdateInProgress)
                }
                if self.rollbackVersionsError != nil {
                    Button("Try Again") { Task { await self.loadRollbackVersions() } }
                        .fluidAction()
                }
            }
            .fixedSize()
        }
    }

    /// Loading, failure or "nothing to roll back to", under the Roll back row.
    private var rollbackStatusNote: String? {
        if self.isLoadingRollbackVersions { return "Loading versions…" }
        if let error = self.rollbackVersionsError { return error }
        if self.rollbackOptions.isEmpty, self.rollbackVersion.isEmpty { return "No earlier versions are available." }
        return nil
    }

    private var selectedRollbackTitle: String {
        if self.selectedRollbackVersion == "local" { return "\(self.rollbackVersion) · Saved on this Mac" }
        return self.selectedRollbackVersion.isEmpty ? "Choose a version" : self.selectedRollbackVersion
    }

    private func loadRollbackVersions() async {
        guard !self.isLoadingRollbackVersions, !self.rollbackVersionsLoaded else { return }
        self.isLoadingRollbackVersions = true
        self.rollbackVersionsError = nil
        defer { self.isLoadingRollbackVersions = false }
        do {
            let options = try await self.updater.fetchRecentReleaseBuildOptions(
                owner: "altic-dev",
                repo: "Fluid-oss",
                limit: 12,
                includePrerelease: true,
                olderThanCurrent: true
            )
            try Task.checkCancellation()
            self.rollbackOptions = options.filter {
                $0.version.trimmingCharacters(in: CharacterSet(charactersIn: "v")) != self.rollbackVersion
            }
            self.rollbackVersionsLoaded = true
        } catch {
            self.rollbackVersionsError = self.rollbackVersion.isEmpty
                ? "Couldn't load versions. Check your connection and try again."
                : "Couldn't load online versions. Your saved version is still available."
        }
    }

    private func restorePreviousVersion() {
        guard !self.isRollingBack, !self.updater.isUpdateInProgress,
              !self.selectedRollbackVersion.isEmpty else { return }
        let useLocalBackup = self.selectedRollbackVersion == "local"
        let targetVersion = useLocalBackup ? self.rollbackVersion : self.selectedRollbackVersion
        guard !targetVersion.isEmpty else { return }
        let infoText = targetVersion
        let confirm = NSAlert()
        confirm.messageText = "Roll back to \(infoText)?"
        confirm.informativeText = "This will restore a previous app version and relaunch FluidVoice."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Roll Back")
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
                if useLocalBackup {
                    try await self.updater.rollbackToLatestBackup(expectedVersion: targetVersion)
                } else {
                    try await self.updater.installPreviousRelease(version: targetVersion)
                }
                await MainActor.run {
                    let success = NSAlert()
                    success.messageText = "Rollback Successful"
                    success.informativeText = "Rolled back to \(targetVersion). FluidVoice will relaunch shortly."
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

    private func refreshRollbackState() {
        self.rollbackVersion = SimpleUpdater.shared.latestRollbackVersion() ?? ""
        if self.selectedRollbackVersion.isEmpty, !self.rollbackVersion.isEmpty {
            self.selectedRollbackVersion = "local"
        } else if self.selectedRollbackVersion == "local", self.rollbackVersion.isEmpty {
            self.selectedRollbackVersion = ""
        }
    }
}

/// Routes the shared color panel's live changes into the custom accent setting.
@MainActor
private final class AccentColorPanelTarget: NSObject {
    static let shared = AccentColorPanelTarget()

    func open(with color: Color) {
        let panel = NSColorPanel.shared
        panel.mode = .wheel
        panel.showsAlpha = false
        panel.setTarget(nil) // avoid writing the seed color back as a custom choice
        panel.color = NSColor(color)
        panel.setTarget(self)
        panel.setAction(#selector(self.colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        SettingsStore.shared.customAccentColorHex = Color(nsColor: panel.color).hexString
    }
}

/// Observes only the recovery status, without making the entire Settings page observe history edits.
private struct LegacyHistoryRecoveryControls: View {
    @ObservedObject private var history = TranscriptionHistoryStore.shared
    @Environment(\.theme) private var theme
    @State private var isRecovering = false

    var body: some View {
        if self.history.audioPruningDeferred {
            VStack(alignment: .leading, spacing: 8) {
                Label("Audio cleanup is paused", systemImage: "exclamationmark.triangle")
                    .fluidText(.rowTitle)
                    .foregroundStyle(self.theme.look.text)
                Text("Older history needs recovery. Your recordings are being kept, even above the storage budget.")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(self.isRecovering ? "Saving recovery copy…" : "Review recovery options…", action: self.reviewRecovery)
                    .fluidAction()
                    .disabled(self.isRecovering)
            }
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("history-audio-recovery")
        }
    }

    private func reviewRecovery() {
        let alert = NSAlert()
        alert.messageText = "Resume audio cleanup?"
        alert.informativeText = """
        Restart FluidVoice first to import any readable older history. If this warning remains, save the unreadable history and all saved audio to a recovery folder and resume cleanup.

        Saved transcripts stay intact. Cleanup may remove older audio from the app, but the recovery copy keeps every saved recording and stays outside your audio budget.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save Recovery Copy and Resume")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        self.isRecovering = true
        Task { @MainActor in
            defer { self.isRecovering = false }
            do {
                let directory = try await self.history.archiveLegacyHistoryAndResumeAudioCleanup()
                NSWorkspace.shared.open(directory)
            } catch {
                let failure = NSAlert()
                failure.messageText = "Audio cleanup remains paused"
                failure.informativeText = error.localizedDescription
                failure.runModal()
            }
        }
    }
}
