import AppKit
import SwiftUI

/// Plain-text markdown editor with in-place styling. The stored text is exactly what was typed.
struct MeetingMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Jot down notes. Markdown works: # headings, - bullets, - [ ] tasks."
    var isEditable = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: self.$text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MeetingNotesTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? MeetingNotesTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = MeetingNotesTextView.baseFont
        textView.textColor = .labelColor
        textView.defaultParagraphStyle = MeetingNotesTextView.baseParagraphStyle
        textView.isEditable = self.isEditable
        textView.placeholder = self.placeholder
        textView.setAccessibilityLabel("Meeting notes")
        textView.delegate = context.coordinator
        textView.string = self.text
        textView.restyleAll()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = self.$text
        guard let textView = scrollView.documentView as? MeetingNotesTextView else { return }
        if textView.isEditable != self.isEditable { textView.isEditable = self.isEditable }
        textView.placeholder = self.placeholder
        if textView.string != self.text {
            // A different meeting: its text must not be undone into the previous one's.
            context.coordinator.undoManager.removeAllActions()
            textView.string = self.text
            textView.restyleAll()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let undoManager = UndoManager()

        init(text: Binding<String>) {
            self.text = text
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            self.undoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.text.wrappedValue = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard textView.isEditable, !textView.hasMarkedText() else { return false }
            let string = textView.string as NSString
            let selection = textView.selectedRange()
            var lineStart = 0
            var contentsEnd = 0
            string.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: selection.location, length: 0))
            guard NSMaxRange(selection) <= contentsEnd else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                guard selection.length == 0 else { return false }
                let beforeCursor = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
                switch MeetingMarkdownLists.returnAction(forLine: beforeCursor) {
                case let .insert(insertion):
                    textView.insertText(insertion, replacementRange: selection)
                    return true
                case let .endList(length):
                    textView.insertText("", replacementRange: NSRange(location: selection.location - length, length: length))
                    return true
                case .none:
                    return false
                }
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                let line = string.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
                guard MeetingMarkdownLists.returnAction(forLine: line) != .none else { return false }
                if selector == #selector(NSResponder.insertTab(_:)) {
                    textView.insertText("  ", replacementRange: NSRange(location: lineStart, length: 0))
                    textView.setSelectedRange(NSRange(location: selection.location + 2, length: selection.length))
                } else {
                    let spaces = line.prefix(2).prefix { $0 == " " }.count
                    let removed = spaces > 0 ? spaces : (line.hasPrefix("\t") ? 1 : 0)
                    guard removed > 0 else { return true }
                    textView.insertText("", replacementRange: NSRange(location: lineStart, length: removed))
                    let indentEnd = lineStart + removed
                    let location = selection.location >= indentEnd ? selection.location - removed : lineStart
                    let end = max(NSMaxRange(selection), indentEnd) - removed
                    textView.setSelectedRange(NSRange(location: location, length: end - location))
                }
                return true
            default:
                return false
            }
        }
    }
}

final class MeetingNotesTextView: NSTextView {
    var placeholder = "" {
        didSet {
            guard self.placeholder != oldValue else { return }
            self.setAccessibilityPlaceholderValue(self.placeholder)
            self.needsDisplay = true
        }
    }

    private enum PendingRestyle {
        case none
        case local(NSRange)
        case full
    }

    private var pendingRestyle = PendingRestyle.none
    private var taskBoxes: [NSRange] = []
    private var showsPlaceholder = false
    private var hoverTracking: NSTrackingArea?

