//
//  ContentView.swift
//  fluid
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import Security
import SwiftUI

// MARK: - AI Processing Errors

enum AIProcessingError: LocalizedError {
    case noVerifiedProvider
    case missingAPIKey(provider: String)
    case missingModel(provider: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noVerifiedProvider:
            return "No verified AI provider selected"
        case let .missingAPIKey(provider):
            return "API key not set for \(provider)"
        case let .missingModel(provider):
            return "No model selected for \(provider)"
        case .emptyResponse:
            return "AI returned an empty response"
        }
    }

    /// Configuration errors the user can fix in AI Enhancement settings.
    var isConfigurationError: Bool {
        switch self {
        case .noVerifiedProvider, .missingAPIKey, .missingModel:
            return true
        case .emptyResponse:
            return false
        }
    }
}

// MARK: - Sidebar Item Enum

enum SidebarItem: Hashable {
    case welcome
    case voiceEngine
    case aiEnhancements
    case preferences
    case meetingTools
    case customDictionary
    case stats
    case history
    case changelog
    case feedback
    case commandMode
    case rewriteMode
}

enum PrimaryDictationShortcutEdit: Hashable {
    case add
    case replace(Int)

    var replacementIndex: Int? {
        if case let .replace(index) = self { return index }
        return nil
    }
}

enum ShortcutRecordingTarget: Hashable {
    case primaryDictation(PrimaryDictationShortcutEdit)
    case secondaryDictation
    case command
    case edit
    case cancel
    case pasteLast
    case dictationPrompt(String)
    case newPrompt

    var title: String {
        switch self {
        case .primaryDictation:
            return "Primary Dictation Shortcut"
        case .secondaryDictation:
            return "Secondary Dictation Shortcut"
        case .command:
            return "Command Mode"
        case .edit:
            return "Edit Mode"
        case .cancel:
            return "Cancel Recording"
        case .pasteLast:
            return "Paste Last Transcription"
        case .dictationPrompt:
            return "Prompt Shortcut"
        case .newPrompt:
            return "New Prompt Shortcut"
        }
    }

    var enablesFeatureOnAssignment: Bool {
        switch self {
        case .secondaryDictation, .command, .edit, .pasteLast:
            return true
        case .primaryDictation, .cancel, .dictationPrompt, .newPrompt:
            return false
        }
    }

    var promptConfigurationKey: String? {
        if case let .dictationPrompt(key) = self { return key }
        return nil
    }

    var allowsMouseShortcut: Bool {
        switch self {
        case .primaryDictation, .pasteLast:
            return true
        case .secondaryDictation, .command, .edit, .cancel, .dictationPrompt, .newPrompt:
            return false
        }
    }

    var isPrimaryDictation: Bool {
        if case .primaryDictation = self { return true }
        return false
    }

    var primaryDictationReplacementIndex: Int? {
        if case let .primaryDictation(edit) = self {
            return edit.replacementIndex
        }
        return nil
    }
}

// MARK: - Minimal FluidAudio ASR Service (finalized text, macOS)

// MARK: - Saved Provider Model

// Removed deprecated inline service and model

// NOTE: Streaming and AI response parsing is now handled by LLMClient

// swiftlint:disable type_body_length file_length
struct ContentView: View {
    private enum ActiveRecordingMode: String {
        case none
        case dictate
        case promptMode
        case edit
        case command
    }

    private enum DictationOutputRoute: String {
        case normal
        case onboardingSandbox
    }

    @EnvironmentObject private var appServices: AppServices
    @StateObject private var mouseTracker = MousePositionTracker()
    @StateObject private var commandModeService = CommandModeService()
    @StateObject private var rewriteModeService = RewriteModeService()
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @ObservedObject private var settings = SettingsStore.shared

    /// Computed properties to access shared services from AppServices container
    /// This maintains backward compatibility with the existing code while
    /// removing the duplicate service instances that cause startup crashes.
    private var asr: ASRService {
        self.appServices.asr
    }

    private var audioObserver: AudioHardwareObserver {
        self.appServices.audioObserver
    }

    @Environment(\.theme) private var theme
    @State private var hotkeyManager: GlobalHotkeyManager? = nil
    @State private var hotkeyManagerInitialized: Bool = false

    @State private var appear = false
    @State private var accessibilityEnabled = false
    @State private var primaryDictationShortcuts: [HotkeyShortcut] = SettingsStore.shared.primaryDictationShortcuts
    @State private var promptModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.promptModeHotkeyShortcut
    @State private var commandModeHotkeyShortcut: HotkeyShortcut? = SettingsStore.shared.commandModeHotkeyShortcut
    @State private var rewriteModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.rewriteModeHotkeyShortcut
    @State private var cancelRecordingHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.cancelRecordingHotkeyShortcut
    @State private var pasteLastTranscriptionHotkeyShortcut: HotkeyShortcut? = SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut
    @State private var isPasteLastTranscriptionShortcutEnabled: Bool = SettingsStore.shared.pasteLastTranscriptionShortcutEnabled
    @State private var isPromptModeShortcutEnabled: Bool = SettingsStore.shared.promptModeShortcutEnabled
    @State private var isCommandModeShortcutEnabled: Bool = SettingsStore.shared.commandModeShortcutEnabled
    @State private var isRewriteModeShortcutEnabled: Bool = SettingsStore.shared.rewriteModeShortcutEnabled
    @State private var isRecordingForRewrite: Bool = false // Track if current recording is for rewrite mode
    @State private var isRecordingForCommand: Bool = false // Track if current recording is for command mode
    @State private var promptModeOverrideText: String? // System prompt text to use when in prompt mode
    @State private var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot? = nil
    @State private var activeRecordingMode: ActiveRecordingMode = .none
    @State private var pendingAIReprocessText: String? = nil
    @State private var activeShortcutRecordingTarget: ShortcutRecordingTarget? = nil
    @State private var currentRecordingModifierKeyCodes: Set<UInt16> = []
    @State private var pendingModifierKeyCodes: Set<UInt16> = []
    @State private var pendingModifierFlags: NSEvent.ModifierFlags = []
    @State private var pendingModifierKeyCode: UInt16?
    @State private var pendingModifierOnly = false
    @State private var shortcutRecordingMessage: String? = nil
    @State private var shortcutCaptureMonitor: Any?
    @FocusState private var isTranscriptionFocused: Bool

