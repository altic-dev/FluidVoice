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
    case aiSettings
    case preferences
    case meetingTools
    case customDictionary
    case stats
    case history
    case feedback
    case commandMode
    case rewriteMode
}

// MARK: - Minimal FluidAudio ASR Service (finalized text, macOS)

// MARK: - Saved Provider Model

// Removed deprecated inline service and model

// NOTE: Streaming and AI response parsing is now handled by LLMClient

struct ContentView: View {
    @EnvironmentObject private var appServices: AppServices
    @StateObject private var mouseTracker = MousePositionTracker()
    @StateObject private var commandModeService = CommandModeService()
    @StateObject private var rewriteModeService = RewriteModeService()
    @EnvironmentObject private var menuBarManager: MenuBarManager

    // Computed properties to access shared services from AppServices container
    // This maintains backward compatibility with the existing code while
    // removing the duplicate service instances that cause startup crashes.
    private var asr: ASRService { self.appServices.asr }
    private var audioObserver: AudioHardwareObserver { self.appServices.audioObserver }
    @Environment(\.theme) private var theme
    @State private var hotkeyManager: GlobalHotkeyManager? = nil
    @State private var hotkeyManagerInitialized: Bool = false

    @State private var appear = false
    @State private var accessibilityEnabled = false
    @State private var hotkeyShortcut: HotkeyShortcut = SettingsStore.shared.hotkeyShortcut
    @State private var commandModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.commandModeHotkeyShortcut
    @State private var rewriteModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.rewriteModeHotkeyShortcut
    @State private var isCommandModeShortcutEnabled: Bool = SettingsStore.shared.commandModeShortcutEnabled
    @State private var isRewriteModeShortcutEnabled: Bool = SettingsStore.shared.rewriteModeShortcutEnabled
    @State private var isRecordingForRewrite: Bool = false // Track if current recording is for rewrite mode
    @State private var isRecordingForCommand: Bool = false // Track if current recording is for command mode
    @State private var isRecordingShortcut = false
    @State private var isRecordingCommandModeShortcut = false
    @State private var isRecordingRewriteShortcut = false
    @State private var pendingModifierFlags: NSEvent.ModifierFlags = []
    @State private var pendingModifierKeyCode: UInt16?
    @State private var pendingModifierOnly = false
    @FocusState private var isTranscriptionFocused: Bool

