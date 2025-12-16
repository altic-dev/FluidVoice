//
//  ContentView.swift
//  fluid
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import SwiftUI
import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import Security

// MARK: - Sidebar Item Enum

enum SidebarItem: Hashable {
    case welcome
    case aiSettings
    case preferences
    case meetingTools
    case stats
    case history
    case feedback
    case commandMode
    case rewriteMode
}

// MARK: - Minimal FluidAudio ASR Service (finalized text, macOS)

// MARK: - Saved Provider Model
// Removed deprecated inline service and model

// MARK: - Streaming Response Structures
private struct StreamingDelta: Codable { let role: String?; let content: String? }
private struct StreamingChoice: Codable { let index: Int?; let delta: StreamingDelta; let finish_reason: String? }
private struct StreamingChunk: Codable { let choices: [StreamingChoice] }

// MARK: - AI Processing Response Structures
// NOTE: Keep Codable types out of View methods to avoid SwiftUI/metadata blowups at launch.
private struct AIProcessingMessage: Codable { let role: String; let content: String }
private struct AIProcessingChoiceMessage: Codable { let role: String; let content: String }
private struct AIProcessingChoice: Codable { let index: Int?; let message: AIProcessingChoiceMessage }
private struct AIProcessingResponse: Codable { let choices: [AIProcessingChoice] }

struct ContentView: View {
    @StateObject private var audioObserver = AudioHardwareObserver()
    @StateObject private var asr = ASRService()
    @StateObject private var mouseTracker = MousePositionTracker()
    @StateObject private var commandModeService = CommandModeService()
    @StateObject private var rewriteModeService = RewriteModeService()
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @Environment(\.theme) private var theme
    @State private var hotkeyManager: GlobalHotkeyManager? = nil
    @State private var hotkeyManagerInitialized: Bool = false
    
    @State private var appear = false
    @State private var accessibilityEnabled = false
    @State private var hotkeyShortcut: HotkeyShortcut = SettingsStore.shared.hotkeyShortcut
    @State private var commandModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.commandModeHotkeyShortcut
    @State private var rewriteModeHotkeyShortcut: HotkeyShortcut = SettingsStore.shared.rewriteModeHotkeyShortcut
    @State private var isRecordingForRewrite: Bool = false  // Track if current recording is for rewrite mode
    @State private var isRecordingForCommand: Bool = false  // Track if current recording is for command mode
    @State private var isRecordingShortcut = false
    @State private var isRecordingCommandModeShortcut = false
    @State private var isRecordingRewriteShortcut = false
    @State private var pendingModifierFlags: NSEvent.ModifierFlags = []
    @State private var pendingModifierKeyCode: UInt16?
    @State private var pendingModifierOnly = false
    @FocusState private var isTranscriptionFocused: Bool
    
    @State private var selectedSidebarItem: SidebarItem? = .welcome
    @State private var previousSidebarItem: SidebarItem? = nil  // Track previous for mode transitions
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



