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
    private var commandModeShortcutEnabled: Bool
    private var rewriteModeShortcutEnabled: Bool
    private var startRecordingCallback: (() async -> Void)?
    private var stopAndProcessCallback: (() async -> Void)?
    private var commandModeCallback: (() async -> Void)?
    private var rewriteModeCallback: (() async -> Void)?
    private var cancelCallback: (() -> Bool)? // Returns true if handled
    private var isKeyPressed = false
    private var isCommandModeKeyPressed = false
    private var isRewriteKeyPressed = false

    // Hotkey activation mode (toggle, hold, or automatic)
    private var hotkeyMode: SettingsStore.HotkeyMode = SettingsStore.shared.hotkeyMode

    // Dual-mode hotkey support: tracks key press timing to distinguish tap vs hold
    // Tap (< threshold): toggle mode - recording continues after release
    // Hold (>= threshold): push-to-talk mode - recording stops on release
    private let tapThresholdSeconds: TimeInterval = 0.4 // 400ms threshold
    private var keyDownTime: Date?
    private var commandModeKeyDownTime: Date?
    private var rewriteKeyDownTime: Date?
    // Track if recording was already running when key was pressed (for tap-to-stop)
    private var wasRecordingBeforeKeyDown = false
    private var wasRecordingBeforeCommandModeKeyDown = false
    private var wasRecordingBeforeRewriteKeyDown = false

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
        commandModeShortcutEnabled: Bool,
        rewriteModeShortcutEnabled: Bool,
        startRecordingCallback: (() async -> Void)? = nil,
        stopAndProcessCallback: (() async -> Void)? = nil,
        commandModeCallback: (() async -> Void)? = nil,
        rewriteModeCallback: (() async -> Void)? = nil
    ) {
        self.asrService = asrService
        self.shortcut = shortcut
        self.commandModeShortcut = commandModeShortcut
        self.rewriteModeShortcut = rewriteModeShortcut
        self.commandModeShortcutEnabled = commandModeShortcutEnabled
        self.rewriteModeShortcutEnabled = rewriteModeShortcutEnabled
        self.startRecordingCallback = startRecordingCallback
        self.stopAndProcessCallback = stopAndProcessCallback
        self.commandModeCallback = commandModeCallback
        self.rewriteModeCallback = rewriteModeCallback
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

            // CRITICAL: Return the event to let it pass through during recovery.
            // Previously returning nil would consume/block all keyboard events
            // (including CGEvent text insertion) during the recovery period.
            return Unmanaged.passUnretained(event)
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
                switch self.hotkeyMode {
                case .toggle:
                    // Toggle mode: tap to start/stop
                    if self.asrService.isRunning {
                        self.stopRecordingIfNeeded()
                    } else {
                        self.triggerCommandMode()
                    }
                case .hold:
                    // Hold mode: start on keyDown
                    if !self.isCommandModeKeyPressed {
                        self.isCommandModeKeyPressed = true
                        self.triggerCommandMode()
                    }
                case .automatic:
                    // Automatic mode: detect tap vs hold
                    if !self.isCommandModeKeyPressed {
                        self.isCommandModeKeyPressed = true
                        self.commandModeKeyDownTime = Date()
                        self.wasRecordingBeforeCommandModeKeyDown = self.asrService.isRunning
                        if !self.wasRecordingBeforeCommandModeKeyDown {
                            self.triggerCommandMode()
                        }
                    }
                }
                return nil
            }

            // Check dedicated rewrite mode hotkey
            if self.rewriteModeShortcutEnabled {
                if self.matchesRewriteModeShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                    switch self.hotkeyMode {
                    case .toggle:
                        // Toggle mode: tap to start/stop
                        if self.asrService.isRunning {
                            self.stopRecordingIfNeeded()
                        } else {
                            self.triggerRewriteMode()
                        }
                    case .hold:
                        // Hold mode: start on keyDown
                        if !self.isRewriteKeyPressed {
                            self.isRewriteKeyPressed = true
                            self.triggerRewriteMode()
                        }
                    case .automatic:
                        // Automatic mode: detect tap vs hold
                        if !self.isRewriteKeyPressed {
                            self.isRewriteKeyPressed = true
                            self.rewriteKeyDownTime = Date()
                            self.wasRecordingBeforeRewriteKeyDown = self.asrService.isRunning
                            if !self.wasRecordingBeforeRewriteKeyDown {
                                self.triggerRewriteMode()
                            }
                        }
                    }
                    return nil
                }
            }

            // Then check transcription hotkey
            if self.matchesShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                switch self.hotkeyMode {
                case .toggle:
                    // Toggle mode: tap to start/stop
                    self.toggleRecording()
                case .hold:
                    // Hold mode: start on keyDown, stop on keyUp
                    if !self.isKeyPressed {
                        self.isKeyPressed = true
                        self.startRecordingIfNeeded()
                    }
                case .automatic:
                    // Automatic mode: detect tap vs hold
                    if !self.isKeyPressed {
                        self.isKeyPressed = true
                        self.keyDownTime = Date()
                        self.wasRecordingBeforeKeyDown = self.asrService.isRunning
                        if !self.wasRecordingBeforeKeyDown {
                            self.startRecordingIfNeeded()
                        }
                    }
                }
                return nil
            }

        case .keyUp:
            // Command mode key up
            if self.commandModeShortcutEnabled, self.isCommandModeKeyPressed, self.matchesCommandModeShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                switch self.hotkeyMode {
                case .toggle:
                    // Toggle mode: keyUp is ignored
                    self.isCommandModeKeyPressed = false
                case .hold:
                    // Hold mode: stop on keyUp
                    self.isCommandModeKeyPressed = false
                    self.stopRecordingIfNeeded()
                case .automatic:
                    // Automatic mode: detect tap vs hold
                    let pressDuration = Date().timeIntervalSince(self.commandModeKeyDownTime ?? Date())
                    self.isCommandModeKeyPressed = false
                    self.commandModeKeyDownTime = nil

                    if pressDuration < self.tapThresholdSeconds {
                        if self.wasRecordingBeforeCommandModeKeyDown {
                            DebugLogger.shared.info("Command mode tap (\(String(format: "%.2f", pressDuration))s) - stopping", source: "GlobalHotkeyManager")
                            self.stopRecordingIfNeeded()
                        } else {
                            DebugLogger.shared.info("Command mode tap (\(String(format: "%.2f", pressDuration))s) - continues", source: "GlobalHotkeyManager")
                        }
                    } else {
                        DebugLogger.shared.info("Command mode hold (\(String(format: "%.2f", pressDuration))s) - stopping", source: "GlobalHotkeyManager")
                        self.stopRecordingIfNeeded()
                    }
                    self.wasRecordingBeforeCommandModeKeyDown = false
                }
                return nil
            }

            // Rewrite mode key up
            if self.rewriteModeShortcutEnabled, self.isRewriteKeyPressed, self.matchesRewriteModeShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                switch self.hotkeyMode {
                case .toggle:
                    // Toggle mode: keyUp is ignored
                    self.isRewriteKeyPressed = false
                case .hold:
                    // Hold mode: stop on keyUp
                    self.isRewriteKeyPressed = false
                    self.stopRecordingIfNeeded()
                case .automatic:
                    // Automatic mode: detect tap vs hold
                    let pressDuration = Date().timeIntervalSince(self.rewriteKeyDownTime ?? Date())
                    self.isRewriteKeyPressed = false
                    self.rewriteKeyDownTime = nil

                    if pressDuration < self.tapThresholdSeconds {
                        if self.wasRecordingBeforeRewriteKeyDown {
                            DebugLogger.shared.info("Rewrite mode tap (\(String(format: "%.2f", pressDuration))s) - stopping", source: "GlobalHotkeyManager")
                            self.stopRecordingIfNeeded()
                        } else {
                            DebugLogger.shared.info("Rewrite mode tap (\(String(format: "%.2f", pressDuration))s) - continues", source: "GlobalHotkeyManager")
                        }
                    } else {
                        DebugLogger.shared.info("Rewrite mode hold (\(String(format: "%.2f", pressDuration))s) - stopping", source: "GlobalHotkeyManager")
                        self.stopRecordingIfNeeded()
                    }
                    self.wasRecordingBeforeRewriteKeyDown = false
                }
                return nil
            }

            // Transcription key up
            if self.isKeyPressed, self.matchesShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                switch self.hotkeyMode {
                case .toggle:
                    // Toggle mode: keyUp is ignored (toggle happens on keyDown)
                    self.isKeyPressed = false
                case .hold:
                    // Hold mode: stop on keyUp
                    self.isKeyPressed = false
                    self.stopRecordingIfNeeded()
                case .automatic:
                    // Automatic mode: detect tap vs hold
                    let pressDuration = Date().timeIntervalSince(self.keyDownTime ?? Date())
                    self.isKeyPressed = false
                    self.keyDownTime = nil

                    if pressDuration < self.tapThresholdSeconds {
                        // TAP detected: toggle behavior
                        if self.wasRecordingBeforeKeyDown {
                            DebugLogger.shared.info("Tap (\(String(format: "%.2f", pressDuration))s) - stopping (was running)", source: "GlobalHotkeyManager")
                            self.stopRecordingIfNeeded()
                        } else {
                            DebugLogger.shared.info("Tap (\(String(format: "%.2f", pressDuration))s) - recording continues", source: "GlobalHotkeyManager")
                        }
                    } else {
                        // HOLD detected: stop on release
                        DebugLogger.shared.info("Hold (\(String(format: "%.2f", pressDuration))s) - stopping", source: "GlobalHotkeyManager")
                        self.stopRecordingIfNeeded()
                    }
                    self.wasRecordingBeforeKeyDown = false
                }
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
                switch self.hotkeyMode {
                case .toggle:
                    if isModifierPressed {
                        if self.asrService.isRunning {
                            self.stopRecordingIfNeeded()
                        } else {
                            self.triggerCommandMode()
                        }
                    }
                case .hold:
                    if isModifierPressed {
                        if !self.isCommandModeKeyPressed {
                            self.isCommandModeKeyPressed = true
                            self.triggerCommandMode()
                        }
                    } else if self.isCommandModeKeyPressed {
                        self.isCommandModeKeyPressed = false
                        self.stopRecordingIfNeeded()
                    }
                case .automatic:
                    if isModifierPressed {
                        if !self.isCommandModeKeyPressed {
                            self.isCommandModeKeyPressed = true
                            self.commandModeKeyDownTime = Date()
                            self.wasRecordingBeforeCommandModeKeyDown = self.asrService.isRunning
                            if !self.wasRecordingBeforeCommandModeKeyDown {
                                self.triggerCommandMode()
                            }
                        }
                    } else if self.isCommandModeKeyPressed {
                        let pressDuration = Date().timeIntervalSince(self.commandModeKeyDownTime ?? Date())
                        self.isCommandModeKeyPressed = false
                        self.commandModeKeyDownTime = nil

                        if pressDuration < self.tapThresholdSeconds {
                            if self.wasRecordingBeforeCommandModeKeyDown {
                                self.stopRecordingIfNeeded()
                            }
                        } else {
                            self.stopRecordingIfNeeded()
                        }
                        self.wasRecordingBeforeCommandModeKeyDown = false
                    }
                }
                return nil
            }

            // Check rewrite mode shortcut (if it's a modifier-only shortcut - actual modifier keys only)
            // Note: Regular keys with no modifiers are handled in keyDown, not flagsChanged
            // Only handle actual modifier keys (Command, Option, Control, Shift, Function) here
            if self.rewriteModeShortcutEnabled, self.rewriteModeShortcut.modifierFlags.isEmpty {
                // Check if this is an actual modifier key (not a regular key)
                let isModifierKey = keyCode == 54 || keyCode == 55 || // Command keys
                    keyCode == 58 || keyCode == 61 || // Option keys
                    keyCode == 59 || keyCode == 62 || // Control keys
                    keyCode == 56 || keyCode == 60 || // Shift keys
                    keyCode == 63 // Function key

                if isModifierKey, keyCode == self.rewriteModeShortcut.keyCode {
                    switch self.hotkeyMode {
                    case .toggle:
                        if isModifierPressed {
                            if self.asrService.isRunning {
                                self.stopRecordingIfNeeded()
                            } else {
                                self.triggerRewriteMode()
                            }
                        }
                    case .hold:
                        if isModifierPressed {
                            if !self.isRewriteKeyPressed {
                                self.isRewriteKeyPressed = true
                                self.triggerRewriteMode()
                            }
                        } else if self.isRewriteKeyPressed {
                            self.isRewriteKeyPressed = false
                            self.stopRecordingIfNeeded()
                        }
                    case .automatic:
                        if isModifierPressed {
                            if !self.isRewriteKeyPressed {
                                self.isRewriteKeyPressed = true
                                self.rewriteKeyDownTime = Date()
                                self.wasRecordingBeforeRewriteKeyDown = self.asrService.isRunning
                                if !self.wasRecordingBeforeRewriteKeyDown {
                                    self.triggerRewriteMode()
                                }
                            }
                        } else if self.isRewriteKeyPressed {
                            let pressDuration = Date().timeIntervalSince(self.rewriteKeyDownTime ?? Date())
                            self.isRewriteKeyPressed = false
                            self.rewriteKeyDownTime = nil

                            if pressDuration < self.tapThresholdSeconds {
                                if self.wasRecordingBeforeRewriteKeyDown {
                                    self.stopRecordingIfNeeded()
                                }
                            } else {
                                self.stopRecordingIfNeeded()
                            }
                            self.wasRecordingBeforeRewriteKeyDown = false
                        }
                    }
                    return nil
                }
            }

            // Check transcription shortcut (if it's a modifier-only shortcut)
            guard self.shortcut.modifierFlags.isEmpty else { break }

            if keyCode == self.shortcut.keyCode {
                switch self.hotkeyMode {
                case .toggle:
                    if isModifierPressed {
                        self.toggleRecording()
                    }
                case .hold:
                    if isModifierPressed {
                        if !self.isKeyPressed {
                            self.isKeyPressed = true
                            self.startRecordingIfNeeded()
                        }
                    } else if self.isKeyPressed {
                        self.isKeyPressed = false
                        self.stopRecordingIfNeeded()
                    }
                case .automatic:
                    if isModifierPressed {
                        if !self.isKeyPressed {
                            self.isKeyPressed = true
                            self.keyDownTime = Date()
                            self.wasRecordingBeforeKeyDown = self.asrService.isRunning
                            if !self.wasRecordingBeforeKeyDown {
                                self.startRecordingIfNeeded()
                            }
                        }
                    } else if self.isKeyPressed {
                        let pressDuration = Date().timeIntervalSince(self.keyDownTime ?? Date())
                        self.isKeyPressed = false
                        self.keyDownTime = nil

                        if pressDuration < self.tapThresholdSeconds {
                            if self.wasRecordingBeforeKeyDown {
                                self.stopRecordingIfNeeded()
                            }
                        } else {
                            self.stopRecordingIfNeeded()
                        }
                        self.wasRecordingBeforeKeyDown = false
                    }
                }
                return nil
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func triggerCommandMode() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Command mode hotkey triggered", source: "GlobalHotkeyManager")
            await self.commandModeCallback?()
        }
    }

    private func triggerRewriteMode() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Rewrite mode hotkey triggered", source: "GlobalHotkeyManager")
            await self.rewriteModeCallback?()
        }
    }

    /// Sets the hotkey activation mode
    func setHotkeyMode(_ mode: SettingsStore.HotkeyMode) {
        self.hotkeyMode = mode
        // Reset key states when mode changes
        self.isKeyPressed = false
        self.isCommandModeKeyPressed = false
        self.isRewriteKeyPressed = false
        self.keyDownTime = nil
        self.commandModeKeyDownTime = nil
        self.rewriteKeyDownTime = nil
        DebugLogger.shared.info("Hotkey mode set to: \(mode.displayName)", source: "GlobalHotkeyManager")
    }

    /// Legacy function for API compatibility - use setHotkeyMode instead
    func enablePressAndHoldMode(_ enable: Bool) {
        self.setHotkeyMode(enable ? .hold : .toggle)
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
