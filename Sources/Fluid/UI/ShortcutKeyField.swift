import SwiftUI

/// A shortcut shown as centred keycaps inside a field. Click the field to record a new shortcut, the same
/// way macOS keyboard settings work; click it again (or press Escape) to stop recording. When a
/// shortcut can be cleared, a small clear button appears inside the field on hover.
struct ShortcutKeyField: View {
    static let width: CGFloat = 156
    /// Same height as the shared dropdown beside it.
    static let height: CGFloat = 34

    let shortcut: HotkeyShortcut?
    let title: String
    let isRecording: Bool
    let isLocked: Bool
    let onToggleRecording: () -> Void
    var onClear: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var canClear: Bool {
        self.onClear != nil && self.shortcut != nil && !self.isRecording && !self.isLocked
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: self.onToggleRecording) {
            HStack(spacing: 3) {
                if self.isRecording {
                    Text("Press keys…")
                        .foregroundStyle(self.theme.look.text)
                } else if let shortcut {
                    ForEach(Array(ShortcutKeycaps.caps(for: shortcut.displayString).enumerated()), id: \.offset) { _, cap in
                        self.keycap(cap)
                    }
                } else {
                    Text("Record shortcut")
                        .foregroundStyle(self.theme.palette.tertiaryText)
                }
            }
            .font(self.theme.typography.bodySmall)
            .lineLimit(1)
            // Equal room on both sides keeps the keys centred and clear of the hover clear button.
            .padding(.horizontal, self.onClear == nil ? 7 : 24)
            .frame(width: Self.width, height: Self.height)
            .fluidDropdownSurface(cornerRadius: 10)
            .overlay {
                if self.isRecording {
                    // Listening for keys shows as a solid edge in the text color, with no glow.
                    shape.strokeBorder(self.theme.look.text, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(self.isLocked && !self.isRecording)
        .overlay(alignment: .trailing) {
            if self.canClear, let onClear {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.fluidSystem(size: 13))
                        .foregroundStyle(self.theme.palette.tertiaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 3)
                .opacity(self.isHovered ? 1 : 0)
                .help("Clear shortcut")
                .accessibilityLabel("Clear \(self.title) shortcut")
            }
        }
        .onHover { self.isHovered = $0 }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.isHovered)
        .help(self.isRecording ? "Press the new shortcut, or click to stop" : "Click to change")
        .accessibilityLabel(self.isRecording ? "Recording \(self.title) shortcut" : "\(self.title) shortcut")
        .accessibilityValue(self.shortcut?.displayString ?? "Not set")
        .accessibilityHint(self.isRecording ? "Press the new shortcut" : "Press to record a new shortcut")
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(self.theme.typography.bodySmall.weight(.medium))
            .foregroundStyle(self.theme.palette.primaryText)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(self.theme.palette.primaryText.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(self.theme.palette.primaryText.opacity(0.08), lineWidth: 0.5)
            )
    }
}
