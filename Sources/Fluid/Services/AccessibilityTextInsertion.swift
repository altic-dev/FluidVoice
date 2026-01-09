import ApplicationServices
import Foundation

/// Helpers for inserting text into the currently focused UI element using macOS Accessibility APIs.
///
/// This is preferred for "floating" panels (launchers/search bars) where the focused field may not
/// belong to the app that `NSWorkspace.shared.frontmostApplication` reports, and where posting events
/// to a specific PID can be unreliable.
enum AccessibilityTextInsertion {
    /// Returns the system-wide focused UI element, if available.
    static func systemFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success, let focused else { return nil }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focused, to: AXUIElement.self)
    }

    /// Returns the owning PID for a given AX element.
    static func owningPID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        guard result == .success, pid > 0 else { return nil }
        return pid
    }

    /// Attempts to insert text into an AX text field by setting `kAXValueAttribute`, respecting
    /// the current `kAXSelectedTextRangeAttribute` when available.
    ///
    /// - Returns: true iff we successfully set the value attribute (best-effort cursor restoration).
    static func insertTextViaAXValue(_ text: String, into element: AXUIElement) -> Bool {
        guard text.isEmpty == false else { return false }

        // Ensure the element supports setting kAXValueAttribute.
        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        guard settableResult == .success, settable.boolValue else { return false }

        // Read the current value (must be a String for our purposes).
        var valueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard valueResult == .success else { return false }

        let currentValue: String
        if let s = valueRef as? String {
            currentValue = s
        } else if valueRef == nil {
            currentValue = ""
        } else {
            return false
        }

        let currentNSString = currentValue as NSString

        // Determine insertion range (selection). If unavailable, insert at end.
        var selectionRange = NSRange(location: currentNSString.length, length: 0)
        if let selected = copySelectedTextRange(from: element) {
            let maxLen = currentNSString.length
            let safeLocation = max(0, min(selected.location, maxLen))
            let safeEnd = max(0, min(selected.location + selected.length, maxLen))
            selectionRange = NSRange(location: safeLocation, length: safeEnd - safeLocation)
        }

        // Replace selection with new text.
        let newValue = currentNSString.replacingCharacters(in: selectionRange, with: text)
        let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef)
        guard setResult == .success else { return false }

        // Best-effort cursor restore: set selection to end of inserted text.
        let insertionEnd = selectionRange.location + (text as NSString).length
        _ = self.setSelectedTextRange(
            NSRange(location: insertionEnd, length: 0),
            on: element
        )

        return true
    }

    private static func copySelectedTextRange(from element: AXUIElement) -> NSRange? {
        var rangeRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        )
        guard result == .success, let rangeRef else { return nil }
        guard CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }

        let axValue = unsafeBitCast(rangeRef, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var cfRange = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else { return nil }

        return NSRange(location: cfRange.location, length: cfRange.length)
    }

    @discardableResult
    private static func setSelectedTextRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &settable
        )
        guard settableResult == .success, settable.boolValue else { return false }

        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return false }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        )
        return result == .success
    }
}
