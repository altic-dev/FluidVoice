import AppKit
import ApplicationServices
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

    // MARK: - Focus helpers (shared)

    /// Best-effort: returns the PID owning the currently focused accessibility element.
    /// This is more reliable than NSWorkspace.frontmostApplication for floating overlays/launchers.
    static func captureSystemFocusedPID() -> pid_t? {
        // Accessibility is required to query system-focused AX element.
        guard AXIsProcessTrusted() else { return nil }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard result == .success, let focusedElementRef else { return nil }
        guard CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else { return nil }

        let element = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0 else { return nil }
        return pid
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

    func typeTextInstantly(_ text: String) {
        self.typeTextInstantly(text, preferredTargetPID: nil)
    }

    /// Types/inserts text, optionally preferring a specific target PID for CGEvent posting.
    /// This helps when our overlay temporarily has focus; we can still target the original app.
    func typeTextInstantly(_ text: String, preferredTargetPID: pid_t?) {
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

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                self.isCurrentlyTyping = false
                self.log("[TypingService] Typing operation completed, isCurrentlyTyping set to false")
            }

            self.log("[TypingService] Starting async text insertion process")
            // Longer delay to ensure target app is ready and focused
            usleep(200_000) // 200ms delay - more reliable for app switching
            self.log("[TypingService] Delay completed, calling insertTextInstantly")
            self.insertTextInstantly(text, preferredTargetPID: preferredTargetPID)
        }
    }

    // MARK: - Internal insertion pipeline

    private func insertTextInstantly(_ text: String, preferredTargetPID: pid_t?) {
        self.log("[TypingService] insertTextInstantly called with \(text.count) characters")
        self.log("[TypingService] Attempting to type text: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\"")

        // Preferred: target a specific PID when provided (e.g., the app that was focused when recording started).
        // Use clipboard paste (Cmd+V via postToPid) as the primary method — it works universally across
        // native apps, Electron-based editors (VS Code, Slack), web views, and terminals.
        // Unicode key-event posting (insertTextBulkInstant) silently fails for many of these because those
        // apps don't process CGEvent.keyboardSetUnicodeString events through their text input system.
        if let preferredTargetPID, preferredTargetPID > 0 {
            self.log("[TypingService] Trying clipboard-to-PID insertion targeting preferred PID \(preferredTargetPID)")
            if self.insertTextViaClipboardToPid(text, targetPID: preferredTargetPID) {
                self.log("[TypingService] SUCCESS: Clipboard-to-PID insertion completed")
                return
            }
            // Fallback: unicode events to preferred PID (for apps where Cmd+V is intercepted or disabled)
            self.log("[TypingService] Clipboard-to-PID failed, trying CGEvent insertion targeting preferred PID \(preferredTargetPID)")
            if self.insertTextBulkInstant(text, targetPID: preferredTargetPID) {
                self.log("[TypingService] SUCCESS: CGEvent preferred-PID insertion completed")
                return
            }
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
        // This is useful for some native apps or when direct event posting fails
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

    /// Clipboard-paste insertion targeted at a specific PID.
    /// Puts text in the clipboard, sends Cmd+V directly to the target process via postToPid,
    /// then restores the previous clipboard contents. This is the most universal insertion method
    /// because Cmd+V is handled by virtually all apps (native, Electron, web views, terminals).
    private func insertTextViaClipboardToPid(_ text: String, targetPID: pid_t) -> Bool {
        self.log("[TypingService] Starting clipboard-to-PID insertion to PID \(targetPID)")

        guard targetPID > 0 else {
            self.log("[TypingService] ERROR: Invalid target PID \(targetPID)")
            return false
        }

        let pasteboard = NSPasteboard.general
        let previousContent = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let cmdVUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        else {
            self.log("[TypingService] ERROR: Failed to create Cmd+V events for PID insertion")
            if let prev = previousContent {
                pasteboard.clearContents()
                pasteboard.setString(prev, forType: .string)
            }
            return false
        }

        cmdVDown.flags = .maskCommand
        cmdVUp.flags = .maskCommand

        cmdVDown.postToPid(targetPID)
        usleep(10_000) // 10ms between key-down and key-up
        cmdVUp.postToPid(targetPID)

        self.log("[TypingService] Cmd+V posted to PID \(targetPID)")

        // Wait for paste to complete before restoring clipboard
        usleep(150_000) // 150ms
        if let prev = previousContent {
            pasteboard.clearContents()
            pasteboard.setString(prev, forType: .string)
            self.log("[TypingService] Restored previous clipboard content")
        }

        return true
    }

    private func insertTextBulkInstant(_ text: String, targetPID: pid_t) -> Bool {
        self.log("[TypingService] Starting INSTANT bulk CGEvent insertion (NO CLIPBOARD) to PID \(targetPID)")

        guard targetPID > 0 else {
            self.log("[TypingService] ERROR: Invalid target PID \(targetPID)")
            return false
        }

        // Convert entire text to UTF16
        let utf16Array = Array(text.utf16)
        self.log("[TypingService] Converting \(text.count) characters to CGEvents (UTF16 count \(utf16Array.count))")

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

        // Save current clipboard content
        let pasteboard = NSPasteboard.general
        let previousContent = pasteboard.string(forType: .string)

        // Copy our text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        guard let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true), // 9 = 'V'
              let cmdVUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        else {
            self.log("[TypingService] ERROR: Failed to create Cmd+V events")
            // Restore clipboard
            if let prev = previousContent {
                pasteboard.clearContents()
                pasteboard.setString(prev, forType: .string)
            }
            return false
        }

        cmdVDown.flags = .maskCommand
        cmdVUp.flags = .maskCommand

        cmdVDown.post(tap: .cghidEventTap)
        usleep(10_000) // 10ms delay
        cmdVUp.post(tap: .cghidEventTap)

        self.log("[TypingService] Cmd+V sent via clipboard insertion")

        // Brief delay then restore clipboard
        usleep(100_000) // 100ms delay for paste to complete
        if let prev = previousContent {
            pasteboard.clearContents()
            pasteboard.setString(prev, forType: .string)
            self.log("[TypingService] Restored previous clipboard content")
        }

        return true
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
