import SwiftUI

/// Neutral action button, matching the shared dropdown surface.
/// Prominent primary actions retain their accent-filled styles.
struct FluidOutlinedButtonStyle: ButtonStyle {
    var height: CGFloat? = nil
    var fillsWidth = false
    var foreground: Color? = nil
    var borderColor: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        Control(
            configuration: configuration,
            height: self.height,
            fillsWidth: self.fillsWidth,
            foreground: self.foreground,
            borderColor: self.borderColor
        )
    }

    private struct Control: View {
        let configuration: ButtonStyle.Configuration
        let height: CGFloat?
        let fillsWidth: Bool
        let foreground: Color?
        let borderColor: Color?
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        private var controlHeight: CGFloat {
            if let height { return height }
            switch self.controlSize {
            case .mini: return 26
            case .small: return 30
            case .large, .extraLarge: return 40
            default: return 34
            }
        }

        var body: some View {
            let highlighted = self.isEnabled && self.isHovered
            let pressed = self.isEnabled && self.configuration.isPressed
            let destructive = self.configuration.role == .destructive
            let tone = destructive ? Color(nsColor: .systemRed) : self.theme.palette.accent
            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
            self.configuration.label
                .font(self.theme.typography.bodySmall)
                .fontWeight(.medium)
                .foregroundStyle(self.foreground ?? (destructive ? tone : self.theme.palette.primaryText))
                .padding(.horizontal, 12)
                .frame(maxWidth: self.fillsWidth ? .infinity : nil)
                .frame(minHeight: self.controlHeight)
                .background {
                    shape.fill(self.theme.palette.elevatedCardBackground)
                        .overlay { shape.fill(tone.opacity(pressed ? 0.15 : (highlighted ? 0.08 : 0))) }
                }
                .overlay {
                    shape.strokeBorder(highlighted || pressed ? tone.opacity(0.45) : (self.borderColor ?? self.theme.palette.cardBorder), lineWidth: 1)
                }
                .contentShape(shape)
                .opacity(self.isEnabled ? 1 : 0.45)
                .onHover { self.isHovered = $0 }
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: highlighted)
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.1), value: pressed)
        }
    }
}

extension View {
    func fluidOutlinedButton() -> some View {
        self.buttonStyle(FluidOutlinedButtonStyle())
    }
}
