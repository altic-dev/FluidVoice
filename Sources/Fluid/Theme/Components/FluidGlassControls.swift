import SwiftUI

struct ProviderDefaultButton: View {
    let isCurrent: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 6) {
                if self.isCurrent { Image(systemName: "checkmark.circle.fill") }
                Text(self.isCurrent ? "Current default" : "Set as default")
            }
        }
        .fluidGlassAction()
        .disabled(self.isCurrent || !self.isEnabled)
        .help(self.isCurrent ? "Used by your main dictation shortcut. App-specific cleanup styles can override it."
            : "Use this provider for your main dictation shortcut. Choose a model and complete setup first; verification is optional.")
    }
}

/// Opt-in native controls. Existing app-wide button styles are deliberately unchanged.
struct FluidGlassControlGroup<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26, *), !self.reduceTransparency {
            GlassEffectContainer(spacing: 8) { self.content() }
        } else {
            self.content()
        }
    }
}

private struct FluidGlassActionModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let prominent: Bool
    let circular: Bool
    let tone: Color?
    let spacious: Bool
    let quiet: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if self.quiet, !self.prominent {
            content.buttonStyle(FluidQuietActionStyle(circular: self.circular, tone: self.tone, spacious: self.spacious))
        } else if #available(macOS 26, *), !self.reduceTransparency {
            if self.prominent {
                content.buttonStyle(.glassProminent).tint(self.tone ?? FluidBrandColors.blue)
                    .controlSize(self.spacious ? .extraLarge : .large).buttonBorderShape(self.circular ? .circle : .capsule)
            } else {
                // A secondary action stays neutral inside tinted containers; only an explicit tone colors it.
                content.buttonStyle(.glass).tint(self.tone).controlSize(self.spacious ? .extraLarge : .large).buttonBorderShape(self.circular ? .circle : .capsule)
            }
        } else {
            if self.prominent {
                content.buttonStyle(AccentButtonStyle(tone: self.tone ?? FluidBrandColors.blue))
            } else {
                content.buttonStyle(FluidOutlinedButtonStyle(height: FluidButtonSize.large.controlHeight))
            }
        }
    }
}

/// Native button behavior with an unboxed label and a stable, usable hit target.
private struct FluidQuietActionStyle: ButtonStyle {
    let circular: Bool
    let tone: Color?
    let spacious: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = self.isHovered && self.isEnabled
        let height = self.spacious ? FluidButtonSize.large.controlHeight : FluidButtonSize.small.controlHeight
        let pressed = configuration.isPressed && self.isEnabled
        configuration.label
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(self.tone ?? (highlighted ? self.theme.palette.primaryText : self.theme.palette.secondaryText))
            .padding(.horizontal, self.circular ? 0 : 8)
            .frame(minWidth: height, minHeight: height)
            // A soft fill in the button's own shape and hit area, so it reads as clickable on hover.
            .background {
                let fill = self.theme.palette.primaryText.opacity(pressed ? 0.14 : (highlighted ? 0.08 : 0))
                if self.circular {
                    Circle().fill(fill)
                } else {
                    Capsule().fill(fill)
                }
            }
            .contentShape(self.circular ? AnyShape(Circle()) : AnyShape(Capsule()))
            .opacity(self.isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .onHover { self.isHovered = $0 && self.isEnabled }
            .onChange(of: self.isEnabled) { _, enabled in
                if !enabled { self.isHovered = false }
            }
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
    }
}

/// Glass stays outside the menu label; macOS flattens anything drawn inside it.
private struct FluidGlassMenuActionModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.theme) private var theme

    @ViewBuilder func body(content: Content) -> some View {
        let menu = content
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(FluidGlassMenuActionStyle())
            .fixedSize(horizontal: true, vertical: false)
        // Stationary glass: native menu tracking swallows the release that interactive glass waits for.
        if #available(macOS 26, *), !self.reduceTransparency {
            menu.glassEffect(.regular, in: .capsule)
        } else {
            menu
                .background(self.theme.palette.cardBackground, in: Capsule())
                .overlay { Capsule().strokeBorder(self.theme.palette.cardBorder, lineWidth: 1).allowsHitTesting(false) }
        }
    }
}

/// Padding lives in the label so the whole pill opens the menu.
private struct FluidGlassMenuActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .frame(height: 32)
            .contentShape(Capsule())
    }
}

extension View {
    func fluidGlassMenuAction() -> some View {
        self.modifier(FluidGlassMenuActionModifier())
    }

    func fluidGlassAction(prominent: Bool = false, circular: Bool = false, tone: Color? = nil, spacious: Bool = false, quiet: Bool = false) -> some View {
        self.modifier(FluidGlassActionModifier(prominent: prominent, circular: circular, tone: tone, spacious: spacious, quiet: quiet))
            .fixedSize(horizontal: true, vertical: false)
    }
}

extension AppTheme.Metrics {
    /// Shared showcase geometry, separate from compact form rows.
    enum Showcase {
        static let pageMaxWidth: CGFloat = 1080
        static let sideCardMaxWidth: CGFloat = 240
        static let cardHeight: CGFloat = 320
        static let cardMaxWidth: CGFloat = 320
        static let cardRadius: CGFloat = 24
        static let stageHeight: CGFloat = 350
        static let metricWidth: CGFloat = 128
        static let compactMetricWidth: CGFloat = 112
    }
}
