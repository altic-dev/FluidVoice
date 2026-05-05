import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

final class TypingService {
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

        var canVerifyInsertion: Bool {
            self.value != nil ||
                self.selectedRange != nil ||
                self.appScriptValue != nil ||
                self.appScriptSelectedRange != nil
        }
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
    private static let reliablePasteVerificationTimeoutMicros: useconds_t = 5_000_000
    private static let standardVerifyTimeoutMicros: useconds_t = 750_000
    private static let standardUnverifiedSettleMicros: useconds_t = 200_000

    private var textInsertionMode: SettingsStore.TextInsertionMode {
        SettingsStore.shared.textInsertionMode
    }

    // MARK: - Layout-aware key code lookup

    /// Returns the virtual key code that produces `character` under the current keyboard layout.
    /// Uses the TIS (Text Input Services) API which must run on the main thread, so the lookup
    /// is dispatched there when called from a background thread. Falls back to `qwertyFallback`
    /// if the layout data is unavailable.
    private static func virtualKeyCode(for character: Character, qwertyFallback: CGKeyCode) -> CGKeyCode {
        if Thread.isMainThread {
            return self.tisLookup(for: character, qwertyFallback: qwertyFallback)
        }
        var result = qwertyFallback
        DispatchQueue.main.sync {
            result = self.tisLookup(for: character, qwertyFallback: qwertyFallback)
        }
        return result
    }

    /// Performs the actual TIS + UCKeyTranslate scan. Must be called on the main thread.
    private static func tisLookup(for character: Character, qwertyFallback: CGKeyCode) -> CGKeyCode {
        guard let targetScalar = character.unicodeScalars.first else { return qwertyFallback }

        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData)
        else {
            return qwertyFallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawPtr).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layoutPtr = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return qwertyFallback
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let kbType = UInt32(LMGetKbdType())

            for keyCode: UInt16 in 0..<128 {
                deadKeyState = 0
                length = 0
                let status = UCKeyTranslate(
                    layoutPtr,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    0,
                    kbType,
                    UInt32(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                guard status == noErr, length > 0 else { continue }
                if Unicode.Scalar(chars[0]) == targetScalar {
                    return CGKeyCode(keyCode)
                }
            }
            return qwertyFallback
        }
    }

    /// The virtual key code for "v" in the current keyboard layout (used for Cmd+V paste).
    /// Re-evaluated on every call so runtime keyboard layout switches are picked up immediately.
    private static var pasteVirtualKeyCode: CGKeyCode {
        virtualKeyCode(for: "v", qwertyFallback: 9)
    }

    // MARK: - Focus helpers (shared)

