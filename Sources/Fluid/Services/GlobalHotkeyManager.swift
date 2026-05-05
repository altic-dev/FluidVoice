import AppKit
import Foundation

private enum HotkeyHoldModeType {
    case transcription
    case promptMode
    case commandMode
    case rewriteMode
}

private final class HotkeyState: @unchecked Sendable {
    private let lock = NSLock()
    var isKeyPressed = false
    var isPromptModeKeyPressed = false
    var isCommandModeKeyPressed = false
    var isRewriteKeyPressed = false
    var pressedModifierKeyCodes: Set<UInt16> = []
    var modifierOnlyKeyDown = false
    var otherKeyPressedDuringModifier = false
    var modifierPressStartTime: Date?
    var pendingHoldModeStart: Task<Void, Never>?
    var pendingHoldModeType: HotkeyHoldModeType?

    func withLock<T>(_ block: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return block()
    }
}

@MainActor
final class GlobalHotkeyManager: NSObject {
    private nonisolated(unsafe) var state = HotkeyState()
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private let asrService: ASRService
    private var shortcut: HotkeyShortcut
    private var promptModeShortcut: HotkeyShortcut
    private var commandModeShortcut: HotkeyShortcut
    private var rewriteModeShortcut: HotkeyShortcut
    private var promptModeShortcutEnabled: Bool
    private var commandModeShortcutEnabled: Bool
    private var rewriteModeShortcutEnabled: Bool
    private var startRecordingCallback: (() async -> Void)?
    private var dictationModeCallback: (() async -> Void)?
    private var stopAndProcessCallback: (() async -> Void)?
    private var promptModeCallback: (() async -> Void)?
    private var commandModeCallback: (() async -> Void)?
    private var rewriteModeCallback: (() async -> Void)?
    private var isDictateRecordingProvider: (() -> Bool)?
    private var isPromptModeRecordingProvider: (() -> Bool)?
    private var isCommandRecordingProvider: (() -> Bool)?
    private var isRewriteRecordingProvider: (() -> Bool)?
    private var isShortcutCaptureActiveProvider: (() -> Bool)?
    private var cancelCallback: (() -> Bool)? // Returns true if handled
    private var pressAndHoldMode: Bool = SettingsStore.shared.pressAndHoldMode

    private struct ModifierOnlyShortcutBehavior {
        let shortcut: HotkeyShortcut
        let isEnabled: Bool
        let holdModeType: HotkeyHoldModeType
        let holdStartCancelledMessage: String
        let holdStartMessage: String
        let holdReleaseMessage: String
        let toggleIgnoredMessage: String
        let isModeKeyPressed: () -> Bool
        let setModeKeyPressed: (Bool) -> Void
        let onHoldStart: () -> Void
        let onToggleRelease: () -> Void
    }

    enum ModifierTrackingResetReason {
        case shortcutCapture
        case tapDisabled
        case reinitialize
    }

    private nonisolated var isKeyPressed: Bool {
        get { self.state.withLock { self.state.isKeyPressed } }
        set { self.state.withLock { self.state.isKeyPressed = newValue } }
    }

    private nonisolated var isPromptModeKeyPressed: Bool {
        get { self.state.withLock { self.state.isPromptModeKeyPressed } }
        set { self.state.withLock { self.state.isPromptModeKeyPressed = newValue } }
    }

    private nonisolated var isCommandModeKeyPressed: Bool {
        get { self.state.withLock { self.state.isCommandModeKeyPressed } }
        set { self.state.withLock { self.state.isCommandModeKeyPressed = newValue } }
    }

    private nonisolated var isRewriteKeyPressed: Bool {
        get { self.state.withLock { self.state.isRewriteKeyPressed } }
        set { self.state.withLock { self.state.isRewriteKeyPressed = newValue } }
    }

    private nonisolated var pressedModifierKeyCodes: Set<UInt16> {
        get { self.state.withLock { self.state.pressedModifierKeyCodes } }
        set { self.state.withLock { self.state.pressedModifierKeyCodes = newValue } }
    }

    /// Modifier-only shortcut tracking: detect if another key was pressed during modifier hold
    private nonisolated var modifierOnlyKeyDown: Bool {
        get { self.state.withLock { self.state.modifierOnlyKeyDown } }
        set { self.state.withLock { self.state.modifierOnlyKeyDown = newValue } }
    }

    private nonisolated var otherKeyPressedDuringModifier: Bool {
        get { self.state.withLock { self.state.otherKeyPressedDuringModifier } }
        set { self.state.withLock { self.state.otherKeyPressedDuringModifier = newValue } }
    }

