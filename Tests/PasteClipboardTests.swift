import AppKit

@main
enum PasteClipboardTests {
    static func main() {
        self.testClipboardPreservation()
        print("PASS: rich clipboard round-trip, empty clipboard, newer and identical-text user copies preserved")
    }

    static func testClipboardPreservation() {
        let board = NSPasteboard(name: NSPasteboard.Name("fluidvoice.paste-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        original.setData(Data([0, 1, 2, 255]), forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(Data([3, 4, 5]), forType: .png)
        board.clearContents()
        precondition(board.writeObjects([original, second]))
        let preserved = PreservedPasteboardSnapshot(board)
        board.clearContents()
        board.setString("dictated", forType: .string)
        let owned = board.changeCount
        precondition(preserved.restore(to: board, ifUnchangedSince: owned))
        precondition(PreservedPasteboardSnapshot(board).items == preserved.items, "All item representations must round-trip")

        board.clearContents()
        board.setString("dictated", forType: .string)
        let oldGeneration = board.changeCount
        board.clearContents()
        board.setString("dictated", forType: .string)
        let userCopy = board.changeCount
        precondition(!preserved.restore(to: board, ifUnchangedSince: oldGeneration), "Same text copied again belongs to the user")
        precondition(board.changeCount == userCopy && board.string(forType: .string) == "dictated")
        board.clearContents()
        board.setString("new user copy", forType: .string)
        precondition(!preserved.restore(to: board, ifUnchangedSince: oldGeneration))
        precondition(board.string(forType: .string) == "new user copy")

        board.clearContents()
        let empty = PreservedPasteboardSnapshot(board)
        board.setString("temporary", forType: .string)
        precondition(empty.restore(to: board, ifUnchangedSince: board.changeCount))
        precondition(board.string(forType: .string) == nil, "An originally empty clipboard must end empty")
    }
}