    /// Best-effort: returns the PID owning the currently focused accessibility element.
    /// This is more reliable than NSWorkspace.frontmostApplication for floating overlays/launchers.
    static func captureSystemFocusedPID() -> pid_t? {
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
        return pid
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

        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    // MARK: - Public API

    func typeTextInstantly(_ text: String, onComplete: (() -> Void)? = nil) {
        self.typeTextInstantly(text, preferredTargetPID: nil, onComplete: onComplete)
    }

    /// Types/inserts text, optionally preferring a specific target PID for CGEvent posting.
    /// This helps when our overlay temporarily has focus; we can still target the original app.
    func typeTextInstantly(_ text: String, preferredTargetPID: pid_t?, onComplete: (() -> Void)? = nil) {
        self.log("[TypingService] ENTRY: typeTextInstantly called with text length: \(text.count)")
        self.log("[TypingService] Text preview: \"\(String(text.prefix(100)))\"")

        guard text.isEmpty == false else {
            self.log("[TypingService] ERROR: Empty text provided, aborting")
            return
        }

        // Prevent concurrent typing operations
        guard !self.isCurrentlyTyping else {
            self.log("[TypingService] WARNING: Skipping text injection - already in progress")
            return
        }

        // Check accessibility permissions first
        guard AXIsProcessTrusted() else {
            self.log("[TypingService] ERROR: Accessibility permissions required for text injection")
            self.log("[TypingService] Current accessibility status: \(AXIsProcessTrusted())")
            return
        }

        self.log("[TypingService] Accessibility check passed, proceeding with text injection")
        self.isCurrentlyTyping = true
        let insertionMode = self.textInsertionMode

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                self.isCurrentlyTyping = false
                self.log("[TypingService] Typing operation completed, isCurrentlyTyping set to false")
                DispatchQueue.main.async {
                    onComplete?()
                }
            }

            self.log("[TypingService] Starting async text insertion process")
            if self.textInsertionMode == .reliablePaste {
                // Reliable Paste still needs a short settle window after focus restoration.
                usleep(80_000)
            } else {
                // Direct typing paths are more timing-sensitive after app activation.
                usleep(200_000)
            }
            self.log("[TypingService] Delay completed, calling insertTextInstantly")
            let focusedTextSnapshot = self.captureFocusedTextSnapshot()
            self.insertTextInstantly(text, preferredTargetPID: preferredTargetPID)
            self.waitForInsertionToSettle(
                from: focusedTextSnapshot,
                expectedText: text,
                insertionMode: insertionMode
            )
        }
    }

    // MARK: - Internal insertion pipeline

    private func insertTextInstantly(_ text: String, preferredTargetPID: pid_t?) {
        self.log("[TypingService] insertTextInstantly called with \(text.count) characters")
        self.log("[TypingService] Attempting to type text: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\"")

        if self.textInsertionMode == .reliablePaste {
            self.log("[TypingService] Reliable Paste mode enabled")
            if self.tryReliablePasteInsertion(text, preferredTargetPID: preferredTargetPID) {
                self.log("[TypingService] SUCCESS: Reliable Paste mode completed")
                return
            }
            self.log("[TypingService] Reliable Paste mode fell through to direct-typing fallbacks")
        } else if let preferredTargetPID, preferredTargetPID > 0 {
            self.log("[TypingService] Experimental Direct Typing mode: trying preferred PID unicode insertion first")
            if self.insertTextBulkInstant(text, targetPID: preferredTargetPID) {
                self.log("[TypingService] SUCCESS: Preferred PID CGEvent insertion completed")
                return
            }
            self.log("[TypingService] Preferred PID CGEvent insertion failed, continuing fallback pipeline")
        }

        if text.utf16.count > Self.cgEventUnicodeLimit {
            self.log("[TypingService] Text exceeds CGEvent limit (\(text.utf16.count) UTF-16 units), using clipboard insertion")
            if self.insertTextViaClipboard(text) {
                self.log("[TypingService] SUCCESS: Clipboard insertion completed (long text path)")
                return
            }
            self.log("[TypingService] Clipboard failed for long text, trying character-by-character")
            for (index, char) in text.enumerated() {
                if index % 10 == 0 {
                    self.log("[TypingService] Typing character \(index + 1)/\(text.count)")
                }
                self.typeCharacter(char)
                usleep(1000)
            }
            self.log("[TypingService] Character-by-character typing completed")
            return
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
                return
            }
        }

        // Secondary: Try Accessibility insertion into the actual focused element
        self.log("[TypingService] Trying Accessibility focused-element insertion")
        if self.insertTextViaAccessibility(text) {
            self.log("[TypingService] SUCCESS: Accessibility insertion completed")
            return
        }

        // HID Fallback if PID targeting failed
        if focusInfo?.pid == nil {
            self.log("[TypingService] No focused PID available, trying HID CGEvent insertion")
            if self.insertTextBulkHIDInstant(text) {
                self.log("[TypingService] SUCCESS: CGEvent HID insertion completed")
                return
            }
        }

        // Fallback: Use clipboard-based insertion (more reliable)
        self.log("[TypingService] CGEvent failed, trying clipboard fallback")
        if self.insertTextViaClipboard(text) {
            self.log("[TypingService] SUCCESS: Clipboard insertion completed")
            return
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

    private static let cgEventUnicodeLimit = 200

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

    private func withTemporaryPasteboardString(
        _ text: String,
        restoreDelayMicros: useconds_t,
        action: () -> Bool
    ) -> Bool {
        Self.pasteboardSessionSemaphore.wait()
        var releasesPasteboardSessionOnReturn = true
        defer {
            if releasesPasteboardSessionOnReturn {
                Self.pasteboardSessionSemaphore.signal()
            }
        }

        let pasteboard = NSPasteboard.general
        let snapshot = self.capturePasteboardSnapshot(pasteboard)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            self.log("[TypingService] ERROR: Failed to set temporary clipboard string")
            self.restorePasteboardSnapshot(snapshot, to: pasteboard)
            return false
        }
        let temporaryChangeCount = pasteboard.changeCount
        let focusedTextSnapshot = self.captureFocusedTextSnapshot()
        let actionResult = action()
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

    private func waitForInsertionToSettle(
        from snapshot: FocusedTextSnapshot?,
        expectedText: String,
        insertionMode: SettingsStore.TextInsertionMode
    ) {
        guard let snapshot else {
            usleep(Self.insertionSettleTimeoutMicros(
                insertionMode: insertionMode,
                canVerifyFocusedText: false
            ))
            return
        }

        let timeoutMicros = Self.insertionSettleTimeoutMicros(
            insertionMode: insertionMode,
            canVerifyFocusedText: snapshot.canVerifyInsertion
        )
        let result = self.waitForFocusedTextVerification(
            from: snapshot,
            expectedText: expectedText,
            timeoutMicros: timeoutMicros
        )
        self.log("[TypingService] Completion settle verification: \(result.rawValue)")
    }

    private static func insertionSettleTimeoutMicros(
        insertionMode: SettingsStore.TextInsertionMode,
        canVerifyFocusedText: Bool
    ) -> useconds_t {
        switch (insertionMode, canVerifyFocusedText) {
        case (.reliablePaste, true):
            return self.reliablePasteVerificationTimeoutMicros
        case (.reliablePaste, false):
            return self.reliablePasteVerificationTimeoutMicros
        case (.standard, true):
            return self.standardVerifyTimeoutMicros
        case (.standard, false):
            return self.standardUnverifiedSettleMicros
        }
    }

    /// Clipboard-paste insertion targeted at a specific PID.
    /// Uses postToPid for Cmd+V while preserving the full previous pasteboard payload.
    private func insertTextViaClipboardToPid(_ text: String, targetPID: pid_t, activateTargetFirst: Bool = true) -> Bool {
        self.log("[TypingService] Starting clipboard-to-PID insertion to PID \(targetPID)")

        guard targetPID > 0 else {
            self.log("[TypingService] ERROR: Invalid target PID \(targetPID)")
            return false
        }

        if activateTargetFirst, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            _ = Self.activateApp(pid: targetPID)
            usleep(80_000)
        }

        return self.withTemporaryPasteboardString(text, restoreDelayMicros: Self.reliablePasteVerificationTimeoutMicros) {
            let vKey = Self.pasteVirtualKeyCode
            guard let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: true),
                  let cmdVUp = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: false)
            else {
                self.log("[TypingService] ERROR: Failed to create Cmd+V events for PID insertion")
                return false
            }

            cmdVDown.flags = .maskCommand
            cmdVUp.flags = .maskCommand

            cmdVDown.postToPid(targetPID)
            usleep(10_000)
            cmdVUp.postToPid(targetPID)
            self.log("[TypingService] Cmd+V posted to PID \(targetPID)")
            return true
        }
    }

    private func insertTextBulkInstant(_ text: String, targetPID: pid_t) -> Bool {
        self.log("[TypingService] Starting INSTANT bulk CGEvent insertion (NO CLIPBOARD) to PID \(targetPID)")

        guard targetPID > 0 else {
            self.log("[TypingService] ERROR: Invalid target PID \(targetPID)")
            return false
        }

        let utf16Array = Array(text.utf16)
        self.log("[TypingService] Converting \(text.count) characters to CGEvents (UTF16 count \(utf16Array.count))")

        guard utf16Array.count <= Self.cgEventUnicodeLimit else {
            self.log("[TypingService] Text too long for single CGEvent (\(utf16Array.count) UTF-16 units > \(Self.cgEventUnicodeLimit)), falling back")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            self.log("[TypingService] ERROR: Failed to create bulk CGEvents")
            return false
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUp.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)

        keyDown.postToPid(targetPID)
        usleep(2000)
        keyUp.postToPid(targetPID)

        self.log("[TypingService] Posted bulk CGEvents to PID \(targetPID)")
        return true
    }

    private func insertTextBulkHIDInstant(_ text: String) -> Bool {
        self.log("[TypingService] Starting INSTANT bulk CGEvent insertion via HID (NO PID)")

        let utf16Array = Array(text.utf16)

        guard utf16Array.count <= Self.cgEventUnicodeLimit else {
            self.log("[TypingService] Text too long for single HID CGEvent (\(utf16Array.count) > \(Self.cgEventUnicodeLimit)), falling back")
            return false
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            self.log("[TypingService] ERROR: Failed to create HID bulk CGEvents")
            return false
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUp.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)

        keyDown.post(tap: .cghidEventTap)
        usleep(2000)
        keyUp.post(tap: .cghidEventTap)

        self.log("[TypingService] Posted bulk CGEvents via HID tap")
        return true
    }

    /// Clipboard-based text insertion as fallback
    /// More reliable but slightly slower - copies text to clipboard then pastes
    private func insertTextViaClipboard(_ text: String) -> Bool {
        self.log("[TypingService] Starting clipboard-based insertion")
        return self.withTemporaryPasteboardString(text, restoreDelayMicros: Self.reliablePasteVerificationTimeoutMicros) {
            let vKey = Self.pasteVirtualKeyCode
            guard let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: true),
                  let cmdVUp = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: false)
            else {
                self.log("[TypingService] ERROR: Failed to create Cmd+V events")
                return false
            }

            cmdVDown.flags = .maskCommand
            cmdVUp.flags = .maskCommand

            cmdVDown.post(tap: .cghidEventTap)
            usleep(10_000)
            cmdVUp.post(tap: .cghidEventTap)
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

        return self.withTemporaryPasteboardString(text, restoreDelayMicros: Self.reliablePasteVerificationTimeoutMicros) {
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

        guard snapshot.canVerifyInsertion else {
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

#if DEBUG
extension TypingService {
    static func insertionSettleTimeoutMicrosForTesting(
        insertionMode: SettingsStore.TextInsertionMode,
        canVerifyFocusedText: Bool
    ) -> useconds_t {
        self.insertionSettleTimeoutMicros(
            insertionMode: insertionMode,
            canVerifyFocusedText: canVerifyFocusedText
        )
    }
}
#endif