    @State private var selectedSidebarItem: SidebarItem?
    @State private var previousSidebarItem: SidebarItem? = nil // Track previous for mode transitions
    @State private var playgroundUsed: Bool = SettingsStore.shared.playgroundUsed
    @State private var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)? = nil
    @State private var recordingPrecedingText: String = ""

    // Command Mode State
    // @State private var showCommandMode: Bool = false

    // Audio Settings Tab State
    @State private var visualizerNoiseThreshold: Double = SettingsStore.shared.visualizerNoiseThreshold
    @State private var inputDevices: [AudioDevice.Device] = []
    @State private var outputDevices: [AudioDevice.Device] = []
    @State private var selectedInputUID: String = AudioDevice.getDefaultInputDevice()?.uid ?? ""
    @State private var selectedOutputUID: String = SettingsStore.shared.preferredOutputDeviceUID ?? ""

    // AI Prompts Tab State
    @State private var aiInputText: String = ""
    @State private var aiOutputText: String = ""
    @State private var isCallingAI: Bool = false
    @State private var openAIBaseURL: String = ""

    @State private var enableDebugLogs: Bool = SettingsStore.shared.enableDebugLogs
    @State private var hotkeyMode: HotkeyActivationMode = SettingsStore.shared.hotkeyMode
    @State private var enableStreamingPreview: Bool = SettingsStore.shared.enableStreamingPreview
    @State private var copyToClipboard: Bool = SettingsStore.shared.copyTranscriptionToClipboard

    // Preferences Tab State
    @State private var launchAtStartup: Bool = SettingsStore.shared.launchAtStartup
    @State private var showInDock: Bool = SettingsStore.shared.showInDock
    @State private var showRestartPrompt: Bool = false
    @State private var didOpenAccessibilityPane: Bool = false
    private let accessibilityRestartFlagKey = "FluidVoice_AccessibilityRestartPending"
    private let hasAutoRestartedForAccessibilityKey = "FluidVoice_HasAutoRestartedForAccessibility"
    @State private var accessibilityPollingTask: Task<Void, Never>?
    @State private var accessibilityGuidePanel: NSPanel?
    @State private var accessibilityGuideMonitorTask: Task<Void, Never>?
    @State private var accessibilityGuideRequestID: UUID?
    @State private var prewarmDictationTask: Task<Void, Never>?
    @State private var overlayLifecycleID: UInt64 = 0

    private var isRecordingAnyShortcutCapture: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    // MARK: - Voice Recognition Model Management

    // Models scoped by provider (name -> [models])
    @State private var availableModelsByProvider: [String: [String]] = [:]
    @State private var selectedModelByProvider: [String: String] = [:]
    @State private var availableModels: [String] = [] // derived from currentProvider
    @State private var selectedModel: String = "" // derived from currentProvider
    @State private var showingAddModel: Bool = false
    @State private var newModelName: String = ""

    // Model Reasoning Configuration
    @State private var showingReasoningConfig: Bool = false
    @State private var editingReasoningParamName: String = "reasoning_effort"
    @State private var editingReasoningParamValue: String = "low"
    @State private var editingReasoningEnabled: Bool = false

    // MARK: - Provider Management

    @State private var providerAPIKeys: [String: String] = [:] // [providerKey: apiKey]
    @State private var currentProvider: String = "" // canonical key: "openai" | "groq" | "custom:<id>"

    @State private var savedProviders: [SettingsStore.SavedProvider] = []
    @State private var selectedProviderID: String = SettingsStore.shared.selectedProviderID
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        let layout = AnyView(
            Group {
                if self.settings.shouldShowOnboarding {
                    self.onboardingOnlyView
                } else {
                    NavigationSplitView(columnVisibility: self.$columnVisibility) {
                        self.sidebarView
                            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
                    } detail: {
                        self.detailView
                    }
                    .navigationSplitViewStyle(.balanced)
                }
            }
        )

        let tracked = layout.withMouseTracking(self.mouseTracker)
        let env = tracked.environmentObject(self.mouseTracker)
        let nav = env.onChange(of: self.menuBarManager.requestedNavigationDestination) { _, destination in
            self.handleMenuBarNavigation(destination)
        }
        let sized = nav.fluidWindowSizing(self.windowSizing)

        let observed = self.applyShortcutStateChanges(to: sized)

        return observed
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                self.refreshAccessibilityPermissionState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCustomDictionaryFromVoiceEngine)) { _ in
                self.selectedSidebarItem = .customDictionary
            }
            .onReceive(NotificationCenter.default.publisher(for: .appNavigationRequested)) { _ in
                self.handlePendingAppNavigation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dictationPromptShortcutsChanged)) { _ in
                self.hotkeyManager?.updatePromptShortcutAssignments(SettingsStore.shared.dictationPromptShortcutAssignments())
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsBackupDidRestore)) { _ in
                self.reloadSettingsStateAfterBackupRestore()
            }
            .toolbar {
                if !self.settings.shouldShowOnboarding {
                    ToolbarItemGroup(placement: .primaryAction) {
                        self.todayStatsButton

                        self.themePreferenceButton

                        Button(action: self.openIssueReportingPage) {
                            Image(systemName: "ladybug.fill")
                        }
                        .help("Report an issue")
                        .accessibilityLabel("Report an issue")
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            .overlay(alignment: .center) {}
            .alert(
                self.asr.errorTitle,
                isPresented: Binding(
                    get: { self.asr.showError },
                    set: { self.asr.showError = $0 }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(self.asr.errorMessage)
            }
            .onChange(of: self.audioObserver.changeTick) { _, _ in
                // Hardware change detected → refresh device lists
                self.refreshDevices()

                // Only sync UI with system defaults when sync is enabled
                // When sync is disabled, keep the user's preferred device selection
                if SettingsStore.shared.syncAudioDevicesWithSystem {
                    // Sync mode: Update UI to match current system defaults
                    if let sysIn = AudioDevice.getDefaultInputDevice()?.uid {
                        self.selectedInputUID = sysIn
                    }
                    if let sysOut = AudioDevice.getDefaultOutputDevice()?.uid {
                        self.selectedOutputUID = sysOut
                    }
                } else {
                    // Independent mode: Only update if preferred device is no longer available
                    if let prefIn = SettingsStore.shared.preferredInputDeviceUID,
                       inputDevices.contains(where: { $0.uid == prefIn })
                    {
                        self.selectedInputUID = prefIn
                    } else if let sysIn = AudioDevice.getDefaultInputDevice()?.uid {
                        // Fallback to system default if preferred device disconnected
                        self.selectedInputUID = sysIn
                        SettingsStore.shared.preferredInputDeviceUID = sysIn
                    }

                    if let prefOut = SettingsStore.shared.preferredOutputDeviceUID,
                       outputDevices.contains(where: { $0.uid == prefOut })
                    {
                        self.selectedOutputUID = prefOut
                    } else if let sysOut = AudioDevice.getDefaultOutputDevice()?.uid {
                        // Fallback to system default if preferred device disconnected
                        self.selectedOutputUID = sysOut
                        SettingsStore.shared.preferredOutputDeviceUID = sysOut
                    }
                }
            }
            .onDisappear {
                Task { await self.asr.stopWithoutTranscription() }
                self.cancelPrewarmDictationIfNeeded()
                // Note: Overlay lifecycle is now managed by MenuBarManager
                // Note: NotchContentState handlers capture self (a struct value copy) and are
                // intentionally kept alive so the overlay remains fully functional when the
                // settings window is closed. No retain cycle risk since ContentView is a value type.

                // Stop accessibility polling
                self.finishAccessibilityPermissionFlow()
                self.removeShortcutCaptureMonitor()
            }
            .onChange(of: self.primaryDictationShortcuts) { _, newValue in
                SettingsStore.shared.primaryDictationShortcuts = newValue
                let storedShortcuts = SettingsStore.shared.primaryDictationShortcuts
                if storedShortcuts != newValue {
                    self.primaryDictationShortcuts = storedShortcuts
                    return
                }

                let display = storedShortcuts.map(\.displayString).joined(separator: ", ")
                DebugLogger.shared.debug("Primary dictation shortcuts changed to \(display)", source: "ContentView")
                self.hotkeyManager?.updatePrimaryShortcuts(storedShortcuts)

                // Update initialization status after shortcut change
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                    DebugLogger.shared.debug(
                        "Hotkey manager initialized: \(self.hotkeyManagerInitialized)",
                        source: "ContentView"
                    )
                }
            }
            .onChange(of: self.selectedSidebarItem) { _, newValue in
                self.handleModeTransition(from: self.previousSidebarItem, to: newValue)
                self.previousSidebarItem = newValue
            }
    }

    private func applyShortcutStateChanges<Content: View>(to view: Content) -> some View {
        view
            .onAppear {
                self.handleContentAppear()
            }
            .onChange(of: self.accessibilityEnabled) { _, enabled in
                if enabled {
                    self.finishAccessibilityPermissionFlow()
                }

                if enabled && self.hotkeyManager != nil && !self.hotkeyManagerInitialized {
                    DebugLogger.shared.debug("Accessibility enabled, reinitializing hotkey manager", source: "ContentView")
                    self.hotkeyManager?.reinitialize()
                }
            }
            .onChange(of: self.selectedModel) { _, newValue in
                if newValue != "__ADD_MODEL__" {
                    self.selectedModelByProvider[self.currentProvider] = newValue
                    SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider
                }
            }
            .onChange(of: self.selectedProviderID) { _, newValue in
                SettingsStore.shared.selectedProviderID = newValue
            }
            .onChange(of: self.activeShortcutRecordingTarget) { _, _ in
                self.hotkeyManager?.resetModifierOnlyShortcutTracking()
            }
            .onChange(of: self.commandModeHotkeyShortcut) { _, newValue in
                SettingsStore.shared.commandModeHotkeyShortcut = newValue
                self.hotkeyManager?.updateCommandModeShortcut(newValue)
            }
            .onChange(of: self.isPromptModeShortcutEnabled) { newValue in
                self.handlePromptShortcutEnabledChange(newValue)
            }
            .onChange(of: self.isCommandModeShortcutEnabled) { newValue in
                self.handleCommandShortcutEnabledChange(newValue)
            }
            .onChange(of: self.isRewriteModeShortcutEnabled) { newValue in
                self.handleRewriteShortcutEnabledChange(newValue)
            }
            .onChange(of: self.pasteLastTranscriptionHotkeyShortcut) { _, newValue in
                // The hotkey manager reads this value live from SettingsStore, so persisting is enough.
                SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut = newValue
            }
            .onChange(of: self.isPasteLastTranscriptionShortcutEnabled) { newValue in
                self.handlePasteLastTranscriptionShortcutEnabledChange(newValue)
            }
    }

    private func handlePasteLastTranscriptionShortcutEnabledChange(_ isEnabled: Bool) {
        SettingsStore.shared.pasteLastTranscriptionShortcutEnabled = isEnabled
        if !isEnabled, self.activeShortcutRecordingTarget == .pasteLast {
            self.clearShortcutRecordingMode()
        }
    }

    private func handlePromptShortcutEnabledChange(_ isEnabled: Bool) {
        SettingsStore.shared.promptModeShortcutEnabled = isEnabled
        self.hotkeyManager?.updatePromptModeShortcutEnabled(isEnabled)

        if !isEnabled {
            if self.activeShortcutRecordingTarget == .secondaryDictation {
                self.clearShortcutRecordingMode()
            }

            if self.activeRecordingMode == .promptMode {
                if self.asr.isRunning {
                    Task { await self.asr.stopWithoutTranscription() }
                }
                self.cancelPrewarmDictationIfNeeded()
                self.clearActiveRecordingMode()
                self.menuBarManager.setOverlayMode(.dictation)
            }
        }
    }

    private func handleCommandShortcutEnabledChange(_ isEnabled: Bool) {
        SettingsStore.shared.commandModeShortcutEnabled = isEnabled
        self.hotkeyManager?.updateCommandModeShortcutEnabled(isEnabled)

        if !isEnabled {
            if self.activeShortcutRecordingTarget == .command {
                self.clearShortcutRecordingMode()
            }

            if self.activeRecordingMode == .command {
                if self.asr.isRunning {
                    Task { await self.asr.stopWithoutTranscription() }
                }
                self.cancelPrewarmDictationIfNeeded()
                self.clearActiveRecordingMode()
                self.menuBarManager.setOverlayMode(.dictation)
            }
        }
    }

    private func handleRewriteShortcutEnabledChange(_ isEnabled: Bool) {
        SettingsStore.shared.rewriteModeShortcutEnabled = isEnabled
        self.hotkeyManager?.updateRewriteModeShortcutEnabled(isEnabled)

        if !isEnabled {
            if self.activeShortcutRecordingTarget == .edit {
                self.clearShortcutRecordingMode()
            }

            if self.activeRecordingMode == .edit {
                if self.asr.isRunning {
                    Task { await self.asr.stopWithoutTranscription() }
                }
                self.cancelPrewarmDictationIfNeeded()
                self.clearActiveRecordingMode()
                self.rewriteModeService.clearState()
                self.menuBarManager.setOverlayMode(.dictation)
            }
        }
    }

    private func handleContentAppear() {
        self.appear = true
        self.refreshAccessibilityPermissionState()

        self.handleMenuBarNavigation(self.menuBarManager.requestedNavigationDestination)
        if UserDefaults.standard.bool(forKey: self.accessibilityRestartFlagKey) {
            UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
            self.showRestartPrompt = false
        }

        if self.accessibilityEnabled {
            self.finishAccessibilityPermissionFlow()
        }

        if self.selectedSidebarItem == nil {
            let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
            self.selectedSidebarItem = isOnboarded ? .preferences : .welcome
        }
        self.handlePendingAppNavigation()

        if !self.accessibilityEnabled {
            UserDefaults.standard.set(false, forKey: self.hasAutoRestartedForAccessibilityKey)
        }

        self.menuBarManager.initializeMenuBar()
        self.scheduleDelayedAudioInitialization()
        self.configureNotchCallbacks()
        self.startAccessibilityPolling()
        self.initializeHotkeyManagerIfNeeded()

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self.preloadASRModel()
        }

        self.loadProviderState()
        self.installShortcutCaptureMonitor()
    }

    private func scheduleDelayedAudioInitialization() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            DebugLogger.shared.info("🚦 Startup delay complete, signaling UI ready...", source: "ContentView")
            self.appServices.signalUIReady()

            DebugLogger.shared.info("🔊 Starting delayed audio initialization...", source: "ContentView")
            self.audioObserver.startObserving()
            self.asr.initialize()
            self.menuBarManager.configure(asrService: self.appServices.asr)
            self.refreshDevices()

            if self.selectedInputUID.isEmpty, let defIn = AudioDevice.getDefaultInputDevice()?.uid {
                self.selectedInputUID = defIn
            }
            if self.selectedOutputUID.isEmpty, let defOut = AudioDevice.getDefaultOutputDevice()?.uid {
                self.selectedOutputUID = defOut
            }

            if let systemInputUID = AudioDevice.getDefaultInputDevice()?.uid,
               self.inputDevices.contains(where: { $0.uid == systemInputUID })
            {
                self.selectedInputUID = systemInputUID
            }

            if let prefOut = SettingsStore.shared.preferredOutputDeviceUID,
               !prefOut.isEmpty,
               outputDevices.first(where: { $0.uid == prefOut }) != nil
            {
                self.selectedOutputUID = prefOut
            }

            DebugLogger.shared.info("✅ Audio subsystems initialized", source: "ContentView")
        }
    }

    private func configureNotchCallbacks() {
        NotchOverlayManager.shared.onNotchClicked = {
            guard NotchOverlayManager.shared.canHandleNotchCommandTap else { return }
            if NotchOverlayManager.shared.canShowExpandedCommandOutput,
               !NotchContentState.shared.commandConversationHistory.isEmpty
            {
                NotchOverlayManager.shared.showExpandedCommandOutput()
            }
        }

        NotchOverlayManager.shared.onCommandFollowUp = { [weak commandModeService] text in
            guard NotchOverlayManager.shared.allowsCommandNotchActions else { return }
            await commandModeService?.processFollowUpCommand(text)
        }

        NotchOverlayManager.shared.onNewChat = { [weak commandModeService] in
            guard NotchOverlayManager.shared.allowsCommandNotchActions else { return }
            commandModeService?.createNewChat()
        }

        NotchOverlayManager.shared.onSwitchChat = { [weak commandModeService] chatID in
            guard NotchOverlayManager.shared.allowsCommandNotchActions else { return }
            commandModeService?.switchToChat(id: chatID)
        }

        NotchOverlayManager.shared.onClearChat = { [weak commandModeService] in
            guard NotchOverlayManager.shared.allowsCommandNotchActions else { return }
            commandModeService?.deleteCurrentChat()
        }
    }

    private func loadProviderState() {
        self.selectedProviderID = SettingsStore.shared.selectedProviderID
        self.updateCurrentProvider()

        self.enableDebugLogs = SettingsStore.shared.enableDebugLogs
        self.availableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        self.selectedModelByProvider = SettingsStore.shared.selectedModelByProvider
        self.providerAPIKeys = SettingsStore.shared.providerAPIKeys
        self.savedProviders = SettingsStore.shared.savedProviders

        var normalized: [String: [String]] = [:]
        for (key, models) in self.availableModelsByProvider {
            let lower = key.lowercased()
            let newKey = ModelRepository.shared.isBuiltIn(lower) ? lower : (key.hasPrefix("custom:") ? key : "custom:\(key)")
            let clean = Array(Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
            if !clean.isEmpty {
                normalized[newKey] = clean
            }
        }
        self.availableModelsByProvider = normalized
        SettingsStore.shared.availableModelsByProvider = normalized

        var normalizedSel: [String: String] = [:]
        for (key, model) in self.selectedModelByProvider {
            let lower = key.lowercased()
            let newKey = ModelRepository.shared.isBuiltIn(lower) ? lower : (key.hasPrefix("custom:") ? key : "custom:\(key)")
            if let list = normalized[newKey], list.contains(model) {
                normalizedSel[newKey] = model
            }
        }
        self.selectedModelByProvider = normalizedSel
        SettingsStore.shared.selectedModelByProvider = normalizedSel

        if let saved = savedProviders.first(where: { $0.id == selectedProviderID }) {
            self.availableModels = saved.models
            self.openAIBaseURL = saved.baseURL
        } else if let stored = availableModelsByProvider[currentProvider], !stored.isEmpty {
            self.availableModels = stored
        } else {
            self.availableModels = ModelRepository.shared.defaultModels(for: self.providerKey(for: self.selectedProviderID))
        }

        if let sel = selectedModelByProvider[currentProvider], availableModels.contains(sel) {
            self.selectedModel = sel
        } else if let first = availableModels.first {
            self.selectedModel = first
        }
    }

    private func installShortcutCaptureMonitor() {
        self.removeShortcutCaptureMonitor()
        self.shortcutCaptureMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            self.handleShortcutCaptureEvent(event)
        }
    }

    private func removeShortcutCaptureMonitor() {
        guard let monitor = self.shortcutCaptureMonitor else { return }
        NSEvent.removeMonitor(monitor)
        self.shortcutCaptureMonitor = nil
    }

    private func handleShortcutCaptureEvent(_ event: NSEvent) -> NSEvent? {
        let eventModifiers = event.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        let isRecordingAnyShortcut = self.isRecordingAnyShortcutCapture
        let recordingTarget = self.activeShortcutRecordingTarget

        if event.type == .keyDown {
            return self.handleShortcutKeyDownEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        } else if event.type == .flagsChanged {
            return self.handleShortcutFlagsChangedEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        } else if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            return self.handleShortcutMouseDownEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        }

        return event
    }

    private func handleShortcutKeyDownEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            if self.cancelRecordingHotkeyShortcut.matches(keyCode: event.keyCode, modifiers: eventModifiers),
               self.handleCancelShortcut()
            {
                return nil
            }
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let keyCode = event.keyCode
        if keyCode == 53, recordingTarget != .cancel {
            DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling shortcut recording", source: "ContentView")
            self.clearShortcutRecordingMode()
            return nil
        }

        let newShortcut = HotkeyShortcut(keyCode: keyCode, modifierFlags: self.pendingModifierFlags.union(eventModifiers))
        DebugLogger.shared.debug("NSEvent monitor: Recording new shortcut: \(newShortcut.displayString)", source: "ContentView")

        if let recordingTarget,
           let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
        {
            self.shortcutRecordingMessage = conflictMessage
            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
            return nil
        }

        self.shortcutRecordingMessage = nil
        if let recordingTarget {
            self.assignRecordedShortcut(newShortcut, to: recordingTarget)
        }
        self.resetPendingShortcutState()
        DebugLogger.shared.debug("NSEvent monitor: Finished recording shortcut", source: "ContentView")
        return nil
    }

    private func handleShortcutMouseDownEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let newShortcut = HotkeyShortcut(mouseButton: event.buttonNumber, modifierFlags: self.pendingModifierFlags.union(eventModifiers))
        DebugLogger.shared.debug("NSEvent monitor: Recording new mouse shortcut: \(newShortcut.displayString)", source: "ContentView")

        if newShortcut.isUnmodifiedLeftOrRightClick, let mouseButton = newShortcut.mouseButton {
            self.shortcutRecordingMessage = "\(HotkeyShortcut.mouseButtonToString(mouseButton)) needs a modifier key"
            self.resetPendingShortcutState()
            return event
        }

        if let recordingTarget,
           let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
        {
            self.shortcutRecordingMessage = conflictMessage
            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Mouse shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
            return nil
        }

        self.shortcutRecordingMessage = nil
        if let recordingTarget {
            self.assignRecordedShortcut(newShortcut, to: recordingTarget)
        }
        self.resetPendingShortcutState()
        DebugLogger.shared.debug("NSEvent monitor: Finished recording mouse shortcut", source: "ContentView")
        return nil
    }

    private func handleShortcutFlagsChangedEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let changedModifierFlag = HotkeyShortcut.modifierFlag(forKeyCode: event.keyCode)

        if eventModifiers.isEmpty {
            if self.pendingModifierOnly, let modifierKeyCode = pendingModifierKeyCode {
                let newShortcut = HotkeyShortcut(
                    keyCode: modifierKeyCode,
                    modifierFlags: self.pendingModifierFlags,
                    modifierKeyCodes: Array(self.pendingModifierKeyCodes)
                )
                DebugLogger.shared.debug("NSEvent monitor: Recording modifier-only shortcut: \(newShortcut.displayString)", source: "ContentView")

                if let recordingTarget,
                   let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
                {
                    self.shortcutRecordingMessage = conflictMessage
                    self.resetPendingShortcutState()
                    DebugLogger.shared.debug("NSEvent monitor: Modifier shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
                    return nil
                }

                self.shortcutRecordingMessage = nil
                if let recordingTarget {
                    self.assignRecordedShortcut(newShortcut, to: recordingTarget)
                }
                self.resetPendingShortcutState()
                DebugLogger.shared.debug("NSEvent monitor: Finished recording modifier shortcut", source: "ContentView")
                return nil
            }

            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Modifiers released without recording, continuing to wait", source: "ContentView")
            return nil
        }

        if let changedModifierFlag {
            let isRelease = self.currentRecordingModifierKeyCodes.contains(event.keyCode)

            if isRelease {
                self.currentRecordingModifierKeyCodes.remove(event.keyCode)
            } else if eventModifiers.contains(changedModifierFlag) {
                self.currentRecordingModifierKeyCodes.insert(event.keyCode)
                self.pendingModifierKeyCodes.insert(event.keyCode)
                self.pendingModifierFlags = self.pendingModifierFlags.union(eventModifiers)
                self.pendingModifierKeyCode = event.keyCode
                self.pendingModifierOnly = true
                DebugLogger.shared.debug("NSEvent monitor: Modifier key pressed during recording, pending modifiers: \(self.pendingModifierFlags)", source: "ContentView")
            }
        }
        return nil
    }

    // MARK: - Analytics helpers

    private func currentDictationAIModelInfo() -> (provider: String?, model: String?) {
        let providerID = SettingsStore.shared.selectedProviderID

        if providerID == "apple-intelligence" {
            return (provider: "apple-intelligence", model: "apple-intelligence")
        }

        let storedSelectedModelByProvider = SettingsStore.shared.selectedModelByProvider
        let storedSavedProviders = SettingsStore.shared.savedProviders

        let derivedProvider: String
        let derivedModel: String

        if let saved = storedSavedProviders.first(where: { $0.id == providerID }) {
            derivedProvider = "custom:\(saved.id)"
            derivedModel = storedSelectedModelByProvider[derivedProvider] ?? saved.models.first ?? ""
        } else if providerID == "openai" {
            derivedProvider = "openai"
            derivedModel = storedSelectedModelByProvider["openai"] ?? "gpt-4.1"
        } else if providerID == "groq" {
            derivedProvider = "groq"
            derivedModel = storedSelectedModelByProvider["groq"] ?? "llama-3.3-70b-versatile"
        } else {
            derivedProvider = providerID
            derivedModel = storedSelectedModelByProvider[providerID] ?? ""
        }

        let providerOut = derivedProvider.isEmpty ? nil : derivedProvider
        let modelOut = derivedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : derivedModel
        return (provider: providerOut, model: modelOut)
    }

    private func currentTranscriptionModelInfo() -> (provider: String, model: String) {
        let selectedModel = SettingsStore.shared.selectedSpeechModel
        return (
            provider: selectedModel.provider.rawValue.lowercased(),
            model: selectedModel.rawValue
        )
    }

    // MARK: - Mode Transition Handler

    /// Centralized handler for sidebar mode transitions to ensure proper cleanup and state management
    private func handleModeTransition(from oldValue: SidebarItem?, to newValue: SidebarItem?) {
        DebugLogger.shared.debug("Mode transition: \(String(describing: oldValue)) → \(String(describing: newValue))", source: "ContentView")

        // Clean up state from the previous mode
        if let old = oldValue {
            switch old {
            case .commandMode:
                // Close expanded command output notch if visible
                if NotchOverlayManager.shared.isCommandOutputExpanded {
                    DebugLogger.shared.debug("Closing expanded command notch on mode transition", source: "ContentView")
                    NotchOverlayManager.shared.hideExpandedCommandOutput()
                }
                // Note: We don't clear command history here - user may want to return to it

            case .rewriteMode:
                // Clear rewrite state when leaving
                self.rewriteModeService.clearState()

            default:
                break
            }
        }

        // Set up state for the new mode
        if let new = newValue {
            switch new {
            case .commandMode:
                self.menuBarManager.setOverlayMode(.command)

            case .rewriteMode:
                self.menuBarManager.setOverlayMode(.edit)

            default:
                // For all other views, set to dictation mode
                self.menuBarManager.setOverlayMode(.dictation)
            }
        } else {
            // If newValue is nil, default to dictation
            self.menuBarManager.setOverlayMode(.dictation)
        }
    }

    @MainActor
    private func handleMenuBarNavigation(_ destination: MenuBarNavigationDestination?) {
        guard let destination else { return }
        defer { menuBarManager.requestedNavigationDestination = nil }
        guard !self.settings.shouldShowOnboarding else { return }

        switch destination {
        case .customDictionary:
            self.selectedSidebarItem = .customDictionary
        case .preferences:
            self.selectedSidebarItem = .preferences
        }
    }

    private func handlePendingAppNavigation() {
        guard let destination = AppNavigationRouter.shared.consumePendingDestination() else { return }

        switch destination {
        case .aiEnhancements:
            self.selectedSidebarItem = .aiEnhancements
        case .history:
            self.selectedSidebarItem = .history
        }
    }

    private func resetPendingShortcutState() {
        self.currentRecordingModifierKeyCodes = []
        self.pendingModifierKeyCodes = []
        self.pendingModifierFlags = []
        self.pendingModifierKeyCode = nil
        self.pendingModifierOnly = false
    }

    private func shortcutConflictMessage(for shortcut: HotkeyShortcut, target: ShortcutRecordingTarget) -> String? {
        if shortcut.isMouseShortcut {
            guard target.allowsMouseShortcut else {
                return "Mouse clicks can only be assigned to Primary Dictation or Paste Last Transcription"
            }

            if shortcut.isUnmodifiedLeftOrRightClick, let mouseButton = shortcut.mouseButton {
                return "\(HotkeyShortcut.mouseButtonToString(mouseButton)) needs a modifier key"
            }
        }

        let replacingPrimaryIndex = target.primaryDictationReplacementIndex
        for (index, configuredShortcut) in self.primaryDictationShortcuts.enumerated() where replacingPrimaryIndex != index {
            if configuredShortcut == shortcut {
                return "Duplicate with Primary Dictation Shortcut"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps Primary Dictation Shortcut — use a different modifier key"
            }
        }

        var configuredShortcuts: [(ShortcutRecordingTarget, HotkeyShortcut)] = [
            (.edit, self.rewriteModeHotkeyShortcut),
            (.cancel, self.cancelRecordingHotkeyShortcut),
        ]
        if self.isPromptModeShortcutEnabled {
            configuredShortcuts.append((.secondaryDictation, self.promptModeHotkeyShortcut))
        }
        let optionalConfiguredShortcuts: [(ShortcutRecordingTarget, HotkeyShortcut?)] = [
            (.command, self.commandModeHotkeyShortcut),
            (.pasteLast, self.pasteLastTranscriptionHotkeyShortcut),
        ]

        for (otherTarget, configuredShortcut) in configuredShortcuts where otherTarget != target {
            if configuredShortcut == shortcut {
                return "Duplicate with \(otherTarget.title)"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps \(otherTarget.title) — use a different modifier key"
            }
        }
        for (otherTarget, configuredShortcut) in optionalConfiguredShortcuts where otherTarget != target {
            guard let configuredShortcut else { continue }
            if configuredShortcut == shortcut {
                return "Duplicate with \(otherTarget.title)"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps \(otherTarget.title) — use a different modifier key"
            }
        }

        let targetPromptKey = target.promptConfigurationKey
        for assignment in SettingsStore.shared.dictationPromptShortcutAssignments() {
            guard let key = SettingsStore.shared.dictationPromptConfigurationKey(for: assignment.selection),
                  key != targetPromptKey
            else {
                continue
            }
            if assignment.shortcut == shortcut {
                return "Duplicate with Prompt Shortcut"
            }
            if shortcut.conflictsWith(assignment.shortcut) {
                return "Overlaps Prompt Shortcut — use a different modifier key"
            }
        }

        return nil
    }

    private func assignRecordedShortcut(_ shortcut: HotkeyShortcut, to target: ShortcutRecordingTarget) {
        self.applyRecordedShortcut(shortcut, to: target)
        if target.enablesFeatureOnAssignment {
            self.setShortcutTargetEnabled(true, for: target)
        }
        self.setShortcutRecording(false, for: target)
    }

    private func applyRecordedShortcut(_ shortcut: HotkeyShortcut, to target: ShortcutRecordingTarget) {
        switch target {
        case let .primaryDictation(edit):
            self.applyPrimaryDictationShortcut(shortcut, edit: edit)
        case .secondaryDictation:
            self.promptModeHotkeyShortcut = shortcut
            SettingsStore.shared.promptModeHotkeyShortcut = shortcut
            self.hotkeyManager?.updatePromptModeShortcut(shortcut)
        case .command:
            self.commandModeHotkeyShortcut = shortcut
            SettingsStore.shared.commandModeHotkeyShortcut = shortcut
            self.hotkeyManager?.updateCommandModeShortcut(shortcut)
        case .edit:
            self.rewriteModeHotkeyShortcut = shortcut
            SettingsStore.shared.rewriteModeHotkeyShortcut = shortcut
            self.hotkeyManager?.updateRewriteModeShortcut(shortcut)
        case .cancel:
            self.cancelRecordingHotkeyShortcut = shortcut
            SettingsStore.shared.cancelRecordingHotkeyShortcut = shortcut
        case .pasteLast:
            // The hotkey manager reads this shortcut directly from SettingsStore, so no manager update is needed.
            self.pasteLastTranscriptionHotkeyShortcut = shortcut
            SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut = shortcut
        case let .dictationPrompt(key):
            guard let selection = SettingsStore.shared.dictationPromptSelection(forConfigurationKey: key) else { return }
            var configuration = SettingsStore.shared.dictationPromptConfiguration(for: selection)
            configuration.shortcut = shortcut
            SettingsStore.shared.setDictationPromptConfiguration(configuration, for: selection)
            self.hotkeyManager?.updatePromptShortcutAssignments(SettingsStore.shared.dictationPromptShortcutAssignments())
        case .newPrompt:
            NotificationCenter.default.post(
                name: .newPromptShortcutRecorded,
                object: nil,
                userInfo: ["shortcut": shortcut]
            )
        }
    }

    private func applyPrimaryDictationShortcut(_ shortcut: HotkeyShortcut, edit: PrimaryDictationShortcutEdit) {
        var shortcuts = self.primaryDictationShortcuts
        switch edit {
        case .add:
            shortcuts.append(shortcut)
        case let .replace(index):
            if shortcuts.indices.contains(index) {
                shortcuts[index] = shortcut
            } else {
                shortcuts.append(shortcut)
            }
        }
        self.primaryDictationShortcuts = shortcuts
    }

    private func setShortcutTargetEnabled(_ enabled: Bool, for target: ShortcutRecordingTarget) {
        switch target {
        case .secondaryDictation:
            self.isPromptModeShortcutEnabled = enabled
            SettingsStore.shared.promptModeShortcutEnabled = enabled
            self.hotkeyManager?.updatePromptModeShortcutEnabled(enabled)
        case .command:
            self.isCommandModeShortcutEnabled = enabled
            SettingsStore.shared.commandModeShortcutEnabled = enabled
            self.hotkeyManager?.updateCommandModeShortcutEnabled(enabled)
        case .edit:
            self.isRewriteModeShortcutEnabled = enabled
            SettingsStore.shared.rewriteModeShortcutEnabled = enabled
            self.hotkeyManager?.updateRewriteModeShortcutEnabled(enabled)
        case .pasteLast:
            self.isPasteLastTranscriptionShortcutEnabled = enabled
            SettingsStore.shared.pasteLastTranscriptionShortcutEnabled = enabled
        case .primaryDictation, .cancel, .dictationPrompt, .newPrompt:
            break
        }
    }

    private func setShortcutRecording(_ isRecording: Bool, for target: ShortcutRecordingTarget) {
        if isRecording {
            self.activeShortcutRecordingTarget = target
        } else if self.activeShortcutRecordingTarget == target {
            self.activeShortcutRecordingTarget = nil
        }
    }

    private func clearShortcutRecordingMode() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.resetPendingShortcutState()
    }

    private func openIssueReportingPage() {
        guard let url = URL(string: "https://github.com/altic-dev/Fluid-oss/issues/new/choose") else { return }
        NSWorkspace.shared.open(url)
    }

    private var sidebarView: some View {
        List(selection: self.$selectedSidebarItem) {
            Section {
                self.sidebarNavigationLink(.preferences, title: "Settings", systemImage: "gearshape.fill")
                self.sidebarNavigationLink(.voiceEngine, title: "Voice Engine", systemImage: "waveform")
                self.sidebarNavigationLink(.aiEnhancements, title: "AI Enhancement", systemImage: "brain")
                self.sidebarNavigationLink(.customDictionary, title: "Custom Dictionary", systemImage: "text.book.closed.fill")
            } header: {
                self.sidebarSectionHeader("Configure")
            }

            Section {
                self.sidebarNavigationLink(.commandMode, title: "Command Mode", systemImage: "terminal.fill")
                self.sidebarNavigationLink(.meetingTools, title: "File Transcription", systemImage: "doc.text.fill")
            } header: {
                self.sidebarSectionHeader("Use")
            }

            Section {
                self.sidebarNavigationLink(.history, title: "History", systemImage: "clock.arrow.circlepath")
                self.sidebarNavigationLink(.stats, title: "Stats", systemImage: "chart.bar.fill")
            } header: {
                self.sidebarSectionHeader("Activity")
            }

            Section {
                self.sidebarNavigationLink(.welcome, title: "Getting Started", systemImage: "house.fill")
                self.sidebarNavigationLink(.changelog, title: "Change logs", systemImage: "doc.text.magnifyingglass")
                self.sidebarNavigationLink(.feedback, title: "Feedback", systemImage: "envelope.fill")
            } header: {
                self.sidebarSectionHeader("Help")
            }
        }
        .listStyle(.sidebar)
        .animation(nil, value: self.selectedSidebarItem)
        .navigationTitle("FluidVoice")
        .tint(self.theme.palette.accent)
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(self.theme.typography.sidebarSection)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.top, self.theme.metrics.spacing.sm)
            .padding(.bottom, self.theme.metrics.spacing.xs)
    }

    private func sidebarNavigationLink(_ item: SidebarItem, title: String, systemImage: String) -> some View {
        NavigationLink(value: item) {
            Label(title, systemImage: systemImage)
                .font(self.theme.typography.sidebarItem)
                .frame(minHeight: 24, alignment: .leading)
                .padding(.vertical, self.theme.metrics.spacing.xs / 2)
        }
    }

    private var themePreferenceButton: some View {
        Button {
            self.settings.themePreference = self.nextThemePreference(after: self.settings.themePreference)
        } label: {
            Image(systemName: self.settings.themePreference.systemImageName)
        }
        .help("Theme: \(self.settings.themePreference.displayName)")
        .accessibilityLabel("Theme")
    }

    private func nextThemePreference(after preference: SettingsStore.ThemePreference) -> SettingsStore.ThemePreference {
        switch preference {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }

    private var todayStatsButton: some View {
        TodayStatsToolbarButton(typingWPM: self.settings.userTypingWPM) {
            self.selectedSidebarItem = .stats
        }
    }

    private var detailView: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            self.detailContent
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
    }

    private var detailContent: AnyView {
        switch self.selectedSidebarItem ?? .welcome {
        case .welcome:
            return AnyView(self.welcomeView)
        case .voiceEngine:
            return AnyView(VoiceEngineSettingsScreen(
                appServices: self.appServices,
                theme: self.theme
            ))
        case .aiEnhancements:
            return AnyView(AIEnhancementSettingsScreen(
                menuBarManager: self.menuBarManager,
                theme: self.theme,
                activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                shortcutRecordingMessage: self.$shortcutRecordingMessage
            ))
        case .preferences:
            return AnyView(self.preferencesView)
        case .meetingTools:
            return AnyView(self.meetingToolsView)
        case .customDictionary:
            return AnyView(CustomDictionaryView())
        case .stats:
            return AnyView(self.statsView)
        case .feedback:
            return AnyView(FeedbackView())
        case .changelog:
            return AnyView(ChangelogView())
        case .commandMode:
            return AnyView(self.commandModeView)
        case .rewriteMode:
            return AnyView(self.rewriteModeView)
        case .history:
            return AnyView(TranscriptionHistoryView())
        }
    }

    private var onboardingOnlyView: some View {
        OnboardingFlowView(
            currentStep: Binding(
                get: { self.settings.onboardingCurrentStep },
                set: { self.settings.onboardingCurrentStep = $0 }
            ),
            accessibilityEnabled: self.accessibilityEnabled,
            accessibilitySetupInProgress: self.didOpenAccessibilityPane,
            markAISkipped: {
                self.settings.onboardingAISkipped = true
                self.settings.setDictationPromptSelection(.off)
            },
            finishOnboarding: {
                self.completeOnboardingIfPossible()
            },
            finishOnboardingAtGettingStarted: {
                self.completeOnboardingIfPossible(selecting: .welcome)
            },
            openAIEnhancementSettingsFromOnboarding: {
                self.completeOnboardingForAIProviderSetup()
            },
            openAccessibilitySettings: self.openAccessibilitySettings,
            restartApp: self.restartApp,
            menuBarManager: self.menuBarManager,
            activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
            shortcutRecordingMessage: self.$shortcutRecordingMessage,
            theme: self.theme
        )
        .environmentObject(self.appServices)
    }

    // MARK: - Welcome Guide

    private var welcomeView: some View {
        WelcomeView(
            selectedSidebarItem: self.$selectedSidebarItem,
            playgroundUsed: self.$playgroundUsed,
            isTranscriptionFocused: self.$isTranscriptionFocused,
            accessibilityEnabled: self.accessibilityEnabled,
            stopAndProcessTranscription: { await self.stopAndProcessTranscription() },
            startRecording: self.startRecording,
            openAccessibilitySettings: self.openAccessibilitySettings,
            restartApp: self.restartApp
        )
    }

    // MARK: - Microphone Permission View (Kept inline for RecordingView)

    private var microphonePermissionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(self.asr.micStatus == .authorized ? self.theme.palette.success : self.theme.palette.warning)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(self.labelFor(status: self.asr.micStatus))
                        .fontWeight(.medium)
                        .foregroundStyle(self.asr.micStatus == .authorized ? self.theme.palette.primaryText : self.theme.palette.warning)

                    if self.asr.micStatus != .authorized {
                        Text("Microphone access is required for voice recording")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                self.microphoneActionButton
            }

            // Step-by-step instructions when microphone is not authorized
            if self.asr.micStatus != .authorized {
                self.microphoneInstructionsView
            }
        }
    }

    private var windowSizing: FluidWindowSizing {
        let window = self.theme.metrics.window
        if self.settings.shouldShowOnboarding {
            return .minimum(width: window.onboardingMinWidth, height: window.onboardingMinHeight)
        }
        return .minimum(width: window.mainMinWidth, height: window.mainMinHeight)
    }

    private var microphoneActionButton: some View {
        Group {
            if self.asr.micStatus == .notDetermined {
                Button {
                    self.asr.requestMicAccess()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                        Text("Grant Access")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            } else if self.asr.micStatus == .denied {
                Button {
                    self.asr.openSystemSettingsForMic()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gear")
                        Text("Open Settings")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            }
        }
    }

    private var microphoneInstructionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(self.theme.palette.accent)
                    .font(self.theme.typography.caption)
                Text("How to enable microphone access:")
                    .font(self.theme.typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                if self.asr.micStatus == .notDetermined {
                    self.instructionStep(number: "1", text: "Click **Grant Access** above")
                    self.instructionStep(number: "2", text: "Choose **Allow** in the system dialog")
                } else if self.asr.micStatus == .denied {
                    self.instructionStep(number: "1", text: "Click **Open Settings** above")
                    self.instructionStep(number: "2", text: "Find **FluidVoice** in the microphone list")
                    self.instructionStep(number: "3", text: "Toggle **FluidVoice ON** to allow access")
                }
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(self.theme.palette.accent.opacity(0.12))
        .cornerRadius(8)
    }

    private func instructionStep(number: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(number + ".")
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.theme.palette.accent)
                .fontWeight(.semibold)
                .frame(width: 16)
            Text(text)
                .font(self.theme.typography.caption)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Preferences View

    private var preferencesView: some View {
        SettingsView(
            appear: self.$appear,
            visualizerNoiseThreshold: self.$visualizerNoiseThreshold,
            selectedInputUID: self.$selectedInputUID,
            selectedOutputUID: self.$selectedOutputUID,
            inputDevices: self.$inputDevices,
            outputDevices: self.$outputDevices,
            accessibilityEnabled: self.$accessibilityEnabled,
            primaryDictationShortcuts: self.$primaryDictationShortcuts,
            activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
            shortcutRecordingMessage: self.$shortcutRecordingMessage,
            commandModeShortcut: self.$commandModeHotkeyShortcut,
            rewriteShortcut: self.$rewriteModeHotkeyShortcut,
            cancelRecordingShortcut: self.$cancelRecordingHotkeyShortcut,
            pasteLastTranscriptionShortcut: self.$pasteLastTranscriptionHotkeyShortcut,
            commandModeShortcutEnabled: self.$isCommandModeShortcutEnabled,
            rewriteShortcutEnabled: self.$isRewriteModeShortcutEnabled,
            pasteLastTranscriptionShortcutEnabled: self.$isPasteLastTranscriptionShortcutEnabled,
            hotkeyManagerInitialized: self.$hotkeyManagerInitialized,
            hotkeyMode: self.$hotkeyMode,
            enableStreamingPreview: self.$enableStreamingPreview,
            copyToClipboard: self.$copyToClipboard,
            hotkeyManager: self.hotkeyManager,
            menuBarManager: self.menuBarManager,
            startRecording: self.startRecording,
            refreshDevices: self.refreshDevices,
            openAccessibilitySettings: self.openAccessibilitySettings,
            restartApp: self.restartApp,
            revealAppInFinder: self.revealAppInFinder,
            openApplicationsFolder: self.openApplicationsFolder
        )
    }

    private var recordingView: some View {
        RecordingView(
            appear: self.$appear,
            stopAndProcessTranscription: { await self.stopAndProcessTranscription() },
            startRecording: self.startRecording
        )
    }

    private var commandModeView: some View {
        CommandModeView(service: self.commandModeService, onClose: {
            let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
            self.selectedSidebarItem = isOnboarded ? .preferences : .welcome
        })
    }

    private var rewriteModeView: some View {
        RewriteModeView(service: self.rewriteModeService, onClose: {
            let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
            self.selectedSidebarItem = isOnboarded ? .preferences : .welcome
        })
    }

    // MARK: - Meeting Transcription (Coming Soon)

    private var meetingToolsView: some View {
        MeetingTranscriptionView(asrService: self.asr)
    }

    // MARK: - Stats View

    private var statsView: some View {
        StatsView()
    }

    // Audio settings merged into SettingsView

    private func refreshDevices() {
        // Query CoreAudio off the main thread — during device topology changes, synchronous
        // CoreAudio calls on main can deadlock while the HAL is still settling.
        DispatchQueue.global(qos: .userInitiated).async {
            let inputs = AudioDevice.listInputDevices()
            let outputs = AudioDevice.listOutputDevices()
            DispatchQueue.main.async {
                self.inputDevices = inputs
                self.outputDevices = outputs
            }
        }
    }

    // MARK: - Model Management Functions

    private func saveModels() {
        SettingsStore.shared.availableModels = self.availableModels
    }

    // MARK: - Provider Management Functions

    private func providerKey(for providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Built-in providers use their ID directly
        if ModelRepository.shared.isBuiltIn(trimmed) { return trimmed }
        // Saved providers use their stable id with "custom:" prefix (if not already present)
        if trimmed.hasPrefix("custom:") { return trimmed }
        return "custom:\(trimmed)"
    }

    private func updateCurrentProvider() {
        // Map baseURL to canonical key for built-ins; else keep existing
        let url = self.openAIBaseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if url.contains("openai.com") { self.currentProvider = "openai"; return }
        if url.contains("groq.com") { self.currentProvider = "groq"; return }
        // For saved/custom, keep current or derive from selectedProviderID
        self.currentProvider = self.providerKey(for: self.selectedProviderID)
    }

    private func saveSavedProviders() {
        let storedProviders = SettingsStore.shared.savedProviders
        if self.savedProviders.isEmpty, !storedProviders.isEmpty {
            DebugLogger.shared.warning(
                "Skipped stale empty savedProviders write from ContentView.",
                source: "ContentView"
            )
            return
        }
        SettingsStore.shared.savedProviders = self.savedProviders
    }

    // MARK: - App Detection and Context-Aware Prompts

    private func getCurrentAppInfo() -> (name: String, bundleId: String, windowTitle: String) {
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let name = frontmostApp.localizedName ?? "Unknown"
            let bundleId = frontmostApp.bundleIdentifier ?? "unknown"
            let title = self.getFrontmostWindowTitle(ownerPid: frontmostApp.processIdentifier) ?? ""
            return (name: name, bundleId: bundleId, windowTitle: title)
        }
        return (name: "Unknown", bundleId: "unknown", windowTitle: "")
    }

    /// Best-effort frontmost window title lookup for the current app
    private func getFrontmostWindowTitle(ownerPid: pid_t) -> String? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in windowInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == ownerPid else { continue }
            if let name = info[kCGWindowName as String] as? String, name.isEmpty == false {
                return name
            }
        }
        return nil
    }

    private func captureRecordingTargetContext() {
        // Capture the focused target PID BEFORE any overlay/UI changes.
        // Used to restore focus when the user interacts with overlay dropdowns.
        let focusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotchContentState.shared.recordingTargetPID = focusedPID

        let info = self.getCurrentAppInfo()
        self.recordingAppInfo = info
        self.rewriteModeService.setPromptAppBundleID(info.bundleId)
        DebugLogger.shared.debug(
            "Captured recording app context: app=\(info.name), bundleId=\(info.bundleId), title=\(info.windowTitle)",
            source: "ContentView"
        )
    }

    private func captureRecordingFormattingContextIfNeeded() {
        // Capture text before the caret only when formatting needs focused-field context.
        if SettingsStore.shared.needsDictationFormattingContext {
            self.recordingPrecedingText = TypingService.textBeforeCursorInFocusedField()
            DebugLogger.shared.debug(
                "Captured preceding text for continuous dictation (chars=\(self.recordingPrecedingText.count))",
                source: "ContentView"
            )
        } else {
            self.recordingPrecedingText = ""
        }
    }

    private func captureRecordingContext() {
        self.captureRecordingTargetContext()
        self.captureRecordingFormattingContextIfNeeded()
    }

    private func resolveTypingTargetPID() -> (pid: pid_t?, shouldRestoreOriginalFocus: Bool) {
        let originalPID = NotchContentState.shared.recordingTargetPID
        let currentFocusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier

        let selfBundleID = Bundle.main.bundleIdentifier
        if let currentFocusedPID,
           let app = NSRunningApplication(processIdentifier: currentFocusedPID),
           app.bundleIdentifier != selfBundleID
        {
            return (currentFocusedPID, currentFocusedPID == originalPID)
        }

        return (originalPID, true)
    }

    // MARK: - Commented out app-specific prompts - using general processing only

    /*
     private func getContextualPrompt(for appInfo: (name: String, bundleId: String, windowTitle: String)) -> String {
         let appName = appInfo.name
         let bundleId = appInfo.bundleId.lowercased()
         let windowTitle = appInfo.windowTitle.lowercased()

         // Code editors and IDEs
         if bundleId.contains("xcode") || bundleId.contains("vscode") || bundleId.contains("sublime") ||
            bundleId.contains("atom") || bundleId.contains("jetbrains") || bundleId.contains("cursor") ||
            bundleId.contains("vim") || bundleId.contains("emacs") || appName.lowercased().contains("code")
         {
             return "Clean up this transcribed text for code editor \(appName). Make the smallest necessary mechanical edits; do not add or invent content or answer questions. Remove fillers and false starts. Correct programming terms and obvious transcription errors. Preserve meaning and tone."
         }

         // Email applications
         else if bundleId.contains("mail") || bundleId.contains("outlook") || bundleId.contains("thunderbird") ||
                 bundleId.contains("airmail") || bundleId.contains("spark")
         {
             return "Clean up this transcribed text for email app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and capitalization while preserving meaning and tone."
         }

         // Messaging and chat applications
         else if bundleId.contains("messages") || bundleId.contains("slack") || bundleId.contains("discord") ||
                 bundleId.contains("telegram") || bundleId.contains("whatsapp") || bundleId.contains("signal") ||
                 bundleId.contains("teams") || bundleId.contains("zoom")
         {
             return "Clean up this transcribed text for messaging app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar and clarity while keeping the casual tone."
         }

         // Document editors and word processors
         else if bundleId.contains("pages") || bundleId.contains("word") || bundleId.contains("docs") ||
                 bundleId.contains("writer") || bundleId.contains("notion") || bundleId.contains("bear") ||
                 bundleId.contains("ulysses") || bundleId.contains("scrivener")
         {
             return "Clean up this transcribed text for document editor \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and structure while preserving meaning."
         }

         // Note-taking applications
         else if bundleId.contains("notes") || bundleId.contains("obsidian") || bundleId.contains("roam") ||
                 bundleId.contains("logseq") || bundleId.contains("evernote") || bundleId.contains("onenote")
         {
             return "Clean up this transcribed text for note-taking app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar and organize into clear, readable notes without adding information."
         }

         // Browsers (various web apps). Include: Safari, Chrome, Firefox, Edge, Arc, Brave, Dia, Comet
         else if bundleId.contains("safari") || bundleId.contains("chrome") || bundleId.contains("firefox") ||
                 bundleId.contains("edge") || bundleId.contains("arc") || bundleId.contains("brave") ||
                 bundleId.contains("dia") || bundleId.contains("comet") ||
                 appName.lowercased().contains("safari") || appName.lowercased().contains("chrome") ||
                 appName.lowercased().contains("arc") || appName.lowercased().contains("brave") ||
                 appName.lowercased().contains("dia") || appName.lowercased().contains("comet")
         {
             // Infer common web apps from window title for better context
             if let inferred = inferWebContext(from: windowTitle, appName: appName) {
                 return inferred
             }
             return "Clean up this transcribed text for web browser \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar and basic formatting while preserving meaning."
         }

         // Terminal and command line tools
         else if bundleId.contains("terminal") || bundleId.contains("iterm") || bundleId.contains("console") ||
                 appName.lowercased().contains("terminal")
         {
             return "Clean up this transcribed text for terminal \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix command syntax, file paths, and technical terms without adding options or commands."
         }

         // Social media and creative apps
         else if bundleId.contains("twitter") || bundleId.contains("facebook") || bundleId.contains("instagram") ||
                 bundleId.contains("tiktok") || bundleId.contains("linkedin")
         {
             return "Clean up this transcribed text for social media app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar while keeping the natural, engaging tone."
         }

         // Default fallback
         else
         {
             return "Clean up this transcribed text for \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and formatting while preserving meaning and tone."
         }
     }
     */

    /*
     /// Infer web-app specific prompt from a browser window title
     private func inferWebContext(from windowTitle: String, appName: String) -> String? {
         let title = windowTitle
         // Email (Gmail, Outlook Web)
         if title.contains("gmail") || title.contains("inbox") || title.contains("outlook") {
             return "Clean up this transcribed text for email app \(appName) (web). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and capitalization while preserving meaning."
         }
         // Messaging (Slack, Discord, Teams, Telegram, WhatsApp)
         if title.contains("slack") || title.contains("discord") || title.contains("teams") || title.contains("telegram") || title.contains("whatsapp") {
             return "Clean up this transcribed text for messaging app \(appName) (web). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar and clarity while keeping the casual tone."
         }
         // Documents (Google Docs/Sheets, Notion, Confluence)
         if title.contains("google docs") || title.contains("docs") || title.contains("notion") || title.contains("confluence") || title.contains("google sheets") || title.contains("sheet") {
             return "Clean up this transcribed text for a document editor in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Improve grammar, structure, and readability without adding information."
         }
         // Code (GitHub, Stack Overflow, online IDEs)
         if title.contains("github") || title.contains("stack overflow") || title.contains("stackexchange") || title.contains("replit") || title.contains("codesandbox") {
             return "Clean up this transcribed text for code-related context in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Correct programming terms and obvious errors without adding explanations."
         }
         // Project/issue tracking (Jira, Linear, Asana)
         if title.contains("jira") || title.contains("linear") || title.contains("asana") || title.contains("clickup") {
             return "Clean up this transcribed text for project management context in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Keep the text concise and clear without adding commentary."
         }
         return nil
     }
     */

    // NOTE: Thinking token filtering is now handled by LLMClient.stripThinkingTags()

    // MARK: - Modular AI Processing

    private func processTextWithAI(
        _ inputText: String,
        overrideSystemPrompt: String? = nil,
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil
    ) async throws -> String {
        // CRITICAL FIX: Read current settings from SettingsStore, not stale @State copies
        // This ensures AI provider/model changes in AISettingsView take effect immediately
        let currentSelectedProviderID = SettingsStore.shared.selectedProviderID
        let storedProviderAPIKeys = SettingsStore.shared.providerAPIKeys
        let storedSelectedModelByProvider = SettingsStore.shared.selectedModelByProvider
        let storedSavedProviders = SettingsStore.shared.savedProviders

        // Derive currentProvider and openAIBaseURL from the current settings
        let derivedCurrentProvider: String
        let derivedBaseURL: String
        let derivedSelectedModel: String

        // Get provider info
        if let saved = storedSavedProviders.first(where: { $0.id == currentSelectedProviderID }) {
            // Saved/custom provider
            derivedCurrentProvider = "custom:\(saved.id)"
            derivedBaseURL = saved.baseURL
            derivedSelectedModel = storedSelectedModelByProvider[derivedCurrentProvider] ?? saved.models.first ?? ""
        } else if ModelRepository.shared.isBuiltIn(currentSelectedProviderID) {
            // Built-in provider (openai, groq, cerebras, google, openrouter, ollama, lmstudio)
            derivedCurrentProvider = currentSelectedProviderID
            derivedBaseURL = ModelRepository.shared.defaultBaseURL(for: currentSelectedProviderID)
            derivedSelectedModel = storedSelectedModelByProvider[currentSelectedProviderID] ?? ModelRepository.shared.defaultModels(for: currentSelectedProviderID).first ?? ""
        } else {
            // Unknown provider - fail closed instead of silently sending to OpenAI.
            derivedCurrentProvider = currentSelectedProviderID
            derivedBaseURL = ""
            derivedSelectedModel = storedSelectedModelByProvider[currentSelectedProviderID] ?? ""
        }

        guard !derivedCurrentProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProcessingError.noVerifiedProvider
        }
        if currentSelectedProviderID != "apple-intelligence",
           derivedSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw AIProcessingError.missingModel(provider: derivedCurrentProvider)
        }

        DebugLogger.shared.debug("processTextWithAI using provider=\(derivedCurrentProvider), model=\(derivedSelectedModel)", source: "ContentView")

        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        let isDictationCall = overrideSystemPrompt != nil || dictationSlot != nil
        let isPrivateAIProvider = currentSelectedProviderID == PrivateAIProviderFeature.shared.providerID ||
            derivedCurrentProvider == PrivateAIProviderFeature.shared.providerID ||
            derivedCurrentProvider == "custom:\(PrivateAIProviderFeature.shared.providerID)"
        let usePrivateAIProvider = overrideSystemPrompt == nil &&
            isDictationCall &&
            (isPrivateAIProvider || PrivateAIIntegrationService.shouldHandleDictation(model: derivedSelectedModel))

        if usePrivateAIProvider {
            if self.shouldTracePromptProcessing {
                self.logDictationPromptTrace("Private AI Provider task", value: "dictationEnhancement")
                self.logDictationPromptTrace("Input transcription (Q)", value: inputText)
                self.logDictationPromptTrace("Selected context text", value: "<none (dictation mode)>")
            }

            let apiKey = storedProviderAPIKeys[derivedCurrentProvider] ?? storedProviderAPIKeys[currentSelectedProviderID] ?? ""
            let response = try await PrivateAIIntegrationService.shared.enhanceDictation(
                inputText,
                runtime: PrivateAIIntegrationService.RuntimeConfiguration(
                    selectedProviderID: currentSelectedProviderID,
                    providerKey: derivedCurrentProvider,
                    baseURL: derivedBaseURL,
                    model: derivedSelectedModel,
                    apiKey: apiKey,
                    localModelPath: PrivateAIIntegrationService.configuredLocalModelPath,
                    usesStablePromptPrefixKVCache: SettingsStore.shared.privateAIPrefixKVCacheEnabled,
                    usesFluid1Boost: SettingsStore.shared.privateAIBoostEnabled,
                    contextTokenLimit: SettingsStore.shared.privateAIContextTokenLimit
                ),
                context: PrivateAIIntegrationService.AppContext(
                    appName: appInfo.name,
                    bundleID: appInfo.bundleId,
                    windowTitle: appInfo.windowTitle,
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                )
            )

            if self.shouldTracePromptProcessing {
                self.logDictationPromptTrace("Model answer (A)", value: response.outputText)
            }
            return response.outputText
        }

        // Resolve the effective prompt once so every provider path honors
        // transient overrides such as "Transcribe with Prompt".
        let promptText: String = {
            let override = overrideSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !override.isEmpty { return override }
            return self.buildSystemPrompt(appInfo: appInfo, dictationSlot: dictationSlot)
        }()

        // Dictation enhancement folds the prompt + transcript into a single user
        // turn (substituting `${transcript}` when present, otherwise appending
        // the transcript after a blank line). Non-dictation callers — the AI
        // chat tab specifically — keep the legacy two-message layout where
        // the prompt is the system turn and the input is the user turn.
        let systemPrompt: String
        let userMessageContent: String
        if isDictationCall {
            systemPrompt = ""
            userMessageContent = SettingsStore.renderDictationUserMessage(
                promptText: promptText,
                transcript: inputText
            )
        } else {
            systemPrompt = promptText
            userMessageContent = inputText
        }

        // Route to Apple Intelligence if selected
        if currentSelectedProviderID == "apple-intelligence" {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let provider = AppleIntelligenceProvider()
                if self.shouldTracePromptProcessing {
                    let activeSlot = dictationSlot ?? self.currentDictationShortcutSlot(for: self.activeRecordingMode) ?? .primary
                    let selectedProfile = SettingsStore.shared.resolvedDictationPromptProfile(
                        for: activeSlot,
                        appBundleID: appInfo.bundleId
                    )
                    let selectedPromptName: String = {
                        if SettingsStore.shared.dictationPromptSelection(for: activeSlot) == .off {
                            return "Off"
                        }
                        if let profile = selectedProfile {
                            return profile.name.isEmpty ? "Untitled Prompt" : profile.name
                        }
                        return "Default"
                    }()
                    self.logDictationPromptTrace("Selected prompt profile", value: selectedPromptName)
                    self.logDictationPromptTrace(
                        "Prompt body (custom/default body)",
                        value: SettingsStore.shared.effectiveDictationPromptBody(for: activeSlot, appBundleID: appInfo.bundleId)
                    )
                    self.logDictationPromptTrace("Built-in default system prompt (baseline)", value: SettingsStore.defaultSystemPromptText(for: .dictate))
                    self.logDictationPromptTrace("Final system prompt sent to model", value: systemPrompt)
                    self.logDictationPromptTrace("Input transcription (Q)", value: inputText)
                    if userMessageContent != inputText {
                        self.logDictationPromptTrace("Final user message sent to model", value: userMessageContent)
                    }
                    self.logDictationPromptTrace("Selected context text", value: "<none (dictation mode)>")
                }
                DebugLogger.shared.debug("Using Apple Intelligence for transcription enhancement", source: "ContentView")
                let output = try await provider.process(systemPrompt: systemPrompt, userText: userMessageContent)
                if self.shouldTracePromptProcessing {
                    self.logDictationPromptTrace("Model answer (A)", value: output)
                }
                return output
            }
            #endif
            return inputText // Fallback if not available
        }

        // Skip API key validation for local endpoints
        let isLocal = self.isLocalEndpoint(derivedBaseURL)
        let apiKey = storedProviderAPIKeys[derivedCurrentProvider] ?? ""

        if !isLocal {
            guard !apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
                throw AIProcessingError.missingAPIKey(provider: derivedCurrentProvider)
            }
        }

        DebugLogger.shared.debug("Using app context for AI: app=\(appInfo.name), bundleId=\(appInfo.bundleId), title=\(appInfo.windowTitle)", source: "ContentView")
        if self.shouldTracePromptProcessing {
            let activeSlot = dictationSlot ?? self.currentDictationShortcutSlot(for: self.activeRecordingMode) ?? .primary
            let selectedProfile = SettingsStore.shared.resolvedDictationPromptProfile(
                for: activeSlot,
                appBundleID: appInfo.bundleId
            )
            let selectedPromptName: String = {
                if SettingsStore.shared.dictationPromptSelection(for: activeSlot) == .off {
                    return "Off"
                }
                if let profile = selectedProfile {
                    return profile.name.isEmpty ? "Untitled Prompt" : profile.name
                }
                return "Default"
            }()
            self.logDictationPromptTrace("Selected prompt profile", value: selectedPromptName)
            self.logDictationPromptTrace(
                "Prompt body (custom/default body)",
                value: SettingsStore.shared.effectiveDictationPromptBody(for: activeSlot, appBundleID: appInfo.bundleId)
            )
            self.logDictationPromptTrace("Built-in default system prompt (baseline)", value: SettingsStore.defaultSystemPromptText(for: .dictate))
            self.logDictationPromptTrace("Prompt override in use", value: (overrideSystemPrompt?.isEmpty == false) ? "yes" : "no")
            if let overrideSystemPrompt, !overrideSystemPrompt.isEmpty {
                self.logDictationPromptTrace("Override system prompt", value: overrideSystemPrompt)
            }
            self.logDictationPromptTrace("Final system prompt sent to model", value: systemPrompt)
            self.logDictationPromptTrace("Input transcription (Q)", value: inputText)
            if userMessageContent != inputText {
                self.logDictationPromptTrace("Final user message sent to model", value: userMessageContent)
            }
            self.logDictationPromptTrace("Selected context text", value: "<none (dictation mode)>")
        }

        // Check if this model doesn't support the temperature parameter
        let isTemperatureUnsupported = SettingsStore.shared.isTemperatureUnsupported(derivedSelectedModel)

        // Get reasoning config for this model (uses per-model settings or auto-detection)
        // This handles custom parameters like reasoning_effort, enable_thinking, etc.
        let providerKey = self.providerKey(for: currentSelectedProviderID)
        let reasoningConfig = SettingsStore.shared.getReasoningConfig(forModel: derivedSelectedModel, provider: providerKey)

        // Build extra parameters from reasoning config
        var extraParams: [String: Any] = [:]
        if let config = reasoningConfig, config.isEnabled {
            if config.parameterName == "enable_thinking" {
                // DeepSeek uses boolean
                extraParams = [config.parameterName: config.parameterValue == "true"]
            } else {
                // OpenAI/Groq use string values (reasoning_effort, etc.)
                extraParams = [config.parameterName: config.parameterValue]
            }
            DebugLogger.shared.debug(
                "Added reasoning param: \(config.parameterName)=\(config.parameterValue)",
                source: "ContentView"
            )
        }

        // Build messages array. For dictation enhancement the whole prompt +
        // transcript is folded into a single user message, so we omit the
        // (empty) system role. Non-dictation callers keep the legacy
        // system + user shape.
        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": userMessageContent])

        // NOTE: Transcription doesn't need streaming - the full result appears at once
        // Streaming is only useful for Command/Rewrite modes where real-time display helps
        // Using non-streaming is simpler and more reliable for transcription enhancement
        let enableStreaming = false // Hardcoded off for transcription

        // Build LLMClient configuration
        // Note: No onContentChunk callback needed since we don't display real-time
        // Thinking tokens are extracted but not displayed (no onThinkingChunk)
        let config = LLMClient.Config(
            messages: messages,
            model: derivedSelectedModel,
            baseURL: derivedBaseURL,
            apiKey: apiKey,
            streaming: enableStreaming,
            tools: [],
            temperature: isTemperatureUnsupported ? nil : 0.2,
            extraParameters: extraParams
        )

        DebugLogger.shared.info("Using LLMClient for transcription (streaming=\(enableStreaming))", source: "ContentView")

        let response = try await LLMClient.shared.call(config)

        // Log thinking if present (for debugging)
        if let thinking = response.thinking {
            DebugLogger.shared.debug("LLM thinking tokens extracted (\(thinking.count) chars)", source: "ContentView")
            if self.shouldTracePromptProcessing {
                self.logDictationPromptTrace("Model thinking", value: thinking)
            }
        }

        if self.shouldTracePromptProcessing {
            self.logDictationPromptTrace("Model answer (A)", value: response.content)
        }

        guard !response.content.isEmpty else {
            throw AIProcessingError.emptyResponse
        }
        return response.content
    }

    // MARK: - Streaming Response Handler (DEPRECATED - Now handled by LLMClient)

    // This method is no longer used - LLMClient.call() handles streaming internally

    // MARK: - Stop and Process Transcription

    private func stopAndProcessTranscription(route: DictationOutputRoute = .normal) async {
        DebugLogger.shared.debug("stopAndProcessTranscription called", source: "ContentView")
        DebugLogger.shared.info("Output route selected: \(route.rawValue)", source: "ContentView")
        self.appBench("stop_path_enter route=\(route.rawValue)")

        // Check if we're in rewrite or command mode
        let modeAtStop = self.activeRecordingMode
        let wasRewriteMode = modeAtStop == .edit || self.isRecordingForRewrite
        let wasCommandMode = modeAtStop == .command || self.isRecordingForCommand
        let activeDictationSlot = self.currentDictationShortcutSlot(for: modeAtStop)
        let promptOverride = self.promptModeOverrideText
        let promptTest = DictationPromptTestCoordinator.shared
        let shouldUseAIOnStop = activeDictationSlot.map {
            DictationAIPostProcessingGate.isConfigured(for: $0, appBundleID: self.recordingAppInfo?.bundleId)
        } ?? DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: self.recordingAppInfo?.bundleId)
        let shouldHideOverlayOnStop = route == .normal &&
            !wasRewriteMode &&
            !wasCommandMode &&
            !promptTest.isActive &&
            !shouldUseAIOnStop
        var didRequestOverlayHideOnStop = false
        DebugLogger.shared.info(
            "Routing decision snapshot | activeMode=\(modeAtStop.rawValue) | rewrite=\(wasRewriteMode) | command=\(wasCommandMode) | overlay=\(NotchContentState.shared.mode.rawValue)",
            source: "ContentView"
        )

        self.clearActiveRecordingMode()

        if shouldHideOverlayOnStop {
            didRequestOverlayHideOnStop = true
            DebugLogger.shared.debug("Hiding dictation overlay at stop path", source: "ContentView")
            self.hideOverlayAsync(reason: "stop_path")
        } else {
            // Show "Transcribing" state before calling stop() when the overlay needs
            // to remain available for prompt, command, rewrite, or AI feedback.
            DebugLogger.shared.debug("Showing transcription processing state", source: "ContentView")
            self.appBench("processing_ui_request status=Transcribing")
            self.menuBarManager.setProcessing(true)
            NotchOverlayManager.shared.updateTranscriptionText("Transcribing")
            self.appBench("processing_ui_requested status=Transcribing")

            // Give SwiftUI a chance to render the processing state before heavier work.
            await Task.yield()
        }

        // Stop the ASR service and wait for transcription to complete
        // The processing indicator will stay visible during this phase
        let asrStopStartedAt = ProcessInfo.processInfo.systemUptime
        self.appBench("asr_stop_call")
        // Play the stop cue as soon as the audio engine has stopped, before the
        // (potentially slow) final transcription pass. Scoped to dictation only —
        // Command/Edit modes call asr.stop() without this callback.
        let transcribedText = await asr.stop(onCaptureStopped: {
            TranscriptionSoundPlayer.shared.playStopSound()
        })
        self.appBench("asr_stop_return elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - asrStopStartedAt) * 1000).rounded()))")
        let audioSnapshot = self.asr.consumeLastCompletedAudioSnapshot()
        DebugLogger.shared.info(
            "Stop transcription result | chars=\(transcribedText.count) | empty=\(transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
            source: "ContentView"
        )

        // Reset the transcription text display after transcription completes
        NotchOverlayManager.shared.updateTranscriptionText("")

        guard transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            DebugLogger.shared.debug("Transcription returned empty text", source: "ContentView")
            // Finish the same short exit transition even when no text is emitted.
            if !didRequestOverlayHideOnStop {
                await self.menuBarManager.finishProcessingAndHideOverlay()
            }
            return
        }

        // Prompt Test Mode: reroute dictation hotkey output into the prompt editor (no typing/clipboard/history).
        if promptTest.isActive {
            promptTest.lastTranscriptionText = transcribedText
            promptTest.lastOutputText = ""
            promptTest.lastError = ""

            guard DictationAIPostProcessingGate.isProviderConfigured() else {
                promptTest.lastError = "AI post-processing is not configured. Configure a provider/model (and API key for non-local endpoints) to test prompts."
                self.menuBarManager.setProcessing(false)
                return
            }

            promptTest.isProcessing = true
            // Processing already true from above
            defer {
                self.menuBarManager.setProcessing(false)
                promptTest.isProcessing = false
            }

            do {
                let result = try await self.processTextWithAI(transcribedText, overrideSystemPrompt: promptTest.draftPromptText)
                let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
                let literalFormattedResult = ASRService.applyDictationLiteralFormatting(
                    result,
                    appName: appInfo.name,
                    bundleID: appInfo.bundleId,
                    windowTitle: appInfo.windowTitle
                )
                promptTest.lastOutputText = ASRService.applyGAAVFormatting(literalFormattedResult)
            } catch {
                DebugLogger.shared.error("Prompt test AI call failed: \(error.localizedDescription)", source: "ContentView")
                promptTest.lastError = error.localizedDescription
            }
            return
        }

        if NotchOverlayManager.shared.isBottomOverlayVisible {
            BottomOverlayWindowController.shared.beginReleaseTransition()
        }

        // If this was a rewrite recording, process the rewrite instead of typing
        if wasRewriteMode {
            DebugLogger.shared.info("Processing rewrite with instruction: \(transcribedText)", source: "ContentView")
            let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
            await self.processRewriteWithVoiceInstruction(transcribedText, appInfo: appInfo)
            AnalyticsService.shared.capture(
                .transcriptionCompleted,
                properties: [
                    "mode": AnalyticsMode.rewrite.rawValue,
                    "words_bucket": AnalyticsBuckets.bucketWords(AnalyticsBuckets.wordCount(in: transcribedText)),
                    "ai_used": true,
                ]
            )
            return
        }

        // If this was a command recording, process the command
        if wasCommandMode {
            DebugLogger.shared.info("Processing command: \(transcribedText)", source: "ContentView")
            await self.processCommandWithVoice(transcribedText)
            AnalyticsService.shared.capture(
                .transcriptionCompleted,
                properties: [
                    "mode": AnalyticsMode.command.rawValue,
                    "words_bucket": AnalyticsBuckets.bucketWords(AnalyticsBuckets.wordCount(in: transcribedText)),
                    "ai_used": true,
                ]
            )
            return
        }

        var finalText: String
        var aiFallbackReason: String?
        var postProcessingModel: String?
        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        let normalizedTranscribedText = ASRService.applySpokenPunctuationFormatting(
            transcribedText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )

        let shouldUseAI = activeDictationSlot.map {
            DictationAIPostProcessingGate.isConfigured(for: $0, appBundleID: appInfo.bundleId)
        } ?? DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: appInfo.bundleId)
        let transcriptionModelInfo = self.currentTranscriptionModelInfo()

        if shouldUseAI {
            DebugLogger.shared.debug("Routing transcription through AI post-processing", source: "ContentView")
            let postProcessingModelInfo = self.currentDictationAIModelInfo()
            postProcessingModel = postProcessingModelInfo.model
            let postProcessingInputChars = normalizedTranscribedText.count
            let postProcessingStart = Date()

            // Update overlay text to show we're now refining (processing already true)
            self.appBench("processing_ui_request status=Refining")
            NotchOverlayManager.shared.updateTranscriptionText("Refining")
            self.appBench("processing_ui_requested status=Refining")

            // Ensure the status label becomes visible immediately.
            await Task.yield()

            do {
                finalText = try await self.processTextWithAI(
                    normalizedTranscribedText,
                    overrideSystemPrompt: promptOverride,
                    dictationSlot: activeDictationSlot
                )
            } catch {
                // Fall back to the raw transcription so the user still gets
                // their words typed instead of an error string.
                DebugLogger.shared.error(
                    "AI post-processing failed, falling back to raw transcription: \(error.localizedDescription)",
                    source: "ContentView"
                )
                aiFallbackReason = error.localizedDescription
                // Configuration errors are actionable — point the user at settings
                // rather than just echoing the technical error string.
                if let aiError = error as? AIProcessingError,
                   aiError.isConfigurationError
                {
                    NotificationService.showAIProcessingFallback(
                        error: "\(aiError.localizedDescription). Open AI Enhancement settings to configure a provider."
                    )
                } else {
                    NotificationService.showAIProcessingFallback(error: error.localizedDescription)
                }
                finalText = normalizedTranscribedText
            }
            let postProcessingLatencyMs = Int((Date().timeIntervalSince(postProcessingStart) * 1000).rounded())
            AnalyticsService.shared.capture(
                .dictationPostProcessingCompleted,
                properties: [
                    "latency_ms": postProcessingLatencyMs,
                    "input_chars": postProcessingInputChars,
                    "post_processing_provider": postProcessingModelInfo.provider ?? "unknown",
                    "post_processing_model": postProcessingModelInfo.model ?? "unknown",
                    "transcription_provider": transcriptionModelInfo.provider,
                    "transcription_model": transcriptionModelInfo.model,
                ]
            )

            // Clear transient status text before leaving processing state to avoid
            // a brief non-shimmer "Refining..." preview flash.
            NotchOverlayManager.shared.updateTranscriptionText("")

        } else {
            finalText = normalizedTranscribedText
        }

        // Normalize literal command and mention syntax after AI cleanup and before final user preferences.
        finalText = ASRService.applyDictationLiteralFormatting(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        // Apply GAAV formatting as the FINAL step (after AI post-processing)
        // This ensures the user's preference for no capitalization/period is respected
        finalText = ASRService.applyGAAVFormatting(finalText)
        // Apply Continuous Dictation Mode after GAAV so smart caps use the field
        // context captured at recording start, and the trailing space enables chaining.
        finalText = ASRService.applyContinuousDictationFormatting(finalText, precedingText: self.recordingPrecedingText)
        finalText = ASRService.applyTerminalLiteralAutocompleteSpacing(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.recordingPrecedingText = ""
        self.asr.finalText = finalText
        if route == .onboardingSandbox,
           self.isOnboardingVoicePlaygroundStepActive,
           !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            self.settings.onboardingPlaygroundValidated = true
            self.settings.playgroundUsed = true
            self.playgroundUsed = true
        }

        DebugLogger.shared.info("Transcription finalized (chars: \(finalText.count))", source: "ContentView")
        let finalTextReadyAt = ProcessInfo.processInfo.systemUptime
        let finalOutputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.appBench("transcription_finalized chars=\(finalText.count)")
        self.appBench("text_ready chars=\(finalText.count)")

        AnalyticsService.shared.capture(
            .transcriptionCompleted,
            properties: [
                "mode": AnalyticsMode.dictation.rawValue,
                "words_bucket": AnalyticsBuckets.bucketWords(AnalyticsBuckets.wordCount(in: finalText)),
                "ai_used": shouldUseAI,
                "ai_changed_text": transcribedText != finalText,
                "transcription_provider": transcriptionModelInfo.provider,
                "transcription_model": transcriptionModelInfo.model,
            ]
        )

        let shouldPersistOutputs = route == .normal
        if !shouldPersistOutputs {
            DebugLogger.shared.info(
                "Sandbox route active: suppressing clipboard/history/external typing side effects",
                source: "ContentView"
            )
        }

        let shouldShowAIProcessingFailure = shouldPersistOutputs && aiFallbackReason != nil
        if shouldShowAIProcessingFailure {
            self.pendingAIReprocessText = transcribedText
            NotchContentState.shared.showAIProcessingFailure()
            self.menuBarManager.finishProcessingKeepingOverlayVisible()
        } else {
            self.pendingAIReprocessText = nil
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostName = frontmostApp?.localizedName ?? "Unknown"
        let isFluidFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        // Save to transcription history (transcription mode only, if enabled)
        if shouldPersistOutputs, SettingsStore.shared.saveTranscriptionHistory {
            let historyEntryID = UUID()
            let historyTimestamp = Date()
            TranscriptionHistoryStore.shared.addEntry(
                id: historyEntryID,
                timestamp: historyTimestamp,
                rawText: transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: postProcessingModel != nil && aiFallbackReason == nil,
                processingModel: postProcessingModel,
                aiProcessingError: aiFallbackReason
            )
            self.persistDictationAudioIfNeeded(
                audioSnapshot,
                entryID: historyEntryID,
                timestamp: historyTimestamp,
                model: transcriptionModelInfo.model
            )
        }
        // When FluidVoice itself is frontmost, the bound editor already receives `finalText`.
        // Avoid re-inserting or overwriting the clipboard in that self-target case.
        let shouldCopyToClipboard = shouldPersistOutputs &&
            SettingsStore.shared.copyTranscriptionToClipboard &&
            !isFluidFrontmost

        if shouldCopyToClipboard {
            ClipboardService.copyToClipboard(finalText)
            AnalyticsService.shared.capture(
                .outputDelivered,
                properties: [
                    "mode": AnalyticsMode.dictation.rawValue,
                    "method": AnalyticsOutputMethod.clipboard.rawValue,
                ]
            )
        }

        var didTypeExternally = false
        let shouldTypeExternally = shouldPersistOutputs && !isFluidFrontmost

        DebugLogger.shared.debug(
            "Typing decision → frontmost: \(frontmostName), fluidFrontmost: \(isFluidFrontmost), editorFocused: \(self.isTranscriptionFocused), willTypeExternally: \(shouldTypeExternally)",
            source: "ContentView"
        )

        if shouldTypeExternally {
            let typingTarget = self.resolveTypingTargetPID()
            // Dispatch insertion as soon as the destination app is ready; the
            // overlay hides asynchronously after output so it cannot delay paste.
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.appBench(
                "text_ready_to_type_request elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - finalTextReadyAt) * 1000).rounded()))"
            )
            self.asr.typeOutputPlanToActiveField(
                finalOutputPlan,
                preferredTargetPID: typingTarget.pid,
                textReadyAt: finalTextReadyAt
            )
            didTypeExternally = true
            if !shouldShowAIProcessingFailure, !didRequestOverlayHideOnStop {
                self.hideOverlayAfterOutput()
            }
        }

        if didTypeExternally {
            AnalyticsService.shared.capture(
                .outputDelivered,
                properties: [
                    "mode": AnalyticsMode.dictation.rawValue,
                    "method": AnalyticsOutputMethod.typed.rawValue,
                ]
            )

            // Register the post-transcription edit observation after insertion is dispatched.
            let wordsBucket = AnalyticsBuckets.bucketWords(AnalyticsBuckets.wordCount(in: finalText))
            let modelInfo = self.currentDictationAIModelInfo()
            await PostTranscriptionEditTracker.shared.markTranscriptionCompleted(
                mode: AnalyticsMode.dictation.rawValue,
                outputMethod: AnalyticsOutputMethod.typed.rawValue,
                wordsBucket: wordsBucket,
                aiUsed: shouldUseAI,
                aiModel: modelInfo.model,
                aiProvider: modelInfo.provider
            )
        } else if shouldPersistOutputs,
                  SettingsStore.shared.copyTranscriptionToClipboard == false,
                  SettingsStore.shared.saveTranscriptionHistory
        {
            AnalyticsService.shared.capture(
                .outputDelivered,
                properties: [
                    "mode": AnalyticsMode.dictation.rawValue,
                    "method": AnalyticsOutputMethod.historyOnly.rawValue,
                ]
            )
        }

        if !didTypeExternally, !shouldShowAIProcessingFailure, !didRequestOverlayHideOnStop {
            self.hideOverlayAfterOutput()
        }
    }

    private func hideOverlayAfterOutput() {
        self.hideOverlayAsync(reason: "after_output")
    }

    private func advanceOverlayLifecycle() {
        self.overlayLifecycleID &+= 1
    }

    private func hideOverlayAsync(reason: String) {
        let expectedOverlayLifecycleID = self.overlayLifecycleID
        self.appBench("overlay_hide_request reason=\(reason) lifecycle=\(expectedOverlayLifecycleID)")
        Task { @MainActor in
            guard self.overlayLifecycleID == expectedOverlayLifecycleID else {
                self.appBench(
                    "overlay_hide_skipped reason=\(reason) staleLifecycle=\(expectedOverlayLifecycleID) currentLifecycle=\(self.overlayLifecycleID)"
                )
                return
            }

            let overlayHideStartedAt = ProcessInfo.processInfo.systemUptime
            await self.menuBarManager.finishProcessingAndHideOverlay()
            self.appBench(
                "overlay_hidden reason=\(reason) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - overlayHideStartedAt) * 1000).rounded()))"
            )
        }
    }

    private func persistDictationAudioIfNeeded(
        _ snapshot: DictationAudioSnapshot?,
        entryID: UUID,
        timestamp: Date,
        model: String
    ) {
        guard SettingsStore.shared.saveTranscriptionHistory,
              SettingsStore.shared.saveAudioWithTranscriptionHistory,
              let snapshot = snapshot
        else {
            return
        }

        Task.detached(priority: .utility) {
            let result: (metadata: DictationAudioMetadata?, error: String?) = {
                do {
                    let metadata = try DictationAudioHistoryStore.shared.save(
                        snapshot: snapshot,
                        entryID: entryID,
                        timestamp: timestamp,
                        model: model
                    )
                    return (metadata, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }()

            await MainActor.run {
                if let metadata = result.metadata {
                    TranscriptionHistoryStore.shared.attachAudio(metadata, to: entryID)
                } else if let error = result.error {
                    DebugLogger.shared.error("Failed to save dictation audio: \(error)", source: "ContentView")
                }
            }
        }
    }

    private var isOnboardingVoicePlaygroundStepActive: Bool {
        let onboardingPlaygroundStep = 4
        return !self.settings.onboardingCompleted &&
            self.settings.onboardingCurrentStep == onboardingPlaygroundStep
    }

    private var isOnboardingSandboxRouteActive: Bool {
        let onboardingAIEnhancementStep = 5
        return self.isOnboardingVoicePlaygroundStepActive ||
            (!self.settings.onboardingCompleted && self.settings.onboardingCurrentStep == onboardingAIEnhancementStep)
    }

    private func currentDictationOutputRouteForHotkeyStop() -> DictationOutputRoute {
        let isDictationMode = self.activeRecordingMode == .dictate || self.activeRecordingMode == .promptMode

        if self.isOnboardingSandboxRouteActive && isDictationMode {
            return .onboardingSandbox
        }
        return .normal
    }

    private func reprocessLastDictation() {
        if let pendingText = self.pendingAIReprocessText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pendingText.isEmpty
        {
            DebugLogger.shared.info("Actions: Reprocessing pending failed dictation", source: "ContentView")
            Task { @MainActor in
                await self.reprocessDictationText(pendingText)
            }
            return
        }

        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Reprocess requested but history is empty", source: "ContentView")
            return
        }

        let rawText = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            DebugLogger.shared.info("Actions: Reprocess skipped because latest history raw text is empty", source: "ContentView")
            return
        }

        DebugLogger.shared.info("Actions: Reprocessing latest dictation history entry", source: "ContentView")
        Task { @MainActor in
            await self.reprocessDictationText(rawText)
        }
    }

    private func copyLastDictationFromHistory() {
        guard let text = TranscriptionHistoryStore.shared.latestClipboardText else {
            DebugLogger.shared.info("Actions: Copy requested but no transcription is available", source: "ContentView")
            return
        }

        _ = ClipboardService.copyToClipboard(text)
        DebugLogger.shared.info("Actions: Copied latest transcription to clipboard", source: "ContentView")
    }

    /// Re-inserts the most recent transcription into the focused text field using the same
    /// clipboard-free insertion path as live dictation. Unlike copy, this never touches the
    /// system clipboard, and unlike reprocess, it pastes the existing text verbatim (no new
    /// history entry, no reformatting). Useful when the original auto-insert dropped the tail.
    private func pasteLastDictationFromHistory() {
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Paste requested but history is empty", source: "ContentView")
            return
        }

        // Prefer the processed text (what was actually delivered, possibly AI-enhanced),
        // falling back to raw for older entries or when enhancement was off.
        let processed = last.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = processed.isEmpty ? raw : processed
        guard !text.isEmpty else {
            DebugLogger.shared.info("Actions: Paste skipped because latest history text is empty", source: "ContentView")
            return
        }

        Task { @MainActor in
            // Only one paste may be pending at a time. Because the paste waits for the modifier keys
            // to release, a quick double/triple-tap of the chord would otherwise queue several Tasks
            // that all insert at once on release. This collapses them to a single paste while still
            // allowing a deliberate repeat (press, it lands, then press again).
            guard !Self.isPasteLastInProgress else {
                DebugLogger.shared.info("Actions: Paste skipped - a paste is already pending", source: "ContentView")
                return
            }
            Self.isPasteLastInProgress = true
            defer { Self.isPasteLastInProgress = false }

            // The hotkey fires on key-down while its own modifier keys (e.g. ⌘⌃) are still
            // physically held. Synthesizing text in that state makes the target app treat the
            // characters as keyboard shortcuts and drop them, so the paste lands once the keys are
            // released — effectively "paste when you let go". The timeout is generous so a normal
            // hold (or a quick repeated press) still pastes on release; it only aborts if a modifier
            // is genuinely stuck, rather than typing a corrupted/destructive shortcut sequence.
            guard await Self.waitForHotkeyModifiersReleased(timeout: 5) else {
                DebugLogger.shared.info("Actions: Paste aborted - modifier keys still held after timeout", source: "ContentView")
                return
            }

            // Re-check here rather than only at the hotkey trigger: the overlay menu entry point
            // has no pre-check, and the wait above may have elapsed since the trigger fired.
            guard !self.asr.isRunning else {
                DebugLogger.shared.info("Actions: Paste skipped - recording in progress", source: "ContentView")
                return
            }

            let typingTarget = self.resolveTypingTargetPID()
            guard typingTarget.pid != nil else {
                DebugLogger.shared.info("Actions: Paste skipped - no external target field available", source: "ContentView")
                return
            }
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            let appInfo = self.getCurrentAppInfo()
            let outputPlan = ASRService.makeDictationLiteralOutputPlan(
                for: text,
                appName: appInfo.name,
                bundleID: appInfo.bundleId,
                windowTitle: appInfo.windowTitle
            )
            self.asr.typeOutputPlanToActiveField(outputPlan, preferredTargetPID: typingTarget.pid)
            DebugLogger.shared.info("Actions: Pasted latest transcription into focused field", source: "ContentView")
        }
    }

    /// Guards against overlapping paste insertions: only one "paste last transcription" may be
    /// pending at a time (see pasteLastDictationFromHistory). A rapid re-tap while one is still
    /// waiting for the modifier keys to release is ignored rather than queuing a duplicate insert.
    /// Only ever touched on the main actor.
    private static var isPasteLastInProgress = false

    /// Polls until the keyboard modifier keys are released, returning `true` once they are, or
    /// `false` if the timeout elapses with keys still held. Used before synthesizing a paste so the
    /// inserted characters aren't swallowed as modifier+key shortcuts.
    private static func waitForHotkeyModifiersReleased(timeout: TimeInterval) async -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.isDisjoint(with: relevant) {
                return true
            }
            try? await Task.sleep(nanoseconds: 15_000_000) // 15ms
        }
        return false
    }

    private func undoLastAIProcessingFromHistory() {
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Undo AI requested but history is empty", source: "ContentView")
            return
        }

        let rawText = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else {
            DebugLogger.shared.info("Actions: Undo AI skipped because latest history raw text is empty", source: "ContentView")
            return
        }

        guard last.wasAIProcessed else {
            DebugLogger.shared.info("Actions: Undo AI skipped because latest entry was not AI processed", source: "ContentView")
            return
        }

        DebugLogger.shared.info("Actions: Restoring latest transcription raw text (undo AI)", source: "ContentView")
        Task { @MainActor in
            await self.applyHistoryTextOutput(rawText, saveToHistory: true)
        }
    }

    private func applyHistoryTextOutput(_ text: String, saveToHistory: Bool) async {
        // Keep hotkey/recording state deterministic before applying output text.
        if self.asr.isRunning {
            DebugLogger.shared.info("Actions: stopping active recording before history action output", source: "ContentView")
            await self.asr.stopWithoutTranscription()
            self.cancelPrewarmDictationIfNeeded()
        }

        let appInfo = self.getCurrentAppInfo()
        let literalFormattedText = ASRService.applyDictationLiteralFormatting(
            text,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let gaavText = ASRService.applyGAAVFormatting(literalFormattedText)
        let precedingText = SettingsStore.shared.needsDictationFormattingContext
            ? TypingService.textBeforeCursorInFocusedField()
            : ""
        var finalText = ASRService.applyContinuousDictationFormatting(gaavText, precedingText: precedingText)
        finalText = ASRService.applyTerminalLiteralAutocompleteSpacing(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        let outputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )

        if saveToHistory, SettingsStore.shared.saveTranscriptionHistory {
            TranscriptionHistoryStore.shared.addEntry(
                rawText: text,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: false
            )
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isFluidFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        if SettingsStore.shared.copyTranscriptionToClipboard, !isFluidFrontmost {
            ClipboardService.copyToClipboard(finalText)
        }

        let focusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotchContentState.shared.recordingTargetPID = focusedPID

        let shouldTypeExternally = !isFluidFrontmost
        if shouldTypeExternally {
            let typingTarget = self.resolveTypingTargetPID()
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.asr.typeOutputPlanToActiveField(
                outputPlan,
                preferredTargetPID: typingTarget.pid
            )
        }
    }

    private func reprocessDictationText(_ transcribedText: String) async {
        // If live recording is still active, stop it first so reprocess does not
        // leave ASR running in the background (which causes the next hotkey press
        // to behave like a stop instead of start).
        if self.asr.isRunning {
            DebugLogger.shared.info("Actions: stopping active recording before reprocess", source: "ContentView")
            await self.asr.stopWithoutTranscription()
            self.cancelPrewarmDictationIfNeeded()
        }

        self.setActiveRecordingMode(.dictate)
        self.menuBarManager.setProcessing(true)
        NotchOverlayManager.shared.updateTranscriptionText("Reprocessing...")
        await Task.yield()

        var aiFallbackReason: String?
        var postProcessingModel: String?
        let appInfo = self.getCurrentAppInfo()
        let normalizedTranscribedText = ASRService.applySpokenPunctuationFormatting(
            transcribedText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        var finalText = normalizedTranscribedText
        let shouldUseAI = DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: appInfo.bundleId)
        if shouldUseAI {
            postProcessingModel = self.currentDictationAIModelInfo().model
            do {
                finalText = try await self.processTextWithAI(
                    normalizedTranscribedText,
                    dictationSlot: .primary
                )
            } catch {
                DebugLogger.shared.error(
                    "AI reprocess failed, falling back to raw transcription: \(error.localizedDescription)",
                    source: "ContentView"
                )
                aiFallbackReason = error.localizedDescription
                NotificationService.showAIProcessingFallback(error: error.localizedDescription)
                finalText = normalizedTranscribedText
            }
        }

        NotchOverlayManager.shared.updateTranscriptionText("")

        finalText = ASRService.applyDictationLiteralFormatting(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        finalText = ASRService.applyGAAVFormatting(finalText)
        let precedingText = SettingsStore.shared.needsDictationFormattingContext
            ? TypingService.textBeforeCursorInFocusedField()
            : ""
        finalText = ASRService.applyContinuousDictationFormatting(finalText, precedingText: precedingText)
        finalText = ASRService.applyTerminalLiteralAutocompleteSpacing(
            finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )
        self.recordingPrecedingText = ""
        let outputPlan = ASRService.makeDictationLiteralOutputPlan(
            for: finalText,
            appName: appInfo.name,
            bundleID: appInfo.bundleId,
            windowTitle: appInfo.windowTitle
        )

        if SettingsStore.shared.saveTranscriptionHistory {
            TranscriptionHistoryStore.shared.addEntry(
                rawText: transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle,
                wasAIProcessed: postProcessingModel != nil && aiFallbackReason == nil,
                processingModel: postProcessingModel,
                aiProcessingError: aiFallbackReason
            )
        }
        if aiFallbackReason != nil {
            self.pendingAIReprocessText = transcribedText
            NotchContentState.shared.showAIProcessingFailure()
            self.menuBarManager.finishProcessingKeepingOverlayVisible()
        } else {
            self.pendingAIReprocessText = nil
        }

        if SettingsStore.shared.copyTranscriptionToClipboard {
            ClipboardService.copyToClipboard(finalText)
        }

        let focusedPID = TypingService.captureSystemFocusedPID()
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        NotchContentState.shared.recordingTargetPID = focusedPID

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let isFluidFrontmost = frontmostApp?.bundleIdentifier?.contains("fluid") == true
        let shouldTypeExternally = !isFluidFrontmost || self.isTranscriptionFocused == false
        if shouldTypeExternally {
            let typingTarget = self.resolveTypingTargetPID()
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.asr.typeOutputPlanToActiveField(
                outputPlan,
                preferredTargetPID: typingTarget.pid
            )
        }

        if aiFallbackReason == nil {
            self.hideOverlayAfterOutput()
        }

        self.clearActiveRecordingMode()
    }

    // MARK: - Rewrite Mode Voice Processing

    private func processRewriteWithVoiceInstruction(
        _ instruction: String,
        appInfo: (name: String, bundleId: String, windowTitle: String)
    ) async {
        self.rewriteModeService.setPromptAppBundleID(appInfo.bundleId)
        let hasOriginalText = !self.rewriteModeService.originalText.isEmpty
        DebugLogger.shared.info("Processing \(hasOriginalText ? "rewrite" : "write/improve") - instruction: '\(instruction)', originalText length: \(self.rewriteModeService.originalText.count)", source: "ContentView")

        // Show processing animation
        self.menuBarManager.setProcessing(true)

        // Process the request - service handles both cases:
        // - With originalText: rewrites existing text based on instruction
        // - Without originalText: improves/refines the spoken text
        await self.rewriteModeService.processRewriteRequest(instruction)

        // If rewrite was successful, type the result
        if !self.rewriteModeService.rewrittenText.isEmpty {
            DebugLogger.shared.info("Rewrite successful, typing result (chars: \(self.rewriteModeService.rewrittenText.count))", source: "ContentView")

            // Copy to clipboard as backup
            if SettingsStore.shared.copyTranscriptionToClipboard {
                ClipboardService.copyToClipboard(self.rewriteModeService.rewrittenText)
                AnalyticsService.shared.capture(
                    .outputDelivered,
                    properties: [
                        "mode": AnalyticsMode.rewrite.rawValue,
                        "method": AnalyticsOutputMethod.clipboard.rawValue,
                    ]
                )
            }

            // Type the rewritten text
            let typingTarget = self.resolveTypingTargetPID()
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.asr.typeTextToActiveField(
                self.rewriteModeService.rewrittenText,
                preferredTargetPID: typingTarget.pid
            )
            AnalyticsService.shared.capture(
                .outputDelivered,
                properties: [
                    "mode": AnalyticsMode.rewrite.rawValue,
                    "method": AnalyticsOutputMethod.typed.rawValue,
                ]
            )

            // Clear the rewrite service state for next use
            self.rewriteModeService.clearState()
            self.hideOverlayAfterOutput()
        } else {
            await self.menuBarManager.finishProcessingAndHideOverlay()
            DebugLogger.shared.error("Rewrite failed - no result", source: "ContentView")
            AnalyticsService.shared.capture(
                .errorOccurred,
                properties: [
                    "domain": AnalyticsErrorDomain.llm.rawValue,
                    "category": "rewrite_no_result",
                ]
            )
        }
    }

    private func setActiveRecordingMode(_ mode: ActiveRecordingMode) {
        if mode != .dictate, mode != .promptMode {
            self.clearActiveDictationShortcutState()
        }
        self.activeRecordingMode = mode
        switch mode {
        case .none, .dictate, .promptMode:
            self.isRecordingForCommand = false
            self.isRecordingForRewrite = false
        case .edit:
            self.isRecordingForCommand = false
            self.isRecordingForRewrite = true
        case .command:
            self.isRecordingForCommand = true
            self.isRecordingForRewrite = false
        }
    }

    private func clearActiveRecordingMode() {
        self.setActiveRecordingMode(.none)
    }

    /// Cancel an in-flight prewarm. Called on abort / new recording start — NOT on
    /// a normal stop, because AI post-processing runs after stop and benefits from
    /// the warm prefix cache the prewarm prime.
    private func cancelPrewarmDictationIfNeeded() {
        self.prewarmDictationTask?.cancel()
        self.prewarmDictationTask = nil
    }

    private func handleLivePromptModeSwitch(_ mode: SettingsStore.PromptMode) {
        guard !NotchContentState.shared.isProcessing else { return }
        switch mode.normalized {
        case .dictate:
            guard self.activeRecordingMode != .dictate || NotchContentState.shared.mode != .dictation else { return }
            self.setActiveRecordingMode(.dictate)
            self.rewriteModeService.clearState()
            self.menuBarManager.setOverlayMode(.dictation)
        case .edit:
            guard self.activeRecordingMode != .edit || NotchContentState.shared.mode == .dictation else { return }
            self.setActiveRecordingMode(.edit)
            let hasOriginal = !self.rewriteModeService.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasContext = !self.rewriteModeService.selectedContextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasOriginal, !hasContext {
                let captured = self.rewriteModeService.captureSelectedText()
                DebugLogger.shared.info("Live switch to Edit Text attempted context capture: \(captured)", source: "ContentView")
                if !captured {
                    self.rewriteModeService.startWithoutSelection()
                }
            }
            self.menuBarManager.setOverlayMode(.edit)
        case .write, .rewrite:
            guard self.activeRecordingMode != .edit || NotchContentState.shared.mode == .dictation else { return }
            self.setActiveRecordingMode(.edit)
            let hasOriginal = !self.rewriteModeService.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasContext = !self.rewriteModeService.selectedContextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasOriginal, !hasContext {
                let captured = self.rewriteModeService.captureSelectedText()
                DebugLogger.shared.info("Live switch to Edit Text attempted context capture: \(captured)", source: "ContentView")
                if !captured {
                    self.rewriteModeService.startWithoutSelection()
                }
            }
            self.menuBarManager.setOverlayMode(.edit)
        }
    }

    private func handleLiveOverlayModeSwitch(_ mode: OverlayMode) {
        guard !NotchContentState.shared.isProcessing else { return }
        switch mode {
        case .dictation:
            self.handleLivePromptModeSwitch(.dictate)
        case .edit, .write, .rewrite:
            self.handleLivePromptModeSwitch(.edit)
        case .command:
            guard self.activeRecordingMode != .command || NotchContentState.shared.mode != .command else { return }
            self.rewriteModeService.clearState()
            self.setActiveRecordingMode(.command)
            self.menuBarManager.setOverlayMode(.command)
        }
    }

    // MARK: - Command Mode Voice Processing

    private func processCommandWithVoice(_ command: String) async {
        DebugLogger.shared.info("Processing voice command: '\(command)'", source: "ContentView")

        // Show processing animation
        self.menuBarManager.setProcessing(true)

        // Process the command through CommandModeService
        // This stores the conversation history and executes any terminal commands
        await self.commandModeService.processUserCommand(command, notifyInvalidRequest: true)

        // Hide processing animation
        self.menuBarManager.setProcessing(false)

        DebugLogger.shared.info("Command processed, conversation stored in Command Mode", source: "ContentView")
    }

    /// Capture app context at start to avoid mismatches if the user switches apps mid-session
    private func startRecording() {
        let model = SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info(
            "ContentView: startRecording() for model=\(model.displayName), supportsStreaming=\(model.supportsStreaming)",
            source: "ContentView"
        )

        self.advanceOverlayLifecycle()
        self.setActiveRecordingMode(.dictate)
        let shouldShowDictationOverlay = !self.isRecordingForCommand && !self.isRecordingForRewrite
        let shouldPlayStartSound = !self.isRecordingForCommand
            && !self.isRecordingForRewrite
            && self.asr.micStatus == .authorized

        // Ensure normal dictation mode is set (command/rewrite modes set their own)
        if shouldShowDictationOverlay {
            self.menuBarManager.setOverlayMode(.dictation)
        }

        Task {
            if shouldPlayStartSound, !self.asr.isRunning {
                TranscriptionSoundPlayer.shared.playStartSound()
            }
            await self.asr.start(onCaptureStarted: {
                self.captureRecordingContext()
                self.prewarmPrivateAIDictationIfNeeded(for: .primary)
                if shouldShowDictationOverlay {
                    self.menuBarManager.showRecordingOverlayImmediately()
                }
            })
            if !self.asr.isRunning {
                self.menuBarManager.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
        }

        // Pre-load model in background while recording (avoids 10s freeze on stop)
        Task {
            do {
                DebugLogger.shared.debug("ContentView: pre-load model task started", source: "ContentView")
                try await self.asr.ensureAsrReady()
                DebugLogger.shared.debug("Model pre-loaded during recording", source: "ContentView")
            } catch {
                DebugLogger.shared.error("Failed to pre-load model: \(error)", source: "ContentView")
            }
        }
    }

    private func prewarmPrivateAIDictationIfNeeded(for slot: SettingsStore.DictationShortcutSlot) {
        let appBundleID = self.recordingAppInfo?.bundleId
        guard PrivateAIProviderPromptFormat.isAvailable(settings: SettingsStore.shared),
              DictationAIPostProcessingGate.isConfigured(for: slot, appBundleID: appBundleID)
        else { return }

        // Cancel any prior prewarm so rapid start/stop doesn't queue duplicate
        // actor work on PrivateAIIntegrationService.
        self.prewarmDictationTask?.cancel()
        self.prewarmDictationTask = Task {
            DebugLogger.shared.debug(
                "ContentView: AI dictation prewarm started slot=\(slot.rawValue)",
                source: "ContentView"
            )
            await PrivateAIIntegrationService.shared.prewarmDictation()
            DebugLogger.shared.debug(
                "AI dictation prewarm complete slot=\(slot.rawValue)",
                source: "ContentView"
            )
            if !Task.isCancelled {
                self.prewarmDictationTask = nil
            }
        }
    }

    /// Best-effort: re-activate the app that was focused when recording started.
    /// Skips the AX restore work when the captured text element is already focused.
    private func restoreFocusToRecordingTarget() async {
        guard let pid = NotchContentState.shared.recordingTargetPID else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        self.appBench("focus_restore_start targetPID=\(pid)")
        if TypingService.isCapturedFocusStillActive(for: pid) {
            self.appBench("focus_restore_result activated=false element=true elapsedMs=0 reason=already_focused")
            DebugLogger.shared.debug(
                "Restore focus skipped; captured element still focused, targetPID: \(pid)",
                source: "ContentView"
            )
            self.appBench("focus_restore_settle_done delayMs=0")
            return
        }
        let activated = TypingService.activateApp(pid: pid)
        let focusedElementRestored = TypingService.restoreCapturedFocus(in: pid)
        self.appBench(
            "focus_restore_result activated=\(activated) element=\(focusedElementRestored) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))"
        )
        DebugLogger.shared.debug(
            "Restore focus -> appActivated: \(activated), elementFocusRestored: \(focusedElementRestored), targetPID: \(pid)",
            source: "ContentView"
        )
        self.appBench("focus_restore_settle_done delayMs=0")
    }

    // MARK: - ASR Model Management

    /// Manual download trigger - downloads models when user clicks button
    private func downloadModels() async {
        DebugLogger.shared.debug("User initiated model download", source: "ContentView")

        do {
            try await self.asr.ensureAsrReady()
            DebugLogger.shared.info("Model download completed successfully", source: "ContentView")
        } catch {
            DebugLogger.shared.error("Failed to download models: \(error)", source: "ContentView")
        }
    }

    /// Delete models from disk
    private func deleteModels() async {
        DebugLogger.shared.debug("User initiated model deletion", source: "ContentView")

        do {
            try await self.asr.clearModelCache()
            DebugLogger.shared.info("Models deleted successfully", source: "ContentView")
        } catch {
            DebugLogger.shared.error("Failed to delete models: \(error)", source: "ContentView")
        }
    }

    // MARK: - ASR Model Preloading

    private func preloadASRModel() async {
        // DEPRECATED: No longer auto-loads on startup - models downloaded manually
        DebugLogger.shared.debug("Skipping auto-preload - models downloaded manually via UI", source: "ContentView")
    }

    // MARK: - Model Management

    private func addNewModel() {
        guard !self.newModelName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else { return }

        let modelName = self.newModelName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let key = self.providerKey(for: self.selectedProviderID)

        // Get current list or start fresh if empty
        var list = self.availableModelsByProvider[key] ?? self.availableModels
        if list.isEmpty {
            list = []
        }

        // Add the new model if not already in list
        if !list.contains(modelName) {
            list.append(modelName)
        }

        // Update state
        self.availableModelsByProvider[key] = list
        SettingsStore.shared.availableModelsByProvider = self.availableModelsByProvider

        // Update saved provider if exists
        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let updatedProvider = SettingsStore.SavedProvider(
                id: self.savedProviders[providerIndex].id,
                name: self.savedProviders[providerIndex].name,
                baseURL: self.savedProviders[providerIndex].baseURL,
                models: list
            )
            self.savedProviders[providerIndex] = updatedProvider
            self.saveSavedProviders()
        }

        // Update UI state
        self.availableModels = list
        self.selectedModel = modelName
        self.selectedModelByProvider[key] = modelName
        SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider

        // Close the add model UI
        self.showingAddModel = false
        self.newModelName = ""
    }

    private func initializeHotkeyManagerIfNeeded() {
        NotchContentState.shared.onPromptModeSwitchRequested = { mode in
            self.handleLivePromptModeSwitch(mode)
        }
        NotchContentState.shared.onOverlayModeSwitchRequested = { mode in
            self.handleLiveOverlayModeSwitch(mode)
        }
        NotchContentState.shared.onReprocessLastRequested = {
            self.reprocessLastDictation()
        }
        NotchContentState.shared.onCopyLastRequested = {
            self.copyLastDictationFromHistory()
        }
        NotchContentState.shared.onPasteLastRequested = {
            self.pasteLastDictationFromHistory()
        }
        NotchContentState.shared.onUndoLastAIRequested = {
            self.undoLastAIProcessingFromHistory()
        }
        NotchContentState.shared.onOpenPreferencesRequested = {
            self.menuBarManager.openPreferencesFromUI()
        }
        NotchContentState.shared.onCancelRequested = {
            _ = self.handleCancelShortcut()
        }
        NotchContentState.shared.onDictationPromptSelectionRequested = { selection in
            let privateAIAvailable = PrivateAIProviderPromptFormat.isAvailable()
            switch selection {
            case .off:
                break
            case .privateAI:
                guard privateAIAvailable else { return }
            case .default, .profile:
                guard !privateAIAvailable else { return }
            }
            let slot = self.activeDictationShortcutSlot ?? .primary
            SettingsStore.shared.setDictationPromptSelection(selection, for: slot)
            self.applyDictationShortcutSelectionContext(for: slot)
        }

        guard self.hotkeyManager == nil else { return }

        self.hotkeyManager = GlobalHotkeyManager(
            asrService: self.asr,
            primaryShortcuts: self.primaryDictationShortcuts,
            promptModeShortcut: self.promptModeHotkeyShortcut,
            commandModeShortcut: self.commandModeHotkeyShortcut,
            rewriteModeShortcut: self.rewriteModeHotkeyShortcut,
            promptShortcutAssignments: SettingsStore.shared.dictationPromptShortcutAssignments(),
            promptModeShortcutEnabled: self.isPromptModeShortcutEnabled,
            commandModeShortcutEnabled: self.isCommandModeShortcutEnabled,
            rewriteModeShortcutEnabled: self.isRewriteModeShortcutEnabled,
            startRecordingCallback: {
                DebugLogger.shared.debug("ContentView: startRecordingCallback invoked by hotkey", source: "ContentView")
                self.startRecording()
            },
            dictationModeCallback: {
                DebugLogger.shared.info("Dictate mode triggered", source: "ContentView")
                DebugLogger.shared.debug(
                    "ContentView: selected model for dictate hotkey=\(SettingsStore.shared.selectedSpeechModel.displayName)",
                    source: "ContentView"
                )
                self.beginDictationRecording(for: .primary, mode: .dictate)
            },
            stopAndProcessCallback: {
                let route = self.currentDictationOutputRouteForHotkeyStop()
                DebugLogger.shared.info("Hotkey stop callback using route: \(route.rawValue)", source: "ContentView")
                await self.stopAndProcessTranscription(route: route)
            },
            promptModeCallback: {
                DebugLogger.shared.info("Prompt mode triggered", source: "ContentView")
                self.beginDictationRecording(for: .secondary, mode: .promptMode)
            },
            promptSelectionCallback: { selection in
                DebugLogger.shared.info("Prompt selection shortcut triggered", source: "ContentView")
                self.beginDictationRecording(for: selection, mode: .promptMode)
            },
            commandModeCallback: {
                DebugLogger.shared.info("Command mode triggered", source: "ContentView")
                self.captureRecordingContext()

                // Set flag so stopAndProcessTranscription knows to process as command
                self.setActiveRecordingMode(.command)

                // Set overlay mode to command
                self.menuBarManager.setOverlayMode(.command)

                guard !self.asr.isRunning else { return }

                self.advanceOverlayLifecycle()

                // Start recording immediately for the command
                DebugLogger.shared.info(
                    "Starting voice recording for command",
                    source: "ContentView"
                )
                TranscriptionSoundPlayer.shared.playStartSound()
                Task {
                    await self.asr.start()
                }
            },
            rewriteModeCallback: {
                self.captureRecordingContext()

                // Try to capture text first while still in the other app
                let captured = self.rewriteModeService.captureSelectedText()
                DebugLogger.shared.info("Rewrite mode triggered, text captured: \(captured)", source: "ContentView")

                if !captured {
                    // No text selected - start in "write mode" where user speaks
                    // what to write
                    DebugLogger.shared
                        .info(
                            "No text selected - starting in write/improve mode",
                            source: "ContentView"
                        )
                    self.rewriteModeService.startWithoutSelection()
                    // Set overlay mode to edit
                    self.menuBarManager.setOverlayMode(.edit)
                } else {
                    // Text was selected - edit mode (with selected context)
                    self.menuBarManager.setOverlayMode(.edit)
                }

                // Set flag so stopAndProcessTranscription knows to process as rewrite
                self.setActiveRecordingMode(.edit)

                guard !self.asr.isRunning else { return }

                self.advanceOverlayLifecycle()

                // Start recording immediately for the edit instruction
                DebugLogger.shared.info("Starting voice recording for edit mode", source: "ContentView")
                TranscriptionSoundPlayer.shared.playStartSound()
                Task {
                    await self.asr.start()
                }
            },
            isDictateRecordingProvider: {
                self.activeRecordingMode == .dictate
            },
            isPromptModeRecordingProvider: {
                self.activeRecordingMode == .promptMode
            },
            isCommandRecordingProvider: {
                self.activeRecordingMode == .command
            },
            isRewriteRecordingProvider: {
                self.activeRecordingMode == .edit
            },
            isShortcutCaptureActiveProvider: {
                self.isRecordingAnyShortcutCapture
            }
        )

        self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false

        self.hotkeyManager?.setHotkeyMode(self.hotkeyMode)

        // Set cancel callback for Escape key handling (closes transient UI, resets recording state)
        // Returns true if it handled something (so GlobalHotkeyManager knows to consume the event)
        self.hotkeyManager?.setCancelCallback {
            var handled = false

            // Close expanded command notch if visible (highest priority)
            if NotchOverlayManager.shared.isCommandOutputExpanded {
                DebugLogger.shared.debug("Cancel callback: closing expanded command notch", source: "ContentView")
                NotchOverlayManager.shared.hideExpandedCommandOutput()
                handled = true
            }

            // Reset recording mode flags
            if self.activeRecordingMode != .none {
                self.cancelPrewarmDictationIfNeeded()
                self.clearActiveRecordingMode()
                handled = true
            }

            // Close rewrite mode if open. Command Mode stays open so Escape can cancel voice capture without leaving the tool.
            if self.selectedSidebarItem == .rewriteMode {
                DebugLogger.shared.debug("Cancel callback: closing mode view", source: "ContentView")
                DispatchQueue.main.async {
                    self.selectedSidebarItem = .welcome
                }
                handled = true
            }

            return handled
        }

        // Re-insert the most recent transcription on demand (no clipboard involved).
        self.hotkeyManager?.setPasteLastTranscriptionCallback {
            self.pasteLastDictationFromHistory()
        }

        // Monitor initialization status
        Task {
            // Give some time for initialization
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

            await MainActor.run {
                self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                DebugLogger.shared.debug("Initial hotkey manager health check: \(self.hotkeyManagerInitialized)", source: "ContentView")

                // If still not initialized and accessibility is enabled, try reinitializing
                if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                    self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                    DebugLogger.shared.debug("Initial hotkey manager health check: \(self.hotkeyManagerInitialized)", source: "ContentView")

                    // If still not initialized and accessibility is enabled, try reinitializing
                    if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                        DebugLogger.shared.debug("Hotkey manager not healthy, attempting reinitalization", source: "ContentView")
                        self.hotkeyManager?.reinitialize()
                    }
                }
            }
        }
    }

    @discardableResult
    private func handleCancelShortcut() -> Bool {
        var handled = false

        if NotchOverlayManager.shared.isCommandOutputExpanded {
            DebugLogger.shared.debug("Cancel shortcut: closing expanded command notch", source: "ContentView")
            NotchOverlayManager.shared.hideExpandedCommandOutput()
            NotchOverlayManager.shared.onCommandOutputDismiss?()
            handled = true
        }

        if self.asr.isRunning {
            DebugLogger.shared.debug("Cancel shortcut: cancelling ASR recording", source: "ContentView")
            Task { await self.asr.stopWithoutTranscription() }
            self.cancelPrewarmDictationIfNeeded()
            handled = true
        }

        if NotchOverlayManager.shared.isBottomOverlayVisible || NotchOverlayManager.shared.isOverlayVisible {
            DebugLogger.shared.debug("Cancel shortcut: hiding recording overlay", source: "ContentView")
            NotchOverlayManager.shared.hide()
            handled = true
        }

        if self.selectedSidebarItem == .rewriteMode {
            DebugLogger.shared.debug("Cancel shortcut: closing mode view", source: "ContentView")
            let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
            self.selectedSidebarItem = isOnboarded ? .preferences : .welcome
            handled = true
        }

        return handled
    }

    // MARK: - Model Management Helpers

    private func isCustomModel(_ model: String) -> Bool {
        // Non-removable defaults are the provider's default models
        return !ModelRepository.shared.defaultModels(for: self.currentProvider).contains(model)
    }

    /// Check if the current model has a reasoning config (either custom or auto-detected)
    private func hasReasoningConfigForCurrentModel() -> Bool {
        let providerKey = self.providerKey(for: self.selectedProviderID)

        // Check for custom config first
        if SettingsStore.shared.hasCustomReasoningConfig(forModel: self.selectedModel, provider: providerKey) {
            if let config = SettingsStore.shared.getReasoningConfig(forModel: selectedModel, provider: providerKey) {
                return config.isEnabled
            }
        }

        // Check for auto-detected models
        let modelLower = self.selectedModel.lowercased()
        return modelLower.hasPrefix("gpt-5") || modelLower.contains("gpt-5.") ||
            modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") ||
            modelLower.contains("gpt-oss") || modelLower.hasPrefix("openai/") ||
            (modelLower.contains("deepseek") && modelLower.contains("reasoner"))
    }

    private func removeModel(_ model: String) {
        // Don't remove if it's currently selected
        if self.selectedModel == model {
            // Switch to first available model that's not the one being removed
            if let firstOther = availableModels.first(where: { $0 != model }) {
                self.selectedModel = firstOther
            }
        }

        // Remove from current provider's model list
        self.availableModels.removeAll { $0 == model }

        // Update the stored models for this provider
        let key = self.providerKey(for: self.selectedProviderID)
        self.availableModelsByProvider[key] = self.availableModels
        SettingsStore.shared.availableModelsByProvider = self.availableModelsByProvider

        // If this is a saved custom provider, update its models array too
        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let updatedProvider = SettingsStore.SavedProvider(
                id: self.savedProviders[providerIndex].id,
                name: self.savedProviders[providerIndex].name,
                baseURL: self.savedProviders[providerIndex].baseURL,
                models: self.availableModels
            )
            self.savedProviders[providerIndex] = updatedProvider
            self.saveSavedProviders()
        }

        // Update selected model mapping for this provider
        self.selectedModelByProvider[key] = self.selectedModel
        SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider
    }

    // Deprecated: hotkey persistence is handled via SettingsStore
}

