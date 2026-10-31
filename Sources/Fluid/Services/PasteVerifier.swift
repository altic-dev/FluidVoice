import AppKit
import ApplicationServices
import Foundation

/// Reads the focused element back after a paste to learn whether the text
/// landed. `notLanded` requires an unchanged caret plus an unchanged readable
/// value or character count in the same element through the final check.
/// Every other situation is `unknown`, and the caller stays silent.
enum PasteVerifier {
    struct Snapshot {
        let element: AXUIElement
        let pid: pid_t
        let role: String
        let value: String?
        let characterCount: Int?
        let caret: CFRange?

        var summary: String {
            "role=\(self.role) valueLen=\(self.value.map { String($0.count) } ?? "nil") " +
                "chars=\(self.characterCount.map(String.init) ?? "nil") " +
                "caret=\(self.caret.map { "\($0.location)+\($0.length)" } ?? "nil")"
        }
    }

    enum Verdict: Equatable {
        case confirmed(method: String)
        case notLanded(reason: String)
        case unknown(reason: String)

        var logDescription: String {
            switch self {
            case let .confirmed(method): "confirmed method=\(method)"
            case let .notLanded(reason): "notLanded reason=\(reason)"
            case let .unknown(reason): "unknown reason=\(reason)"
            }
        }
    }

    /// Value reads are skipped above this size; count and caret still work.
    private static let maxReadableCharacters = 60_000

    nonisolated static func capture() -> Snapshot? {
        guard AXIsProcessTrusted() else { return nil }
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let role = self.string(element, kAXRoleAttribute as CFString) ?? "unknown"
        let count = self.number(element, kAXNumberOfCharactersAttribute as CFString)
        let value: String? = (count ?? 0) <= self.maxReadableCharacters
            ? self.string(element, kAXValueAttribute as CFString)
            : nil
        return Snapshot(
            element: element,
            pid: pid,
            role: role,
            value: value,
            characterCount: count,
            caret: self.range(element, kAXSelectedTextRangeAttribute as CFString)
        )
    }

    /// Bounded read-back grace, separate from the one-second clipboard timeout.
    /// A late paste inside this window does not produce a failure verdict.
    static let firstCheckDelay: TimeInterval = 0.15
    static let secondCheckDelay: TimeInterval = 0.35
    static let finalCheckDelay: TimeInterval = 1.5
    static var totalDecisionDelay: TimeInterval { self.firstCheckDelay + self.secondCheckDelay + self.finalCheckDelay }

    /// A key press or click after the paste means the user acted on the field
    /// (typically Return to send), so an unchanged field proves nothing.
    nonisolated static func userActedAfterPaste(secondsSinceLastInput: TimeInterval, secondsSincePaste: TimeInterval) -> Bool {
        // Our own synthesized V key lands at the paste instant; ignore that window.
        secondsSinceLastInput < secondsSincePaste - 0.05
    }

