import AppKit
import ApplicationServices
import Foundation

/// Reads the focused element back after a paste to learn whether the text
/// landed. `notLanded` requires an unchanged caret plus an unchanged readable
/// value or character count in the same element through the final check.
/// Every other situation is `unknown`; clipboard evidence may independently
/// justify a neutral copy option without declaring insertion failed.
enum PasteVerifier {
    nonisolated struct Snapshot: @unchecked Sendable {
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
    private nonisolated static let maxReadableCharacters = 60_000

    nonisolated static func captureForDelivery() async -> Snapshot? {
        await Task.detached(priority: .utility) { Self.capture() }.value
    }

    nonisolated static func capture() -> Snapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let app = frontmostPID.map { AXUIElementCreateApplication($0) }
        let system = AXUIElementCreateSystemWide()
        let focused = self.element(system, kAXFocusedUIElementAttribute as CFString)
        if let focused, self.eligibleTextElement(focused) {
            var pid: pid_t = 0
            if AXUIElementGetPid(focused, &pid) == .success, pid == frontmostPID {
                return self.snapshot(focused)
            }
        }
        let appFocused = app.flatMap { self.element($0, kAXFocusedUIElementAttribute as CFString) }
        let window = app.flatMap { self.element($0, kAXFocusedWindowAttribute as CFString) }
        let windowFocused = window.flatMap { self.element($0, kAXFocusedUIElementAttribute as CFString) }
        let roots = [focused, appFocused, windowFocused, window].compactMap { $0 }.filter { element in
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success && pid == frontmostPID
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        guard let element = PasteVerificationTargetSearch.find(
            roots: roots,
            isText: { self.eligibleTextElement($0) },
            isFocused: { self.number($0, kAXFocusedAttribute as CFString) == 1 },
            children: { element in
                AXUIElementSetMessagingTimeout(element, 0.025)
                if let focused = self.element(element, kAXFocusedUIElementAttribute as CFString), !CFEqual(focused, element) { return [focused] }
                var count: CFIndex = 0
                guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success,
                      count > 0 else { return [] }
                var values: CFArray?
                guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(count, 64), &values) == .success else { return [] }
                return values as? [AXUIElement] ?? []
            },
            shouldContinue: { ProcessInfo.processInfo.systemUptime < deadline }
        ) else { return nil }
        return self.snapshot(element)
    }

    private nonisolated static func eligibleTextElement(_ element: AXUIElement) -> Bool {
        self.isTextRole(self.string(element, kAXRoleAttribute as CFString) ?? "") &&
            self.string(element, kAXSubroleAttribute as CFString) != kAXSecureTextFieldSubrole as String
    }