// SidebarItem enum moved to top of file

// AudioDevice and AudioHardwareObserver moved to Services/AudioDeviceService.swift

// MARK: - ContentView Playground & Onboarding Helpers

extension ContentView {
    private func buildSystemPrompt(
        appInfo: (name: String, bundleId: String, windowTitle: String),
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil
    ) -> String {
        if let slot = dictationSlot ?? self.currentDictationShortcutSlot(for: self.activeRecordingMode) {
            return SettingsStore.shared.effectiveDictationSystemPrompt(for: slot, appBundleID: appInfo.bundleId)
        }
        return SettingsStore.shared.effectiveSystemPrompt(for: .dictate, appBundleID: appInfo.bundleId)
    }

    private var shouldTracePromptProcessing: Bool {
        self.forcePromptTraceToConsole ||
            UserDefaults.standard.bool(forKey: "EnableDebugLogs")
    }

    private var forcePromptTraceToConsole: Bool {
        ProcessInfo.processInfo.environment["FLUID_PROMPT_TRACE"] == "1"
    }

    private func logDictationPromptTrace(_ title: String, value: String) {
        let line = "[PromptTrace][Dictate] \(title):\n\(value)"
        if self.forcePromptTraceToConsole {
            print(line)
        }
        DebugLogger.shared.debug(line, source: "ContentView")
    }

