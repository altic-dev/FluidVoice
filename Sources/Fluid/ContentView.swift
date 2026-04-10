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
    case feedback
    case commandMode
    case rewriteMode
}

enum ShortcutRecordingTarget: String, Hashable {
    case primaryDictation
    case secondaryDictation
    case command
    case edit
    case cancel

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
        }
    }

    var enablesFeatureOnAssignment: Bool {
        switch self {
        case .secondaryDictation, .command, .edit:
            return true
        case .primaryDictation, .cancel:
            return false
        }
    }
}

// MARK: - Minimal FluidAudio ASR Service (finalized text, macOS)

// MARK: - Saved Provider Model

// Removed deprecated inline service and model

// NOTE: Streaming and AI response parsing is now handled by LLMClient

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
    @State private var hotkeyShortcut: HotkeyShortcut = SettingsStore.shared.hotkeyShortcut
    @State private var promptModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.promptModeHotkeyShortcut
    @State private var commandModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.commandModeHotkeyShortcut
    @State private var rewriteModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.rewriteModeHotkeyShortcut
    @State private var cancelRecordingHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.cancelRecordingHotkeyShortcut
    @State private var isPromptModeShortcutEnabled: Bool = SettingsStore.shared.promptModeShortcutEnabled
    @State private var isCommandModeShortcutEnabled: Bool = SettingsStore.shared.commandModeShortcutEnabled
    @State private var aiSettingsExpanded: Bool = true
    @State private var isRewriteModeShortcutEnabled: Bool = SettingsStore.shared.rewriteModeShortcutEnabled
    @State private var isRecordingForRewrite: Bool = false // Track if current recording is for rewrite mode
    @State private var isRecordingForCommand: Bool = false // Track if current recording is for command mode
    @State private var promptModeOverrideText: String? // System prompt text to use when in prompt mode
    @State private var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot? = nil
    @State private var activeRecordingMode: ActiveRecordingMode = .none
    @State private var activeShortcutRecordingTarget: ShortcutRecordingTarget? = nil
    @State private var currentRecordingModifierKeyCodes: Set<UInt16> = []
    @State private var pendingModifierKeyCodes: Set<UInt16> = []
    @State private var pendingModifierFlags: NSEvent.ModifierFlags = []
    @State private var pendingModifierKeyCode: UInt16?
    @State private var pendingModifierOnly = false
    @State private var shortcutRecordingMessage: String? = nil
    @FocusState private var isTranscriptionFocused: Bool

    @State private var selectedSidebarItem: SidebarItem?
    @State private var previousSidebarItem: SidebarItem? = nil // Track previous for mode transitions
    @State private var playgroundUsed: Bool = SettingsStore.shared.playgroundUsed
    @State private var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)? = nil

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
    @State private var openAIBaseURL: String = ModelRepository.shared.defaultBaseURL(for: "openai")

    @State private var enableDebugLogs: Bool = SettingsStore.shared.enableDebugLogs
    @State private var pressAndHoldModeEnabled: Bool = SettingsStore.shared.pressAndHoldMode
    @State private var enableStreamingPreview: Bool = SettingsStore.shared.enableStreamingPreview
    @State private var copyToClipboard: Bool = SettingsStore.shared.copyTranscriptionToClipboard

    // Preferences Tab State
    @State private var launchAtStartup: Bool = SettingsStore.shared.launchAtStartup
    @State private var showInDock: Bool = SettingsStore.shared.showInDock
    @State private var showRestartPrompt: Bool = false
    @State private var didOpenAccessibilityPane: Bool = false
    private let accessibilityRestartFlagKey = "MedVoice_AccessibilityRestartPending"
    private let hasAutoRestartedForAccessibilityKey = "MedVoice_HasAutoRestartedForAccessibility"
    @State private var accessibilityPollingTask: Task<Void, Never>?

    private var isRecordingAnyShortcutCapture: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    // MARK: - Voice Recognition Model Management

    // Models scoped by provider (name -> [models])
    @State private var availableModelsByProvider: [String: [String]] = [:]
    @State private var selectedModelByProvider: [String: String] = [:]
    @State private var availableModels: [String] = ["gpt-4.1"] // derived from currentProvider
    @State private var selectedModel: String = "gpt-4.1" // derived from currentProvider
    @State private var showingAddModel: Bool = false
    @State private var newModelName: String = ""

    // Model Reasoning Configuration
    @State private var showingReasoningConfig: Bool = false
    @State private var editingReasoningParamName: String = "reasoning_effort"
    @State private var editingReasoningParamValue: String = "low"
    @State private var editingReasoningEnabled: Bool = false

    // MARK: - Provider Management

    @State private var providerAPIKeys: [String: String] = [:] // [providerKey: apiKey]
    @State private var currentProvider: String = "openai" // canonical key: "openai" | "groq" | "custom:<id>"

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

        return nav.onAppear {
            self.appear = true
            self.accessibilityEnabled = self.checkAccessibilityPermissions()

            // Handle any pending menu-bar navigation (e.g., Preferences clicked before window existed).
            self.handleMenuBarNavigation(self.menuBarManager.requestedNavigationDestination)
            // If a previous run set a pending restart, clear it now on fresh launch
            if UserDefaults.standard.bool(forKey: self.accessibilityRestartFlagKey) {
                UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
                self.showRestartPrompt = false
            }
            // Ensure no restart UI shows if we already have trust
            if self.accessibilityEnabled { self.showRestartPrompt = false }

            // Set default selection if none exists (from menu bar navigation)
            // Show Preferences as default once voice model is ready (AI enhancement is optional)
            if self.selectedSidebarItem == nil {
                let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
                self.selectedSidebarItem = isOnboarded ? .preferences : .welcome
            }

            // Reset auto-restart flag if permission was revoked (allows re-triggering if user re-grants)
            if !self.accessibilityEnabled {
                UserDefaults.standard.set(false, forKey: self.hasAutoRestartedForAccessibilityKey)
            }

            // Initialize menu bar after app is ready (prevents window server crash)
            self.menuBarManager.initializeMenuBar()

            // DEFENSIVE STRATEGY: Multi-layer protection against startup crash
            // Layer 1: Service consolidation (already done - no duplicate @StateObjects)
            // Layer 2: Lazy service initialization (services created on first access)
            // Layer 3: Startup gate (signalUIReady + 1.5s delay)
            // Layer 4: Delayed audio initialization (CoreAudio listeners start after UI is stable)
            //
            // This delay ensures SwiftUI's AttributeGraph has finished processing before
            // any heavy audio system work begins. The race condition between CoreAudio's
            // HALSystem initialization and SwiftUI metadata processing causes EXC_BAD_ACCESS at 0x0.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                DebugLogger.shared.info("🚦 Startup delay complete, signaling UI ready...", source: "ContentView")

                // Signal that UI is ready - this enables service initialization
                self.appServices.signalUIReady()

                DebugLogger.shared.info("🔊 Starting delayed audio initialization...", source: "ContentView")

                // Now it's safe to access services (they'll be lazily created)
                self.audioObserver.startObserving()
                self.asr.initialize()

                // Configure menu bar manager with ASR service AFTER services are initialized
                self.menuBarManager.configure(asrService: self.appServices.asr)

                // Load available devices
                self.refreshDevices()

                // Set default selection if empty
                if self.selectedInputUID.isEmpty, let defIn = AudioDevice.getDefaultInputDevice()?.uid { self.selectedInputUID = defIn }
                if self.selectedOutputUID.isEmpty, let defOut = AudioDevice.getDefaultOutputDevice()?.uid { self.selectedOutputUID = defOut }

                // Input device UI should mirror the current macOS default device.
                if let systemInputUID = AudioDevice.getDefaultInputDevice()?.uid,
                   self.inputDevices.contains(where: { $0.uid == systemInputUID })
                {
                    self.selectedInputUID = systemInputUID
                }

                if let prefOut = SettingsStore.shared.preferredOutputDeviceUID,
                   prefOut.isEmpty == false,
                   outputDevices.first(where: { $0.uid == prefOut }) != nil
                {
                    self.selectedOutputUID = prefOut
                }

                DebugLogger.shared.info("✅ Audio subsystems initialized", source: "ContentView")
            }

            // Set up notch click callback for expanding command conversation
            NotchOverlayManager.shared.onNotchClicked = {
                // When notch is clicked in command mode, show expanded conversation
                if !NotchContentState.shared.commandConversationHistory.isEmpty {
                    NotchOverlayManager.shared.showExpandedCommandOutput()
                }
            }

            // Set up command mode callbacks for notch
            NotchOverlayManager.shared.onCommandFollowUp = { [weak commandModeService] text in
                await commandModeService?.processFollowUpCommand(text)
            }

            // Chat management callbacks
            NotchOverlayManager.shared.onNewChat = { [weak commandModeService] in
                commandModeService?.createNewChat()
            }

            NotchOverlayManager.shared.onSwitchChat = { [weak commandModeService] chatID in
                commandModeService?.switchToChat(id: chatID)
            }

            NotchOverlayManager.shared.onClearChat = { [weak commandModeService] in
                commandModeService?.deleteCurrentChat()
            }

            // Start polling for accessibility permission if not granted
            self.startAccessibilityPolling()

            // Initialize hotkey manager with improved timing and validation
            self.initializeHotkeyManagerIfNeeded()

            // Note: Overlay is now managed by MenuBarManager (persists even when window closed)

            // Devices loaded in delayed audio initialization block
            // Device defaults and preferences handled in delayed block

            // Preload ASR model on app startup (with small delay to let app initialize)
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                await self.preloadASRModel()
            }

            // Load saved provider ID first
            self.selectedProviderID = SettingsStore.shared.selectedProviderID

            // Establish provider context first
            self.updateCurrentProvider()

            self.enableDebugLogs = SettingsStore.shared.enableDebugLogs
            self.availableModelsByProvider = SettingsStore.shared.availableModelsByProvider
            self.selectedModelByProvider = SettingsStore.shared.selectedModelByProvider
            self.providerAPIKeys = SettingsStore.shared.providerAPIKeys
            self.savedProviders = SettingsStore.shared.savedProviders

            // Migration & cleanup: normalize provider keys and drop legacy flat lists
            var normalized: [String: [String]] = [:]
            for (key, models) in self.availableModelsByProvider {
                let lower = key.lowercased()
                let newKey: String
                // Use ModelRepository to correctly identify ALL built-in providers
                if ModelRepository.shared.isBuiltIn(lower) {
                    newKey = lower
                } else {
                    newKey = key.hasPrefix("custom:") ? key : "custom:\(key)"
                }
                // Keep only unique, trimmed models
                let clean = Array(Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
                if !clean.isEmpty { normalized[newKey] = clean }
            }
            self.availableModelsByProvider = normalized
            SettingsStore.shared.availableModelsByProvider = normalized

            // Normalize selectedModelByProvider keys similarly and drop invalid selections
            var normalizedSel: [String: String] = [:]
            for (key, model) in self.selectedModelByProvider {
                let lower = key.lowercased()
                // Use ModelRepository to correctly identify ALL built-in providers
                let newKey: String = ModelRepository.shared.isBuiltIn(lower) ? lower :
                    (key.hasPrefix("custom:") ? key : "custom:\(key)")
                if let list = normalized[newKey], list.contains(model) { normalizedSel[newKey] = model }
            }
            self.selectedModelByProvider = normalizedSel
            SettingsStore.shared.selectedModelByProvider = normalizedSel

            // Determine initial model list without legacy flat-list fallback
            if let saved = savedProviders.first(where: { $0.id == selectedProviderID }) {
                // Use models from saved provider
                self.availableModels = saved.models
                self.openAIBaseURL = saved.baseURL
            } else if let stored = availableModelsByProvider[currentProvider], !stored.isEmpty {
                // Use provider-specific stored list if present
                self.availableModels = stored
            } else {
                // Built-in defaults
                self.availableModels = ModelRepository.shared.defaultModels(for: self.providerKey(for: self.selectedProviderID))
            }

            // Restore previously selected model if valid
            if let sel = selectedModelByProvider[currentProvider], availableModels.contains(sel) {
                self.selectedModel = sel
            } else if let first = availableModels.first {
                self.selectedModel = first
            }

            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                let eventModifiers = event.modifierFlags.intersection([.function, .command, .option, .control, .shift])
                let isRecordingAnyShortcut = self.isRecordingAnyShortcutCapture
                let recordingTarget = self.activeShortcutRecordingTarget

                if event.type == .keyDown {
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
                    if keyCode == 53 && recordingTarget != .cancel {
                        DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling shortcut recording", source: "ContentView")
                        self.clearShortcutRecordingMode()
                        return nil
                    }

                    let combinedModifiers = self.pendingModifierFlags.union(eventModifiers)
                    let newShortcut = HotkeyShortcut(keyCode: keyCode, modifierFlags: combinedModifiers)
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
                } else if event.type == .flagsChanged {
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

                    // Keep the actual changed modifier key as the trigger key and preserve
                    // the full pressed modifier set until the combo is finalized.
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

                return event
            }
        }
        .onChange(of: self.accessibilityEnabled) { _, enabled in
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
        .onChange(of: self.isPromptModeShortcutEnabled) { newValue in
            SettingsStore.shared.promptModeShortcutEnabled = newValue
            self.hotkeyManager?.updatePromptModeShortcutEnabled(newValue)

            if !newValue {
                if self.activeShortcutRecordingTarget == .secondaryDictation {
                    self.clearShortcutRecordingMode()
                }

                if self.activeRecordingMode == .promptMode {
                    if self.asr.isRunning {
                        Task { await self.asr.stopWithoutTranscription() }
                    }
                    self.clearActiveRecordingMode()
                    self.menuBarManager.setOverlayMode(.dictation)
                }
            }
        }
        .onChange(of: self.isCommandModeShortcutEnabled) { newValue in
            SettingsStore.shared.commandModeShortcutEnabled = newValue
            self.hotkeyManager?.updateCommandModeShortcutEnabled(newValue)

            if !newValue {
                if self.activeShortcutRecordingTarget == .command {
                    self.clearShortcutRecordingMode()
                }

                if self.activeRecordingMode == .command {
                    if self.asr.isRunning {
                        Task { await self.asr.stopWithoutTranscription() }
                    }
                    self.clearActiveRecordingMode()
                    self.menuBarManager.setOverlayMode(.dictation)
                }
            }
        }
        .onChange(of: self.isRewriteModeShortcutEnabled) { newValue in
            SettingsStore.shared.rewriteModeShortcutEnabled = newValue
            self.hotkeyManager?.updateRewriteModeShortcutEnabled(newValue)

            if !newValue {
                if self.activeShortcutRecordingTarget == .edit {
                    self.clearShortcutRecordingMode()
                }

                if self.activeRecordingMode == .edit {
                    if self.asr.isRunning {
                        Task { await self.asr.stopWithoutTranscription() }
                    }
                    self.clearActiveRecordingMode()
                    self.rewriteModeService.clearState()
                    self.menuBarManager.setOverlayMode(.dictation)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let trusted = AXIsProcessTrusted()
            if trusted != self.accessibilityEnabled {
                self.accessibilityEnabled = trusted
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCustomDictionaryFromVoiceEngine)) { _ in
            self.selectedSidebarItem = .customDictionary
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsBackupDidRestore)) { _ in
            self.reloadSettingsStateAfterBackupRestore()
        }
        .toolbar {
            if !self.settings.shouldShowOnboarding {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: self.openIssueReportingPage) {
                        Image(systemName: "ladybug.fill")
                    }
                    .help("Report an issue")
                    .accessibilityLabel("Report an issue")
                }
            }
        }
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
            // Note: Overlay lifecycle is now managed by MenuBarManager
            // Note: NotchContentState handlers capture self (a struct value copy) and are
            // intentionally kept alive so the overlay remains fully functional when the
            // settings window is closed. No retain cycle risk since ContentView is a value type.

            // Stop accessibility polling
            self.accessibilityPollingTask?.cancel()
            self.accessibilityPollingTask = nil
        }
        .onChange(of: self.hotkeyShortcut) { _, newValue in
            DebugLogger.shared.debug("Hotkey shortcut changed to \(newValue.displayString)", source: "ContentView")
            self.hotkeyManager?.updateShortcut(newValue)

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
        case .preferences:
            self.selectedSidebarItem = .preferences
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
        let configuredShortcuts: [(ShortcutRecordingTarget, HotkeyShortcut)] = [
            (.primaryDictation, self.hotkeyShortcut),
            (.secondaryDictation, self.promptModeHotkeyShortcut),
            (.command, self.commandModeHotkeyShortcut),
            (.edit, self.rewriteModeHotkeyShortcut),
            (.cancel, self.cancelRecordingHotkeyShortcut),
        ]

        for (otherTarget, configuredShortcut) in configuredShortcuts where otherTarget != target {
            if configuredShortcut == shortcut {
                return "Duplicate with \(otherTarget.title)"
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
        case .primaryDictation:
            self.hotkeyShortcut = shortcut
            SettingsStore.shared.hotkeyShortcut = shortcut
            self.hotkeyManager?.updateShortcut(shortcut)
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
        }
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
        case .primaryDictation, .cancel:
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
            // Priority section: Welcome (if not onboarded) or Preferences (if voice model ready)
            // Voice model readiness is the key onboarding milestone; AI enhancement is optional
            let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
            if !isOnboarded {
                NavigationLink(value: SidebarItem.welcome) {
                    Label("Welcome", systemImage: "house.fill")
                        .font(.system(size: 15, weight: .medium))
                }
                .listRowBackground(self.sidebarRowBackground(for: .welcome))
            } else {
                NavigationLink(value: SidebarItem.preferences) {
                    Label("Preferences", systemImage: "gearshape.fill")
                        .font(.system(size: 15, weight: .medium))
                }
                .listRowBackground(self.sidebarRowBackground(for: .preferences))
            }

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.aiSettingsExpanded.toggle()
                }
            }) {
                HStack {
                    Label("AI Settings", systemImage: "sparkles")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(self.aiSettingsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if self.aiSettingsExpanded {
                NavigationLink(value: SidebarItem.voiceEngine) {
                    Label("Voice Engine", systemImage: "waveform")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.leading, 18)
                }
                .listRowBackground(self.sidebarRowBackground(for: .voiceEngine))

                NavigationLink(value: SidebarItem.aiEnhancements) {
                    Label("AI Enhancements", systemImage: "brain")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.leading, 18)
                }
                .listRowBackground(self.sidebarRowBackground(for: .aiEnhancements))
            }

            // If NOT onboarded, Preferences comes here (below AI Settings)
            if !isOnboarded {
                NavigationLink(value: SidebarItem.preferences) {
                    Label("Preferences", systemImage: "gearshape.fill")
                        .font(.system(size: 15, weight: .medium))
                }
                .listRowBackground(self.sidebarRowBackground(for: .preferences))
            }

            NavigationLink(value: SidebarItem.commandMode) {
                Label("Command Mode", systemImage: "terminal.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(self.sidebarRowBackground(for: .commandMode))

            NavigationLink(value: SidebarItem.meetingTools) {
                Label("File Transcription", systemImage: "doc.text.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(self.sidebarRowBackground(for: .meetingTools))

            NavigationLink(value: SidebarItem.customDictionary) {
                Label("Custom Dictionary", systemImage: "text.book.closed.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(self.sidebarRowBackground(for: .customDictionary))

            NavigationLink(value: SidebarItem.stats) {
                Label("Stats", systemImage: "chart.bar.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(self.sidebarRowBackground(for: .stats))

            NavigationLink(value: SidebarItem.history) {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(self.sidebarRowBackground(for: .history))

            NavigationLink(value: SidebarItem.feedback) {
                Label("Feedback", systemImage: "envelope.fill")
                    .font(.system(size: 15, weight: .medium))
            }
            .listRowBackground(self.sidebarRowBackground(for: .feedback))

            // If onboarded, "Getting Started" comes at the bottom
            if isOnboarded {
                NavigationLink(value: SidebarItem.welcome) {
                    Label("Getting Started", systemImage: "house.fill")
                        .font(.system(size: 15, weight: .medium))
                }
                .listRowBackground(self.sidebarRowBackground(for: .welcome))
            }
        }
        .listStyle(.sidebar)
        .animation(nil, value: self.selectedSidebarItem)
        .navigationTitle("MedVoice")
        .scrollContentBackground(.hidden)
        .background {
            ZStack {
                self.theme.palette.sidebarBackground
                Rectangle().fill(self.theme.materials.sidebar)
            }
            .ignoresSafeArea()
        }
        .tint(self.theme.palette.accent)
    }

    private func sidebarRowBackground(for item: SidebarItem) -> some View {
        return Color.clear
    }

    private var detailView: some View {
        ZStack {
            self.theme.palette.windowBackground
                .opacity(0.98)
                .ignoresSafeArea()

            Rectangle()
                .fill(self.theme.materials.window)
                .opacity(0.75)
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
                theme: self.theme
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
            markAISkipped: {
                self.settings.onboardingAISkipped = true
                self.settings.setDictationPromptSelection(.off)
            },
            markPlaygroundValidated: {
                self.settings.onboardingPlaygroundValidated = true
                self.settings.playgroundUsed = true
                self.playgroundUsed = true
            },
            finishOnboarding: {
                self.completeOnboardingIfPossible()
            },
            openAccessibilitySettings: self.openAccessibilitySettings,
            restartApp: self.restartApp,
            menuBarManager: self.menuBarManager,
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
                            .font(.caption)
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
                    .font(.caption)
                Text("How to enable microphone access:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                if self.asr.micStatus == .notDetermined {
                    self.instructionStep(number: "1", text: "Click **Grant Access** above")
                    self.instructionStep(number: "2", text: "Choose **Allow** in the system dialog")
                } else if self.asr.micStatus == .denied {
                    self.instructionStep(number: "1", text: "Click **Open Settings** above")
                    self.instructionStep(number: "2", text: "Find **MedVoice** in the microphone list")
                    self.instructionStep(number: "3", text: "Toggle **MedVoice ON** to allow access")
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
                .font(.caption2)
                .foregroundStyle(self.theme.palette.accent)
                .fontWeight(.semibold)
                .frame(width: 16)
            Text(text)
                .font(.caption)
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
            hotkeyShortcut: self.$hotkeyShortcut,
            activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
            shortcutRecordingMessage: self.$shortcutRecordingMessage,
            promptModeShortcut: self.$promptModeHotkeyShortcut,
            promptModeShortcutEnabled: self.$isPromptModeShortcutEnabled,
            commandModeShortcut: self.$commandModeHotkeyShortcut,
            rewriteShortcut: self.$rewriteModeHotkeyShortcut,
            cancelRecordingShortcut: self.$cancelRecordingHotkeyShortcut,
            commandModeShortcutEnabled: self.$isCommandModeShortcutEnabled,
            rewriteShortcutEnabled: self.$isRewriteModeShortcutEnabled,
            hotkeyManagerInitialized: self.$hotkeyManagerInitialized,
            pressAndHoldModeEnabled: self.$pressAndHoldModeEnabled,
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
        // Built-in providers use their ID directly
        if ModelRepository.shared.isBuiltIn(providerID) { return providerID }
        // Saved providers use their stable id with "custom:" prefix (if not already present)
        if providerID.hasPrefix("custom:") { return providerID }
        return providerID.isEmpty ? self.currentProvider : "custom:\(providerID)"
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

    private func captureRecordingContext() {
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
    ) async -> String {
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
            // Unknown provider - fallback to OpenAI
            derivedCurrentProvider = currentSelectedProviderID
            derivedBaseURL = ModelRepository.shared.defaultBaseURL(for: "openai")
            derivedSelectedModel = storedSelectedModelByProvider[currentSelectedProviderID] ?? ""
        }

        DebugLogger.shared.debug("processTextWithAI using provider=\(derivedCurrentProvider), model=\(derivedSelectedModel)", source: "ContentView")

        // Resolve the effective system prompt once so every provider path
        // honors transient overrides such as "Transcribe with Prompt".
        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        let systemPrompt: String = {
            let override = overrideSystemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !override.isEmpty { return override }
            return self.buildSystemPrompt(appInfo: appInfo, dictationSlot: dictationSlot)
        }()

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
                    self.logDictationPromptTrace("Selected context text", value: "<none (dictation mode)>")
                }
                DebugLogger.shared.debug("Using Apple Intelligence for transcription cleanup", source: "ContentView")
                let output = await provider.process(systemPrompt: systemPrompt, userText: inputText)
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
                return "Error: API Key not set for \(derivedCurrentProvider)"
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
            self.logDictationPromptTrace("Selected context text", value: "<none (dictation mode)>")
        }

        // Check if this is a reasoning model that doesn't support temperature parameter
        let modelLower = derivedSelectedModel.lowercased()
        let isReasoningModel = modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") || modelLower.hasPrefix("gpt-5")

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

        // Build messages array
        let messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": inputText],
        ]

        // NOTE: Transcription doesn't need streaming - the full result appears at once
        // Streaming is only useful for Command/Rewrite modes where real-time display helps
        // Using non-streaming is simpler and more reliable for transcription cleanup
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
            temperature: isReasoningModel ? nil : 0.2,
            extraParameters: extraParams
        )

        DebugLogger.shared.info("Using LLMClient for transcription (streaming=\(enableStreaming))", source: "ContentView")

        do {
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

            return response.content.isEmpty ? "<no content>" : response.content
        } catch {
            DebugLogger.shared.error("AI API error: \(error.localizedDescription)", source: "ContentView")
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Streaming Response Handler (DEPRECATED - Now handled by LLMClient)

    // This method is no longer used - LLMClient.call() handles streaming internally

    // MARK: - Stop and Process Transcription

    private func stopAndProcessTranscription(route: DictationOutputRoute = .normal) async {
        DebugLogger.shared.debug("stopAndProcessTranscription called", source: "ContentView")
        DebugLogger.shared.info("Output route selected: \(route.rawValue)", source: "ContentView")

        // Check if we're in rewrite or command mode
        let modeAtStop = self.activeRecordingMode
        let wasRewriteMode = modeAtStop == .edit || self.isRecordingForRewrite
        let wasCommandMode = modeAtStop == .command || self.isRecordingForCommand
        let activeDictationSlot = self.currentDictationShortcutSlot(for: modeAtStop)
        let promptOverride = self.promptModeOverrideText
        DebugLogger.shared.info(
            "Routing decision snapshot | activeMode=\(modeAtStop.rawValue) | rewrite=\(wasRewriteMode) | command=\(wasCommandMode) | overlay=\(NotchContentState.shared.mode.rawValue)",
            source: "ContentView"
        )

        self.clearActiveRecordingMode()

        // Show "Transcribing..." state before calling stop() to keep overlay visible.
        // The asr.stop() call performs the final transcription which can take a moment
        // (especially for slower models like Whisper Medium/Large).
        DebugLogger.shared.debug("Showing transcription processing state", source: "ContentView")
        self.menuBarManager.setProcessing(true)
        NotchOverlayManager.shared.updateTranscriptionText("Transcribing...")

        // Give SwiftUI a chance to render the processing state before we do heavier work
        // (ASR finalization + optional AI post-processing).
        await Task.yield()

        // Stop the ASR service and wait for transcription to complete
        // The processing indicator will stay visible during this phase
        let transcribedText = await asr.stop()

        // Reset the transcription text display after transcription completes
        NotchOverlayManager.shared.updateTranscriptionText("")

        guard transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            DebugLogger.shared.debug("Transcription returned empty text", source: "ContentView")
            // Hide processing state when returning early
            self.menuBarManager.setProcessing(false)
            return
        }

        // Prompt Test Mode: reroute dictation hotkey output into the prompt editor (no typing/clipboard/history).
        let promptTest = DictationPromptTestCoordinator.shared
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

            let result = await self.processTextWithAI(transcribedText, overrideSystemPrompt: promptTest.draftPromptText)
            let finalText = ASRService.applyGAAVFormatting(result)
            promptTest.lastOutputText = finalText
            return
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

        let shouldUseAI = activeDictationSlot.map { DictationAIPostProcessingGate.isConfigured(for: $0) } ??
            DictationAIPostProcessingGate.isConfigured()
        let transcriptionModelInfo = self.currentTranscriptionModelInfo()

        if shouldUseAI {
            DebugLogger.shared.debug("Routing transcription through AI post-processing", source: "ContentView")
            let postProcessingModelInfo = self.currentDictationAIModelInfo()
            let postProcessingInputChars = transcribedText.count
            let postProcessingStart = Date()

            // Update overlay text to show we're now refining (processing already true)
            NotchOverlayManager.shared.updateTranscriptionText("Refining...")

            // Ensure the status label becomes visible immediately.
            await Task.yield()

            finalText = await self.processTextWithAI(
                transcribedText,
                overrideSystemPrompt: promptOverride,
                dictationSlot: activeDictationSlot
            )
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

            // Hide processing animation
            self.menuBarManager.setProcessing(false)
        } else {
            finalText = transcribedText
            // No AI processing, hide the processing state
            self.menuBarManager.setProcessing(false)
        }

        // Apply GAAV formatting as the FINAL step (after AI post-processing)
        // This ensures the user's preference for no capitalization/period is respected
        finalText = ASRService.applyGAAVFormatting(finalText)
        self.asr.finalText = finalText

        DebugLogger.shared.info("Transcription finalized (chars: \(finalText.count))", source: "ContentView")

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

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostName = frontmostApp?.localizedName ?? "Unknown"
        let isFluidFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        // Save to transcription history (transcription mode only, if enabled)
        if shouldPersistOutputs, SettingsStore.shared.saveTranscriptionHistory {
            let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
            TranscriptionHistoryStore.shared.addEntry(
                rawText: transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle
            )
        }

        // When MedVoice itself is frontmost, the bound editor already receives `finalText`.
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
            // Await typing completion before proceeding to edit tracker
            // This ensures the tracker window opens after text has been typed
            if typingTarget.shouldRestoreOriginalFocus {
                await self.restoreFocusToRecordingTarget()
            }
            self.asr.typeTextToActiveField(
                finalText,
                preferredTargetPID: typingTarget.pid
            )
            didTypeExternally = true
        }

        if didTypeExternally {
            AnalyticsService.shared.capture(
                .outputDelivered,
                properties: [
                    "mode": AnalyticsMode.dictation.rawValue,
                    "method": AnalyticsOutputMethod.typed.rawValue,
                ]
            )

            // Now that typing is complete, start the edit tracker
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

            NotchOverlayManager.shared.hide()
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
    }

    private func currentDictationOutputRouteForHotkeyStop() -> DictationOutputRoute {
        let onboardingPlaygroundStep = 4
        let isOnboardingPlayground = !self.settings.onboardingCompleted &&
            self.settings.onboardingCurrentStep == onboardingPlaygroundStep
        let isDictationMode = self.activeRecordingMode == .dictate || self.activeRecordingMode == .promptMode

        if isOnboardingPlayground && isDictationMode {
            return .onboardingSandbox
        }
        return .normal
    }

    private func reprocessLastDictationFromHistory() {
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
        guard let last = TranscriptionHistoryStore.shared.entries.first else {
            DebugLogger.shared.info("Actions: Copy requested but history is empty", source: "ContentView")
            return
        }

        // Fallback to raw text when no processed text is available
        // (for example older entries or edge cases with AI enhancement off).
        let processed = last.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = last.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = processed.isEmpty ? raw : processed
        guard !text.isEmpty else {
            DebugLogger.shared.info("Actions: Copy skipped because latest history text is empty", source: "ContentView")
            return
        }

        _ = ClipboardService.copyToClipboard(text)
        DebugLogger.shared.info("Actions: Copied latest transcription to clipboard", source: "ContentView")
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
        }

        let finalText = ASRService.applyGAAVFormatting(text)
        let appInfo = self.getCurrentAppInfo()

        if saveToHistory, SettingsStore.shared.saveTranscriptionHistory {
            TranscriptionHistoryStore.shared.addEntry(
                rawText: text,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle
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
            self.asr.typeTextToActiveField(
                finalText,
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
        }

        self.setActiveRecordingMode(.dictate)
        self.menuBarManager.setProcessing(true)
        NotchOverlayManager.shared.updateTranscriptionText("Reprocessing...")
        await Task.yield()

        var finalText = transcribedText
        let shouldUseAI = DictationAIPostProcessingGate.isConfigured()
        if shouldUseAI {
            finalText = await self.processTextWithAI(transcribedText)
        }

        NotchOverlayManager.shared.updateTranscriptionText("")
        self.menuBarManager.setProcessing(false)

        finalText = ASRService.applyGAAVFormatting(finalText)
        let appInfo = self.getCurrentAppInfo()

        if SettingsStore.shared.saveTranscriptionHistory {
            TranscriptionHistoryStore.shared.addEntry(
                rawText: transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle
            )
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
            self.asr.typeTextToActiveField(
                finalText,
                preferredTargetPID: typingTarget.pid
            )
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

        // Hide processing animation
        self.menuBarManager.setProcessing(false)

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

            Task { @MainActor in
                NotchOverlayManager.shared.hide()
            }
        } else {
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
        await self.commandModeService.processUserCommand(command)

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

        self.captureRecordingContext()
        self.setActiveRecordingMode(.dictate)

        // Ensure normal dictation mode is set (command/rewrite modes set their own)
        if !self.isRecordingForCommand, !self.isRecordingForRewrite {
            self.menuBarManager.setOverlayMode(.dictation)
        }

        if !self.isRecordingForCommand, !self.isRecordingForRewrite {
            TranscriptionSoundPlayer.shared.playStartSound()
        }

        Task {
            await self.asr.start()
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

    /// Best-effort: re-activate the app that was focused when recording started.
    /// Adds a short delay after activation so macOS can deliver focus before typing begins.
    private func restoreFocusToRecordingTarget() async {
        guard let pid = NotchContentState.shared.recordingTargetPID else { return }
        let activated = TypingService.activateApp(pid: pid)
        let focusedElementRestored = TypingService.restoreCapturedFocus(in: pid)
        DebugLogger.shared.debug(
            "Restore focus -> appActivated: \(activated), elementFocusRestored: \(focusedElementRestored), targetPID: \(pid)",
            source: "ContentView"
        )
        if activated {
            // Small delay to allow focus to settle before typing events fire.
            let settleNanos: UInt64 = 10_000_000
            try? await Task.sleep(nanoseconds: settleNanos)
        }
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
            self.reprocessLastDictationFromHistory()
        }
        NotchContentState.shared.onCopyLastRequested = {
            self.copyLastDictationFromHistory()
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
            let slot = self.activeDictationShortcutSlot ?? .primary
            SettingsStore.shared.setDictationPromptSelection(selection, for: slot)
            self.applyDictationShortcutSelectionContext(for: slot)
        }

        guard self.hotkeyManager == nil else { return }

        self.hotkeyManager = GlobalHotkeyManager(
            asrService: self.asr,
            shortcut: self.hotkeyShortcut,
            promptModeShortcut: self.promptModeHotkeyShortcut,
            commandModeShortcut: self.commandModeHotkeyShortcut,
            rewriteModeShortcut: self.rewriteModeHotkeyShortcut,
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
            commandModeCallback: {
                DebugLogger.shared.info("Command mode triggered", source: "ContentView")
                self.captureRecordingContext()

                // Set flag so stopAndProcessTranscription knows to process as command
                self.setActiveRecordingMode(.command)

                // Set overlay mode to command
                self.menuBarManager.setOverlayMode(.command)

                guard !self.asr.isRunning else { return }

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

        self.hotkeyManager?.enablePressAndHoldMode(self.pressAndHoldModeEnabled)

        // Set cancel callback for Escape key handling (closes mode views, resets recording state)
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
                self.clearActiveRecordingMode()
                handled = true
            }

            // Close mode views if open
            if self.selectedSidebarItem == .commandMode || self.selectedSidebarItem == .rewriteMode {
                DebugLogger.shared.debug("Cancel callback: closing mode view", source: "ContentView")
                DispatchQueue.main.async {
                    self.selectedSidebarItem = .welcome
                }
                handled = true
            }

            return handled
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
            handled = true
        }

        if NotchOverlayManager.shared.isBottomOverlayVisible || NotchOverlayManager.shared.isOverlayVisible {
            DebugLogger.shared.debug("Cancel shortcut: hiding recording overlay", source: "ContentView")
            NotchOverlayManager.shared.hide()
            handled = true
        }

        if self.selectedSidebarItem == .commandMode || self.selectedSidebarItem == .rewriteMode {
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
        self.captureRecordingContext()
        self.applyDictationShortcutSelectionContext(for: slot)
        self.setActiveRecordingMode(mode)
        self.rewriteModeService.clearState()
        self.menuBarManager.setOverlayMode(.dictation)

        guard !self.asr.isRunning else { return }
        if SettingsStore.shared.enableTranscriptionSounds {
            TranscriptionSoundPlayer.shared.playStartSound()
        }
        Task {
            await self.asr.start()
        }
    }

    private func callOpenAIChat() async {
        guard !self.isCallingAI else { return }
        await MainActor.run { self.isCallingAI = true }
        defer { Task { await MainActor.run { isCallingAI = false } } }

        let result = await processTextWithAI(aiInputText)
        await MainActor.run { self.aiOutputText = result }
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
        self.asr.isAsrReady || self.asr.modelsExistOnDisk || SettingsStore.shared.selectedSpeechModel.isInstalled
    }

    private var onboardingMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    private var onboardingAccessibilityReady: Bool {
        self.accessibilityEnabled
    }

    private var onboardingAIReady: Bool {
        self.settings.onboardingAISkipped || DictationAIPostProcessingGate.isConfigured()
    }

    private var onboardingPlaygroundReady: Bool {
        self.settings.onboardingPlaygroundValidated
    }

    private var canCompleteOnboarding: Bool {
        self.onboardingVoiceModelReady &&
            self.onboardingMicrophoneReady &&
            self.onboardingAccessibilityReady &&
            self.onboardingAIReady &&
            self.onboardingPlaygroundReady
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
    func completeOnboardingIfPossible() {
        guard self.canCompleteOnboarding else { return }

        self.settings.onboardingCompleted = true

        let isOnboarded = self.asr.isAsrReady || self.asr.modelsExistOnDisk
        self.selectedSidebarItem = isOnboarded ? .preferences : .welcome
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

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        self.didOpenAccessibilityPane = true
        UserDefaults.standard.set(true, forKey: self.accessibilityRestartFlagKey)
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
        // Don't poll if already enabled or if we've already auto-restarted once
        guard !self.accessibilityEnabled else { return }
        guard !UserDefaults.standard.bool(forKey: self.hasAutoRestartedForAccessibilityKey) else { return }

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
                        DebugLogger.shared.info("Accessibility permission granted! Auto-restarting app...", source: "ContentView")

                        // Mark that we've auto-restarted to prevent loops
                        UserDefaults.standard.set(true, forKey: self.hasAutoRestartedForAccessibilityKey)

                        // Give user brief moment to see any UI feedback
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.restartApp()
                        }
                    }
                    break // Stop polling after triggering restart
                }
            }
        }
    }
}

private extension ContentView {
    func reloadSettingsStateAfterBackupRestore() {
        self.hotkeyShortcut = SettingsStore.shared.hotkeyShortcut
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
        self.pressAndHoldModeEnabled = SettingsStore.shared.pressAndHoldMode
        self.enableStreamingPreview = SettingsStore.shared.enableStreamingPreview
        self.copyToClipboard = SettingsStore.shared.copyTranscriptionToClipboard
        self.launchAtStartup = SettingsStore.shared.launchAtStartup
        self.showInDock = SettingsStore.shared.showInDock
        self.availableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        self.selectedModelByProvider = SettingsStore.shared.selectedModelByProvider
        self.savedProviders = SettingsStore.shared.savedProviders
        self.selectedProviderID = SettingsStore.shared.selectedProviderID

        self.hotkeyManager?.updateShortcut(self.hotkeyShortcut)
        self.hotkeyManager?.updatePromptModeShortcut(self.promptModeHotkeyShortcut)
        self.hotkeyManager?.updatePromptModeShortcutEnabled(self.isPromptModeShortcutEnabled)
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
