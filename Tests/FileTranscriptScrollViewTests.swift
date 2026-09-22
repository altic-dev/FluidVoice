import AppKit

@main
struct FileTranscriptScrollViewTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let view = FileTranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 450, height: 600))
        guard let textView = view.documentView as? NSTextView else { preconditionFailure("Missing transcript view") }
        let id = UUID()
        let text = String(repeating: "A long transcript with café, 日本語, and 👨‍👩‍👧‍👦.\n", count: 4000)
        view.display(entryID: id, text: text, font: .systemFont(ofSize: 14), color: .labelColor, inset: 16)
        precondition(textView.string == text, "Full transcript must be retained")
        precondition(!textView.isEditable && textView.isSelectable, "Transcript must remain read-only and selectable")
        precondition(textView.layoutManager?.allowsNonContiguousLayout == true)
        textView.setSelectedRange(NSRange(location: 8, length: 30))
        textView.setFrameSize(NSSize(width: 450, height: 50000))
        view.contentView.scroll(to: NSPoint(x: 0, y: 400))
        let readingPosition = view.contentView.bounds.origin
        precondition(readingPosition.y > 0, "Fixture must start scrolled away from the top")
        guard let storage = textView.textStorage else { preconditionFailure("Missing text storage") }
        var edits = 0
        let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { _ in
            edits += 1
        }
        for _ in 0..<100 {
            view.display(entryID: id, text: text, font: .systemFont(ofSize: 14), color: .labelColor, inset: 16)
        }
        precondition(edits == 0, "Unrelated updates must not replace or restyle text storage")
        precondition(view.contentView.bounds.origin == readingPosition, "Unrelated updates must not move the reading position")
        precondition(textView.selectedRange() == NSRange(location: 8, length: 30), "Unrelated updates must preserve selection")
        view.display(entryID: id, text: text, font: .systemFont(ofSize: 16), color: .systemBlue, inset: 20)
        precondition(textView.string == text && textView.selectedRange().length == 30, "Theme/font changes must preserve content and selection")
        view.display(entryID: id, text: "Updated", font: .systemFont(ofSize: 14), color: .labelColor, inset: 16)
        precondition(textView.string == "Updated", "Same-ID edits must not show stale text")
        for index in 0..<100 {
            view.display(entryID: UUID(), text: "Transcript \(index)", font: .systemFont(ofSize: 14), color: .labelColor, inset: 16)
        }
        precondition(textView.string == "Transcript 99" && textView.selectedRange().length == 0)
        view.display(entryID: UUID(), text: "", font: .systemFont(ofSize: 14), color: .labelColor, inset: 16)
        precondition(textView.string.isEmpty, "Empty input must clear previous content")
        NotificationCenter.default.removeObserver(observer)
        print("PASS: full Unicode content, read-only selection, zero storage edits across 100 unchanged updates, theme changes, same-ID edits, rapid switching, empty content")
    }
}