    private func customPromptAnalyticsProperties(promptSource: String, overrideEmpty: Bool?) -> [String: Any] {
        let providerID = SettingsStore.shared.selectedProviderID
        let providerKey = self.providerKey(for: providerID)
        let selectedModel = SettingsStore.shared.selectedModelByProvider[providerKey] ?? SettingsStore.shared.selectedModel ?? ""
        let isCustomProvider = !ModelRepository.shared.isBuiltIn(providerID)
        let providerName = isCustomProvider ? "Custom Provider" : ModelRepository.shared.displayName(for: providerID)

        var properties: [String: Any] = [
            "prompt_source": promptSource,
            "provider_id": isCustomProvider ? "custom" : providerID,
            "provider_name": providerName,
            "provider_type": isCustomProvider ? "custom" : "built_in",
        ]
        if !selectedModel.isEmpty {
            properties["model"] = isCustomProvider ? "custom" : selectedModel
        }
        if let overrideEmpty {
            properties["override_empty"] = overrideEmpty
        }
        return properties
    }

    private func isLocalEndpoint(_ urlString: String) -> Bool {
        ModelRepository.shared.isLocalEndpoint(urlString)
    }

    private func currentDictationShortcutSlot(for mode: ActiveRecordingMode) -> SettingsStore.DictationShortcutSlot? {
        switch mode {
        case .dictate:
            return self.activeDictationShortcutSlot ?? .primary
        case .promptMode:
            return self.activeDictationShortcutSlot ?? .secondary
        case .none, .edit, .command:
            return nil
        }
    }

