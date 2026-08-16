import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

final class TextSelectionService {
    static let shared = TextSelectionService()

    private init() {}

    /// Attempts to get the currently selected text using Accessibility APIs
    func getSelectedText() -> String? {
        self.diag("Selection capture start")

        // Check accessibility permissions
        guard AXIsProcessTrusted() else {
            DebugLogger.shared.error("Accessibility permissions not granted", source: "TextSelectionService")
            self.diag("Selection capture failed: Accessibility permissions not granted")
            return nil
        }

        // 1. Try to get the system-wide focused element
        if let focusedElement = getFocusedElement() {
            if let text = getSelectedText(from: focusedElement) {
                self.diag("Selection capture success via system focused element (chars=\(text.count))")
                return text
            }
            self.diag("System focused element returned no selected text")
        }

        // 2. Fallback: Try to find focused element in frontmost app
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            self.diag("Trying frontmost app fallback: \(frontmostApp.bundleIdentifier ?? frontmostApp.localizedName ?? "unknown") pid=\(frontmostApp.processIdentifier)")
            let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
            if let focusedElement = getFocusedElement(from: appElement) {
                if let text = getSelectedText(from: focusedElement) {
                    self.diag("Selection capture success via frontmost app focused element (chars=\(text.count))")
                    return text
                }
                self.diag("Frontmost app focused element returned no selected text")
            } else {
                self.diag("Frontmost app fallback could not resolve focused element")
            }
        }

        // 3. Final fallback: synthetic Cmd+C, read the pasteboard, restore it.
        // Electron / GPU-rendered editors (Zed, VS Code, Obsidian, web editors in Chrome)
        // frequently don't expose the focused element or selection through the AX tree, so
        // both AX strategies above return nothing. Copying the live selection is the only
        // reliable way to read it from those apps (issue #259).
        if let text = getSelectedTextViaClipboard() {
            return text
        }