    /// Reserved for future tap-vs-hold timing detection (e.g., quick tap to toggle vs long hold)
    private nonisolated var modifierPressStartTime: Date? {
        get { self.state.withLock { self.state.modifierPressStartTime } }
        set { self.state.withLock { self.state.modifierPressStartTime = newValue } }
    }

    private nonisolated var pendingHoldModeStart: Task<Void, Never>? {
        get { self.state.withLock { self.state.pendingHoldModeStart } }
        set { self.state.withLock { self.state.pendingHoldModeStart = newValue } }
    }

    /// Tracks which mode's pending start is active (for cancellation on key combos)
    private nonisolated var pendingHoldModeType: HotkeyHoldModeType? {
        get { self.state.withLock { self.state.pendingHoldModeType } }
        set { self.state.withLock { self.state.pendingHoldModeType = newValue } }
    }

    /// Busy flag to prevent race conditions during stop processing
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
        promptModeShortcut: HotkeyShortcut,
        commandModeShortcut: HotkeyShortcut,
        rewriteModeShortcut: HotkeyShortcut,
        promptModeShortcutEnabled: Bool,
        commandModeShortcutEnabled: Bool,
        rewriteModeShortcutEnabled: Bool,
        startRecordingCallback: (() async -> Void)? = nil,
        dictationModeCallback: (() async -> Void)? = nil,
        stopAndProcessCallback: (() async -> Void)? = nil,
        promptModeCallback: (() async -> Void)? = nil,
        commandModeCallback: (() async -> Void)? = nil,
        rewriteModeCallback: (() async -> Void)? = nil,
        isDictateRecordingProvider: (() -> Bool)? = nil,
        isPromptModeRecordingProvider: (() -> Bool)? = nil,
        isCommandRecordingProvider: (() -> Bool)? = nil,
        isRewriteRecordingProvider: (() -> Bool)? = nil,
        isShortcutCaptureActiveProvider: (() -> Bool)? = nil
    ) {
        self.asrService = asrService
        self.shortcut = shortcut
        self.promptModeShortcut = promptModeShortcut
        self.commandModeShortcut = commandModeShortcut
        self.rewriteModeShortcut = rewriteModeShortcut
        self.promptModeShortcutEnabled = promptModeShortcutEnabled
        self.commandModeShortcutEnabled = commandModeShortcutEnabled
        self.rewriteModeShortcutEnabled = rewriteModeShortcutEnabled
        self.startRecordingCallback = startRecordingCallback
        self.dictationModeCallback = dictationModeCallback
        self.stopAndProcessCallback = stopAndProcessCallback
        self.promptModeCallback = promptModeCallback
        self.commandModeCallback = commandModeCallback
        self.rewriteModeCallback = rewriteModeCallback
        self.isDictateRecordingProvider = isDictateRecordingProvider
        self.isPromptModeRecordingProvider = isPromptModeRecordingProvider
        self.isCommandRecordingProvider = isCommandRecordingProvider
        self.isRewriteRecordingProvider = isRewriteRecordingProvider
        self.isShortcutCaptureActiveProvider = isShortcutCaptureActiveProvider
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

    func setPromptModeCallback(_ callback: @escaping () async -> Void) {
        self.promptModeCallback = callback
    }

    func updatePromptModeShortcut(_ newShortcut: HotkeyShortcut) {
        self.promptModeShortcut = newShortcut
        DebugLogger.shared.info("Updated prompt mode hotkey", source: "GlobalHotkeyManager")
    }

    func updatePromptModeShortcutEnabled(_ enabled: Bool) {
        self.promptModeShortcutEnabled = enabled
        if !enabled {
            self.isPromptModeKeyPressed = false
        }
        DebugLogger.shared.info(
            "Prompt mode shortcut \(enabled ? "enabled" : "disabled")",
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
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

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
        if let tapRecoveryResult = self.handleTapDisableEvent(type: type, event: event) {
            return tapRecoveryResult
        }

        if self.isShortcutCaptureActiveProvider?() ?? false {
            self.resetModifierOnlyShortcutTracking()
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            AutoLearnDictionaryService.shared.handleObservedMouseDown()
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
            // If a modifier-only shortcut key is being held and this is a different key, mark it
            if self.modifierOnlyKeyDown {
                self.otherKeyPressedDuringModifier = true
                // Cancel any pending hold mode start (user is doing a key combo, not just modifier)
                if let pending = self.pendingHoldModeStart {
                    pending.cancel()
                    self.pendingHoldModeStart = nil
                    self.pendingHoldModeType = nil
                    DebugLogger.shared.info("Another key pressed - cancelled pending hold mode start", source: "GlobalHotkeyManager")
                }
            }

            // Observe post-transcription edits (do not consume the event).
            Task {
                await PostTranscriptionEditTracker.shared.handleKeyDown(keyCode: keyCode, modifiers: eventModifiers)
            }
            AutoLearnDictionaryService.shared.handleObservedKeyDown(
                keyCode: keyCode,
                modifiers: eventModifiers,
                characters: NSEvent(cgEvent: event)?.characters
            )

            // Check the configured cancel shortcut first.
            if SettingsStore.shared.cancelRecordingHotkeyShortcut.matches(keyCode: keyCode, modifiers: eventModifiers) {
                var handled = false

                if self.asrService.isRunning {
                    DebugLogger.shared.info("Cancel shortcut pressed - cancelling recording", source: "GlobalHotkeyManager")
                    Task { @MainActor in
                        await self.asrService.stopWithoutTranscription()
                    }
                    handled = true
                }

                // Trigger cancel callback to close mode views / reset state
                if let callback = cancelCallback, callback() {
                    DebugLogger.shared.info("Cancel shortcut pressed - cancel callback handled", source: "GlobalHotkeyManager")
                    handled = true
                }

                if handled {
                    return nil // Consume event only if we did something
                }
            }

            // Check prompt mode hotkey
            if self.handlePromptModeKeyDown(keyCode: keyCode, modifiers: eventModifiers) { return nil }

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
                        if self.isCommandRecordingProvider?() ?? false {
                            DebugLogger.shared.info("Command mode shortcut pressed in Command mode - stopping", source: "GlobalHotkeyManager")
                            self.stopRecordingIfNeeded()
                        } else {
                            DebugLogger.shared.info("Command mode shortcut pressed while recording - switching mode", source: "GlobalHotkeyManager")
                            self.triggerCommandMode()
                        }
                    } else {
                        DebugLogger.shared.info("Command mode shortcut triggered - starting", source: "GlobalHotkeyManager")
                        self.triggerCommandMode()
                    }
                }
                return nil
            }

            // Check dedicated rewrite mode hotkey
            if self.rewriteModeShortcutEnabled {
                if self.matchesRewriteModeShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                    if self.pressAndHoldMode {
                        // Press and hold: start on keyDown, stop on keyUp
                        if !self.isRewriteKeyPressed {
                            self.isRewriteKeyPressed = true
                            DebugLogger.shared.info("Rewrite mode shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                            self.triggerRewriteMode()
                        }
                    } else {
                        // Toggle mode: press to start, press again to stop
                        if self.asrService.isRunning {
                            if self.isRewriteRecordingProvider?() ?? false {
                                DebugLogger.shared.info("Rewrite mode shortcut pressed in Edit mode - stopping", source: "GlobalHotkeyManager")
                                self.stopRecordingIfNeeded()
                            } else {
                                DebugLogger.shared.info("Rewrite mode shortcut pressed while recording - switching mode", source: "GlobalHotkeyManager")
                                self.triggerRewriteMode()
                            }
                        } else {
                            DebugLogger.shared.info("Rewrite mode shortcut triggered - starting", source: "GlobalHotkeyManager")
                            self.triggerRewriteMode()
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
                        if self.asrService.isRunning {
                            let isSameMode = self.isDictateRecordingProvider?() ?? false
                            DebugLogger.shared.debug(
                                "GlobalHotkeyManager: dictation hold-press path",
                                source: "GlobalHotkeyManager"
                            )
                            DebugLogger.shared.info(
                                "Hotkey route | pressed=dictate | active=\(isSameMode ? "dictate" : "other") | asrRunning=true | action=\(isSameMode ? "stop" : "switch")",
                                source: "GlobalHotkeyManager"
                            )
                            if !isSameMode {
                                self.triggerDictationMode()
                            }
                        } else {
                            DebugLogger.shared.info(
                                "Hotkey route | pressed=dictate | active=none | asrRunning=false | action=start",
                                source: "GlobalHotkeyManager"
                            )
                            self.startRecordingIfNeeded()
                        }
                    }
                } else {
                    if self.asrService.isRunning {
                        let isSameMode = self.isDictateRecordingProvider?() ?? false
                        DebugLogger.shared.debug(
                            "GlobalHotkeyManager: dictation tap path while already running",
                            source: "GlobalHotkeyManager"
                        )
                        DebugLogger.shared.info(
                            "Hotkey route | pressed=dictate | active=\(isSameMode ? "dictate" : "other") | asrRunning=true | action=\(isSameMode ? "stop" : "switch")",
                            source: "GlobalHotkeyManager"
                        )
                        if isSameMode {
                            self.stopRecordingIfNeeded()
                        } else {
                            self.triggerDictationMode()
                        }
                    } else {
                        DebugLogger.shared.info(
                            "Hotkey route | pressed=dictate | active=none | asrRunning=false | action=start",
                            source: "GlobalHotkeyManager"
                        )
                        self.triggerDictationMode()
                    }
                }
                return nil
            }

        case .keyUp:
            // Prompt mode key up (press and hold mode)
            if self.handlePromptModeKeyUp(keyCode: keyCode) { return nil }

            // Command mode key up (press and hold mode)
            // Note: Only check keyCode, not modifiers - user may release modifier before/with main key
            if self.commandModeShortcutEnabled, self.pressAndHoldMode, self.isCommandModeKeyPressed, keyCode == self.commandModeShortcut.keyCode {
                self.isCommandModeKeyPressed = false
                DebugLogger.shared.info("Command mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                self.stopRecordingIfNeeded()
                return nil
            }

            // Rewrite mode key up (press and hold mode)
            // Note: Only check keyCode, not modifiers - user may release modifier before/with main key
            if self.rewriteModeShortcutEnabled, self.pressAndHoldMode, self.isRewriteKeyPressed, keyCode == self.rewriteModeShortcut.keyCode {
                self.isRewriteKeyPressed = false
                DebugLogger.shared.info("Rewrite mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                self.stopRecordingIfNeeded()
                return nil
            }

            // Transcription key up
            // Note: Only check keyCode, not modifiers - user may release modifier before/with main key
            if self.pressAndHoldMode, self.isKeyPressed, keyCode == self.shortcut.keyCode {
                self.isKeyPressed = false
                self.stopRecordingIfNeeded()
                return nil
            }

        case .flagsChanged:
            if HotkeyShortcut.modifierFlag(forKeyCode: keyCode) != nil {
                self.pressedModifierKeyCodes = self.synchronizedPressedModifierKeyCodes(
                    changedKeyCode: keyCode,
                    modifiers: eventModifiers
                )
            }

            if self.handlePromptModeFlagsChanged(keyCode: keyCode, modifiers: eventModifiers) { return nil }

            if self.handleModifierOnlyShortcutFlagsChanged(
                behavior: .init(
                    shortcut: self.commandModeShortcut,
                    isEnabled: self.commandModeShortcutEnabled,
                    holdModeType: .commandMode,
                    holdStartCancelledMessage: "Command mode hold start cancelled - key combo detected",
                    holdStartMessage: "Command mode modifier held (hold mode) - starting after delay",
                    holdReleaseMessage: "Command mode modifier released (hold mode) - stopping",
                    toggleIgnoredMessage: "Command mode modifier released but another key was pressed - ignoring",
                    isModeKeyPressed: { self.isCommandModeKeyPressed },
                    setModeKeyPressed: { self.isCommandModeKeyPressed = $0 },
                    onHoldStart: { self.triggerCommandMode() },
                    onToggleRelease: {
                        if self.asrService.isRunning {
                            if self.isCommandRecordingProvider?() ?? false {
                                DebugLogger.shared.info("Command mode modifier released (toggle, same mode) - stopping", source: "GlobalHotkeyManager")
                                self.stopRecordingIfNeeded()
                            } else {
                                DebugLogger.shared.info("Command mode modifier released (toggle, switch mode) - switching", source: "GlobalHotkeyManager")
                                self.triggerCommandMode()
                            }
                        } else {
                            DebugLogger.shared.info("Command mode modifier released (toggle) - starting", source: "GlobalHotkeyManager")
                            self.triggerCommandMode()
                        }
                    }
                ),
                keyCode: keyCode,
                modifiers: eventModifiers
            ) { return nil }

            if self.handleModifierOnlyShortcutFlagsChanged(
                behavior: .init(
                    shortcut: self.rewriteModeShortcut,
                    isEnabled: self.rewriteModeShortcutEnabled,
                    holdModeType: .rewriteMode,
                    holdStartCancelledMessage: "Rewrite mode hold start cancelled - key combo detected",
                    holdStartMessage: "Rewrite mode modifier held (hold mode) - starting after delay",
                    holdReleaseMessage: "Rewrite mode modifier released (hold mode) - stopping",
                    toggleIgnoredMessage: "Rewrite mode modifier released but another key was pressed - ignoring",
                    isModeKeyPressed: { self.isRewriteKeyPressed },
                    setModeKeyPressed: { self.isRewriteKeyPressed = $0 },
                    onHoldStart: { self.triggerRewriteMode() },
                    onToggleRelease: {
                        if self.asrService.isRunning {
                            if self.isRewriteRecordingProvider?() ?? false {
                                DebugLogger.shared.info("Rewrite mode modifier released (toggle, same mode) - stopping", source: "GlobalHotkeyManager")
                                self.stopRecordingIfNeeded()
                            } else {
                                DebugLogger.shared.info("Rewrite mode modifier released (toggle, switch mode) - switching", source: "GlobalHotkeyManager")
                                self.triggerRewriteMode()
                            }
                        } else {
                            DebugLogger.shared.info("Rewrite mode modifier released (toggle) - starting", source: "GlobalHotkeyManager")
                            self.triggerRewriteMode()
                        }
                    }
                ),
                keyCode: keyCode,
                modifiers: eventModifiers
            ) { return nil }

            if self.handleModifierOnlyShortcutFlagsChanged(
                behavior: .init(
                    shortcut: self.shortcut,
                    isEnabled: true,
                    holdModeType: .transcription,
                    holdStartCancelledMessage: "Transcription hold start cancelled - key combo detected",
                    holdStartMessage: "Transcription modifier held (hold mode) - starting after delay",
                    holdReleaseMessage: "Transcription modifier released (hold mode) - stopping",
                    toggleIgnoredMessage: "Transcription modifier released but another key was pressed - ignoring",
                    isModeKeyPressed: { self.isKeyPressed },
                    setModeKeyPressed: { self.isKeyPressed = $0 },
                    onHoldStart: { self.startRecordingIfNeeded() },
                    onToggleRelease: {
                        if self.asrService.isRunning {
                            let isSameMode = self.isDictateRecordingProvider?() ?? false
                            DebugLogger.shared.info(
                                "Hotkey route | pressed=dictate(mod) | active=\(isSameMode ? "dictate" : "other") | asrRunning=true | action=\(isSameMode ? "stop" : "switch")",
                                source: "GlobalHotkeyManager"
                            )
                            if isSameMode {
                                self.stopRecordingIfNeeded()
                            } else {
                                self.triggerDictationMode()
                            }
                        } else {
                            DebugLogger.shared.info(
                                "Hotkey route | pressed=dictate(mod) | active=none | asrRunning=false | action=start",
                                source: "GlobalHotkeyManager"
                            )
                            self.triggerDictationMode()
                        }
                    }
                ),
                keyCode: keyCode,
                modifiers: eventModifiers
            ) { return nil }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleTapDisableEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS can temporarily disable event taps (e.g. timeouts, user input protection).
        // If we don't immediately re-enable here, hotkeys will silently stop working until our
        // periodic health check kicks in, and the OS may handle the key (e.g. system dictation).
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else {
            return nil
        }

        let reason = (type == .tapDisabledByTimeout) ? "timeout" : "user input"
        DebugLogger.shared.warning("Event tap disabled by \(reason) — attempting immediate re-enable", source: "GlobalHotkeyManager")
        self.resetModifierOnlyShortcutTracking(reason: .tapDisabled)

        if let tap = self.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        if !self.isEventTapEnabled() {
            DebugLogger.shared.warning("Event tap re-enable failed — recreating tap", source: "GlobalHotkeyManager")
            self.setupGlobalHotkeyWithRetry()
        }

        return Unmanaged.passUnretained(event)
    }

    private func synchronizedPressedModifierKeyCodes(
        changedKeyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Set<UInt16> {
        guard let changedFlag = HotkeyShortcut.modifierFlag(forKeyCode: changedKeyCode) else {
            return self.pressedModifierKeyCodes
        }

        let activeModifiers = modifiers.intersection(HotkeyShortcut.relevantModifierMask)
        let activeModifierGroups: [(NSEvent.ModifierFlags, [UInt16])] = [
            (.function, [63]),
            (.command, [55, 54]),
            (.option, [58, 61]),
            (.control, [59, 62]),
            (.shift, [56, 60]),
        ]

        var synchronizedKeyCodes = Set<UInt16>()

        for (flag, keyCodes) in activeModifierGroups where activeModifiers.contains(flag) {
            let livePressedKeyCodes = keyCodes.filter {
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
            }

            if !livePressedKeyCodes.isEmpty {
                synchronizedKeyCodes.formUnion(livePressedKeyCodes)
                continue
            }

            // If the changed modifier family is active but the live key-state query did not yet
            // reflect it, trust the current event's key code for this transition.
            if flag == changedFlag {
                synchronizedKeyCodes.insert(changedKeyCode)
            }
        }

        return synchronizedKeyCodes
    }

    private func cancelPendingModifierOnlyHoldStart(
        for behavior: ModifierOnlyShortcutBehavior,
        message: String
    ) {
        guard self.pendingHoldModeType == behavior.holdModeType else { return }
        self.otherKeyPressedDuringModifier = true
        self.pendingHoldModeStart?.cancel()
        self.pendingHoldModeStart = nil
        self.pendingHoldModeType = nil
        DebugLogger.shared.info(message, source: "GlobalHotkeyManager")
    }

    func resetModifierOnlyShortcutTracking(reason: ModifierTrackingResetReason = .shortcutCapture) {
        let shouldStopActiveHold = self.pressAndHoldMode
            && self.asrService.isRunning
            && (self.isKeyPressed || self.isPromptModeKeyPressed || self.isCommandModeKeyPressed || self.isRewriteKeyPressed)

        self.pressedModifierKeyCodes = []
        self.modifierOnlyKeyDown = false
        self.otherKeyPressedDuringModifier = false
        self.modifierPressStartTime = nil
        self.pendingHoldModeStart?.cancel()
        self.pendingHoldModeStart = nil
        self.pendingHoldModeType = nil
        self.isKeyPressed = false
        self.isPromptModeKeyPressed = false
        self.isCommandModeKeyPressed = false
        self.isRewriteKeyPressed = false

        if shouldStopActiveHold {
            switch reason {
            case .shortcutCapture:
                DebugLogger.shared.debug("Shortcut capture active - stopping active hold recording before reset", source: "GlobalHotkeyManager")
            case .tapDisabled:
                DebugLogger.shared.warning("Event tap disabled during active hold - stopping recording before reset", source: "GlobalHotkeyManager")
            case .reinitialize:
                DebugLogger.shared.info("Hotkey manager reinitializing - stopping active hold recording before reset", source: "GlobalHotkeyManager")
            }
            self.stopRecordingIfNeeded()
        }
    }

    private func handlePromptModeKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard self.promptModeShortcutEnabled, self.matchesPromptModeShortcut(keyCode: keyCode, modifiers: modifiers) else { return false }
        if self.pressAndHoldMode {
            if !self.isPromptModeKeyPressed {
                self.isPromptModeKeyPressed = true
                DebugLogger.shared.info("Prompt mode shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                self.triggerPromptMode()
            }
        } else {
            if self.asrService.isRunning {
                if self.isPromptModeRecordingProvider?() ?? false {
                    DebugLogger.shared.info("Prompt mode shortcut pressed in Prompt mode - stopping", source: "GlobalHotkeyManager")
                    self.stopRecordingIfNeeded()
                } else {
                    DebugLogger.shared.info("Prompt mode shortcut pressed while recording - switching mode", source: "GlobalHotkeyManager")
                    self.triggerPromptMode()
                }
            } else {
                DebugLogger.shared.info("Prompt mode shortcut triggered - starting", source: "GlobalHotkeyManager")
                self.triggerPromptMode()
            }
        }
        return true
    }

    private func handlePromptModeKeyUp(keyCode: UInt16) -> Bool {
        guard self.promptModeShortcutEnabled, self.pressAndHoldMode,
              self.isPromptModeKeyPressed, keyCode == self.promptModeShortcut.keyCode else { return false }
        self.isPromptModeKeyPressed = false
        DebugLogger.shared.info("Prompt mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
        self.stopRecordingIfNeeded()
        return true
    }

    private func handlePromptModeFlagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        self.handleModifierOnlyShortcutFlagsChanged(
            behavior: .init(
                shortcut: self.promptModeShortcut,
                isEnabled: self.promptModeShortcutEnabled,
                holdModeType: .promptMode,
                holdStartCancelledMessage: "Prompt mode hold start cancelled - key combo detected",
                holdStartMessage: "Prompt mode modifier held (hold mode) - starting after delay",
                holdReleaseMessage: "Prompt mode modifier released (hold mode) - stopping",
                toggleIgnoredMessage: "Prompt mode modifier released but another key was pressed - ignoring",
                isModeKeyPressed: { self.isPromptModeKeyPressed },
                setModeKeyPressed: { self.isPromptModeKeyPressed = $0 },
                onHoldStart: { self.triggerPromptMode() },
                onToggleRelease: {
                    if self.asrService.isRunning {
                        if self.isPromptModeRecordingProvider?() ?? false {
                            DebugLogger.shared.info("Prompt mode modifier released (toggle, same mode) - stopping", source: "GlobalHotkeyManager")
                            self.stopRecordingIfNeeded()
                        } else {
                            DebugLogger.shared.info("Prompt mode modifier released (toggle, switch mode) - switching", source: "GlobalHotkeyManager")
                            self.triggerPromptMode()
                        }
                    } else {
                        DebugLogger.shared.info("Prompt mode modifier released (toggle) - starting", source: "GlobalHotkeyManager")
                        self.triggerPromptMode()
                    }
                }
            ),
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    private func handleModifierOnlyShortcutFlagsChanged(
        behavior: ModifierOnlyShortcutBehavior,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let shortcut = behavior.shortcut
        guard behavior.isEnabled, shortcut.isModifierOnlyShortcut else { return false }

        let relevantModifiers = modifiers.intersection(HotkeyShortcut.relevantModifierMask)
        let expectedModifierKeyCodes = shortcut.normalizedModifierKeyCodes
        if !expectedModifierKeyCodes.isEmpty {
            let pressedModifierKeyCodes = HotkeyShortcut.normalizedModifierKeyCodes(from: Array(self.pressedModifierKeyCodes))
            if pressedModifierKeyCodes == expectedModifierKeyCodes {
                self.modifierOnlyKeyDown = true
                self.otherKeyPressedDuringModifier = false
                self.modifierPressStartTime = Date()

                if self.pressAndHoldMode, !behavior.isModeKeyPressed() {
                    behavior.setModeKeyPressed(true)
                    self.pendingHoldModeStart?.cancel()
                    self.pendingHoldModeType = behavior.holdModeType
                    self.pendingHoldModeStart = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard let self = self, !Task.isCancelled else { return }
                        guard behavior.isModeKeyPressed(), !self.otherKeyPressedDuringModifier else {
                            DebugLogger.shared.debug(behavior.holdStartCancelledMessage, source: "GlobalHotkeyManager")
                            return
                        }
                        DebugLogger.shared.info(behavior.holdStartMessage, source: "GlobalHotkeyManager")
                        behavior.onHoldStart()
                    }
                }
                return true
            }

            if self.modifierOnlyKeyDown || behavior.isModeKeyPressed() {
                let extraModifierKeyCodes = pressedModifierKeyCodes.filter { !expectedModifierKeyCodes.contains($0) }
                if !extraModifierKeyCodes.isEmpty {
                    self.cancelPendingModifierOnlyHoldStart(
                        for: behavior,
                        message: "\(behavior.holdStartCancelledMessage) - extra modifier pressed"
                    )
                }
            }

            guard self.modifierOnlyKeyDown || behavior.isModeKeyPressed(),
                  expectedModifierKeyCodes.contains(keyCode),
                  !pressedModifierKeyCodes.contains(keyCode)
            else {
                return false
            }

            let wasCleanPress = !self.otherKeyPressedDuringModifier
            self.modifierOnlyKeyDown = false
            self.otherKeyPressedDuringModifier = false
            self.modifierPressStartTime = nil

            if self.pressAndHoldMode {
                self.pendingHoldModeStart?.cancel()
                self.pendingHoldModeStart = nil
                self.pendingHoldModeType = nil

                if behavior.isModeKeyPressed() {
                    behavior.setModeKeyPressed(false)
                    if self.asrService.isRunning {
                        DebugLogger.shared.info(behavior.holdReleaseMessage, source: "GlobalHotkeyManager")
                        self.stopRecordingIfNeeded()
                    }
                }
            } else if wasCleanPress {
                behavior.onToggleRelease()
            } else {
                DebugLogger.shared.debug(behavior.toggleIgnoredMessage, source: "GlobalHotkeyManager")
            }
            return true
        }

        guard let expectedPressedModifiers = shortcut.expectedModifierFlags,
              let triggerFlag = shortcut.modifierTriggerFlag
        else {
            return false
        }

        if relevantModifiers == expectedPressedModifiers {
            self.modifierOnlyKeyDown = true
            self.otherKeyPressedDuringModifier = false
            self.modifierPressStartTime = Date()

            if self.pressAndHoldMode, !behavior.isModeKeyPressed() {
                behavior.setModeKeyPressed(true)
                self.pendingHoldModeStart?.cancel()
                self.pendingHoldModeType = behavior.holdModeType
                self.pendingHoldModeStart = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard let self = self, !Task.isCancelled else { return }
                    guard behavior.isModeKeyPressed(), !self.otherKeyPressedDuringModifier else {
                        DebugLogger.shared.debug(behavior.holdStartCancelledMessage, source: "GlobalHotkeyManager")
                        return
                    }
                    DebugLogger.shared.info(behavior.holdStartMessage, source: "GlobalHotkeyManager")
                    behavior.onHoldStart()
                }
            }
            return true
        }

        if self.modifierOnlyKeyDown || behavior.isModeKeyPressed() {
            let unexpectedModifiers = relevantModifiers.subtracting(expectedPressedModifiers)
            if !unexpectedModifiers.isEmpty {
                self.cancelPendingModifierOnlyHoldStart(
                    for: behavior,
                    message: "\(behavior.holdStartCancelledMessage) - extra modifier pressed"
                )
            }
        }

        guard self.modifierOnlyKeyDown || behavior.isModeKeyPressed(),
              keyCode == shortcut.keyCode,
              !relevantModifiers.contains(triggerFlag)
        else {
            return false
        }

        let wasCleanPress = !self.otherKeyPressedDuringModifier
        self.modifierOnlyKeyDown = false
        self.otherKeyPressedDuringModifier = false
        self.modifierPressStartTime = nil

        if self.pressAndHoldMode {
            self.pendingHoldModeStart?.cancel()
            self.pendingHoldModeStart = nil
            self.pendingHoldModeType = nil

            if behavior.isModeKeyPressed() {
                behavior.setModeKeyPressed(false)
                if self.asrService.isRunning {
                    DebugLogger.shared.info(behavior.holdReleaseMessage, source: "GlobalHotkeyManager")
                    self.stopRecordingIfNeeded()
                }
            }
        } else if wasCleanPress {
            behavior.onToggleRelease()
        } else {
            DebugLogger.shared.debug(behavior.toggleIgnoredMessage, source: "GlobalHotkeyManager")
        }
        return true
    }

    private func triggerPromptMode() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Prompt mode hotkey triggered", source: "GlobalHotkeyManager")
            await self.promptModeCallback?()
        }
    }

    private func triggerCommandMode() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Command mode hotkey triggered", source: "GlobalHotkeyManager")
            DebugLogger.shared.debug(
                "GlobalHotkeyManager: command callback path, isRunning=\(self.asrService.isRunning), isReady=\(self.asrService.isAsrReady)",
                source: "GlobalHotkeyManager"
            )
            await self.commandModeCallback?()
        }
    }

    private func triggerRewriteMode() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Rewrite mode hotkey triggered", source: "GlobalHotkeyManager")
            DebugLogger.shared.debug(
                "GlobalHotkeyManager: rewrite callback path, isRunning=\(self.asrService.isRunning), isReady=\(self.asrService.isAsrReady)",
                source: "GlobalHotkeyManager"
            )
            await self.rewriteModeCallback?()
        }
    }

    private func triggerDictationMode() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let model = SettingsStore.shared.selectedSpeechModel
            DebugLogger.shared.info("Dictate mode hotkey triggered", source: "GlobalHotkeyManager")
            DebugLogger.shared.debug(
                "GlobalHotkeyManager: dictate callback path, isRunning=\(self.asrService.isRunning), isReady=\(self.asrService.isAsrReady), model=\(model.displayName)",
                source: "GlobalHotkeyManager"
            )
            if let callback = self.dictationModeCallback {
                DebugLogger.shared.debug("GlobalHotkeyManager: invoking dictationModeCallback", source: "GlobalHotkeyManager")
                await callback()
            } else if let startCallback = self.startRecordingCallback {
                DebugLogger.shared.debug(
                    "GlobalHotkeyManager: dictationModeCallback missing; invoking fallback callback",
                    source: "GlobalHotkeyManager"
                )
                await startCallback()
            } else {
                DebugLogger.shared.warning(
                    "GlobalHotkeyManager: dictation callbacks missing; invoking ASRService.start directly",
                    source: "GlobalHotkeyManager"
                )
                await self.asrService.start()
            }
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
                    await self.asrService.start()
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
                    await self.asrService.start()
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

    private func matchesPromptModeShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevantModifiers: NSEvent.ModifierFlags = modifiers.intersection([.function, .command, .option, .control, .shift])
        let shortcutModifiers = self.promptModeShortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        return keyCode == self.promptModeShortcut.keyCode && relevantModifiers == shortcutModifiers
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
        self.resetModifierOnlyShortcutTracking(reason: .reinitialize)
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
    }
}