    nonisolated static func secondsSinceLastUserInput() -> TimeInterval {
        min(
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .rightMouseDown),
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .otherMouseDown)
        )
    }

    /// Call off the main thread after the paste command was posted.
    nonisolated static func verify(
        before: Snapshot,
        pastedText: String,
        capture: () -> Snapshot? = { Self.capture() },
        wait: (TimeInterval) async -> Bool = { delay in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return !Task.isCancelled
            } catch {
                return false
            }
        }
    ) async -> Verdict {
        let needle = self.normalize(pastedText)
        guard !needle.isEmpty else { return .unknown(reason: "empty_text") }
        guard before.value != nil || before.characterCount != nil || before.caret != nil else {
            return .unknown(reason: "before_unreadable")
        }

        guard await wait(self.firstCheckDelay) else { return .unknown(reason: "cancelled") }
        guard let first = capture() else { return .unknown(reason: "after_unreadable") }
        guard CFEqual(first.element, before.element) else { return .unknown(reason: "focus_moved") }

        if let verdict = self.confirmation(before: before, after: first, needle: needle) { return verdict }

        // Nothing changed yet. Give slow apps a second chance before deciding.
        guard await wait(self.secondCheckDelay) else { return .unknown(reason: "cancelled") }
        guard let second = capture(), CFEqual(second.element, before.element) else {
            return .unknown(reason: "focus_moved_late")
        }
        if let verdict = self.confirmation(before: before, after: second, needle: needle) { return verdict }
        if let verdict = self.unchangedVerdict(before: before, after: second) { return verdict }

        // Still unchanged. A failure card is disruptive, so wait once more for
        // apps that apply Cmd+V on a later run-loop turn before deciding.
        guard await wait(self.finalCheckDelay) else { return .unknown(reason: "cancelled") }
        guard let final = capture(), CFEqual(final.element, before.element) else {
            return .unknown(reason: "focus_moved_final")
        }
        if let verdict = self.confirmation(before: before, after: final, needle: needle) { return verdict }
        return self.unchangedVerdict(before: before, after: final) ?? .notLanded(reason: "value_count_caret_unchanged")
    }

    /// `unknown` when the signals are incomplete or something other than the
    /// pasted text changed; nil when everything is exactly as before.
    private nonisolated static func unchangedVerdict(before: Snapshot, after: Snapshot) -> Verdict? {
        let valueKnown = before.value != nil && after.value != nil
        let countKnown = before.characterCount != nil && after.characterCount != nil
        let caretKnown = before.caret != nil && after.caret != nil
        guard valueKnown || countKnown, caretKnown else {
            return .unknown(reason: "signals_incomplete value=\(valueKnown) count=\(countKnown) caret=\(caretKnown)")
        }
        guard !valueKnown || before.value == after.value,
              !countKnown || before.characterCount == after.characterCount,
              before.caret?.location == after.caret?.location,
              before.caret?.length == after.caret?.length
        else { return .unknown(reason: "changed_without_text") }
        return nil
    }

    private nonisolated static func confirmation(before: Snapshot, after: Snapshot, needle: String) -> Verdict? {
        if let afterValue = after.value {
            let beforeCount = before.value.map { self.occurrences(of: needle, in: self.normalize($0)) } ?? 0
            if self.occurrences(of: needle, in: self.normalize(afterValue)) > beforeCount {
                return .confirmed(method: "value")
            }
        }
        let insertedLength = needle.utf16.count
        let countDelta = insertedLength - (before.caret?.length ?? 0)
        if let beforeCount = before.characterCount, let afterCount = after.characterCount,
           afterCount != beforeCount,
           afterCount - beforeCount == countDelta || afterCount - beforeCount == countDelta + 1
        {
            return .confirmed(method: "count")
        }
        if let beforeCaret = before.caret, let afterCaret = after.caret,
           afterCaret.location - beforeCaret.location == insertedLength,
           afterCaret.length == 0
        {
            return .confirmed(method: "caret")
        }
        return nil
    }

    private nonisolated static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    private nonisolated static func number(_ element: AXUIElement, _ attribute: CFString) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.intValue
    }

    private nonisolated static func range(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(ref, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }
}

/// Warning identity only: never controls capture, clipboard writes or retries.
/// A new delivery/recording invalidates older checks across TypingService instances.
@MainActor
final class PasteRecoveryPresentationPolicy {
    static let shared = PasteRecoveryPresentationPolicy()
    private var generation: UInt64 = 0
    private var presentedGeneration: UInt64?

    nonisolated deinit {}

    @discardableResult
    func beginDelivery() -> UInt64 {
        self.generation &+= 1
        return self.generation
    }

    func isCurrent(_ id: UInt64) -> Bool { self.generation == id }

    func claim(_ id: UInt64, alertsEnabled: Bool, isBusy: Bool, userActed: Bool) -> Bool {
        guard alertsEnabled, !isBusy, !userActed, self.isCurrent(id), self.presentedGeneration != id else { return false }
        self.presentedGeneration = id
        return true
    }
}

extension Notification.Name {
    /// Posted on the main queue with `userInfo["transcript"]` when a paste
    /// was verified to not land.
    static let fluidPasteNotLanded = Notification.Name("com.FluidApp.pasteNotLanded")
}
