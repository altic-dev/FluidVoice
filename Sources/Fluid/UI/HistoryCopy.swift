import Foundation

/// Decides what a copy *gesture* (double-click) in the Transcription History
/// list places on the pasteboard. Keeps the gesture wiring in
/// `TranscriptionHistoryView` thin and gives the behavior a unit-testable seam.
enum HistoryCopy {
    /// Text a copy gesture should place on the pasteboard for `entry`, or `nil`
    /// when the entry has nothing copyable. Delegates to
    /// `TranscriptionHistoryEntry.clipboardText` — the same processed-then-raw
    /// selection PR #450 centralized for the menu-bar copy.
    static func text(for entry: TranscriptionHistoryEntry) -> String? {
        entry.clipboardText
    }

    /// The index to select when the user presses ↑ (`moveUp == true`) or ↓ in
    /// the History list, clamped to the list bounds. Returns `nil` for an empty
    /// list. A `nil` current selection moves to the first row either way.
    static func nextIndex(current: Int?, count: Int, moveUp: Bool) -> Int? {
        guard count > 0 else { return nil }
        if moveUp {
            return max(0, (current ?? 0) - 1)
        }
        return min(count - 1, (current ?? -1) + 1)
    }
}
