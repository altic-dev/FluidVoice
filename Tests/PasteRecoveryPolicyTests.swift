import AppKit
import ApplicationServices

@main
@MainActor
enum PasteRecoveryPolicyTests {
    static let element = AXUIElementCreateApplication(getpid())

    static func snapshot(_ value: String? = "", count: Int? = 0, caret: CFRange? = CFRange(location: 0, length: 0), element: AXUIElement? = nil) -> PasteVerifier.Snapshot {
        .init(element: element ?? self.element, pid: getpid(), role: "AXTextArea", value: value, characterCount: count, caret: caret)
    }

    static func verify(_ before: PasteVerifier.Snapshot, _ after: [PasteVerifier.Snapshot?], text: String = "hello") async -> (PasteVerifier.Verdict, [TimeInterval]) {
        var index = 0
        var waits: [TimeInterval] = []
        let result = await PasteVerifier.verify(
            before: before,
            pastedText: text,
            capture: {
                defer { index += 1 }
                return after[min(index, after.count - 1)]
            },
            wait: { delay in waits.append(delay); return true }
        )
        return (result, waits)
    }

    static func main() async {
        let before = self.snapshot()
        let inserted = self.snapshot("hello", count: 5, caret: CFRange(location: 5, length: 0))
        let late = await self.verify(before, [before, before, inserted])
        precondition(late.0 == .confirmed(method: "value"))
        precondition(late.1.reduce(0, +) == 2, "A late paste must get the full grace window")

        let miss = await self.verify(before, [before, before, before])
        precondition(miss.0 == .notLanded(reason: "value_count_caret_unchanged"))
        precondition(miss.1.count == 3 && miss.1.reduce(0, +) == 2)

        let noCount = self.snapshot(count: nil)
        let result1 = await self.verify(noCount, [noCount]).0
        precondition(result1 == .notLanded(reason: "value_count_caret_unchanged"))
        let noValue = self.snapshot(nil)
        let result2 = await self.verify(noValue, [noValue]).0
        precondition(result2 == .notLanded(reason: "value_count_caret_unchanged"))
        let noCaret = self.snapshot(caret: nil)
        guard case .unknown = await self.verify(noCaret, [noCaret]).0 else { fatalError("Incomplete evidence must not warn") }

        let changed = self.snapshot("other", count: 5, caret: CFRange(location: 2, length: 0))
        // Use an equal-length replacement so unchanged-count evidence cannot
        // mistake the unrelated editor change for a failed paste.
        let selected = self.snapshot("xxxxx", count: 5, caret: CFRange(location: 0, length: 5))
        guard case .unknown = await self.verify(selected, [changed]).0 else { fatalError("Other changes must stand down") }

        let moved = self.snapshot(element: AXUIElementCreateSystemWide())
        let result3 = await self.verify(before, [moved]).0
        precondition(result3 == .unknown(reason: "focus_moved"))
        let result4 = await self.verify(before, [nil]).0
        precondition(result4 == .unknown(reason: "after_unreadable"))
        let cancelled = await PasteVerifier.verify(before: before, pastedText: "hello", capture: { fatalError("Cancelled verification must not read AX") }, wait: { _ in false })
        precondition(cancelled == .unknown(reason: "cancelled"))

        let emojiBefore = self.snapshot(nil)
        let emojiAfter = self.snapshot(nil, count: 2, caret: CFRange(location: 2, length: 0))
        let result5 = await self.verify(emojiBefore, [emojiAfter], text: "😀").0
        precondition(result5 == .confirmed(method: "count"))
        let replacementAfter = self.snapshot(nil, count: 5, caret: CFRange(location: 5, length: 0))
        let replacementBefore = self.snapshot(nil, count: 5, caret: CFRange(location: 0, length: 5))
        let result6 = await self.verify(replacementBefore, [replacementAfter]).0
        precondition(result6 == .confirmed(method: "caret"))

        let policy = PasteRecoveryPresentationPolicy()
        let first = policy.beginDelivery()
        precondition(!policy.claim(first, alertsEnabled: false, isBusy: false, userActed: false))
        precondition(!policy.claim(first, alertsEnabled: true, isBusy: true, userActed: false))
        precondition(!policy.claim(first, alertsEnabled: true, isBusy: false, userActed: true))
        precondition(policy.claim(first, alertsEnabled: true, isBusy: false, userActed: false), "Suppressed checks must not consume a valid recovery")
        precondition(!policy.claim(first, alertsEnabled: true, isBusy: false, userActed: false), "A duplicate must not reopen the card")
        let second = policy.beginDelivery()
        precondition(!policy.claim(first, alertsEnabled: true, isBusy: false, userActed: false))
        precondition(policy.claim(second, alertsEnabled: true, isBusy: false, userActed: false), "A distinct genuine miss must not be hidden by a cooldown")
        let pending = policy.beginDelivery()
        _ = policy.beginDelivery() // New recording supersedes a pending check.
        precondition(!policy.claim(pending, alertsEnabled: true, isBusy: false, userActed: false))
        print("PASS: late insertion, definite misses, partial signals, changed fields, focus loss, unreadable/cancelled checks, UTF-16, selection replacement")
        print("PASS: opt-out, busy/user activity suppression, duplicate/stale checks and distinct genuine failures")
    }
}
