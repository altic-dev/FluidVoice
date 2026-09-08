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

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *), !self.reduceTransparency {
            if self.prominent {
                content.buttonStyle(.glassProminent).tint(FluidBrandColors.blue)
                    .controlSize(.large).buttonBorderShape(.capsule)
            } else {
                content.buttonStyle(.glass).controlSize(.large).buttonBorderShape(self.circular ? .circle : .capsule)
            }
        } else {
            content.fluidButton(self.prominent ? .accent : .secondary, size: .large)
        }
    }
}

extension View {
    func fluidGlassAction(prominent: Bool = false, circular: Bool = false) -> some View {
        self.modifier(FluidGlassActionModifier(prominent: prominent, circular: circular))
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
