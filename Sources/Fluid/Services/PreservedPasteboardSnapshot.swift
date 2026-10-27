import AppKit

/// Preserves every readable representation, not just the plain text used for pasting.
struct PreservedPasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        self.items = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return dataByType
        } ?? []
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard, ifUnchangedSince changeCount: Int) -> Bool {
        // Equal text is not ownership: a user may have copied that same text with
        // different formats since our write. Their newer clipboard always wins.
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        guard !self.items.isEmpty else { return true }
        let restoredItems = self.items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot {
                item.setData(data, forType: type)
            }
            return item
        }
        return pasteboard.writeObjects(restoredItems)
    }
}
