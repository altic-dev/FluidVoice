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

    /// Logging toggle (off by default). Enable by setting env FLUID_TYPING_LOGS=1
    /// or UserDefaults bool for key "enableTypingLogs".
    private nonisolated static var isLoggingEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["FLUID_TYPING_LOGS"], env == "1" { return true }
        return UserDefaults.standard.bool(forKey: "enableTypingLogs")
    }

    private nonisolated func log(_ message: @autoclosure () -> String) {
        guard TypingService.isLoggingEnabled else { return }
        Self.emitDebugLog(message())
    }

    struct RecordingTargetContext {
        let id: UUID
        let pid: pid_t
        let bundleIdentifier: String?
        let window: AXUIElement?
        let element: AXUIElement?
    }

    enum FocusPreparationResult: String {
        case alreadyFocused = "already_focused"
        case restoredExactTarget = "restored_exact_target"
        case activatedForRecovery = "activated_for_recovery"
        case failed

        var isReady: Bool {
            self != .failed
        }
    }

    private struct FocusedTextSnapshot {
        let pid: pid_t
        let bundleIdentifier: String?
        let value: String?
        let selectedRange: CFRange?
        let appScriptValue: String?
        let appScriptSelectedRange: CFRange?
    }

    private static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
    private static let directInsertionQueue = DispatchQueue(
        label: "com.FluidApp.Fluid.direct-text-insertion",
        qos: .userInitiated
    )
    static let recoveryActivationOptions: NSApplication.ActivationOptions = [.activateIgnoringOtherApps]

    private var textInsertionMode: SettingsStore.TextInsertionMode {
        SettingsStore.shared.textInsertionMode
    }

    // MARK: - Focus helpers (shared)

    /// Best-effort: returns the PID owning the currently focused accessibility element.
    /// This is more reliable than NSWorkspace.frontmostApplication for floating overlays/launchers.
    static func captureSystemFocusTarget() -> CapturedFocusTarget? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard result == .success, let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID()
        else { return nil }

        let element = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        let window = Self.copyAXElementAttribute(from: appElement, attribute: kAXFocusedWindowAttribute as CFString)
            ?? Self.copyAXElementAttribute(from: appElement, attribute: kAXMainWindowAttribute as CFString)
        Self.logFocusState("[TypingService] Captured focus snapshot")
        return CapturedFocusTarget(pid: pid, window: window, element: element)
    }

    /// Captures the immutable destination window and element before any FluidVoice UI interaction.
    static func captureRecordingTargetContext() -> RecordingTargetContext? {
        guard AXIsProcessTrusted() else {
            return self.fallbackRecordingTargetContext()
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard result == .success, let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID()
        else { return self.fallbackRecordingTargetContext() }

        let element = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0 else { return self.fallbackRecordingTargetContext() }
        let appElement = AXUIElementCreateApplication(pid)
        let window = Self.copyAXElementAttribute(from: appElement, attribute: kAXFocusedWindowAttribute as CFString)
            ?? Self.copyAXElementAttribute(from: appElement, attribute: kAXMainWindowAttribute as CFString)
        Self.logFocusState("[TypingService] Captured focus snapshot")
        return RecordingTargetContext(
            id: UUID(),
            pid: pid,
            bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            window: window,
            element: element
        )
    }

    /// Read-only focus observation. It must never replace the recording target snapshot.
    static func currentFocusedPID() -> pid_t? {
        guard AXIsProcessTrusted() else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

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
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

        let element = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid > 0 ? pid : NSWorkspace.shared.frontmostApplication?.processIdentifier
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

    private static func fallbackRecordingTargetContext() -> RecordingTargetContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return RecordingTargetContext(
            id: UUID(),
            pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            window: nil,
            element: nil
        )
    }

    /// Best-effort: returns the text immediately before the caret in the currently focused
    /// text field. Used by Continuous Dictation Mode to decide capitalization when chaining
    /// transcribed segments. Returns "" when the focused field/context is unavailable.
    static func textBeforeCursorInFocusedField() -> String {
        TypingService().captureTextBeforeCursorInFocusedField()
    }

    static func prepareTargetForDelivery(_ context: RecordingTargetContext) async -> FocusPreparationResult {
        if context.pid == self.currentFocusedPID(),
           context.element == nil || self.isCapturedFocusStillActive(context)
        {
            return .alreadyFocused
        }

        if await self.restoreExactTarget(context) {
            return .restoredExactTarget
        }

        guard context.window != nil, context.element != nil,
              self.activateAppForRecovery(pid: context.pid)
        else {
            return .failed
        }

        try? await Task.sleep(nanoseconds: 25_000_000)
        return await self.restoreExactTarget(context) ? .activatedForRecovery : .failed
    }

    private static func restoreExactTarget(_ context: RecordingTargetContext) async -> Bool {
        guard AXIsProcessTrusted(), context.window != nil, context.element != nil else { return false }

        self.logFocusState("[TypingService] Before restoreExactTarget")
        let appElement = AXUIElementCreateApplication(context.pid)

        if let window = context.window {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, window)
            _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        guard let element = context.element else { return false }

        for attempt in 0..<3 {
            let result = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            if result == .success, Self.isCurrentlyFocusedElement(element, expectedPID: context.pid) {
                Self.logFocusState("[TypingService] After restoreExactTarget success")
                return true
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }

        let isFocused = Self.isCurrentlyFocusedElement(element, expectedPID: context.pid)
        Self.logFocusState("[TypingService] After restoreExactTarget final result=\(isFocused)")
        return isFocused
    }

    static func isCapturedFocusStillActive(_ context: RecordingTargetContext) -> Bool {
        guard AXIsProcessTrusted(),
              let element = context.element
        else {
            return false
        }

        return Self.isCurrentlyFocusedElement(element, expectedPID: context.pid)
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

    /// Recovery-only activation. Normal dictation must preserve the destination's focus.
    @discardableResult
    static func activateAppForRecovery(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }

        // Never try to re-activate ourselves; callers want focus to go back to the external app.
        if let selfBundleID = Bundle.main.bundleIdentifier,
           let targetBundleID = app.bundleIdentifier,
           selfBundleID == targetBundleID
        {
            return false
        }

        return app.activate(options: Self.recoveryActivationOptions)
    }

    // MARK: - Public API

    @MainActor
    func typeTextInstantly(_ text: String) async -> TextDeliveryResult {
        await self.typeTextInstantly(text, preferredTargetPID: nil, textReadyAt: nil)
    }

    /// Types/inserts text, optionally preferring a specific target PID for CGEvent posting.
    /// This helps when our overlay temporarily has focus; we can still target the original app.
    @MainActor
    func typeTextInstantly(_ text: String, preferredTargetPID: pid_t?) async -> TextDeliveryResult {
        await self.typeTextInstantly(text, preferredTargetPID: preferredTargetPID, textReadyAt: nil)
    }

    /// Types/inserts text, optionally preferring a specific target PID for CGEvent posting.
    /// This helps when our overlay temporarily has focus; we can still target the original app.
    @MainActor
    func typeTextInstantly(
        _ text: String,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval?,
        toggleStopRequestedAt: TimeInterval? = nil,
        preserveTranscriptOnClipboard: Bool = false
    ) async -> TextDeliveryResult {
        await self.typeOutputPlanInstantly(
            .plain(text),
            preferredTargetPID: preferredTargetPID,
            textReadyAt: textReadyAt,
            toggleStopRequestedAt: toggleStopRequestedAt,
            preserveTranscriptOnClipboard: preserveTranscriptOnClipboard
        )
    }

    @MainActor
    func typeOutputPlanInstantly(
        _ plan: DictationLiteralOutputPlan,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval?,
        toggleStopRequestedAt: TimeInterval? = nil,
        tracksDictionaryCorrections: Bool = false,
        preserveTranscriptOnClipboard: Bool = false
    ) async -> TextDeliveryResult {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let text = plan.plainText
        let mode = self.textInsertionMode
        let textReadyAge = textReadyAt.map { Self.elapsedMs(from: $0, to: requestedAt) }
        self.bench(
            "request chars=\(text.count) mode=\(mode.rawValue) autocompleteSteps=\(plan.steps.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyAgeMs=\(textReadyAge.map { String($0) } ?? "nil")"
        )
        self.log("[TypingService] ENTRY: typeTextInstantly called with text length: \(text.count)")
        self.log("[TypingService] Text preview: \"\(String(text.prefix(100)))\"")

        guard !text.isEmpty else {
            self.bench("request_return reason=empty_text")
            self.log("[TypingService] ERROR: Empty text provided, aborting")
            let result = TextDeliveryResult.recoverableFailure(.emptyText)
            self.recordInsertionLatency(
                path: .notAttempted,
                result: result,
                requestedAt: requestedAt,
                textReadyAt: textReadyAt,
                toggleStopRequestedAt: toggleStopRequestedAt
            )
            return result
        }

        // Check accessibility permissions first
        guard AXIsProcessTrusted() else {
            self.bench("request_return reason=accessibility_not_trusted")
            self.log("[TypingService] ERROR: Accessibility permissions required for text injection")
            self.log("[TypingService] Current accessibility status: \(AXIsProcessTrusted())")
            let result = TextDeliveryResult.recoverableFailure(.accessibilityNotTrusted)
            self.recordInsertionLatency(
                path: .notAttempted,
                result: result,
                requestedAt: requestedAt,
                textReadyAt: textReadyAt,
                toggleStopRequestedAt: toggleStopRequestedAt
            )
            return result
        }

        let usesClipboard = mode == .reliablePaste ||
            self.ghosttyTargetPID(preferredTargetPID: preferredTargetPID) != nil
        let result: TextDeliveryResult
        let deliveryPath: AnalyticsInsertionPath
        var dispatchedAt: TimeInterval?
        if usesClipboard {
            deliveryPath = .clipboard
            result = await PasteDeliveryCoordinator.shared.deliver(
                text,
                preserveTranscriptOnClipboard: preserveTranscriptOnClipboard,
                onCommandPosted: { dispatchedAt = $0 }
            )
        } else if await self.insertTextDirectlyOffMain(text, preferredTargetPID: preferredTargetPID) {
            deliveryPath = .direct
            if preserveTranscriptOnClipboard {
                _ = ClipboardService.copyToClipboard(text)
            }
            result = .commandPosted
        } else {
            deliveryPath = .clipboardFallback
            self.log("[TypingService] Direct insertion failed; using non-blocking clipboard fallback")
            result = await PasteDeliveryCoordinator.shared.deliver(
                text,
                preserveTranscriptOnClipboard: preserveTranscriptOnClipboard,
                onCommandPosted: { dispatchedAt = $0 }
            )
        }

        let completedAt = dispatchedAt ?? ProcessInfo.processInfo.systemUptime
        self.bench(
            "complete result=\(String(describing: result)) totalMs=\(Self.elapsedMs(from: requestedAt, to: completedAt)) textReadyToCompleteMs=\(textReadyAt.map { String(Self.elapsedMs(from: $0, to: completedAt)) } ?? "nil")"
        )
        self.recordInsertionLatency(
            path: deliveryPath,
            result: result,
            requestedAt: requestedAt,
            textReadyAt: textReadyAt,
            toggleStopRequestedAt: toggleStopRequestedAt,
            completedAt: completedAt
        )
        if result.wasDispatched, tracksDictionaryCorrections {
            AutomaticDictionaryCorrectionTracker.shared.beginObservingInsertion(
                text,
                targetPID: preferredTargetPID
            )
        }
        return result
    }

    func typeOutputPlanInstantly(
        _ plan: DictationLiteralOutputPlan,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval?,
        toggleStopRequestedAt: TimeInterval? = nil,
        tracksDictionaryCorrections: Bool = false,
        postInsertionKey: SettingsStore.SpokenSendKey? = nil,
        requiredFocusTarget: CapturedFocusTarget? = nil,
        preserveTranscriptOnClipboard: Bool = false,
        completion: ((DeliveryOutcome) -> Void)? = nil
    ) {
        Task { @MainActor in
            let hasTextToInsert = !plan.plainText.isEmpty
            guard hasTextToInsert || postInsertionKey != nil else {
                completion?(.rejected)
                return
            }

            if postInsertionKey != nil {
                guard let preferredTargetPID, let requiredFocusTarget,
                      Self.canInsertBeforePostInsertionAction(
                          preferredTargetPID: preferredTargetPID,
                          requiredTargetPID: requiredFocusTarget.pid,
                          isSecureTextField: requiredFocusTarget.isSecureTextField,
                          exactFocusIsActive: Self.isExactFocusTargetActive(requiredFocusTarget)
                      )
                else {
                    completion?(.actionSuppressed)
                    return
                }
            }

            var outcome: DeliveryOutcome = .actionSuppressed
            if hasTextToInsert {
                let result = await self.typeOutputPlanInstantly(
                    plan,
                    preferredTargetPID: preferredTargetPID,
                    textReadyAt: textReadyAt,
                    toggleStopRequestedAt: toggleStopRequestedAt,
                    tracksDictionaryCorrections: tracksDictionaryCorrections,
                    preserveTranscriptOnClipboard: preserveTranscriptOnClipboard
                )
                guard result.wasDispatched else {
                    completion?(.insertionFailed)
                    return
                }
                outcome = .inserted
            }

            guard let postInsertionKey else {
                completion?(outcome)
                return
            }
            guard let preferredTargetPID, let requiredFocusTarget else {
                completion?(hasTextToInsert ? .insertedActionSuppressed : .actionSuppressed)
                return
            }

            let modifiersReleased = await self.waitForPhysicalModifiersToRelease(timeout: 2)
            guard Self.canDispatchPostInsertionAction(
                preferredTargetPID: preferredTargetPID,
                requiredTargetPID: requiredFocusTarget.pid,
                isSecureTextField: requiredFocusTarget.isSecureTextField,
                modifiersReleased: modifiersReleased,
                exactFocusIsActive: Self.isExactFocusTargetActive(requiredFocusTarget)
            ) else {
                completion?(hasTextToInsert ? .insertedActionSuppressed : .actionSuppressed)
                return
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
            guard Self.isExactFocusTargetActive(requiredFocusTarget),
                  await self.postReturnKey(postInsertionKey, targetPID: preferredTargetPID)
            else {
                completion?(hasTextToInsert ? .insertedActionSuppressed : .actionSuppressed)
                return
            }
            completion?(hasTextToInsert ? .insertedAndActionDispatched : .actionDispatched)
        }
    }

    private func bench(_ message: String) {
        DebugLogger.shared.benchmark("TYPING_BENCH", message: message, source: "TypingBenchmark")
    }

    private func recordInsertionLatency(
        path: AnalyticsInsertionPath,
        result: TextDeliveryResult,
        requestedAt: TimeInterval,
        textReadyAt: TimeInterval?,
        toggleStopRequestedAt: TimeInterval?,
        completedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let outcome = Self.analyticsOutcome(for: result)
        let isClipboardDispatch = outcome == .dispatched &&
            (path == .clipboard || path == .clipboardFallback)
        AnalyticsService.shared.recordInsertionLatency(
            path: path,
            outcome: outcome,
            requestMilliseconds: max(0, Self.elapsedMs(from: requestedAt, to: completedAt)),
            readyMilliseconds: textReadyAt.map {
                max(0, Self.elapsedMs(from: $0, to: completedAt))
            },
            toggleStopMilliseconds: isClipboardDispatch ? toggleStopRequestedAt.map {
                max(0, Self.elapsedMs(from: $0, to: completedAt))
            } : nil
        )
    }

    private static func analyticsOutcome(for result: TextDeliveryResult) -> AnalyticsInsertionOutcome {
        switch result {
        case .commandPosted:
            .dispatched
        case let .recoverableFailure(failure):
            switch failure {
            case .emptyText: .emptyText
            case .accessibilityNotTrusted: .accessibilityNotTrusted
            case .clipboardSnapshotFailed: .clipboardSnapshotFailed
            case .clipboardWriteFailed: .clipboardWriteFailed
            case .pasteCommandFailed: .pasteCommandFailed
            case .targetUnavailable: .targetUnavailable
            case .targetRestoreFailed: .targetRestoreFailed
            }
        }
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private static func elapsedMs(from start: TimeInterval, to end: TimeInterval) -> Int {
        Int(((end - start) * 1000).rounded())
    }

    // MARK: - Internal insertion pipeline

    private func insertTextDirectlyOffMain(_ text: String, preferredTargetPID: pid_t?) async -> Bool {
        await withCheckedContinuation { continuation in
            Self.directInsertionQueue.async {
                continuation.resume(
                    returning: self.insertTextDirectly(text, preferredTargetPID: preferredTargetPID)
                )
            }
        }
    }

    private nonisolated func insertTextDirectly(_ text: String, preferredTargetPID: pid_t?) -> Bool {
        self.log("[TypingService] insertTextInstantly called with \(text.count) characters")
        self.log("[TypingService] Attempting to type text: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\"")

        if let preferredTargetPID, preferredTargetPID > 0 {
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

        return false
    }

    private func waitForPhysicalModifiersToRelease(timeout: TimeInterval) async -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let startedAt = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - startedAt < timeout {
            if CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: relevant) {
                return true
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return false
    }

    private func postReturnKey(_ key: SettingsStore.SpokenSendKey, targetPID: pid_t) async -> Bool {
        let returnKeyCode = CGKeyCode(kVK_Return)
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
        try? await Task.sleep(nanoseconds: 10_000_000)
        keyUp.postToPid(targetPID)
        return true
    }

    private nonisolated static let cgEventUnicodeChunkSize = 200

    private nonisolated static func copyAXElementAttribute(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private nonisolated static func stringAXAttribute(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private nonisolated static func currentFocusDebugDescription() -> String {
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

    private nonisolated static func logFocusState(_ prefix: String) {
        guard self.isLoggingEnabled else { return }
        self.emitDebugLog("\(prefix) | \(self.currentFocusDebugDescription())")
    }

    private nonisolated static func emitDebugLog(_ message: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                DebugLogger.shared.debug(message, source: "TypingService")
            }
        } else {
            DispatchQueue.main.async {
                DebugLogger.shared.debug(message, source: "TypingService")
            }
        }
    }

    private nonisolated static func isCurrentlyFocusedElement(_ expectedElement: AXUIElement, expectedPID: pid_t) -> Bool {
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

    private nonisolated func insertTextBulkInstant(_ text: String, targetPID: pid_t) -> Bool {
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

    private nonisolated func insertTextBulkHIDInstant(_ text: String) -> Bool {
        self.log("[TypingService] Starting chunked bulk CGEvent insertion via HID (NO PID)")

        let utf16Array = Array(text.utf16)

        return self.postUnicodeChunks(utf16Array, destinationDescription: "HID tap") { event in
            event.post(tap: .cghidEventTap)
        }
    }

    private nonisolated func postUnicodeChunks(
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

    private nonisolated static func unicodeChunkEnd(in utf16Array: [UInt16], start: Int) -> Int {
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

    private nonisolated static func isHighSurrogate(_ value: UInt16) -> Bool {
        (0xd800...0xdbff).contains(value)
    }

    private nonisolated static func isLowSurrogate(_ value: UInt16) -> Bool {
        (0xdc00...0xdfff).contains(value)
    }

    private nonisolated func insertTextViaAccessibility(_ text: String) -> Bool {
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

    private nonisolated func getFocusedTextElement() -> AXUIElement? {
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

    private nonisolated func findTextElementInFrontmostApp() -> AXUIElement? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            self.log("[TypingService] Could not get frontmost app")
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        return self.findTextElementRecursively(appElement, depth: 0, maxDepth: 8)
    }

    private nonisolated func findTextElementRecursively(_ element: AXUIElement, depth: Int, maxDepth: Int) -> AXUIElement? {
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

    private nonisolated func findKeyboardFocusedElement() -> AXUIElement? {
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

    private nonisolated func tryAllTextInsertionMethods(_ element: AXUIElement, _ text: String) -> Bool {
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

    private nonisolated func getElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        if result == .success, let stringValue = value as? String {
            return stringValue
        }
        return nil
    }

    private nonisolated func getSystemFocusedElementAndPID() -> (element: AXUIElement, pid: pid_t)? {
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

    private nonisolated func getElementStringValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success, let str = value as? String else { return nil }
        return str
    }

    private nonisolated func getSelectedTextRange(_ element: AXUIElement) -> CFRange? {
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

    private nonisolated func insertTextAtCursorUsingSelectedRange(_ element: AXUIElement, _ text: String) -> Bool {
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

    /// Why is it working now? And why is it not working now?
    private nonisolated func setTextViaValue(_ element: AXUIElement, _ text: String) -> Bool {
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

    private nonisolated func setTextViaSelection(_ element: AXUIElement, _ text: String) -> Bool {
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

    private nonisolated func insertTextAtInsertionPoint(_ element: AXUIElement, _ text: String) -> Bool {
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
}
