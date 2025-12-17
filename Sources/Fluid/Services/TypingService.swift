import AppKit
import Foundation

final class TypingService {
    // Logging toggle (off by default). Enable by setting env FLUID_TYPING_LOGS=1
    // or UserDefaults bool for key "enableTypingLogs".
    private static var isLoggingEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["FLUID_TYPING_LOGS"], env == "1" { return true }
        return UserDefaults.standard.bool(forKey: "enableTypingLogs")
    }

    private func log(_ message: @autoclosure () -> String) {
        if Self.isLoggingEnabled { print(message()) }
    }

    private var isCurrentlyTyping = false

    func typeTextInstantly(_ text: String) {
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
            self.insertTextInstantly(text)
        }
    }

    private func insertTextInstantly(_ text: String) {
        self.log("[TypingService] insertTextInstantly called with \(text.count) characters")
        self.log("[TypingService] Attempting to type text: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\"")

        // Get frontmost app info
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            self.log("[TypingService] Target app: \(frontApp.localizedName ?? "Unknown") (\(frontApp.bundleIdentifier ?? "Unknown"))")
        } else {
            self.log("[TypingService] WARNING: Could not get frontmost application")
        }

        // Check if we have permission to create events
        self.log("[TypingService] Accessibility trusted: \(AXIsProcessTrusted())")

        // Try direct bulk CGEvent insertion (NO CLIPBOARD)
        self.log("[TypingService] Trying INSTANT bulk CGEvent insertion (no clipboard)")
        if self.insertTextBulkInstant(text) {
            self.log("[TypingService] SUCCESS: Instant bulk CGEvent completed")
        } else {
            self.log("[TypingService] FAILED: Bulk CGEvent, trying character-by-character")
            // Fallback to character-by-character if bulk fails
            for (index, char) in text.enumerated() {
                if index % 10 == 0 { // Log every 10th character to avoid spam
                    self.log("[TypingService] Typing character \(index + 1)/\(text.count): '\(char)'")
                }
                self.typeCharacter(char)
                usleep(1000) // Small delay between characters (1ms)
            }

            self.log("[TypingService] Character-by-character typing completed")
        }
    }

    private func insertTextBulkInstant(_ text: String) -> Bool {
        self.log("[TypingService] Starting INSTANT bulk CGEvent insertion (NO CLIPBOARD)")

        // Create single CGEvent with entire text - truly instant
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            self.log("[TypingService] ERROR: Failed to create bulk CGEvent")
            return false
        }

        // Convert entire text to UTF16
        let utf16Array = Array(text.utf16)
        self.log("[TypingService] Converting \(text.count) characters to single CGEvent")

        // Set the entire text as unicode string
        event.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)

        // Post single event - INSTANT insertion
        event.post(tap: .cghidEventTap)
        self.log("[TypingService] Posted single CGEvent with entire text - INSTANT!")

        return true
    }

    private func insertTextViaAccessibility(_ text: String) -> Bool {
        self.log("[TypingService] Starting Accessibility API insertion")

        // Try multiple strategies to find text input element

        // Strategy 1: Get focused element directly
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

        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

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

        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

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
        let selectAllResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            "" as CFString
        )
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
        let getResult = AXUIElementCopyAttributeValue(
            element,
            kAXInsertionPointLineNumberAttribute as CFString,
            &insertionPoint
        )
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

    private func insertTextBulk(_ text: String) -> Bool {
        self.log("[TypingService] Starting bulk CGEvent insertion")

        // Get the frontmost application's PID for targeted event posting
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            self.log("[TypingService] ERROR: Could not get frontmost application for bulk insertion")
            return false
        }

        let targetPID = frontApp.processIdentifier
        self.log("[TypingService] Targeting PID \(targetPID) for bulk insertion")

        // Try word-by-word insertion instead of entire text at once (faster than char-by-char but more reliable than
        // bulk)
        let words = text.components(separatedBy: " ")
        self.log("[TypingService] Splitting text into \(words.count) words for bulk insertion")

        for (index, word) in words.enumerated() {
            let wordToType = word + (index < words.count - 1 ? " " : "") // Add space except for last word

            if !self.insertWordViaCGEvent(wordToType, targetPID: targetPID) {
                self.log("[TypingService] Failed to insert word \(index + 1): '\(word)', falling back to character method")
                return false
            }

            if index % 5 == 0 && index > 0 {
                self.log("[TypingService] Bulk insertion progress: \(index + 1)/\(words.count) words")
            }
        }

        self.log("[TypingService] Successfully completed bulk word-by-word insertion")
        return true
    }

    private func insertWordViaCGEvent(_ word: String, targetPID: pid_t) -> Bool {
        // Convert word to UTF16 for CGEvent
        let utf16Array = Array(word.utf16)

        // Create keyboard event for this word
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            self.log("[TypingService] ERROR: Failed to create CGEvents for word: '\(word)'")
            return false
        }

        // Set the unicode string for both events
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)

        // Post events to specific PID
        keyDownEvent.postToPid(targetPID)
        usleep(2000) // 2ms delay between keyDown and keyUp
        keyUpEvent.postToPid(targetPID)

        return true
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