    static let baseFont = NSFont.fluidSystemFont(ofSize: NSFont.systemFontSize + 1)
    static let baseParagraphStyle: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        return paragraph
    }()

    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: baseFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: baseParagraphStyle,
    ]

    // MARK: - Styling

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool { // swiftlint:disable:this discouraged_optional_collection
        guard super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) else { return false }
        let string = self.string as NSString
        if case .none = self.pendingRestyle, affectedRanges.count == 1, let replacement = replacementStrings?.first {
            let range = affectedRanges[0].rangeValue
            // A fence edit restyles every line after it.
            let touchesFence = Self.containsFence(string.substring(with: string.paragraphRange(for: range)))
            self.pendingRestyle = touchesFence ? .full : .local(NSRange(location: range.location, length: (replacement as NSString).length))
        } else {
            self.pendingRestyle = .full
        }
        return true
    }

    override func didChangeText() {
        if self.hasMarkedText() {
            // Restyling would strip the IME's marked-text underline; restyle once composition commits.
            self.pendingRestyle = .full
        } else {
            if case let .local(edit) = self.pendingRestyle {
                self.restyle(around: edit)
            } else {
                self.restyleAll()
            }
            self.pendingRestyle = .none
        }
        super.didChangeText()
    }

    func restyleAll() {
        guard let storage = self.textStorage else { return }
        self.apply(MeetingMarkdownStyler.spans(in: storage.string), in: NSRange(location: 0, length: storage.length))
    }

    private func restyle(around edit: NSRange) {
        guard let storage = self.textStorage else { return }
        let string = storage.string as NSString
        guard edit.location <= string.length else { return self.restyleAll() }
        // One character past the edit pulls in the following line when the edit ends with a newline.
        let probe = NSRange(location: edit.location, length: min(edit.length + 1, string.length - edit.location))
        let paragraphs = string.paragraphRange(for: probe)
        guard !Self.containsFence(string.substring(with: paragraphs)) else { return self.restyleAll() }
        self.apply(MeetingMarkdownStyler.spans(in: storage.string), in: paragraphs)
    }

    private func apply(_ spans: [MeetingMarkdownSpan], in range: NSRange) {
        guard let storage = self.textStorage else { return }
        self.taskBoxes = spans.compactMap { if case .taskBox = $0.style { $0.range } else { nil } }
        storage.beginEditing()
        storage.setAttributes(Self.baseAttributes, range: range)
        for span in spans {
            let target = NSIntersectionRange(span.range, range)
            if target.length > 0 { Self.style(storage, span.style, in: target) }
        }
        storage.endEditing()
        self.typingAttributes = Self.baseAttributes
        if (storage.length == 0) != self.showsPlaceholder {
            self.showsPlaceholder.toggle()
            self.needsDisplay = true
        }
    }

    private static func containsFence(_ text: String) -> Bool {
        text.contains("```") || text.contains("~~~")
    }

    private static func style(_ storage: NSTextStorage, _ style: MeetingMarkdownStyle, in range: NSRange) {
        switch style {
        case let .heading(level):
            let size: CGFloat = [22, 18, 15][min(max(level, 1), 3) - 1]
            storage.addAttribute(.font, value: NSFont.fluidSystemFont(ofSize: size, weight: .semibold), range: range)
        case .bold:
            self.convertFonts(storage, in: range) { font in
                font.isFixedPitch
                    ? .fluidMonospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
                    : .fluidSystemFont(ofSize: font.pointSize, weight: .semibold)
            }
        case .italic:
            self.convertFonts(storage, in: range) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
        case .code, .codeBlock:
            self.convertFonts(storage, in: range) { .fluidMonospacedSystemFont(ofSize: $0.pointSize - 1, weight: .regular) }
            storage.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
        case .quote, .listMarker, .taskBox:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .done:
            storage.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: range)
        case .link:
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        case .marker:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }

    private static func convertFonts(_ storage: NSTextStorage, in range: NSRange, _ convert: (NSFont) -> NSFont) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            storage.addAttribute(.font, value: convert(value as? NSFont ?? self.baseFont), range: run)
        }
    }

    // MARK: - Task boxes

    private func taskBox(at point: NSPoint) -> NSRange? {
        guard self.isEditable, !self.taskBoxes.isEmpty, let window = self.window else { return nil }
        let index = self.characterIndexForInsertion(at: point)
        guard let box = self.taskBoxes.first(where: { index >= $0.location && index <= NSMaxRange($0) }) else { return nil }
        let screenRect = self.firstRect(forCharacterRange: box, actualRange: nil)
        let rect = self.convert(window.convertFromScreen(screenRect), from: nil)
        return rect.contains(point) ? box : nil
    }

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        guard event.clickCount == 1, modifiers.isEmpty,
              let box = self.taskBox(at: self.convert(event.locationInWindow, from: nil))
        else { return super.mouseDown(with: event) }
        let string = self.string as NSString
        var lineStart = 0
        var contentsEnd = 0
        string.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: box)
        let line = NSRange(location: lineStart, length: contentsEnd - lineStart)
        guard let toggled = MeetingMarkdownLists.toggledTask(string.substring(with: line)) else { return super.mouseDown(with: event) }
        self.breakUndoCoalescing()
        guard self.shouldChangeText(in: line, replacementString: toggled) else { return }
        self.textStorage?.replaceCharacters(in: line, with: toggled)
        self.didChangeText()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { self.removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        self.addTrackingArea(area)
        self.hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if self.taskBox(at: self.convert(event.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() }
    }

    override func cursorUpdate(with event: NSEvent) {
        if self.taskBox(at: self.convert(event.locationInWindow, from: nil)) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    // MARK: - Keys, paste, placeholder

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        guard self.window?.firstResponder === self, modifiers.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("b", .command) where self.isEditable:
            self.wrapSelection(with: "**")
        case ("i", .command) where self.isEditable:
            self.wrapSelection(with: "*")
        // The app binds ⌘F to sidebar search; inside the notes it searches the notes.
        case ("f", .command):
            self.performFind(.showFindPanel)
        case ("g", .command):
            self.performFind(.next)
        case ("g", [.command, .shift]):
            self.performFind(.previous)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func performFind(_ action: NSFindPanelAction) {
        let sender = NSMenuItem()
        sender.tag = Int(action.rawValue)
        self.performFindPanelAction(sender)
    }

    private func wrapSelection(with marker: String) {
        let range = self.selectedRange()
        let selected = (self.string as NSString).substring(with: range)
        self.insertText("\(marker)\(selected)\(marker)", replacementRange: range)
        self.setSelectedRange(NSRange(location: range.location + (marker as NSString).length, length: range.length))
    }

    override func paste(_ sender: Any?) {
        self.pasteAsPlainText(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard self.textStorage?.length == 0, !self.placeholder.isEmpty else { return }
        let padding = self.textContainer?.lineFragmentPadding ?? 0
        let origin = self.textContainerOrigin
        let rect = NSRect(
            x: origin.x + padding,
            y: origin.y,
            width: max(0, self.bounds.width - 2 * (origin.x + padding)),
            height: max(0, self.bounds.height - origin.y)
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.baseFont,
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: Self.baseParagraphStyle,
        ]
        (self.placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attributes)
    }
}
