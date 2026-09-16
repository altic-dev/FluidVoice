//
//  LiveTypingAXTarget.swift
//  Fluid
//
//  Accessibility read/write primitives for the experimental Live Typing path.
//

import ApplicationServices
import AppKit
import Foundation

/// What the focused field actually, verifiably supports.
///
/// Produced by a strictly read-only probe: it reads attributes and asks the
/// Accessibility server whether they are settable. It never writes, so running
/// it can not modify the user's text.
nonisolated struct LiveTypingCapabilities: Equatable {
    let role: String?
    let subrole: String?
    let canReadValue: Bool
    let canReadSelection: Bool
    let valueIsSettable: Bool
    let selectedTextIsSettable: Bool
    let isSecure: Bool

    /// The level the target can be expected to support, before any write.
    ///
    /// Level 1 needs a settable value (read, revise, verify). Level 2 only needs
    /// a settable selection, because it appends stabilised chunks at the caret.
    /// Anything else is Level 3, the behaviour the app has always had.
    var predictedLevel: LiveTypingLevel {
        if self.isSecure || !self.canReadValue || !self.canReadSelection {
            return .finalOnly
        }
        if self.valueIsSettable {
            return .full
        }
        if self.selectedTextIsSettable {
            return .committedChunks
        }
        return .finalOnly
    }

    /// One-line report shown in Settings, so a user can certify a given app.
    var summary: String {
        let target = self.role ?? "unknown field"
        let level = self.predictedLevel.rawValue
        if self.isSecure {
            return "\(target): secure field, never streamed into. Level 3 (final paste)."
        }
        if self.predictedLevel == .finalOnly {
            return "\(target): value not readable/writable. Level 3 (final paste)."
        }
        return "\(target): readable=\(self.canReadValue) range=\(self.canReadSelection) "
            + "valueSettable=\(self.valueIsSettable) selectionSettable=\(self.selectedTextIsSettable) "
            + "-> Level \(level)"
    }
}

/// Thin Accessibility wrapper around the focused text field.
///
/// It reuses the same primitives the existing cursor-insertion path already
/// relies on (`kAXValueAttribute` + `kAXSelectedTextRangeAttribute`), but it only
/// ever replaces a range it is explicitly handed. It never deletes anything on
/// its own, and it never assumes an attribute is available: every read can fail
/// and every caller must handle that.
struct LiveTypingAXTarget {
    let pid: pid_t
    let element: AXUIElement
    let bundleIdentifier: String?

    /// Resolves the focused element, reusing the same system-wide lookup the
    /// typing service uses. Returns nil when Accessibility is not granted or when
    /// the focused element is not a text field.
    static func capture(preferredPID: pid_t?) -> LiveTypingAXTarget? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0 else { return nil }
        // A session may only continue in the process it started in.
        if let preferredPID, preferredPID > 0, pid != preferredPID { return nil }

        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        return LiveTypingAXTarget(pid: pid, element: element, bundleIdentifier: bundle)
    }

    /// Secure fields must never be streamed into.
    func isSecure() -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            self.element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success, let subrole = value as? String else {
            // Unknown subrole: treat it as unavailable rather than risk a secure
            // field. The caller falls back to final-only delivery.
            return true
        }
        return subrole == (kAXSecureTextFieldSubrole as String)
            || subrole.localizedCaseInsensitiveContains("secure")
    }

    func value() -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            self.element,
            kAXValueAttribute as CFString,
            &value
        )
        guard result == .success, let text = value as? String else { return nil }
        return text
    }

    func selection() -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            self.element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else {
            return nil
        }
        return range
    }

    /// Replaces exactly `range` with `text` and puts the caret after the new
    /// text. Returns false without touching the field whenever the value cannot
    /// be read or the range does not fit.
    func replace(range: NSRange, with text: String) -> Bool {
        guard let current = self.value() else { return false }
        let currentText = current as NSString
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= currentText.length
        else { return false }

        let mutable = NSMutableString(string: current)
        mutable.replaceCharacters(in: range, with: text)
        let updated = mutable as String

        if AXUIElementSetAttributeValue(
            self.element,
            kAXValueAttribute as CFString,
            updated as CFString
        ) == .success {
            self.moveCaret(to: range.location + (text as NSString).length)
            return true
        }

        // Level 2 fallback: select the owned range and replace the selection.
        // Used by fields that expose a settable selection but not a settable
        // value.
        var selection = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &selection),
              AXUIElementSetAttributeValue(
                  self.element,
                  kAXSelectedTextRangeAttribute as CFString,
                  axRange
              ) == .success,
              AXUIElementSetAttributeValue(
                  self.element,
                  kAXSelectedTextAttribute as CFString,
                  text as CFString
              ) == .success
        else { return false }
        return true
    }

    private func moveCaret(to location: Int) {
        var caret = CFRange(location: location, length: 0)
        if let axRange = AXValueCreate(.cfRange, &caret) {
            _ = AXUIElementSetAttributeValue(
                self.element,
                kAXSelectedTextRangeAttribute as CFString,
                axRange
            )
        }
    }

    private func stringAttribute(_ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self.element, attribute, &value)
        guard result == .success, let text = value as? String else { return nil }
        return text
    }

    private func isSettable(_ attribute: CFString) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(self.element, attribute, &settable)
        return result == .success && settable.boolValue
    }

    /// Read-only capability probe. Never writes.
    func capabilities() -> LiveTypingCapabilities {
        let role = self.stringAttribute(kAXRoleAttribute as CFString)
        let subrole = self.stringAttribute(kAXSubroleAttribute as CFString)
        let isSecure = subrole == (kAXSecureTextFieldSubrole as String)
            || (subrole ?? "").localizedCaseInsensitiveContains("secure")
        return LiveTypingCapabilities(
            role: role,
            subrole: subrole,
            canReadValue: self.value() != nil,
            canReadSelection: self.selection() != nil,
            valueIsSettable: self.isSettable(kAXValueAttribute as CFString),
            selectedTextIsSettable: self.isSettable(kAXSelectedTextAttribute as CFString),
            isSecure: isSecure
        )
    }

    /// Reads the substring at a range, used to verify a write after the fact.
    func substring(at range: NSRange) -> String? {
        guard let current = self.value() else { return nil }
        let text = current as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }
}
