import AppKit
import Foundation

/// Decides what a copy *gesture* (double-click / ⌘C) in the Transcription
/// History list places on the pasteboard. Keeps the gesture wiring in
/// `TranscriptionHistoryView` thin and gives the behavior a unit-testable seam.
enum HistoryCopy {
    /// Text a copy gesture should place on the pasteboard for `entry`, or `nil`
    /// when the entry has nothing copyable. Delegates to
    /// `TranscriptionHistoryEntry.clipboardText` — the same processed-then-raw
    /// selection PR #450 centralized for the menu-bar copy.
    static func text(for entry: TranscriptionHistoryEntry) -> String? {
        entry.clipboardText
    }

    /// Item providers for the standard Copy command (⌘C / Edit ▸ Copy), used by
    /// `.onCopyCommand`. Empty when there is no selection or no text, so the Copy
    /// command becomes a no-op instead of clearing the pasteboard.
    static func itemProviders(for entry: TranscriptionHistoryEntry?) -> [NSItemProvider] {
        guard let entry, let text = text(for: entry) else { return [] }
        return [NSItemProvider(object: text as NSString)]
    }
}
