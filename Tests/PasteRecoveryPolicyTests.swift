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

        // A six-unit selection replaced by five units expects -1. The optional
        // newline tolerance must never turn an unchanged count into success.
        let longerSelection = self.snapshot("xxxxxx", count: 6, caret: CFRange(location: 0, length: 6))
        let blockedReplacement = await self.verify(longerSelection, [longerSelection])
        guard blockedReplacement.0 == .notLanded(reason: "value_count_caret_unchanged") else {
            print("FAIL: a blocked six-to-five replacement was reported as successful: \(blockedReplacement.0)")
            exit(1)
        }
        precondition(blockedReplacement.1.count == 3 && blockedReplacement.1.reduce(0, +) == 2)

        let countOnlySelection = self.snapshot(nil, count: 6, caret: CFRange(location: 0, length: 6))
        let blockedCountOnly = await self.verify(countOnlySelection, [countOnlySelection])
        precondition(blockedCountOnly.0 == .notLanded(reason: "value_count_caret_unchanged"))
        let shorterReplacement = await self.verify(countOnlySelection, [replacementAfter])
        precondition(shorterReplacement.0 == .confirmed(method: "count"), "An actual shorter replacement must still confirm")

        let selectedEmoji = self.snapshot(nil, count: 3, caret: CFRange(location: 0, length: 3))
        let blockedEmoji = await self.verify(selectedEmoji, [selectedEmoji], text: "😀")
        precondition(blockedEmoji.0 == .notLanded(reason: "value_count_caret_unchanged"))
        let shorterEmoji = await self.verify(selectedEmoji, [emojiAfter], text: "😀")
        precondition(shorterEmoji.0 == .confirmed(method: "count"))

        let newlineAfter = self.snapshot(nil, count: 6, caret: nil)
        let newlineInsertion = await self.verify(emojiBefore, [newlineAfter])
        precondition(newlineInsertion.0 == .confirmed(method: "count"), "An actual +1 newline count change must still confirm")
        let equalLengthWithNewline = await self.verify(replacementBefore, [newlineAfter])
        precondition(equalLengthWithNewline.0 == .confirmed(method: "count"), "Equal-length replacement with an actual extra newline must still confirm")
        let longerSelectionWithNewline = self.snapshot(nil, count: 8, caret: CFRange(location: 0, length: 8))
        let shorterWithNewline = await self.verify(longerSelectionWithNewline, [newlineAfter])
        precondition(shorterWithNewline.0 == .confirmed(method: "count"), "A shrinking replacement with newline tolerance must still confirm")
        print("PASS: blocked one-unit-shorter replacements never confirm unchanged counts; real replacements, emoji and newline tolerance still confirm")

        let container = PasteVerifier.Snapshot(element: self.element, pid: getpid(), role: "AXGroup", value: "", characterCount: 0, caret: CFRange(location: 0, length: 0))
        guard case .unknown = await self.verify(container, [container]).0 else {
            fatalError("A container is not evidence of an unchanged editor")
        }
        let recovered = await self.verify(before, [nil, before, inserted])
        precondition(recovered.0 == .confirmed(method: "value"), "A transient unreadable sample must not abandon later insertion evidence")

        // Focused descendants are eligible; merely finding an editor is not enough.
        let graph = [0: [1, 2], 1: [0], 2: [3]]
        func find(_ roots: [Int], focused: Set<Int>, limit: Int = 64, proceed: Bool = true) -> Int? {
            PasteVerificationTargetSearch.find(roots: roots, isText: { $0 == 1 || $0 == 3 }, isFocused: { focused.contains($0) }, children: { graph[$0] ?? [] }, maxNodes: limit, shouldContinue: { proceed })
        }
        precondition(find([0], focused: [3]) == 3)
        precondition(find([0], focused: []) == nil, "An unfocused composer must not become the destination")
        precondition(find([1], focused: []) == 1, "A directly focused text field does not need a duplicate focused attribute")
        precondition(find([0], focused: [3], limit: 2) == nil)
        precondition(find([0], focused: [3], proceed: false) == nil)
        precondition(find([], focused: [3]) == nil)
        precondition(!PasteVerifier.isTextRole("AXGroup"))
        precondition(!PasteVerifier.isTextRole("AXSecureTextField"))

        var recoveries: [PasteRecoveryEvidence.Recovery] = []
        let evidence = PasteRecoveryEvidence { recoveries.append($0) }
        evidence.verified(.unknown(reason: "baseline_unavailable"))
        precondition(recoveries.isEmpty, "An unreadable editor alone must not spam a copy card")
        evidence.clipboardTimedOut()
        evidence.clipboardTimedOut()
        precondition(recoveries == [.unverified], "Unread clipboard plus unknown insertion offers one honest recovery")
        let confirmed = PasteRecoveryEvidence { recoveries.append($0) }
        confirmed.clipboardTimedOut()
        confirmed.verified(.confirmed(method: "value"))
        confirmed.verified(.unknown(reason: "duplicate_stale_result"))
        precondition(recoveries == [.unverified], "Confirmed insertion overrides a clipboard timeout")
        let reversed = PasteRecoveryEvidence { recoveries.append($0) }
        reversed.clipboardTimedOut()
        reversed.verified(.unknown(reason: "focus_moved"))
        precondition(recoveries == [.unverified, .unverified])
        let definite = PasteRecoveryEvidence { recoveries.append($0) }
        definite.verified(.notLanded(reason: "unchanged"))
        precondition(recoveries.last == .notLanded, "A readable unchanged editor does not require a clipboard timeout")

        let inbox = PasteRecoveryInbox()
        inbox.submit(id: 1, transcript: "earlier miss", unverified: true, now: 0, alertsEnabled: true)
        precondition(inbox.disposition(now: 1, isBusy: true, alertsEnabled: true) == .waitingForIdle)
        precondition(inbox.take(now: 1, isBusy: true, alertsEnabled: true) == nil)
        precondition(inbox.disposition(now: 2, isBusy: false, alertsEnabled: true) == .ready)
        let deferred = inbox.take(now: 2, isBusy: false, alertsEnabled: true)
        precondition(deferred?.transcript == "earlier miss" && deferred?.unverified == true, "The next recording must defer, not lose the recovery")
        inbox.submit(id: 1, transcript: "duplicate", unverified: false, now: 3, alertsEnabled: true)
        precondition(inbox.take(now: 3, isBusy: false, alertsEnabled: true) == nil)
        inbox.submit(id: 3, transcript: "newer miss", unverified: false, now: 4, alertsEnabled: true)
        inbox.submit(id: 2, transcript: "stale late result", unverified: true, now: 5, alertsEnabled: true)
        precondition(inbox.take(now: 6, isBusy: false, alertsEnabled: true)?.transcript == "newer miss")
        inbox.submit(id: 4, transcript: "expired", unverified: true, now: 0, alertsEnabled: true)
        inbox.expire(now: PasteRecoveryInbox.lifetime)
        precondition(inbox.take(now: 31, isBusy: false, alertsEnabled: true) == nil)
        inbox.submit(id: 5, transcript: "opted out", unverified: true, now: 32, alertsEnabled: false)
        precondition(inbox.take(now: 33, isBusy: false, alertsEnabled: true) == nil)
        inbox.submit(id: 6, transcript: "opted out later", unverified: true, now: 34, alertsEnabled: true)
        precondition(inbox.take(now: 35, isBusy: false, alertsEnabled: false) == nil)
        precondition(inbox.take(now: 36, isBusy: false, alertsEnabled: true) == nil)
        print("PASS: bounded focused-editor search, transient reads, combined clipboard/field evidence and deferred recovery")

        let sequence = PasteRecoverySequence()
        let firstID = sequence.nextID()
        precondition(sequence.nextID() > firstID)
        print("PASS: late insertion, definite misses, partial signals, changed fields, focus loss, unreadable/cancelled checks, UTF-16, selection replacement")
        print("PASS: opt-out, busy deferral, duplicate/stale checks and distinct genuine failures")
    }
}
