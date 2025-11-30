import Foundation
import AppKit

final class GlobalHotkeyManager: NSObject
{
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let asrService: ASRService
    private var shortcut: HotkeyShortcut
    private var commandModeShortcut: HotkeyShortcut
    private var rewriteModeShortcut: HotkeyShortcut
    private var startRecordingCallback: (() async -> Void)?
    private var stopAndProcessCallback: (() async -> Void)?
    private var commandModeCallback: (() async -> Void)?
    private var rewriteModeCallback: (() async -> Void)?
    private var cancelCallback: (() -> Bool)?  // Returns true if handled
    private var pressAndHoldMode: Bool = SettingsStore.shared.pressAndHoldMode
    private var isKeyPressed = false
    private var isCommandModeKeyPressed = false
    private var isRewriteKeyPressed = false
    
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
        startRecordingCallback: (() async -> Void)? = nil,
        stopAndProcessCallback: (() async -> Void)? = nil,
        commandModeCallback: (() async -> Void)? = nil,
        rewriteModeCallback: (() async -> Void)? = nil
    )
    {
        self.asrService = asrService
        self.shortcut = shortcut
        self.commandModeShortcut = commandModeShortcut
        self.rewriteModeShortcut = rewriteModeShortcut
        self.startRecordingCallback = startRecordingCallback
        self.stopAndProcessCallback = stopAndProcessCallback
        self.commandModeCallback = commandModeCallback
        self.rewriteModeCallback = rewriteModeCallback
        super.init()
        
        initializeWithDelay()
    }
    
    private func initializeWithDelay() {
        DebugLogger.shared.debug("Starting delayed initialization...", source: "GlobalHotkeyManager")
        
        initializationTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 second delay
            
            await MainActor.run {
                self.setupGlobalHotkeyWithRetry()
            }
        }
    }

    func setStopAndProcessCallback(_ callback: @escaping () async -> Void)
    {
        self.stopAndProcessCallback = callback
    }
    
    func setCommandModeCallback(_ callback: @escaping () async -> Void)
    {
        self.commandModeCallback = callback
    }
    
    func updateShortcut(_ newShortcut: HotkeyShortcut)
    {
        self.shortcut = newShortcut
        DebugLogger.shared.info("Updated transcription hotkey", source: "GlobalHotkeyManager")
    }
    
    func updateCommandModeShortcut(_ newShortcut: HotkeyShortcut)
    {
        self.commandModeShortcut = newShortcut
        DebugLogger.shared.info("Updated command mode hotkey", source: "GlobalHotkeyManager")
    }
    
    func setRewriteModeCallback(_ callback: @escaping () async -> Void)
    {
        self.rewriteModeCallback = callback
    }
    
    func updateRewriteModeShortcut(_ newShortcut: HotkeyShortcut)
    {
        self.rewriteModeShortcut = newShortcut
        DebugLogger.shared.info("Updated rewrite mode hotkey", source: "GlobalHotkeyManager")
    }
    
    func setCancelCallback(_ callback: @escaping () -> Bool)
    {
        self.cancelCallback = callback
    }

    private func setupGlobalHotkeyWithRetry() {
        for attempt in 1...maxRetryAttempts {
            DebugLogger.shared.debug("Setup attempt \(attempt)/\(maxRetryAttempts)", source: "GlobalHotkeyManager")
            
            if setupGlobalHotkey() {
                isInitialized = true
                DebugLogger.shared.info("Successfully initialized on attempt \(attempt)", source: "GlobalHotkeyManager")
                startHealthCheckTimer()
                return
            }
            
            if attempt < maxRetryAttempts {
                DebugLogger.shared.warning("Attempt \(attempt) failed, retrying in \(retryDelay) seconds...", source: "GlobalHotkeyManager")
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    await MainActor.run { [weak self] in
                        self?.setupGlobalHotkeyWithRetry()
                    }
                }
                return
            }
        }
        
        DebugLogger.shared.error("Failed to initialize after \(maxRetryAttempts) attempts", source: "GlobalHotkeyManager")
    }
    
    @discardableResult
    private func setupGlobalHotkey() -> Bool
    {
        cleanupEventTap()
        
        if !AXIsProcessTrusted() {
            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                print("[GlobalHotkeyManager] Accessibility permissions not granted")
            }
            return false
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
                    | (1 << CGEventType.keyUp.rawValue)
                    | (1 << CGEventType.flagsChanged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let tap = eventTap else {
            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                print("[GlobalHotkeyManager] Failed to create CGEvent tap")
            }
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = runLoopSource else {
            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                print("[GlobalHotkeyManager] Failed to create CFRunLoopSource")
            }
            return false
        }
        
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        if !isEventTapEnabled() {
            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                print("[GlobalHotkeyManager] Event tap could not be enabled")
            }
            cleanupEventTap()
            return false
        }
        
        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
            print("[GlobalHotkeyManager] Event tap successfully created and enabled")
        }
        return true
    }
    
    private func cleanupEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        
        eventTap = nil
        runLoopSource = nil
    }

    private func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>?
    {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        var eventModifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskSecondaryFn) { eventModifiers.insert(.function) }
        if flags.contains(.maskCommand) { eventModifiers.insert(.command) }
        if flags.contains(.maskAlternate) { eventModifiers.insert(.option) }
        if flags.contains(.maskControl) { eventModifiers.insert(.control) }
        if flags.contains(.maskShift) { eventModifiers.insert(.shift) }

        switch type
        {
        case .keyDown:
            // Check Escape key first (keyCode 53) - cancels recording and closes mode views
            if keyCode == 53 && eventModifiers.isEmpty {
                var handled = false
                
                if asrService.isRunning {
                    DebugLogger.shared.info("Escape pressed - cancelling recording", source: "GlobalHotkeyManager")
                    Task { @MainActor in
                        self.asrService.stopWithoutTranscription()
                    }
                    handled = true
                }
                
                // Trigger cancel callback to close mode views / reset state
                if let callback = cancelCallback, callback() {
                    DebugLogger.shared.info("Escape pressed - cancel callback handled", source: "GlobalHotkeyManager")
                    handled = true
                }
                
                if handled {
                    return nil  // Consume event only if we did something
                }
            }
            
            // Check command mode hotkey first
            if matchesCommandModeShortcut(keyCode: keyCode, modifiers: eventModifiers)
            {
                if pressAndHoldMode {
                    // Press and hold: start on keyDown, stop on keyUp
                    if !isCommandModeKeyPressed {
                        isCommandModeKeyPressed = true
                        DebugLogger.shared.info("Command mode shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                        triggerCommandMode()
                    }
                } else {
                    // Toggle mode: press to start, press again to stop
                    if asrService.isRunning {
                        DebugLogger.shared.info("Command mode shortcut pressed while recording - stopping", source: "GlobalHotkeyManager")
                        stopRecordingIfNeeded()
                    } else {
                        DebugLogger.shared.info("Command mode shortcut triggered - starting", source: "GlobalHotkeyManager")
                        triggerCommandMode()
                    }
                }
                return nil
            }
            
            // Check dedicated rewrite mode hotkey
            if matchesRewriteModeShortcut(keyCode: keyCode, modifiers: eventModifiers)
            {
                if pressAndHoldMode {
                    // Press and hold: start on keyDown, stop on keyUp
                    if !isRewriteKeyPressed {
                        isRewriteKeyPressed = true
                        DebugLogger.shared.info("Rewrite mode shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                        triggerRewriteMode()
                    }
                } else {
                    // Toggle mode: press to start, press again to stop
                    if asrService.isRunning {
                        DebugLogger.shared.info("Rewrite mode shortcut pressed while recording - stopping", source: "GlobalHotkeyManager")
                        stopRecordingIfNeeded()
                    } else {
                        DebugLogger.shared.info("Rewrite mode shortcut triggered - starting", source: "GlobalHotkeyManager")
                        triggerRewriteMode()
                    }
                }
                return nil
            }
            
            // Then check transcription hotkey
            if matchesShortcut(keyCode: keyCode, modifiers: eventModifiers)
            {
                if pressAndHoldMode
                {
                    if !isKeyPressed
                    {
                        isKeyPressed = true
                        startRecordingIfNeeded()
                    }
                }
                else
                {
                    toggleRecording()
                }
                return nil
            }

        case .keyUp:
            // Command mode key up (press and hold mode)
            if pressAndHoldMode && isCommandModeKeyPressed && matchesCommandModeShortcut(keyCode: keyCode, modifiers: eventModifiers)
            {
                isCommandModeKeyPressed = false
                DebugLogger.shared.info("Command mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                stopRecordingIfNeeded()
                return nil
            }
            
            // Rewrite mode key up (press and hold mode)
            if pressAndHoldMode && isRewriteKeyPressed && matchesRewriteModeShortcut(keyCode: keyCode, modifiers: eventModifiers)
            {
                isRewriteKeyPressed = false
                DebugLogger.shared.info("Rewrite mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                stopRecordingIfNeeded()
                return nil
            }
            
            // Transcription key up
            if pressAndHoldMode && isKeyPressed && matchesShortcut(keyCode: keyCode, modifiers: eventModifiers)
            {
                isKeyPressed = false
                stopRecordingIfNeeded()
                return nil
            }

        case .flagsChanged:
            let isModifierPressed = flags.contains(.maskSecondaryFn)
                || flags.contains(.maskCommand)
                || flags.contains(.maskAlternate)
                || flags.contains(.maskControl)
                || flags.contains(.maskShift)
            
            // Check command mode shortcut (if it's a modifier-only shortcut)
            if commandModeShortcut.modifierFlags.isEmpty && keyCode == commandModeShortcut.keyCode
            {
                if isModifierPressed
                {
                    if pressAndHoldMode {
                        if !isCommandModeKeyPressed {
                            isCommandModeKeyPressed = true
                            DebugLogger.shared.info("Command mode modifier pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                            triggerCommandMode()
                        }
                    } else {
                        // Toggle mode
                        if asrService.isRunning {
                            DebugLogger.shared.info("Command mode modifier pressed while recording - stopping", source: "GlobalHotkeyManager")
                            stopRecordingIfNeeded()
                        } else {
                            DebugLogger.shared.info("Command mode modifier pressed - starting", source: "GlobalHotkeyManager")
                            triggerCommandMode()
                        }
                    }
                } else if pressAndHoldMode && isCommandModeKeyPressed {
                    // Key released in press-and-hold mode
                    isCommandModeKeyPressed = false
                    DebugLogger.shared.info("Command mode modifier released (hold mode) - stopping", source: "GlobalHotkeyManager")
                    stopRecordingIfNeeded()
                }
                return nil
            }
            
            // Check rewrite mode shortcut (if it's a modifier-only shortcut)
            if rewriteModeShortcut.modifierFlags.isEmpty && keyCode == rewriteModeShortcut.keyCode
            {
                if isModifierPressed
                {
                    if pressAndHoldMode {
                        if !isRewriteKeyPressed {
                            isRewriteKeyPressed = true
                            DebugLogger.shared.info("Rewrite mode modifier pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                            triggerRewriteMode()
                        }
                    } else {
                        // Toggle mode
                        if asrService.isRunning {
                            DebugLogger.shared.info("Rewrite mode modifier pressed while recording - stopping", source: "GlobalHotkeyManager")
                            stopRecordingIfNeeded()
                        } else {
                            DebugLogger.shared.info("Rewrite mode modifier pressed - starting", source: "GlobalHotkeyManager")
                            triggerRewriteMode()
                        }
                    }
                } else if pressAndHoldMode && isRewriteKeyPressed {
                    // Key released in press-and-hold mode
                    isRewriteKeyPressed = false
                    DebugLogger.shared.info("Rewrite mode modifier released (hold mode) - stopping", source: "GlobalHotkeyManager")
                    stopRecordingIfNeeded()
                }
                return nil
            }

            // Check transcription shortcut (if it's a modifier-only shortcut)
            guard shortcut.modifierFlags.isEmpty else { break }

            if keyCode == shortcut.keyCode
            {
                if pressAndHoldMode
                {
                    if isModifierPressed
                    {
                        if !isKeyPressed
                        {
                            isKeyPressed = true
                            startRecordingIfNeeded()
                        }
                    }
                    else if isKeyPressed
                    {
                        isKeyPressed = false
                        stopRecordingIfNeeded()
                    }
                }
                else if isModifierPressed
                {
                    toggleRecording()
                }
                return nil
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
    
    private func triggerCommandMode()
    {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Command mode hotkey triggered", source: "GlobalHotkeyManager")
            await self.commandModeCallback?()
        }
    }
    
    private func triggerRewriteMode()
    {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            DebugLogger.shared.info("Rewrite mode hotkey triggered", source: "GlobalHotkeyManager")
            await self.rewriteModeCallback?()
        }
    }

    func enablePressAndHoldMode(_ enable: Bool)
    {
        pressAndHoldMode = enable
        if !enable && isKeyPressed
        {
            isKeyPressed = false
            stopRecordingIfNeeded()
        }
        else if enable
        {
            isKeyPressed = false
        }
    }

    private func toggleRecording()
    {
        // Capture state at event time to prevent race conditions
        let shouldStop = asrService.isRunning
        let alreadyProcessing = isProcessingStop
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // Prevent new operations while stop is processing
            if alreadyProcessing {
                DebugLogger.shared.debug("Ignoring toggle - stop already in progress", source: "GlobalHotkeyManager")
                return
            }
            
            if shouldStop
            {
                await self.stopRecordingInternal()
            }
            else
            {
                // Use callback if available, otherwise fallback to direct start
                if let callback = self.startRecordingCallback {
                    await callback()
                } else {
                    self.asrService.start()
                }
            }
        }
    }

    private func startRecordingIfNeeded()
    {
        // Capture state at event time
        let alreadyRunning = asrService.isRunning
        let alreadyProcessing = isProcessingStop
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // Prevent starting while stop is processing
            if alreadyProcessing {
                DebugLogger.shared.debug("Ignoring start - stop in progress", source: "GlobalHotkeyManager")
                return
            }
            
            if !alreadyRunning
            {
                // Use callback if available, otherwise fallback to direct start
                if let callback = self.startRecordingCallback {
                    await callback()
                } else {
                    self.asrService.start()
                }
            }
        }
    }

    private func stopRecordingIfNeeded()
    {
        // Capture state at event time
        let shouldStop = asrService.isRunning
        let alreadyProcessing = isProcessingStop
        
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
    private func stopRecordingInternal() async
    {
        guard asrService.isRunning else { return }
        guard !isProcessingStop else {
            DebugLogger.shared.debug("Stop already in progress, ignoring", source: "GlobalHotkeyManager")
            return
        }
        
        isProcessingStop = true
        defer { isProcessingStop = false }
        
        if let callback = stopAndProcessCallback
        {
            await callback()
        }
        else
        {
            asrService.stopWithoutTranscription()
        }
    }

    private func matchesShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool
    {
        let relevantModifiers: NSEvent.ModifierFlags = modifiers.intersection([.function, .command, .option, .control, .shift])
        let shortcutModifiers = shortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        return keyCode == shortcut.keyCode && relevantModifiers == shortcutModifiers
    }
    
    private func matchesCommandModeShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool
    {
        let relevantModifiers: NSEvent.ModifierFlags = modifiers.intersection([.function, .command, .option, .control, .shift])
        let shortcutModifiers = commandModeShortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        return keyCode == commandModeShortcut.keyCode && relevantModifiers == shortcutModifiers
    }
    
    private func matchesRewriteModeShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool
    {
        let relevantModifiers: NSEvent.ModifierFlags = modifiers.intersection([.function, .command, .option, .control, .shift])
        let shortcutModifiers = rewriteModeShortcut.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        return keyCode == rewriteModeShortcut.keyCode && relevantModifiers == shortcutModifiers
    }
    
    func isEventTapEnabled() -> Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }
    
    func validateEventTapHealth() -> Bool {
        guard isInitialized else { return false }
        return isEventTapEnabled()
    }
    
    func reinitialize() {
        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
            print("[GlobalHotkeyManager] Manual reinitialization requested")
        }
        
        initializationTask?.cancel()
        healthCheckTask?.cancel()
        isInitialized = false
        initializeWithDelay()
    }

    private func startHealthCheckTimer() {
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(healthCheckInterval * 1_000_000_000))
                
                guard !Task.isCancelled else { break }
                
                await MainActor.run {
                    if !self.validateEventTapHealth() {
                        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                            print("[GlobalHotkeyManager] Health check failed, attempting to recover")
                        }
                        
                        if self.setupGlobalHotkey() {
                            if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
                                print("[GlobalHotkeyManager] Health check recovery successful")
                            }
                        } else {
                            print("[GlobalHotkeyManager] Health check recovery failed")
                            self.isInitialized = false
                        }
                    }
                }
            }
        }
    }
    
    deinit
    {
        initializationTask?.cancel()
        healthCheckTask?.cancel()
        cleanupEventTap()
        
        if UserDefaults.standard.bool(forKey: "enableDebugLogs") {
            print("[GlobalHotkeyManager] Deinitialized and cleaned up")
        }
    }
}


