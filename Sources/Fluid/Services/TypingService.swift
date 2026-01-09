import AppKit
import ApplicationServices
import Foundation

final class TypingService {
    // Logging toggle (off by default). Enable by setting env FLUID_TYPING_LOGS=1
    // or UserDefaults bool for key "enableTypingLogs".
    private static var isLoggingEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["FLUID_TYPING_LOGS"], env == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "enableTypingLogs")
    }

    private func log(_ message: @autoclosure () -> String) {
        guard TypingService.isLoggingEnabled else { return }
        DebugLogger.shared.debug(message(), source: "TypingService")
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
                self.log(
                    "[TypingService] Typing operation completed, isCurrentlyTyping set to false")
            }

            self.log("[TypingService] Starting async text insertion process")
            // Longer delay to ensure target app is ready and focused
            usleep(200_000)  // 200ms delay - more reliable for app switching
            self.log("[TypingService] Delay completed, calling insertTextInstantly")
            self.insertTextInstantly(text)
        }
    }

    private func insertTextInstantly(_ text: String) {
        self.log("[TypingService] insertTextInstantly called with \(text.count) characters")
        self.log(
            "[TypingService] Attempting to type text: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\""
        )

        // Get frontmost app info
        let frontApp = NSWorkspace.shared.frontmostApplication
        if let frontApp {
            self.log(
                "[TypingService] Frontmost app: \(frontApp.localizedName ?? "Unknown") (\(frontApp.bundleIdentifier ?? "Unknown")) PID=\(frontApp.processIdentifier)"
            )
        } else {
            self.log("[TypingService] WARNING: Could not get frontmost application")
        }

        // Check if we have permission to create events
        self.log("[TypingService] Accessibility trusted: \(AXIsProcessTrusted())")

        // Get the system-wide focused element (useful for floating panels where focus PID != frontmost PID).
        let focusedElement = AccessibilityTextInsertion.systemFocusedElement()
        let focusedPID = focusedElement.flatMap { AccessibilityTextInsertion.owningPID(of: $0) }
        if let focusedPID {
            self.log("[TypingService] AX focused element PID=\(focusedPID)")
        } else if focusedElement != nil {
            self.log("[TypingService] AX focused element found (PID unavailable)")
        }

        // Primary: target a specific PID (previous behavior).
        // If overlays make FluidVoice frontmost, fall back to the last non-Fluid frontmost app.
        var targetPID: pid_t? = frontApp?.processIdentifier
        if let frontApp,
            frontApp.bundleIdentifier == Bundle.main.bundleIdentifier
        {
            targetPID = LastActiveNonFluidAppTracker.shared.lastNonFluidPID
            self.log(
                "[TypingService] Frontmost is FluidVoice; using last non-Fluid PID \(targetPID.map(String.init) ?? "nil")"
            )
        }

        let isFocusPIDMismatch: Bool = {
            guard let focusedPID, let targetPID else { return false }
            return focusedPID != targetPID
        }()

        if !isFocusPIDMismatch {
            if let targetPID {
                self.log(
                    "[TypingService] Trying PID-targeted CGEvent insertion targeting PID \(targetPID)")
                if self.insertTextBulkInstant(text, targetPID: targetPID) {
                    self.log("[TypingService] SUCCESS: PID-targeted CGEvent events posted")
                    return
                }
            } else {
                self.log(
                    "[TypingService] WARNING: No target PID available for PID-targeted CGEvent insertion"
                )
            }
        } else {
            self.log(
                "[TypingService] Focus PID mismatch (focused=\(focusedPID ?? -1), target=\(targetPID ?? -1)); will try AX before PID-targeted events"
            )
        }

        // Second option: AX value insertion into the currently focused element.
        if let focusedElement {
            self.log("[TypingService] Trying AX value insertion to focused element")
            if AccessibilityTextInsertion.insertTextViaAXValue(text, into: focusedElement) {
                self.log("[TypingService] SUCCESS: AX value insertion completed")
                return
            }
        } else {
            self.log("[TypingService] WARNING: No AX focused element; skipping AX insertion")
        }

        // Next best: post Unicode events to the HID tap (system-wide focused element routes the events).
        self.log("[TypingService] AX insertion failed, trying HID-tap Unicode events")
        if self.insertTextBulkInstantToHIDTap(text) {
            self.log("[TypingService] SUCCESS: HID-tap Unicode events posted")
            return
        }

        // If we skipped the primary PID-targeted attempt due to focus mismatch, try it as a later fallback.
        if isFocusPIDMismatch, let targetPID {
            self.log(
                "[TypingService] Trying PID-targeted CGEvent insertion as fallback targeting PID \(targetPID)"
            )
            if self.insertTextBulkInstant(text, targetPID: targetPID) {
                self.log("[TypingService] SUCCESS: PID-targeted CGEvent events posted (fallback)")
                return
            }
        }

        // Optional clipboard fallback (OFF by default). Enable by setting UserDefaults bool for key
        // "enableClipboardInsertionFallback" to true.
        if UserDefaults.standard.bool(forKey: "enableClipboardInsertionFallback") {
            self.log("[TypingService] Trying clipboard insertion fallback (opt-in)")
            if self.insertTextViaClipboard(text) {
                self.log("[TypingService] SUCCESS: Clipboard insertion completed")
                return
            }
        } else {
            self.log("[TypingService] Clipboard insertion fallback disabled")
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

    private func insertTextBulkInstant(_ text: String, targetPID: pid_t) -> Bool {
        self.log(
            "[TypingService] Starting INSTANT bulk CGEvent insertion (NO CLIPBOARD) to PID \(targetPID)"
        )

        guard targetPID > 0 else {
            self.log("[TypingService] ERROR: Invalid target PID \(targetPID)")
            return false
        }

        // Convert entire text to UTF16
        let utf16Array = Array(text.utf16)
        self.log(
            "[TypingService] Converting \(text.count) characters to CGEvents (UTF16 count \(utf16Array.count))"
        )

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

    private func insertTextBulkInstantToHIDTap(_ text: String) -> Bool {
        self.log(
            "[TypingService] Starting INSTANT bulk CGEvent insertion (NO CLIPBOARD) via HID tap")

        let utf16Array = Array(text.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            self.log("[TypingService] ERROR: Failed to create HID-tap CGEvents")
            return false
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUp.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)

        keyDown.post(tap: .cghidEventTap)
        usleep(2000)
        keyUp.post(tap: .cghidEventTap)

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
        guard let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),  // 9 = 'V'
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
        usleep(10_000)  // 10ms delay
        cmdVUp.post(tap: .cghidEventTap)

        self.log("[TypingService] Cmd+V sent via clipboard insertion")

        // Brief delay then restore clipboard
        usleep(100_000)  // 100ms delay for paste to complete
        if let prev = previousContent {
            pasteboard.clearContents()
            pasteboard.setString(prev, forType: .string)
            self.log("[TypingService] Restored previous clipboard content")
        }

        return true
    }

    private func insertTextBulk(_ text: String) -> Bool {
        self.log("[TypingService] Starting bulk CGEvent insertion")

        // Get the frontmost application's PID for targeted event posting
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            self.log(
                "[TypingService] ERROR: Could not get frontmost application for bulk insertion")
            return false
        }

        let targetPID = frontApp.processIdentifier
        self.log("[TypingService] Targeting PID \(targetPID) for bulk insertion")

        // Try word-by-word insertion instead of entire text at once (faster than char-by-char but more reliable than bulk)
        let words = text.components(separatedBy: " ")
        self.log("[TypingService] Splitting text into \(words.count) words for bulk insertion")

        for (index, word) in words.enumerated() {
            let wordToType = word + (index < words.count - 1 ? " " : "")  // Add space except for last word

            if !self.insertWordViaCGEvent(wordToType, targetPID: targetPID) {
                self.log(
                    "[TypingService] Failed to insert word \(index + 1): '\(word)', falling back to character method"
                )
                return false
            }

            if index % 5 == 0 && index > 0 {
                self.log(
                    "[TypingService] Bulk insertion progress: \(index + 1)/\(words.count) words")
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
        keyDownEvent.keyboardSetUnicodeString(
            stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUpEvent.keyboardSetUnicodeString(
            stringLength: utf16Array.count, unicodeString: utf16Array)

        // Post events to specific PID
        keyDownEvent.postToPid(targetPID)
        usleep(2000)  // 2ms delay between keyDown and keyUp
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
        keyDownEvent.keyboardSetUnicodeString(
            stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUpEvent.keyboardSetUnicodeString(
            stringLength: utf16Array.count, unicodeString: utf16Array)

        // Post the events
        keyDownEvent.post(tap: .cghidEventTap)
        usleep(2000)  // Short delay between key down and up (2ms)
        keyUpEvent.post(tap: .cghidEventTap)
    }
}