    @State private var selectedSidebarItem: SidebarItem? = .welcome
    @State private var previousSidebarItem: SidebarItem? = nil // Track previous for mode transitions
    @State private var playgroundUsed: Bool = SettingsStore.shared.playgroundUsed
    @State private var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)? = nil

    // Command Mode State
    // @State private var showCommandMode: Bool = false

    // Audio Settings Tab State
    @State private var visualizerNoiseThreshold: Double = SettingsStore.shared.visualizerNoiseThreshold
    @State private var inputDevices: [AudioDevice.Device] = []
    @State private var outputDevices: [AudioDevice.Device] = []
    @State private var selectedInputUID: String = SettingsStore.shared.preferredInputDeviceUID ?? ""
    @State private var selectedOutputUID: String = SettingsStore.shared.preferredOutputDeviceUID ?? ""

    // AI Prompts Tab State
    @State private var aiInputText: String = ""
    @State private var aiOutputText: String = ""
    @State private var isCallingAI: Bool = false
    @State private var openAIBaseURL: String = "https://api.openai.com/v1"

    @State private var enableDebugLogs: Bool = SettingsStore.shared.enableDebugLogs
    @State private var pressAndHoldModeEnabled: Bool = SettingsStore.shared.pressAndHoldMode
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
            NavigationSplitView(columnVisibility: self.$columnVisibility) {
                self.sidebarView
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
            } detail: {
                self.detailView
            }
            .navigationSplitViewStyle(.balanced)
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

                // Load saved preferences for UI display (but don't force system defaults)
                // FluidVoice should NOT control system-wide audio routing
                if let prefIn = SettingsStore.shared.preferredInputDeviceUID,
                   prefIn.isEmpty == false,
                   inputDevices.first(where: { $0.uid == prefIn }) != nil
                {
                    self.selectedInputUID = prefIn
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
                if lower == "openai" || lower == "groq" {
                    newKey = lower
                } else {
                    newKey = key.hasPrefix("custom:") ? key : "custom:\\(key)"
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
                let newKey: String = (lower == "openai" || lower == "groq") ? lower :
                    (key.hasPrefix("custom:") ? key : "custom:\\(key)")
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
                self.availableModels = self.defaultModels(for: self.providerKey(for: self.selectedProviderID))
            }

            // Restore previously selected model if valid
            if let sel = selectedModelByProvider[currentProvider], availableModels.contains(sel) {
                self.selectedModel = sel
            } else if let first = availableModels.first {
                self.selectedModel = first
            }

            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                let eventModifiers = event.modifierFlags.intersection([.function, .command, .option, .control, .shift])
                let shortcutModifiers = self.hotkeyShortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])

                let isRecordingAnyShortcut = self.isRecordingShortcut || self.isRecordingCommandModeShortcut || self.isRecordingRewriteShortcut

                if event.type == .keyDown {
                    if event.keyCode == self.hotkeyShortcut.keyCode && eventModifiers == shortcutModifiers {
                        DebugLogger.shared.debug("NSEvent monitor: Global hotkey matched on keyDown, passing event through (GlobalHotkeyManager handles)", source: "ContentView")
                        return event
                    }

                    guard isRecordingAnyShortcut else {
                        if event.keyCode == 53 {
                            // Escape pressed - handle cancellation
                            var handled = false

                            // Close expanded command notch if visible (highest priority)
                            if NotchOverlayManager.shared.isCommandOutputExpanded {
                                DebugLogger.shared
                                    .debug(
                                        "NSEvent monitor: Escape pressed, closing expanded command notch",
                                        source: "ContentView"
                                    )
                                NotchOverlayManager.shared.hideExpandedCommandOutput()
                                handled = true
                            }

                            if self.asr.isRunning {
                                DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling ASR recording", source: "ContentView")
                                Task { await self.asr.stopWithoutTranscription() }
                                handled = true
                            }

                            // Close mode views if active
                            if self.selectedSidebarItem == .commandMode || self.selectedSidebarItem == .rewriteMode {
                                DebugLogger.shared.debug("NSEvent monitor: Escape pressed, closing mode view", source: "ContentView")
                                self.selectedSidebarItem = .welcome
                                handled = true
                            }

                            if handled {
                                return nil // Suppress beep
                            }
                        }
                        self.resetPendingShortcutState()
                        return event
                    }

                    let keyCode = event.keyCode
                    if keyCode == 53 {
                        DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling shortcut recording", source: "ContentView")
                        self.isRecordingShortcut = false
                        self.isRecordingCommandModeShortcut = false
                        self.isRecordingRewriteShortcut = false
                        self.resetPendingShortcutState()
                        return nil
                    }

                    let combinedModifiers = self.pendingModifierFlags.union(eventModifiers)
                    let newShortcut = HotkeyShortcut(keyCode: keyCode, modifierFlags: combinedModifiers)
                    DebugLogger.shared.debug("NSEvent monitor: Recording new shortcut: \(newShortcut.displayString)", source: "ContentView")

                    if self.isRecordingRewriteShortcut {
                        self.rewriteModeHotkeyShortcut = newShortcut
                        SettingsStore.shared.rewriteModeHotkeyShortcut = newShortcut
                        self.hotkeyManager?.updateRewriteModeShortcut(newShortcut)
                        self.isRecordingRewriteShortcut = false
                    } else if self.isRecordingCommandModeShortcut {
                        self.commandModeHotkeyShortcut = newShortcut
                        SettingsStore.shared.commandModeHotkeyShortcut = newShortcut
                        self.hotkeyManager?.updateCommandModeShortcut(newShortcut)
                        self.isRecordingCommandModeShortcut = false
                    } else {
                        self.hotkeyShortcut = newShortcut
                        SettingsStore.shared.hotkeyShortcut = newShortcut
                        self.hotkeyManager?.updateShortcut(newShortcut)
                        self.isRecordingShortcut = false
                    }
                    self.resetPendingShortcutState()
                    DebugLogger.shared.debug("NSEvent monitor: Finished recording shortcut", source: "ContentView")
                    return nil
                } else if event.type == .flagsChanged {
                    if self.hotkeyShortcut.modifierFlags.isEmpty {
                        let isModifierKeyPressed = eventModifiers.isEmpty == false
                        if event.keyCode == self.hotkeyShortcut.keyCode && isModifierKeyPressed {
                            DebugLogger.shared.debug("NSEvent monitor: Global hotkey matched on flagsChanged, passing event through (GlobalHotkeyManager handles)", source: "ContentView")
                            return event
                        }
                    }

                    guard isRecordingAnyShortcut else {
                        self.resetPendingShortcutState()
                        return event
                    }

                    if eventModifiers.isEmpty {
                        if self.pendingModifierOnly, let modifierKeyCode = pendingModifierKeyCode {
                            let newShortcut = HotkeyShortcut(keyCode: modifierKeyCode, modifierFlags: [])
                            DebugLogger.shared.debug("NSEvent monitor: Recording modifier-only shortcut: \(newShortcut.displayString)", source: "ContentView")

                            if self.isRecordingRewriteShortcut {
                                self.rewriteModeHotkeyShortcut = newShortcut
                                SettingsStore.shared.rewriteModeHotkeyShortcut = newShortcut
                                self.hotkeyManager?.updateRewriteModeShortcut(newShortcut)
                                self.isRecordingRewriteShortcut = false
                            } else if self.isRecordingCommandModeShortcut {
                                self.commandModeHotkeyShortcut = newShortcut
                                SettingsStore.shared.commandModeHotkeyShortcut = newShortcut
                                self.hotkeyManager?.updateCommandModeShortcut(newShortcut)
                                self.isRecordingCommandModeShortcut = false
                            } else {
                                self.hotkeyShortcut = newShortcut
                                SettingsStore.shared.hotkeyShortcut = newShortcut
                                self.hotkeyManager?.updateShortcut(newShortcut)
                                self.isRecordingShortcut = false
                            }
                            self.resetPendingShortcutState()
                            DebugLogger.shared.debug("NSEvent monitor: Finished recording modifier shortcut", source: "ContentView")
                            return nil
                        }

                        self.resetPendingShortcutState()
                        DebugLogger.shared.debug("NSEvent monitor: Modifiers released without recording, continuing to wait", source: "ContentView")
                        return nil
                    }

                    // Modifiers are currently pressed
                    var actualKeyCode = event.keyCode
                    if eventModifiers.contains(.function) {
                        actualKeyCode = 63 // fn key
                    } else if eventModifiers.contains(.command) {
                        actualKeyCode = (event.keyCode == 55) ? 55 : 54 // 55 = left cmd, 54 = right cmd
                    } else if eventModifiers.contains(.option) {
                        actualKeyCode = (event.keyCode == 58) ? 58 : 61 // 58 = left opt, 61 = right opt
                    } else if eventModifiers.contains(.control) {
                        actualKeyCode = (event.keyCode == 59) ? 59 : 62 // 59 = left ctrl, 62 = right ctrl
                    } else if eventModifiers.contains(.shift) {
                        actualKeyCode = (event.keyCode == 56) ? 56 : 60 // 56 = left shift, 60 = right shift
                    }

                    self.pendingModifierFlags = eventModifiers
                    self.pendingModifierKeyCode = actualKeyCode
                    self.pendingModifierOnly = true
                    DebugLogger.shared.debug("NSEvent monitor: Modifier key pressed during recording, pending modifiers: \(self.pendingModifierFlags)", source: "ContentView")
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
        .onChange(of: self.isCommandModeShortcutEnabled) { newValue in
            SettingsStore.shared.commandModeShortcutEnabled = newValue
            self.hotkeyManager?.updateCommandModeShortcutEnabled(newValue)

            if !newValue {
                self.isRecordingCommandModeShortcut = false

                if self.isRecordingForCommand {
                    if self.asr.isRunning {
                        Task { await self.asr.stopWithoutTranscription() }
                    }
                    self.isRecordingForCommand = false
                    self.menuBarManager.setOverlayMode(.dictation)
                }
            }
        }
        .onChange(of: self.isRewriteModeShortcutEnabled) { newValue in
            SettingsStore.shared.rewriteModeShortcutEnabled = newValue
            self.hotkeyManager?.updateRewriteModeShortcutEnabled(newValue)

            if !newValue {
                self.isRecordingRewriteShortcut = false

                if self.isRecordingForRewrite {
                    if self.asr.isRunning {
                        Task { await self.asr.stopWithoutTranscription() }
                    }
                    self.isRecordingForRewrite = false
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
                // Check if in write mode (no original text) vs rewrite mode
                if self.rewriteModeService.isWriteMode || self.rewriteModeService.originalText.isEmpty {
                    self.menuBarManager.setOverlayMode(.write)
                } else {
                    self.menuBarManager.setOverlayMode(.rewrite)
                }

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

        switch destination {
        case .preferences:
            self.selectedSidebarItem = .preferences
        }
    }

    private func resetPendingShortcutState() {
        self.pendingModifierFlags = []
        self.pendingModifierKeyCode = nil
        self.pendingModifierOnly = false
    }

    private var sidebarView: some View {
        List(selection: self.$selectedSidebarItem) {
            NavigationLink(value: SidebarItem.welcome) {
                Label("Welcome", systemImage: "house.fill")
                    .font(.system(size: 15, weight: .medium))
            }

            NavigationLink(value: SidebarItem.aiSettings) {
                Label("AI Settings", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .medium))
            }

            NavigationLink(value: SidebarItem.commandMode) {
                Label("Command Mode", systemImage: "terminal.fill")
                    .font(.system(size: 15, weight: .medium))
            }

            NavigationLink(value: SidebarItem.rewriteMode) {
                Label("Write Mode", systemImage: "pencil.and.outline")
                    .font(.system(size: 15, weight: .medium))
            }

            NavigationLink(value: SidebarItem.meetingTools) {
                Label("File Transcription", systemImage: "doc.text.fill")
                    .font(.system(size: 15, weight: .medium))
            }

            NavigationLink(value: SidebarItem.customDictionary) {
                Label("Custom Dictionary", systemImage: "text.book.closed.fill")
                    .font(.system(size: 15, weight: .medium))
            }

            NavigationLink(value: SidebarItem.stats) {
                Label("Stats", systemImage: "chart.bar.fill")
                    .font(.system(size: 15, weight: .medium))
            }

            NavigationLink(value: SidebarItem.history) {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .medium))
            }

            NavigationLink(value: SidebarItem.preferences) {
                Label("Preferences", systemImage: "gearshape.fill")
                    .font(.system(size: 15, weight: .medium))
            }

            NavigationLink(value: SidebarItem.feedback) {
                Label("Feedback", systemImage: "envelope.fill")
                    .font(.system(size: 15, weight: .medium))
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("FluidVoice")
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

    private var detailView: some View {
        ZStack {
            self.theme.palette.windowBackground
                .ignoresSafeArea()

            Rectangle()
                .fill(self.theme.materials.window)
                .ignoresSafeArea()

            self.detailContent
                .transition(.opacity)
        }
    }

    private var detailContent: AnyView {
        switch self.selectedSidebarItem ?? .welcome {
        case .welcome:
            return AnyView(self.welcomeView)
        case .aiSettings:
            return AnyView(AISettingsView())
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

    // MARK: - Welcome Guide

    private var welcomeView: some View {
        WelcomeView(
            selectedSidebarItem: self.$selectedSidebarItem,
            playgroundUsed: self.$playgroundUsed,
            isTranscriptionFocused: self.$isTranscriptionFocused,
            accessibilityEnabled: self.accessibilityEnabled,
            providerAPIKeys: self.providerAPIKeys,
            currentProvider: self.currentProvider,
            openAIBaseURL: self.openAIBaseURL,
            availableModels: self.availableModels,
            selectedModel: self.selectedModel,
            stopAndProcessTranscription: { await self.stopAndProcessTranscription() },
            startRecording: self.startRecording,
            isLocalEndpoint: self.isLocalEndpoint,
            openAccessibilitySettings: self.openAccessibilitySettings
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
            isRecordingShortcut: self.$isRecordingShortcut,
            commandModeShortcut: self.$commandModeHotkeyShortcut,
            isRecordingCommandModeShortcut: self.$isRecordingCommandModeShortcut,
            rewriteShortcut: self.$rewriteModeHotkeyShortcut,
            isRecordingRewriteShortcut: self.$isRecordingRewriteShortcut,
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
            self.selectedSidebarItem = .welcome
        })
    }

    private var rewriteModeView: some View {
        RewriteModeView(service: self.rewriteModeService, onClose: {
            self.selectedSidebarItem = .welcome
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
        self.inputDevices = AudioDevice.listInputDevices()
        self.outputDevices = AudioDevice.listOutputDevices()
    }

    // MARK: - Model Management Functions

    private func saveModels() { SettingsStore.shared.availableModels = self.availableModels }

    // MARK: - Provider Management Functions

    private func providerKey(for providerID: String) -> String {
        if providerID == "openai" || providerID == "groq" { return providerID }
        // Saved providers use their stable id
        return providerID.isEmpty ? self.currentProvider : "custom:\(providerID)"
    }

    private func defaultModels(for providerKey: String) -> [String] {
        switch providerKey {
        case "openai": return ["gpt-4.1"]
        case "groq": return ["openai/gpt-oss-120b"]
        default: return []
        }
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

    /// Build a general system prompt with voice editing commands support
    private func buildSystemPrompt(appInfo: (name: String, bundleId: String, windowTitle: String)) -> String {
        return """
        CRITICAL: You are a TEXT CLEANER, NOT an assistant. You ONLY fix typos and grammar. You NEVER answer, respond, or add content.

        YOUR ONLY JOB: Clean the transcribed text. Return ONLY the cleaned version.

        RULES:
        - Fix grammar, punctuation, capitalization
        - Remove filler words (uh, um, like, you know)
        - Fix obvious typos and transcription errors
        - NEVER answer questions - just clean them and return them as questions
        - NEVER add explanations, responses, or new content
        - NEVER say "I can help" or "Here's" or anything like that
        - If someone says "what is X" → return "What is X?" (cleaned, NOT answered)
        - Output ONLY the cleaned text, nothing else

        VOICE COMMANDS TO PROCESS:
        - "new line" → line break
        - "new paragraph" → double line break
        - "period/comma/question mark" → actual punctuation
        - "bullet point X" → "- X"

        EXAMPLES:
        Input: "uh what is the capital of france"
        Output: "What is the capital of France?"

        Input: "can you help me with this"
        Output: "Can you help me with this?"

        Input: "um the meeting is at um 3 PM"
        Output: "The meeting is at 3 PM."

        Input: "hello new line how are you question mark"
        Output: "Hello
        How are you?"
        """
    }

    // MARK: - Local Endpoint Detection

    private func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host else { return false }

        let hostLower = host.lowercased()

        // Check for localhost variations
        if hostLower == "localhost" || hostLower == "127.0.0.1" {
            return true
        }

        // Check for private IP ranges
        // 127.x.x.x
        if hostLower.hasPrefix("127.") {
            return true
        }
        // 10.x.x.x
        if hostLower.hasPrefix("10.") {
            return true
        }
        // 192.168.x.x
        if hostLower.hasPrefix("192.168.") {
            return true
        }
        // 172.16.x.x - 172.31.x.x
        if hostLower.hasPrefix("172.") {
            let components = hostLower.split(separator: ".")
            if components.count >= 2,
               let secondOctet = Int(components[1]),
               secondOctet >= 16 && secondOctet <= 31
            {
                return true
            }
        }

        return false
    }

    // NOTE: Thinking token filtering is now handled by LLMClient.stripThinkingTags()

    // MARK: - Modular AI Processing

    private func processTextWithAI(_ inputText: String) async -> String {
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
            derivedCurrentProvider = "custom:\(saved.id)"
            derivedBaseURL = saved.baseURL
            derivedSelectedModel = storedSelectedModelByProvider[derivedCurrentProvider] ?? saved.models.first ?? ""
        } else if currentSelectedProviderID == "openai" {
            derivedCurrentProvider = "openai"
            derivedBaseURL = "https://api.openai.com/v1"
            derivedSelectedModel = storedSelectedModelByProvider["openai"] ?? "gpt-4.1"
        } else if currentSelectedProviderID == "groq" {
            derivedCurrentProvider = "groq"
            derivedBaseURL = "https://api.groq.com/openai/v1"
            derivedSelectedModel = storedSelectedModelByProvider["groq"] ?? "llama-3.3-70b-versatile"
        } else {
            derivedCurrentProvider = currentSelectedProviderID
            derivedBaseURL = "https://api.openai.com/v1"
            derivedSelectedModel = storedSelectedModelByProvider[currentSelectedProviderID] ?? ""
        }

        DebugLogger.shared.debug("processTextWithAI using provider=\(derivedCurrentProvider), model=\(derivedSelectedModel)", source: "ContentView")

        // Route to Apple Intelligence if selected
        if currentSelectedProviderID == "apple-intelligence" {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let provider = AppleIntelligenceProvider()
                let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
                let systemPrompt = self.buildSystemPrompt(appInfo: appInfo)
                DebugLogger.shared.debug("Using Apple Intelligence for transcription cleanup", source: "ContentView")
                return await provider.process(systemPrompt: systemPrompt, userText: inputText)
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

        // Get app context captured at start of recording if available
        let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
        let systemPrompt = self.buildSystemPrompt(appInfo: appInfo)
        DebugLogger.shared.debug("Using app context for AI: app=\(appInfo.name), bundleId=\(appInfo.bundleId), title=\(appInfo.windowTitle)", source: "ContentView")

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

    private func stopAndProcessTranscription() async {
        DebugLogger.shared.debug("stopAndProcessTranscription called", source: "ContentView")

        // Check if we're in rewrite or command mode
        let wasRewriteMode = self.isRecordingForRewrite
        let wasCommandMode = self.isRecordingForCommand
        if wasRewriteMode {
            self.isRecordingForRewrite = false
            // Don't reset overlay mode here - let it stay colored until it hides
        }
        if wasCommandMode {
            self.isRecordingForCommand = false
            // Don't reset overlay mode here - let it stay colored until it hides
        }

        // Stop the ASR service and wait for transcription to complete
        // This will set isRunning = false, which triggers overlay hide
        // The overlay will hide while still showing the correct mode color (no gray transition)
        let transcribedText = await asr.stop()

        guard transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            DebugLogger.shared.debug("Transcription returned empty text", source: "ContentView")
            return
        }

        // If this was a rewrite recording, process the rewrite instead of typing
        if wasRewriteMode {
            DebugLogger.shared.info("Processing rewrite with instruction: \(transcribedText)", source: "ContentView")
            await self.processRewriteWithVoiceInstruction(transcribedText)
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

        let finalText: String

        // Check if we should use AI processing
        // IMPORTANT: Derive provider context from SettingsStore so AISettingsView changes take effect immediately.
        let currentProviderID = SettingsStore.shared.selectedProviderID
        let baseURL: String
        if let saved = SettingsStore.shared.savedProviders.first(where: { $0.id == currentProviderID }) {
            baseURL = saved.baseURL
        } else if currentProviderID == "groq" {
            baseURL = "https://api.groq.com/openai/v1"
        } else {
            baseURL = "https://api.openai.com/v1"
        }
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = self.isLocalEndpoint(trimmedBaseURL)
        let apiKey = (SettingsStore.shared.getAPIKey(for: currentProviderID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldUseAI = SettingsStore.shared.enableAIProcessing && (isLocal || !apiKey.isEmpty)

        if shouldUseAI {
            DebugLogger.shared.debug("Routing transcription through AI post-processing", source: "ContentView")

            // Show processing animation in notch
            self.menuBarManager.setProcessing(true)

            finalText = await self.processTextWithAI(transcribedText)

            // Hide processing animation
            self.menuBarManager.setProcessing(false)
        } else {
            finalText = transcribedText
        }

        DebugLogger.shared.info("Transcription finalized (chars: \(finalText.count))", source: "ContentView")

        AnalyticsService.shared.capture(
            .transcriptionCompleted,
            properties: [
                "mode": AnalyticsMode.dictation.rawValue,
                "words_bucket": AnalyticsBuckets.bucketWords(AnalyticsBuckets.wordCount(in: finalText)),
                "ai_used": shouldUseAI,
                "ai_changed_text": transcribedText != finalText,
            ]
        )

        // Save to transcription history (transcription mode only, if enabled)
        if SettingsStore.shared.saveTranscriptionHistory {
            let appInfo = self.recordingAppInfo ?? self.getCurrentAppInfo()
            TranscriptionHistoryStore.shared.addEntry(
                rawText: transcribedText,
                processedText: finalText,
                appName: appInfo.name,
                windowTitle: appInfo.windowTitle
            )
        }

        // Copy to clipboard if enabled (happens before typing as a backup)
        if SettingsStore.shared.copyTranscriptionToClipboard {
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
        await MainActor.run {
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            let frontmostName = frontmostApp?.localizedName ?? "Unknown"
            let isFluidFrontmost = frontmostApp?.bundleIdentifier?.contains("fluid") == true
            let shouldTypeExternally = !isFluidFrontmost || self.isTranscriptionFocused == false

            DebugLogger.shared.debug(
                "Typing decision → frontmost: \(frontmostName), fluidFrontmost: \(isFluidFrontmost), editorFocused: \(self.isTranscriptionFocused), willTypeExternally: \(shouldTypeExternally)",
                source: "ContentView"
            )

            if shouldTypeExternally {
                self.asr.typeTextToActiveField(finalText)
                didTypeExternally = true
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
        } else if SettingsStore.shared.copyTranscriptionToClipboard == false,
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

    // MARK: - Rewrite Mode Voice Processing

    private func processRewriteWithVoiceInstruction(_ instruction: String) async {
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
            self.asr.typeTextToActiveField(self.rewriteModeService.rewrittenText)
            AnalyticsService.shared.capture(
                .outputDelivered,
                properties: [
                    "mode": AnalyticsMode.rewrite.rawValue,
                    "method": AnalyticsOutputMethod.typed.rawValue,
                ]
            )

            // Clear the rewrite service state for next use
            self.rewriteModeService.clearState()
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

    // Capture app context at start to avoid mismatches if the user switches apps mid-session
    private func startRecording() {
        // Ensure normal dictation mode is set (command/rewrite modes set their own)
        if !self.isRecordingForCommand, !self.isRecordingForRewrite {
            self.menuBarManager.setOverlayMode(.dictation)
        }

        let info = self.getCurrentAppInfo()
        self.recordingAppInfo = info
        DebugLogger.shared.debug("Captured recording app context: app=\(info.name), bundleId=\(info.bundleId), title=\(info.windowTitle)", source: "ContentView")
        self.asr.start()

        // Pre-load model in background while recording (avoids 10s freeze on stop)
        Task {
            do {
                try await self.asr.ensureAsrReady()
                DebugLogger.shared.debug("Model pre-loaded during recording", source: "ContentView")
            } catch {
                DebugLogger.shared.error("Failed to pre-load model: \(error)", source: "ContentView")
            }
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

    // MARK: - OpenAI-compatible call for playground

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

    private func labelFor(status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Microphone: Authorized"
        case .denied: return "Microphone: Denied"
        case .restricted: return "Microphone: Restricted"
        case .notDetermined: return "Microphone: Not Determined"
        @unknown default: return "Microphone: Unknown"
        }
    }

    private func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }

    private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        self.didOpenAccessibilityPane = true
        UserDefaults.standard.set(true, forKey: self.accessibilityRestartFlagKey)
    }

    private func restartApp() {
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

    private func startAccessibilityPolling() {
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

    private func revealAppInFinder() {
        let appPath = Bundle.main.bundlePath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
    }

    private func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }

    private func initializeHotkeyManagerIfNeeded() {
        guard self.hotkeyManager == nil else { return }

        self.hotkeyManager = GlobalHotkeyManager(
            asrService: self.asr,
            shortcut: self.hotkeyShortcut,
            commandModeShortcut: self.commandModeHotkeyShortcut,
            rewriteModeShortcut: self.rewriteModeHotkeyShortcut,
            commandModeShortcutEnabled: self.isCommandModeShortcutEnabled,
            rewriteModeShortcutEnabled: self.isRewriteModeShortcutEnabled,
            startRecordingCallback: {
                self.startRecording()
            },
            stopAndProcessCallback: {
                await self.stopAndProcessTranscription()
            },
            commandModeCallback: {
                DebugLogger.shared.info("Command mode triggered", source: "ContentView")

                // Set flag so stopAndProcessTranscription knows to process as command
                self.isRecordingForCommand = true

                // Set overlay mode to command
                self.menuBarManager.setOverlayMode(.command)

                // Start recording immediately for the command
                DebugLogger.shared.info(
                    "Starting voice recording for command",
                    source: "ContentView"
                )
                self.asr.start()
            },
            rewriteModeCallback: {
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
                    // Set overlay mode to write (different visual)
                    self.menuBarManager.setOverlayMode(.write)
                } else {
                    // Text was selected - rewrite mode
                    self.menuBarManager.setOverlayMode(.rewrite)
                }

                // Set flag so stopAndProcessTranscription knows to process as rewrite
                self.isRecordingForRewrite = true

                // Start recording immediately for the rewrite instruction (or text to improve)
                DebugLogger.shared.info("Starting voice recording for rewrite/write mode", source: "ContentView")
                self.asr.start()
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
            if self.isRecordingForCommand {
                self.isRecordingForCommand = false
                self.menuBarManager.setOverlayMode(.dictation)
                handled = true
            }
            if self.isRecordingForRewrite {
                self.isRecordingForRewrite = false
                self.menuBarManager.setOverlayMode(.dictation)
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

    // MARK: - Model Management Helpers

    private func isCustomModel(_ model: String) -> Bool {
        // Non-removable defaults are the provider's default models
        return !self.defaultModels(for: self.currentProvider).contains(model)
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
