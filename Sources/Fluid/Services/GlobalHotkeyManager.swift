import AppKit
import Foundation

private nonisolated enum HotkeyHoldModeType: Hashable {
    case transcription
    case promptMode
    case commandMode
    case rewriteMode
    case promptAssignment
}

private nonisolated enum ActivePrimaryShortcutPress: Equatable {
    case keyboard(UInt16)
    case mouse(Int)
}

private final nonisolated class HotkeyState: @unchecked Sendable {
    private let lock = NSLock()
    var isKeyPressed = false
    var isPromptModeKeyPressed = false
    var isCommandModeKeyPressed = false
    var isRewriteKeyPressed = false
    var isPromptAssignmentKeyPressed = false
    var pressedModifierKeyCodes: Set<UInt16> = []
    var modifierOnlyKeyDown = false
    var otherKeyPressedDuringModifier = false
    var modifierPressStartTime: Date?
    var pendingHoldModeStart: Task<Void, Never>?
    var pendingHoldModeType: HotkeyHoldModeType?
    var holdModeStartTriggeredTypes: Set<HotkeyHoldModeType> = []
    var pendingReleaseStopTasks: [HotkeyHoldModeType: Task<Void, Never>] = [:]
    var pendingReleaseStopTokens: [HotkeyHoldModeType: UUID] = [:]
    var automaticPressStartTimes: [HotkeyHoldModeType: Date] = [:]
    var automaticPressWasTargetActive: [HotkeyHoldModeType: Bool] = [:]
    var automaticPressStartedTypes: Set<HotkeyHoldModeType> = []
    var activePrimaryShortcutPress: ActivePrimaryShortcutPress?

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
    private var primaryShortcuts: [HotkeyShortcut]
    private var promptModeShortcut: HotkeyShortcut
    private var commandModeShortcut: HotkeyShortcut
    private var rewriteModeShortcut: HotkeyShortcut
    private var promptShortcutAssignments: [(selection: SettingsStore.DictationPromptSelection, shortcut: HotkeyShortcut)]
    private var promptModeShortcutEnabled: Bool
    private var commandModeShortcutEnabled: Bool
    private var rewriteModeShortcutEnabled: Bool
    private var startRecordingCallback: (() async -> Void)?
    private var dictationModeCallback: (() async -> Void)?
    private var stopAndProcessCallback: (() async -> Void)?
    private var promptModeCallback: (() async -> Void)?
    private var promptSelectionCallback: ((SettingsStore.DictationPromptSelection) async -> Void)?
    private var commandModeCallback: (() async -> Void)?
    private var rewriteModeCallback: (() async -> Void)?
    private var isDictateRecordingProvider: (() -> Bool)?
    private var isPromptModeRecordingProvider: (() -> Bool)?
    private var isCommandRecordingProvider: (() -> Bool)?
    private var isRewriteRecordingProvider: (() -> Bool)?
    private var isShortcutCaptureActiveProvider: (() -> Bool)?
    private var cancelCallback: (() -> Bool)? // Returns true if handled
    private var hotkeyMode: HotkeyActivationMode = SettingsStore.shared.hotkeyMode
    private let automaticTapThresholdSeconds: TimeInterval = 0.4

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
        let isTargetModeActive: () -> Bool
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

    private nonisolated var isPromptAssignmentKeyPressed: Bool {
        get { self.state.withLock { self.state.isPromptAssignmentKeyPressed } }
        set { self.state.withLock { self.state.isPromptAssignmentKeyPressed = newValue } }
    }

    private nonisolated var activePrimaryShortcutPress: ActivePrimaryShortcutPress? {
        get { self.state.withLock { self.state.activePrimaryShortcutPress } }
        set { self.state.withLock { self.state.activePrimaryShortcutPress = newValue } }
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

    private func cancelPendingReleaseStop(for type: HotkeyHoldModeType) {
        let task = self.state.withLock { () -> Task<Void, Never>? in
            _ = self.state.pendingReleaseStopTokens.removeValue(forKey: type)
            return self.state.pendingReleaseStopTasks.removeValue(forKey: type)
        }
        task?.cancel()
    }

    private func cancelPendingReleaseStops() {
        let tasks = self.state.withLock { () -> [Task<Void, Never>] in
            let tasks = Array(self.state.pendingReleaseStopTasks.values)
            self.state.pendingReleaseStopTasks.removeAll()
            self.state.pendingReleaseStopTokens.removeAll()
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
    }

    private func beginPendingReleaseStop(for type: HotkeyHoldModeType) -> UUID {
        let token = UUID()
        let task = self.state.withLock { () -> Task<Void, Never>? in
            self.state.pendingReleaseStopTokens[type] = token
            return self.state.pendingReleaseStopTasks.removeValue(forKey: type)
        }
        task?.cancel()
        return token
    }

    private func storePendingReleaseStopTask(_ task: Task<Void, Never>, for type: HotkeyHoldModeType, token: UUID) {
        let taskToCancel = self.state.withLock { () -> Task<Void, Never>? in
            guard self.state.pendingReleaseStopTokens[type] == token else { return task }
            let previousTask = self.state.pendingReleaseStopTasks[type]
            self.state.pendingReleaseStopTasks[type] = task
            return previousTask
        }
        taskToCancel?.cancel()
    }

    private func isPendingReleaseStopCurrent(for type: HotkeyHoldModeType, token: UUID) -> Bool {
        self.state.withLock {
            self.state.pendingReleaseStopTokens[type] == token
        }
    }

    private func clearPendingReleaseStop(for type: HotkeyHoldModeType, token: UUID) {
        self.state.withLock {
            guard self.state.pendingReleaseStopTokens[type] == token else { return }
            _ = self.state.pendingReleaseStopTokens.removeValue(forKey: type)
            _ = self.state.pendingReleaseStopTasks.removeValue(forKey: type)
        }
    }

    private func beginAutomaticPress(for type: HotkeyHoldModeType, wasTargetActive: Bool) {
        self.cancelPendingReleaseStop(for: type)
        self.state.withLock {
            self.state.automaticPressStartTimes[type] = Date()
            self.state.automaticPressWasTargetActive[type] = wasTargetActive
            _ = self.state.automaticPressStartedTypes.remove(type)
        }
    }

    private func markAutomaticPressStarted(for type: HotkeyHoldModeType) {
        self.state.withLock {
            _ = self.state.automaticPressStartedTypes.insert(type)
        }
    }

    private func clearHoldModeStartTriggered(for type: HotkeyHoldModeType) {
        self.state.withLock {
            _ = self.state.holdModeStartTriggeredTypes.remove(type)
        }
    }

    private func markHoldModeStartTriggered(for type: HotkeyHoldModeType) {
        self.state.withLock {
            _ = self.state.holdModeStartTriggeredTypes.insert(type)
        }
    }

    private func finishHoldModeStartTriggered(for type: HotkeyHoldModeType) -> Bool {
        self.state.withLock {
            self.state.holdModeStartTriggeredTypes.remove(type) != nil
        }
    }

    private func finishAutomaticPress(
        for type: HotkeyHoldModeType
    ) -> (duration: TimeInterval, wasTargetActive: Bool, started: Bool) {
        let now = Date()
        return self.state.withLock {
            let startTime = self.state.automaticPressStartTimes.removeValue(forKey: type) ?? now
            let wasTargetActive = self.state.automaticPressWasTargetActive.removeValue(forKey: type) ?? false
            let started = self.state.automaticPressStartedTypes.remove(type) != nil
            return (now.timeIntervalSince(startTime), wasTargetActive, started)
        }
    }

    private func clearAutomaticPressTracking() {
        self.cancelPendingReleaseStops()
        self.state.withLock {
            self.state.holdModeStartTriggeredTypes.removeAll()
            self.state.automaticPressStartTimes.removeAll()
            self.state.automaticPressWasTargetActive.removeAll()
            self.state.automaticPressStartedTypes.removeAll()
        }
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
        primaryShortcuts: [HotkeyShortcut],
        promptModeShortcut: HotkeyShortcut,
        commandModeShortcut: HotkeyShortcut,
        rewriteModeShortcut: HotkeyShortcut,
        promptShortcutAssignments: [(selection: SettingsStore.DictationPromptSelection, shortcut: HotkeyShortcut)] = [],
        promptModeShortcutEnabled: Bool,
        commandModeShortcutEnabled: Bool,
        rewriteModeShortcutEnabled: Bool,
        startRecordingCallback: (() async -> Void)? = nil,
        dictationModeCallback: (() async -> Void)? = nil,
        stopAndProcessCallback: (() async -> Void)? = nil,
        promptModeCallback: (() async -> Void)? = nil,
        promptSelectionCallback: ((SettingsStore.DictationPromptSelection) async -> Void)? = nil,
        commandModeCallback: (() async -> Void)? = nil,
        rewriteModeCallback: (() async -> Void)? = nil,
        isDictateRecordingProvider: (() -> Bool)? = nil,
        isPromptModeRecordingProvider: (() -> Bool)? = nil,
        isCommandRecordingProvider: (() -> Bool)? = nil,
        isRewriteRecordingProvider: (() -> Bool)? = nil,
        isShortcutCaptureActiveProvider: (() -> Bool)? = nil
    ) {
        self.asrService = asrService
        self.primaryShortcuts = primaryShortcuts
        self.promptModeShortcut = promptModeShortcut
        self.commandModeShortcut = commandModeShortcut
        self.rewriteModeShortcut = rewriteModeShortcut
        self.promptShortcutAssignments = promptShortcutAssignments
        self.promptModeShortcutEnabled = promptModeShortcutEnabled
        self.commandModeShortcutEnabled = commandModeShortcutEnabled
        self.rewriteModeShortcutEnabled = rewriteModeShortcutEnabled
        self.startRecordingCallback = startRecordingCallback
        self.dictationModeCallback = dictationModeCallback
        self.stopAndProcessCallback = stopAndProcessCallback
        self.promptModeCallback = promptModeCallback
        self.promptSelectionCallback = promptSelectionCallback
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

    func updatePrimaryShortcuts(_ newShortcuts: [HotkeyShortcut]) {
        self.primaryShortcuts = newShortcuts
        DebugLogger.shared.info("Updated transcription hotkeys", source: "GlobalHotkeyManager")
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

    func updatePromptShortcutAssignments(_ assignments: [(selection: SettingsStore.DictationPromptSelection, shortcut: HotkeyShortcut)]) {
        self.promptShortcutAssignments = assignments
        DebugLogger.shared.info("Updated prompt shortcut assignments", source: "GlobalHotkeyManager")
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
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

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
        self.clearPrimaryShortcutPressState()
    }

    private nonisolated func clearPrimaryShortcutPressState() {
        let task = self.state.withLock { () -> Task<Void, Never>? in
            guard self.state.activePrimaryShortcutPress != nil || self.state.isKeyPressed else { return nil }
            self.state.activePrimaryShortcutPress = nil
            self.state.isKeyPressed = false
            self.state.holdModeStartTriggeredTypes.remove(.transcription)
            self.state.automaticPressStartTimes.removeValue(forKey: .transcription)
            self.state.automaticPressWasTargetActive.removeValue(forKey: .transcription)
            self.state.automaticPressStartedTypes.remove(.transcription)
            _ = self.state.pendingReleaseStopTokens.removeValue(forKey: .transcription)
            return self.state.pendingReleaseStopTasks.removeValue(forKey: .transcription)
        }
        task?.cancel()
    }

    private func markOtherInputDuringModifierOnly() {
        guard self.modifierOnlyKeyDown else { return }
        self.otherKeyPressedDuringModifier = true
        if let pending = self.pendingHoldModeStart {
            pending.cancel()
            self.pendingHoldModeStart = nil
            self.pendingHoldModeType = nil
            DebugLogger.shared.info("Another input pressed - cancelled pending hold mode start", source: "GlobalHotkeyManager")
        }
    }

    private func mouseButton(from event: CGEvent) -> Int {
        Int(event.getIntegerValueField(.mouseEventButtonNumber))
    }

    private func beginPrimaryShortcutPress(_ press: ActivePrimaryShortcutPress) -> Bool {
        self.state.withLock {
            guard self.state.activePrimaryShortcutPress == nil, !self.state.isKeyPressed else {
                return false
            }
            self.state.activePrimaryShortcutPress = press
            return true
        }
    }

    private func finishPrimaryShortcutPress(_ press: ActivePrimaryShortcutPress) -> Bool {
        self.state.withLock {
            guard self.state.activePrimaryShortcutPress == press else {
                return false
            }
            self.state.activePrimaryShortcutPress = nil
            return true
        }
    }

    private func primaryModifierOnlyBehavior(for shortcut: HotkeyShortcut) -> ModifierOnlyShortcutBehavior {
        .init(
            shortcut: shortcut,
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
            },
            isTargetModeActive: { self.isDictateRecordingProvider?() ?? false }
        )
    }

    private func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if let tapRecoveryResult = self.handleTapDisableEvent(type: type, event: event) {
            return tapRecoveryResult
        }

        if self.isShortcutCaptureActiveProvider?() ?? false {
            self.resetModifierOnlyShortcutTracking()
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
            self.markOtherInputDuringModifierOnly()

            // Observe post-transcription edits (do not consume the event).
            Task {
                await PostTranscriptionEditTracker.shared.handleKeyDown(keyCode: keyCode, modifiers: eventModifiers)
            }

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

            if let assignment = self.promptShortcutAssignments.first(where: { $0.shortcut.matches(keyCode: keyCode, modifiers: eventModifiers) }) {
                switch self.hotkeyMode {
                case .hold:
                    if !self.isPromptAssignmentKeyPressed {
                        self.cancelPendingReleaseStop(for: .promptAssignment)
                        self.clearHoldModeStartTriggered(for: .promptAssignment)
                        self.isPromptAssignmentKeyPressed = true
                        DebugLogger.shared.info("Prompt shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                        self.triggerPromptSelection(assignment.selection)
                        self.markHoldModeStartTriggered(for: .promptAssignment)
                    }
                case .automatic:
                    if !self.isPromptAssignmentKeyPressed {
                        self.isPromptAssignmentKeyPressed = true
                        let isSameMode = self.asrService.isRunning && (self.isPromptModeRecordingProvider?() ?? false)
                        self.beginAutomaticPress(for: .promptAssignment, wasTargetActive: isSameMode)
                        if self.asrService.isRunning {
                            if isSameMode {
                                DebugLogger.shared.info("Prompt shortcut pressed (automatic, same mode) - waiting for release", source: "GlobalHotkeyManager")
                            } else {
                                DebugLogger.shared.info("Prompt shortcut pressed (automatic, switch mode)", source: "GlobalHotkeyManager")
                                self.triggerPromptSelection(assignment.selection)
                                self.markAutomaticPressStarted(for: .promptAssignment)
                            }
                        } else {
                            DebugLogger.shared.info("Prompt shortcut triggered (automatic) - starting", source: "GlobalHotkeyManager")
                            self.triggerPromptSelection(assignment.selection)
                            self.markAutomaticPressStarted(for: .promptAssignment)
                        }
                    }
                case .toggle:
                    if self.asrService.isRunning {
                        if self.isPromptModeRecordingProvider?() ?? false {
                            DebugLogger.shared.info("Prompt shortcut pressed in Prompt mode - stopping", source: "GlobalHotkeyManager")
                            self.stopRecordingIfNeeded()
                        } else {
                            DebugLogger.shared.info("Prompt shortcut pressed while recording - switching mode", source: "GlobalHotkeyManager")
                            self.triggerPromptSelection(assignment.selection)
                        }
                    } else {
                        DebugLogger.shared.info("Prompt shortcut triggered - starting", source: "GlobalHotkeyManager")
                        self.triggerPromptSelection(assignment.selection)
                    }
                }
                return nil
            }

            // Check prompt mode hotkey
            if self.handlePromptModeKeyDown(keyCode: keyCode, modifiers: eventModifiers) { return nil }

            // Check command mode hotkey first
            if self.commandModeShortcutEnabled, self.commandModeShortcut.matches(keyCode: keyCode, modifiers: eventModifiers) {
                switch self.hotkeyMode {
                case .hold:
                    // Press and hold: start on keyDown, stop on keyUp
                    if !self.isCommandModeKeyPressed {
                        self.cancelPendingReleaseStop(for: .commandMode)
                        self.clearHoldModeStartTriggered(for: .commandMode)
                        self.isCommandModeKeyPressed = true
                        DebugLogger.shared.info("Command mode shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                        self.triggerCommandMode()
                        self.markHoldModeStartTriggered(for: .commandMode)
                    }
                case .automatic:
                    if !self.isCommandModeKeyPressed {
                        self.isCommandModeKeyPressed = true
                        let isSameMode = self.asrService.isRunning && (self.isCommandRecordingProvider?() ?? false)
                        self.beginAutomaticPress(for: .commandMode, wasTargetActive: isSameMode)
                        if self.asrService.isRunning {
                            if isSameMode {
                                DebugLogger.shared.info("Command mode shortcut pressed (automatic, same mode) - waiting for release", source: "GlobalHotkeyManager")
                            } else {
                                DebugLogger.shared.info("Command mode shortcut pressed (automatic, switch mode)", source: "GlobalHotkeyManager")
                                self.triggerCommandMode()
                                self.markAutomaticPressStarted(for: .commandMode)
                            }
                        } else {
                            DebugLogger.shared.info("Command mode shortcut triggered (automatic) - starting", source: "GlobalHotkeyManager")
                            self.triggerCommandMode()
                            self.markAutomaticPressStarted(for: .commandMode)
                        }
                    }
                case .toggle:
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
                if self.rewriteModeShortcut.matches(keyCode: keyCode, modifiers: eventModifiers) {
                    switch self.hotkeyMode {
                    case .hold:
                        // Press and hold: start on keyDown, stop on keyUp
                        if !self.isRewriteKeyPressed {
                            self.cancelPendingReleaseStop(for: .rewriteMode)
                            self.clearHoldModeStartTriggered(for: .rewriteMode)
                            self.isRewriteKeyPressed = true
                            DebugLogger.shared.info("Rewrite mode shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                            self.triggerRewriteMode()
                            self.markHoldModeStartTriggered(for: .rewriteMode)
                        }
                    case .automatic:
                        if !self.isRewriteKeyPressed {
                            self.isRewriteKeyPressed = true
                            let isSameMode = self.asrService.isRunning && (self.isRewriteRecordingProvider?() ?? false)
                            self.beginAutomaticPress(for: .rewriteMode, wasTargetActive: isSameMode)
                            if self.asrService.isRunning {
                                if isSameMode {
                                    DebugLogger.shared.info("Rewrite mode shortcut pressed (automatic, same mode) - waiting for release", source: "GlobalHotkeyManager")
                                } else {
                                    DebugLogger.shared.info("Rewrite mode shortcut pressed (automatic, switch mode)", source: "GlobalHotkeyManager")
                                    self.triggerRewriteMode()
                                    self.markAutomaticPressStarted(for: .rewriteMode)
                                }
                            } else {
                                DebugLogger.shared.info("Rewrite mode shortcut triggered (automatic) - starting", source: "GlobalHotkeyManager")
                                self.triggerRewriteMode()
                                self.markAutomaticPressStarted(for: .rewriteMode)
                            }
                        }
                    case .toggle:
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

            // Then check transcription hotkeys
            if let shortcut = self.primaryShortcuts.first(where: { $0.matches(keyCode: keyCode, modifiers: eventModifiers) }) {
                guard self.beginPrimaryShortcutPress(.keyboard(shortcut.keyCode)) else { return nil }
                self.handlePrimaryDictationTriggerDown()
                return nil
            }

        case .keyUp:
            // Prompt mode key up (press and hold mode)
            if self.handlePromptModeKeyUp(keyCode: keyCode) { return nil }

            // Command mode key up
            // Note: Only check keyCode, not modifiers - user may release modifier before/with main key
            if self.commandModeShortcutEnabled, self.isCommandModeKeyPressed, keyCode == self.commandModeShortcut.keyCode {
                switch self.hotkeyMode {
                case .hold:
                    self.isCommandModeKeyPressed = false
                    _ = self.finishHoldModeStartTriggered(for: .commandMode)
                    DebugLogger.shared.info("Command mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                    self.stopRecordingAfterRelease(for: .commandMode, label: "Command mode")
                case .automatic:
                    self.isCommandModeKeyPressed = false
                    self.handleAutomaticKeyRelease(for: .commandMode, label: "Command mode")
                case .toggle:
                    break
                }
                return nil
            }

            // Rewrite mode key up
            // Note: Only check keyCode, not modifiers - user may release modifier before/with main key
            if self.rewriteModeShortcutEnabled, self.isRewriteKeyPressed, keyCode == self.rewriteModeShortcut.keyCode {
                switch self.hotkeyMode {
                case .hold:
                    self.isRewriteKeyPressed = false
                    _ = self.finishHoldModeStartTriggered(for: .rewriteMode)
                    DebugLogger.shared.info("Rewrite mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                    self.stopRecordingAfterRelease(for: .rewriteMode, label: "Rewrite mode")
                case .automatic:
                    self.isRewriteKeyPressed = false
                    self.handleAutomaticKeyRelease(for: .rewriteMode, label: "Rewrite mode")
                case .toggle:
                    break
                }
                return nil
            }

            // Prompt assignment key up
            // Note: Only check keyCode, not modifiers - user may release modifier before/with main key
            if self.isPromptAssignmentKeyPressed,
               let assignment = self.promptShortcutAssignments.first(where: { $0.shortcut.keyCode == keyCode })
            {
                _ = assignment
                switch self.hotkeyMode {
                case .hold:
                    self.isPromptAssignmentKeyPressed = false
                    _ = self.finishHoldModeStartTriggered(for: .promptAssignment)
                    DebugLogger.shared.info("Prompt shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
                    self.stopRecordingAfterRelease(for: .promptAssignment, label: "Prompt shortcut")
                case .automatic:
                    self.isPromptAssignmentKeyPressed = false
                    self.handleAutomaticKeyRelease(for: .promptAssignment, label: "Prompt shortcut")
                case .toggle:
                    break
                }
                return nil
            }

            // Transcription key up
            // Note: Only check keyCode, not modifiers - user may release modifier before/with main key
            if self.finishPrimaryShortcutPress(.keyboard(keyCode)) {
                self.handlePrimaryDictationTriggerUp()
                return nil
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            self.markOtherInputDuringModifierOnly()
            let mouseButton = self.mouseButton(from: event)
            if self.primaryShortcuts.contains(where: { $0.matchesMouse(button: mouseButton, modifiers: eventModifiers) }) {
                guard self.beginPrimaryShortcutPress(.mouse(mouseButton)) else { return nil }
                self.handlePrimaryDictationTriggerDown()
                return nil
            }

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let mouseButton = self.mouseButton(from: event)
            guard self.finishPrimaryShortcutPress(.mouse(mouseButton)) else { break }
            self.handlePrimaryDictationTriggerUp()
            return nil

        case .flagsChanged:
            if HotkeyShortcut.modifierFlag(forKeyCode: keyCode) != nil {
                self.pressedModifierKeyCodes = self.synchronizedPressedModifierKeyCodes(
                    changedKeyCode: keyCode,
                    modifiers: eventModifiers
                )
            }

            if self.handlePromptAssignmentFlagsChanged(keyCode: keyCode, modifiers: eventModifiers) { return nil }

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
                    },
                    isTargetModeActive: { self.isCommandRecordingProvider?() ?? false }
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
                    },
                    isTargetModeActive: { self.isRewriteRecordingProvider?() ?? false }
                ),
                keyCode: keyCode,
                modifiers: eventModifiers
            ) { return nil }

            for shortcut in self.primaryShortcuts where shortcut.isModifierOnlyShortcut {
                if self.handleModifierOnlyShortcutFlagsChanged(
                    behavior: self.primaryModifierOnlyBehavior(for: shortcut),
                    keyCode: keyCode,
                    modifiers: eventModifiers
                ) { return nil }
            }

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

    private func handleAutomaticKeyRelease(
        for type: HotkeyHoldModeType,
        label: String,
        onUnstartedTap: (() -> Void)? = nil
    ) {
        let press = self.finishAutomaticPress(for: type)
        let duration = String(format: "%.2f", press.duration)

        if press.duration < self.automaticTapThresholdSeconds {
            if press.wasTargetActive {
                DebugLogger.shared.info("\(label) tap (\(duration)s) - stopping", source: "GlobalHotkeyManager")
                self.stopRecordingIfNeeded()
            } else if press.started {
                DebugLogger.shared.info("\(label) tap (\(duration)s) - continuing", source: "GlobalHotkeyManager")
            } else {
                DebugLogger.shared.info("\(label) tap (\(duration)s) - toggling", source: "GlobalHotkeyManager")
                onUnstartedTap?()
            }
            return
        }

        if press.wasTargetActive || press.started {
            DebugLogger.shared.info("\(label) hold (\(duration)s) - stopping", source: "GlobalHotkeyManager")
            self.stopRecordingAfterRelease(for: type, label: label)
        } else {
            DebugLogger.shared.debug("\(label) hold (\(duration)s) ignored - no automatic start", source: "GlobalHotkeyManager")
        }
    }

    private func handlePrimaryDictationTriggerDown() {
        switch self.hotkeyMode {
        case .hold:
            if !self.isKeyPressed {
                self.cancelPendingReleaseStop(for: .transcription)
                self.clearHoldModeStartTriggered(for: .transcription)
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
                self.markHoldModeStartTriggered(for: .transcription)
            }
        case .automatic:
            if !self.isKeyPressed {
                self.isKeyPressed = true
                let isSameMode = self.asrService.isRunning && (self.isDictateRecordingProvider?() ?? false)
                self.beginAutomaticPress(for: .transcription, wasTargetActive: isSameMode)
                if self.asrService.isRunning {
                    DebugLogger.shared.info(
                        "Hotkey route | pressed=dictate | active=\(isSameMode ? "dictate" : "other") | asrRunning=true | action=\(isSameMode ? "release-stop" : "switch")",
                        source: "GlobalHotkeyManager"
                    )
                    if !isSameMode {
                        self.triggerDictationMode()
                        self.markAutomaticPressStarted(for: .transcription)
                    }
                } else {
                    DebugLogger.shared.info(
                        "Hotkey route | pressed=dictate | active=none | asrRunning=false | action=start",
                        source: "GlobalHotkeyManager"
                    )
                    self.triggerDictationMode()
                    self.markAutomaticPressStarted(for: .transcription)
                }
            }
        case .toggle:
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
    }

    private func handlePrimaryDictationTriggerUp() {
        switch self.hotkeyMode {
        case .hold:
            self.isKeyPressed = false
            _ = self.finishHoldModeStartTriggered(for: .transcription)
            self.stopRecordingAfterRelease(for: .transcription, label: "Transcription")
        case .automatic:
            self.isKeyPressed = false
            self.handleAutomaticKeyRelease(for: .transcription, label: "Transcription")
        case .toggle:
            break
        }
    }

    private func isRecordingTargetActive(for type: HotkeyHoldModeType) -> Bool {
        switch type {
        case .transcription:
            guard let provider = self.isDictateRecordingProvider else { return true }
            return provider()
        case .promptMode:
            guard let provider = self.isPromptModeRecordingProvider else { return true }
            return provider()
        case .commandMode:
            guard let provider = self.isCommandRecordingProvider else { return true }
            return provider()
        case .rewriteMode:
            guard let provider = self.isRewriteRecordingProvider else { return true }
            return provider()
        case .promptAssignment:
            guard let provider = self.isPromptModeRecordingProvider else { return true }
            return provider()
        }
    }

    private func stopRecordingAfterRelease(for type: HotkeyHoldModeType, label: String) {
        if self.asrService.isRunning {
            self.cancelPendingReleaseStop(for: type)
            self.stopRecordingIfNeeded()
            return
        }

        let token = self.beginPendingReleaseStop(for: type)
        DebugLogger.shared.debug("\(label) release stop deferred until recording starts", source: "GlobalHotkeyManager")

        let task = Task { @MainActor [weak self] in
            let maxAttempts = 60
            let retryDelayNanoseconds: UInt64 = 50_000_000

            for _ in 0..<maxAttempts {
                guard !Task.isCancelled else { return }
                guard let self = self else { return }
                guard self.isPendingReleaseStopCurrent(for: type, token: token) else { return }

                if self.asrService.isRunning {
                    guard self.isRecordingTargetActive(for: type) else {
                        DebugLogger.shared.debug("\(label) deferred stop skipped - active mode changed", source: "GlobalHotkeyManager")
                        self.clearPendingReleaseStop(for: type, token: token)
                        return
                    }

                    DebugLogger.shared.info("\(label) deferred stop after recording start", source: "GlobalHotkeyManager")
                    self.clearPendingReleaseStop(for: type, token: token)
                    await self.stopRecordingInternal()
                    return
                }

                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }

            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            guard self.isPendingReleaseStopCurrent(for: type, token: token) else { return }
            DebugLogger.shared.warning("\(label) deferred stop expired before recording started", source: "GlobalHotkeyManager")
            self.clearPendingReleaseStop(for: type, token: token)
        }

        self.storePendingReleaseStopTask(task, for: type, token: token)
    }

    private func label(for type: HotkeyHoldModeType) -> String {
        switch type {
        case .transcription:
            return "Transcription"
        case .promptMode:
            return "Prompt mode"
        case .commandMode:
            return "Command mode"
        case .rewriteMode:
            return "Rewrite mode"
        case .promptAssignment:
            return "Prompt shortcut"
        }
    }

    private func scheduleModifierOnlyStart(for behavior: ModifierOnlyShortcutBehavior) {
        guard self.hotkeyMode != .toggle, !behavior.isModeKeyPressed() else { return }

        self.cancelPendingReleaseStop(for: behavior.holdModeType)
        self.clearHoldModeStartTriggered(for: behavior.holdModeType)
        behavior.setModeKeyPressed(true)
        self.pendingHoldModeStart?.cancel()
        self.pendingHoldModeType = behavior.holdModeType

        let wasTargetActive = self.asrService.isRunning && behavior.isTargetModeActive()
        if self.hotkeyMode == .automatic {
            self.beginAutomaticPress(for: behavior.holdModeType, wasTargetActive: wasTargetActive)
        }

        self.pendingHoldModeStart = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self = self, !Task.isCancelled else { return }
            guard behavior.isModeKeyPressed(), !self.otherKeyPressedDuringModifier else {
                DebugLogger.shared.debug(behavior.holdStartCancelledMessage, source: "GlobalHotkeyManager")
                return
            }
            guard self.hotkeyMode != .automatic || !wasTargetActive else { return }
            DebugLogger.shared.info(behavior.holdStartMessage, source: "GlobalHotkeyManager")
            if self.hotkeyMode == .hold {
                self.markHoldModeStartTriggered(for: behavior.holdModeType)
            }
            behavior.onHoldStart()
            if self.hotkeyMode == .automatic {
                self.markAutomaticPressStarted(for: behavior.holdModeType)
            }
        }
    }

    private func finishModifierOnlyPress(
        for behavior: ModifierOnlyShortcutBehavior,
        wasCleanPress: Bool
    ) {
        self.pendingHoldModeStart?.cancel()
        self.pendingHoldModeStart = nil
        self.pendingHoldModeType = nil

        switch self.hotkeyMode {
        case .hold:
            if behavior.isModeKeyPressed() {
                behavior.setModeKeyPressed(false)
                let didStart = self.finishHoldModeStartTriggered(for: behavior.holdModeType)
                if self.asrService.isRunning || didStart {
                    DebugLogger.shared.info(behavior.holdReleaseMessage, source: "GlobalHotkeyManager")
                    self.stopRecordingAfterRelease(for: behavior.holdModeType, label: self.label(for: behavior.holdModeType))
                }
            }
        case .automatic:
            if behavior.isModeKeyPressed() {
                behavior.setModeKeyPressed(false)
            }
            if wasCleanPress {
                self.handleAutomaticKeyRelease(
                    for: behavior.holdModeType,
                    label: self.label(for: behavior.holdModeType),
                    onUnstartedTap: behavior.onToggleRelease
                )
            } else {
                let press = self.finishAutomaticPress(for: behavior.holdModeType)
                if press.started {
                    DebugLogger.shared.info("\(self.label(for: behavior.holdModeType)) modifier released after combo - stopping automatic start", source: "GlobalHotkeyManager")
                    self.stopRecordingAfterRelease(for: behavior.holdModeType, label: self.label(for: behavior.holdModeType))
                } else {
                    DebugLogger.shared.debug(behavior.toggleIgnoredMessage, source: "GlobalHotkeyManager")
                }
            }
        case .toggle:
            if wasCleanPress {
                behavior.onToggleRelease()
            } else {
                DebugLogger.shared.debug(behavior.toggleIgnoredMessage, source: "GlobalHotkeyManager")
            }
        }
    }

    func resetModifierOnlyShortcutTracking(reason: ModifierTrackingResetReason = .shortcutCapture) {
        let shouldStopActiveHold = self.hotkeyMode != .toggle
            && self.asrService.isRunning
            && (self.isKeyPressed || self.isPromptModeKeyPressed || self.isCommandModeKeyPressed || self.isRewriteKeyPressed || self.isPromptAssignmentKeyPressed)

        self.pressedModifierKeyCodes = []
        self.modifierOnlyKeyDown = false
        self.otherKeyPressedDuringModifier = false
        self.modifierPressStartTime = nil
        self.pendingHoldModeStart?.cancel()
        self.pendingHoldModeStart = nil
        self.pendingHoldModeType = nil
        self.clearAutomaticPressTracking()
        self.isKeyPressed = false
        self.isPromptModeKeyPressed = false
        self.isCommandModeKeyPressed = false
        self.isRewriteKeyPressed = false
        self.isPromptAssignmentKeyPressed = false
        self.activePrimaryShortcutPress = nil

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
        guard self.promptModeShortcutEnabled, self.promptModeShortcut.matches(keyCode: keyCode, modifiers: modifiers) else { return false }
        switch self.hotkeyMode {
        case .hold:
            if !self.isPromptModeKeyPressed {
                self.cancelPendingReleaseStop(for: .promptMode)
                self.clearHoldModeStartTriggered(for: .promptMode)
                self.isPromptModeKeyPressed = true
                DebugLogger.shared.info("Prompt mode shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                self.triggerPromptMode()
                self.markHoldModeStartTriggered(for: .promptMode)
            }
        case .automatic:
            if !self.isPromptModeKeyPressed {
                self.isPromptModeKeyPressed = true
                let isSameMode = self.asrService.isRunning && (self.isPromptModeRecordingProvider?() ?? false)
                self.beginAutomaticPress(for: .promptMode, wasTargetActive: isSameMode)
                if self.asrService.isRunning {
                    if isSameMode {
                        DebugLogger.shared.info("Prompt mode shortcut pressed (automatic, same mode) - waiting for release", source: "GlobalHotkeyManager")
                    } else {
                        DebugLogger.shared.info("Prompt mode shortcut pressed (automatic, switch mode)", source: "GlobalHotkeyManager")
                        self.triggerPromptMode()
                        self.markAutomaticPressStarted(for: .promptMode)
                    }
                } else {
                    DebugLogger.shared.info("Prompt mode shortcut triggered (automatic) - starting", source: "GlobalHotkeyManager")
                    self.triggerPromptMode()
                    self.markAutomaticPressStarted(for: .promptMode)
                }
            }
        case .toggle:
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
        guard self.promptModeShortcutEnabled,
              self.isPromptModeKeyPressed, keyCode == self.promptModeShortcut.keyCode else { return false }
        switch self.hotkeyMode {
        case .hold:
            self.isPromptModeKeyPressed = false
            _ = self.finishHoldModeStartTriggered(for: .promptMode)
            DebugLogger.shared.info("Prompt mode shortcut released (hold mode) - stopping", source: "GlobalHotkeyManager")
            self.stopRecordingAfterRelease(for: .promptMode, label: "Prompt mode")
        case .automatic:
            self.isPromptModeKeyPressed = false
            self.handleAutomaticKeyRelease(for: .promptMode, label: "Prompt mode")
        case .toggle:
            break
        }
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
                },
                isTargetModeActive: { self.isPromptModeRecordingProvider?() ?? false }
            ),
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    private func handlePromptAssignmentFlagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        for assignment in self.promptShortcutAssignments where assignment.shortcut.isModifierOnlyShortcut {
            let handled = self.handleModifierOnlyShortcutFlagsChanged(
                behavior: .init(
                    shortcut: assignment.shortcut,
                    isEnabled: true,
                    holdModeType: .promptMode,
                    holdStartCancelledMessage: "Prompt shortcut hold start cancelled - key combo detected",
                    holdStartMessage: "Prompt shortcut modifier held (hold mode) - starting after delay",
                    holdReleaseMessage: "Prompt shortcut modifier released (hold mode) - stopping",
                    toggleIgnoredMessage: "Prompt shortcut modifier released but another key was pressed - ignoring",
                    isModeKeyPressed: { self.isPromptModeKeyPressed },
                    setModeKeyPressed: { self.isPromptModeKeyPressed = $0 },
                    onHoldStart: { self.triggerPromptSelection(assignment.selection) },
                    onToggleRelease: {
                        if self.asrService.isRunning {
                            if self.isPromptModeRecordingProvider?() ?? false {
                                DebugLogger.shared.info("Prompt shortcut modifier released (toggle, same mode) - stopping", source: "GlobalHotkeyManager")
                                self.stopRecordingIfNeeded()
                            } else {
                                DebugLogger.shared.info("Prompt shortcut modifier released (toggle, switch mode) - switching", source: "GlobalHotkeyManager")
                                self.triggerPromptSelection(assignment.selection)
                            }
                        } else {
                            DebugLogger.shared.info("Prompt shortcut modifier released (toggle) - starting", source: "GlobalHotkeyManager")
                            self.triggerPromptSelection(assignment.selection)
                        }
                    },
                    isTargetModeActive: { self.isPromptModeRecordingProvider?() ?? false }
                ),
                keyCode: keyCode,
                modifiers: modifiers
            )
            if handled {
                return true
            }
        }

        return false
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

                self.scheduleModifierOnlyStart(for: behavior)
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

            self.finishModifierOnlyPress(for: behavior, wasCleanPress: wasCleanPress)
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

            self.scheduleModifierOnlyStart(for: behavior)
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

        self.finishModifierOnlyPress(for: behavior, wasCleanPress: wasCleanPress)
        return true
    }

    private func triggerPromptMode() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard self.canTriggerRecordingAction("Prompt mode hotkey") else { return }
            DebugLogger.shared.info("Prompt mode hotkey triggered", source: "GlobalHotkeyManager")
            await self.promptModeCallback?()
        }
    }

    private func triggerPromptSelection(_ selection: SettingsStore.DictationPromptSelection) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard self.canTriggerRecordingAction("Prompt selection hotkey") else { return }
            DebugLogger.shared.info("Prompt selection hotkey triggered", source: "GlobalHotkeyManager")
            await self.promptSelectionCallback?(selection)
        }
    }

    private func triggerCommandMode() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard self.canTriggerRecordingAction("Command mode hotkey") else { return }
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
            guard self.canTriggerRecordingAction("Rewrite mode hotkey") else { return }
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
            guard self.canTriggerRecordingAction("Dictate mode hotkey") else { return }
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

    func setHotkeyMode(_ mode: HotkeyActivationMode) {
        let shouldStopActivePress = self.hotkeyMode != .toggle
            && self.asrService.isRunning
            && (self.isKeyPressed || self.isPromptModeKeyPressed || self.isCommandModeKeyPressed || self.isRewriteKeyPressed || self.isPromptAssignmentKeyPressed)

        self.hotkeyMode = mode
        self.pendingHoldModeStart?.cancel()
        self.pendingHoldModeStart = nil
        self.pendingHoldModeType = nil
        self.clearAutomaticPressTracking()
        self.isKeyPressed = false
        self.isPromptModeKeyPressed = false
        self.isCommandModeKeyPressed = false
        self.isRewriteKeyPressed = false
        self.isPromptAssignmentKeyPressed = false
        self.activePrimaryShortcutPress = nil

        if shouldStopActivePress {
            self.stopRecordingIfNeeded()
        }
        DebugLogger.shared.info("Hotkey activation mode set to \(mode.displayName)", source: "GlobalHotkeyManager")
    }

    func enablePressAndHoldMode(_ enable: Bool) {
        self.setHotkeyMode(enable ? .hold : .toggle)
    }

    private func canTriggerRecordingAction(_ label: String) -> Bool {
        guard !self.isProcessingStop else {
            DebugLogger.shared.debug("Ignoring \(label) - stop already processing", source: "GlobalHotkeyManager")
            return false
        }
        return true
    }

    private func toggleRecording() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Prevent new operations while stop is processing
            guard self.canTriggerRecordingAction("toggle") else { return }

            if self.asrService.isRunning {
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
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Prevent starting while stop is processing
            guard self.canTriggerRecordingAction("start") else { return }

            if !self.asrService.isRunning {
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
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            if self.isProcessingStop {
                DebugLogger.shared.debug("Ignoring stop - already processing", source: "GlobalHotkeyManager")
                return
            }

            guard self.asrService.isRunning else {
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
