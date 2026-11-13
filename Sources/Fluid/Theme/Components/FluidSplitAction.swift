import SwiftUI

/// A primary action and a separate options menu share one clipped, opaque surface.
struct FluidSplitAction<Options: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let options: () -> Options

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var menuHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: self.action) {
                Text(self.title)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(FluidSplitActionSegmentStyle())
            .accessibilityIdentifier("meeting-prompt-primary-action")

            Rectangle()
                .fill(self.theme.palette.separator.opacity(0.55))
                .frame(width: 1, height: 22)
                .allowsHitTesting(false)

            Menu {
                self.options()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.fluidSystem(size: 11, weight: .medium))
                    .frame(width: 30, height: 34)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(FluidSplitMenuSegmentStyle())
            .frame(width: 30, height: 34)
            .contentShape(Rectangle())
            .background(self.theme.palette.primaryText.opacity(self.menuHovered && self.isEnabled ? 0.08 : 0))
            .onHover { self.menuHovered = $0 && self.isEnabled }
            .onChange(of: self.isEnabled) { _, enabled in
                if !enabled { self.menuHovered = false }
            }
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.menuHovered)
            .accessibilityLabel("More options")
            .accessibilityIdentifier("meeting-prompt-options")
        }
        .font(self.theme.typography.body)
        .foregroundStyle(self.theme.palette.primaryText)
        .background(self.theme.palette.primaryText.opacity(0.04))
        .background(self.theme.palette.elevatedCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(self.isEnabled ? 1 : 0.45)
        .fixedSize()
    }
}

private struct FluidSplitActionSegmentStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(self.theme.palette.primaryText.opacity(self.isEnabled ? (configuration.isPressed ? 0.16 : (self.hovered ? 0.08 : 0)) : 0))
            .onHover { self.hovered = $0 && self.isEnabled }
            .onChange(of: self.isEnabled) { _, enabled in
                if !enabled { self.hovered = false }
            }
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.hovered)
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Keep the native menu's action region and the outer hover region the same size.
private struct FluidSplitMenuSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 34)
            .contentShape(Rectangle())
    }
}
