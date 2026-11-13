import SwiftUI

/// A shared, keyboard-accessible rename affordance. Losing focus cancels rather
/// than silently saving a draft while the user navigates to another document.
private struct EditableTitleModifier: ViewModifier {
    let title: String
    let identity: String
    let enabled: Bool
    let editorFont: Font?
    let doubleClickEnabled: Bool
    let singleClickEnabled: Bool
    let submitUnchanged: Bool
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
                if self.singleClickEnabled {
                    HStack(alignment: .center, spacing: 8) {
                        content
                            .highPriorityGesture(TapGesture().onEnded { self.begin() })
                            .accessibilityAction(named: Text("Rename"), self.begin)
                        if self.enabled && self.isEnabled {
                            Button(action: self.begin) {
                                FluidPencilShape()
                                    .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                                    .frame(width: 20, height: 20)
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(FluidHoverIconButtonStyle())
                            .help("Rename")
                            .accessibilityLabel("Rename \(self.title)")
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.restingHeight = $0 }
                } else if self.doubleClickEnabled {
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
        .help(self.renameHelp)
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

    private var renameHelp: String {
        guard self.enabled else { return self.title }
        let action = self.singleClickEnabled ? "Click to rename." : self.doubleClickEnabled ? "Double-click to rename." : "Right-click for Rename."
        return "\(action) Enter saves; Escape cancels."
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
        if self.submitUnchanged || value != self.title { self.onRename(value) }
    }
}

extension View {
    func editableTitle(_ title: String, id: String, enabled: Bool = true, editorFont: Font? = nil, doubleClickEnabled: Bool = true, singleClickEnabled: Bool = false, submitUnchanged: Bool = false, onRename: @escaping (String) -> Void) -> some View {
        self.modifier(EditableTitleModifier(title: title, identity: id, enabled: enabled, editorFont: editorFont, doubleClickEnabled: doubleClickEnabled, singleClickEnabled: singleClickEnabled, submitUnchanged: submitUnchanged, onRename: onRename))
    }
}