    var body: some View {
        let splitView: AnyView = AnyView(
            NavigationSplitView {
                sidebarView
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
            } detail: {
                detailView
            }
        )

        let tracked = splitView.withMouseTracking(mouseTracker)
        let env = tracked.environmentObject(mouseTracker)
        let nav = env.onChange(of: menuBarManager.requestedNavigationDestination) { _, destination in
            handleMenuBarNavigation(destination)
        }

        return nav.onAppear {
            appear = true
            accessibilityEnabled = checkAccessibilityPermissions()
            
            // Handle any pending menu-bar navigation (e.g., Preferences clicked before window existed).
            handleMenuBarNavigation(menuBarManager.requestedNavigationDestination)
            // If a previous run set a pending restart, clear it now on fresh launch
            if UserDefaults.standard.bool(forKey: accessibilityRestartFlagKey) {
                UserDefaults.standard.set(false, forKey: accessibilityRestartFlagKey)
                showRestartPrompt = false
            }
            // Ensure no restart UI shows if we already have trust
            if accessibilityEnabled { showRestartPrompt = false }
            
            // Reset auto-restart flag if permission was revoked (allows re-triggering if user re-grants)
            if !accessibilityEnabled {
                UserDefaults.standard.set(false, forKey: hasAutoRestartedForAccessibilityKey)
            }
            
            // Initialize menu bar after app is ready (prevents window server crash)
            menuBarManager.initializeMenuBar()
            
            // Configure menu bar manager with ASR service
            menuBarManager.configure(asrService: asr)
            
            // CRITICAL FIX: Defer all audio subsystem initialization by 1.5 seconds.
            // There is a known race condition between CoreAudio's HALSystem initialization (triggered by 
            // AudioObjectAddPropertyListenerBlock) and SwiftUI's AttributeGraph metadata processing during app launch.
            // This race causes an EXC_BAD_ACCESS (SIGSEGV) at 0x0.
            // By waiting for the main runloop to settle and SwiftUI to finish its initial layout passes,
            // we ensure the audio system initializes safely.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                DebugLogger.shared.info("🔊 Starting delayed audio initialization...", source: "ContentView")
                
                audioObserver.startObserving()
                asr.initialize()
                
                // Load available devices
                refreshDevices()
                
                // Set default selection if empty
                if selectedInputUID.isEmpty, let defIn = AudioDevice.getDefaultInputDevice()?.uid { selectedInputUID = defIn }
                if selectedOutputUID.isEmpty, let defOut = AudioDevice.getDefaultOutputDevice()?.uid { selectedOutputUID = defOut }
                
                // Load saved preferences for UI display (but don't force system defaults)
                // FluidVoice should NOT control system-wide audio routing
                if let prefIn = SettingsStore.shared.preferredInputDeviceUID,
                   prefIn.isEmpty == false,
                   inputDevices.first(where: { $0.uid == prefIn }) != nil
                {
                    selectedInputUID = prefIn
                }
                
                if let prefOut = SettingsStore.shared.preferredOutputDeviceUID,
                   prefOut.isEmpty == false,
                   outputDevices.first(where: { $0.uid == prefOut }) != nil
                {
                    selectedOutputUID = prefOut
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
            startAccessibilityPolling()
            
            // Initialize hotkey manager with improved timing and validation
            initializeHotkeyManagerIfNeeded()
            
            // Note: Overlay is now managed by MenuBarManager (persists even when window closed)
            
            // Devices loaded in delayed audio initialization block
            // Device defaults and preferences handled in delayed block
            
            // Preload ASR model on app startup (with small delay to let app initialize)
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                await preloadASRModel()
            }
            
            // Load saved provider ID first
            selectedProviderID = SettingsStore.shared.selectedProviderID
            
            // Establish provider context first
            updateCurrentProvider()

            enableDebugLogs = SettingsStore.shared.enableDebugLogs
            availableModelsByProvider = SettingsStore.shared.availableModelsByProvider
            selectedModelByProvider = SettingsStore.shared.selectedModelByProvider
            providerAPIKeys = SettingsStore.shared.providerAPIKeys
            savedProviders = SettingsStore.shared.savedProviders

            // Migration & cleanup: normalize provider keys and drop legacy flat lists
            var normalized: [String: [String]] = [:]
            for (key, models) in availableModelsByProvider {
                let lower = key.lowercased()
                let newKey: String
                if lower == "openai" || lower == "groq" { newKey = lower }
                else { newKey = key.hasPrefix("custom:") ? key : "custom:\\(key)" }
                // Keep only unique, trimmed models
                let clean = Array(Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
                if !clean.isEmpty { normalized[newKey] = clean }
            }
            availableModelsByProvider = normalized
            SettingsStore.shared.availableModelsByProvider = normalized

            // Normalize selectedModelByProvider keys similarly and drop invalid selections
            var normalizedSel: [String: String] = [:]
            for (key, model) in selectedModelByProvider {
                let lower = key.lowercased()
                let newKey: String = (lower == "openai" || lower == "groq") ? lower : (key.hasPrefix("custom:") ? key : "custom:\\(key)")
                if let list = normalized[newKey], list.contains(model) { normalizedSel[newKey] = model }
            }
            selectedModelByProvider = normalizedSel
            SettingsStore.shared.selectedModelByProvider = normalizedSel

            // Determine initial model list without legacy flat-list fallback
            if let saved = savedProviders.first(where: { $0.id == selectedProviderID }) {
                // Use models from saved provider
                availableModels = saved.models
                openAIBaseURL = saved.baseURL
            } else if let stored = availableModelsByProvider[currentProvider], !stored.isEmpty {
                // Use provider-specific stored list if present
                availableModels = stored
            } else {
                // Built-in defaults
                availableModels = defaultModels(for: providerKey(for: selectedProviderID))
            }

            // Restore previously selected model if valid
            if let sel = selectedModelByProvider[currentProvider], availableModels.contains(sel) {
                selectedModel = sel
            } else if let first = availableModels.first {
                selectedModel = first
            }
            
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                let eventModifiers = event.modifierFlags.intersection([.function, .command, .option, .control, .shift])
                let shortcutModifiers = hotkeyShortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])
                
                let isRecordingAnyShortcut = isRecordingShortcut || isRecordingCommandModeShortcut || isRecordingRewriteShortcut
                DebugLogger.shared.debug("NSEvent \(event.type) keyCode=\(event.keyCode) recordingShortcut=\(isRecordingShortcut) recordingCommand=\(isRecordingCommandModeShortcut) recordingRewrite=\(isRecordingRewriteShortcut)", source: "ContentView")

                if event.type == .keyDown {
                    if event.keyCode == hotkeyShortcut.keyCode && eventModifiers == shortcutModifiers {
                        DebugLogger.shared.debug("NSEvent monitor: Global hotkey matched on keyDown, passing event through (GlobalHotkeyManager handles)", source: "ContentView")
                        return event
                    }

                    guard isRecordingAnyShortcut else {
                        if event.keyCode == 53 {
                            // Escape pressed - handle cancellation
                            var handled = false
                            
                            // Close expanded command notch if visible (highest priority)
                            if NotchOverlayManager.shared.isCommandOutputExpanded {
                                DebugLogger.shared.debug("NSEvent monitor: Escape pressed, closing expanded command notch", source: "ContentView")
                                NotchOverlayManager.shared.hideExpandedCommandOutput()
                                handled = true
                            }
                            
                            if asr.isRunning {
                                DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling ASR recording", source: "ContentView")
                                asr.stopWithoutTranscription()
                                handled = true
                            }
                            
                            // Close mode views if active
                            if selectedSidebarItem == .commandMode || selectedSidebarItem == .rewriteMode {
                                DebugLogger.shared.debug("NSEvent monitor: Escape pressed, closing mode view", source: "ContentView")
                                selectedSidebarItem = .welcome
                                handled = true
                            }
                            
                            if handled {
                                return nil  // Suppress beep
                            }
                        }
                        resetPendingShortcutState()
                        return event
                    }
                    
                    let keyCode = event.keyCode
                    if keyCode == 53 {
                        DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling shortcut recording", source: "ContentView")
                        isRecordingShortcut = false
                        isRecordingCommandModeShortcut = false
                        isRecordingRewriteShortcut = false
                        resetPendingShortcutState()
                        return nil
                    }
                    
                    let combinedModifiers = pendingModifierFlags.union(eventModifiers)
                    let newShortcut = HotkeyShortcut(keyCode: keyCode, modifierFlags: combinedModifiers)
                    DebugLogger.shared.debug("NSEvent monitor: Recording new shortcut: \(newShortcut.displayString)", source: "ContentView")
                    
                    if isRecordingRewriteShortcut {
                        rewriteModeHotkeyShortcut = newShortcut
                        SettingsStore.shared.rewriteModeHotkeyShortcut = newShortcut
                        hotkeyManager?.updateRewriteModeShortcut(newShortcut)
                        isRecordingRewriteShortcut = false
                    } else if isRecordingCommandModeShortcut {
                        commandModeHotkeyShortcut = newShortcut
                        SettingsStore.shared.commandModeHotkeyShortcut = newShortcut
                        hotkeyManager?.updateCommandModeShortcut(newShortcut)
                        isRecordingCommandModeShortcut = false
                    } else {
                        hotkeyShortcut = newShortcut
                        SettingsStore.shared.hotkeyShortcut = newShortcut
                        hotkeyManager?.updateShortcut(newShortcut)
                        isRecordingShortcut = false
                    }
                    resetPendingShortcutState()
                    DebugLogger.shared.debug("NSEvent monitor: Finished recording shortcut", source: "ContentView")
                    return nil
                } else if event.type == .flagsChanged {
                    if hotkeyShortcut.modifierFlags.isEmpty {
                        let isModifierKeyPressed = eventModifiers.isEmpty == false
                        if event.keyCode == hotkeyShortcut.keyCode && isModifierKeyPressed {
                            DebugLogger.shared.debug("NSEvent monitor: Global hotkey matched on flagsChanged, passing event through (GlobalHotkeyManager handles)", source: "ContentView")
                            return event
                        }
                    }

                    guard isRecordingAnyShortcut else {
                        resetPendingShortcutState()
                        return event
                    }

                    if eventModifiers.isEmpty {
                        if pendingModifierOnly, let modifierKeyCode = pendingModifierKeyCode {
                            let newShortcut = HotkeyShortcut(keyCode: modifierKeyCode, modifierFlags: [])
                            DebugLogger.shared.debug("NSEvent monitor: Recording modifier-only shortcut: \(newShortcut.displayString)", source: "ContentView")
                            
                            if isRecordingRewriteShortcut {
                                rewriteModeHotkeyShortcut = newShortcut
                                SettingsStore.shared.rewriteModeHotkeyShortcut = newShortcut
                                hotkeyManager?.updateRewriteModeShortcut(newShortcut)
                                isRecordingRewriteShortcut = false
                            } else if isRecordingCommandModeShortcut {
                                commandModeHotkeyShortcut = newShortcut
                                SettingsStore.shared.commandModeHotkeyShortcut = newShortcut
                                hotkeyManager?.updateCommandModeShortcut(newShortcut)
                                isRecordingCommandModeShortcut = false
                            } else {
                                hotkeyShortcut = newShortcut
                                SettingsStore.shared.hotkeyShortcut = newShortcut
                                hotkeyManager?.updateShortcut(newShortcut)
                                isRecordingShortcut = false
                            }
                            resetPendingShortcutState()
                            DebugLogger.shared.debug("NSEvent monitor: Finished recording modifier shortcut", source: "ContentView")
                            return nil
                        }

                        resetPendingShortcutState()
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

                    pendingModifierFlags = eventModifiers
                    pendingModifierKeyCode = actualKeyCode
                    pendingModifierOnly = true
                    DebugLogger.shared.debug("NSEvent monitor: Modifier key pressed during recording, pending modifiers: \(pendingModifierFlags)", source: "ContentView")
                    return nil
                }
                
                return event
            }
        }
        .onChange(of: accessibilityEnabled) { _, enabled in
            if enabled && hotkeyManager != nil && !hotkeyManagerInitialized {
                DebugLogger.shared.debug("Accessibility enabled, reinitializing hotkey manager", source: "ContentView")
                hotkeyManager?.reinitialize()
            }
        }
        .onChange(of: selectedModel) { _, newValue in
            if newValue != "__ADD_MODEL__" {
                selectedModelByProvider[currentProvider] = newValue
                SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
            }
        }
        .onChange(of: selectedProviderID) { _, newValue in
            SettingsStore.shared.selectedProviderID = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            let trusted = AXIsProcessTrusted()
            if trusted != accessibilityEnabled {
                accessibilityEnabled = trusted
            }
        }
        .overlay(alignment: .center) {
        }

