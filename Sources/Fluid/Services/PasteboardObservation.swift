import AppKit
import Foundation

/// One coherent, immutable observation of a single `NSPasteboard` generation.
///
/// The Write Mode clipboard fallback has to do two things with a pasteboard write it sees during
/// its settle window: classify it (is this our own synthetic copy, or somebody else's clipboard?)
/// and, when it belongs to somebody else, keep it as the state to restore to later. Taking those
/// from two separate reads of the live pasteboard lets a write land in between, so the branch can
/// classify one generation and save another. Bundling the classification payload and the full
/// snapshot into one immutable value removes that gap (issue #259).
///
/// The two cases are not a convenience. Only a generation with a readable payload can ever be
/// adopted as a restore target, so only `readable` carries a snapshot — an unreadable generation
/// cannot be adopted by accident, because there is nothing there to adopt.
enum PasteboardObservation {
    /// A generation carrying no readable text. Ambiguous by nature: either a genuinely non-text
    /// clipboard value, or a writer caught between `clearContents()` and its payload write. The
    /// pasteboard carries no writer provenance, so the two cannot be told apart.
    case unreadable(changeCount: Int)

    /// A generation with a readable payload.
    case readable(changeCount: Int, snapshot: PasteboardSnapshot)

    /// The generation this observation describes, verified unchanged across the whole capture.
    var changeCount: Int {
        switch self {
        case let .unreadable(changeCount): return changeCount
        case let .readable(changeCount, _): return changeCount
        }
    }

    /// The classification payload — a pure projection of `snapshot`, never a stored value and never
    /// an independent read.
    ///
    /// Computing it rather than storing it is the point. A stored copy could be assigned from
    /// somewhere else by a later edit and nothing would catch it; a projection of the snapshot's own
    /// bytes cannot disagree with the snapshot, because there is only one value involved. That is
    /// the property the whole redesign turns on: the text a write is classified by and the state
    /// that would be restored are the same observation.
    var string: String? {
        switch self {
        case .unreadable: return nil
        case let .readable(_, snapshot): return snapshot.plainText
        }
    }

    /// Captures one observation of `pasteboard`, or `nil` if the pasteboard advanced a generation
    /// while the capture was in progress.
    ///
    /// Returning `nil` rather than a possibly-torn value is deliberate: a caller cannot forget to
    /// check for a moved generation, because a discarded observation is the only thing there is to
    /// work with.
    /// `expectedGeneration`, when supplied, binds the capture to the generation that triggered the
    /// poll: an observation of any *other* generation is discarded rather than committed, so a poll
    /// woken by one write can never commit a decision about a different, later one. Callers that
    /// deliberately want whatever generation is current — the initial payload settle, which is
    /// allowed to follow the pasteboard forward — omit it.
    static func capture(
        from pasteboard: NSPasteboard,
        expectedGeneration: Int? = nil
    ) -> PasteboardObservation? {
        self.capture(from: pasteboard, expectedGeneration: expectedGeneration) {
            pasteboard.changeCount
        }
    }

    /// Testing seam: `currentGeneration` is read immediately before and immediately after the
    /// capture, so a test can simulate a write landing mid-capture and prove the observation is
    /// discarded deterministically. Production callers use `capture(from:expectedGeneration:)`,
    /// which reads the live `changeCount`.
    static func capture(
        from pasteboard: NSPasteboard,
        expectedGeneration: Int? = nil,
        currentGeneration: () -> Int
    ) -> PasteboardObservation? {
        let generationBefore = currentGeneration()
        if let expectedGeneration, generationBefore != expectedGeneration { return nil }

        // Cheap gate before the expensive copy. A generation with no readable text can never be
        // adopted as a restore target, so copying every item's data for it would be pure waste —
        // and it is the *repeating* case: an unreadable generation deliberately does not advance
        // the settle loop's baseline, so it is re-observed on every poll for the rest of the
        // window. Snapshotting a large image twenty times over would blow the loop's main-thread
        // latency budget. This read is advisory only: it decides whether to copy, never what the
        // payload is. The authoritative payload below comes from the snapshot itself.
        guard pasteboard.string(forType: .string)?.isEmpty == false else {
            guard currentGeneration() == generationBefore else { return nil }
            return .unreadable(changeCount: generationBefore)
        }

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        guard currentGeneration() == generationBefore else { return nil }

        // The probe said there was text; the snapshot is what decides whether there actually is,
        // and the probe's value is discarded either way.
        guard snapshot.plainText != nil else {
            return .unreadable(changeCount: generationBefore)
        }

        return .readable(changeCount: generationBefore, snapshot: snapshot)
    }
}