    private func clearActiveDictationShortcutState() {
        self.activeDictationShortcutSlot = nil
        self.promptModeOverrideText = nil
        NotchContentState.shared.activeDictationShortcutSlot = nil
        NotchContentState.shared.promptModeOverrideProfileName = nil
        NotchContentState.shared.promptModeOverrideProfileID = nil
        NotchContentState.shared.isPromptModeActive = false
    }

    private func applyDictationShortcutSelectionContext(for slot: SettingsStore.DictationShortcutSlot) {
        let settings = SettingsStore.shared
        self.activeDictationShortcutSlot = slot
        NotchContentState.shared.activeDictationShortcutSlot = slot
        NotchContentState.shared.isPromptModeActive = (slot == .secondary)

        switch settings.dictationPromptSelection(for: slot) {
        case .off, .default:
            self.promptModeOverrideText = nil
            NotchContentState.shared.promptModeOverrideProfileName = nil
            NotchContentState.shared.promptModeOverrideProfileID = nil
        case .privateAI:
            self.promptModeOverrideText = nil
            NotchContentState.shared.promptModeOverrideProfileName = PrivateAIProviderFeature.displayName
            NotchContentState.shared.promptModeOverrideProfileID = PrivateAIProviderPromptFormat.promptSelectionID
        case let .profile(profileID):
            guard let profile = settings.selectedDictationPromptProfile(for: slot) ?? settings.dictationPromptProfiles.first(where: {
                $0.id == profileID && $0.mode.normalized == .dictate
            }) else {
                settings.setDictationPromptSelection(.default, for: slot)
                self.promptModeOverrideText = nil
                NotchContentState.shared.promptModeOverrideProfileName = nil
                NotchContentState.shared.promptModeOverrideProfileID = nil
                return
            }

            self.promptModeOverrideText = SettingsStore.combineBasePrompt(
                for: .dictate,
                with: SettingsStore.stripBasePrompt(for: .dictate, from: profile.prompt)
            )
            NotchContentState.shared.promptModeOverrideProfileName = profile.name
            NotchContentState.shared.promptModeOverrideProfileID = profile.id
        }
    }

