import AppKit
import Foundation

/// Best-effort snapshot of each pasteboard item and every representation whose `Data` was readable
/// during capture.
///
/// Used to save and restore the user's clipboard around synthetic copy/paste operations
/// so those operations don't clobber whatever the user had on the pasteboard. Shared by
/// `TypingService` (paste insertion) and `TextSelectionService` (Cmd+C selection fallback).
struct PasteboardSnapshot {
    private struct ItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private let items: [ItemSnapshot]

    /// Captures the current contents of `pasteboard`.
    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [ItemSnapshot] = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return ItemSnapshot(dataByType: dataByType)
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    /// Captures the contents together with the generation they belong to, or `nil` if the pasteboard
    /// advanced while the capture was in progress.
    ///
    /// Capturing a snapshot and then separately reading `changeCount` lets an external write land
    /// between the two, producing a target that holds one clipboard and a baseline that names a
    /// different one — the loop would then treat the newer write as already handled and could
    /// overwrite it. Unlike `PasteboardObservation`, this works for any contents, readable or not,
    /// because the pre-operation clipboard has to be preserved whether or not it is text.
    /// A capture in which no item produced a single representation. Ambiguous: either a genuinely
    /// empty clipboard, or a writer that has announced a generation and not yet published a payload.
    ///
    /// Deliberately measured by what was CAPTURED, not by item count: re-poll when no declared
    /// representation produced a `Data` value. `declareTypes(_:owner:)` — a common rich-text
    /// declare-then-publish path used by applications that expose multiple promised pasteboard
    /// representations — advances the generation and leaves ONE item whose every `data(forType:)` is
    /// nil until the payload lands. An item-count test calls that
    /// non-empty and adopts an empty restore target, which is the same defect the itemless case
    /// describes, one layer down. Images and file lists produce representations, so the non-text
    /// clipboards this helper exists to serve are unaffected.
    ///
    /// This counts representations, NOT their length. A zero-length `Data()` is still a captured
    /// representation, so the transient markers `TypingService` writes (`org.nspasteboard
    /// .TransientType` and friends, which carry no value by design) make a snapshot non-empty and
    /// come back intact through a restore.
    var hasNoCapturedRepresentations: Bool { self.items.allSatisfy { $0.dataByType.isEmpty } }

    static func captureStable(
        from pasteboard: NSPasteboard,
        emptySettleMicros: useconds_t = emptyContentsSettleMicros
    ) -> (snapshot: PasteboardSnapshot, generation: Int)? {
        // A capture that produced no representations is the dangerous ambiguity. `clearContents()`
        // advances the generation and empties the pasteboard, and the writer's
        // `setString`/`writeObjects` that follows does NOT advance it again, so a capture taken
        // inside that window is internally consistent, passes the generation guard, and holds
        // nothing. `declareTypes(_:owner:)` opens the same window with an item already present but
        // every representation still nil. Adopting either as the pre-operation restore target means
        // our restore later wipes what that writer published.
        //
        // Rejecting empty outright would be wrong: a genuinely empty clipboard has to be preserved
        // as empty. Only time separates the two, so re-poll for a bounded interval and accept a
        // representation-less result once the bound expires.
        //
        // Note the gate is on REPRESENTATIONS CAPTURED, not readability. A non-text clipboard
        // (image, file list) produces representations and is returned immediately, which is exactly
        // the case this helper exists to serve and which a readability gate would have broken.
        let deadline = DispatchTime.now() + .microseconds(Int(emptySettleMicros))
        while DispatchTime.now() < deadline {
            if let captured = self.captureStableOnce(from: pasteboard),
               !captured.snapshot.hasNoCapturedRepresentations
            {
                return captured
            }
            usleep(2_000)
        }

        // Terminal capture is authoritative, including when it is still empty or unstable. Never
        // resurrect an earlier one: the same discipline the payload-settle helper follows.
        return self.captureStableOnce(from: pasteboard)
    }