        .alert(asr.errorTitle, isPresented: $asr.showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(asr.errorMessage)
        }
        .onChange(of: audioObserver.changeTick) { _, _ in
            // Hardware change detected → refresh device lists only
            // NOTE: We do NOT force system defaults here anymore.
            // FluidVoice should not hijack system-wide audio routing.
            // The saved preferences are only used when FluidVoice actively records.
            refreshDevices()

            // Just sync the UI to show current system defaults (don't force them)
            if let sysIn = AudioDevice.getDefaultInputDevice()?.uid {
                selectedInputUID = sysIn
            }
            if let sysOut = AudioDevice.getDefaultOutputDevice()?.uid {
                selectedOutputUID = sysOut
            }
        }
        .onDisappear {
            asr.stopWithoutTranscription()
            // Note: Overlay lifecycle is now managed by MenuBarManager
            
            // Stop accessibility polling
            accessibilityPollingTask?.cancel()
            accessibilityPollingTask = nil
        }
        .onChange(of: hotkeyShortcut) { _, newValue in
            DebugLogger.shared.debug("Hotkey shortcut changed to \(newValue.displayString)", source: "ContentView")
            hotkeyManager?.updateShortcut(newValue)

            // Update initialization status after shortcut change
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                DebugLogger.shared.debug("Hotkey manager initialized: \(self.hotkeyManagerInitialized)", source: "ContentView")
            }
        }
        .onChange(of: selectedSidebarItem) { _, newValue in
            handleModeTransition(from: previousSidebarItem, to: newValue)
            previousSidebarItem = newValue
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
                rewriteModeService.clearState()
                
            default:
                break
            }
        }
        
        // Set up state for the new mode
        if let new = newValue {
            switch new {
            case .commandMode:
                menuBarManager.setOverlayMode(.command)
                
            case .rewriteMode:
                // Check if in write mode (no original text) vs rewrite mode
                if rewriteModeService.isWriteMode || rewriteModeService.originalText.isEmpty {
                    menuBarManager.setOverlayMode(.write)
                } else {
                    menuBarManager.setOverlayMode(.rewrite)
                }
                
            default:
                // For all other views, set to dictation mode
                menuBarManager.setOverlayMode(.dictation)
            }
        } else {
            // If newValue is nil, default to dictation
            menuBarManager.setOverlayMode(.dictation)
        }
    }
    
    @MainActor
    private func handleMenuBarNavigation(_ destination: MenuBarNavigationDestination?) {
        guard let destination else { return }
        defer { menuBarManager.requestedNavigationDestination = nil }
        
        switch destination {
        case .preferences:
            selectedSidebarItem = .preferences
        }
    }

    private func resetPendingShortcutState()
    {
        pendingModifierFlags = []
        pendingModifierKeyCode = nil
        pendingModifierOnly = false
    }

    private var sidebarView: some View {
        List(selection: $selectedSidebarItem) {
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
                theme.palette.sidebarBackground
                Rectangle().fill(theme.materials.sidebar)
            }
            .ignoresSafeArea()
        }
        .tint(theme.palette.accent)
    }
    
    private var detailView: some View {
        ZStack {
            theme.palette.windowBackground
                .ignoresSafeArea()

            Rectangle()
                .fill(theme.materials.window)
                .ignoresSafeArea()

            detailContent
                .transition(.opacity)
        }
        .toolbar(.hidden, for: .automatic)
    }

    private var detailContent: AnyView {
        switch selectedSidebarItem ?? .welcome {
        case .welcome:
            return AnyView(welcomeView)
        case .aiSettings:
            return AnyView(AISettingsView())
        case .preferences:
            return AnyView(preferencesView)
        case .meetingTools:
            return AnyView(meetingToolsView)
        case .stats:
            return AnyView(statsView)
        case .feedback:
            return AnyView(FeedbackView())
        case .commandMode:
            return AnyView(commandModeView)
        case .rewriteMode:
            return AnyView(rewriteModeView)
        case .history:
            return AnyView(TranscriptionHistoryView())
        }
    }

    // MARK: - Welcome Guide
    private var welcomeView: some View {
        WelcomeView(

            selectedSidebarItem: $selectedSidebarItem,
            playgroundUsed: $playgroundUsed,
            isTranscriptionFocused: $isTranscriptionFocused,
            accessibilityEnabled: accessibilityEnabled,
            providerAPIKeys: providerAPIKeys,
            currentProvider: currentProvider,
            openAIBaseURL: openAIBaseURL,
            availableModels: availableModels,
            selectedModel: selectedModel,
            stopAndProcessTranscription: { await stopAndProcessTranscription() },
            startRecording: startRecording,
            isLocalEndpoint: isLocalEndpoint,
            openAccessibilitySettings: openAccessibilitySettings
        )
    }
    
    // MARK: - Microphone Permission View (Kept inline for RecordingView)
    private var microphonePermissionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(asr.micStatus == .authorized ? theme.palette.success : theme.palette.warning)
                    .frame(width: 10, height: 10)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(labelFor(status: asr.micStatus))
                        .fontWeight(.medium)
                        .foregroundStyle(asr.micStatus == .authorized ? theme.palette.primaryText : theme.palette.warning)
                    
                    if asr.micStatus != .authorized {
                        Text("Microphone access is required for voice recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                
                microphoneActionButton
            }
            
            // Step-by-step instructions when microphone is not authorized
            if asr.micStatus != .authorized {
                microphoneInstructionsView
            }
        }
    }
    
    private var microphoneActionButton: some View {
        Group {
            if asr.micStatus == .notDetermined {
                Button {
                    asr.requestMicAccess()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                        Text("Grant Access")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            } else if asr.micStatus == .denied {
                Button {
                    asr.openSystemSettingsForMic()
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
                    .foregroundStyle(theme.palette.accent)
                    .font(.caption)
                Text("How to enable microphone access:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                if asr.micStatus == .notDetermined {
                    instructionStep(number: "1", text: "Click **Grant Access** above")
                    instructionStep(number: "2", text: "Choose **Allow** in the system dialog")
                } else if asr.micStatus == .denied {
                    instructionStep(number: "1", text: "Click **Open Settings** above")
                    instructionStep(number: "2", text: "Find **FluidVoice** in the microphone list")
                    instructionStep(number: "3", text: "Toggle **FluidVoice ON** to allow access")
                }
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(theme.palette.accent.opacity(0.12))
        .cornerRadius(8)
    }
    
    private func instructionStep(number: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(number + ".")
                .font(.caption2)
                .foregroundStyle(theme.palette.accent)
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

            appear: $appear,
            visualizerNoiseThreshold: $visualizerNoiseThreshold,
            selectedInputUID: $selectedInputUID,
            selectedOutputUID: $selectedOutputUID,
            inputDevices: $inputDevices,
            outputDevices: $outputDevices,
            accessibilityEnabled: $accessibilityEnabled,
            hotkeyShortcut: $hotkeyShortcut,
            isRecordingShortcut: $isRecordingShortcut,
            commandModeShortcut: $commandModeHotkeyShortcut,
            isRecordingCommandModeShortcut: $isRecordingCommandModeShortcut,
            rewriteShortcut: $rewriteModeHotkeyShortcut,
            isRecordingRewriteShortcut: $isRecordingRewriteShortcut,
            hotkeyManagerInitialized: $hotkeyManagerInitialized,
            pressAndHoldModeEnabled: $pressAndHoldModeEnabled,
            enableStreamingPreview: $enableStreamingPreview,
            copyToClipboard: $copyToClipboard,
            hotkeyManager: hotkeyManager,
            menuBarManager: menuBarManager,
            startRecording: startRecording,
            refreshDevices: refreshDevices,
            openAccessibilitySettings: openAccessibilitySettings,
            restartApp: restartApp,
            revealAppInFinder: revealAppInFinder,
            openApplicationsFolder: openApplicationsFolder
        )
    }

    private var recordingView: some View {
        RecordingView(

            appear: $appear,
            stopAndProcessTranscription: { await stopAndProcessTranscription() },
            startRecording: startRecording
        )
    }
    
    private var commandModeView: some View {
        CommandModeView(service: commandModeService, onClose: {
            self.selectedSidebarItem = .welcome
        })
    }
    
    private var rewriteModeView: some View {
        RewriteModeView(service: rewriteModeService, onClose: {
            self.selectedSidebarItem = .welcome
        })
    }

    // MARK: - Meeting Transcription (Coming Soon)
    private var meetingToolsView: some View
    {
        MeetingTranscriptionView(asrService: asr)
    }

    // MARK: - Stats View
    private var statsView: some View {
        StatsView()
    }


    // Audio settings merged into SettingsView

    private func refreshDevices()
    {
        inputDevices = AudioDevice.listInputDevices()
        outputDevices = AudioDevice.listOutputDevices()
    }

    // MARK: - Model Management Functions
    private func saveModels() { SettingsStore.shared.availableModels = availableModels }
    
    // MARK: - Provider Management Functions
    private func providerKey(for providerID: String) -> String {
        if providerID == "openai" || providerID == "groq" { return providerID }
        // Saved providers use their stable id
        return providerID.isEmpty ? currentProvider : "custom:\(providerID)"
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
        let url = openAIBaseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if url.contains("openai.com") { currentProvider = "openai"; return }
        if url.contains("groq.com") { currentProvider = "groq"; return }
        // For saved/custom, keep current or derive from selectedProviderID
        currentProvider = providerKey(for: selectedProviderID)
    }
    
    private func saveSavedProviders() {
        SettingsStore.shared.savedProviders = savedProviders
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
               secondOctet >= 16 && secondOctet <= 31 {
                return true
            }
        }
        
        return false
    }

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
                let appInfo = recordingAppInfo ?? getCurrentAppInfo()
                let systemPrompt = buildSystemPrompt(appInfo: appInfo)
                DebugLogger.shared.debug("Using Apple Intelligence for transcription cleanup", source: "ContentView")
                return await provider.process(systemPrompt: systemPrompt, userText: inputText)
            }
            #endif
            return inputText // Fallback if not available
        }
        
        let endpoint = derivedBaseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty ? "https://api.openai.com/v1" : derivedBaseURL.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        // Build the full URL - only append /chat/completions if not already present
        let fullEndpoint: String
        if endpoint.contains("/chat/completions") || 
           endpoint.contains("/api/chat") || 
           endpoint.contains("/api/generate") {
            // URL already has a complete path, use as-is
            fullEndpoint = endpoint
        } else {
            // Append /chat/completions for OpenAI-compatible endpoints
            fullEndpoint = endpoint + "/chat/completions"
        }
        
        guard let url = URL(string: fullEndpoint) else {
            return "Error: Invalid Base URL"
        }
        
        let isLocal = isLocalEndpoint(endpoint)
        let apiKey = storedProviderAPIKeys[derivedCurrentProvider] ?? ""
        
        // Skip API key validation for local endpoints
        if !isLocal {
            guard !apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
                return "Error: API Key not set for \(derivedCurrentProvider)"
            }
        }
        

        // Get app context captured at start of recording if available
        let appInfo = recordingAppInfo ?? getCurrentAppInfo()
        let systemPrompt = buildSystemPrompt(appInfo: appInfo)
        DebugLogger.shared.debug("Using app context for AI: app=\(appInfo.name), bundleId=\(appInfo.bundleId), title=\(appInfo.windowTitle)", source: "ContentView")
        
        // Get reasoning config for this model (uses per-model settings or auto-detection)
        let providerKey = self.providerKey(for: currentSelectedProviderID)
        let reasoningConfig = SettingsStore.shared.getReasoningConfig(forModel: derivedSelectedModel, provider: providerKey)
        
        if let config = reasoningConfig {
            DebugLogger.shared.debug("Model '\(derivedSelectedModel)' reasoning config: \(config.parameterName)=\(config.parameterValue), enabled=\(config.isEnabled)", source: "ContentView")
        } else {
            DebugLogger.shared.debug("Model '\(derivedSelectedModel)' has no reasoning config", source: "ContentView")
        }
        
        // Get streaming setting
        let enableStreaming = SettingsStore.shared.enableAIStreaming
        
        // Check if this is a reasoning model that doesn't support temperature parameter
        let modelLower = derivedSelectedModel.lowercased()
        let isReasoningModel = modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") || modelLower.hasPrefix("gpt-5")
        
        // Build request body dynamically to support different reasoning parameters
        var requestDict: [String: Any] = [
            "model": derivedSelectedModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": inputText]
            ]
        ]
        
        // Only add temperature for non-reasoning models
        // OpenAI reasoning models (o1, o3, gpt-5) don't support custom temperature
        if !isReasoningModel {
            requestDict["temperature"] = 0.2
        }
        
        // Add reasoning parameter if configured for this model
        if let config = reasoningConfig, config.isEnabled {
            if config.parameterName == "enable_thinking" {
                // DeepSeek uses boolean
                requestDict[config.parameterName] = config.parameterValue == "true"
            } else {
                // OpenAI/Groq use string values
                requestDict[config.parameterName] = config.parameterValue
            }
            DebugLogger.shared.debug("Added reasoning param: \(config.parameterName)=\(config.parameterValue)", source: "ContentView")
        }
        
        // Add streaming if enabled
        if enableStreaming {
            requestDict["stream"] = true
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestDict, options: []) else {
            return "Error: Failed to encode request"
        }
        
        // Debug: Log request body
        if let bodyStr = String(data: jsonData, encoding: .utf8) {
            DebugLogger.shared.debug("AI Request body: \(bodyStr)", source: "ContentView")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Only add Authorization header for non-local endpoints
        if !isLocal {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = jsonData

        do {
            if enableStreaming {
                // Streaming mode - parse SSE response
                DebugLogger.shared.info("Using STREAMING mode for AI request", source: "ContentView")
                return try await processStreamingResponse(request: request)
            } else {
                // Non-streaming mode - single JSON response
                DebugLogger.shared.info("Using NON-STREAMING mode for AI request", source: "ContentView")
                let (data, response) = try await URLSession.shared.data(for: request)
                
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    let errText = String(data: data, encoding: .utf8) ?? "Unknown error"
                    return "Error: HTTP \(http.statusCode): \(errText)"
                }
                let decoded = try JSONDecoder().decode(AIProcessingResponse.self, from: data)
                return decoded.choices.first?.message.content ?? "<no content>"
            }
        } catch {
            DebugLogger.shared.error("AI API error: \(error.localizedDescription)", source: "ContentView")
            return "Error: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Streaming Response Handler
    private func processStreamingResponse(request: URLRequest) async throws -> String {
        DebugLogger.shared.debug("Starting streaming request to: \(request.url?.absoluteString ?? "unknown")", source: "Streaming")
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        if let http = response as? HTTPURLResponse {
            DebugLogger.shared.debug("Streaming response status: \(http.statusCode)", source: "Streaming")
            if http.statusCode >= 400 {
                var errorData = Data()
                for try await byte in bytes {
                    errorData.append(byte)
                }
                let errText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                DebugLogger.shared.error("Streaming error: \(errText)", source: "Streaming")
                return "Error: HTTP \(http.statusCode): \(errText)"
            }
        }
        
        var fullContent = ""
        
        // Use efficient line-based iteration instead of byte-by-byte
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            
            guard line.hasPrefix("data:") else { continue }
            
            // Handle both "data: " and "data:" formats
            var jsonString = String(line.dropFirst(5))
            if jsonString.hasPrefix(" ") {
                jsonString = String(jsonString.dropFirst(1))
            }
            
            // Skip [DONE] marker
            if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                DebugLogger.shared.debug("Received [DONE] marker", source: "Streaming")
                continue
            }
            
            // Parse the JSON chunk
            guard let jsonData = jsonString.data(using: .utf8) else { continue }
            
            do {
                let chunk = try JSONDecoder().decode(StreamingChunk.self, from: jsonData)
                if let delta = chunk.choices.first?.delta,
                   let content = delta.content {
                    fullContent += content
                }
            } catch {
                // Try alternative parsing for different response formats
                if let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let delta = firstChoice["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    fullContent += content
                }
            }
        }
        
        DebugLogger.shared.debug("Streaming complete. Content length: \(fullContent.count)", source: "Streaming")
        return fullContent.isEmpty ? "<no content>" : fullContent
    }
    
    // MARK: - Stop and Process Transcription
    private func stopAndProcessTranscription() async {
        DebugLogger.shared.debug("stopAndProcessTranscription called", source: "ContentView")

        // Check if we're in rewrite or command mode
        let wasRewriteMode = isRecordingForRewrite
        let wasCommandMode = isRecordingForCommand
        if wasRewriteMode {
            isRecordingForRewrite = false
            // Don't reset overlay mode here - let it stay colored until it hides
        }
        if wasCommandMode {
            isRecordingForCommand = false
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
            await processRewriteWithVoiceInstruction(transcribedText)
            return
        }
        
        // If this was a command recording, process the command
        if wasCommandMode {
            DebugLogger.shared.info("Processing command: \(transcribedText)", source: "ContentView")
            await processCommandWithVoice(transcribedText)
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
        let isLocal = isLocalEndpoint(trimmedBaseURL)
        let apiKey = (SettingsStore.shared.getAPIKey(for: currentProviderID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldUseAI = SettingsStore.shared.enableAIProcessing && (isLocal || !apiKey.isEmpty)
        
        if shouldUseAI {
            DebugLogger.shared.debug("Routing transcription through AI post-processing", source: "ContentView")
            
            // Show processing animation in notch
            menuBarManager.setProcessing(true)
            
            finalText = await processTextWithAI(transcribedText)
            
            // Hide processing animation
            menuBarManager.setProcessing(false)
        } else {
            finalText = transcribedText
        }

        DebugLogger.shared.info("Transcription finalized (chars: \(finalText.count))", source: "ContentView")
        
        // Save to transcription history (transcription mode only)
        let appInfo = recordingAppInfo ?? getCurrentAppInfo()
        TranscriptionHistoryStore.shared.addEntry(
            rawText: transcribedText,
            processedText: finalText,
            appName: appInfo.name,
            windowTitle: appInfo.windowTitle
        )

        // Copy to clipboard if enabled (happens before typing as a backup)
        if SettingsStore.shared.copyTranscriptionToClipboard {
            ClipboardService.copyToClipboard(finalText)
        }

        await MainActor.run {
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            let frontmostName = frontmostApp?.localizedName ?? "Unknown"
            let isFluidFrontmost = frontmostApp?.bundleIdentifier?.contains("fluid") == true
            let shouldTypeExternally = !isFluidFrontmost || isTranscriptionFocused == false

            DebugLogger.shared.debug(
                "Typing decision → frontmost: \(frontmostName), fluidFrontmost: \(isFluidFrontmost), editorFocused: \(isTranscriptionFocused), willTypeExternally: \(shouldTypeExternally)",
                source: "ContentView"
            )

            if shouldTypeExternally {
                asr.typeTextToActiveField(finalText)
            }
        }
    }
    
    // MARK: - Rewrite Mode Voice Processing
    private func processRewriteWithVoiceInstruction(_ instruction: String) async {
        let hasOriginalText = !rewriteModeService.originalText.isEmpty
        DebugLogger.shared.info("Processing \(hasOriginalText ? "rewrite" : "write/improve") - instruction: '\(instruction)', originalText length: \(rewriteModeService.originalText.count)", source: "ContentView")
        
        // Show processing animation
        menuBarManager.setProcessing(true)
        
        // Process the request - service handles both cases:
        // - With originalText: rewrites existing text based on instruction
        // - Without originalText: improves/refines the spoken text
        await rewriteModeService.processRewriteRequest(instruction)
        
        // Hide processing animation
        menuBarManager.setProcessing(false)
        
        // If rewrite was successful, type the result
        if !rewriteModeService.rewrittenText.isEmpty {
            DebugLogger.shared.info("Rewrite successful, typing result (chars: \(rewriteModeService.rewrittenText.count))", source: "ContentView")
            
            // Copy to clipboard as backup
            if SettingsStore.shared.copyTranscriptionToClipboard {
                ClipboardService.copyToClipboard(rewriteModeService.rewrittenText)
            }
            
            // Type the rewritten text
            asr.typeTextToActiveField(rewriteModeService.rewrittenText)
            
            // Clear the rewrite service state for next use
            rewriteModeService.clearState()
        } else {
            DebugLogger.shared.error("Rewrite failed - no result", source: "ContentView")
        }
    }
    
    // MARK: - Command Mode Voice Processing
    private func processCommandWithVoice(_ command: String) async {
        DebugLogger.shared.info("Processing voice command: '\(command)'", source: "ContentView")
        
        // Show processing animation
        menuBarManager.setProcessing(true)
        
        // Process the command through CommandModeService
        // This stores the conversation history and executes any terminal commands
        await commandModeService.processUserCommand(command)
        
        // Hide processing animation
        menuBarManager.setProcessing(false)
        
        DebugLogger.shared.info("Command processed, conversation stored in Command Mode", source: "ContentView")
    }

    // Capture app context at start to avoid mismatches if the user switches apps mid-session
    private func startRecording() {
        // Ensure normal dictation mode is set (command/rewrite modes set their own)
        if !isRecordingForCommand && !isRecordingForRewrite {
            menuBarManager.setOverlayMode(.dictation)
        }
        
        let info = getCurrentAppInfo()
        recordingAppInfo = info
        DebugLogger.shared.debug("Captured recording app context: app=\(info.name), bundleId=\(info.bundleId), title=\(info.windowTitle)", source: "ContentView")
        asr.start()
        
        // Pre-load model in background while recording (avoids 10s freeze on stop)
        Task {
            do {
                try await asr.ensureAsrReady()
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
            try await asr.ensureAsrReady()
            DebugLogger.shared.info("Model download completed successfully", source: "ContentView")
        } catch {
            DebugLogger.shared.error("Failed to download models: \(error)", source: "ContentView")
        }
    }
    
    /// Delete models from disk
    private func deleteModels() async {
        DebugLogger.shared.debug("User initiated model deletion", source: "ContentView")
        
        do {
            try await asr.clearModelCache()
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
        guard !newModelName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else { return }
        
        let modelName = newModelName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let key = providerKey(for: selectedProviderID)
        
        // Get current list or start fresh if empty
        var list = availableModelsByProvider[key] ?? availableModels
        if list.isEmpty {
            list = []
        }
        
        // Add the new model if not already in list
        if !list.contains(modelName) {
            list.append(modelName)
        }
        
        // Update state
        availableModelsByProvider[key] = list
        SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
        
        // Update saved provider if exists
        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let updatedProvider = SettingsStore.SavedProvider(
                id: savedProviders[providerIndex].id,
                name: savedProviders[providerIndex].name,
                baseURL: savedProviders[providerIndex].baseURL,
                models: list
            )
            savedProviders[providerIndex] = updatedProvider
            saveSavedProviders()
        }
        
        // Update UI state
        availableModels = list
        selectedModel = modelName
        selectedModelByProvider[key] = modelName
        SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
        
        // Close the add model UI
        showingAddModel = false
        newModelName = ""
    }
    

    // MARK: - OpenAI-compatible call for playground
    private func callOpenAIChat() async {
        guard !isCallingAI else { return }
        await MainActor.run { isCallingAI = true }
        defer { Task { await MainActor.run { isCallingAI = false } } }
        
        let result = await processTextWithAI(aiInputText)
        await MainActor.run { aiOutputText = result }
    }

    private func getModelStatusText() -> String {
        if asr.isLoadingModel {
            return "Loading model into memory... (30-60 sec)"
        } else if asr.isDownloadingModel {
            return "Downloading model... Please wait."
        } else if asr.isAsrReady {
            return "Model is ready to use!"
        } else if asr.modelsExistOnDisk {
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
    didOpenAccessibilityPane = true
    UserDefaults.standard.set(true, forKey: accessibilityRestartFlagKey)
    }

    private func restartApp() {
        let appPath = Bundle.main.bundlePath
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = ["-n", appPath]
        // Clear pending flag and hide prompt before restarting
        UserDefaults.standard.set(false, forKey: accessibilityRestartFlagKey)
        showRestartPrompt = false
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }
    
    private func startAccessibilityPolling() {
        // Don't poll if already enabled or if we've already auto-restarted once
        guard !accessibilityEnabled else { return }
        guard !UserDefaults.standard.bool(forKey: hasAutoRestartedForAccessibilityKey) else { return }
        
        // Cancel any existing polling task
        accessibilityPollingTask?.cancel()
        
        // Start background polling
        accessibilityPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Poll every 2 seconds
                
                // Check if permission was granted
                let nowTrusted = AXIsProcessTrusted()
                if nowTrusted && !accessibilityEnabled {
                    await MainActor.run {
                        DebugLogger.shared.info("Accessibility permission granted! Auto-restarting app...", source: "ContentView")
                        
                        // Mark that we've auto-restarted to prevent loops
                        UserDefaults.standard.set(true, forKey: hasAutoRestartedForAccessibilityKey)
                        
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
        guard hotkeyManager == nil else { return }
        
        hotkeyManager = GlobalHotkeyManager(
            asrService: asr,
            shortcut: hotkeyShortcut,
            commandModeShortcut: commandModeHotkeyShortcut,
            rewriteModeShortcut: rewriteModeHotkeyShortcut,
            startRecordingCallback: {
                self.startRecording()
            },
            stopAndProcessCallback: {
                await stopAndProcessTranscription()
            },
            commandModeCallback: {
                DebugLogger.shared.info("Command mode triggered", source: "ContentView")
                
                // Set flag so stopAndProcessTranscription knows to process as command
                self.isRecordingForCommand = true
                
                // Set overlay mode to command
                self.menuBarManager.setOverlayMode(.command)
                
                // Start recording immediately for the command
                DebugLogger.shared.info("Starting voice recording for command", source: "ContentView")
                self.asr.start()
            },
            rewriteModeCallback: {
                // Try to capture text first while still in the other app
                let captured = self.rewriteModeService.captureSelectedText()
                DebugLogger.shared.info("Rewrite mode triggered, text captured: \(captured)", source: "ContentView")
                
                if !captured {
                    // No text selected - start in "write mode" where user speaks what to write
                    DebugLogger.shared.info("No text selected - starting in write/improve mode", source: "ContentView")
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
        
        hotkeyManagerInitialized = hotkeyManager?.validateEventTapHealth() ?? false
        
        hotkeyManager?.enablePressAndHoldMode(pressAndHoldModeEnabled)
        
        // Set cancel callback for Escape key handling (closes mode views, resets recording state)
        // Returns true if it handled something (so GlobalHotkeyManager knows to consume the event)
        hotkeyManager?.setCancelCallback {
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
                if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                    print("[ContentView] Initial hotkey manager health check: \(self.hotkeyManagerInitialized)")
                }
                
                // If still not initialized and accessibility is enabled, try reinitializing
                if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                    self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                    if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                        print("[ContentView] Initial hotkey manager health check: \(self.hotkeyManagerInitialized)")
                    }
                    
                    // If still not initialized and accessibility is enabled, try reinitializing
                    if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                            print("[ContentView] Hotkey manager not healthy, attempting reinitalization")
                        }
                        self.hotkeyManager?.reinitialize()
                    }
                }
            }
        }
    }
    
    // MARK: - Model Management Helpers
    
    private func isCustomModel(_ model: String) -> Bool {
        // Non-removable defaults are the provider's default models
        return !defaultModels(for: currentProvider).contains(model)
    }
    
    /// Check if the current model has a reasoning config (either custom or auto-detected)
    private func hasReasoningConfigForCurrentModel() -> Bool {
        let providerKey = self.providerKey(for: selectedProviderID)
        
        // Check for custom config first
        if SettingsStore.shared.hasCustomReasoningConfig(forModel: selectedModel, provider: providerKey) {
            if let config = SettingsStore.shared.getReasoningConfig(forModel: selectedModel, provider: providerKey) {
                return config.isEnabled
            }
        }
        
        // Check for auto-detected models
        let modelLower = selectedModel.lowercased()
        return modelLower.hasPrefix("gpt-5") || modelLower.contains("gpt-5.") ||
               modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") ||
               modelLower.contains("gpt-oss") || modelLower.hasPrefix("openai/") ||
               (modelLower.contains("deepseek") && modelLower.contains("reasoner"))
    }
    
    private func removeModel(_ model: String) {
        // Don't remove if it's currently selected
        if selectedModel == model {
            // Switch to first available model that's not the one being removed
            if let firstOther = availableModels.first(where: { $0 != model }) {
                selectedModel = firstOther
            }
        }
        
        // Remove from current provider's model list
        availableModels.removeAll { $0 == model }
        
        // Update the stored models for this provider
        let key = providerKey(for: selectedProviderID)
        availableModelsByProvider[key] = availableModels
        SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
        
        // If this is a saved custom provider, update its models array too
        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let updatedProvider = SettingsStore.SavedProvider(
                id: savedProviders[providerIndex].id,
                name: savedProviders[providerIndex].name,
                baseURL: savedProviders[providerIndex].baseURL,
                models: availableModels
            )
            savedProviders[providerIndex] = updatedProvider
            saveSavedProviders()
        }
        
        // Update selected model mapping for this provider
        selectedModelByProvider[key] = selectedModel
        SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
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
            .scaleEffect(appear ? 1.0 : 0.96)
            .opacity(appear ? 1.0 : 0)
            .animation(.spring(response: 0.8, dampingFraction: 0.75, blendDuration: 0.2).delay(delay), value: appear)
    }
}