    private func beginDictationRecording(for slot: SettingsStore.DictationShortcutSlot, mode: ActiveRecordingMode) {
        DebugLogger.shared.debug("Begin dictation recording for slot \(slot.rawValue)", source: "ContentView")
        self.appBench("begin_recording slot=\(slot.rawValue) mode=\(mode.rawValue)")
        if self.isOnboardingVoicePlaygroundStepActive {
            self.asr.finalText = ""
            self.settings.onboardingPlaygroundValidated = false
            self.settings.onboardingPlaygroundSkipped = false
            self.settings.playgroundUsed = false
            self.playgroundUsed = false
        }
        self.applyDictationShortcutSelectionContext(for: slot)
        self.setActiveRecordingMode(mode)
        self.rewriteModeService.clearState()

        guard !self.asr.isRunning else {
            self.appBench("asr_start_skipped reason=already_running")
            return
        }
        self.advanceOverlayLifecycle()
        Task {
            let asrStartStartedAt = ProcessInfo.processInfo.systemUptime
            DebugLogger.shared.benchmark("APP_BENCH", message: "asr_start_call", source: "AppBenchmark")
            if SettingsStore.shared.enableTranscriptionSounds, !self.asr.isRunning {
                TranscriptionSoundPlayer.shared.playStartSound()
            }
            await self.asr.start(onCaptureStarted: {
                self.captureRecordingContext()
                self.applyDictationPromptConfiguration(for: SettingsStore.shared.dictationPromptSelection(for: slot))
                self.appBench("overlay_mode_request mode=Dictation")
                self.menuBarManager.setOverlayMode(.dictation)
                self.menuBarManager.showRecordingOverlayImmediately()
                self.appBench("overlay_mode_requested mode=Dictation")
                self.prewarmPrivateAIDictationIfNeeded(for: slot)
            })
            if !self.asr.isRunning {
                self.menuBarManager.hideRecordingOverlayImmediately(reason: "asr_start_failed")
            }
            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "asr_start_return elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - asrStartStartedAt) * 1000).rounded()))",
                source: "AppBenchmark"
            )
        }
    }

    private func beginDictationRecording(for selection: SettingsStore.DictationPromptSelection, mode: ActiveRecordingMode) {
        let settings = SettingsStore.shared
        settings.setDictationPromptSelection(selection, for: .secondary)
        self.applyDictationPromptConfiguration(for: selection)
        self.beginDictationRecording(for: .secondary, mode: mode)
    }

    private func applyDictationPromptConfiguration(for selection: SettingsStore.DictationPromptSelection) {
        let providerID: String
        let modelName: String

        if selection == .privateAI {
            providerID = PrivateAIProviderFeature.shared.providerID
            modelName = PrivateAIIntegrationService.configuredModelID
        } else {
            let configuration = SettingsStore.shared.dictationPromptConfiguration(for: selection)
            providerID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            modelName = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !providerID.isEmpty, !modelName.isEmpty else { return }
        }

        let providerKey = self.providerKey(for: providerID)
        SettingsStore.shared.selectedProviderID = providerID
        var selectedModels = SettingsStore.shared.selectedModelByProvider
        selectedModels[providerKey] = modelName
        SettingsStore.shared.selectedModelByProvider = selectedModels
        self.selectedProviderID = providerID
        self.currentProvider = providerKey
        self.selectedModelByProvider = selectedModels
        self.selectedModel = modelName
    }

    private func appBench(_ message: String) {
        DebugLogger.shared.benchmark("APP_BENCH", message: message, source: "AppBenchmark")
    }

    private func callOpenAIChat() async {
        guard !self.isCallingAI else { return }
        await MainActor.run { self.isCallingAI = true }
        defer { Task { await MainActor.run { isCallingAI = false } } }

        do {
            let result = try await processTextWithAI(aiInputText)
            await MainActor.run { self.aiOutputText = result }
        } catch {
            DebugLogger.shared.error("callOpenAIChat failed: \(error.localizedDescription)", source: "ContentView")
            await MainActor.run { self.aiOutputText = "Error: \(error.localizedDescription)" }
        }
    }

    private func getModelStatusText() -> String {
        if self.asr.isLoadingModel {
            return "Loading model into memory... (30-60 sec)"
        } else if self.asr.isDownloadingModel {
            return "Downloading model... Please wait."
        } else if self.asr.isAsrReady {
            return "Model is ready to use!"
        } else if self.asr.modelsExistOnDisk {
            return "Model cached. Will load on first use."
        } else {
            return "Model will download when needed."
        }
    }

    private var onboardingVoiceModelReady: Bool {
        self.asr.isAsrReady
    }

    private var onboardingMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    private var onboardingAccessibilityReady: Bool {
        self.accessibilityEnabled
    }

    private var onboardingAIReady: Bool {
        self.settings.onboardingAISkipped || DictationAIPostProcessingGate.isProviderConfigured()
    }

    private var onboardingPlaygroundReady: Bool {
        self.settings.onboardingPlaygroundValidated || self.settings.onboardingPlaygroundSkipped
    }

    @MainActor
    private func revealAppInFinder() {
        let appPath = Bundle.main.bundlePath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
    }

    private func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
}