    /// One coherent snapshot/generation pair, or `nil` if the pasteboard moved mid-capture.
    private static func captureStableOnce(
        from pasteboard: NSPasteboard
    ) -> (snapshot: PasteboardSnapshot, generation: Int)? {
        let generationBefore = pasteboard.changeCount
        let snapshot = self.capture(from: pasteboard)
        guard pasteboard.changeCount == generationBefore else { return nil }
        return (snapshot, generationBefore)
    }

    /// How long to keep re-polling a representation-less capture before accepting it as genuinely empty.
    /// Matched to the payload-settle bound, since it covers the same clear-then-publish gap.
    static let emptyContentsSettleMicros: useconds_t = 30_000

    /// The plain-text projection of these captured representations, or `nil` if none of the items
    /// carries readable UTF-8 text.
    ///
    /// Deliberately derived from the snapshot's own already-copied `Data` rather than from a second
    /// read of the live pasteboard. That makes the text and the snapshot the *same* observation by
    /// construction: they cannot describe different pasteboard states, because there is only one
    /// state involved. A caller that classified a write from a live string read and then captured a
    /// snapshot separately would have made two observations, and a write landing between them would
    /// let the classification and the saved state disagree (issue #259).
    /// Every text-bearing item contributes, in pasteboard order, joined by newlines — matching
    /// `NSPasteboard.stringForType:`, which is documented to return the text of each item "as one
    /// combined result separated by newlines" for standard text types (`NSPasteboard.h`). Taking
    /// only the first item would both change the selection text this fallback returns and widen the
    /// classifier's collisions: two different multi-item clipboards that merely share a first item
    /// would compare equal.
    ///
    /// An item with a readable but empty string still contributes, because it affects newline
    /// placement. `nil` means no item carried a readable text representation at all.
    var plainText: String? {
        var contributions: [String] = []
        for item in self.items {
            guard let data = item.dataByType[.string],
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            contributions.append(text)
        }

        guard !contributions.isEmpty else { return nil }
        let combined = contributions.joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }

    /// What a restore actually did.
    struct RestoreResult {
        /// The pasteboard generation `clearContents()` created.
        ///
        /// Valid whether or not the contents were written back: the clear always lands, so a caller
        /// must baseline on this either way or its settle loop will keep re-observing a generation
        /// it believes it has not seen.
        ///
        /// It is `clearContents()`'s own result rather than a `changeCount` re-read afterwards,
        /// because a re-read samples a count an external writer may already have advanced — adopting
        /// that as a baseline records "already handled" for a generation whose contents were never
        /// observed, which is exactly how a settled external write gets skipped and then overwritten.
        ///
        /// That closes the post-restore baseline-resampling race specifically. It does NOT make the
        /// restore atomic, and it does not mean every later write lands on a later generation: a
        /// writer that cleared *before* this restore can publish afterwards at this very generation.
        /// See the straddling-writer residual on `TextSelectionService.LateWriteArbiter`.
        let generation: Int

        /// `false` when AppKit rejected the write. The clear has already happened by then, so the
        /// pasteboard is empty or incomplete — emphatically NOT restored. Success and generation are
        /// deliberately separate values so a caller cannot report one while meaning the other.
        let didRestoreContents: Bool
    }

    /// Restores the captured contents onto `pasteboard`, replacing whatever is there.
    @discardableResult
    func restore(to pasteboard: NSPasteboard) -> RestoreResult {
        let generation = pasteboard.clearContents()
        guard !self.items.isEmpty else {
            // An empty snapshot restores to an empty pasteboard, so the clear alone is the restore.
            return RestoreResult(generation: generation, didRestoreContents: true)
        }

        let restoredItems = self.items.map { snap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snap.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        return RestoreResult(
            generation: generation,
            didRestoreContents: pasteboard.writeObjects(restoredItems)
        )
    }
}
