import AppKit
import Foundation

@MainActor
final class GlobalHotkeyManager: NSObject {
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private let asrService: ASRService
    private var shortcut: HotkeyShortcut
    private var commandModeShortcut: HotkeyShortcut
    private var rewriteModeShortcut: HotkeyShortcut
    private var askModeShortcut: HotkeyShortcut
    private var commandModeShortcutEnabled: Bool
    private var rewriteModeShortcutEnabled: Bool
    private var askModeShortcutEnabled: Bool
    private var startRecordingCallback: (() async -> Void)?
    private var stopAndProcessCallback: (() async -> Void)?
    private var commandModeCallback: (() async -> Void)?
    private var rewriteModeCallback: (() async -> Void)?
    private var askModeCallback: (() async -> Void)?
    private var cancelCallback: (() -> Bool)? // Returns true if handled
    private var pressAndHoldMode: Bool = SettingsStore.shared.pressAndHoldMode
    private var isKeyPressed = false
    private var isCommandModeKeyPressed = false
    private var isRewriteKeyPressed = false
    private var isAskKeyPressed = false

    // Double-tap detection for Ask Mode (triggered by double-tapping Rewrite shortcut)
    private var lastRewriteShortcutTime: Date?
    private var doubleTapThreshold: TimeInterval = 0.35 // 350ms window for double-tap
    private var pendingRewriteTask: Task<Void, Never>?
    private var singleTapDelay: TimeInterval = 0.25 // Delay before executing single-tap rewrite

    // Debouncing to prevent rapid-fire activations (crashes Speech framework)
    private var lastModeActivationTime: Date?
    private var minimumModeInterval: TimeInterval = 0.5 // 500ms between mode activations
    private var isModeSwitching: Bool = false // Prevents concurrent mode switches

    // Busy flag to prevent race conditions during stop processing
    private var isProcessingStop = false

    private var isInitialized = false
    private var initializationTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var maxRetryAttempts = 5
    private var retryDelay: TimeInterval = 0.5
    private var healthCheckInterval: TimeInterval = 30.0

    init(
        asrService: ASRService,
        shortcut: HotkeyShortcut,
        commandModeShortcut: HotkeyShortcut,
        rewriteModeShortcut: HotkeyShortcut,
        askModeShortcut: HotkeyShortcut,
        commandModeShortcutEnabled: Bool,
        rewriteModeShortcutEnabled: Bool,
        askModeShortcutEnabled: Bool,
        startRecordingCallback: (() async -> Void)? = nil,
        stopAndProcessCallback: (() async -> Void)? = nil,
        commandModeCallback: (() async -> Void)? = nil,
        rewriteModeCallback: (() async -> Void)? = nil,
        askModeCallback: (() async -> Void)? = nil
    ) {
        self.asrService = asrService
        self.shortcut = shortcut
        self.commandModeShortcut = commandModeShortcut
        self.rewriteModeShortcut = rewriteModeShortcut
        self.askModeShortcut = askModeShortcut
        self.commandModeShortcutEnabled = commandModeShortcutEnabled
        self.rewriteModeShortcutEnabled = rewriteModeShortcutEnabled
        self.askModeShortcutEnabled = askModeShortcutEnabled
        self.startRecordingCallback = startRecordingCallback
        self.stopAndProcessCallback = stopAndProcessCallback
        self.commandModeCallback = commandModeCallback
        self.rewriteModeCallback = rewriteModeCallback
        self.askModeCallback = askModeCallback
        super.init()

        self.initializeWithDelay()
    }

