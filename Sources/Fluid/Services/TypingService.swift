import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

final class TypingService {
    nonisolated static let synthesizedEventUserData: Int64 = 0x46565353

    struct CapturedFocusTarget {
        let pid: pid_t
        let window: AXUIElement?
        let element: AXUIElement

        var isSecureTextField: Bool {
            let subrole = TypingService.stringAXAttribute(
                from: self.element,
                attribute: kAXSubroleAttribute as CFString
            ) ?? ""
            return subrole == (kAXSecureTextFieldSubrole as String)
                || subrole.localizedCaseInsensitiveContains("secure")
        }
    }

    enum DeliveryOutcome: Equatable {
        case rejected
        case insertionFailed
        case inserted
        case actionSuppressed
        case actionDispatched
        case insertedActionSuppressed
        case insertedAndActionDispatched

        var didInsert: Bool {
            switch self {
            case .inserted, .insertedActionSuppressed, .insertedAndActionDispatched:
                return true
            case .rejected, .insertionFailed, .actionSuppressed, .actionDispatched:
                return false
            }
        }

        var didDispatchAction: Bool {
            self == .actionDispatched || self == .insertedAndActionDispatched
        }
    }

    nonisolated static func canDispatchPostInsertionAction(
        preferredTargetPID: pid_t?,
        requiredTargetPID: pid_t?,
        isSecureTextField: Bool,
        modifiersReleased: Bool,
        exactFocusIsActive: Bool
    ) -> Bool {
        guard let preferredTargetPID, preferredTargetPID > 0,
              requiredTargetPID == preferredTargetPID
        else {
            return false
        }
        return !isSecureTextField && modifiersReleased && exactFocusIsActive
    }

    nonisolated static func canInsertBeforePostInsertionAction(
        preferredTargetPID: pid_t?,
        requiredTargetPID: pid_t?,
        isSecureTextField: Bool,
        exactFocusIsActive: Bool
    ) -> Bool {
        guard let preferredTargetPID, preferredTargetPID > 0,
              requiredTargetPID == preferredTargetPID
        else {
            return false
        }
        return !isSecureTextField && exactFocusIsActive
    }

