import AppKit
import Foundation

nonisolated enum HotkeyHoldModeType: Hashable {
    case transcription
    case promptMode
    case commandMode
    case rewriteMode
    case promptAssignment
}

private nonisolated enum ActivePrimaryShortcutPress: Equatable {
    case keyboard(HotkeyShortcut)
    case mouse(HotkeyShortcut)

    var shortcut: HotkeyShortcut {
        switch self {
        case let .keyboard(shortcut), let .mouse(shortcut): return shortcut
        }
    }

    var keyboardKeyCode: UInt16? {
        guard case let .keyboard(shortcut) = self else { return nil }
        return shortcut.keyCode
    }

    var mouseButton: Int? {
        guard case let .mouse(shortcut) = self else { return nil }
        return shortcut.mouseButton
    }
}

/// Input timing only: never changes shortcut routing or retains a keyboard event.
struct HotkeyInputTiming {
    let receivedAt: TimeInterval
    let eventTimestamp: UInt64
    let eventType: UInt32

    let receivedTimestamp: UInt64

    /// Quartz event timestamps and DispatchTime uptime are nanoseconds since boot.
    /// Keep this clock separate from the ProcessInfo timestamp used by the pipeline.
    var deliveryAgeMs: Double? {
        guard self.eventTimestamp > 0, self.receivedTimestamp >= self.eventTimestamp else { return nil }
        return Double(self.receivedTimestamp - self.eventTimestamp) / 1_000_000
    }
}

/// Snapshot of the modifier-only tracking state fed into `ModifierOnlyShortcutFlagsDecision`.
struct ModifierOnlyShortcutTrackingState: Equatable {
    /// Currently-pressed modifier key codes (output of `synchronizedPressedModifierKeyCodes`).
    let pressedModifierKeyCodes: Set<UInt16>
    /// The currently-active modifier-only mode, if any.
    let activeModifierOnlyType: HotkeyHoldModeType?
    /// The exact shortcut that owns the active modifier-only press.
    let activeModifierOnlyShortcut: HotkeyShortcut?
    /// Whether a non-configured key was pressed during the active modifier-only press.
    let otherKeyPressedDuringModifier: Bool
    /// Snapshot of the behavior's mode-key-pressed flag.
    let isModeKeyPressed: Bool
}

/// Pure, side-effect-free decision describing how a modifier-only shortcut responds to a single
/// `flagsChanged` event. Extracted from `GlobalHotkeyManager.handleModifierOnlyShortcutFlagsChanged`
/// so the modifier-only start/finish state machine is unit-testable without the global event tap.
struct ModifierOnlyShortcutFlagsDecision: Equatable {
    enum Outcome: Equatable {
        /// The event neither starts nor finishes the press.
        case ignore
        /// The configured modifier was pressed: arm the modifier-only press.
        case start
        /// The configured modifier was released: finish the press; a clean tap only when
        /// `wasCleanPress` is true.
        case finish(wasCleanPress: Bool)
    }

    let outcome: Outcome
    /// True when an extra modifier was pressed during an active press this event; the caller logs
    /// and marks the press interrupted.
    let markInterrupted: Bool
    /// Value `activeModifierOnlyType` should hold after this event.
    let activeModifierOnlyType: HotkeyHoldModeType?
    /// Shortcut that should own the active modifier-only press after this event.
    let activeModifierOnlyShortcut: HotkeyShortcut?
    /// Value `otherKeyPressedDuringModifier` should hold after this event.
    let otherKeyPressedDuringModifier: Bool

    /// Mirrors the decision logic of `handleModifierOnlyShortcutFlagsChanged`. Branch 1 handles
    /// shortcuts that carry explicit modifier key codes (e.g. a captured Left Option); branch 2
    /// handles the flag-only form.
    static func evaluate(
        shortcut: HotkeyShortcut,
        holdModeType: HotkeyHoldModeType,
        isEnabled: Bool,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        state: ModifierOnlyShortcutTrackingState
    ) -> ModifierOnlyShortcutFlagsDecision {
        let pressedModifierKeyCodes = state.pressedModifierKeyCodes
        let activeModifierOnlyType = state.activeModifierOnlyType
        let activeModifierOnlyShortcut = state.activeModifierOnlyShortcut
        let otherKeyPressedDuringModifier = state.otherKeyPressedDuringModifier
        let isModeKeyPressed = state.isModeKeyPressed

        guard isEnabled, shortcut.isModifierOnlyShortcut else {
            return .init(
                outcome: .ignore,
                markInterrupted: false,
                activeModifierOnlyType: activeModifierOnlyType,
                activeModifierOnlyShortcut: activeModifierOnlyShortcut,
                otherKeyPressedDuringModifier: otherKeyPressedDuringModifier
            )
        }

        let relevantModifiers = modifiers.intersection(HotkeyShortcut.relevantModifierMask)
        let expectedModifierKeyCodes = shortcut.normalizedModifierKeyCodes

        if !expectedModifierKeyCodes.isEmpty {
            let pressedKeyCodes = HotkeyShortcut.normalizedModifierKeyCodes(from: Array(pressedModifierKeyCodes))
            // Only arm on the FIRST press of the configured modifier itself. The `activeModifierOnlyType == nil`
            // precondition prevents a mid-press re-arm: without it, releasing an unrelated modifier (e.g. Shift)
            // or pressing a sibling modifier while the configured modifier is held can shrink `pressedModifierKeyCodes`
            // back to the expected set and re-enter this block, erasing `otherKeyPressedDuringModifier` so the
            // subsequent release reads as a clean tap and falsely starts recording (#688).
            if activeModifierOnlyType == nil,
               pressedKeyCodes == expectedModifierKeyCodes,
               relevantModifiers == shortcut.expectedModifierFlags,
               expectedModifierKeyCodes.contains(keyCode)
            {
                return .init(
                    outcome: .start,
                    markInterrupted: false,
                    activeModifierOnlyType: holdModeType,
                    activeModifierOnlyShortcut: shortcut,
                    otherKeyPressedDuringModifier: false
                )
            }

            let isActiveModifierOnlyPress = activeModifierOnlyType == holdModeType && activeModifierOnlyShortcut == shortcut
            let isLegacyModePress = activeModifierOnlyShortcut == nil && isModeKeyPressed
            var markInterrupted = false
            if isActiveModifierOnlyPress || isLegacyModePress {
                let extraModifierKeyCodes = pressedKeyCodes.filter { !expectedModifierKeyCodes.contains($0) }
                markInterrupted = !extraModifierKeyCodes.isEmpty
            }

            guard isActiveModifierOnlyPress || isLegacyModePress,
                  expectedModifierKeyCodes.contains(keyCode),
                  !pressedKeyCodes.contains(keyCode)
            else {
                return .init(
                    outcome: .ignore,
                    markInterrupted: markInterrupted,
                    activeModifierOnlyType: activeModifierOnlyType,
                    activeModifierOnlyShortcut: activeModifierOnlyShortcut,
                    otherKeyPressedDuringModifier: markInterrupted ? true : otherKeyPressedDuringModifier
                )
            }

            let wasCleanPress = !(markInterrupted || otherKeyPressedDuringModifier)
            return .init(
                outcome: .finish(wasCleanPress: wasCleanPress),
                markInterrupted: markInterrupted,
                activeModifierOnlyType: nil,
                activeModifierOnlyShortcut: nil,
                otherKeyPressedDuringModifier: false
            )
        }

        guard let expectedPressedModifiers = shortcut.expectedModifierFlags,
              let triggerFlag = shortcut.modifierTriggerFlag
        else {
            return .init(
                outcome: .ignore,
                markInterrupted: false,
                activeModifierOnlyType: activeModifierOnlyType,
                activeModifierOnlyShortcut: activeModifierOnlyShortcut,
                otherKeyPressedDuringModifier: otherKeyPressedDuringModifier
            )
        }

        // Only arm on the FIRST press of a modifier that belongs to the shortcut. The
        // `activeModifierOnlyType == nil` precondition prevents a mid-press re-arm (same #688 class
        // as branch 1): a sibling-side modifier whose flag is in `expectedPressedModifiers` would
        // otherwise re-enter `.start` and erase `otherKeyPressedDuringModifier`. Matching the
        // modifier flag (not the literal key code) preserves the original side-agnostic start, so a
        // Left-Option-stored shortcut still arms on Right Option.
        if activeModifierOnlyType == nil,
           relevantModifiers == expectedPressedModifiers,
           let changedModifierFlag = HotkeyShortcut.modifierFlag(forKeyCode: keyCode),
           expectedPressedModifiers.contains(changedModifierFlag)
        {
            return .init(
                outcome: .start,
                markInterrupted: false,
                activeModifierOnlyType: holdModeType,
                activeModifierOnlyShortcut: shortcut,
                otherKeyPressedDuringModifier: false
            )
        }

        let isActiveModifierOnlyPress = activeModifierOnlyType == holdModeType && activeModifierOnlyShortcut == shortcut
        let isLegacyModePress = activeModifierOnlyShortcut == nil && isModeKeyPressed
        var markInterrupted = false
        if isActiveModifierOnlyPress || isLegacyModePress {
            let unexpectedModifiers = relevantModifiers.subtracting(expectedPressedModifiers)
            markInterrupted = !unexpectedModifiers.isEmpty
        }

        guard isActiveModifierOnlyPress || isLegacyModePress,
              HotkeyShortcut.modifierFlag(forKeyCode: keyCode) == triggerFlag,
              !relevantModifiers.contains(triggerFlag)
        else {
            return .init(
                outcome: .ignore,
                markInterrupted: markInterrupted,
                activeModifierOnlyType: activeModifierOnlyType,
                activeModifierOnlyShortcut: activeModifierOnlyShortcut,
                otherKeyPressedDuringModifier: markInterrupted ? true : otherKeyPressedDuringModifier
            )
        }

        let wasCleanPress = !(markInterrupted || otherKeyPressedDuringModifier)
        return .init(
            outcome: .finish(wasCleanPress: wasCleanPress),
            markInterrupted: markInterrupted,
            activeModifierOnlyType: nil,
            activeModifierOnlyShortcut: nil,
            otherKeyPressedDuringModifier: false
        )
    }
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
    var activeModifierOnlyType: HotkeyHoldModeType?
    var activeModifierOnlyShortcut: HotkeyShortcut?
    var otherKeyPressedDuringModifier = false
    var modifierPressStartTime: Date?
    var holdModeStartTriggeredTypes: Set<HotkeyHoldModeType> = []
    var pendingReleaseStopTasks: [HotkeyHoldModeType: Task<Void, Never>] = [:]
    var pendingReleaseStopTokens: [HotkeyHoldModeType: UUID] = [:]
    var automaticPressStartTimes: [HotkeyHoldModeType: Date] = [:]
    var automaticPressWasTargetActive: [HotkeyHoldModeType: Bool] = [:]
    var automaticPressStartedTypes: Set<HotkeyHoldModeType> = []
    var activePrimaryShortcutPress: ActivePrimaryShortcutPress?
    var consumedPasteMouseButton: Int?

