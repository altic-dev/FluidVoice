import SwiftUI

/// A shared, keyboard-accessible rename affordance. Losing focus cancels rather
/// than silently saving a draft while the user navigates to another document.
private struct EditableTitleModifier: ViewModifier {
    let title: String
    let identity: String
    let enabled: Bool
    let editorFont: Font?
    let doubleClickEnabled: Bool
    let onRename: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var restingHeight: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        Group {
            if self.editing {
                TextField("Name", text: self.$draft)
                    .textFieldStyle(.roundedBorder)
                    .font(self.editorFont)
                    .frame(minHeight: self.restingHeight)
                    .focused(self.$focused)
                    .accessibilityLabel("Rename \(self.title)")
                    .onSubmit(self.commit)
                    .onKeyPress(.escape) {
                        self.cancel()
                        return .handled
                    }
                    .task {
                        // Wait until the native field is mounted before requesting focus.
                        await Task.yield()
                        guard self.editing else { return }
                        self.focused = true
                    }
            } else {
                if self.doubleClickEnabled {
                    content
                        .highPriorityGesture(TapGesture(count: 2).onEnded { self.begin() })
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.restingHeight = $0 }
                        .accessibilityAction(named: Text("Rename"), self.begin)
                } else {
                    content
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.restingHeight = $0 }
                        .accessibilityAction(named: Text("Rename"), self.begin)
                }
            }
        }
        .help(self.enabled ? (self.doubleClickEnabled ? "Double-click to rename. Enter saves; Escape cancels." : "Right-click for Rename. Enter saves; Escape cancels.") : self.title)
        .contextMenu {
            Button("Rename…", systemImage: "pencil", action: self.begin)
                .disabled(!self.enabled)
        }
        .onChange(of: self.focused) { _, focused in
            if !focused { self.editing = false }
        }
        .onChange(of: self.identity) { _, _ in self.cancel() }
        .onChange(of: self.title) { _, _ in self.cancel() }
        .onChange(of: self.enabled && self.isEnabled) { _, enabled in
            if !enabled { self.cancel() }
        }
    }

    private func begin() {
        guard self.enabled, self.isEnabled else { return }
        self.draft = self.title
        self.editing = true
    }

    private func cancel() {
        self.editing = false
        self.focused = false
    }

    private func commit() {
        guard self.editing, self.enabled, self.isEnabled else { return }
        let value = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        self.cancel()
        if value != self.title { self.onRename(value) }
    }
}

extension View {
    func editableTitle(_ title: String, id: String, enabled: Bool = true, editorFont: Font? = nil, doubleClickEnabled: Bool = true, onRename: @escaping (String) -> Void) -> some View {
        self.modifier(EditableTitleModifier(title: title, identity: id, enabled: enabled, editorFont: editorFont, doubleClickEnabled: doubleClickEnabled, onRename: onRename))
    }
}