// MARK: - ContentView Accessibility & Lifecycle Helpers

extension ContentView {
    func completeOnboardingIfPossible(selecting target: SidebarItem? = nil) {
        let missingRequirements = self.missingOnboardingCompletionRequirements()
        guard missingRequirements.isEmpty else {
            self.presentOnboardingCompletionBlocked(missingRequirements)
            return
        }

        self.completeOnboarding(selecting: target)
    }

    func completeOnboardingForAIProviderSetup() {
        let missingRequirements = self.missingOnboardingCompletionRequirements(allowsAIConfiguration: true)
        guard missingRequirements.isEmpty else {
            self.presentOnboardingCompletionBlocked(missingRequirements)
            return
        }

        self.completeOnboarding(selecting: .aiEnhancements)
    }

    private func completeOnboarding(selecting target: SidebarItem? = nil) {
        self.settings.onboardingCompleted = true

        let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
        self.selectedSidebarItem = target ?? (isOnboarded ? .preferences : .welcome)
    }

    private func missingOnboardingCompletionRequirements(allowsAIConfiguration: Bool = false) -> [String] {
        var missing: [String] = []

        if !self.onboardingVoiceModelReady {
            missing.append("voice model")
        }
        if !self.onboardingMicrophoneReady {
            missing.append("microphone access")
        }
        if !self.onboardingAccessibilityReady {
            missing.append("Accessibility access")
        }
        if !allowsAIConfiguration, !self.onboardingAIReady {
            missing.append("AI choice")
        }
        if !self.onboardingPlaygroundReady {
            missing.append("test or skip")
        }

        return missing
    }