    // Logging toggle (off by default). Enable by setting env FLUID_TYPING_LOGS=1
    // or UserDefaults bool for key "enableTypingLogs".
    private static var isLoggingEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["FLUID_TYPING_LOGS"], env == "1" { return true }
        return UserDefaults.standard.bool(forKey: "enableTypingLogs")
    }

    private func log(_ message: @autoclosure () -> String) {
        guard TypingService.isLoggingEnabled else { return }
        DebugLogger.shared.debug(message(), source: "TypingService")
    }

    private var isCurrentlyTyping = false

    private struct FocusSnapshot {
        let pid: pid_t
        let window: AXUIElement?
        let element: AXUIElement?
    }

    private struct PasteboardItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
    }

    private struct FocusedTextSnapshot {
        let pid: pid_t
        let bundleIdentifier: String?
        let value: String?
        let selectedRange: CFRange?
        let appScriptValue: String?
        let appScriptSelectedRange: CFRange?
    }

    private enum PasteVerificationResult: String {
        case appScriptContainsText = "appscript_contains_text"
        case appScriptCaretMovedExpectedDistance = "appscript_caret_moved_expected_distance"
        case fieldContainsText = "field_contains_text"
        case caretMovedExpectedDistance = "caret_moved_expected_distance"
        case timeout
        case unavailable
    }

    private static let focusSnapshotQueue = DispatchQueue(label: "TypingService.FocusSnapshot")
    private static let pasteboardSessionSemaphore = DispatchSemaphore(value: 1)
    private static let pasteboardRestoreQueue = DispatchQueue(label: "TypingService.PasteboardRestore", qos: .utility)
    private static var focusSnapshot: FocusSnapshot?

    /// Modifier flags observed when dictation started, used to decide whether the guest may
    /// have been left in a menu state. `nil` when nothing recorded it for this dictation.
    private static var dictationHotkeyModifiers: CGEventFlags?
    private static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"

    /// Windows App, formerly Microsoft Remote Desktop. Both ship this bundle identifier.
    private static let remoteDesktopBundleIdentifier = "com.microsoft.rdc.macos"

    static let remoteDesktopClipboardSettleDefaultMs = 200
    static let remoteDesktopClipboardSettleMaximumMs = 10_000
    static let remoteDesktopClipboardSettleOverrideKey = "RemoteDesktopClipboardSettleMs"

    /// Grace period between writing the pasteboard and starting the focus bounce that makes
    /// the client re-advertise its clipboard.
    ///
    /// Measured against a live session: no settle length alone is sufficient. Four pastes over
    /// 43 seconds, across four distinct pasteboard writes 8 seconds apart, all delivered the
    /// *first* value, with plain and transient items behaving identically and a 2.5s settle
    /// changing nothing. The focus change is the mechanism, not elapsed time - so this is only
    /// a short grace to let the write land before focus moves.
    ///
    /// Clamped, because the value is multiplied into a `useconds_t` and an unclamped user
    /// default would trap.
    nonisolated static func remoteDesktopSettleMicros(override: NSNumber?) -> useconds_t {
        let requested = override.map(\.intValue) ?? self.remoteDesktopClipboardSettleDefaultMs
        let clamped = min(max(0, requested), self.remoteDesktopClipboardSettleMaximumMs)
        return useconds_t(clamped * 1000)
    }

    static let remoteDesktopTypeDelayDefaultMs = 16
    static let remoteDesktopTypeDelayMaximumMs = 200
    static let remoteDesktopTypeDelayOverrideKey = "RemoteDesktopTypeDelayMs"
    /// How often the focused *element* is re-confirmed while typing. The per-chord check
    /// compares only the PID, which cannot tell two windows of the same client apart.
    static let remoteDesktopElementRecheckInterval = 10

    static let remoteDesktopWarmupDefaultMs = 250
    static let remoteDesktopWarmupMaximumMs = 3000
    static let remoteDesktopWarmupOverrideKey = "RemoteDesktopWarmupMs"

    /// Pause between releasing the hotkey's modifiers and the first typed character.
    ///
    /// `waitForPhysicalModifiersToRelease` only observes the *local* flag state. The client
    /// still has to forward the modifier release across the remote keyboard channel, and until
    /// the guest processes it the guest believes the modifier is held - so the first character
    /// arrives as a modifier chord (`Alt+a` is a menu accelerator, which inserts nothing) and is
    /// lost. This is the dropped-leading-character behaviour reported in discussion #563.
    ///
    /// Overridable via the `RemoteDesktopWarmupMs` user default (no Settings UI).
    nonisolated static func remoteDesktopWarmupMicros(override: NSNumber?) -> useconds_t {
        let requested = override.map(\.intValue) ?? self.remoteDesktopWarmupDefaultMs
        let clamped = min(max(0, requested), self.remoteDesktopWarmupMaximumMs)
        return useconds_t(clamped * 1000)
    }

    private static var remoteDesktopWarmup: useconds_t {
        self.remoteDesktopWarmupMicros(
            override: UserDefaults.standard.object(forKey: self.remoteDesktopWarmupOverrideKey) as? NSNumber
        )
    }

    /// Pause between the modifier releases and the Escape that exits Windows menu mode.
    static let remoteDesktopEscapeGapMicros: useconds_t = 150_000

    /// Modifier key codes explicitly released before typing into a remote session.
    private static let remoteDesktopResyncModifierKeyCodes: [CGKeyCode] = [
        CGKeyCode(kVK_Shift), CGKeyCode(kVK_RightShift),
        CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl),
        CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption),
        CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand),
    ]

    /// Pause after each character when typing into a remote-desktop session. The remote
    /// keyboard channel drops characters if they arrive faster than it forwards them.
    /// Overridable via the `RemoteDesktopTypeDelayMs` user default (no Settings UI).
    nonisolated static func remoteDesktopTypeDelayMicros(override: NSNumber?) -> useconds_t {
        let requested = override.map(\.intValue) ?? self.remoteDesktopTypeDelayDefaultMs
        let clamped = min(max(0, requested), self.remoteDesktopTypeDelayMaximumMs)
        return useconds_t(clamped * 1000)
    }

    private static var remoteDesktopTypeDelay: useconds_t {
        self.remoteDesktopTypeDelayMicros(
            override: UserDefaults.standard.object(forKey: self.remoteDesktopTypeDelayOverrideKey) as? NSNumber
        )
    }

    /// Overridable via the `RemoteDesktopClipboardSettleMs` user default (no Settings UI) so a
    /// slow link can be tuned without a rebuild.
    private static var remoteDesktopClipboardSettleMicros: useconds_t {
        self.remoteDesktopSettleMicros(
            override: UserDefaults.standard.object(forKey: self.remoteDesktopClipboardSettleOverrideKey) as? NSNumber
        )
    }

    private var textInsertionMode: SettingsStore.TextInsertionMode {
        SettingsStore.shared.textInsertionMode
    }

    // MARK: - Layout-aware key code lookup

    private static let pasteKeyCache = KeyboardLayoutSnapshotCache(initialValue: CGKeyCode(9)) {
        let key = PasteKeyCodeResolver.current()
        DebugLogger.shared.benchmark("TYPING_BENCH", message: "paste_key_cache_refresh keyCode=\(key)", source: "TypingBenchmark")
        return key
    }

    /// The characters that can be typed into a remote-desktop session on the active layout.
    ///
    /// Snapshotted for the same reason as the paste key code, but the consequence of getting it
    /// wrong is worse: the remote-desktop typing path runs on a background queue, and resolving
    /// this inline there reads the input source off the main thread, which can trap inside
    /// HIToolbox and kill the app mid-dictation.
    ///
    /// Starts empty so that a cache which never started declines to type rather than typing from
    /// a layout it has not actually read.
    private static let remoteDesktopLayoutCache = KeyboardLayoutSnapshotCache(
        initialValue: RemoteDesktopKeyMapResolver.Snapshot()
    ) {
        let snapshot = RemoteDesktopKeyMapResolver.currentSnapshot()
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "remote_layout_cache_refresh characters=\(snapshot.typable.count) pasteKey=\(snapshot.pasteKeyCode.map(String.init) ?? "none")",
            source: "TypingBenchmark"
        )
        return snapshot
    }

    /// Called during application launch, before any paste requests can arrive.
    static func startKeyboardLayoutTracking() {
        self.pasteKeyCache.start()
        self.remoteDesktopLayoutCache.start()
    }

    /// The virtual key code for "v" in the current keyboard layout (used for Cmd+V paste).
    /// Refreshed by the input-source notification, never by a background paste request.
    private static var pasteVirtualKeyCode: CGKeyCode {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let key = self.pasteKeyCache.snapshot()
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "paste_key_lookup queueMs=0 lookupMs=\((ProcessInfo.processInfo.systemUptime - startedAt) * 1000) returnMs=0 cached=true keyCode=\(key)",
            source: "TypingBenchmark"
        )
        return key
    }

    // MARK: - Focus helpers (shared)

    /// Best-effort: returns the PID owning the currently focused accessibility element.
    /// This is more reliable than NSWorkspace.frontmostApplication for floating overlays/launchers.
    /// Records the modifiers held as dictation begins.
    ///
    /// Called at recording start, before any overlay or focus changes. The hotkey's own
    /// modifiers are still down at that point, which is the only moment they can be observed -
    /// by insertion time they have been released, and the *configured* shortcut list cannot
    /// say which of several shortcuts actually fired, or whether a mouse shortcut was used.
    nonisolated static func noteDictationHotkeyModifiers() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        self.focusSnapshotQueue.sync { self.dictationHotkeyModifiers = flags }
    }

    /// Reads and clears the recorded modifiers.
    ///
    /// One-shot on purpose. The value describes a single dictation, and insertion paths that do
    /// not record it - Paste Last Transcription, for one - would otherwise read whatever the
    /// previous dictation left behind and decide the guest's menu state from stale input.
    private static func consumeDictationHotkeyModifiers() -> CGEventFlags? {
        self.focusSnapshotQueue.sync {
            let flags = self.dictationHotkeyModifiers
            self.dictationHotkeyModifiers = nil
            return flags
        }
    }

    static func captureSystemFocusTarget() -> CapturedFocusTarget? {
        // Accessibility is required to query system-focused AX element.
        guard AXIsProcessTrusted() else {
            self.storeFocusSnapshot(nil)
            return nil
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard result == .success, let focusedElementRef else {
            Self.storeFocusSnapshot(nil)
            return nil
        }
        guard CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else {
            Self.storeFocusSnapshot(nil)
            return nil
        }

        let element = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0 else {
            Self.storeFocusSnapshot(nil)
            return nil
        }
        let appElement = AXUIElementCreateApplication(pid)
        let window = Self.copyAXElementAttribute(from: appElement, attribute: kAXFocusedWindowAttribute as CFString)
            ?? Self.copyAXElementAttribute(from: appElement, attribute: kAXMainWindowAttribute as CFString)
        Self.storeFocusSnapshot(FocusSnapshot(pid: pid, window: window, element: element))
        Self.logFocusState("[TypingService] Captured focus snapshot")
        return CapturedFocusTarget(pid: pid, window: window, element: element)
    }

    static func captureSystemFocusedPID() -> pid_t? {
        self.captureSystemFocusTarget()?.pid
    }

    static func isExactFocusTargetActive(_ target: CapturedFocusTarget) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard result == .success, let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID()
        else {
            return false
        }

        let currentElement = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        return CFEqual(currentElement, target.element)
    }

    @discardableResult
    static func restoreFocusTarget(_ target: CapturedFocusTarget) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let appElement = AXUIElementCreateApplication(target.pid)

        if let window = target.window {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, window)
            _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
            usleep(40_000)
        }

        for _ in 0..<3 {
            let result = AXUIElementSetAttributeValue(
                target.element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            if result == .success, self.isExactFocusTargetActive(target) {
                return true
            }
            usleep(50_000)
        }
        return self.isExactFocusTargetActive(target)
    }

    /// Best-effort: returns the text immediately before the caret in the currently focused
    /// text field. Used by Continuous Dictation Mode to decide capitalization when chaining
    /// transcribed segments. Returns "" when the focused field/context is unavailable.
    static func textBeforeCursorInFocusedField() -> String {
        TypingService().captureTextBeforeCursorInFocusedField()
    }

    @discardableResult
    static func restoreCapturedFocus(in pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let snapshot = loadFocusSnapshot(),
              snapshot.pid == pid else { return false }

        Self.logFocusState("[TypingService] Before restoreCapturedFocus")
        let appElement = AXUIElementCreateApplication(pid)

        if let window = snapshot.window {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, window)
            _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
            usleep(40_000)
        }

        guard let element = snapshot.element else { return false }

        for _ in 0..<3 {
            let result = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            if result == .success, Self.isCurrentlyFocusedElement(element, expectedPID: pid) {
                Self.logFocusState("[TypingService] After restoreCapturedFocus success")
                return true
            }
            usleep(50_000)
        }

        let isFocused = Self.isCurrentlyFocusedElement(element, expectedPID: pid)
        Self.logFocusState("[TypingService] After restoreCapturedFocus final result=\(isFocused)")
        return isFocused
    }

    static func isCapturedFocusStillActive(for pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(),
              let snapshot = loadFocusSnapshot(),
              snapshot.pid == pid,
              let element = snapshot.element
        else {
            return false
        }

        return Self.isCurrentlyFocusedElement(element, expectedPID: pid)
    }

    private func isGhosttyApplication(pid: pid_t) -> Bool {
        guard pid > 0,
              let app = NSRunningApplication(processIdentifier: pid)
        else {
            return false
        }

        return app.bundleIdentifier == Self.ghosttyBundleIdentifier
    }

    private func ghosttyTargetPID(preferredTargetPID: pid_t?) -> pid_t? {
        if let preferredTargetPID, preferredTargetPID > 0 {
            return self.isGhosttyApplication(pid: preferredTargetPID) ? preferredTargetPID : nil
        }

        if let focusedPID = self.getSystemFocusedElementAndPID()?.pid,
           self.isGhosttyApplication(pid: focusedPID)
        {
            return focusedPID
        }

        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           self.isGhosttyApplication(pid: frontmostPID)
        {
            return frontmostPID
        }

        return nil
    }

    private func isRemoteDesktopApplication(pid: pid_t) -> Bool {
        guard pid > 0,
              let app = NSRunningApplication(processIdentifier: pid)
        else {
            return false
        }

        return app.bundleIdentifier == Self.remoteDesktopBundleIdentifier
    }

    /// Resolution order, extracted so it can be tested without a running app.
    ///
    /// Unlike ``ghosttyTargetPID`` this does not fall through from a known focused PID to the
    /// frontmost app: the chord is delivered by the window server to whatever holds key focus,
    /// so treating a frontmost remote-desktop window as the target while something else owns
    /// the focused element would paste into the wrong place.
    /// `focusedPID` and `frontmostPID` are autoclosures because resolving the focused element
    /// is a synchronous Accessibility round trip to another process. This runs on every
    /// dictation into every app, so it must not be paid when the preferred PID already decides
    /// the answer.
    nonisolated static func resolveRemoteDesktopPID(
        preferredTargetPID: pid_t?,
        focusedPID: @autoclosure () -> pid_t?,
        frontmostPID: @autoclosure () -> pid_t?,
        isRemoteDesktop: (pid_t) -> Bool
    ) -> pid_t? {
        if let preferredTargetPID, preferredTargetPID > 0 {
            return isRemoteDesktop(preferredTargetPID) ? preferredTargetPID : nil
        }

        if let focused = focusedPID() {
            return isRemoteDesktop(focused) ? focused : nil
        }

        if let frontmost = frontmostPID(), isRemoteDesktop(frontmost) {
            return frontmost
        }

        return nil
    }

    private func remoteDesktopTargetPID(preferredTargetPID: pid_t?) -> pid_t? {
        Self.resolveRemoteDesktopPID(
            preferredTargetPID: preferredTargetPID,
            focusedPID: self.getSystemFocusedElementAndPID()?.pid,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            isRemoteDesktop: { self.isRemoteDesktopApplication(pid: $0) }
        )
    }

    /// Activation options used to restore focus to the external target app after dictation.
    /// `.activateAllWindows` is intentionally omitted: raising every window of a multi-window
    /// app (e.g. WebStorm) destroys the user's window layout on each dictation (issue #748).
    static let focusRestoreActivationOptions: NSApplication.ActivationOptions = [
        .activateIgnoringOtherApps,
    ]

    /// Best-effort: activates the app with the given PID, unless it's Fluid itself.
    @discardableResult
    static func activateApp(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }

        // Never try to re-activate ourselves; callers want focus to go back to the external app.
        if let selfBundleID = Bundle.main.bundleIdentifier,
           let targetBundleID = app.bundleIdentifier,
           selfBundleID == targetBundleID
        {
            return false
        }

        return app.activate(options: Self.focusRestoreActivationOptions)
    }

    // MARK: - Public API

    func typeTextInstantly(_ text: String) {
        self.typeTextInstantly(text, preferredTargetPID: nil, textReadyAt: nil)
    }

    /// Types/inserts text, optionally preferring a specific target PID for CGEvent posting.
    /// This helps when our overlay temporarily has focus; we can still target the original app.
    func typeTextInstantly(_ text: String, preferredTargetPID: pid_t?) {
        self.typeTextInstantly(text, preferredTargetPID: preferredTargetPID, textReadyAt: nil)
    }

    /// Types/inserts text, optionally preferring a specific target PID for CGEvent posting.
    /// This helps when our overlay temporarily has focus; we can still target the original app.
    func typeTextInstantly(_ text: String, preferredTargetPID: pid_t?, textReadyAt: TimeInterval?) {
        self.typeOutputPlanInstantly(.plain(text), preferredTargetPID: preferredTargetPID, textReadyAt: textReadyAt)
    }

    func typeOutputPlanInstantly(
        _ plan: DictationLiteralOutputPlan,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval?,
        tracksDictionaryCorrections: Bool = false,
        postInsertionKey: SettingsStore.SpokenSendKey? = nil,
        requiredFocusTarget: CapturedFocusTarget? = nil,
        completion: (@MainActor (DeliveryOutcome) -> Void)? = nil
    ) {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let text = plan.plainText
        let mode = self.textInsertionMode
        let settleDelayMs: Int = {
            if mode == .reliablePaste {
                return preferredTargetPID == nil ? 80 : 0
            }
            return preferredTargetPID == nil ? 200 : 0
        }()
        let textReadyAge = textReadyAt.map { Self.elapsedMs(from: $0, to: requestedAt) }
        self.bench(
            "request chars=\(text.count) mode=\(mode.rawValue) autocompleteSteps=\(plan.steps.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyAgeMs=\(textReadyAge.map { String($0) } ?? "nil")"
        )
        self.log("[TypingService] ENTRY: typeTextInstantly called with text length: \(text.count)")
        self.log("[TypingService] Text preview: \"\(String(text.prefix(100)))\"")

        guard text.isEmpty == false || postInsertionKey != nil else {
            self.bench("request_return reason=empty_text")
            self.log("[TypingService] ERROR: Empty text provided, aborting")
            completion?(.rejected)
            return
        }

        // Prevent concurrent typing operations
        guard !self.isCurrentlyTyping else {
            self.bench("request_return reason=already_typing")
            self.log("[TypingService] WARNING: Skipping text injection - already in progress")
            completion?(.rejected)
            return
        }

        // Check accessibility permissions first
        guard AXIsProcessTrusted() else {
            self.bench("request_return reason=accessibility_not_trusted")
            self.log("[TypingService] ERROR: Accessibility permissions required for text injection")
            self.log("[TypingService] Current accessibility status: \(AXIsProcessTrusted())")
            completion?(.rejected)
            return
        }

        self.log("[TypingService] Accessibility check passed, proceeding with text injection")
        self.isCurrentlyTyping = true

        let pipelineID = DebugLogger.pipelineID
        DispatchQueue.global(qos: .userInitiated).async {
            DebugLogger.$pipelineID.withValue(pipelineID) {
                var outcome: DeliveryOutcome = .insertionFailed
                let workerStartedAt = ProcessInfo.processInfo.systemUptime
                self.bench("worker_start queueDelayMs=\(Self.elapsedMs(from: requestedAt, to: workerStartedAt))")

                defer {
                    let completedAt = ProcessInfo.processInfo.systemUptime
                    self.isCurrentlyTyping = false
                    self.bench(
                        "complete totalMs=\(Self.elapsedMs(from: requestedAt, to: completedAt)) textReadyToCompleteMs=\(textReadyAt.map { String(Self.elapsedMs(from: $0, to: completedAt)) } ?? "nil")"
                    )
                    self.log("[TypingService] Typing operation completed, isCurrentlyTyping set to false")
                    let completedOutcome = outcome
                    Task { @MainActor in
                        self.bench(
                            "delivery_main_begin queueMs=\(Self.elapsedMs(from: completedAt, to: ProcessInfo.processInfo.systemUptime))"
                        )
                        // Delivery UI must finish before correction tracking performs
                        // any synchronous Accessibility queries on the main thread.
                        completion?(completedOutcome)
                        self.bench("delivery_main_callback_return")
                        if tracksDictionaryCorrections,
                           postInsertionKey == nil,
                           completedOutcome.didInsert
                        {
                            AutomaticDictionaryCorrectionTracker.shared.beginObservingInsertion(
                                text,
                                targetPID: preferredTargetPID
                            )
                            self.bench("dictionary_tracking_scheduled afterDeliveryCallback=true")
                        }
                    }
                }

                self.log("[TypingService] Starting async text insertion process")
                if settleDelayMs > 0 {
                    usleep(useconds_t(settleDelayMs * 1000))
                }
                self.bench("settle_delay_done delayMs=\(settleDelayMs) elapsedMs=\(Self.elapsedMs(since: requestedAt))")
                let hasTextToInsert = !text.isEmpty
                if postInsertionKey != nil {
                    guard let preferredTargetPID, let requiredFocusTarget else {
                        outcome = .actionSuppressed
                        return
                    }
                    // A held dictation modifier must suppress only the key action,
                    // not the dictated text. The longer check below waits for
                    // modifiers after insertion before deciding whether to send.
                    guard Self.canInsertBeforePostInsertionAction(
                        preferredTargetPID: preferredTargetPID,
                        requiredTargetPID: requiredFocusTarget.pid,
                        isSecureTextField: requiredFocusTarget.isSecureTextField,
                        exactFocusIsActive: Self.isExactFocusTargetActive(requiredFocusTarget)
                    ) else {
                        outcome = .actionSuppressed
                        return
                    }
                }

                if hasTextToInsert {
                    self.log("[TypingService] Delay completed, calling insertTextInstantly")
                    let insertStartedAt = ProcessInfo.processInfo.systemUptime
                    self.bench("insert_call")
                    let inserted = self.insertTextInstantly(text, preferredTargetPID: preferredTargetPID)
                    self.bench(
                        "insert_return elapsedMs=\(Self.elapsedMs(since: insertStartedAt)) totalMs=\(Self.elapsedMs(since: requestedAt))"
                    )
                    guard inserted else {
                        outcome = .insertionFailed
                        return
                    }

                    outcome = .inserted
                }

                guard let postInsertionKey else { return }
                guard let preferredTargetPID, let requiredFocusTarget else {
                    outcome = hasTextToInsert ? .insertedActionSuppressed : .actionSuppressed
                    return
                }
                let modifiersReleased = self.waitForPhysicalModifiersToRelease(timeout: 2)
                let exactFocusIsActive = Self.isExactFocusTargetActive(requiredFocusTarget)
                guard Self.canDispatchPostInsertionAction(
                    preferredTargetPID: preferredTargetPID,
                    requiredTargetPID: requiredFocusTarget.pid,
                    isSecureTextField: requiredFocusTarget.isSecureTextField,
                    modifiersReleased: modifiersReleased,
                    exactFocusIsActive: exactFocusIsActive
                ) else {
                    outcome = hasTextToInsert ? .insertedActionSuppressed : .actionSuppressed
                    return
                }

                usleep(50_000)
                guard Self.isExactFocusTargetActive(requiredFocusTarget),
                      self.postReturnKey(
                          postInsertionKey,
                          targetPID: preferredTargetPID,
                          resetKeyboardState: hasTextToInsert == false,
                          requiredFocusTarget: requiredFocusTarget
                      )
                else {
                    outcome = hasTextToInsert ? .insertedActionSuppressed : .actionSuppressed
                    return
                }
                outcome = hasTextToInsert ? .insertedAndActionDispatched : .actionDispatched
            }
        }
    }

    private func bench(_ message: String) {
        DebugLogger.shared.benchmark("TYPING_BENCH", message: message, source: "TypingBenchmark")
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private static func elapsedMs(from start: TimeInterval, to end: TimeInterval) -> Int {
        Int(((end - start) * 1000).rounded())
    }

    // MARK: - Internal insertion pipeline

    private func insertTextInstantly(_ text: String, preferredTargetPID: pid_t?) -> Bool {
        self.log("[TypingService] insertTextInstantly called with \(text.count) characters")
        self.log("[TypingService] Attempting to type text: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\"")

        // Remote-desktop sessions come first and apply in both insertion modes, because both
        // of the normal paths fail there: the unicode path posts `virtualKey: 0` events that a
        // client translating scan codes cannot forward, and the clipboard path posts Cmd+V via
        // `postToPid`, which these clients do not act on, with no settle time for the client to
        // ship the clipboard to the guest.
        if let remoteDesktopPID = self.remoteDesktopTargetPID(preferredTargetPID: preferredTargetPID) {
            self.log("[TypingService] Remote desktop target detected (PID \(remoteDesktopPID)); typing directly")
            switch self.insertTextViaRemoteDesktopTyping(text, targetPID: remoteDesktopPID) {
            case .typed:
                self.log("[TypingService] SUCCESS: Remote-desktop typing path completed")
                return true

            case .unmappable:
                // Paste is lossless but needs a focus bounce, so it is only worth the
                // disruption when the layout genuinely cannot express the transcript.
                self.log("[TypingService] Falling back to remote-desktop clipboard paste")
                if self.insertTextViaRemoteDesktopPaste(text, targetPID: remoteDesktopPID) {
                    self.log("[TypingService] SUCCESS: Remote-desktop paste path completed")
                    return true
                }

            case .declined:
                break
            }

            // Deliberately not falling through to the generic cascade. Those paths post via
            // `postToPid`, which this client ignores while still reporting success, and the
            // clipboard ones would re-activate the target and hold the user's clipboard for
            // five seconds to no effect.
            self.log("[TypingService] Remote-desktop insertion failed; not attempting generic fallbacks")
            return false
        }

        if self.textInsertionMode == .standard,
           let ghosttyTargetPID = self.ghosttyTargetPID(preferredTargetPID: preferredTargetPID)
        {
            self.log("[TypingService] Ghostty target detected in standard mode (PID \(ghosttyTargetPID)); forcing Reliable Paste path")
            if self.tryReliablePasteInsertion(text, preferredTargetPID: ghosttyTargetPID) {
                self.log("[TypingService] SUCCESS: Ghostty Reliable Paste path completed")
                return true
            }
            self.log("[TypingService] Ghostty Reliable Paste path fell through to direct-typing fallbacks")
        }

        if self.textInsertionMode == .reliablePaste {
            self.log("[TypingService] Reliable Paste mode enabled")
            if self.tryReliablePasteInsertion(text, preferredTargetPID: preferredTargetPID) {
                self.log("[TypingService] SUCCESS: Reliable Paste mode completed")
                return true
            }
            self.log("[TypingService] Reliable Paste mode fell through to direct-typing fallbacks")
        } else if let preferredTargetPID, preferredTargetPID > 0 {
            self.log("[TypingService] Experimental Direct Typing mode: trying preferred PID unicode insertion first")
            if self.insertTextBulkInstant(text, targetPID: preferredTargetPID) {
                self.log("[TypingService] SUCCESS: Preferred PID CGEvent insertion completed")
                return true
            }
            self.log("[TypingService] Preferred PID CGEvent insertion failed, continuing fallback pipeline")
        }

        // Get frontmost app info
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            self.log("[TypingService] Target app: \(frontApp.localizedName ?? "Unknown") (\(frontApp.bundleIdentifier ?? "Unknown"))")
        } else {
            self.log("[TypingService] WARNING: Could not get frontmost application")
        }

        // Determine the actual focused element + owning PID (more reliable than "frontmost app" for floating launchers)
        let focusInfo = self.getSystemFocusedElementAndPID()
        if let focusedPID = focusInfo?.pid {
            self.log("[TypingService] Focused AX element PID: \(focusedPID)")
        } else {
            self.log("[TypingService] WARNING: Could not determine focused AX element PID")
        }
        Self.logFocusState("[TypingService] Before insertion pipeline")

        if let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            self.log("[TypingService] Frontmost PID: \(frontPID)")
        }

        // Check if we have permission to create events
        self.log("[TypingService] Accessibility trusted: \(AXIsProcessTrusted())")

        // Primary: Try CGEvent unicode insertion, targeting the focused PID when available
        // This is the most reliable method for Terminals, Electron apps (Discord, VSCode), etc.
        if let focusedPID = focusInfo?.pid {
            self.log("[TypingService] Trying CGEvent insertion targeting focused PID \(focusedPID)")
            if self.insertTextBulkInstant(text, targetPID: focusedPID) {
                self.log("[TypingService] SUCCESS: CGEvent focused-PID insertion completed")
                return true
            }
        }

        // Secondary: Try Accessibility insertion into the actual focused element
        self.log("[TypingService] Trying Accessibility focused-element insertion")
        if self.insertTextViaAccessibility(text) {
            self.log("[TypingService] SUCCESS: Accessibility insertion completed")
            return true
        }

        // HID Fallback if PID targeting failed
        if focusInfo?.pid == nil {
            self.log("[TypingService] No focused PID available, trying HID CGEvent insertion")
            if self.insertTextBulkHIDInstant(text) {
                self.log("[TypingService] SUCCESS: CGEvent HID insertion completed")
                return true
            }
        }

        // Fallback: Use clipboard-based insertion (more reliable)
        self.log("[TypingService] CGEvent failed, trying clipboard fallback")
        if self.insertTextViaClipboard(text) {
            self.log("[TypingService] SUCCESS: Clipboard insertion completed")
            return true
        }

        // Last resort: Character-by-character
        self.log("[TypingService] WARNING: All methods failed, trying character-by-character")
        for (index, char) in text.enumerated() {
            if index % 10 == 0 {
                self.log("[TypingService] Typing character \(index + 1)/\(text.count)")
            }
            self.typeCharacter(char)
            usleep(1000)
        }
        self.log("[TypingService] Character-by-character typing completed")
        return true
    }

    private func waitForPhysicalModifiersToRelease(timeout: TimeInterval) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let startedAt = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - startedAt < timeout {
            if CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: relevant) {
                return true
            }
            usleep(15_000)
        }
        return false
    }

    /// - Parameter resetKeyboardState: only for the action-only path, where no text was
    ///   inserted and the typing path's reset therefore never ran. After text *has* been typed
    ///   the guest is already out of menu mode, and an Escape there would dismiss the control
    ///   that is about to receive Return - cancelling an autocomplete, or reverting a field.
    private func postReturnKey(
        _ key: SettingsStore.SpokenSendKey,
        targetPID: pid_t,
        resetKeyboardState: Bool,
        requiredFocusTarget: CapturedFocusTarget?
    ) -> Bool {
        let returnKeyCode = CGKeyCode(kVK_Return)

        // Remote-desktop clients do not act on `postToPid` keyboard events, so a Spoken Send
        // Return would otherwise be dropped while the UI reported it as sent. Build it as a
        // real chord: assigning `key.eventFlags` would give Shift+Enter and Command+Enter no
        // modifier scan code to forward, and a Shift+Enter that arrives as a bare Enter sends
        // a message the user meant to add a newline to.
        if self.isRemoteDesktopApplication(pid: targetPID) {
            guard let chord = Self.makeRemoteDesktopChord(
                modifierKeyCode: Self.spokenSendModifierKeyCode(for: key),
                keyCode: returnKeyCode
            ) else {
                self.log("[TypingService] ERROR: Failed to create remote-desktop \(key.displayName) chord")
                return false
            }

            if resetKeyboardState {
                self.resyncRemoteDesktopKeyboardState()
                // The reset sleeps for well over 150ms and posts Escape globally, so the
                // destination has to be re-confirmed before Return - which activates whatever
                // now holds focus - rather than trusting the check made before the reset.
                //
                // The PID alone is not enough here: it cannot tell one connection window or
                // field of this client from another, and Return submits whatever it lands on.
                // So the exact element is required, matching the check the caller makes before
                // this and the one the typing path makes after its own reset.
                guard self.isRemoteDesktopTargetStillFrontmost(targetPID) else {
                    self.log("[TypingService] ERROR: Target lost focus during the keyboard reset; not sending \(key.displayName)")
                    return false
                }
                guard let requiredFocusTarget else {
                    self.log("[TypingService] ERROR: No focus target to re-confirm after the keyboard reset; not sending \(key.displayName)")
                    return false
                }
                guard Self.isExactFocusTargetActive(requiredFocusTarget) else {
                    self.log("[TypingService] ERROR: Focused element changed during the keyboard reset; not sending \(key.displayName)")
                    return false
                }
            }
            self.log("[TypingService] Spoken Send: posting \(key.displayName) chord via HID tap for remote-desktop target")
            self.postRemoteDesktopChord(chord)
            return true
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: false)
        else {
            return false
        }

        keyDown.flags = key.eventFlags
        keyUp.flags = key.eventFlags
        keyDown.setIntegerValueField(.eventSourceUserData, value: Self.synthesizedEventUserData)
        keyUp.setIntegerValueField(.eventSourceUserData, value: Self.synthesizedEventUserData)
        keyDown.postToPid(targetPID)
        usleep(10_000)
        keyUp.postToPid(targetPID)
        return true
    }

    private func tryReliablePasteInsertion(_ text: String, preferredTargetPID: pid_t?) -> Bool {
        if let preferredTargetPID, preferredTargetPID > 0 {
            self.log("[TypingService] Trying clipboard-to-PID insertion first")
            if self.insertTextViaClipboardToPid(text, targetPID: preferredTargetPID) {
                self.log("[TypingService] Reliable Paste dispatched via clipboard-to-PID")
                return true
            }
        }

        self.log("[TypingService] Trying global clipboard insertion")
        if self.insertTextViaClipboard(text) {
            self.log("[TypingService] Reliable Paste dispatched via global clipboard paste")
            return true
        }

        self.log("[TypingService] Global clipboard insertion failed, trying menu paste")
        if self.insertTextViaMenuPaste(text) {
            self.log("[TypingService] Reliable Paste dispatched via menu paste")
            return true
        }

        return false
    }

    private static let cgEventUnicodeChunkSize = 200

    private static func storeFocusSnapshot(_ snapshot: FocusSnapshot?) {
        self.focusSnapshotQueue.sync {
            Self.focusSnapshot = snapshot
        }
    }

    private static func loadFocusSnapshot() -> FocusSnapshot? {
        self.focusSnapshotQueue.sync { Self.focusSnapshot }
    }

    private static func copyAXElementAttribute(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func stringAXAttribute(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func currentFocusDebugDescription() -> String {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard result == .success, let focusedElementRef else {
            return "focusedElement=unavailable result=\(result.rawValue)"
        }
        guard CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else {
            return "focusedElement=unexpectedType"
        }

        let element = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let role = Self.stringAXAttribute(from: element, attribute: kAXRoleAttribute as CFString) ?? "unknown"
        let subrole = Self.stringAXAttribute(from: element, attribute: kAXSubroleAttribute as CFString) ?? "none"
        let title = Self.stringAXAttribute(from: element, attribute: kAXTitleAttribute as CFString) ?? "none"
        let description = Self.stringAXAttribute(from: element, attribute: kAXDescriptionAttribute as CFString) ?? "none"
        return "focusedPID=\(pid) role=\(role) subrole=\(subrole) title=\(title) description=\(description)"
    }

    private static func logFocusState(_ prefix: String) {
        guard self.isLoggingEnabled else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            DebugLogger.shared.info("TYPING_BENCH t=\(ProcessInfo.processInfo.systemUptime) focus_debug_query elapsedMs=\(Self.elapsedMs(since: startedAt))", source: "TypingBenchmark")
        }
        DebugLogger.shared.debug("\(prefix) | \(self.currentFocusDebugDescription())", source: "TypingService")
    }

    private static func isCurrentlyFocusedElement(_ expectedElement: AXUIElement, expectedPID: pid_t) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard result == .success, let focusedElementRef else { return false }
        guard CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else { return false }

        let currentElement = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        if CFEqual(currentElement, expectedElement) { return true }

        var currentPID: pid_t = 0
        AXUIElementGetPid(currentElement, &currentPID)
        guard currentPID == expectedPID else { return false }

        var currentRoleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            currentElement,
            kAXRoleAttribute as CFString,
            &currentRoleRef
        )
        guard roleResult == .success, let currentRole = currentRoleRef as? String else { return false }
        return ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea", "AXGroup"].contains(currentRole)
    }

    private func capturePasteboardSnapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [PasteboardItemSnapshot] = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return PasteboardItemSnapshot(dataByType: dataByType)
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let restoredItems = snapshot.items.map { snap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snap.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        _ = pasteboard.writeObjects(restoredItems)
    }

    /// Builds the pasteboard item for a temporary paste write, tagged with the nspasteboard.org
    /// Transient and AutoGenerated marker types so clipboard managers exclude it from history.
    /// `ConcealedType` is deliberately not used: it signals sensitive/password content, which
    /// would be misleading for a dictation transcript.
    static func makeTransientPasteboardItem(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        return item
    }

    private func withTemporaryPasteboardString(
        _ text: String,
        restoreDelayMicros: useconds_t,
        action: () -> Bool
    ) -> Bool {
        let pasteboardWaitStartedAt = ProcessInfo.processInfo.systemUptime
        Self.pasteboardSessionSemaphore.wait()
        self.bench("pasteboard_lock_acquired elapsedMs=\(Self.elapsedMs(since: pasteboardWaitStartedAt))")
        var releasesPasteboardSessionOnReturn = true
        defer {
            if releasesPasteboardSessionOnReturn {
                Self.pasteboardSessionSemaphore.signal()
            }
        }

        let pasteboard = NSPasteboard.general
        let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
        let snapshot = self.capturePasteboardSnapshot(pasteboard)
        self.bench("pasteboard_snapshot_done elapsedMs=\(Self.elapsedMs(since: snapshotStartedAt)) items=\(snapshot.items.count)")

        let writeStartedAt = ProcessInfo.processInfo.systemUptime
        pasteboard.clearContents()
        guard pasteboard.writeObjects([Self.makeTransientPasteboardItem(text)]) else {
            self.log("[TypingService] ERROR: Failed to set temporary clipboard string")
            self.restorePasteboardSnapshot(snapshot, to: pasteboard)
            return false
        }
        let temporaryChangeCount = pasteboard.changeCount
        self.bench("pasteboard_write_done elapsedMs=\(Self.elapsedMs(since: writeStartedAt))")
        let focusSnapshotStartedAt = ProcessInfo.processInfo.systemUptime
        let focusedTextSnapshot = self.captureFocusedTextSnapshot()
        self.bench("paste_focus_snapshot_done elapsedMs=\(Self.elapsedMs(since: focusSnapshotStartedAt))")
        let actionStartedAt = ProcessInfo.processInfo.systemUptime
        let actionResult = action()
        self.bench("paste_dispatch_done elapsedMs=\(Self.elapsedMs(since: actionStartedAt)) success=\(actionResult)")
        guard actionResult else {
            self.restorePasteboardSnapshot(snapshot, to: pasteboard)
            self.log("[TypingService] Restored previous clipboard snapshot after paste dispatch failure")
            return false
        }

        releasesPasteboardSessionOnReturn = false
        Self.pasteboardRestoreQueue.async {
            defer { Self.pasteboardSessionSemaphore.signal() }
            _ = self.waitForFocusedTextVerification(
                from: focusedTextSnapshot,
                expectedText: text,
                timeoutMicros: restoreDelayMicros
            )
            let pasteboard = NSPasteboard.general

            // Avoid clobbering user clipboard changes that happened after our insertion.
            if pasteboard.changeCount == temporaryChangeCount || pasteboard.string(forType: .string) == text {
                self.restorePasteboardSnapshot(snapshot, to: pasteboard)
                self.log("[TypingService] Restored previous clipboard snapshot")
            } else {
                self.log("[TypingService] Skipped clipboard restore because clipboard changed externally")
            }
        }

        return true
    }

    /// Clipboard-paste insertion targeted at a specific PID.
    /// Uses postToPid for Cmd+V while preserving the full previous pasteboard payload.
    private func insertTextViaClipboardToPid(_ text: String, targetPID: pid_t, activateTargetFirst: Bool = true) -> Bool {
        self.log("[TypingService] Starting clipboard-to-PID insertion to PID \(targetPID)")

        guard targetPID > 0 else {
            self.log("[TypingService] ERROR: Invalid target PID \(targetPID)")
            return false
        }

        let targetStartedAt = ProcessInfo.processInfo.systemUptime
        if activateTargetFirst, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            _ = Self.activateApp(pid: targetPID)
            usleep(80_000)
        }
        self.bench("paste_target_prepared elapsedMs=\(Self.elapsedMs(since: targetStartedAt))")

        return self.withTemporaryPasteboardString(text, restoreDelayMicros: 5_000_000) {
            let dispatchStartedAt = ProcessInfo.processInfo.systemUptime
            let vKey = Self.pasteVirtualKeyCode
            let keyResolvedAt = ProcessInfo.processInfo.systemUptime
            guard let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: true),
                  let cmdVUp = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: false)
            else {
                self.bench("paste_dispatch_failed route=pid stage=event_creation elapsedMs=\(Self.elapsedMs(since: keyResolvedAt))")
                self.log("[TypingService] ERROR: Failed to create Cmd+V events for PID insertion")
                return false
            }

            cmdVDown.flags = .maskCommand
            cmdVUp.flags = .maskCommand

            let eventsCreatedAt = ProcessInfo.processInfo.systemUptime
            cmdVDown.postToPid(targetPID)
            let keyDownFinishedAt = ProcessInfo.processInfo.systemUptime
            usleep(10_000)
            let waitFinishedAt = ProcessInfo.processInfo.systemUptime
            cmdVUp.postToPid(targetPID)
            let keyUpFinishedAt = ProcessInfo.processInfo.systemUptime
            self.bench(
                "paste_dispatch_phases route=pid keyLookupMs=\((keyResolvedAt - dispatchStartedAt) * 1000) " +
                    "eventCreateMs=\((eventsCreatedAt - keyResolvedAt) * 1000) keyDownMs=\((keyDownFinishedAt - eventsCreatedAt) * 1000) " +
                    "sleepMs=\((waitFinishedAt - keyDownFinishedAt) * 1000) keyUpMs=\((keyUpFinishedAt - waitFinishedAt) * 1000) " +
                    "totalMs=\((keyUpFinishedAt - dispatchStartedAt) * 1000)"
            )
            self.log("[TypingService] Cmd+V posted to PID \(targetPID)")
            return true
        }
    }

    // MARK: - Remote desktop targets (Windows App / Microsoft Remote Desktop)

    /// A synthetic chord: an optional modifier held across one key press.
    struct SyntheticChord {
        let modifierDown: CGEvent?
        let keyDown: CGEvent
        let keyUp: CGEvent
        let modifierUp: CGEvent?

        var ordered: [CGEvent] {
            [self.modifierDown, self.keyDown, self.keyUp, self.modifierUp].compactMap { $0 }
        }
    }

    /// Builds a chord for a remote-desktop target.
    ///
    /// Three details matter, and all three differ from the other paste paths in this file:
    ///
    /// 1. The chord includes the modifier's *own* key events. A client in Scancode mode
    ///    forwards key positions to the guest, so it has to see the modifier go down and up -
    ///    a key event that merely carries `.maskControl` gives it nothing to forward, which
    ///    matches the long-reported "pasting into RDP types the letter V" behaviour.
    /// 2. The modifier events are used exactly as created. `CGEvent(keyboardEventSource:
    ///    virtualKey:keyDown:)` already returns a `.flagsChanged` event for a modifier key
    ///    code, carrying the modifier flag, the device-side bit identifying which physical key
    ///    it is, and `.maskNonCoalesced`. Assigning `type` is a no-op and assigning `flags`
    ///    discards those bits, so we do neither - the held-modifier flags are copied off the
    ///    modifier event and *inserted* into the key events, reproducing what hardware sends
    ///    while a modifier is held.
    /// 3. Every event is tagged with ``synthesizedEventUserData``. FluidVoice's own event tap
    ///    listens for `flagsChanged` (`GlobalHotkeyManager.keyboardEventMask()`) and only lets
    ///    tagged events through untouched, so without the tag a modifier-only dictation
    ///    shortcut would read our synthetic modifier press as its own hotkey and start a
    ///    phantom recording on every dictation.
    nonisolated static func makeRemoteDesktopChord(
        modifierKeyCode: CGKeyCode?,
        keyCode: CGKeyCode
    ) -> SyntheticChord? {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            return nil
        }

        var modifierDown: CGEvent?
        var modifierUp: CGEvent?

        if let modifierKeyCode {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: modifierKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: modifierKeyCode, keyDown: false)
            else {
                return nil
            }

            // Copied off the modifier event rather than hard-coded: CoreGraphics has already
            // put both the modifier flag and the correct device-side bit there, including for
            // right-hand modifier key codes.
            keyDown.flags.insert(down.flags)
            keyUp.flags.insert(down.flags)

            modifierDown = down
            modifierUp = up
        }

        let chord = SyntheticChord(
            modifierDown: modifierDown,
            keyDown: keyDown,
            keyUp: keyUp,
            modifierUp: modifierUp
        )
        for event in chord.ordered {
            event.setIntegerValueField(.eventSourceUserData, value: self.synthesizedEventUserData)
        }
        return chord
    }

    /// The modifier key code that produces `key`'s intent as a real chord in the *guest*, so a
    /// remote-desktop client has a modifier scan code to forward. Returns nil for plain Return.
    ///
    /// Command is deliberately translated to Control rather than forwarded as-is. The client
    /// forwards the Command position as the Windows key, so a literal Command+Enter arrives as
    /// Win+Enter - which is an operating-system shortcut in Windows and never submits. Control
    /// is the modifier that carries the same meaning in the guest, and is the mapping the client
    /// itself applies for copy, cut and paste.
    nonisolated static func spokenSendModifierKeyCode(for key: SettingsStore.SpokenSendKey) -> CGKeyCode? {
        switch key {
        case .enter: nil
        case .shiftEnter: CGKeyCode(kVK_Shift)
        case .commandEnter: CGKeyCode(kVK_Control)
        }
    }

    /// Posts a chord to the HID tap. These clients do not act on `postToPid` keyboard events.
    private func postRemoteDesktopChord(_ chord: SyntheticChord, keyGapMicros: useconds_t = 10_000) {
        // Release the modifier no matter how we leave this scope. A stuck synthetic modifier
        // shows up in `CGEventSource.flagsState(.combinedSessionState)` and would make the next
        // dictation's `waitForPhysicalModifiersToRelease` time out.
        defer { chord.modifierUp?.post(tap: .cghidEventTap) }

        chord.modifierDown?.post(tap: .cghidEventTap)
        chord.keyDown.post(tap: .cghidEventTap)
        usleep(keyGapMicros)
        chord.keyUp.post(tap: .cghidEventTap)
    }

    /// Why a remote-desktop typing attempt did not produce text.
    enum RemoteDesktopTypingOutcome {
        /// The transcript was typed in full.
        case typed
        /// The layout cannot express some characters; the lossless clipboard path is worth trying.
        case unmappable
        /// Something else prevented typing. Trying the clipboard path would not help.
        case declined
    }

    /// Types `text` into a remote-desktop session as real key presses, never touching the
    /// clipboard.
    ///
    /// This is the primary path for these targets because clipboard redirection is not usable:
    /// the client only re-advertises its clipboard to the guest after a focus change, so a
    /// programmatic pasteboard write followed by a paste makes the guest insert whatever it
    /// last synced. Typing has no such dependency - the guest receives key positions directly.
    ///
    /// The cost is reach: the guest applies its own layout to those positions, and only
    /// characters the local layout can produce with at most shift can be expressed at all.
    private func insertTextViaRemoteDesktopTyping(
        _ text: String,
        targetPID: pid_t
    ) -> RemoteDesktopTypingOutcome {
        let normalized = RemoteDesktopKeyMapResolver.transliterate(text)
        // Snapshot, never a live lookup: this runs on a background queue and reading the input
        // source from here can trap inside HIToolbox.
        let map = Self.remoteDesktopLayoutCache.snapshot().typable
        if map.isEmpty {
            self.log("[TypingService] Layout offers no directly typable characters; the paste fallback will carry this transcript")
        }

        let strokes: [RemoteDesktopKeyStroke]
        let capsLockActive = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        if capsLockActive {
            self.log("[TypingService] Caps Lock is active; inverting shift for alphabetic keys")
        }

        switch RemoteDesktopKeyMapResolver.plan(for: normalized, map: map, capsLockActive: capsLockActive) {
        case let .strokes(planned):
            strokes = planned
        case let .unmappable(characters):
            let described = characters
                .map { "U+" + String($0.unicodeScalars.first?.value ?? 0, radix: 16, uppercase: true) }
                .joined(separator: " ")
            self.log("[TypingService] Remote-desktop typing skipped: \(characters.count) character(s) have no key on this layout (\(described))")
            return .unmappable
        }

        // Posting a chord while the user still physically holds a modifier merges the two, and
        // over a whole transcript that would corrupt every character.
        guard self.waitForPhysicalModifiersToRelease(timeout: 2) else {
            self.log("[TypingService] ERROR: Physical modifiers still held; skipping remote-desktop typing")
            return .declined
        }


        // The reset is itself a batch of global HID events, including possibly Escape, so the
        // destination has to be confirmed before it is posted - otherwise a focus change between
        // resolving the target and starting the run sends Escape to some other application and
        // cancels whatever it had open. The per-chord checks below cover only the typing.
        guard self.isRemoteDesktopTargetStillFrontmost(targetPID) else {
            self.log("[TypingService] ERROR: Target is not frontmost; skipping remote-desktop reset and typing")
            return .declined
        }

        // Captured *before* the reset and the warm-up below, not after. Those take up to three
        // seconds together, and a PID cannot tell one connection window of this client from
        // another - so a baseline taken afterwards would adopt whichever session the user had
        // switched to during the wait, and every later check would then agree with it and send
        // the whole transcript to the wrong remote machine.
        //
        // Required, not optional. Without an element there is nothing but the PID to check, and
        // the PID cannot see a connection switch at all. Only insist on it when Accessibility is
        // actually trusted: untrusted is a different failure that is already refused upstream,
        // and a nil element there says nothing about the destination.
        let focusTarget = Self.captureSystemFocusTarget()
        if focusTarget == nil, AXIsProcessTrusted() {
            self.log("[TypingService] ERROR: No focused element for the remote session; refusing to type blind")
            return .declined
        }

        // The hotkey that started this dictation is very often a modifier (the default is
        // modifier-only), and the client forwards that modifier's press and release to the guest
        // independently. Until the guest processes the release it still believes the modifier is
        // held, so post an explicit release for every modifier and then wait before typing.
        // Without this the first character arrives as a modifier chord and is swallowed.
        self.resyncRemoteDesktopKeyboardState()
        let warmupMicros = Self.remoteDesktopWarmup
        if warmupMicros > 0 {
            self.log("[TypingService] Warming up remote keyboard channel for \(warmupMicros / 1000)ms")
            usleep(warmupMicros)
        }

        // Built up front for two reasons: a creation failure aborts before anything is typed,
        // and a nil-source CGEvent captures the combined-session modifier flags at creation, so
        // building them all now - after the modifier wait - guarantees every event carries clean
        // flags rather than picking up a previous synthetic shift that is still in flight.
        var chords: [SyntheticChord] = []
        chords.reserveCapacity(strokes.count)
        for stroke in strokes {
            guard let chord = Self.makeRemoteDesktopChord(
                modifierKeyCode: stroke.needsShift ? CGKeyCode(kVK_Shift) : nil,
                keyCode: stroke.keyCode
            ) else {
                self.log("[TypingService] ERROR: Failed to create remote-desktop typing events")
                return .declined
            }
            chords.append(chord)
        }

        // Re-confirmed here because the baseline was taken before the reset and warm-up: this is
        // the check that catches a connection switch made during that window.
        if let focusTarget, Self.isExactFocusTargetActive(focusTarget) == false {
            self.log("[TypingService] ERROR: Focused element changed during the reset or warm-up; not typing")
            return .declined
        }

        let perCharacterDelay = Self.remoteDesktopTypeDelay
        self.log("[TypingService] Typing \(chords.count) character(s) via HID tap at \(perCharacterDelay / 1000)ms/char")

        // Checked before *every* chord, not on an interval. These events are delivered by the
        // window server to whatever holds key focus, so any unchecked gap is a window in which
        // transcript characters land in another application. `frontmostApplication` is a local
        // lookup, not an Accessibility round trip, so this is cheap enough to do per character.
        for (index, chord) in chords.enumerated() {
            guard self.isRemoteDesktopTargetStillFrontmost(targetPID) else {
                self.log("[TypingService] ERROR: Target lost focus after \(index) character(s); stopping")
                return .declined
            }
            if let focusTarget, index > 0, index % Self.remoteDesktopElementRecheckInterval == 0,
               Self.isExactFocusTargetActive(focusTarget) == false
            {
                self.log("[TypingService] ERROR: Focused window changed after \(index) character(s); stopping")
                return .declined
            }
            self.postRemoteDesktopChord(chord, keyGapMicros: 1500)
            usleep(perCharacterDelay)
        }

        self.log("[TypingService] Remote-desktop typing completed")
        return .typed
    }

    /// Puts the guest's keyboard back into a state where plain characters insert text.
    ///
    /// Two things have to be undone, both caused by the dictation hotkey rather than by us:
    ///
    /// 1. A held modifier. The client forwards the hotkey modifier's press and release to the
    ///    guest independently, so a lost release leaves the guest believing it is still down and
    ///    every subsequent letter becomes a chord.
    /// 2. Windows menu mode. This is the one that actually bites. An Option-based hotkey looks
    ///    to the guest like a *bare Alt tap* - FluidVoice swallows the accompanying key as its
    ///    hotkey, so the guest sees Alt down then Alt up with nothing between - and a bare Alt
    ///    tap activates the focused window's menu bar. The transcript then navigates menus
    ///    instead of typing: measured, `E` opens the Edit menu and the rest of the text is
    ///    consumed. Escape exits menu mode.
    ///
    /// Escape rather than a second Alt tap on purpose. Both were measured to fix it, but an Alt
    /// tap is a *toggle*: if menu mode were not active it would switch it on and cause exactly
    /// the bug it is meant to prevent. Escape only ever exits, so it cannot create the bad
    /// state. Waiting does not help - measured - because this is a mode, not latency.
    ///
    /// Escape is sent here as a deliberate reset, which is separate from the rule that Return
    /// and Tab are never typed as transcript *content*.
    /// Whether the configured dictation hotkey can leave the guest in a menu state.
    ///
    /// A bare Alt tap activates the menu bar and a bare Windows-key tap opens the Start menu, so
    /// only Option- and Command-based hotkeys create something for Escape to dismiss. For any
    /// other hotkey an unconditional Escape would be a gratuitous keypress into the guest, where
    /// it can cancel a dialog or abandon an in-progress operation.
    private var remoteDesktopHotkeyCanEnterMenuMode: Bool {
        // Prefer what was actually held when this dictation started. Asking whether *any*
        // configured shortcut uses Option or Command would send Escape for a dictation begun
        // with a mouse or a plain-key shortcut, where there is no menu to dismiss.
        // A non-empty reading is trustworthy: something was genuinely held. An *empty* one is
        // not, because the sample is taken when capture starts rather than when the hotkey
        // fires - and a modifier-only shortcut in toggle mode only starts recording once the
        // modifier is released, so the flags are already gone by then. Treating empty as "no
        // modifier" would skip Escape for exactly the default shortcut that needs it most, so
        // it falls through to the configured-shortcut check instead.
        // Caps Lock and the numeric-pad bit can be set without any key being held, so compare
        // against the modifiers a shortcut can actually use rather than against an empty set.
        let heldModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        if let observed = Self.consumeDictationHotkeyModifiers(),
           observed.intersection(heldModifiers).isEmpty == false
        {
            return observed.contains(.maskAlternate) || observed.contains(.maskCommand)
        }

        // Nothing recorded, or already consumed. Fall back to the configured shortcuts, which
        // is over-broad but errs the safer way: failing to leave menu mode means the transcript
        // navigates menus and can act on the guest, whereas an unnecessary Escape only cancels.
        let shortcuts = SettingsStore.shared.primaryDictationShortcuts
        guard shortcuts.isEmpty == false else { return true }
        return shortcuts.contains { shortcut in
            shortcut.modifierFlags.contains(.option) || shortcut.modifierFlags.contains(.command)
        }
    }

    private func resyncRemoteDesktopKeyboardState() {
        for keyCode in Self.remoteDesktopResyncModifierKeyCodes {
            guard let release = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                continue
            }
            // Created as a `flagsChanged` already; only the tag is added so FluidVoice's own
            // event tap ignores it.
            release.setIntegerValueField(.eventSourceUserData, value: Self.synthesizedEventUserData)
            release.post(tap: .cghidEventTap)
        }

        guard self.remoteDesktopHotkeyCanEnterMenuMode else {
            self.log("[TypingService] Reset remote keyboard state (modifier releases only; hotkey cannot enter menu mode)")
            return
        }

        usleep(Self.remoteDesktopEscapeGapMicros)

        if let escapeDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: true),
           let escapeUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: false)
        {
            escapeDown.setIntegerValueField(.eventSourceUserData, value: Self.synthesizedEventUserData)
            escapeUp.setIntegerValueField(.eventSourceUserData, value: Self.synthesizedEventUserData)
            escapeDown.post(tap: .cghidEventTap)
            usleep(10_000)
            escapeUp.post(tap: .cghidEventTap)
        }

        self.log("[TypingService] Reset remote keyboard state (modifier releases + Escape)")
    }

    private func isRemoteDesktopTargetStillFrontmost(_ targetPID: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
    }

    /// Clipboard paste for a remote-desktop session.
    ///
    /// Differs from ``insertTextViaClipboardToPid`` in the three ways that make it work here:
    /// the chord goes to the HID tap rather than `postToPid`, it is a complete Ctrl+V chord
    /// rather than a flag-carrying `v`, and it waits for the client to notice the pasteboard
    /// before firing.
    ///
    /// Ctrl+V rather than Cmd+V on purpose: Cmd+V depends on the client's "Use Mac shortcuts
    /// for copy, cut, paste" setting being on, and if the chord ever lands on the client's own
    /// local UI instead of the session canvas, Ctrl+V is a harmless no-op there whereas Cmd+V
    /// would paste into it.
    private func insertTextViaRemoteDesktopPaste(_ text: String, targetPID: pid_t) -> Bool {
        self.log("[TypingService] Starting remote-desktop paste insertion to PID \(targetPID)")

        // Posting a modifier chord while the user still physically holds a modifier merges the
        // two into a different chord, so refuse rather than send something wrong.
        guard self.waitForPhysicalModifiersToRelease(timeout: 2) else {
            self.log("[TypingService] ERROR: Physical modifiers still held; skipping remote-desktop paste")
            return false
        }

        // Checked before the pasteboard is written so a doomed attempt does not churn the
        // user's clipboard.
        guard self.isRemoteDesktopTargetStillFrontmost(targetPID) else {
            self.log("[TypingService] ERROR: Target is not frontmost; skipping remote-desktop paste")
            return false
        }

        guard let target = NSRunningApplication(processIdentifier: targetPID) else {
            self.log("[TypingService] ERROR: Remote-desktop target no longer running")
            return false
        }

        // Resolved before anything below has an effect. This used to be checked after the
        // pasteboard had been written and focus had been bounced away for two seconds, so a
        // layout with no usable paste position churned the user's clipboard and stole focus
        // and then inserted nothing at all.
        guard let pasteKeyCode = Self.remoteDesktopLayoutCache.snapshot().pasteKeyCode else {
            self.log("[TypingService] ERROR: No trustworthy position for the paste key on this layout; refusing to press an unknown key")
            return false
        }

        // The bounce below deliberately takes focus away for roughly two seconds. A PID alone
        // cannot tell one window or session of the same client from another, so capture the
        // focused element itself and require the *same* element afterwards.
        let focusTargetBeforeBounce = Self.captureSystemFocusTarget()

        return self.withTemporaryPasteboardString(text, restoreDelayMicros: 5_000_000) {
            usleep(Self.remoteDesktopClipboardSettleMicros)

            // These clients only re-advertise their clipboard to the guest after a focus
            // change, so without this the guest pastes whatever it last synced. Measured: a
            // re-activation of the already-frontmost client is not enough; focus has to
            // actually leave and come back, and it needs over a second to settle.
            NSRunningApplication.current.activate(options: Self.focusRestoreActivationOptions)
            usleep(400_000)

            // If focus never actually left, the client has not re-advertised anything and the
            // chord would paste whatever the guest last synced - someone else's clipboard
            // content, into their session. Refuse rather than paste the wrong text.
            guard self.isRemoteDesktopTargetStillFrontmost(targetPID) == false else {
                self.log("[TypingService] ERROR: Focus never left the target; refusing to paste possibly stale content")
                return false
            }

            target.activate(options: Self.focusRestoreActivationOptions)
            usleep(1_500_000)
            self.log("[TypingService] Bounced focus to force clipboard re-advertise")

            guard self.isRemoteDesktopTargetStillFrontmost(targetPID) else {
                self.log("[TypingService] ERROR: Target not frontmost after focus bounce; skipping paste")
                return false
            }

            // Same application is not enough: the paste is a single global chord carrying the
            // whole transcript, so require the identical focused element we captured. If it
            // cannot be confirmed, abort - `withTemporaryPasteboardString` restores the
            // clipboard, and the transcript is still in History.
            guard let focusTargetBeforeBounce else {
                self.log("[TypingService] ERROR: No focus target was captured; refusing to paste blind")
                return false
            }
            guard Self.isExactFocusTargetActive(focusTargetBeforeBounce) else {
                self.log("[TypingService] ERROR: Focused element changed across the bounce; skipping paste")
                return false
            }

            guard self.waitForPhysicalModifiersToRelease(timeout: 0.5) else {
                self.log("[TypingService] ERROR: Physical modifiers held after bounce; skipping remote-desktop paste")
                return false
            }

            guard let chord = Self.makeRemoteDesktopChord(
                modifierKeyCode: CGKeyCode(kVK_Control),
                keyCode: pasteKeyCode
            ) else {
                self.log("[TypingService] ERROR: Failed to create remote-desktop paste chord")
                return false
            }

            self.log("[TypingService] Posting Ctrl+V chord via HID tap")
            self.postRemoteDesktopChord(chord)
            return true
        }
    }

    private func insertTextBulkInstant(_ text: String, targetPID: pid_t) -> Bool {
        self.log("[TypingService] Starting chunked bulk CGEvent insertion (NO CLIPBOARD) to PID \(targetPID)")

        guard targetPID > 0 else {
            self.log("[TypingService] ERROR: Invalid target PID \(targetPID)")
            return false
        }

        let utf16Array = Array(text.utf16)
        self.log("[TypingService] Converting \(text.count) characters to CGEvents (UTF16 count \(utf16Array.count))")

        return self.postUnicodeChunks(utf16Array, destinationDescription: "PID \(targetPID)") { event in
            event.postToPid(targetPID)
        }
    }

    private func insertTextBulkHIDInstant(_ text: String) -> Bool {
        self.log("[TypingService] Starting chunked bulk CGEvent insertion via HID (NO PID)")

        let utf16Array = Array(text.utf16)

        return self.postUnicodeChunks(utf16Array, destinationDescription: "HID tap") { event in
            event.post(tap: .cghidEventTap)
        }
    }

    private func postUnicodeChunks(
        _ utf16Array: [UInt16],
        destinationDescription: String,
        post: (CGEvent) -> Void
    ) -> Bool {
        guard utf16Array.isEmpty == false else { return true }

        let chunkCount: Int = utf16Array.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }

            var chunkStart = 0
            var chunkCount = 0
            while chunkStart < buffer.count {
                let chunkEnd = Self.unicodeChunkEnd(in: utf16Array, start: chunkStart)
                let chunkLength = chunkEnd - chunkStart

                guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                else {
                    self.log("[TypingService] ERROR: Failed to create unicode chunk CGEvents")
                    return -1
                }

                let chunkPointer = baseAddress.advanced(by: chunkStart)
                keyDown.keyboardSetUnicodeString(stringLength: chunkLength, unicodeString: chunkPointer)
                keyUp.keyboardSetUnicodeString(stringLength: chunkLength, unicodeString: chunkPointer)

                post(keyDown)
                post(keyUp)

                chunkStart = chunkEnd
                chunkCount += 1
            }
            return chunkCount
        }

        guard chunkCount >= 0 else { return false }

        self.log("[TypingService] Posted \(chunkCount) unicode CGEvent chunk(s) to \(destinationDescription) with chunkSize=\(Self.cgEventUnicodeChunkSize) interChunkDelayMs=0")
        return true
    }

    private static func unicodeChunkEnd(in utf16Array: [UInt16], start: Int) -> Int {
        var end = min(start + Self.cgEventUnicodeChunkSize, utf16Array.count)
        if end < utf16Array.count,
           end > start,
           Self.isHighSurrogate(utf16Array[end - 1]),
           Self.isLowSurrogate(utf16Array[end])
        {
            end -= 1
        }
        return max(end, start + 1)
    }

    private static func isHighSurrogate(_ value: UInt16) -> Bool {
        (0xd800...0xdbff).contains(value)
    }

    private static func isLowSurrogate(_ value: UInt16) -> Bool {
        (0xdc00...0xdfff).contains(value)
    }

    /// Clipboard-based text insertion as fallback
    /// More reliable but slightly slower - copies text to clipboard then pastes
    private func insertTextViaClipboard(_ text: String) -> Bool {
        self.log("[TypingService] Starting clipboard-based insertion")
        return self.withTemporaryPasteboardString(text, restoreDelayMicros: 5_000_000) {
            let dispatchStartedAt = ProcessInfo.processInfo.systemUptime
            let vKey = Self.pasteVirtualKeyCode
            let keyResolvedAt = ProcessInfo.processInfo.systemUptime
            guard let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: true),
                  let cmdVUp = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: false)
            else {
                self.bench("paste_dispatch_failed route=global stage=event_creation elapsedMs=\(Self.elapsedMs(since: keyResolvedAt))")
                self.log("[TypingService] ERROR: Failed to create Cmd+V events")
                return false
            }

            cmdVDown.flags = .maskCommand
            cmdVUp.flags = .maskCommand

            let eventsCreatedAt = ProcessInfo.processInfo.systemUptime
            cmdVDown.post(tap: .cghidEventTap)
            let keyDownFinishedAt = ProcessInfo.processInfo.systemUptime
            usleep(10_000)
            let waitFinishedAt = ProcessInfo.processInfo.systemUptime
            cmdVUp.post(tap: .cghidEventTap)
            let keyUpFinishedAt = ProcessInfo.processInfo.systemUptime
            self.bench(
                "paste_dispatch_phases route=global keyLookupMs=\((keyResolvedAt - dispatchStartedAt) * 1000) " +
                    "eventCreateMs=\((eventsCreatedAt - keyResolvedAt) * 1000) keyDownMs=\((keyDownFinishedAt - eventsCreatedAt) * 1000) " +
                    "sleepMs=\((waitFinishedAt - keyDownFinishedAt) * 1000) keyUpMs=\((keyUpFinishedAt - waitFinishedAt) * 1000) " +
                    "totalMs=\((keyUpFinishedAt - dispatchStartedAt) * 1000)"
            )
            self.log("[TypingService] Cmd+V sent via clipboard insertion")
            return true
        }
    }

    private func insertTextViaMenuPaste(_ text: String) -> Bool {
        self.log("[TypingService] Starting menu-based paste insertion")
        guard let appName = NSWorkspace.shared.frontmostApplication?.localizedName, !appName.isEmpty else {
            self.log("[TypingService] ERROR: No frontmost app name available for menu paste")
            return false
        }

        return self.withTemporaryPasteboardString(text, restoreDelayMicros: 5_000_000) {
            let escapedAppName = appName.replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "System Events"
                tell process "\(escapedAppName)"
                    click menu item "Paste" of menu "Edit" of menu bar 1
                end tell
            end tell
            """

            guard let appleScript = NSAppleScript(source: script) else {
                self.log("[TypingService] ERROR: Failed to create AppleScript for menu paste")
                return false
            }

            var errorInfo: NSDictionary?
            let result = appleScript.executeAndReturnError(&errorInfo)
            if let errorInfo {
                self.log("[TypingService] ERROR: Menu paste AppleScript failed: \(errorInfo)")
                return false
            }

            self.log("[TypingService] Menu paste executed for app \(appName), result: \(result.stringValue ?? "ok")")
            return true
        }
    }

    private func insertTextViaAccessibility(_ text: String) -> Bool {
        self.log("[TypingService] Starting Accessibility API insertion")

        // Try multiple strategies to find text input element

        // Strategy 1: Get focused element directly (system-wide)
        self.log("[TypingService] Strategy 1: Getting focused UI element...")
        if let textElement = getFocusedTextElement() {
            self.log("[TypingService] Found focused text element")
            if self.tryAllTextInsertionMethods(textElement, text) {
                return true
            }
        }

        // Strategy 2: Traverse frontmost app UI hierarchy to find text elements
        self.log("[TypingService] Strategy 2: Traversing app UI hierarchy...")
        if let textElement = findTextElementInFrontmostApp() {
            self.log("[TypingService] Found text element in app hierarchy")
            if self.tryAllTextInsertionMethods(textElement, text) {
                return true
            }
        }

        // Strategy 3: Find element with keyboard focus
        self.log("[TypingService] Strategy 3: Looking for keyboard focus...")
        if let textElement = findKeyboardFocusedElement() {
            self.log("[TypingService] Found keyboard focused element")
            if self.tryAllTextInsertionMethods(textElement, text) {
                return true
            }
        }

        self.log("[TypingService] All Accessibility API strategies failed")
        return false
    }

    private func getFocusedTextElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result == .success, let focusedElement {
            guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
            let axElement = unsafeBitCast(focusedElement, to: AXUIElement.self)
            if let role = getElementAttribute(axElement, kAXRoleAttribute as CFString) {
                self.log("[TypingService] Found focused element with role: \(role)")
                return axElement
            }
        } else {
            self.log("[TypingService] Could not get focused UI element - result: \(result.rawValue)")
        }

        return nil
    }

    private func findTextElementInFrontmostApp() -> AXUIElement? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            self.log("[TypingService] Could not get frontmost app")
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        return self.findTextElementRecursively(appElement, depth: 0, maxDepth: 8)
    }

    private func findTextElementRecursively(_ element: AXUIElement, depth: Int, maxDepth: Int) -> AXUIElement? {
        if depth > maxDepth { return nil }

        // Check if this element is a text input element
        if let role = getElementAttribute(element, kAXRoleAttribute as CFString) {
            let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXStaticText"]
            if textRoles.contains(role) {
                self.log("[TypingService] Found text element at depth \(depth) with role: \(role)")
                return element
            }
        }

        // Get children and search recursively
        var children: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)

        if result == .success, let childrenArray = children as? [AXUIElement] {
            for child in childrenArray.prefix(10) { // Limit to first 10 children per level
                if let found = findTextElementRecursively(child, depth: depth + 1, maxDepth: maxDepth) {
                    return found
                }
            }
        }

        return nil
    }

    private func findKeyboardFocusedElement() -> AXUIElement? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        var focusedElement: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result == .success, let focusedElement {
            guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
            let axElement = unsafeBitCast(focusedElement, to: AXUIElement.self)
            if let role = getElementAttribute(axElement, kAXRoleAttribute as CFString) {
                self.log("[TypingService] Found app-level focused element with role: \(role)")
                return axElement
            }
        }

        return nil
    }

    private func tryAllTextInsertionMethods(_ element: AXUIElement, _ text: String) -> Bool {
        // Get element info for debugging
        if let role = getElementAttribute(element, kAXRoleAttribute as CFString) {
            self.log("[TypingService] Trying insertion on element with role: \(role)")

            if let title = getElementAttribute(element, kAXTitleAttribute as CFString) {
                self.log("[TypingService] Element title: \(title)")
            }
        }

        self.log("[TypingService] Trying approach 0: Insert at cursor via kAXSelectedTextRangeAttribute + kAXValueAttribute")
        if self.insertTextAtCursorUsingSelectedRange(element, text) {
            return true
        }

        // Try multiple approaches for text insertion
        self.log("[TypingService] Trying approach 1: Direct kAXValueAttribute")
        if self.setTextViaValue(element, text) {
            return true
        }

        self.log("[TypingService] Trying approach 2: kAXSelectedTextAttribute (replace selection)")
        if self.setTextViaSelection(element, text) {
            return true
        }

        self.log("[TypingService] Trying approach 3: Insert text at insertion point")
        if self.insertTextAtInsertionPoint(element, text) {
            return true
        }

        return false
    }

    private func getElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        if result == .success, let stringValue = value as? String {
            return stringValue
        }
        return nil
    }

    private func getSystemFocusedElementAndPID() -> (element: AXUIElement, pid: pid_t)? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        guard result == .success, let focusedElementRef else { return nil }
        guard CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else { return nil }

        let element = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0 else { return nil }
        return (element: element, pid: pid)
    }

    private func getElementStringValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success, let str = value as? String else { return nil }
        return str
    }

    private func getSelectedTextRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        guard CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }

        var range = CFRange()
        let ok = AXValueGetValue(unsafeBitCast(axValue, to: AXValue.self), .cfRange, &range)
        return ok ? range : nil
    }

    private func captureFocusedTextSnapshot() -> FocusedTextSnapshot? {
        guard let focusInfo = self.getSystemFocusedElementAndPID() else { return nil }
        let bundleIdentifier = NSRunningApplication(processIdentifier: focusInfo.pid)?.bundleIdentifier
        let appScriptSnapshot = self.captureAppScriptTextSnapshot(forBundleIdentifier: bundleIdentifier)
        return FocusedTextSnapshot(
            pid: focusInfo.pid,
            bundleIdentifier: bundleIdentifier,
            value: self.getElementStringValue(focusInfo.element),
            selectedRange: self.getSelectedTextRange(focusInfo.element),
            appScriptValue: appScriptSnapshot?.value,
            appScriptSelectedRange: appScriptSnapshot?.selectedRange
        )
    }

    private func captureTextBeforeCursorInFocusedField() -> String {
        guard let snapshot = self.captureFocusedTextSnapshot() else { return "" }

        if let scriptValue = snapshot.appScriptValue,
           let scriptRange = snapshot.appScriptSelectedRange
        {
            return Self.prefix(in: scriptValue, before: scriptRange.location)
        }

        if let value = snapshot.value,
           let selectedRange = snapshot.selectedRange
        {
            return Self.prefix(in: value, before: selectedRange.location)
        }

        return ""
    }

    private static func prefix(in text: String, before location: Int) -> String {
        let nsText = text as NSString
        let safeLocation = max(0, min(location, nsText.length))
        guard safeLocation > 0 else { return "" }
        return nsText.substring(with: NSRange(location: 0, length: safeLocation))
    }

    private struct AppScriptTextSnapshot {
        let value: String?
        let selectedRange: CFRange?
    }

    private func waitForFocusedTextVerification(
        from snapshot: FocusedTextSnapshot?,
        expectedText: String,
        timeoutMicros: useconds_t
    ) -> PasteVerificationResult {
        guard let snapshot else {
            usleep(timeoutMicros)
            return .unavailable
        }

        let pollMicros: useconds_t = 50_000
        let expectedLength = max(1, (expectedText as NSString).length)
        let tolerance = max(2, expectedLength / 5)
        var waited: useconds_t = 0

        while waited < timeoutMicros {
            usleep(pollMicros)
            waited += pollMicros

            guard let current = self.captureFocusedTextSnapshot(),
                  current.pid == snapshot.pid
            else {
                continue
            }

            if let currentValue = current.appScriptValue,
               currentValue.contains(expectedText),
               currentValue != snapshot.appScriptValue
            {
                return .appScriptContainsText
            }

            if let before = snapshot.appScriptSelectedRange,
               let after = current.appScriptSelectedRange,
               after.length == 0
            {
                let expectedCaretLocation = before.location + expectedLength
                let caretDelta = abs(after.location - expectedCaretLocation)
                if caretDelta <= tolerance {
                    return .appScriptCaretMovedExpectedDistance
                }
            }

            if let currentValue = current.value,
               currentValue.contains(expectedText),
               currentValue != snapshot.value
            {
                return .fieldContainsText
            }

            if let before = snapshot.selectedRange,
               let after = current.selectedRange,
               after.length == 0
            {
                let expectedCaretLocation = before.location + expectedLength
                let caretDelta = abs(after.location - expectedCaretLocation)
                if caretDelta <= tolerance {
                    return .caretMovedExpectedDistance
                }
            }
        }

        return .timeout
    }

    private func captureAppScriptTextSnapshot(forBundleIdentifier bundleIdentifier: String?) -> AppScriptTextSnapshot? {
        switch bundleIdentifier {
        case "com.apple.dt.Xcode":
            return self.captureXcodeScriptSnapshot()
        case "com.apple.Notes":
            return self.captureNotesScriptSnapshot()
        default:
            return nil
        }
    }

    private func captureXcodeScriptSnapshot() -> AppScriptTextSnapshot? {
        guard let value = self.runAppleScript("""
        tell application "Xcode"
            if (count of source documents) is 0 then return ""
            return text of source document 1
        end tell
        """) else {
            return nil
        }

        let selectedRange = self.runAppleScript("""
        tell application "Xcode"
            if (count of source documents) is 0 then return ""
            return selected character range of source document 1
        end tell
        """).flatMap(self.parseAppleScriptRange)

        return AppScriptTextSnapshot(value: value, selectedRange: selectedRange)
    }

    private func captureNotesScriptSnapshot() -> AppScriptTextSnapshot? {
        guard let value = self.runAppleScript("""
        tell application "Notes"
            set selectedNotes to selection as list
            if (count of selectedNotes) is 0 then return ""
            set noteId to id of item 1 of selectedNotes
            return plaintext of note id noteId
        end tell
        """) else {
            return nil
        }
        return AppScriptTextSnapshot(value: value, selectedRange: nil)
    }

    private func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            self.log("[TypingService] AppleScript verification failed: \(error)")
            return nil
        }
        return result.stringValue
    }

    private func parseAppleScriptRange(_ rawValue: String) -> CFRange? {
        let components = rawValue
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard components.count == 2 else { return nil }
        let start = max(0, components[0] - 1)
        let end = max(start, components[1] - 1)
        return CFRange(location: start, length: end - start)
    }

    private func insertTextAtCursorUsingSelectedRange(_ element: AXUIElement, _ text: String) -> Bool {
        guard let currentValue = self.getElementStringValue(element) else {
            self.log("[TypingService] Cursor insert failed: could not read kAXValueAttribute")
            return false
        }
        guard var range = self.getSelectedTextRange(element) else {
            self.log("[TypingService] Cursor insert failed: could not read kAXSelectedTextRangeAttribute")
            return false
        }

        // CFRange is in UTF16 units. Use NSString to apply NSRange safely.
        let currentNSString = currentValue as NSString
        let maxLen = currentNSString.length

        let safeLoc = max(0, min(range.location, maxLen))
        let safeLen = max(0, min(range.length, maxLen - safeLoc))
        range = CFRange(location: safeLoc, length: safeLen)

        let mutable = NSMutableString(string: currentValue)
        mutable.replaceCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        let newValue = mutable as String

        let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFString)
        guard setResult == .success else {
            self.log("[TypingService] Cursor insert failed: setting kAXValueAttribute error \(setResult.rawValue)")
            return false
        }

        // Move caret to just after inserted text (best-effort)
        let insertedLen = (text as NSString).length
        var newRange = CFRange(location: range.location + insertedLen, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }

        self.log("[TypingService] SUCCESS: Inserted text using selected range + value")
        return true
    }

    // Why is it working now? And why is it not working now?
    private func setTextViaValue(_ element: AXUIElement, _ text: String) -> Bool {
        let cfText = text as CFString
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, cfText)

        if result == .success {
            self.log("[TypingService] SUCCESS: Set text via kAXValueAttribute")
            return true
        } else {
            self.log("[TypingService] FAILED: kAXValueAttribute - error: \(result.rawValue)")
            return false
        }
    }

    private func setTextViaSelection(_ element: AXUIElement, _ text: String) -> Bool {
        // First, select all existing text
        let selectAllResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, "" as CFString)
        self.log("[TypingService] Select all result: \(selectAllResult.rawValue)")

        // Then replace the selection with our text
        let cfText = text as CFString
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, cfText)

        if result == .success {
            self.log("[TypingService] SUCCESS: Set text via kAXSelectedTextAttribute")
            return true
        } else {
            self.log("[TypingService] FAILED: kAXSelectedTextAttribute - error: \(result.rawValue)")
            return false
        }
    }

    private func insertTextAtInsertionPoint(_ element: AXUIElement, _ text: String) -> Bool {
        // Try to get the insertion point
        var insertionPoint: CFTypeRef?
        let getResult = AXUIElementCopyAttributeValue(element, kAXInsertionPointLineNumberAttribute as CFString, &insertionPoint)
        self.log("[TypingService] Get insertion point result: \(getResult.rawValue)")

        // Try to insert text using parameterized attribute
        let cfText = text as CFString
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, cfText)

        if result == .success {
            self.log("[TypingService] SUCCESS: Inserted text at insertion point")
            return true
        } else {
            self.log("[TypingService] FAILED: Insertion point method - error: \(result.rawValue)")
            return false
        }
    }

    private func typeCharacter(_ char: Character) {
        let charString = String(char)
        let utf16Array = Array(charString.utf16)

        // Create keyboard events for this character
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            self.log("[TypingService] ERROR: Failed to create CGEvents for character: \(char)")
            return
        }

        // Set the unicode string for both events
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)

        // Post the events
        keyDownEvent.post(tap: .cghidEventTap)
        usleep(2000) // Short delay between key down and up (2ms)
        keyUpEvent.post(tap: .cghidEventTap)
    }
}