        self.diag("Selection capture failed: no selected text found")
        return nil
    }

    // MARK: - Private Helpers

    /// Reads the current selection by synthesizing Cmd+C, polling the pasteboard for the
    /// resulting write, then restoring the user's previous pasteboard contents. This is a
    /// last resort used only when the Accessibility tree yields no selection.
    ///
    /// Runs synchronously on the caller's thread (the main thread for Write/Rewrite mode);
    /// the poll is bounded by `Self.clipboardCopyTimeoutMicros` so a missing selection (no
    /// pasteboard write) degrades to `nil` quickly rather than hanging.
    private func getSelectedTextViaClipboard() -> String? {
        // Coordinate with TypingService's pasteboard session. A paste insertion keeps the
        // user's clipboard "in flight" — it writes the to-be-pasted text, posts Cmd+V, and
        // restores the snapshot on a background queue up to several seconds later — all under
        // the shared `PasteboardSession`. If we sampled `changeCount` and posted our Cmd+C
        // while that restore was still pending, the paste's writes would masquerade as our
        // copy (wrong selection captured) and our snapshot/restore would fight the paste's.
        // Acquiring the same session makes the two mutually exclusive (issue #259).
        //
        // This runs on the main thread for Write/Rewrite mode, so the acquire is short and
        // BOUNDED. The timeout is load-bearing for deadlock-freedom, not just UX: the paste
        // path holds the session while running its paste closure, which resolves the
        // layout-aware Cmd+V key code via `LayoutAwareKeyCode`, which does
        // `DispatchQueue.main.sync` when off-main. So a background paste can hold the session
        // *and* be waiting on the main thread; a blocking acquire here would let the two wait
        // on each other. The short timed wait breaks that inversion. On timeout we skip the
        // clipboard fallback entirely (degrading to "no selection") rather than sampling
        // `changeCount` or posting Cmd+C without the guard, which would re-open the
        // cross-session race this coordination prevents. We always release before returning
        // (the deferred `endExclusive`).
        let acquiredSession = PasteboardSession.tryBeginExclusive(timeoutMicros: Self.pasteboardSessionWaitMicros)
        guard acquiredSession else {
            self.diag("Clipboard fallback: skipped because pasteboard session is busy")
            return nil
        }
        defer {
            PasteboardSession.endExclusive()
        }

        let pasteboard = NSPasteboard.general

        // The initial restore target and the baseline generation must describe the same clipboard.
        // Capturing the snapshot and then reading `changeCount` separately lets a write land between
        // them, so the loop would start out holding one clipboard as its target while treating a
        // different, newer one as already handled. Retry briefly; if the pasteboard will not hold
        // still, skip the fallback rather than begin from a knowingly inconsistent pair.
        guard let preOperation = self.capturePreOperationState(of: pasteboard) else {
            self.diag("Clipboard fallback: skipped because the pasteboard would not hold still long enough to snapshot")
            return nil
        }
        let snapshot = preOperation.snapshot
        let changeCountBeforeCopy = preOperation.generation

        self.diag("Trying clipboard fallback (synthetic Cmd+C)")
        guard self.postSyntheticCopy() else {
            self.diag("Clipboard fallback: failed to post Cmd+C events")
            return nil
        }

        // Cmd+C is delivered asynchronously; wait for the target app to write the selection
        // to the pasteboard. The change-count increments on any write, even if the copied
        // text equals the prior contents, so this reliably detects a successful copy.
        let didChange = self.waitForPasteboardChange(
            pasteboard,
            since: changeCountBeforeCopy,
            timeoutMicros: Self.clipboardCopyTimeoutMicros
        )

        // Read the copied selection only if the pasteboard actually changed. One observation
        // serves both purposes: the text handed back as the selection, and the payload the settle
        // window recognises a delayed copy by. Reading those separately would let them disagree.
        let copyObservation = didChange ? self.readSettledObservation(from: pasteboard) : nil
        let copiedText = copyObservation?.string

        // Restore only in response to a real pasteboard write. If Cmd+C never changed the
        // pasteboard (usually no selection), clearing and rewriting the snapshot would degrade
        // complex clipboard contents that `data(forType:)` could not faithfully capture. The
        // helper still watches briefly for a late copy write and restores if one appears.
        self.restoreClipboardDefensively(
            snapshot,
            to: pasteboard,
            changeCountBeforeCopy: changeCountBeforeCopy,
            didObserveCopyWrite: didChange,
            syntheticCopyText: copiedText
        )

        guard didChange else {
            self.diag("Clipboard fallback: pasteboard unchanged within timeout (no selection?)")
            return nil
        }
        guard let copiedText, !copiedText.isEmpty else {
            self.diag("Clipboard fallback: pasteboard changed but yielded no string")
            return nil
        }

        self.diag("Clipboard fallback succeeded (chars=\(copiedText.count))")
        return copiedText
    }

    /// Posts a synthetic Cmd+C to the currently focused app via the HID event tap.
    /// Returns false only if the CGEvents could not be created.
    ///
    /// The key code for "c" is resolved against the active keyboard layout (via the same
    /// mechanism `TypingService` uses for Cmd+V), so the copy lands on the correct physical
    /// key on non-QWERTY layouts (Dvorak/AZERTY/...). Falls back to the ANSI "c" key code
    /// only when the layout data is unavailable.
    private func postSyntheticCopy() -> Bool {
        let cKeyCode = LayoutAwareKeyCode.virtualKeyCode(
            for: "c",
            qwertyFallback: CGKeyCode(kVK_ANSI_C),
            carbonModifierState: LayoutAwareKeyCode.commandModifierState
        )
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: cKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: cKeyCode, keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(10_000)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Reads one coherent observation of the copy generation, allowing briefly for a payload that
    /// is still in flight.
    ///
    /// A writer bumps `changeCount` on `clearContents()` and only then sets its payload, so a read
    /// taken the instant a change is observed can land in that gap and see nothing. Re-observing
    /// for a short bounded interval keeps a transient nil from being mistaken for a genuinely
    /// non-text selection, which matters because that distinction decides whether the settle window
    /// has a payload to recognise the delayed copy by. Returns as soon as a payload is readable, so
    /// the common case adds no latency and the bound is only paid on a real non-text selection.
    ///
    /// This MITIGATES the clear-before-set race; it does not close it. A writer that takes longer
    /// than `copyPayloadSettleMicros` to publish still finishes outside the bound, and the settle
    /// window then runs with no payload to compare against (issue #259).
    ///
    /// It also widens the window for the first-observed-write attribution ambiguity rather than
    /// narrowing it. This helper deliberately follows the pasteboard forward (it passes no
    /// `expectedGeneration`), so an unrelated write can be attributed to the synthetic copy and then
    /// become BOTH the text handed back as the selection and the payload the settle window
    /// recognises the delayed copy by.
    ///
    /// That window is wider than "the 300 ms copy wait": it opens the moment the pre-operation
    /// generation is sampled — before the diagnostics, the key-event construction, and the 10 ms
    /// gap between key-down and key-up — and closes only when this helper's terminal capture
    /// returns. Writer provenance is unavailable, so it is irreducible.
    ///
    /// `copyPayloadSettleMicros` is likewise a nominal polling horizon plus one terminal capture,
    /// not a strict read bound.
    /// - Parameter capture: testing seam. Defaults to a live coherent capture; a test overrides it
    ///   to prove that an unstable terminal capture yields nothing rather than an earlier value.
    func readSettledObservation(
        from pasteboard: NSPasteboard,
        capture: (() -> PasteboardObservation?)? = nil
    ) -> PasteboardObservation? {
        let observe = capture ?? { PasteboardObservation.capture(from: pasteboard) }

        let deadline = Self.deadline(afterMicros: Self.copyPayloadSettleMicros)
        while DispatchTime.now() < deadline {
            if let observation = observe(), observation.string != nil {
                return observation
            }
            usleep(5_000)
        }

        // The terminal capture is the answer, including when it is unstable. Falling back to an
        // earlier observation here would resurrect a value we have affirmative evidence is stale:
        // its text would become both the recorded synthetic payload and the selection handed back,
        // misattributing an older clipboard to the copy that just happened.
        return observe()
    }

    /// A monotonic deadline `micros` from now, used as a *scheduling horizon* for polling.
    ///
    /// It is better than summing requested sleep intervals, which bounds nothing at all: `usleep`
    /// may oversleep and the work between sleeps goes uncounted. It is still not a return bound —
    /// callers check it before sleeping, and a pasteboard read already in flight can finish well
    /// after it.
    private static func deadline(afterMicros micros: useconds_t) -> DispatchTime {
        DispatchTime.now() + .microseconds(Int(micros))
    }

    /// Captures the pre-operation clipboard and the generation it belongs to as one coherent pair,
    /// retrying briefly if the pasteboard moves mid-capture. `nil` means it never held still.
    private func capturePreOperationState(
        of pasteboard: NSPasteboard
    ) -> (snapshot: PasteboardSnapshot, generation: Int)? {
        for attempt in 0 ..< Self.preOperationCaptureAttempts {
            if let captured = PasteboardSnapshot.captureStable(from: pasteboard) {
                return captured
            }
            if attempt < Self.preOperationCaptureAttempts - 1 {
                usleep(2_000)
            }
        }
        return nil
    }

    /// How many times to retry a pre-operation capture that a concurrent write interrupted. Small:
    /// this runs on the main thread, and repeated failure means the clipboard is churning hard
    /// enough that skipping the fallback is the safer answer.
    private static let preOperationCaptureAttempts = 3

    /// Upper bound on how long to wait for an observed copy's payload to become readable after its
    /// `changeCount` bump. Small next to `clipboardCopyTimeoutMicros` because the gap between
    /// `clearContents()` and the payload write is a single writer's own critical section.
    private static let copyPayloadSettleMicros: useconds_t = 30_000

    /// Polls `pasteboard.changeCount` until it differs from `previousChangeCount` or the
    /// timeout elapses. Returns whether a change was observed.
    private func waitForPasteboardChange(
        _ pasteboard: NSPasteboard,
        since previousChangeCount: Int,
        timeoutMicros: useconds_t
    ) -> Bool {
        let pollMicros: useconds_t = 10_000
        var waited: useconds_t = 0
        while waited < timeoutMicros {
            if pasteboard.changeCount != previousChangeCount {
                return true
            }
            usleep(pollMicros)
            waited += pollMicros
        }
        return pasteboard.changeCount != previousChangeCount
    }

    /// Upper bound on how long to wait for a synthetic Cmd+C to land on the pasteboard.
    /// Kept tight because this runs on the main thread; the copy normally completes in tens
    /// of milliseconds, and exceeding this just means "treat as no selection."
    private static let clipboardCopyTimeoutMicros: useconds_t = 300_000

    /// Upper bound on how long to wait for an in-flight `TypingService` pasteboard session
    /// before reading the selection. Kept comparable to `clipboardCopyTimeoutMicros`: long
    /// enough to absorb normal handoff jitter, short enough that a paste verification timeout
    /// in AX-opaque apps cannot freeze the main thread for seconds. If this expires, the
    /// clipboard fallback is skipped rather than run without the session guard.
    private static let pasteboardSessionWaitMicros: useconds_t = 250_000

    /// Restores `snapshot` onto `pasteboard` only after observing a pasteboard write, then
    /// briefly watches for a *late* pasteboard write and re-restores if one lands.
    ///
    /// The hazard: our synthetic Cmd+C is delivered asynchronously. If the target app is
    /// slow/busy it may process the copy *after* `clipboardCopyTimeoutMicros` has elapsed and
    /// we've already given up — its delayed write would then clobber the user's clipboard,
    /// leaving the copied selection (or stale data) where the user's content should be.
    ///
    /// Defense: if the initial copy write landed, restore immediately; otherwise leave the
    /// pasteboard untouched. Then poll for a short, bounded settle window, handing each observed
    /// generation to `LateWriteArbiter`, which decides whether it is our delayed copy (restore it,
    /// capped at `maxLateCopyRestores` within `lateCopySettleMicros`) or somebody else's clipboard
    /// (adopt it as the new restore target). The loop is doubly bounded (time and retry count) so
    /// it cannot hang. Crucially, a timed-out Cmd+C with no late write never clears and rewrites
    /// the pasteboard, preserving complex clipboard contents that a snapshot may only partially
    /// capture.
    ///
    /// The restore target MOVES. `snapshot` is only the starting target: once a late write has been
    /// positively distinguished from the recorded synthetic payload it is the user's current
    /// clipboard, and a later synthetic write is reverted to *that* rather than to the older
    /// pre-operation state. See `LateWriteArbiter` for the rule and for the residuals it does not
    /// solve.
    ///
    /// Internal rather than private so the settle loop's wiring can be driven from tests.
    /// `testDefensiveRestore_finalEdgeReconcilesAWriteTheLoopNeverSaw` pins the final-edge
    /// reconciliation by giving the loop no horizon to run in, and
    /// `testDefensiveRestore_initialBaselineComesFromTheRestoreNotALiveReread` pins the initial
    /// baseline. That the loop and the final edge call one routine rather than two is established by
    /// reading the code, not by a test.
    ///
    /// Runs synchronously on the caller's thread (the main thread for Write/Rewrite mode),
    /// consistent with the copy-wait above, and only on this last-resort fallback path.
    ///
    /// `lateCopySettleMicros` is a nominal horizon for SCHEDULING polls, not a bound on how long
    /// this takes to return. `data(forType:)`, string conversion, and lazily-supplied pasteboard
    /// items have no wall-clock bound, so a capture begun near the horizon can finish well past it,
    /// and one terminal reconciliation always runs afterwards.
    /// - Parameters:
    ///   - settleWindowMicros: testing seam. The polling horizon; a test passes `0` so the loop
    ///     cannot run and the final-edge reconciliation is the only thing that can act, which is the
    ///     only way to prove the final edge deterministically rather than by racing a writer.
    ///   - performRestore: testing seam. Defaults to the real restore. A test substitutes an
    ///     operation that restores and then lands an external write immediately afterwards, proving
    ///     the baseline comes from the restore's own generation rather than a later live re-read.
    func restoreClipboardDefensively(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        changeCountBeforeCopy: Int,
        didObserveCopyWrite: Bool,
        syntheticCopyText: String?,
        settleWindowMicros: useconds_t? = nil,
        performRestore: ((PasteboardSnapshot, NSPasteboard) -> PasteboardSnapshot.RestoreResult)? = nil
    ) {
        let restoreOperation = performRestore ?? { snapshot, pasteboard in
            snapshot.restore(to: pasteboard)
        }
        // The baseline is the generation our own restore created, taken from the restore itself.
        // Re-reading `changeCount` here instead would sample a count an external writer may already
        // have advanced, and adopting that records "already handled" for a generation whose
        // contents were never observed — the write would then be silently skipped and overwritten
        // by a later synthetic restore.
        let baselineChangeCount: Int
        if didObserveCopyWrite {
            let restored = restoreOperation(snapshot, pasteboard)
            baselineChangeCount = restored.generation
            if !restored.didRestoreContents {
                self.diag("Clipboard fallback: the pasteboard rejected the initial restore write; the clipboard is now empty or incomplete rather than restored (best effort, not retried)")
            }
        } else {
            baselineChangeCount = changeCountBeforeCopy
        }

        var arbiter = LateWriteArbiter(
            restoreTarget: snapshot,
            baselineChangeCount: baselineChangeCount,
            restoresRemaining: Self.maxLateCopyRestores,
            syntheticCopyText: syntheticCopyText,
            didObserveCopyWrite: didObserveCopyWrite,
            performRestore: performRestore
        )

        var loggedRetarget = false
        var loggedUnsettled = false

        // Logs one step's outcome and reports whether to stop watching. Declared once so the
        // settle loop and the final-edge reconciliation share it rather than diverging.
        func report(_ outcome: LateWriteArbiter.Outcome) -> Bool {
            switch outcome {
            case .unchanged, .discarded:
                return false
            case .unsettled:
                if !loggedUnsettled {
                    loggedUnsettled = true
                    self.diag("Clipboard fallback: late write carries no readable text (either a non-text clipboard value or a writer between clearContents() and its payload); re-reading the same generation")
                }
                return false
            case .retargeted:
                if !loggedRetarget {
                    loggedRetarget = true
                    self.diag("Clipboard fallback: late write does not currently match the recorded synthetic payload; adopting it as the restore target and continuing to observe")
                }
                return false
            case .restored:
                self.diag("Clipboard fallback: re-restored the user clipboard after a late write matching the recorded synthetic payload")
                return false
            case .restoreFailed:
                self.diag("Clipboard fallback: the pasteboard rejected a restore write; the clipboard is now empty or incomplete rather than restored (best effort, not retried)")
                return false
            case .budgetExhausted:
                // Deliberately not "leaving the user clipboard restored": at exhaustion the write
                // that hit the budget was NOT restored over, so what is live is that write, not the
                // restore target.
                self.diag("Clipboard fallback: restore budget of \(Self.maxLateCopyRestores) exhausted; leaving the current pasteboard state unchanged")
                return true
            }
        }

        // A monotonic deadline, not a sum of requested sleeps: `usleep` may oversleep and the
        // observation work between sleeps is not counted at all, so an accumulator would not bound
        // anything.
        //
        // What this does NOT establish is a wall-clock bound, and it does not even establish that
        // no poll BEGINS after the deadline: the clock is checked before the sleep, so an iteration
        // can pass the check at 195ms, sleep to 205ms, and start an observation late — after which
        // the unconditional final edge starts one more. A full capture already under way can also
        // run long on a large or lazily-supplied clipboard. The accurate description is a nominal
        // polling horizon followed by one terminal reconciliation.
        let deadline = Self.deadline(afterMicros: settleWindowMicros ?? Self.lateCopySettleMicros)
        while DispatchTime.now() < deadline {
            usleep(10_000)

            if report(arbiter.observeAndHandle(pasteboard)) {
                return
            }
        }

        // Reconcile a write that landed in the final poll interval (just past the loop edge),
        // through the same observe-and-handle routine so there is only ever one classifier path.
        _ = report(arbiter.observeAndHandle(pasteboard))
    }

    // MARK: - Late-write arbitration

    /// The state machine behind the defensive restore's settle window.
    ///
    /// Owns the *moving* restore target. The user's pre-operation clipboard is only the starting
    /// target: once a late write has been positively distinguished from the recorded synthetic
    /// payload, that write is the user's current clipboard and becomes the state a later synthetic
    /// write is reverted to. Without that, a settled external write `B` followed by a write
    /// matching the synthetic payload would restore the older pre-operation state over `B`.
    ///
    /// Every decision comes from ONE immutable `PasteboardObservation`. `handle(_:on:)` takes the
    /// observation as a parameter and uses `pasteboard` only to *write* a restore — never to read a
    /// payload and never to capture a target. A branch that re-read the live pasteboard could
    /// classify one generation and save another, and making that unrepresentable is the whole
    /// point of the type.
    ///
    /// Unresolved policies, stated rather than buried. None is solvable with the available signals,
    /// because the pasteboard carries no writer provenance:
    /// - **Timed-out copy.** With no recorded payload, every readable write in the window is taken
    ///   for the delayed copy, so a genuine external write during that window is restored over.
    /// - **Nil or non-text generation.** A settled external image or file list is indistinguishable
    ///   from a writer caught between `clearContents()` and its payload, so neither is adopted as a
    ///   restore target; a matching synthetic write afterwards still reverts to the older target.
    /// - **Same-string external write.** The comparison is exact string equality, not authorship.
    ///   An external write carrying the same text as the synthetic copy is classified as ours and
    ///   restored over.
    /// - **Compare and restore are not atomic.** A write can land after an observation is
    ///   classified and before the restore is applied, and the restore overwrites it.
    /// - **A writer can straddle the restore.** Baselining on `clearContents()`'s own generation
    ///   closes the narrow race where a post-restore re-read swallowed a later generation. It does
    ///   not make the restore atomic, and it does not mean every subsequent write gets a later
    ///   generation: an external writer that called `clearContents()` *before* our restore can
    ///   publish its payload *after* it, landing that payload at the very generation our restore
    ///   created. Every poll then compares equal to the baseline, the write is never adopted as the
    ///   target, and a later synthetic write restores the older target over it.
    /// - **Restore budget.** After `maxLateCopyRestores` restores the loop stops. The write that hit
    ///   the exhausted budget is deliberately NOT restored over, so what is left live is that write
    ///   — not the restore target, and not the state of the last successful restore.
    /// - **Restore writes can fail.** `clearContents()` always lands but the write back may be
    ///   rejected, leaving the clipboard empty or incomplete. That is reported as `restoreFailed`
    ///   and never as a restore.
    struct LateWriteArbiter {
        /// How a *readable* generation is attributed. No case here appeals to writer provenance: a
        /// different readable payload is treated as external because it does not match the recorded
        /// synthetic payload, which is not the same thing as knowing who wrote it.
        ///
        /// There is no `unsettled` case. An unreadable generation is not a classification outcome,
        /// it is a property of the observation — `PasteboardObservation.unreadable` — so it cannot
        /// be confused with a classified value or accidentally carry a restore target.
        enum Classification {
            /// A readable payload that is not the recorded synthetic copy.
            case external
            /// A readable payload attributed to our own synthetic copy.
            case synthetic
        }

        /// What one observe-and-handle step did. Returned rather than logged so a step is a pure
        /// value-level decision a test can assert on, which is what lets each test prove that the
        /// branch it targets actually executed.
        enum Outcome: Equatable {
            /// The generation still matches the baseline; nothing was observed.
            case unchanged
            /// The generation moved while the observation was being captured, so it was discarded.
            case discarded
            /// Observed, but with no readable payload. The baseline is deliberately NOT advanced.
            case unsettled
            /// A distinguishable external write became the new restore target.
            case retargeted
            /// A write matching the recorded synthetic payload was reverted to the restore target.
            case restored
            /// A restore was attempted and the pasteboard rejected the write. The clear still
            /// landed, so the clipboard is empty or incomplete — distinct from `restored` precisely
            /// so a failure can never be reported as a successful restore.
            case restoreFailed
            /// A matching write was seen but the restore budget is spent; stop watching.
            case budgetExhausted
        }

        private var restoreTarget: PasteboardSnapshot
        private var baselineChangeCount: Int
        private var restoresRemaining: Int
        private let syntheticCopyText: String?
        private let didObserveCopyWrite: Bool
        private let performRestore: (PasteboardSnapshot, NSPasteboard) -> PasteboardSnapshot.RestoreResult

        /// - Parameter performRestore: testing seam. Defaults to the real restore. A test
        ///   substitutes an operation that restores and then lands an external write immediately
        ///   afterwards, proving the baseline is taken from the restore's own generation rather than
        ///   a later live re-read that could swallow that write.
        init(
            restoreTarget: PasteboardSnapshot,
            baselineChangeCount: Int,
            restoresRemaining: Int,
            syntheticCopyText: String?,
            didObserveCopyWrite: Bool,
            performRestore: ((PasteboardSnapshot, NSPasteboard) -> PasteboardSnapshot.RestoreResult)? = nil
        ) {
            self.restoreTarget = restoreTarget
            self.baselineChangeCount = baselineChangeCount
            self.restoresRemaining = restoresRemaining
            self.syntheticCopyText = syntheticCopyText
            self.didObserveCopyWrite = didObserveCopyWrite
            self.performRestore = performRestore ?? { snapshot, pasteboard in
                snapshot.restore(to: pasteboard)
            }
        }

        /// Observes `pasteboard` once and handles what it found. The single entry point: the settle
        /// loop and the final-edge reconciliation both call this, so there is exactly one
        /// classification path.
        mutating func observeAndHandle(_ pasteboard: NSPasteboard) -> Outcome {
            let observedCount = pasteboard.changeCount
            guard observedCount != self.baselineChangeCount else { return .unchanged }

            // Bind the capture to the generation that woke this poll. Letting it settle on a later
            // generation instead would mean a poll triggered by one write commits a decision about
            // a different one; discarding leaves that later generation to the next poll, which is
            // what the spec's read-compare-read loop does.
            guard let observation = PasteboardObservation.capture(
                from: pasteboard,
                expectedGeneration: observedCount
            ) else {
                return .discarded
            }
            return self.handle(observation, on: pasteboard)
        }

        /// Handles one immutable observation. `pasteboard` is a write target only; every decision
        /// below is taken from `observation`.
        mutating func handle(
            _ observation: PasteboardObservation,
            on pasteboard: NSPasteboard
        ) -> Outcome {
            guard case let .readable(changeCount, snapshot) = observation,
                  let string = snapshot.plainText
            else {
                // Deliberately leave the baseline alone so this same generation is observed again.
                // A writer bumps `changeCount` on `clearContents()` and its later `setString` need
                // not bump it a second time, so the payload can become readable with no new
                // generation to notice it by. Skipping the re-read while `changeCount` is unchanged
                // would miss exactly the publish this loop exists to catch, which is why this must
                // not be turned into a cache keyed on the generation.
                return .unsettled
            }

            switch self.classify(string) {
            case .external:
                self.restoreTarget = snapshot
                self.baselineChangeCount = changeCount
                return .retargeted

            case .synthetic:
                guard self.restoresRemaining > 0 else { return .budgetExhausted }
                self.restoresRemaining -= 1
                // Baseline comes from the restore itself, not a re-read, for the same reason the
                // initial baseline does: a re-read can absorb an external generation we never
                // observed. It is adopted even when the write failed, because the clear still
                // landed and a stale baseline would make the loop spin on that generation.
                let restored = self.performRestore(self.restoreTarget, pasteboard)
                self.baselineChangeCount = restored.generation
                return restored.didRestoreContents ? .restored : .restoreFailed
            }
        }

        private func classify(_ payload: String) -> Classification {
            guard let syntheticCopyText = self.syntheticCopyText else {
                // No payload was recorded, and why it is missing decides the policy. If the copy
                // never landed, nothing was restored and a write inside this short window is
                // treated as the delayed copy the defense exists for. If the copy did land but
                // carried no readable string (a non-text selection), the target is already back in
                // place and a later readable write is treated as external. Neither branch knows
                // authorship — a synthetic payload finishing after the payload-settle helper is
                // treated as external too. These are policies, not determinations.
                return self.didObserveCopyWrite ? .external : .synthetic
            }
            return payload == syntheticCopyText ? .synthetic : .external
        }
    }

    /// Total time the defensive restore watches for a late synthetic-copy write before giving
    /// up. Bounds the extra main-thread latency added on top of `clipboardCopyTimeoutMicros`.
    private static let lateCopySettleMicros: useconds_t = 200_000

    /// Maximum number of re-restores during the settle window. A real app emits one delayed
    /// write per Cmd+C, so 1 suffices in practice; the small headroom covers pathological
    /// repeated writers without ever looping unbounded.
    private static let maxLateCopyRestores = 3

    private func getFocusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result == .success, let focusedElement {
            guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(focusedElement, to: AXUIElement.self)
        }

        return nil
    }

    private func getFocusedElement(from appElement: AXUIElement) -> AXUIElement? {
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result == .success, let focusedElement {
            guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(focusedElement, to: AXUIElement.self)
        }

        return nil
    }

    private func getSelectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)

        // An empty string is NOT a selection. Some AX-opaque editors answer this attribute with ""
        // rather than an error, and treating that as success terminates selection capture before the
        // clipboard fallback runs, leaving exactly the apps this fallback exists for still broken.
        // Fall through to the range fallback, and then to the clipboard, instead.
        if result == .success, let text = value as? String, !text.isEmpty {
            self.diag("kAXSelectedTextAttribute succeeded (chars=\(text.count))")
            return text
        }

        self.diag("kAXSelectedTextAttribute unavailable (\(self.describe(result))) - trying selected range fallback")

        // Fallback: reconstruct selected text from selected range + full value for apps
        // that don't expose kAXSelectedTextAttribute directly.
        var selectedRangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef)
        guard rangeResult == .success, let axRange = selectedRangeRef else {
            self.diag("kAXSelectedTextRangeAttribute unavailable (\(self.describe(rangeResult)))")
            return nil
        }

        guard CFGetTypeID(axRange) == AXValueGetTypeID() else {
            self.diag("kAXSelectedTextRangeAttribute returned non-AXValue")
            return nil
        }

        let axValue = unsafeBitCast(axRange, to: AXValue.self)

        var range = CFRange()
        let gotRange = AXValueGetValue(axValue, .cfRange, &range)
        guard gotRange else {
            self.diag("AXValueGetValue(.cfRange) failed")
            return nil
        }

        guard range.location != kCFNotFound, range.length > 0 else {
            self.diag("Selected range empty (location=\(range.location), length=\(range.length))")
            return nil
        }

        var fullValueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fullValueRef)
        guard valueResult == .success, let fullText = fullValueRef as? String else {
            self.diag("kAXValueAttribute unavailable for range extraction (\(self.describe(valueResult)))")
            return nil
        }

        let nsText = fullText as NSString
        guard range.location >= 0,
              range.length > 0,
              range.location + range.length <= nsText.length
        else {
            self.diag("Selected range out of bounds (textLen=\(nsText.length), location=\(range.location), length=\(range.length))")
            return nil
        }

        let extracted = nsText.substring(with: NSRange(location: range.location, length: range.length))
        self.diag("Selected range extraction succeeded (chars=\(extracted.count))")
        return extracted
    }

    private func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(error.rawValue))"
        }
    }

    private func diag(_ message: String) {
        let line = "[TextSelectionService] \(message)"
        FileLogger.shared.append(line: line)
        DebugLogger.shared.debug(line, source: "TextSelectionService")
    }
}
