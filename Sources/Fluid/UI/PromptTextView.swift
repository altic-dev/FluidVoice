import AppKit
import SwiftUI

/// A lightweight macOS-native text view that reliably renders bound text immediately,
/// avoiding occasional `TextEditor` refresh glitches in sheets.
struct PromptTextView: NSViewRepresentable {
    @Binding var text: String

    var isEditable: Bool = true
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    var contentInset: CGFloat = 10

    func makeCoordinator() -> Coordinator {
        Coordinator(text: self.$text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isRichText = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.isEditable = self.isEditable
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = self.font
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: self.contentInset, height: self.contentInset)
        textView.textContainer?.lineFragmentPadding = 0

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)

        textView.string = self.text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        // Keep AppKit view in sync with SwiftUI state.
        // This is the critical bit that avoids "blank until focus changes" behavior.
        if textView.string != self.text {
            let selectedRanges = textView.selectedRanges
            textView.string = self.text
            textView.selectedRanges = selectedRanges
        }

        if textView.isEditable != self.isEditable { textView.isEditable = self.isEditable }
        textView.isSelectable = true
        textView.drawsBackground = false
        if textView.font != self.font { textView.font = self.font }
        if textView.textContainerInset != NSSize(width: self.contentInset, height: self.contentInset) {
            textView.textContainerInset = NSSize(width: self.contentInset, height: self.contentInset)
        }
        if textView.textContainer?.lineFragmentPadding != 0 {
            textView.textContainer?.lineFragmentPadding = 0
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if self.text.wrappedValue != textView.string {
                self.text.wrappedValue = textView.string
            }
        }
    }
}