    private func presentOnboardingCompletionBlocked(_ missingRequirements: [String]) {
        let missingText = missingRequirements.joined(separator: ", ")
        DebugLogger.shared.warning(
            "Onboarding completion blocked; missing=\(missingText)",
            source: "ContentView"
        )
        self.asr.errorTitle = "Setup Isn't Complete"
        self.asr.errorMessage = "Finish \(missingText) to continue."
        self.asr.showError = true
    }

    func labelFor(status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Microphone: Authorized"
        case .denied: return "Microphone: Denied"
        case .restricted: return "Microphone: Restricted"
        case .notDetermined: return "Microphone: Not Determined"
        @unknown default: return "Microphone: Unknown"
        }
    }

    func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }

    @discardableResult
    private func refreshAccessibilityPermissionState() -> Bool {
        let trusted = self.checkAccessibilityPermissions()
        if trusted != self.accessibilityEnabled {
            self.accessibilityEnabled = trusted
        }
        return trusted
    }

    func openAccessibilitySettings() {
        let requestID = UUID()
        self.accessibilityGuideRequestID = requestID

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        self.didOpenAccessibilityPane = true
        UserDefaults.standard.set(true, forKey: self.accessibilityRestartFlagKey)
        self.startAccessibilityPolling()
        self.positionWindowBesideSystemSettings(requestID: requestID)
        self.showAccessibilityGuidePanel(requestID: requestID)
        self.activateSystemSettingsSoon(requestID: requestID)
    }

    private func positionWindowBesideSystemSettings(requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard self.accessibilityGuideRequestID == requestID else { return }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "FluidVoice" }) ?? NSApp.keyWindow else {
                return
            }

            let screen = self.systemSettingsWindowFrame()
                .flatMap { settingsFrame in
                    NSScreen.screens.first { $0.frame.intersects(settingsFrame) }
                } ?? window.screen ?? NSScreen.main
            guard let screen else { return }

            let visibleFrame = screen.visibleFrame
            let currentSize = window.frame.size
            let guideWidth = min(currentSize.width, max(640, visibleFrame.width * 0.42))
            let guideHeight = min(currentSize.height, visibleFrame.height - 56)
            let targetSize = NSSize(width: guideWidth, height: guideHeight)

            let settingsFrame = self.systemSettingsWindowFrame()
            let gap: CGFloat = 20
            let targetX: CGFloat
            if let settingsFrame, settingsFrame.maxX + gap + targetSize.width <= visibleFrame.maxX {
                targetX = settingsFrame.maxX + gap
            } else if let settingsFrame, settingsFrame.minX - gap - targetSize.width >= visibleFrame.minX {
                targetX = settingsFrame.minX - gap - targetSize.width
            } else {
                targetX = visibleFrame.maxX - targetSize.width - 24
            }

            let targetY: CGFloat
            if let settingsFrame {
                targetY = min(
                    visibleFrame.maxY - targetSize.height - 16,
                    max(visibleFrame.minY + 16, settingsFrame.maxY - targetSize.height)
                )
            } else {
                targetY = visibleFrame.midY - (targetSize.height / 2)
            }

            window.setFrame(
                NSRect(origin: NSPoint(x: targetX, y: targetY), size: targetSize),
                display: true,
                animate: true
            )
            window.orderBack(nil)
        }
    }

    private func systemSettingsWindowFrame() -> NSRect? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard (info[kCGWindowOwnerName as String] as? String) == "System Settings",
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 0,
                  height > 0
            else {
                continue
            }

            for screen in NSScreen.screens {
                let convertedFrame = NSRect(
                    x: x,
                    y: screen.frame.maxY - y - height,
                    width: width,
                    height: height
                )
                if screen.frame.intersects(convertedFrame) {
                    return convertedFrame
                }
            }

            let convertedY = (NSScreen.main?.frame.maxY ?? 0) - y - height
            return NSRect(x: x, y: convertedY, width: width, height: height)
        }

        return nil
    }

    private func showAccessibilityGuidePanel(requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard self.accessibilityGuideRequestID == requestID else { return }
            guard !self.refreshAccessibilityPermissionState() else {
                self.finishAccessibilityPermissionFlow()
                return
            }

            let settingsFrame = self.systemSettingsWindowFrame()
            let screen = settingsFrame
                .flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main
            guard let screen else { return }

            let visibleFrame = screen.visibleFrame
            let panelWidth = min(max((settingsFrame?.width ?? visibleFrame.width * 0.48) * 0.86, 520), 760)
            let panelHeight: CGFloat = 132
            let gap: CGFloat = 14

            let panelX: CGFloat
            let panelY: CGFloat
            if let settingsFrame {
                panelX = min(
                    visibleFrame.maxX - panelWidth - 16,
                    max(visibleFrame.minX + 16, settingsFrame.midX - (panelWidth / 2))
                )
                panelY = max(visibleFrame.minY + 16, settingsFrame.minY - panelHeight - gap)
            } else {
                panelX = visibleFrame.midX - (panelWidth / 2)
                panelY = visibleFrame.minY + 120
            }

            let frame = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
            let panel = self.accessibilityGuidePanel ?? NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(
                rootView: AccessibilitySettingsFloatingGuideView(
                    appURL: self.draggableAccessibilityAppURL,
                    appName: self.accessibilityAppDisplayName,
                    onReturnToApp: {
                        self.cancelAccessibilityPermissionFlow()
                    },
                    onClose: {
                        self.cancelAccessibilityPermissionFlow()
                    }
                )
            )
            panel.setFrame(frame, display: true, animate: self.accessibilityGuidePanel != nil)
            panel.orderFrontRegardless()
            self.accessibilityGuidePanel = panel
            self.startAccessibilityGuidePanelMonitor()
            self.activateSystemSettingsSoon(requestID: requestID)
        }
    }

    private func activateSystemSettingsSoon(requestID: UUID) {
        for delay in [0.25, 0.85, 1.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.accessibilityGuideRequestID == requestID else { return }
                self.activateSystemSettings()
            }
        }
    }

    private func activateSystemSettings() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.SystemSettings" }) ??
            NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }) ??
            NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "System Settings" })
        {
            app.activate(options: [])
        }
    }

    private func cancelAccessibilityPermissionFlow() {
        self.finishAccessibilityPermissionFlow()
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.windows.first { $0.isVisible && $0.title == "FluidVoice" } ?? NSApp.keyWindow)?
            .makeKeyAndOrderFront(nil)
    }

    private func finishAccessibilityPermissionFlow() {
        self.accessibilityGuideRequestID = nil
        self.didOpenAccessibilityPane = false
        self.showRestartPrompt = false
        UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
        self.closeAccessibilityGuidePanel()
        self.stopAccessibilityPolling()
    }

    private func closeAccessibilityGuidePanel() {
        self.accessibilityGuideMonitorTask?.cancel()
        self.accessibilityGuideMonitorTask = nil
        self.accessibilityGuidePanel?.close()
        self.accessibilityGuidePanel = nil
    }

    private func startAccessibilityGuidePanelMonitor() {
        self.accessibilityGuideMonitorTask?.cancel()
        self.accessibilityGuideMonitorTask = Task {
            var missingSettingsCount = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)

                let isTrusted = AXIsProcessTrusted()
                let settingsFrame = await MainActor.run {
                    self.systemSettingsWindowFrame()
                }

                if isTrusted {
                    await MainActor.run {
                        self.refreshAccessibilityPermissionState()
                        self.finishAccessibilityPermissionFlow()
                    }
                    return
                }

                if settingsFrame == nil {
                    missingSettingsCount += 1
                } else {
                    missingSettingsCount = 0
                }

                if missingSettingsCount >= 3 {
                    await MainActor.run {
                        self.cancelAccessibilityPermissionFlow()
                    }
                    return
                }
            }
        }
    }

    private var draggableAccessibilityAppURL: URL {
        let runningAppURL = Bundle.main.bundleURL
        if runningAppURL.pathExtension == "app",
           FileManager.default.fileExists(atPath: runningAppURL.path)
        {
            return runningAppURL
        }

        let installedURL = URL(fileURLWithPath: "/Applications/FluidVoice.app")
        if FileManager.default.fileExists(atPath: installedURL.path) {
            return installedURL
        }
        return Bundle.main.bundleURL
    }

    private var accessibilityAppDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    func restartApp() {
        let appPath = Bundle.main.bundlePath
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = ["-n", appPath]
        // Clear pending flag and hide prompt before restarting
        UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
        self.showRestartPrompt = false
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }

    func startAccessibilityPolling() {
        // Keep polling until macOS reports the current process is trusted. The restart guard
        // only prevents restart loops; it must not prevent the UI from noticing permission changes.
        guard !self.accessibilityEnabled else { return }

        // Cancel any existing polling task
        self.accessibilityPollingTask?.cancel()

        // Start background polling
        self.accessibilityPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Poll every 2 seconds

                // Check if permission was granted
                let nowTrusted = AXIsProcessTrusted()
                if nowTrusted && !self.accessibilityEnabled {
                    await MainActor.run {
                        DebugLogger.shared.info("Accessibility permission granted", source: "ContentView")
                        self.refreshAccessibilityPermissionState()
                        self.finishAccessibilityPermissionFlow()

                        guard !UserDefaults.standard.bool(forKey: self.hasAutoRestartedForAccessibilityKey) else {
                            self.hotkeyManager?.reinitialize()
                            return
                        }

                        // Mark that we've auto-restarted to prevent loops.
                        UserDefaults.standard.set(true, forKey: self.hasAutoRestartedForAccessibilityKey)
                        DebugLogger.shared.info("Auto-restarting app after accessibility grant", source: "ContentView")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.restartApp()
                        }
                    }
                    break // Stop polling after triggering restart
                }
            }
        }
    }

    private func stopAccessibilityPolling() {
        self.accessibilityPollingTask?.cancel()
        self.accessibilityPollingTask = nil
    }
}

// swiftlint:enable type_body_length

private struct AccessibilitySettingsFloatingGuideView: View {
    let appURL: URL
    let appName: String
    let onReturnToApp: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isArrowRaised = false
    @State private var isTokenHovered = false

    private var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: self.appURL.path)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(FluidOnboardingLandingColors.blue)
                    .offset(y: self.reduceMotion ? 0 : (self.isArrowRaised ? -8 : 4))
                    .animation(
                        self.reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: self.isArrowRaised
                    )

                Text("Drag \(self.appName) into the Accessibility apps list as shown")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                Spacer()

                Button {
                    self.onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Close guide")
            }

            HStack(spacing: 12) {
                Button {
                    self.onReturnToApp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Return to \(self.appName)")

                Image(nsImage: self.appIcon)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(self.appName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Spacer()

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(self.isTokenHovered ? 0.095 : 0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(self.isTokenHovered ? 0.16 : 0.08), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { isHovered in
                if self.reduceMotion {
                    self.isTokenHovered = isHovered
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        self.isTokenHovered = isHovered
                    }
                }
            }
            .onDrag {
                NSItemProvider(object: self.appURL as NSURL)
            }
            .accessibilityLabel("Drag \(self.appName) to the Accessibility list")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .onAppear {
            guard !self.reduceMotion else { return }
            self.isArrowRaised = true
        }
    }
}

private extension ContentView {
    func reloadSettingsStateAfterBackupRestore() {
        self.primaryDictationShortcuts = SettingsStore.shared.primaryDictationShortcuts
        self.promptModeHotkeyShortcut = SettingsStore.shared.promptModeHotkeyShortcut
        self.commandModeHotkeyShortcut = SettingsStore.shared.commandModeHotkeyShortcut
        self.rewriteModeHotkeyShortcut = SettingsStore.shared.rewriteModeHotkeyShortcut
        self.cancelRecordingHotkeyShortcut = SettingsStore.shared.cancelRecordingHotkeyShortcut
        self.isPromptModeShortcutEnabled = SettingsStore.shared.promptModeShortcutEnabled
        self.isCommandModeShortcutEnabled = SettingsStore.shared.commandModeShortcutEnabled
        self.isRewriteModeShortcutEnabled = SettingsStore.shared.rewriteModeShortcutEnabled
        self.playgroundUsed = SettingsStore.shared.playgroundUsed
        self.visualizerNoiseThreshold = SettingsStore.shared.visualizerNoiseThreshold
        self.selectedInputUID = AudioDevice.getDefaultInputDevice()?.uid ?? ""
        self.selectedOutputUID = SettingsStore.shared.preferredOutputDeviceUID ?? ""
        self.enableDebugLogs = SettingsStore.shared.enableDebugLogs
        self.hotkeyMode = SettingsStore.shared.hotkeyMode
        self.enableStreamingPreview = SettingsStore.shared.enableStreamingPreview
        self.copyToClipboard = SettingsStore.shared.copyTranscriptionToClipboard
        self.launchAtStartup = SettingsStore.shared.launchAtStartup
        self.showInDock = SettingsStore.shared.showInDock
        self.availableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        self.selectedModelByProvider = SettingsStore.shared.selectedModelByProvider
        self.savedProviders = SettingsStore.shared.savedProviders
        self.selectedProviderID = SettingsStore.shared.selectedProviderID

        self.hotkeyManager?.updatePrimaryShortcuts(self.primaryDictationShortcuts)
        self.hotkeyManager?.updatePromptModeShortcut(self.promptModeHotkeyShortcut)
        self.hotkeyManager?.updatePromptModeShortcutEnabled(self.isPromptModeShortcutEnabled)
        self.hotkeyManager?.updatePromptShortcutAssignments(SettingsStore.shared.dictationPromptShortcutAssignments())
        self.hotkeyManager?.updateCommandModeShortcut(self.commandModeHotkeyShortcut)
        self.hotkeyManager?.updateCommandModeShortcutEnabled(self.isCommandModeShortcutEnabled)
        self.hotkeyManager?.updateRewriteModeShortcut(self.rewriteModeHotkeyShortcut)
        self.hotkeyManager?.updateRewriteModeShortcutEnabled(self.isRewriteModeShortcutEnabled)

        self.currentProvider = self.providerKey(for: self.selectedProviderID)
        if let saved = self.savedProviders.first(where: { $0.id == self.selectedProviderID }) {
            self.availableModels = saved.models
            self.openAIBaseURL = saved.baseURL
        } else if let stored = self.availableModelsByProvider[self.currentProvider], !stored.isEmpty {
            self.availableModels = stored
            self.openAIBaseURL = ModelRepository.shared.defaultBaseURL(for: self.selectedProviderID)
        } else {
            self.availableModels = ModelRepository.shared.defaultModels(for: self.currentProvider)
            self.openAIBaseURL = ModelRepository.shared.defaultBaseURL(for: self.selectedProviderID)
        }

        if let restoredSelectedModel = self.selectedModelByProvider[self.currentProvider],
           self.availableModels.contains(restoredSelectedModel)
        {
            self.selectedModel = restoredSelectedModel
        } else if let firstModel = self.availableModels.first {
            self.selectedModel = firstModel
        }

        self.refreshDevices()
    }
}

private struct TodayStatsToolbarButton: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared

    let typingWPM: Int
    let action: () -> Void

    var body: some View {
        let summary = self.historyStore.todaySummary
        let timeSaved = summary.formattedTimeSaved(typingWPM: self.typingWPM)
        let hasActivity = summary.words > 0

        return Button(action: self.action) {
            HStack(spacing: 4) {
                Image(systemName: hasActivity ? "waveform" : "chart.bar.fill")
                if hasActivity {
                    Text("\(summary.words) words")
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(timeSaved)
                } else {
                    Text("Today")
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .help(hasActivity ? "Today: \(summary.words) words · \(timeSaved) saved - view stats" : "View your stats")
        .accessibilityLabel("Today stats")
    }
}

// MARK: - Card Animation Modifier

struct CardAppearAnimation: ViewModifier {
    let delay: Double
    @Binding var appear: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(self.appear ? 1.0 : 0.96)
            .opacity(self.appear ? 1.0 : 0)
            .animation(.spring(response: 0.8, dampingFraction: 0.75, blendDuration: 0.2).delay(self.delay), value: self.appear)
    }
}
