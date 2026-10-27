import AppKit
import Combine
import SwiftUI

/// Delivers only a shortcut capture begun in this field, through its native editor.
/// Native insertion preserves the selection and invokes the field's existing binding.
private struct DictionaryFieldDictation: ViewModifier {
    let focused: Bool
    @EnvironmentObject private var services: AppServices
    @State private var editor: NSTextView?
    @State private var originalText = ""
    @State private var originalSelection = NSRange(location: 0, length: 0)
    @State private var attempt: UUID?
    @State private var stopped = false

    func body(content: Content) -> some View {
        content
            .onReceive(self.services.asr.$isRunning.dropFirst()) { running in
                if running {
                    self.cancel()
                    guard self.focused, NSApp.isActive,
                          !self.services.asr.isDictionaryTrainingCaptureActive,
                          let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                          editor.isEditable
                    else { return }
                    self.editor = editor
                    self.originalText = editor.string
                    self.originalSelection = editor.selectedRange()
                    self.attempt = UUID()
                } else if self.attempt != nil {
                    self.stopped = true
                }
            }
            .onReceive(self.services.asr.$finalText.dropFirst()) { text in
                guard self.attempt != nil, self.stopped,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return }
                defer { self.cancel() }
                guard self.focused, NSApp.isActive, let editor = self.editor,
                      NSApp.keyWindow?.firstResponder === editor,
                      editor.string == self.originalText,
                      editor.selectedRange() == self.originalSelection
                else { return }
                editor.insertText(text, replacementRange: self.originalSelection)
            }
            .onReceive(self.services.asr.$showError) { failed in
                if failed { self.cancel() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                self.cancel()
            }
            .onChange(of: self.focused) { _, focused in
                if !focused { self.cancel() }
            }
            .task(id: self.stopped ? self.attempt : nil) {
                guard self.stopped, let attempt = self.attempt else { return }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if self.attempt == attempt { self.cancel() }
            }
            .onDisappear { self.cancel() }
    }

    private func cancel() {
        self.attempt = nil
        self.stopped = false
        self.editor = nil
        self.originalText = ""
    }
}

extension View {
    func dictionaryDictationInput(focused: Bool) -> some View {
        self.modifier(DictionaryFieldDictation(focused: focused))
    }
}
