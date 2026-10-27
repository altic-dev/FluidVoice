import AppKit

final class FileTranscriptScrollView: NSScrollView {
    private let transcriptView = NSTextView(frame: .zero)
    private var displayedID: UUID?
    private var displayedText: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.configure()
    }

    private func configure() {
        self.hasVerticalScroller = true
        self.autohidesScrollers = true
        self.drawsBackground = false
        self.borderType = .noBorder
        self.transcriptView.isEditable = false
        self.transcriptView.isSelectable = true
        self.transcriptView.isRichText = false
        self.transcriptView.allowsUndo = false
        self.transcriptView.drawsBackground = false
        self.transcriptView.isVerticallyResizable = true
        self.transcriptView.isHorizontallyResizable = false
        self.transcriptView.autoresizingMask = [.width]
        self.transcriptView.textContainer?.widthTracksTextView = true
        self.transcriptView.textContainer?.lineFragmentPadding = 0
        self.transcriptView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        self.transcriptView.layoutManager?.allowsNonContiguousLayout = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        self.transcriptView.defaultParagraphStyle = paragraph
        self.transcriptView.setAccessibilityLabel("Transcript")
        self.documentView = self.transcriptView
    }

    func display(entryID: UUID, text: String, font: NSFont, color: NSColor, inset: CGFloat) {
        if self.transcriptView.font != font { self.transcriptView.font = font }
        if self.transcriptView.textColor != color { self.transcriptView.textColor = color }
        let insets = NSSize(width: inset, height: inset)
        if self.transcriptView.textContainerInset != insets { self.transcriptView.textContainerInset = insets }
        guard self.displayedID != entryID || self.displayedText != text else { return }
        self.displayedID = entryID
        self.displayedText = text
        self.transcriptView.string = text
        self.transcriptView.setSelectedRange(NSRange(location: 0, length: 0))
        self.contentView.scroll(to: .zero)
        self.reflectScrolledClipView(self.contentView)
    }
}
