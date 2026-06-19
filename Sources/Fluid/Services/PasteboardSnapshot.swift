import AppKit
import Foundation

/// A full-fidelity snapshot of an `NSPasteboard`'s contents (every item, every type).
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

    /// Restores the captured contents onto `pasteboard`, replacing whatever is there.
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !self.items.isEmpty else { return }

        let restoredItems = self.items.map { snap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snap.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        _ = pasteboard.writeObjects(restoredItems)
    }
}
