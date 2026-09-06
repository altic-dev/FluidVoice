import AppKit
import SwiftUI

/// A fixed-size caption viewport. TextKit performs one unbounded layout, then the same layout
/// manager draws only the maximal suffix of complete wrapped lines whose ink fits the viewport.
struct MeetingRollingCaptionView: NSViewRepresentable {
    let text: String
    var foregroundColor: NSColor = .white

    func makeNSView(context: Context) -> MeetingRollingCaptionNSView {
        MeetingRollingCaptionNSView()
    }

    func updateNSView(_ nsView: MeetingRollingCaptionNSView, context: Context) {
        nsView.foregroundColor = self.foregroundColor
        nsView.text = self.text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeetingRollingCaptionNSView, context: Context) -> CGSize {
        MeetingRollingCaptionLayout.contentSize
    }
}

struct MeetingRollingCaptionLayout {
    static let contentSize = CGSize(width: MeetingOverlayPresentation.captionsContentWidth, height: MeetingOverlayPresentation.captionsContentHeight)
    static let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let lineSpacing: CGFloat = 4
    static let maximumInputCharacters = 4096

    let attributedText: NSAttributedString
    let textStorage: NSTextStorage
    let selectedGlyphRange: NSRange
    let translation: CGPoint
    let inkBounds: CGRect
    let layoutManager: NSLayoutManager

    static func inputSuffix(_ text: String) -> String {
        String(text.suffix(Self.maximumInputCharacters))
    }

    static func make(_ text: String, width: CGFloat = contentSize.width, height: CGFloat = contentSize.height, foregroundColor: NSColor = .white) -> MeetingRollingCaptionLayout {
        let boundedText = Self.inputSuffix(text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Self.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: boundedText, attributes: [
            .font: Self.font,
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraph,
        ])
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: 10_000_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        // Font fallback and RTL glyphs can extend past their line container. Refine the
        // wrap width, never the viewport or font, until the actual selected ink fits.
        // Every pass lays out the original bounded string; drawing retains that same manager.
        for _ in 0..<8 {
            guard width > 0, height > 0, container.containerSize.width > 0 else { break }
            manager.ensureLayout(for: container)
            var lines: [(glyphRange: NSRange, ink: CGRect)] = []
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, usedRect, container, glyphRange, _ in
                guard glyphRange.length > 0 else { return }
                let ink = usedRect.union(manager.boundingRect(forGlyphRange: glyphRange, in: container))
                lines.append((glyphRange, ink))
            }
            guard !lines.isEmpty else { break }
            var first = lines.count
            var selectedInk = CGRect.null
            for index in stride(from: lines.count - 1, through: 0, by: -1) {
                let candidate = selectedInk.union(lines[index].ink)
                if candidate.height > height { break }
                selectedInk = candidate
                first = index
            }
            guard first < lines.count else { break }
            if selectedInk.width > width {
                container.containerSize.width -= selectedInk.width - width + 0.5
                continue
            }
            let selected = NSUnionRange(lines[first].glyphRange, lines[lines.count - 1].glyphRange)
            let translation = CGPoint(x: -selectedInk.minX, y: height - selectedInk.maxY)
            return Self(attributedText: attributed, textStorage: storage, selectedGlyphRange: selected, translation: translation, inkBounds: selectedInk.offsetBy(dx: translation.x, dy: translation.y), layoutManager: manager)
        }
        // A glyph taller/wider than the entire viewport cannot be shown as a complete line.
        return Self(attributedText: attributed, textStorage: storage, selectedGlyphRange: NSRange(location: 0, length: 0), translation: .zero, inkBounds: .zero, layoutManager: manager)
    }
}

final class MeetingRollingCaptionNSView: NSView {
    var text = "" { didSet { if oldValue != text { invalidateCaption() } } }
    var foregroundColor = NSColor.white { didSet { if !oldValue.isEqual(foregroundColor) { invalidateCaption() } } }
    private var cachedText = ""
    private var cachedSize: CGSize = .zero
    private var cachedColor: NSColor = .clear
    private var cachedLayout: MeetingRollingCaptionLayout?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func draw(_ dirtyRect: NSRect) {
        let captionLayout = self.captionLayout
        guard captionLayout.selectedGlyphRange.length > 0 else { return }
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.clip(to: self.bounds)
        context?.translateBy(x: captionLayout.translation.x, y: captionLayout.translation.y)
        captionLayout.layoutManager.drawBackground(forGlyphRange: captionLayout.selectedGlyphRange, at: .zero)
        captionLayout.layoutManager.drawGlyphs(forGlyphRange: captionLayout.selectedGlyphRange, at: .zero)
        context?.restoreGState()
    }

    override func layout() {
        super.layout()
        if self.bounds.size != self.cachedSize { self.invalidateCaption() }
    }

    private var captionLayout: MeetingRollingCaptionLayout {
        if let cachedLayout, cachedText == text, cachedSize == bounds.size, cachedColor.isEqual(foregroundColor) { return cachedLayout }
        let value = MeetingRollingCaptionLayout.make(text, width: max(1, bounds.width), height: max(1, bounds.height), foregroundColor: foregroundColor)
        cachedText = text
        cachedSize = bounds.size
        cachedColor = foregroundColor
        cachedLayout = value
        return value
    }

    private func invalidateCaption() {
        cachedLayout = nil
        needsDisplay = true
    }
}