    func withLock<T>(_ block: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return block()
    }
}

@MainActor
final class GlobalHotkeyManager: NSObject {
    enum CancelHandlingResult {
        case unhandled
        case dismissedOverlay
        case cancelled
    }

    private nonisolated(unsafe) var state = HotkeyState()
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    /// Keyboard tap events are serviced here, not on the main run loop, so main-thread
    /// work after a paste never holds the synthetic Cmd+V (or any keystroke) in our tap.
    private nonisolated(unsafe) var keyboardTapRunLoop: CFRunLoop?
    private nonisolated(unsafe) var keyboardTapThread: Thread?
    private nonisolated(unsafe) var mouseObserverTap: CFMachPort?
    private nonisolated(unsafe) var mouseObserverSource: CFRunLoopSource?
    private nonisolated(unsafe) var mouseShortcutTap: CFMachPort?
    private nonisolated(unsafe) var mouseShortcutSource: CFRunLoopSource?
    private nonisolated(unsafe) var monitoredMouseButtons: Set<Int> = []
    private let asrService: ASRService
    private var recordingActionRevisions: [HotkeyHoldModeType: UInt64] = [:]
    private var pendingRecordingActionCounts: [HotkeyHoldModeType: Int] = [:]
    private var activeRecordingActionShortcuts: [HotkeyHoldModeType: HotkeyShortcut] = [:]
    private var pendingRecordingActions: [HotkeyHoldModeType: Task<Void, Never>] = [:]
    private var primaryShortcuts: [HotkeyShortcut]
    private var promptModeShortcut: HotkeyShortcut
    private var commandModeShortcut: HotkeyShortcut?
    private var rewriteModeShortcut: HotkeyShortcut
    private var promptShortcutAssignments: [(selection: SettingsStore.DictationPromptSelection, shortcut: HotkeyShortcut)]
    private var promptModeShortcutEnabled: Bool
    private var commandModeShortcutEnabled: Bool
    private var rewriteModeShortcutEnabled: Bool
    private var startRecordingCallback: (() async -> Void)?
    private var dictationModeCallback: (() async -> Void)?
    private var stopAndProcessCallback: ((TimeInterval?) async -> Void)?
    private var promptModeCallback: (() async -> Void)?
    private var promptSelectionCallback: ((SettingsStore.DictationPromptSelection) async -> Void)?
    private var commandModeCallback: (() async -> Void)?
    private var rewriteModeCallback: (() async -> Void)?
    private var isDictateRecordingProvider: (() -> Bool)?
    private var isPromptModeRecordingProvider: (() -> Bool)?
    private var isCommandRecordingProvider: (() -> Bool)?
    private var isRewriteRecordingProvider: (() -> Bool)?
    private var isShortcutCaptureActiveProvider: (() -> Bool)?
    private var shortcutCaptureHandler: ((NSEvent) -> NSEvent?)?
    private var cancelCallback: (() -> CancelHandlingResult)?
    private var pasteLastTranscriptionCallback: (() -> Void)?
    private var hotkeyMode: HotkeyActivationMode = SettingsStore.shared.hotkeyMode
    private let automaticTapThresholdSeconds: TimeInterval = 0.4
    private var holdToMuteKeyState = HoldToMuteKeyState()
    let holdToMuteSpaceTap = HoldToMuteSpaceTap()
    private var muteRecordingGeneration: UInt64?
    private var muteReleaseRecoveryTask: Task<Void, Never>?
    // Event-replay tests opt out of consulting the real keyboard.
    var holdToMuteChecksPhysicalKeyState = true
    private var currentInputTiming: HotkeyInputTiming?
    private var modifierPressReceivedAt: TimeInterval?
    private var currentStopPressReceivedAt: TimeInterval?
    private var activePromptAssignmentPress: (selection: SettingsStore.DictationPromptSelection, shortcut: HotkeyShortcut)?

    private struct ModifierOnlyShortcutBehavior {
        let shortcut: HotkeyShortcut
        let isEnabled: Bool
        let holdModeType: HotkeyHoldModeType
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
        case cancel
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

    private nonisolated var activeModifierOnlyType: HotkeyHoldModeType? {
        get { self.state.withLock { self.state.activeModifierOnlyType } }
        set { self.state.withLock { self.state.activeModifierOnlyType = newValue } }
    }

    private nonisolated var activeModifierOnlyShortcut: HotkeyShortcut? {
        get { self.state.withLock { self.state.activeModifierOnlyShortcut } }
        set { self.state.withLock { self.state.activeModifierOnlyShortcut = newValue } }
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
    private var activeShortcutLogScheduled = false

    init(
        asrService: ASRService,
        primaryShortcuts: [HotkeyShortcut],
        promptModeShortcut: HotkeyShortcut,
        commandModeShortcut: HotkeyShortcut?,
        rewriteModeShortcut: HotkeyShortcut,
        promptShortcutAssignments: [(selection: SettingsStore.DictationPromptSelection, shortcut: HotkeyShortcut)] = [],
        promptModeShortcutEnabled: Bool,
        commandModeShortcutEnabled: Bool,
        rewriteModeShortcutEnabled: Bool,
        startRecordingCallback: (() async -> Void)? = nil,
        dictationModeCallback: (() async -> Void)? = nil,
        stopAndProcessCallback: ((TimeInterval?) async -> Void)? = nil,
        promptModeCallback: (() async -> Void)? = nil,
        promptSelectionCallback: ((SettingsStore.DictationPromptSelection) async -> Void)? = nil,
        commandModeCallback: (() async -> Void)? = nil,
        rewriteModeCallback: (() async -> Void)? = nil,
        isDictateRecordingProvider: (() -> Bool)? = nil,
        isPromptModeRecordingProvider: (() -> Bool)? = nil,
        isCommandRecordingProvider: (() -> Bool)? = nil,
        isRewriteRecordingProvider: (() -> Bool)? = nil,
        isShortcutCaptureActiveProvider: (() -> Bool)? = nil,
        shortcutCaptureHandler: ((NSEvent) -> NSEvent?)? = nil
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
        self.shortcutCaptureHandler = shortcutCaptureHandler
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.holdSpaceSettingChanged),
            name: .init("HoldSpaceToMuteChanged"),
            object: nil
        )

        self.initializeWithDelay()
    }

    private func initializeWithDelay() {
        DebugLogger.shared.debug("Starting delayed initialization...", source: "GlobalHotkeyManager")

        self.initializationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 second delay
            } catch {
                return
            }