    private nonisolated static func snapshot(_ element: AXUIElement) -> Snapshot? {
        guard self.eligibleTextElement(element) else { return nil }
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

    nonisolated static func isTextRole(_ role: String) -> Bool {
        // Generic containers can expose dummy zero counts/ranges. They do not
        // establish what happened inside their web editor. Never read passwords.
        ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
    }

    private nonisolated static func element(_ parent: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(parent, 0.025)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Bounded read-back grace, separate from the one-second clipboard timeout.
    /// A late paste inside this window does not produce a failure verdict.
    nonisolated static let firstCheckDelay: TimeInterval = 0.15
    nonisolated static let secondCheckDelay: TimeInterval = 0.35
    nonisolated static let finalCheckDelay: TimeInterval = 1.5
    nonisolated static var totalDecisionDelay: TimeInterval { self.firstCheckDelay + self.secondCheckDelay + self.finalCheckDelay }

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

        guard Self.isTextRole(before.role) else { return .unknown(reason: "before_not_text_editor") }
        var unreadable = false
        for (index, delay) in [self.firstCheckDelay, self.secondCheckDelay, self.finalCheckDelay].enumerated() {
            guard await wait(delay) else { return .unknown(reason: "cancelled") }
            guard let after = capture() else {
                unreadable = true
                continue
            }
            guard CFEqual(after.element, before.element) else { return .unknown(reason: "focus_moved") }
            if let verdict = self.confirmation(before: before, after: after, needle: needle) { return verdict }
            if let verdict = self.unchangedVerdict(before: before, after: after) { return verdict }
            if index == 2 {
                // A missing sample could hide an edit/send between reads.
                return unreadable ? .unknown(reason: "intermittent_read_failure") : .notLanded(reason: "value_count_caret_unchanged")
            }
        }
        return .unknown(reason: "after_unreadable")
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
        AXUIElementSetMessagingTimeout(element, 0.025)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    private nonisolated static func number(_ element: AXUIElement, _ attribute: CFString) -> Int? {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.intValue
    }

    private nonisolated static func range(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(ref, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }
}

/// Bounded search only accepts a directly focused text control or a descendant
/// explicitly marked focused. A nearby but unfocused composer is never selected.
enum PasteVerificationTargetSearch {
    nonisolated static func find<Node: Equatable>(
        roots: [Node], isText: (Node) -> Bool, isFocused: (Node) -> Bool,
        children: (Node) -> [Node], maxNodes: Int = 64,
        shouldContinue: () -> Bool = { true }
    ) -> Node? {
        var pending = roots.map { ($0, true) }
        var visited: [Node] = []
        var index = 0
        while index < pending.count, visited.count < maxNodes, shouldContinue() {
            let (node, direct) = pending[index]
            index += 1
            guard !visited.contains(node) else { continue }
            visited.append(node)
            if isText(node), direct || isFocused(node) { return node }
            pending.append(contentsOf: children(node).prefix(max(0, maxNodes - pending.count)).map { ($0, false) })
        }
        return nil
    }
}

/// These are independent signals: no clipboard consumer plus no readable editor
/// warrants a copy option, never a claim that insertion definitely failed.
@MainActor
final class PasteRecoveryEvidence {
    enum Recovery: Equatable { case notLanded, unverified }
    private var verdict: PasteVerifier.Verdict?
    private var unread = false
    private var reported = false
    private let report: (Recovery) -> Void

    init(report: @escaping (Recovery) -> Void) { self.report = report }

    func clipboardTimedOut() { self.unread = true; self.evaluate() }
    func verified(_ verdict: PasteVerifier.Verdict) {
        guard self.verdict == nil else { return }
        self.verdict = verdict
        self.evaluate()
    }

    private func evaluate() {
        guard !self.reported, let verdict else { return }
        let recovery: Recovery
        switch verdict {
        case .confirmed: return
        case .notLanded: recovery = .notLanded
        case .unknown:
            guard self.unread else { return }
            recovery = .unverified
        }
        self.reported = true
        self.report(recovery)
    }
}

/// At most one recent recovery waits for the current recording to finish.
/// Notifications carry text only; this never sends keys or writes the clipboard.
@MainActor
final class PasteRecoveryInbox {
    struct Entry {
        let id: UInt64
        let transcript: String
        let unverified: Bool
        let expiresAt: TimeInterval
    }

    private var newestID: UInt64 = 0
    private var pending: Entry?
    static let lifetime: TimeInterval = 30

    @discardableResult
    func submit(id: UInt64, transcript: String, unverified: Bool, now: TimeInterval, alertsEnabled: Bool) -> Bool {
        guard alertsEnabled, id > self.newestID, !transcript.isEmpty else { return false }
        self.newestID = id
        self.pending = Entry(id: id, transcript: transcript, unverified: unverified, expiresAt: now + Self.lifetime)
        return true
    }

    var pendingID: UInt64? { self.pending?.id }

    enum Disposition: String { case none, alertsDisabled, expired, waitingForIdle, ready }

    func disposition(now: TimeInterval, isBusy: Bool, alertsEnabled: Bool) -> Disposition {
        guard self.pending != nil else { return .none }
        guard alertsEnabled else { return .alertsDisabled }
        guard let pending = self.pending, now < pending.expiresAt else { return .expired }
        return isBusy ? .waitingForIdle : .ready
    }

    func take(now: TimeInterval, isBusy: Bool, alertsEnabled: Bool) -> Entry? {
        guard alertsEnabled, let pending = self.pending, now < pending.expiresAt else {
            self.pending = nil
            return nil
        }
        guard !isBusy else { return nil }
        self.pending = nil
        return pending
    }

    func expire(now: TimeInterval) {
        if let pending, now >= pending.expiresAt { self.pending = nil }
    }
}

/// Monotonic identity for deduplicating read-only recovery notices. Starting a
/// recording does not invalidate evidence belonging to the preceding delivery.
@MainActor
final class PasteRecoverySequence {
    static let shared = PasteRecoverySequence()
    private var generation: UInt64 = 0

    nonisolated deinit {}

    func nextID() -> UInt64 {
        self.generation &+= 1
        return self.generation
    }
}

extension Notification.Name {
    /// Posted on the main queue with `userInfo["transcript"]` when a paste
    /// has a verified miss, or no clipboard consumer and unverifiable insertion.
    /// `unverified` distinguishes a copy option from a definite failure.
    static let fluidPasteRecoveryAvailable = Notification.Name("com.FluidApp.pasteRecoveryAvailable")
}