    private func initializeWithDelay() {
        DebugLogger.shared.debug("Starting delayed initialization...", source: "GlobalHotkeyManager")

        self.initializationTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 second delay

            await MainActor.run {
                self.setupGlobalHotkeyWithRetry()
            }
        }
    }

    func setStopAndProcessCallback(_ callback: @escaping () async -> Void) {
        self.stopAndProcessCallback = callback
    }

    func setCommandModeCallback(_ callback: @escaping () async -> Void) {
        self.commandModeCallback = callback
    }

    func updateShortcut(_ newShortcut: HotkeyShortcut) {
        self.shortcut = newShortcut
        DebugLogger.shared.info("Updated transcription hotkey", source: "GlobalHotkeyManager")
    }

    func updateCommandModeShortcut(_ newShortcut: HotkeyShortcut) {
        self.commandModeShortcut = newShortcut
        DebugLogger.shared.info("Updated command mode hotkey", source: "GlobalHotkeyManager")
    }

    func setRewriteModeCallback(_ callback: @escaping () async -> Void) {
        self.rewriteModeCallback = callback
    }

    func updateRewriteModeShortcut(_ newShortcut: HotkeyShortcut) {
        self.rewriteModeShortcut = newShortcut
        DebugLogger.shared.info("Updated rewrite mode hotkey", source: "GlobalHotkeyManager")
    }

    func updateCommandModeShortcutEnabled(_ enabled: Bool) {
        self.commandModeShortcutEnabled = enabled
        if !enabled {
            self.isCommandModeKeyPressed = false
        }
        DebugLogger.shared.info(
            "Command mode shortcut \(enabled ? "enabled" : "disabled")",
            source: "GlobalHotkeyManager"
        )
    }

    func updateRewriteModeShortcutEnabled(_ enabled: Bool) {
        self.rewriteModeShortcutEnabled = enabled
        if !enabled {
            self.isRewriteKeyPressed = false
        }
        DebugLogger.shared.info(
            "Rewrite mode shortcut \(enabled ? "enabled" : "disabled")",
            source: "GlobalHotkeyManager"
        )
    }

    func setAskModeCallback(_ callback: @escaping () async -> Void) {
        self.askModeCallback = callback
    }

    func updateAskModeShortcut(_ newShortcut: HotkeyShortcut) {
        self.askModeShortcut = newShortcut
        DebugLogger.shared.info("Updated ask mode hotkey", source: "GlobalHotkeyManager")
    }

    func updateAskModeShortcutEnabled(_ enabled: Bool) {
        self.askModeShortcutEnabled = enabled
        if !enabled {
            self.isAskKeyPressed = false
        }
        DebugLogger.shared.info(
            "Ask mode shortcut \(enabled ? "enabled" : "disabled")",
            source: "GlobalHotkeyManager"
        )
    }

    func setCancelCallback(_ callback: @escaping () -> Bool) {
        self.cancelCallback = callback
    }

    private func setupGlobalHotkeyWithRetry() {
        for attempt in 1...self.maxRetryAttempts {
            DebugLogger.shared.debug("Setup attempt \(attempt)/\(self.maxRetryAttempts)", source: "GlobalHotkeyManager")

            if self.setupGlobalHotkey() {
                self.isInitialized = true
                DebugLogger.shared.info("Successfully initialized on attempt \(attempt)", source: "GlobalHotkeyManager")
                self.startHealthCheckTimer()
                return
            }

            if attempt < self.maxRetryAttempts {
                DebugLogger.shared.warning("Attempt \(attempt) failed, retrying in \(self.retryDelay) seconds...", source: "GlobalHotkeyManager")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((self?.retryDelay ?? 0.5) * 1_000_000_000))
                    await MainActor.run { [weak self] in
                        self?.setupGlobalHotkeyWithRetry()
                    }
                }
                return
            }
        }

        DebugLogger.shared.error("Failed to initialize after \(self.maxRetryAttempts) attempts", source: "GlobalHotkeyManager")
    }

    @discardableResult
    private func setupGlobalHotkey() -> Bool {
        self.cleanupEventTap()

        if !AXIsProcessTrusted() {
            DebugLogger.shared.debug("Accessibility permissions not granted", source: "GlobalHotkeyManager")
            return false
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        self.eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon)
                    .takeUnretainedValue()
                return manager.handleKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            DebugLogger.shared.error("Failed to create CGEvent tap", source: "GlobalHotkeyManager")
            return false
        }

        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = runLoopSource else {
            DebugLogger.shared.error("Failed to create CFRunLoopSource", source: "GlobalHotkeyManager")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        if !self.isEventTapEnabled() {
            DebugLogger.shared.error("Event tap could not be enabled", source: "GlobalHotkeyManager")
            self.cleanupEventTap()
            return false
        }

        DebugLogger.shared.info("Event tap successfully created and enabled", source: "GlobalHotkeyManager")
        return true
    }

    private nonisolated func cleanupEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        self.eventTap = nil
        self.runLoopSource = nil
    }

    private func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS can temporarily disable event taps (e.g. timeouts, user input protection).
        // If we don't immediately re-enable here, hotkeys will silently stop working until our
        // periodic health check kicks in, and the OS may handle the key (e.g. system dictation).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = (type == .tapDisabledByTimeout) ? "timeout" : "user input"
            DebugLogger.shared.warning("Event tap disabled by \(reason) — attempting immediate re-enable", source: "GlobalHotkeyManager")

            if let tap = self.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }

            // If re-enable failed, recreate the tap.
            if !self.isEventTapEnabled() {
                DebugLogger.shared.warning("Event tap re-enable failed — recreating tap", source: "GlobalHotkeyManager")
                self.setupGlobalHotkeyWithRetry()
            }

            return nil
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        var eventModifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskSecondaryFn) { eventModifiers.insert(.function) }
        if flags.contains(.maskCommand) { eventModifiers.insert(.command) }
        if flags.contains(.maskAlternate) { eventModifiers.insert(.option) }
        if flags.contains(.maskControl) { eventModifiers.insert(.control) }
        if flags.contains(.maskShift) { eventModifiers.insert(.shift) }

        switch type {
        case .keyDown:
            // Check Escape key first (keyCode 53) - cancels recording and closes mode views
            if keyCode == 53, eventModifiers.isEmpty {
                var handled = false

                if self.asrService.isRunning {
                    DebugLogger.shared.info("Escape pressed - cancelling recording", source: "GlobalHotkeyManager")
                    Task { @MainActor in
                        await self.asrService.stopWithoutTranscription()
                    }
                    handled = true
                }

                // Trigger cancel callback to close mode views / reset state
                if let callback = cancelCallback, callback() {
                    DebugLogger.shared.info("Escape pressed - cancel callback handled", source: "GlobalHotkeyManager")
                    handled = true
                }

                if handled {
                    return nil // Consume event only if we did something
                }
            }

            // Check command mode hotkey first
            if self.commandModeShortcutEnabled, self.matchesCommandModeShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                if self.pressAndHoldMode {
                    // Press and hold: start on keyDown, stop on keyUp
                    if !self.isCommandModeKeyPressed {
                        self.isCommandModeKeyPressed = true
                        DebugLogger.shared.info("Command mode shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                        self.triggerCommandMode()
                    }
                } else {
                    // Toggle mode: press to start, press again to stop
                    if self.asrService.isRunning {
                        DebugLogger.shared.info("Command mode shortcut pressed while recording - stopping", source: "GlobalHotkeyManager")
                        self.stopRecordingIfNeeded()
                    } else {
                        DebugLogger.shared.info("Command mode shortcut triggered - starting", source: "GlobalHotkeyManager")
                        self.triggerCommandMode()
                    }
                }
                return nil
            }

            // Check dedicated rewrite mode hotkey (with double-tap detection for Ask Mode)
            if self.rewriteModeShortcutEnabled {
                if self.matchesRewriteModeShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                    let now = Date()

                    // Check if this is a double-tap (within threshold of last tap)
                    // Only check if Ask Mode is enabled (otherwise no need for double-tap detection)
                    if self.askModeShortcutEnabled,
                       let lastTap = self.lastRewriteShortcutTime,
                       now.timeIntervalSince(lastTap) < self.doubleTapThreshold
                    {
                        // Double-tap detected! Cancel pending rewrite and trigger Ask Mode
                        DebugLogger.shared.info("Double-tap detected - triggering Ask Mode", source: "GlobalHotkeyManager")
                        self.pendingRewriteTask?.cancel()
                        self.pendingRewriteTask = nil
                        self.lastRewriteShortcutTime = nil

                        if self.pressAndHoldMode {
                            // In press-and-hold mode, a quick double-tap may have already started rewrite
                            // Stop it and switch to ask mode
                            if self.asrService.isRunning {
                                Task { await self.asrService.stopWithoutTranscription() }
                            }
                            self.isRewriteKeyPressed = false
                            self.isAskKeyPressed = true
                        }
                        self.triggerAskMode()
                        return nil
                    }

                    // Record tap time for double-tap detection
                    self.lastRewriteShortcutTime = now

                    if self.pressAndHoldMode {
                        // Press and hold: START IMMEDIATELY (no delay for responsiveness)
                        // If user double-taps quickly, we'll cancel and switch to Ask Mode
                        if !self.isRewriteKeyPressed {
                            self.isRewriteKeyPressed = true
                            DebugLogger.shared.info("Rewrite mode shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                            self.triggerRewriteMode()
                        }
                    } else {
                        // Toggle mode: press to start, press again to stop
                        if self.asrService.isRunning {
                            DebugLogger.shared.info("Rewrite mode shortcut pressed while recording - stopping", source: "GlobalHotkeyManager")
                            self.pendingRewriteTask?.cancel()
                            self.pendingRewriteTask = nil
                            self.stopRecordingIfNeeded()
                        } else if self.askModeShortcutEnabled {
                            // Ask Mode enabled: use delay for double-tap detection in toggle mode
                            self.pendingRewriteTask?.cancel()
                            self.pendingRewriteTask = Task { @MainActor [weak self] in
                                guard let self = self else { return }
                                try? await Task.sleep(nanoseconds: UInt64(self.singleTapDelay * 1_000_000_000))
                                guard !Task.isCancelled else { return }
                                DebugLogger.shared.info("Rewrite mode shortcut triggered - starting", source: "GlobalHotkeyManager")
                                self.triggerRewriteMode()
                            }
                        } else {
                            // Ask Mode disabled: no need for delay, trigger immediately
                            DebugLogger.shared.info("Rewrite mode shortcut triggered - starting", source: "GlobalHotkeyManager")
                            self.triggerRewriteMode()
                        }
                    }
                    return nil
                }
            }

            // Check dedicated ask mode hotkey
            if self.askModeShortcutEnabled {
                if self.matchesAskModeShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                    if self.pressAndHoldMode {
                        // Press and hold: start on keyDown, stop on keyUp
                        if !self.isAskKeyPressed {
                            self.isAskKeyPressed = true
                            DebugLogger.shared.info("Ask mode shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                            self.triggerAskMode()
                        }
                    } else {
                        // Toggle mode: press to start, press again to stop
                        if self.asrService.isRunning {
                            DebugLogger.shared.info("Ask mode shortcut pressed while recording - stopping", source: "GlobalHotkeyManager")
                            self.stopRecordingIfNeeded()
                        } else {
                            DebugLogger.shared.info("Ask mode shortcut triggered - starting", source: "GlobalHotkeyManager")
                            self.triggerAskMode()
                        }
                    }
                    return nil
                }
            }

            // Then check transcription hotkey
            if self.matchesShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                if self.pressAndHoldMode {
                    if !self.isKeyPressed {
                        self.isKeyPressed = true
                        self.startRecordingIfNeeded()
                    }
                } else {
                    self.toggleRecording()
                }
                return nil
            }

        case .keyUp:
            // Command mode key up (press and hold mode)
            if self.commandModeShortcutEnabled, self.pressAndHoldMode, self.isCommandModeKeyPressed, self.matchesCommandModeShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                self.isCommandModeKeyPressed = false
                DebugLogger.shared.info("Command mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                self.stopRecordingIfNeeded()
                return nil
            }

            // Rewrite mode key up (press and hold mode)
            // Also handles Ask Mode triggered via double-tap of Rewrite shortcut
            if self.rewriteModeShortcutEnabled, self.pressAndHoldMode, self.matchesRewriteModeShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                // Cancel any pending rewrite task on key release
                self.pendingRewriteTask?.cancel()
                self.pendingRewriteTask = nil

                if self.isRewriteKeyPressed {
                    self.isRewriteKeyPressed = false
                    DebugLogger.shared.info("Rewrite mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                    self.stopRecordingIfNeeded()
                    return nil
                }
                // Also handle if Ask Mode was triggered via double-tap (key release on rewrite key)
                if self.isAskKeyPressed {
                    self.isAskKeyPressed = false
                    DebugLogger.shared.info("Ask mode (via double-tap) shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                    self.stopRecordingIfNeeded()
                    return nil
                }
            }

            // Ask mode key up (press and hold mode)
            if self.askModeShortcutEnabled, self.pressAndHoldMode, self.isAskKeyPressed, self.matchesAskModeShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                self.isAskKeyPressed = false
                DebugLogger.shared.info("Ask mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                self.stopRecordingIfNeeded()
                return nil
            }

            // Transcription key up
            if self.pressAndHoldMode, self.isKeyPressed, self.matchesShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                self.isKeyPressed = false
                self.stopRecordingIfNeeded()
                return nil
            }

        case .flagsChanged:
            let isModifierPressed = flags.contains(.maskSecondaryFn)
                || flags.contains(.maskCommand)
                || flags.contains(.maskAlternate)
                || flags.contains(.maskControl)
                || flags.contains(.maskShift)

            // Check command mode shortcut (if it's a modifier-only shortcut)
            if self.commandModeShortcutEnabled, self.commandModeShortcut.modifierFlags.isEmpty, keyCode == self.commandModeShortcut.keyCode {
                if isModifierPressed {
                    if self.pressAndHoldMode {
                        if !self.isCommandModeKeyPressed {
                            self.isCommandModeKeyPressed = true
                            DebugLogger.shared.info("Command mode modifier pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                            self.triggerCommandMode()
                        }
                    } else {
                        // Toggle mode
                        if self.asrService.isRunning {
                            DebugLogger.shared.info("Command mode modifier pressed while recording - stopping", source: "GlobalHotkeyManager")
                            self.stopRecordingIfNeeded()
                        } else {
                            DebugLogger.shared.info("Command mode modifier pressed - starting", source: "GlobalHotkeyManager")
                            self.triggerCommandMode()
                        }
                    }
                } else if self.pressAndHoldMode, self.isCommandModeKeyPressed {
                    // Key released in press-and-hold mode
                    self.isCommandModeKeyPressed = false
                    DebugLogger.shared.info("Command mode modifier released (hold mode) - stopping", source: "GlobalHotkeyManager")
                    self.stopRecordingIfNeeded()
                }
                return nil
            }

            // Check rewrite mode shortcut (if it's a modifier-only shortcut - actual modifier keys only)
            // Note: Regular keys with no modifiers are handled in keyDown, not flagsChanged
            // Only handle actual modifier keys (Command, Option, Control, Shift, Function) here
            // Includes double-tap detection for Ask Mode
            if self.rewriteModeShortcutEnabled, self.rewriteModeShortcut.modifierFlags.isEmpty {
                // Check if this is an actual modifier key (not a regular key)
                let isModifierKey = keyCode == 54 || keyCode == 55 || // Command keys
                    keyCode == 58 || keyCode == 61 || // Option keys
                    keyCode == 59 || keyCode == 62 || // Control keys
                    keyCode == 56 || keyCode == 60 || // Shift keys
                    keyCode == 63 // Function key

                if isModifierKey, keyCode == self.rewriteModeShortcut.keyCode {
                    if isModifierPressed {
                        let now = Date()

                        // Check for double-tap (only if Ask Mode is enabled)
                        if self.askModeShortcutEnabled,
                           let lastTap = self.lastRewriteShortcutTime,
                           now.timeIntervalSince(lastTap) < self.doubleTapThreshold
                        {
                            // Double-tap detected! Trigger Ask Mode
                            DebugLogger.shared.info("Double-tap modifier detected - triggering Ask Mode", source: "GlobalHotkeyManager")
                            self.pendingRewriteTask?.cancel()
                            self.pendingRewriteTask = nil
                            self.lastRewriteShortcutTime = nil

                            if self.pressAndHoldMode {
                                // Stop any already-started rewrite recording
                                if self.asrService.isRunning {
                                    Task { await self.asrService.stopWithoutTranscription() }
                                }
                                self.isRewriteKeyPressed = false
                                self.isAskKeyPressed = true
                            }
                            self.triggerAskMode()
                            return nil
                        }

                        // First tap - record time
                        self.lastRewriteShortcutTime = now

                        if self.pressAndHoldMode {
                            // Press and hold: START IMMEDIATELY (no delay for responsiveness)
                            if !self.isRewriteKeyPressed {
                                self.isRewriteKeyPressed = true
                                DebugLogger.shared.info("Rewrite mode modifier pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                                self.triggerRewriteMode()
                            }
                        } else {
                            // Toggle mode
                            if self.asrService.isRunning {
                                DebugLogger.shared.info("Rewrite mode modifier pressed while recording - stopping", source: "GlobalHotkeyManager")
                                self.pendingRewriteTask?.cancel()
                                self.pendingRewriteTask = nil
                                self.stopRecordingIfNeeded()
                            } else if self.askModeShortcutEnabled {
                                // Ask Mode enabled: use delay for double-tap detection
                                self.pendingRewriteTask?.cancel()
                                self.pendingRewriteTask = Task { @MainActor [weak self] in
                                    guard let self = self else { return }
                                    try? await Task.sleep(nanoseconds: UInt64(self.singleTapDelay * 1_000_000_000))
                                    guard !Task.isCancelled else { return }
                                    DebugLogger.shared.info("Rewrite mode modifier pressed - starting", source: "GlobalHotkeyManager")
                                    self.triggerRewriteMode()
                                }
                            } else {
                                // Ask Mode disabled: no delay needed
                                DebugLogger.shared.info("Rewrite mode modifier pressed - starting", source: "GlobalHotkeyManager")
                                self.triggerRewriteMode()
                            }
                        }
                    } else if self.pressAndHoldMode {
                        // Key released in press-and-hold mode
                        self.pendingRewriteTask?.cancel()
                        self.pendingRewriteTask = nil

                        if self.isRewriteKeyPressed {
                            self.isRewriteKeyPressed = false
                            DebugLogger.shared.info("Rewrite mode modifier released (hold mode) - stopping", source: "GlobalHotkeyManager")
                            self.stopRecordingIfNeeded()
                        }
                        if self.isAskKeyPressed {
                            self.isAskKeyPressed = false
                            DebugLogger.shared.info("Ask mode (via double-tap) modifier released (hold mode) - stopping", source: "GlobalHotkeyManager")
                            self.stopRecordingIfNeeded()
                        }
                    }
                    return nil
                }
            }

            // Check ask mode shortcut (if it's a modifier-only shortcut - actual modifier keys only)
            if self.askModeShortcutEnabled, self.askModeShortcut.modifierFlags.isEmpty {
                let isModifierKey = keyCode == 54 || keyCode == 55 || // Command keys
                    keyCode == 58 || keyCode == 61 || // Option keys
                    keyCode == 59 || keyCode == 62 || // Control keys
                    keyCode == 56 || keyCode == 60 || // Shift keys
                    keyCode == 63 // Function key

                if isModifierKey, keyCode == self.askModeShortcut.keyCode {
                    if isModifierPressed {
                        if self.pressAndHoldMode {
                            if !self.isAskKeyPressed {
                                self.isAskKeyPressed = true
                                DebugLogger.shared.info("Ask mode modifier pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                                self.triggerAskMode()
                            }
                        } else {
                            // Toggle mode
                            if self.asrService.isRunning {
                                DebugLogger.shared.info("Ask mode modifier pressed while recording - stopping", source: "GlobalHotkeyManager")
                                self.stopRecordingIfNeeded()
                            } else {
                                DebugLogger.shared.info("Ask mode modifier pressed - starting", source: "GlobalHotkeyManager")
                                self.triggerAskMode()
                            }
                        }
                    } else if self.pressAndHoldMode, self.isAskKeyPressed {
                        // Key released in press-and-hold mode
                        self.isAskKeyPressed = false
                        DebugLogger.shared.info("Ask mode modifier released (hold mode) - stopping", source: "GlobalHotkeyManager")
                        self.stopRecordingIfNeeded()
                    }
                    return nil
                }
            }

            // Check transcription shortcut (if it's a modifier-only shortcut)
            guard self.shortcut.modifierFlags.isEmpty else { break }

            if keyCode == self.shortcut.keyCode {
                if self.pressAndHoldMode {
                    if isModifierPressed {
                        if !self.isKeyPressed {
                            self.isKeyPressed = true
                            self.startRecordingIfNeeded()
                        }
                    } else if self.isKeyPressed {
                        self.isKeyPressed = false
                        self.stopRecordingIfNeeded()
                    }
                } else if isModifierPressed {
                    self.toggleRecording()
                }
                return nil
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    /// Check if we can safely activate a mode (debouncing)
    private func canActivateMode() -> Bool {
        // Check if we're already switching modes
        if self.isModeSwitching {
            DebugLogger.shared.debug("Mode activation blocked: already switching modes", source: "GlobalHotkeyManager")
            return false
        }

        // Check minimum interval since last activation
        if let lastTime = self.lastModeActivationTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed < self.minimumModeInterval {
                DebugLogger.shared.debug("Mode activation blocked: too soon (\(Int(elapsed * 1000))ms < \(Int(minimumModeInterval * 1000))ms)", source: "GlobalHotkeyManager")
                return false
            }
        }

        return true
    }

    /// Record that a mode was activated
    private func recordModeActivation() {
        self.lastModeActivationTime = Date()
        self.isModeSwitching = true

        // Reset the switching flag after a short delay
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            self?.isModeSwitching = false
        }
    }

    private func triggerCommandMode() {
        guard canActivateMode() else { return }
        recordModeActivation()

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Command mode hotkey triggered", source: "GlobalHotkeyManager")
            await self.commandModeCallback?()
        }
    }

    private func triggerRewriteMode() {
        guard canActivateMode() else { return }
        recordModeActivation()

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Rewrite mode hotkey triggered", source: "GlobalHotkeyManager")
            await self.rewriteModeCallback?()
        }
    }

    private func triggerAskMode() {
        guard canActivateMode() else { return }
        recordModeActivation()

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Ask mode hotkey triggered", source: "GlobalHotkeyManager")
            await self.askModeCallback?()
        }
    }

    func enablePressAndHoldMode(_ enable: Bool) {
        self.pressAndHoldMode = enable
        if !enable, self.isKeyPressed {
            self.isKeyPressed = false
            self.stopRecordingIfNeeded()
        } else if enable {
            self.isKeyPressed = false
        }
    }

    private func toggleRecording() {
        // Capture state at event time to prevent race conditions
        let shouldStop = self.asrService.isRunning
        let alreadyProcessing = self.isProcessingStop

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Prevent new operations while stop is processing
            if alreadyProcessing {
                DebugLogger.shared.debug("Ignoring toggle - stop already in progress", source: "GlobalHotkeyManager")
                return
            }

            if shouldStop {
                await self.stopRecordingInternal()
            } else {
                // Use callback if available, otherwise fallback to direct start
                if let callback = self.startRecordingCallback {
                    await callback()
                } else {
                    self.asrService.start()
                }
            }
        }
    }

    private func startRecordingIfNeeded() {
        // Capture state at event time
        let alreadyRunning = self.asrService.isRunning
        let alreadyProcessing = self.isProcessingStop

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Prevent starting while stop is processing
            if alreadyProcessing {
                DebugLogger.shared.debug("Ignoring start - stop in progress", source: "GlobalHotkeyManager")
                return
            }

            if !alreadyRunning {
                // Use callback if available, otherwise fallback to direct start
                if let callback = self.startRecordingCallback {
                    await callback()
                } else {
                    self.asrService.start()
                }
            }
        }
    }

    private func stopRecordingIfNeeded() {
        // Capture state at event time
        let shouldStop = self.asrService.isRunning
        let alreadyProcessing = self.isProcessingStop

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Only stop if was running and not already processing
            if !shouldStop || alreadyProcessing {
                if alreadyProcessing {
                    DebugLogger.shared.debug("Ignoring stop - already processing", source: "GlobalHotkeyManager")
                }
                return
            }

            await self.stopRecordingInternal()
        }
    }

    @MainActor
    private func stopRecordingInternal() async {
        guard self.asrService.isRunning else { return }
        guard !self.isProcessingStop else {
            DebugLogger.shared.debug("Stop already in progress, ignoring", source: "GlobalHotkeyManager")
            return
        }

        self.isProcessingStop = true
        defer { isProcessingStop = false }

        if let callback = stopAndProcessCallback {
            await callback()
        } else {
            await self.asrService.stopWithoutTranscription()
        }
    }

    private func matchesShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevantModifiers: NSEvent.ModifierFlags = modifiers.intersection([.function, .command, .option, .control, .shift])
        let shortcutModifiers = self.shortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        return keyCode == self.shortcut.keyCode && relevantModifiers == shortcutModifiers
    }

    private func matchesCommandModeShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevantModifiers: NSEvent.ModifierFlags = modifiers.intersection([.function, .command, .option, .control, .shift])
        let shortcutModifiers = self.commandModeShortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        return keyCode == self.commandModeShortcut.keyCode && relevantModifiers == shortcutModifiers
    }

    private func matchesRewriteModeShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevantModifiers: NSEvent.ModifierFlags = modifiers.intersection([.function, .command, .option, .control, .shift])
        let shortcutModifiers = self.rewriteModeShortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        return keyCode == self.rewriteModeShortcut.keyCode && relevantModifiers == shortcutModifiers
    }

    private func matchesAskModeShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevantModifiers: NSEvent.ModifierFlags = modifiers.intersection([.function, .command, .option, .control, .shift])
        let shortcutModifiers = self.askModeShortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        return keyCode == self.askModeShortcut.keyCode && relevantModifiers == shortcutModifiers
    }

    func isEventTapEnabled() -> Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func validateEventTapHealth() -> Bool {
        // Treat an enabled event tap as "healthy", even if our internal `isInitialized` flag drifted.
        // This prevents false "initializing" UI while hotkeys are already working.
        let enabled = self.isEventTapEnabled()
        if enabled && !self.isInitialized {
            self.isInitialized = true
        }
        return enabled
    }

    func reinitialize() {
        DebugLogger.shared.info("Manual reinitialization requested", source: "GlobalHotkeyManager")

        self.initializationTask?.cancel()
        self.healthCheckTask?.cancel()
        self.isInitialized = false
        self.initializeWithDelay()
    }

    private func startHealthCheckTimer() {
        self.healthCheckTask?.cancel()
        self.healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.healthCheckInterval * 1_000_000_000))

                guard !Task.isCancelled else { break }

                await MainActor.run {
                    if !self.validateEventTapHealth() {
                        DebugLogger.shared.warning("Health check failed, attempting to recover", source: "GlobalHotkeyManager")

                        if self.setupGlobalHotkey() {
                            self.isInitialized = true
                            DebugLogger.shared.info("Health check recovery successful", source: "GlobalHotkeyManager")
                        } else {
                            DebugLogger.shared.error("Health check recovery failed", source: "GlobalHotkeyManager")
                            self.isInitialized = false
                        }
                    }
                }
            }
        }
    }

    deinit {
        initializationTask?.cancel()
        healthCheckTask?.cancel()
        cleanupEventTap()

        DebugLogger.shared.info("Deinitialized and cleaned up", source: "GlobalHotkeyManager")
    }
}