            await MainActor.run { [weak self] in
                self?.setupGlobalHotkeyWithRetry()
            }
        }
    }

    func setStopAndProcessCallback(_ callback: @escaping (TimeInterval?) async -> Void) {
        self.stopAndProcessCallback = callback
    }

    func setCommandModeCallback(_ callback: @escaping () async -> Void) {
        self.commandModeCallback = callback
    }

    func updatePrimaryShortcuts(_ newShortcuts: [HotkeyShortcut]) {
        let ownedShortcut = self.activePrimaryShortcutPress?.shortcut
            ?? (self.activeModifierOnlyType == .transcription ? self.activeModifierOnlyShortcut : nil)
            ?? self.activeRecordingActionShortcuts[.transcription]
        if newShortcuts != self.primaryShortcuts,
           ownedShortcut.map({ !newShortcuts.contains($0) })
           ?? newShortcuts.isEmpty
        { self.discardShortcutPress(for: .transcription) }
        self.primaryShortcuts = newShortcuts
        DebugLogger.shared.info("Updated transcription hotkeys", source: "GlobalHotkeyManager")
        self.refreshMouseShortcutTapIfNeeded()
        self.scheduleActiveShortcutLog(reason: "shortcuts updated")
    }

    func refreshMouseShortcutTapIfNeeded() {
        guard self.eventTap != nil else { return }
        let mouseButtons = self.configuredMouseButtons()
        guard mouseButtons != self.monitoredMouseButtons else { return }
        self.setupMouseShortcutTap(mouseButtons: mouseButtons, preservePrimaryPress: true)
    }

    func updateCommandModeShortcut(_ newShortcut: HotkeyShortcut?) {
        if newShortcut != self.commandModeShortcut { self.discardShortcutPress(for: .commandMode) }
        self.commandModeShortcut = newShortcut
        DebugLogger.shared.info("Updated command mode hotkey", source: "GlobalHotkeyManager")
        self.scheduleActiveShortcutLog(reason: "shortcuts updated")
    }

    func setRewriteModeCallback(_ callback: @escaping () async -> Void) {
        self.rewriteModeCallback = callback
    }

    func updateRewriteModeShortcut(_ newShortcut: HotkeyShortcut) {
        if newShortcut != self.rewriteModeShortcut { self.discardShortcutPress(for: .rewriteMode) }
        self.rewriteModeShortcut = newShortcut
        DebugLogger.shared.info("Updated rewrite mode hotkey", source: "GlobalHotkeyManager")
        self.scheduleActiveShortcutLog(reason: "shortcuts updated")
    }

    func updateCommandModeShortcutEnabled(_ enabled: Bool) {
        self.commandModeShortcutEnabled = enabled
        if !enabled { self.discardShortcutPress(for: .commandMode) }
        DebugLogger.shared.info(
            "Command mode shortcut \(enabled ? "enabled" : "disabled")",
            source: "GlobalHotkeyManager"
        )
        self.scheduleActiveShortcutLog(reason: "shortcuts updated")
    }

    func updateRewriteModeShortcutEnabled(_ enabled: Bool) {
        self.rewriteModeShortcutEnabled = enabled
        if !enabled { self.discardShortcutPress(for: .rewriteMode) }
        DebugLogger.shared.info(
            "Rewrite mode shortcut \(enabled ? "enabled" : "disabled")",
            source: "GlobalHotkeyManager"
        )
        self.scheduleActiveShortcutLog(reason: "shortcuts updated")
    }

    func setPromptModeCallback(_ callback: @escaping () async -> Void) {
        self.promptModeCallback = callback
    }

    func updatePromptModeShortcut(_ newShortcut: HotkeyShortcut) {
        if newShortcut != self.promptModeShortcut { self.discardShortcutPress(for: .promptMode) }
        self.promptModeShortcut = newShortcut
        DebugLogger.shared.info("Updated prompt mode hotkey", source: "GlobalHotkeyManager")
        self.scheduleActiveShortcutLog(reason: "shortcuts updated")
    }

    func updatePromptModeShortcutEnabled(_ enabled: Bool) {
        self.promptModeShortcutEnabled = enabled
        if !enabled { self.discardShortcutPress(for: .promptMode) }
        DebugLogger.shared.info(
            "Prompt mode shortcut \(enabled ? "enabled" : "disabled")",
            source: "GlobalHotkeyManager"
        )
        self.scheduleActiveShortcutLog(reason: "shortcuts updated")
    }

    func updatePromptShortcutAssignments(_ assignments: [(selection: SettingsStore.DictationPromptSelection, shortcut: HotkeyShortcut)]) {
        let previous = self.activePromptAssignmentPress.map { [$0] }
            ?? self.promptShortcutAssignments.filter { $0.shortcut == self.activeRecordingActionShortcuts[.promptAssignment] }
        if !previous.allSatisfy({ old in assignments.contains { $0.selection == old.selection && $0.shortcut == old.shortcut } }) {
            self.discardShortcutPress(for: .promptAssignment)
        }
        self.promptShortcutAssignments = assignments
        DebugLogger.shared.info("Updated prompt shortcut assignments", source: "GlobalHotkeyManager")
        self.scheduleActiveShortcutLog(reason: "shortcuts updated")
    }

    func setCancelCallback(_ callback: @escaping () -> CancelHandlingResult) {
        self.cancelCallback = callback
    }

    func setPasteLastTranscriptionCallback(_ callback: @escaping () -> Void) {
        self.pasteLastTranscriptionCallback = callback
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
        self.finishInterruptedMouseShortcutPress(reason: "hotkey tap reinitialized")
        self.cleanupEventTap()

        if !AXIsProcessTrusted() {
            DebugLogger.shared.debug("Accessibility permissions not granted", source: "GlobalHotkeyManager")
            return false
        }

        self.eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.keyboardEventMask(),
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                ClipboardAudit.recordShortcut(type: type, event: event)
                if GlobalHotkeyManager.isSynthesizedTypingEvent(event) {
                    return Unmanaged.passUnretained(event)
                }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon)
                    .takeUnretainedValue()
                if Thread.isMainThread {
                    return MainActor.assumeIsolated {
                        manager.handleKeyEvent(type: type, event: event, proxy: proxy)
                    }
                }
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        manager.handleKeyEvent(type: type, event: event, proxy: proxy)
                    }
                }
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

        CFRunLoopAddSource(self.keyboardTapRunLoopStartingIfNeeded(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        if !self.isEventTapEnabled() {
            DebugLogger.shared.error("Event tap could not be enabled", source: "GlobalHotkeyManager")
            self.cleanupEventTap()
            return false
        }

        DebugLogger.shared.info("Event tap successfully created and enabled", source: "GlobalHotkeyManager")
        self.logActiveShortcuts(reason: "event tap ready")
        self.setupMouseTaps()
        return true
    }

    private nonisolated func cleanupEventTap() {
        Self.tearDown(tap: self.eventTap, source: self.runLoopSource, runLoop: self.keyboardTapRunLoop ?? CFRunLoopGetMain())
        self.eventTap = nil
        self.runLoopSource = nil
        self.clearPrimaryShortcutPressState()
        self.cleanupMouseTaps()
    }

    private nonisolated static func tearDown(
        tap: CFMachPort?,
        source: CFRunLoopSource?,
        runLoop: CFRunLoop = CFRunLoopGetMain()
    ) {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
    }

    /// Starts (once) a dedicated thread whose run loop services the keyboard tap.
    private nonisolated func keyboardTapRunLoopStartingIfNeeded() -> CFRunLoop {
        if let runLoop = self.keyboardTapRunLoop { return runLoop }

        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var createdRunLoop: CFRunLoop?
        let thread = Thread {
            createdRunLoop = CFRunLoopGetCurrent()
            // A port keeps the loop alive while no tap source is attached.
            let keepAlive = NSMachPort()
            RunLoop.current.add(keepAlive, forMode: .common)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.fluidvoice.hotkey-event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        let runLoop: CFRunLoop = createdRunLoop ?? CFRunLoopGetMain()
        self.keyboardTapRunLoop = runLoop
        self.keyboardTapThread = thread
        return runLoop
    }

    nonisolated static func mouseObserverEventMask() -> CGEventMask {
        (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
    }

    nonisolated static func mouseShortcutEventMask(mouseButtons: Set<Int>) -> CGEventMask {
        var mask: CGEventMask = 0
        if mouseButtons.contains(0) {
            mask |= (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
                | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        }
        if mouseButtons.contains(1) {
            mask |= (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
                | (CGEventMask(1) << CGEventType.rightMouseUp.rawValue)
        }
        if mouseButtons.contains(where: { $0 >= 2 }) {
            mask |= (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
                | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        }
        return mask
    }

    struct ActiveShortcutSummaryInput {
        let primary: [HotkeyShortcut]
        let promptAssignments: [(key: String, shortcut: HotkeyShortcut)]
        let secondaryPromptMode: HotkeyShortcut
        let secondaryPromptModeEnabled: Bool
        let command: HotkeyShortcut?
        let commandEnabled: Bool
        let edit: HotkeyShortcut
        let editEnabled: Bool
        let cancel: HotkeyShortcut?
        let pasteLast: HotkeyShortcut?
        let pasteLastEnabled: Bool
        let mode: HotkeyActivationMode
    }

    /// One line listing every shortcut the manager will act on and where it came from.
    static func activeShortcutSummary(_ input: ActiveShortcutSummaryInput) -> String {
        func describe(_ shortcut: HotkeyShortcut?) -> String {
            guard let shortcut else { return "none" }
            if shortcut.isMouseShortcut {
                return "\(shortcut.displayString) [button=\(shortcut.mouseButton ?? -1) flags=\(shortcut.relevantModifierFlags.rawValue)]"
            }
            return "\(shortcut.displayString) [keyCode=\(shortcut.keyCode) flags=\(shortcut.relevantModifierFlags.rawValue)]"
        }

        var parts = ["mode=\(input.mode.rawValue)"]
        parts += input.primary.enumerated().map { "primary[\($0.offset)]=\(describe($0.element))" }
        parts += input.promptAssignments.map { "prompt[\($0.key)]=\(describe($0.shortcut))" }
        parts.append("secondaryPromptMode=\(describe(input.secondaryPromptMode)) enabled=\(input.secondaryPromptModeEnabled)")
        parts.append("command=\(describe(input.command)) enabled=\(input.commandEnabled)")
        parts.append("edit=\(describe(input.edit)) enabled=\(input.editEnabled)")
        parts.append("cancel=\(describe(input.cancel))")
        parts.append("pasteLast=\(describe(input.pasteLast)) enabled=\(input.pasteLastEnabled)")
        return parts.joined(separator: " | ")
    }

    /// Coalesces the burst of shortcut updates into one log line.
    private func scheduleActiveShortcutLog(reason: String) {
        guard !self.activeShortcutLogScheduled else { return }
        self.activeShortcutLogScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activeShortcutLogScheduled = false
            self.logActiveShortcuts(reason: reason)
        }
    }

    private func logActiveShortcuts(reason: String) {
        let settings = SettingsStore.shared
        let promptAssignments = self.promptShortcutAssignments.map { assignment in
            (
                key: settings.dictationPromptConfigurationKey(for: assignment.selection) ?? "?",
                shortcut: assignment.shortcut
            )
        }
        let summary = Self.activeShortcutSummary(.init(
            primary: self.primaryShortcuts,
            promptAssignments: promptAssignments,
            secondaryPromptMode: self.promptModeShortcut,
            secondaryPromptModeEnabled: self.promptModeShortcutEnabled,
            command: self.commandModeShortcut,
            commandEnabled: self.commandModeShortcutEnabled,
            edit: self.rewriteModeShortcut,
            editEnabled: self.rewriteModeShortcutEnabled,
            cancel: settings.cancelRecordingHotkeyShortcut,
            pasteLast: settings.pasteLastTranscriptionHotkeyShortcut,
            pasteLastEnabled: settings.pasteLastTranscriptionShortcutEnabled,
            mode: self.hotkeyMode
        ))
        DebugLogger.shared.info("Active shortcuts (\(reason)) | \(summary)", source: "GlobalHotkeyManager")
    }

    nonisolated static func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var modifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return modifiers
    }

    private nonisolated static func isTapEnabled(_ tap: CFMachPort?) -> Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func configuredMouseButtons() -> Set<Int> {
        var buttons = Set(self.primaryShortcuts.compactMap { shortcut in
            shortcut.isMouseShortcut ? shortcut.mouseButton : nil
        })

        if SettingsStore.shared.pasteLastTranscriptionShortcutEnabled,
           let shortcut = SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut,
           shortcut.isMouseShortcut,
           let mouseButton = shortcut.mouseButton
        {
            buttons.insert(mouseButton)
        }

        return buttons
    }

    private func setupMouseTaps() {
        self.setupMouseObserverTap()
        self.setupMouseShortcutTap(mouseButtons: self.configuredMouseButtons())
    }

    // Listen-only: macOS delivers clicks to apps whether or not this callback runs.
    private func setupMouseObserverTap() {
        self.cleanupMouseObserverTap()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.mouseObserverEventMask(),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleMouseObserverEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugLogger.shared.error("Failed to create mouse observer tap", source: "GlobalHotkeyManager")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            DebugLogger.shared.error("Failed to create mouse observer run loop source", source: "GlobalHotkeyManager")
            return
        }

        self.mouseObserverTap = tap
        self.mouseObserverSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DebugLogger.shared.info("Mouse observer tap enabled (listen-only)", source: "GlobalHotkeyManager")
    }

    // Filter tap, created only for the button families that have a shortcut.
    private func setupMouseShortcutTap(mouseButtons: Set<Int>, preservePrimaryPress: Bool = false) {
        let preservesHeldPress = preservePrimaryPress && self.activePrimaryShortcutPress?.mouseButton != nil
        if !preservesHeldPress { self.finishInterruptedMouseShortcutPress(reason: "mouse shortcut tap rebuilt") }
        self.cleanupMouseShortcutTap(preservePrimaryPress: preservesHeldPress)
        var installedTap = false
        defer {
            if preservesHeldPress, !installedTap {
                self.finishInterruptedMouseShortcutPress(reason: "mouse shortcut tap rebuild failed")
            }
        }

        let mask = Self.mouseShortcutEventMask(mouseButtons: mouseButtons)
        guard mask != 0 else {
            DebugLogger.shared.info("Mouse shortcut tap not needed [mouseButtons=none]", source: "GlobalHotkeyManager")
            return
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleMouseShortcutEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugLogger.shared.error("Failed to create mouse shortcut tap", source: "GlobalHotkeyManager")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            DebugLogger.shared.error("Failed to create mouse shortcut run loop source", source: "GlobalHotkeyManager")
            return
        }

        self.mouseShortcutTap = tap
        self.mouseShortcutSource = source
        self.monitoredMouseButtons = mouseButtons
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        installedTap = Self.isTapEnabled(tap)
        let summary = mouseButtons.sorted().map(String.init).joined(separator: ",")
        DebugLogger.shared.info("Mouse shortcut tap enabled [mouseButtons=\(summary)]", source: "GlobalHotkeyManager")
    }

    private func recoverMouseTapsIfNeeded() {
        if !Self.isTapEnabled(self.mouseObserverTap) {
            DebugLogger.shared.warning("Mouse observer tap not enabled, rebuilding", source: "GlobalHotkeyManager")
            self.setupMouseObserverTap()
        }

        let mouseButtons = self.configuredMouseButtons()
        let shortcutTapMissing = !mouseButtons.isEmpty && !Self.isTapEnabled(self.mouseShortcutTap)
        if mouseButtons != self.monitoredMouseButtons || shortcutTapMissing {
            DebugLogger.shared.warning("Mouse shortcut tap out of date, rebuilding", source: "GlobalHotkeyManager")
            self.setupMouseShortcutTap(mouseButtons: mouseButtons)
        }
    }

    private nonisolated func cleanupMouseTaps() {
        self.cleanupMouseObserverTap()
        self.cleanupMouseShortcutTap()
    }

    private nonisolated func cleanupMouseObserverTap() {
        Self.tearDown(tap: self.mouseObserverTap, source: self.mouseObserverSource)
        self.mouseObserverTap = nil
        self.mouseObserverSource = nil
    }

    private nonisolated func cleanupMouseShortcutTap(preservePrimaryPress: Bool = false) {
        Self.tearDown(tap: self.mouseShortcutTap, source: self.mouseShortcutSource)
        self.mouseShortcutTap = nil
        self.mouseShortcutSource = nil
        self.monitoredMouseButtons = []
        if !preservePrimaryPress { self.clearPrimaryShortcutPressState(mouseOnly: true) }
    }

    private func handleMouseObserverEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            self.reenableMouseTap(self.mouseObserverTap, label: "Mouse observer") { self.setupMouseObserverTap() }
            return Unmanaged.passUnretained(event)
        }

        if self.isShortcutCaptureActiveProvider?() ?? false {
            return Unmanaged.passUnretained(event)
        }

        self.markOtherInputDuringModifierOnly()
        return Unmanaged.passUnretained(event)
    }

    func handleMouseShortcutEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let previousInput = self.currentInputTiming
        self.currentInputTiming = HotkeyInputTiming(
            receivedAt: ProcessInfo.processInfo.systemUptime,
            eventTimestamp: event.timestamp,
            eventType: type.rawValue,
            receivedTimestamp: DispatchTime.now().uptimeNanoseconds
        )
        defer { self.currentInputTiming = previousInput }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            self.finishInterruptedMouseShortcutPress(reason: "mouse shortcut tap disabled")
            self.reenableMouseTap(self.mouseShortcutTap, label: "Mouse shortcut") {
                self.setupMouseShortcutTap(mouseButtons: self.configuredMouseButtons())
            }
            return Unmanaged.passUnretained(event)
        }

        if self.isShortcutCaptureActiveProvider?() ?? false {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            self.markOtherInputDuringModifierOnly()
            if self.handleMouseShortcutDown(event, modifiers: Self.modifierFlags(from: event.flags)) {
                return nil
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if self.handleMouseShortcutUp(event) {
                return nil
            }
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func reenableMouseTap(_ tap: CFMachPort?, label: String, rebuild: @escaping @MainActor () -> Void) {
        DebugLogger.shared.warning("\(label) tap disabled by macOS, re-enabling", source: "GlobalHotkeyManager")
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        guard !Self.isTapEnabled(tap) else { return }

        DebugLogger.shared.warning("\(label) tap re-enable failed, rebuilding", source: "GlobalHotkeyManager")
        Task { @MainActor in
            rebuild()
        }
    }

    nonisolated static func sessionIsLocked(sessionInfo: [String: Any]) -> Bool {
        sessionInfo["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private nonisolated static func currentSessionIsLocked() -> Bool {
        self.sessionIsLocked(sessionInfo: CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:])
    }

    private nonisolated func clearPrimaryShortcutPressState(mouseOnly: Bool = false) {
        let task = self.state.withLock { () -> Task<Void, Never>? in
            self.state.consumedPasteMouseButton = nil
            if mouseOnly {
                guard case .mouse? = self.state.activePrimaryShortcutPress else { return nil }
            } else {
                guard self.state.activePrimaryShortcutPress != nil || self.state.isKeyPressed else { return nil }
            }
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
    }

    private func mouseButton(from event: CGEvent) -> Int {
        Int(event.getIntegerValueField(.mouseEventButtonNumber))
    }

    private func finishInterruptedMouseShortcutPress(reason: String) {
        guard case .mouse? = self.activePrimaryShortcutPress else { return }

        self.clearPrimaryShortcutPressState(mouseOnly: true)

        DebugLogger.shared.warning(
            "Finishing active mouse shortcut press before \(reason)",
            source: "GlobalHotkeyManager"
        )

        guard Self.shouldForceStopInterruptedPrimaryPress(activationMode: self.hotkeyMode) else { return }
        if self.asrService.isRunningOrStarting {
            self.stopRecordingIfNeeded()
        } else {
            self.stopRecordingAfterRelease(
                for: .transcription,
                label: "Interrupted mouse shortcut",
                requireTargetMode: false
            )
        }
    }

    nonisolated static func shouldForceStopInterruptedPrimaryPress(activationMode: HotkeyActivationMode) -> Bool {
        activationMode != .toggle
    }

    private func primaryModifierOnlyBehavior(for shortcut: HotkeyShortcut) -> ModifierOnlyShortcutBehavior {
        .init(
            shortcut: shortcut,
            isEnabled: true,
            holdModeType: .transcription,
            holdStartMessage: "Transcription modifier held (hold mode) - starting",
            holdReleaseMessage: "Transcription modifier released (hold mode) - stopping",
            toggleIgnoredMessage: "Transcription modifier released but another key was pressed - ignoring",
            isModeKeyPressed: { self.isKeyPressed },
            setModeKeyPressed: { self.isKeyPressed = $0 },
            onHoldStart: { self.startRecordingIfNeeded(shortcut: shortcut) },
            onToggleRelease: {
                if self.asrService.isRunningOrStarting {
                    let isSameMode = self.isDictateRecordingProvider?() ?? false
                    DebugLogger.shared.info(
                        "Hotkey route | pressed=dictate(mod) | active=\(isSameMode ? "dictate" : "other") | asrRunning=true | action=\(isSameMode ? "stop" : "switch")",
                        source: "GlobalHotkeyManager"
                    )
                    if isSameMode {
                        self.triggerDictationMode(shortcut: shortcut)
                    } else {
                        self.triggerDictationMode(shortcut: shortcut)
                    }
                } else {
                    DebugLogger.shared.info(
                        "Hotkey route | pressed=dictate(mod) | active=none | asrRunning=false | action=start",
                        source: "GlobalHotkeyManager"
                    )
                    self.triggerDictationMode(shortcut: shortcut)
                }
            },
            isTargetModeActive: { self.isDictateRecordingProvider?() ?? false }
        )
    }

    func handleKeyEvent(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy? = nil) -> Unmanaged<CGEvent>? {
        let previousInput = self.currentInputTiming
        self.currentInputTiming = HotkeyInputTiming(
            receivedAt: ProcessInfo.processInfo.systemUptime,
            eventTimestamp: event.timestamp,
            eventType: type.rawValue,
            receivedTimestamp: DispatchTime.now().uptimeNanoseconds
        )
        defer { self.currentInputTiming = previousInput }

        if let tapRecoveryResult = self.handleTapDisableEvent(type: type, event: event) {
            return tapRecoveryResult
        }

        if Self.isSynthesizedTypingEvent(event) {
            return Unmanaged.passUnretained(event)
        }

        if self.handleHoldToMute(type: type, event: event, proxy: proxy) {
            return nil
        }

        if self.isShortcutCaptureActiveProvider?() ?? false {
            self.resetModifierOnlyShortcutTracking()
            if Self.captureKeyboardEvent(type: type, event: event, isAppActive: NSApp.isActive, handler: self.shortcutCaptureHandler) { return nil }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let eventModifiers = Self.modifierFlags(from: event.flags)
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch type {
        case .keyDown:
            // A fresh down proves the previous same-key release was missed. Do not let its
            // stale ownership turn ordinary typing into a shortcut on the next key-up.
            if self.hotkeyMode == .toggle,
               !isAutorepeat,
               self.activePrimaryShortcutPress?.keyboardKeyCode == keyCode
            { self.activePrimaryShortcutPress = nil }
            // The application owns cancellation output; fallback managers only discard capture.
            if SettingsStore.shared.cancelRecordingHotkeyShortcut?.matches(keyCode: keyCode, modifiers: eventModifiers) == true {
                let result = self.cancelCallback?() ?? .unhandled
                // Closing a suggestion must preserve the held shortcut and capture.
                if result == .dismissedOverlay {
                    self.markOtherInputDuringModifierOnly()
                    return nil
                }
                var handled = result == .cancelled
                if !handled, self.asrService.isRunningOrStarting {
                    Task { @MainActor in await self.asrService.stopWithoutTranscription() }
                    handled = true
                }
                let hasPendingPress = self.state.withLock {
                    self.state.activePrimaryShortcutPress != nil || self.state.activeModifierOnlyType != nil
                }
                if handled || hasPendingPress || self.pendingRecordingActionCounts.values.contains(where: { $0 > 0 }) {
                    self.resetModifierOnlyShortcutTracking(reason: .cancel)
                    return nil
                }
            }

            self.markOtherInputDuringModifierOnly()

            // Check the "paste last transcription" shortcut (a one-shot action, like cancel).
            if SettingsStore.shared.pasteLastTranscriptionShortcutEnabled,
               let pasteShortcut = SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut,
               pasteShortcut.matches(keyCode: keyCode, modifiers: eventModifiers)
            {
                // Holding the chord emits auto-repeat key-downs; because the paste waits for the
                // modifiers to release, every repeat would otherwise queue another insertion and
                // paste N times. triggerPasteLastTranscription ignores repeats.
                self.triggerPasteLastTranscription(isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
                return nil
            }

            if let assignment = self.promptShortcutAssignments.first(where: { $0.shortcut.matchesRecordingShortcut(keyCode: keyCode, modifiers: eventModifiers) }) {
                guard !isAutorepeat else { return nil }
                switch self.hotkeyMode {
                case .hold:
                    if !self.isPromptAssignmentKeyPressed {
                        self.cancelPendingReleaseStop(for: .promptAssignment)
                        self.clearHoldModeStartTriggered(for: .promptAssignment)
                        self.activePromptAssignmentPress = assignment
                        self.isPromptAssignmentKeyPressed = true
                        DebugLogger.shared.info("Prompt shortcut pressed (hold mode) - starting", source: "GlobalHotkeyManager")
                        self.triggerPromptSelection(assignment.selection, shortcut: assignment.shortcut)
                        self.markHoldModeStartTriggered(for: .promptAssignment)
                    }
                case .automatic:
                    if !self.isPromptAssignmentKeyPressed {
                        self.activePromptAssignmentPress = assignment
                        self.isPromptAssignmentKeyPressed = true
                        let isSameMode = self.asrService.isRunning && (self.isPromptModeRecordingProvider?() ?? false)
                        self.beginAutomaticPress(for: .promptAssignment, wasTargetActive: isSameMode)
                        if self.asrService.isRunning {
                            if isSameMode {
                                DebugLogger.shared.info("Prompt shortcut pressed (automatic, same mode) - waiting for release", source: "GlobalHotkeyManager")
                            } else {
                                DebugLogger.shared.info("Prompt shortcut pressed (automatic, switch mode)", source: "GlobalHotkeyManager")
                                self.triggerPromptSelection(assignment.selection, shortcut: assignment.shortcut)
                                self.markAutomaticPressStarted(for: .promptAssignment)
                            }
                        } else {
                            DebugLogger.shared.info("Prompt shortcut triggered (automatic) - starting", source: "GlobalHotkeyManager")
                            self.triggerPromptSelection(assignment.selection, shortcut: assignment.shortcut)
                            self.markAutomaticPressStarted(for: .promptAssignment)
                        }
                    }
                case .toggle:
                    if self.asrService.isRunningOrStarting {
                        if self.isPromptModeRecordingProvider?() ?? false {
                            DebugLogger.shared.info("Prompt shortcut pressed in Prompt mode - stopping", source: "GlobalHotkeyManager")
                            self.triggerPromptSelection(assignment.selection, shortcut: assignment.shortcut)
                        } else {
                            DebugLogger.shared.info("Prompt shortcut pressed while recording - switching mode", source: "GlobalHotkeyManager")
                            self.triggerPromptSelection(assignment.selection, shortcut: assignment.shortcut)
                        }
                    } else {
                        DebugLogger.shared.info("Prompt shortcut triggered - starting", source: "GlobalHotkeyManager")
                        self.triggerPromptSelection(assignment.selection, shortcut: assignment.shortcut)
                    }
                }
                return nil
            }

            // Check prompt mode hotkey
            if self.handlePromptModeKeyDown(keyCode: keyCode, modifiers: eventModifiers, isAutorepeat: isAutorepeat) { return nil }

            // Check command mode hotkey first
            if self.commandModeShortcutEnabled,
               let commandModeShortcut = self.commandModeShortcut,
               commandModeShortcut.matchesRecordingShortcut(keyCode: keyCode, modifiers: eventModifiers)
            {
                guard !isAutorepeat else { return nil }
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
                    if self.asrService.isRunningOrStarting {
                        if self.isCommandRecordingProvider?() ?? false {
                            DebugLogger.shared.info("Command mode shortcut pressed in Command mode - stopping", source: "GlobalHotkeyManager")
                            self.triggerCommandMode()
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
                if self.rewriteModeShortcut.matchesRecordingShortcut(keyCode: keyCode, modifiers: eventModifiers) {
                    guard !isAutorepeat else { return nil }
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
                        if self.asrService.isRunningOrStarting {
                            if self.isRewriteRecordingProvider?() ?? false {
                                DebugLogger.shared.info("Rewrite mode shortcut pressed in Edit mode - stopping", source: "GlobalHotkeyManager")
                                self.triggerRewriteMode()
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
            if let shortcut = self.primaryShortcuts.first(where: { $0.matchesRecordingShortcut(keyCode: keyCode, modifiers: eventModifiers) }) {
                guard !isAutorepeat else { return nil }
                guard self.beginPrimaryShortcutPress(.keyboard(shortcut)) else { return nil }
                self.handlePrimaryDictationTriggerDown()
                return nil
            }

        case .keyUp:
            // Prompt mode key up (press and hold mode)
            if self.handlePromptModeKeyUp(keyCode: keyCode) { return nil }

            // Command mode key up
            // Note: Only check keyCode, not modifiers - user may release modifier before/with main key
            if self.commandModeShortcutEnabled,
               self.isCommandModeKeyPressed,
               let commandModeShortcut = self.commandModeShortcut,
               keyCode == commandModeShortcut.keyCode
            {
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
               self.activePromptAssignmentPress?.shortcut.keyCode == keyCode
            {
                self.activePromptAssignmentPress = nil
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
            if let shortcut = self.finishPrimaryShortcutPress(matching: { $0.keyboardKeyCode == keyCode }) {
                self.handlePrimaryDictationTriggerUp(shortcut: shortcut)
                return nil
            }

        case .flagsChanged:
            if HotkeyShortcut.modifierFlag(forKeyCode: keyCode) != nil {
                self.pressedModifierKeyCodes = self.synchronizedPressedModifierKeyCodes(
                    changedKeyCode: keyCode,
                    modifiers: eventModifiers
                )
            }

            for shortcut in self.primaryShortcuts where shortcut.isModifierOnlyShortcut {
                if self.handleModifierOnlyShortcutFlagsChanged(
                    behavior: self.primaryModifierOnlyBehavior(for: shortcut),
                    keyCode: keyCode,
                    modifiers: eventModifiers
                ) { return nil }
            }

            if self.handlePromptAssignmentFlagsChanged(keyCode: keyCode, modifiers: eventModifiers) { return nil }

            if self.handlePromptModeFlagsChanged(keyCode: keyCode, modifiers: eventModifiers) { return nil }

            if let commandModeShortcut = self.commandModeShortcut,
               self.handleModifierOnlyShortcutFlagsChanged(
                   behavior: .init(
                       shortcut: commandModeShortcut,
                       isEnabled: self.commandModeShortcutEnabled,
                       holdModeType: .commandMode,
                       holdStartMessage: "Command mode modifier held (hold mode) - starting",
                       holdReleaseMessage: "Command mode modifier released (hold mode) - stopping",
                       toggleIgnoredMessage: "Command mode modifier released but another key was pressed - ignoring",
                       isModeKeyPressed: { self.isCommandModeKeyPressed },
                       setModeKeyPressed: { self.isCommandModeKeyPressed = $0 },
                       onHoldStart: { self.triggerCommandMode() },
                       onToggleRelease: {
                           if self.asrService.isRunningOrStarting {
                               if self.isCommandRecordingProvider?() ?? false {
                                   DebugLogger.shared.info("Command mode modifier released (toggle, same mode) - stopping", source: "GlobalHotkeyManager")
                                   self.triggerCommandMode()
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
               )
            { return nil }

            if self.handleModifierOnlyShortcutFlagsChanged(
                behavior: .init(
                    shortcut: self.rewriteModeShortcut,
                    isEnabled: self.rewriteModeShortcutEnabled,
                    holdModeType: .rewriteMode,
                    holdStartMessage: "Rewrite mode modifier held (hold mode) - starting",
                    holdReleaseMessage: "Rewrite mode modifier released (hold mode) - stopping",
                    toggleIgnoredMessage: "Rewrite mode modifier released but another key was pressed - ignoring",
                    isModeKeyPressed: { self.isRewriteKeyPressed },
                    setModeKeyPressed: { self.isRewriteKeyPressed = $0 },
                    onHoldStart: { self.triggerRewriteMode() },
                    onToggleRelease: {
                        if self.asrService.isRunningOrStarting {
                            if self.isRewriteRecordingProvider?() ?? false {
                                DebugLogger.shared.info("Rewrite mode modifier released (toggle, same mode) - stopping", source: "GlobalHotkeyManager")
                                self.triggerRewriteMode()
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

        default:
            break
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

        // Flags tell us a modifier family is active, not which physical side. Preserve the
        // side-specific keys we already observed instead of rediscovering them from keyState.
        var synchronizedKeyCodes = self.pressedModifierKeyCodes.filter { keyCode in
            guard let flag = HotkeyShortcut.modifierFlag(forKeyCode: keyCode) else { return false }
            return activeModifiers.contains(flag)
        }

        guard let changedGroup = activeModifierGroups.first(where: { $0.0 == changedFlag }) else {
            return synchronizedKeyCodes
        }

        if activeModifiers.contains(changedFlag) {
            if synchronizedKeyCodes.contains(changedKeyCode) {
                let siblingKeyCodes = changedGroup.1.filter { $0 != changedKeyCode }
                let siblingIsTracked = siblingKeyCodes.contains { synchronizedKeyCodes.contains($0) }
                if siblingIsTracked,
                   !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(changedKeyCode))
                {
                    synchronizedKeyCodes.remove(changedKeyCode)
                }
            } else {
                synchronizedKeyCodes.insert(changedKeyCode)
            }
        } else {
            synchronizedKeyCodes.subtract(changedGroup.1)
        }

        return synchronizedKeyCodes
    }

    private func markModifierOnlyPressInterrupted(message: String) {
        self.otherKeyPressedDuringModifier = true
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
            break // The owning keyboard/mouse release toggles; repeats do not.
        }
    }

    private func handlePrimaryDictationTriggerUp(shortcut: HotkeyShortcut) {
        switch self.hotkeyMode {
        case .hold:
            self.isKeyPressed = false
            _ = self.finishHoldModeStartTriggered(for: .transcription)
            self.stopRecordingAfterRelease(for: .transcription, label: "Transcription")
        case .automatic:
            self.isKeyPressed = false
            self.handleAutomaticKeyRelease(for: .transcription, label: "Transcription")
        case .toggle:
            if self.asrService.isRunningOrStarting {
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
                    self.triggerDictationMode(shortcut: shortcut)
                } else {
                    self.triggerDictationMode(shortcut: shortcut)
                }
            } else {
                DebugLogger.shared.info(
                    "Hotkey route | pressed=dictate | active=none | asrRunning=false | action=start",
                    source: "GlobalHotkeyManager"
                )
                self.triggerDictationMode(shortcut: shortcut)
            }
        }
    }

    private func stopRecordingAfterRelease(
        for type: HotkeyHoldModeType,
        label: String,
        requireTargetMode: Bool = true
    ) {
        let toggleStopRequestedAt = ProcessInfo.processInfo.systemUptime
        self.logStopInput(requestedAt: toggleStopRequestedAt, route: "deferred_release")
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
                    guard !requireTargetMode || self.isRecordingTargetActive(for: type) else {
                        DebugLogger.shared.debug("\(label) deferred stop skipped - active mode changed", source: "GlobalHotkeyManager")
                        self.clearPendingReleaseStop(for: type, token: token)
                        return
                    }

                    DebugLogger.shared.info("\(label) deferred stop after recording start", source: "GlobalHotkeyManager")
                    self.clearPendingReleaseStop(for: type, token: token)
                    await self.stopRecordingInternal(toggleStopRequestedAt: toggleStopRequestedAt)
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

        let wasTargetActive = self.asrService.isRunning && behavior.isTargetModeActive()
        if self.hotkeyMode == .automatic {
            self.beginAutomaticPress(for: behavior.holdModeType, wasTargetActive: wasTargetActive)
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

    private func finishModifierOnlyPress(
        for behavior: ModifierOnlyShortcutBehavior,
        wasCleanPress: Bool
    ) {
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
        self.invalidateAllRecordingActions()
        self.modifierPressReceivedAt = nil
        self.currentStopPressReceivedAt = nil
        let shouldStopActiveHold = reason != .cancel && self.hotkeyMode != .toggle
            && self.asrService.isRunningOrStarting
            && (self.isKeyPressed || self.isPromptModeKeyPressed || self.isCommandModeKeyPressed || self.isRewriteKeyPressed || self.isPromptAssignmentKeyPressed)

        self.pressedModifierKeyCodes = []
        self.modifierOnlyKeyDown = false
        self.activeModifierOnlyType = nil
        self.otherKeyPressedDuringModifier = false
        self.modifierPressStartTime = nil
        self.clearAutomaticPressTracking()
        self.isKeyPressed = false
        self.isPromptModeKeyPressed = false
        self.isCommandModeKeyPressed = false
        self.isRewriteKeyPressed = false
        self.isPromptAssignmentKeyPressed = false
        self.activePromptAssignmentPress = nil
        self.activeModifierOnlyShortcut = nil
        self.activePrimaryShortcutPress = nil

        if shouldStopActiveHold {
            switch reason {
            case .shortcutCapture:
                DebugLogger.shared.debug("Shortcut capture active - stopping active hold recording before reset", source: "GlobalHotkeyManager")
            case .tapDisabled:
                DebugLogger.shared.warning("Event tap disabled during active hold - stopping recording before reset", source: "GlobalHotkeyManager")
            case .cancel:
                break
            case .reinitialize:
                DebugLogger.shared.info("Hotkey manager reinitializing - stopping active hold recording before reset", source: "GlobalHotkeyManager")
            }
            self.stopRecordingIfNeeded()
        }
    }

    private func handlePromptModeKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isAutorepeat: Bool) -> Bool {
        guard self.promptModeShortcutEnabled, self.promptModeShortcut.matchesRecordingShortcut(keyCode: keyCode, modifiers: modifiers) else { return false }
        guard !isAutorepeat else { return true }
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
            if self.asrService.isRunningOrStarting {
                if self.isPromptModeRecordingProvider?() ?? false {
                    DebugLogger.shared.info("Prompt mode shortcut pressed in Prompt mode - stopping", source: "GlobalHotkeyManager")
                    self.triggerPromptMode()
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
                holdStartMessage: "Prompt mode modifier held (hold mode) - starting",
                holdReleaseMessage: "Prompt mode modifier released (hold mode) - stopping",
                toggleIgnoredMessage: "Prompt mode modifier released but another key was pressed - ignoring",
                isModeKeyPressed: { self.isPromptModeKeyPressed },
                setModeKeyPressed: { self.isPromptModeKeyPressed = $0 },
                onHoldStart: { self.triggerPromptMode() },
                onToggleRelease: {
                    if self.asrService.isRunningOrStarting {
                        if self.isPromptModeRecordingProvider?() ?? false {
                            DebugLogger.shared.info("Prompt mode modifier released (toggle, same mode) - stopping", source: "GlobalHotkeyManager")
                            self.triggerPromptMode()
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
                    holdModeType: .promptAssignment,
                    holdStartMessage: "Prompt shortcut modifier held (hold mode) - starting",
                    holdReleaseMessage: "Prompt shortcut modifier released (hold mode) - stopping",
                    toggleIgnoredMessage: "Prompt shortcut modifier released but another key was pressed - ignoring",
                    isModeKeyPressed: { self.isPromptAssignmentKeyPressed },
                    setModeKeyPressed: { self.isPromptAssignmentKeyPressed = $0 },
                    onHoldStart: { self.triggerPromptSelection(assignment.selection, shortcut: assignment.shortcut) },
                    onToggleRelease: {
                        if self.asrService.isRunningOrStarting {
                            if self.isPromptModeRecordingProvider?() ?? false {
                                DebugLogger.shared.info("Prompt shortcut modifier released (toggle, same mode) - stopping", source: "GlobalHotkeyManager")
                                self.triggerPromptSelection(assignment.selection, shortcut: assignment.shortcut)
                            } else {
                                DebugLogger.shared.info("Prompt shortcut modifier released (toggle, switch mode) - switching", source: "GlobalHotkeyManager")
                                self.triggerPromptSelection(assignment.selection, shortcut: assignment.shortcut)
                            }
                        } else {
                            DebugLogger.shared.info("Prompt shortcut modifier released (toggle) - starting", source: "GlobalHotkeyManager")
                            self.triggerPromptSelection(assignment.selection, shortcut: assignment.shortcut)
                        }
                    },
                    isTargetModeActive: { self.isPromptModeRecordingProvider?() ?? false }
                ),
                keyCode: keyCode,
                modifiers: modifiers
            )
            if handled {
                self.activePromptAssignmentPress = self.activeModifierOnlyType == .promptAssignment ? assignment : nil
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
        // A held keyboard/mouse shortcut already owns this route.
        guard behavior.holdModeType != .transcription || self.activePrimaryShortcutPress == nil else { return false }
        guard !behavior.isModeKeyPressed() || self.activeModifierOnlyType == behavior.holdModeType else { return false }
        let decision = ModifierOnlyShortcutFlagsDecision.evaluate(
            shortcut: behavior.shortcut,
            holdModeType: behavior.holdModeType,
            isEnabled: behavior.isEnabled,
            keyCode: keyCode,
            modifiers: modifiers,
            state: ModifierOnlyShortcutTrackingState(
                pressedModifierKeyCodes: self.pressedModifierKeyCodes,
                activeModifierOnlyType: self.activeModifierOnlyType,
                activeModifierOnlyShortcut: self.activeModifierOnlyShortcut,
                otherKeyPressedDuringModifier: self.otherKeyPressedDuringModifier,
                isModeKeyPressed: behavior.isModeKeyPressed()
            )
        )

        self.activeModifierOnlyType = decision.activeModifierOnlyType
        self.activeModifierOnlyShortcut = decision.activeModifierOnlyShortcut
        if decision.markInterrupted {
            self.markModifierOnlyPressInterrupted(
                message: "\(self.label(for: behavior.holdModeType)) modifier-only press interrupted - extra modifier pressed"
            )
        }
        self.otherKeyPressedDuringModifier = decision.otherKeyPressedDuringModifier

        switch decision.outcome {
        case .ignore:
            return false
        case .start:
            self.modifierPressReceivedAt = self.currentInputTiming?.receivedAt
            self.modifierOnlyKeyDown = true
            self.modifierPressStartTime = Date()

            self.scheduleModifierOnlyStart(for: behavior)
            return true
        case let .finish(wasCleanPress):
            let previousPress = self.currentStopPressReceivedAt
            self.currentStopPressReceivedAt = self.modifierPressReceivedAt
            self.modifierPressReceivedAt = nil
            defer { self.currentStopPressReceivedAt = previousPress }
            self.modifierOnlyKeyDown = false
            self.modifierPressStartTime = nil

            self.finishModifierOnlyPress(for: behavior, wasCleanPress: wasCleanPress)
            return true
        }
    }

    private func triggerPromptMode() {
        self.queueRecordingAction(for: .promptMode, shortcut: self.promptModeShortcut) { [weak self] in
            guard let self = self else { return }
            guard self.canTriggerRecordingAction("Prompt mode hotkey") else { return }
            DebugLogger.shared.info("Prompt mode hotkey triggered", source: "GlobalHotkeyManager")
            await self.promptModeCallback?()
        }
    }

    private func triggerPromptSelection(_ selection: SettingsStore.DictationPromptSelection, shortcut: HotkeyShortcut) {
        self.queueRecordingAction(for: .promptAssignment, shortcut: shortcut, selection: selection) { [weak self] in
            guard let self = self else { return }
            guard self.canTriggerRecordingAction("Prompt selection hotkey") else { return }
            DebugLogger.shared.info("Prompt selection hotkey triggered", source: "GlobalHotkeyManager")
            await self.promptSelectionCallback?(selection)
        }
    }

    private func triggerCommandMode() {
        self.queueRecordingAction(for: .commandMode, shortcut: self.commandModeShortcut) { [weak self] in
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
        self.queueRecordingAction(for: .rewriteMode, shortcut: self.rewriteModeShortcut) { [weak self] in
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

    /// Handles a mouse-button down event against the configured mouse shortcuts. Returns true when
    /// the event was consumed. "Paste Last Transcription" is a one-shot trigger (mirrors the keyboard
    /// path); primary dictation begins a press here and ends it on mouse-up.
    private func handleMouseShortcutDown(_ event: CGEvent, modifiers eventModifiers: NSEvent.ModifierFlags) -> Bool {
        let mouseButton = self.mouseButton(from: event)
        if self.hotkeyMode == .toggle, self.activePrimaryShortcutPress?.mouseButton == mouseButton {
            self.activePrimaryShortcutPress = nil
        }

        if SettingsStore.shared.pasteLastTranscriptionShortcutEnabled,
           let pasteShortcut = SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut,
           pasteShortcut.matchesMouse(button: mouseButton, modifiers: eventModifiers)
        {
            self.state.withLock { self.state.consumedPasteMouseButton = mouseButton }
            self.triggerPasteLastTranscription(isAutorepeat: false)
            return true
        }

        if let shortcut = self.primaryShortcuts.first(where: { $0.matchesMouse(button: mouseButton, modifiers: eventModifiers) }) {
            guard self.beginPrimaryShortcutPress(.mouse(shortcut)) else { return false }
            self.handlePrimaryDictationTriggerDown()
            return true
        }

        return false
    }

    /// Swallows only the mouse-up that pairs with a mouse-down this tap consumed.
    private func handleMouseShortcutUp(_ event: CGEvent) -> Bool {
        let mouseButton = self.mouseButton(from: event)

        let consumedPasteDown = self.state.withLock { () -> Bool in
            guard self.state.consumedPasteMouseButton == mouseButton else { return false }
            self.state.consumedPasteMouseButton = nil
            return true
        }
        if consumedPasteDown {
            return true
        }

        guard let shortcut = self.finishPrimaryShortcutPress(matching: { $0.mouseButton == mouseButton }) else { return false }
        self.handlePrimaryDictationTriggerUp(shortcut: shortcut)
        return true
    }

    func triggerPasteLastTranscription(isAutorepeat: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Holding the chord auto-repeats the key-down; act only on the initial press.
            guard !isAutorepeat else { return }
            guard self.canTriggerRecordingAction("Paste last transcription hotkey") else { return }
            // Re-pasting mid-recording would be surprising; ignore while capture is active.
            guard !self.asrService.isRunning else {
                DebugLogger.shared.info(
                    "Paste last transcription hotkey ignored - recording in progress",
                    source: "GlobalHotkeyManager"
                )
                return
            }
            DebugLogger.shared.info("Paste last transcription hotkey triggered", source: "GlobalHotkeyManager")
            self.pasteLastTranscriptionCallback?()
        }
    }

    private func triggerDictationMode(shortcut: HotkeyShortcut? = nil) {
        let shortcut = shortcut ?? self.activePrimaryShortcutPress?.shortcut ?? (self.activeModifierOnlyType == .transcription ? self.activeModifierOnlyShortcut : nil)
        self.queueRecordingAction(for: .transcription, shortcut: shortcut) { [weak self] in
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
        guard mode != self.hotkeyMode else { return }
        for type in [HotkeyHoldModeType.transcription, .promptMode, .commandMode, .rewriteMode, .promptAssignment] {
            self.discardShortcutPress(for: type)
        }
        self.hotkeyMode = mode
        DebugLogger.shared.info("Hotkey activation mode set to \(mode.displayName)", source: "GlobalHotkeyManager")
        self.scheduleActiveShortcutLog(reason: "shortcuts updated")
    }

    func enablePressAndHoldMode(_ enable: Bool) {
        self.setHotkeyMode(enable ? .hold : .toggle)
    }

    private func canTriggerRecordingAction(_ label: String) -> Bool {
        guard !Self.currentSessionIsLocked() else {
            DebugLogger.shared.info("Ignoring \(label) - screen is locked", source: "GlobalHotkeyManager")
            return false
        }
        guard !self.isProcessingStop else {
            DebugLogger.shared.debug("CLOSE_DETAIL shortcutRejected stopLocked=true uptime=\(ProcessInfo.processInfo.systemUptime)", source: "StopTiming")
            return false
        }
        guard !self.asrService.isDictionaryTrainingCaptureActive else {
            DebugLogger.shared.debug("Ignoring \(label) - dictionary training capture is active", source: "GlobalHotkeyManager")
            return false
        }
        return true
    }

    func toggleRecording() {
        let toggleStopRequestedAt = ProcessInfo.processInfo.systemUptime
        if self.asrService.isRunningOrStarting {
            self.logStopInput(requestedAt: toggleStopRequestedAt, route: "toggle")
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Prevent new operations while stop is processing
            guard self.canTriggerRecordingAction("toggle") else { return }

            if self.asrService.isRunningOrStarting {
                await self.stopRecordingInternal(toggleStopRequestedAt: toggleStopRequestedAt)
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

    private func startRecordingIfNeeded(shortcut: HotkeyShortcut? = nil) {
        let shortcut = shortcut ?? self.activePrimaryShortcutPress?.shortcut ?? (self.activeModifierOnlyType == .transcription ? self.activeModifierOnlyShortcut : nil)
        self.queueRecordingAction(for: .transcription, shortcut: shortcut) { [weak self] in
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

    private func logStopInput(requestedAt: TimeInterval, route: String) {
        guard DebugLogger.diagnosticsEnabled else { return }
        var fields = "stop_request stopRequestedAt=\(requestedAt) route=\(route)"
        if let input = self.currentInputTiming {
            fields += " inputReceivedAt=\(input.receivedAt) eventType=\(input.eventType)"
            if let age = input.deliveryAgeMs {
                fields += " inputAgeMs=\(age)"
            }
            if let press = self.currentStopPressReceivedAt, press <= input.receivedAt {
                fields += " pressReceivedAt=\(press)"
            }
        }
        DebugLogger.shared.benchmark("HOTKEY_BENCH", message: fields, source: "HotkeyBenchmark")
    }

    private func stopRecordingIfNeeded(toggleStopRequestedAt: TimeInterval? = nil) {
        let toggleStopRequestedAt = toggleStopRequestedAt ?? ProcessInfo.processInfo.systemUptime
        self.logStopInput(requestedAt: toggleStopRequestedAt, route: "stop_if_needed")
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            if self.isProcessingStop {
                DebugLogger.shared.debug("Ignoring stop - already processing", source: "GlobalHotkeyManager")
                return
            }
            guard !self.asrService.isDictionaryTrainingCaptureActive else {
                DebugLogger.shared.debug("Ignoring stop - dictionary training capture is active", source: "GlobalHotkeyManager")
                return
            }

            guard self.asrService.isRunningOrStarting else {
                return
            }

            await self.stopRecordingInternal(toggleStopRequestedAt: toggleStopRequestedAt)
        }
    }

    @MainActor
    private func stopRecordingInternal(toggleStopRequestedAt: TimeInterval? = nil) async {
        if self.asrService.isStarting, self.asrService.isRunning == false {
            DebugLogger.shared.debug("Cancelling pending audio capture start", source: "GlobalHotkeyManager")
            await self.asrService.cancelPendingAudioCaptureStart(reason: "hotkey_released")
        }
        guard self.asrService.isRunning else { return }
        guard !self.asrService.isDictionaryTrainingCaptureActive else {
            DebugLogger.shared.debug("Stop ignored - dictionary training capture is active", source: "GlobalHotkeyManager")
            return
        }
        guard !self.isProcessingStop else {
            DebugLogger.shared.debug("Stop already in progress, ignoring", source: "GlobalHotkeyManager")
            return
        }

        let closeStartedAt = self.traceStopLocked()
        defer { self.traceStopUnlocked(since: closeStartedAt) }

        if let callback = stopAndProcessCallback {
            await callback(toggleStopRequestedAt)
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
        self.healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let healthCheckInterval = self?.healthCheckInterval else { break }
                do {
                    try await Task.sleep(nanoseconds: UInt64(healthCheckInterval * 1_000_000_000))
                } catch {
                    break
                }

                guard !Task.isCancelled else { break }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !self.validateEventTapHealth() {
                        DebugLogger.shared.warning("Health check failed, attempting to recover", source: "GlobalHotkeyManager")

                        if self.setupGlobalHotkey() {
                            self.isInitialized = true
                            DebugLogger.shared.info("Health check recovery successful", source: "GlobalHotkeyManager")
                        } else {
                            DebugLogger.shared.error("Health check recovery failed", source: "GlobalHotkeyManager")
                            self.isInitialized = false
                        }
                    } else {
                        self.recoverMouseTapsIfNeeded()
                    }
                }
            }
        }
    }

    deinit {
        initializationTask?.cancel()
        healthCheckTask?.cancel()
        muteReleaseRecoveryTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        cleanupEventTap()
    }
}

private extension GlobalHotkeyManager {
    func invalidateRecordingActions(for type: HotkeyHoldModeType) {
        self.recordingActionRevisions[type, default: 0] &+= 1
        self.pendingRecordingActionCounts[type] = 0
        self.activeRecordingActionShortcuts.removeValue(forKey: type)
        self.pendingRecordingActions.removeValue(forKey: type)?.cancel()
    }

    func invalidateAllRecordingActions() {
        for type in [HotkeyHoldModeType.transcription, .promptMode, .commandMode, .rewriteMode, .promptAssignment] {
            self.invalidateRecordingActions(for: type)
        }
    }

    /// Keep rapid taps in order through the actual asynchronous capture start/stop.
    func queueRecordingAction(for type: HotkeyHoldModeType, shortcut: HotkeyShortcut?, selection: SettingsStore.DictationPromptSelection? = nil, action: @escaping @MainActor () async -> Void) {
        guard self.canTriggerRecordingAction(self.label(for: type)) else { return }
        let revision = self.recordingActionRevisions[type, default: 0]
        let previous = self.pendingRecordingActions[type]
        self.pendingRecordingActionCounts[type, default: 0] += 1
        self.pendingRecordingActions[type] = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                await previous?.value
            } onCancel: {
                previous?.cancel()
            }
            guard !Task.isCancelled else { return }
            guard let self, self.recordingActionRevisions[type, default: 0] == revision else { return }
            defer {
                if self.recordingActionRevisions[type, default: 0] == revision {
                    self.pendingRecordingActionCounts[type, default: 0] -= 1
                    if self.pendingRecordingActionCounts[type] == 0 {
                        self.pendingRecordingActions.removeValue(forKey: type)
                    }
                }
            }
            guard self.canTriggerRecordingAction(self.label(for: type)) else { return }
            if let shortcut, !self.isRecordingShortcutConfigured(shortcut, for: type, selection: selection) { return }
            self.activeRecordingActionShortcuts[type] = shortcut
            defer {
                if self.recordingActionRevisions[type, default: 0] == revision {
                    self.activeRecordingActionShortcuts.removeValue(forKey: type)
                }
            }
            if self.hotkeyMode == .toggle, self.asrService.isRunningOrStarting, self.isRecordingTargetActive(for: type) {
                // Changing an input binding must not cancel transcription already processing.
                await Task { @MainActor in
                    await self.stopRecordingInternal(toggleStopRequestedAt: ProcessInfo.processInfo.systemUptime)
                }.value
                return
            }
            await action()
        }
    }

    private func isRecordingShortcutConfigured(_ shortcut: HotkeyShortcut, for type: HotkeyHoldModeType, selection: SettingsStore.DictationPromptSelection?) -> Bool {
        switch type {
        case .transcription: self.primaryShortcuts.contains(shortcut)
        case .promptMode: self.promptModeShortcutEnabled && self.promptModeShortcut == shortcut
        case .commandMode: self.commandModeShortcutEnabled && self.commandModeShortcut == shortcut
        case .rewriteMode: self.rewriteModeShortcutEnabled && self.rewriteModeShortcut == shortcut
        case .promptAssignment: self.promptShortcutAssignments.contains { $0.shortcut == shortcut && $0.selection == selection }
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

    func discardShortcutPress(for type: HotkeyHoldModeType) {
        self.invalidateRecordingActions(for: type)
        if type == .promptAssignment { self.activePromptAssignmentPress = nil }
        let hadPress = self.state.withLock {
            let ownsModifier = self.state.activeModifierOnlyType == type
            var pressed: Bool
            switch type {
            case .transcription:
                pressed = self.state.isKeyPressed || self.state.activePrimaryShortcutPress != nil
                self.state.isKeyPressed = false
                self.state.activePrimaryShortcutPress = nil
            case .promptMode:
                pressed = self.state.isPromptModeKeyPressed
                self.state.isPromptModeKeyPressed = false
            case .commandMode:
                pressed = self.state.isCommandModeKeyPressed
                self.state.isCommandModeKeyPressed = false
            case .rewriteMode:
                pressed = self.state.isRewriteKeyPressed
                self.state.isRewriteKeyPressed = false
            case .promptAssignment:
                pressed = self.state.isPromptAssignmentKeyPressed
                self.state.isPromptAssignmentKeyPressed = false
            }
            if ownsModifier {
                self.state.activeModifierOnlyType = nil
                self.state.activeModifierOnlyShortcut = nil
                self.state.modifierOnlyKeyDown = false
                self.state.otherKeyPressedDuringModifier = false
                self.state.modifierPressStartTime = nil
            }
            return pressed || ownsModifier
        }
        guard hadPress else { return }
        self.cancelPendingReleaseStop(for: type)
        self.clearHoldModeStartTriggered(for: type)
        _ = self.finishAutomaticPress(for: type)
        if self.hotkeyMode != .toggle, self.asrService.isRunningOrStarting, self.isRecordingTargetActive(for: type) {
            self.stopRecordingAfterRelease(for: type, label: self.label(for: type))
        }
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

    private func finishPrimaryShortcutPress(matching matches: (ActivePrimaryShortcutPress) -> Bool) -> HotkeyShortcut? {
        self.state.withLock {
            guard let press = self.state.activePrimaryShortcutPress, matches(press) else {
                return nil
            }
            self.state.activePrimaryShortcutPress = nil
            return press.shortcut
        }
    }
}

extension GlobalHotkeyManager {
    func traceStopLocked() -> TimeInterval {
        OverlayCloseRunLoopProbe.begin()
        self.isProcessingStop = true
        return ProcessInfo.processInfo.systemUptime
    }

    func traceStopUnlocked(since startedAt: TimeInterval) {
        self.isProcessingStop = false
        DebugLogger.shared.debug(
            "CLOSE_DETAIL shortcutUnlocked uptime=\(ProcessInfo.processInfo.systemUptime) heldMs=\((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)",
            source: "StopTiming"
        )
    }

    nonisolated static func isSynthesizedTypingEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == TypingService.synthesizedEventUserData
    }

    nonisolated static func keyboardEventMask() -> CGEventMask {
        (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
    }

    /// Capture before system shortcuts (such as Control-Command-D lookup) can consume the key.
    /// The local monitor remains a fallback for app-directed events that bypass the session tap.
    static func captureKeyboardEvent(
        type: CGEventType,
        event: CGEvent,
        isAppActive: Bool,
        handler: ((NSEvent) -> NSEvent?)?
    ) -> Bool {
        guard isAppActive, type == .keyDown || type == .flagsChanged,
              let handler, let appEvent = NSEvent(cgEvent: event)
        else { return false }
        return handler(appEvent) == nil
    }
}

extension GlobalHotkeyManager {
    private func handleTapDisableEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS can temporarily disable event taps (e.g. timeouts, user input protection).
        // If we don't immediately re-enable here, hotkeys will silently stop working until our
        // periodic health check kicks in, and the OS may handle the key (e.g. system dictation).
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else {
            return nil
        }

        self.holdToMuteSpaceTap.cancel()
        let reason = (type == .tapDisabledByTimeout) ? "timeout" : "user input"
        DebugLogger.shared.warning("Event tap disabled by \(reason) — attempting immediate re-enable", source: "GlobalHotkeyManager")
        self.resetModifierOnlyShortcutTracking(reason: .tapDisabled)
        if self.holdToMuteChecksPhysicalKeyState {
            self.reconcileHoldToMute(isPhysicallyDown: CGEventSource.keyState(.hidSystemState, key: 49))
        }

        if let tap = self.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        if !self.isEventTapEnabled() {
            DebugLogger.shared.warning("Event tap re-enable failed — recreating tap", source: "GlobalHotkeyManager")
            self.setupGlobalHotkeyWithRetry()
        }

        return Unmanaged.passUnretained(event)
    }

    @objc private func holdSpaceSettingChanged() {
        if !SettingsStore.shared.holdSpaceToMute {
            self.holdToMuteSpaceTap.cancel()
            self.muteRecordingGeneration = nil
            self.asrService.setDictationMuted(false)
        }
    }

    private func hasConfiguredShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        var shortcuts = self.primaryShortcuts + self.promptShortcutAssignments.map(\.shortcut)
        if self.promptModeShortcutEnabled {
            shortcuts.append(self.promptModeShortcut)
        }
        if self.rewriteModeShortcutEnabled {
            shortcuts.append(self.rewriteModeShortcut)
        }
        if self.commandModeShortcutEnabled, let shortcut = self.commandModeShortcut {
            shortcuts.append(shortcut)
        }
        if let shortcut = SettingsStore.shared.cancelRecordingHotkeyShortcut {
            shortcuts.append(shortcut)
        }
        if SettingsStore.shared.pasteLastTranscriptionShortcutEnabled,
           let shortcut = SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut
        {
            shortcuts.append(shortcut)
        }
        return shortcuts.contains { $0.matches(keyCode: keyCode, modifiers: modifiers) }
    }

    private var canTypeMuteTap: Bool {
        self.muteRecordingGeneration == self.asrService.dictationMuteGeneration &&
            SettingsStore.shared.holdSpaceToMute && self.asrService.isRunningOrStarting &&
            !self.asrService.isDictionaryTrainingCaptureActive &&
            (self.isDictateRecordingProvider?() ?? false) &&
            !(self.isShortcutCaptureActiveProvider?() ?? false)
    }

    private func handleHoldToMute(type: CGEventType, event: CGEvent, proxy: CGEventTapProxy?) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Self.modifierFlags(from: event.flags)
        guard keyCode == 49, type == .keyDown || type == .keyUp else {
            if self.holdToMuteKeyState.ownsSpace, type != .keyUp {
                // Fast typing can overlap Space and the next letter. Flush before the
                // letter, but never before navigation, shortcuts, or modifier changes.
                let typing = type == .keyDown && HoldToMuteSpaceTap.isPlainTextKey(event) &&
                    !self.hasConfiguredShortcut(keyCode: keyCode, modifiers: modifiers)
                self.holdToMuteSpaceTap.finish(at: event.timestamp, proxy: proxy, allowed: typing && self.canTypeMuteTap)
            }
            return false
        }
        let wasOwned = self.holdToMuteKeyState.ownsSpace
        let consumed: Bool
        var beginTap = false
        var finishTap = false
        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let canBegin = SettingsStore.shared.holdSpaceToMute && self.asrService.isRunningOrStarting &&
                !self.asrService.isDictionaryTrainingCaptureActive &&
                (self.isDictateRecordingProvider?() ?? false) &&
                !(self.isShortcutCaptureActiveProvider?() ?? false) &&
                modifiers.isDisjoint(with: HotkeyShortcut.relevantModifierMask) &&
                !self.hasConfiguredShortcut(keyCode: 49, modifiers: [])
            consumed = self.holdToMuteKeyState.keyDown(isRepeat: isRepeat, canBegin: canBegin)
            self.holdToMuteSpaceTap.cancel()
            if consumed, !isRepeat {
                self.muteRecordingGeneration = self.asrService.dictationMuteGeneration
                self.startMuteReleaseRecovery()
                beginTap = true
            }
        case .keyUp:
            consumed = self.holdToMuteKeyState.keyUp()
            finishTap = consumed && self.canTypeMuteTap && modifiers.isDisjoint(with: HotkeyShortcut.relevantModifierMask)
            self.muteRecordingGeneration = nil
            self.muteReleaseRecoveryTask?.cancel()
            self.muteReleaseRecoveryTask = nil
        default:
            return false
        }
        if consumed || wasOwned {
            let muted = self.holdToMuteKeyState.ownsSpace &&
                self.muteRecordingGeneration == self.asrService.dictationMuteGeneration &&
                SettingsStore.shared.holdSpaceToMute
            self.asrService.setDictationMuted(muted)
        }
        // Muting and unmuting always precede any destination/event bookkeeping.
        if beginTap {
            self.holdToMuteSpaceTap.begin(event)
        } else if type == .keyUp {
            self.holdToMuteSpaceTap.finish(at: event.timestamp, proxy: proxy, allowed: finishTap)
        }
        return consumed
    }

    /// Recover a missed key-up without unmuting while Space is physically held.
    func reconcileHoldToMute(isPhysicallyDown: Bool) {
        guard self.holdToMuteKeyState.ownsSpace else { return }
        self.holdToMuteKeyState.reconcile(isPhysicallyDown: isPhysicallyDown)
        if !self.holdToMuteKeyState.ownsSpace {
            self.holdToMuteSpaceTap.cancel()
            self.muteRecordingGeneration = nil
            self.asrService.setDictationMuted(false)
        }
    }

    private func startMuteReleaseRecovery() {
        self.muteReleaseRecoveryTask?.cancel()
        guard self.holdToMuteChecksPhysicalKeyState else { return }
        self.muteReleaseRecoveryTask = Task { [weak self] in
            // Give a normal short tap its key-up before recovering a lost release.
            do { try await Task.sleep(nanoseconds: HoldToMuteSpaceTap.maximumDuration) } catch { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, self.holdToMuteKeyState.ownsSpace else { return }
                self.reconcileHoldToMute(isPhysicallyDown: CGEventSource.keyState(.hidSystemState, key: 49))
            }
        }
    }
}
