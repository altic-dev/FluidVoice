import SwiftUI

/// A stationary blue invitation with quiet motion inside; capture uses a static red control.
struct FluidRecordInvitationStyle: ButtonStyle {
    let inviting: Bool
    let recording: Bool
    var prominent = true
    var fillsWidth = false
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @State private var visible = false
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let animate = self.visible && self.inviting && self.isEnabled && !self.reduceMotion && self.scenePhase == .active
        let highlighted = self.hovered && self.isEnabled
        configuration.label
            .font(self.theme.typography.bodyStrong)
            .foregroundStyle(self.prominent ? Color.white : self.theme.palette.primaryText)
            .padding(.horizontal, 22)
            .frame(minWidth: 144, maxWidth: self.fillsWidth ? .infinity : nil, minHeight: FluidButtonSize.large.controlHeight)
            .background {
                Group {
                    if self.prominent {
                        FluidRecordInvitationSurface(
                            animate: animate,
                            recording: self.recording,
                            reduceTransparency: self.reduceTransparency
                        )
                    } else {
                        Capsule().fill(self.theme.palette.contentBackground)
                    }
                }
                .brightness(highlighted ? 0.08 : 0)
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.18), value: highlighted)
            }
            .overlay {
                Capsule().strokeBorder((self.prominent ? Color.white : self.theme.palette.secondaryText).opacity(configuration.isPressed ? 0.6 : (highlighted ? 0.48 : 0.16)), lineWidth: 1)
                    .animation(self.reduceMotion ? nil : .easeOut(duration: 0.18), value: highlighted)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .opacity(self.isEnabled ? 1 : 0.65)
            .fixedSize(horizontal: !self.fillsWidth, vertical: false)
            .onHover { self.hovered = $0 && self.isEnabled }
            .onChange(of: self.isEnabled) { _, enabled in
                if !enabled { self.hovered = false }
            }
            .onAppear { self.visible = true }
            .onDisappear { self.visible = false; self.hovered = false }
    }
}

/// Only this small background redraws. The label, hit target, and surrounding layout stay fixed.
private struct FluidRecordInvitationSurface: View {
    let animate: Bool
    let recording: Bool
    let reduceTransparency: Bool

    var body: some View {
        ZStack {
            if self.recording {
                Color.red
            } else {
                LinearGradient(
                    colors: [Color(red: 0.09, green: 0.34, blue: 0.78), Color(red: 0.15, green: 0.49, blue: 0.94), Color(red: 0.07, green: 0.35, blue: 0.82)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !self.animate)) { timeline in
                    let time = self.animate ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 24) : 0
                    Canvas { context, size in
                        guard size.width > 0, size.height > 0 else { return }
                        // One broad highlight travels slowly beneath the dots; no blur or particles to retain.
                        if !self.reduceTransparency {
                            let centre = CGPoint(x: size.width * (0.5 + 0.28 * sin(time / 24 * .pi * 2)), y: size.height * 0.35)
                            context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                                Gradient(colors: [.white.opacity(0.12), .clear]),
                                center: centre,
                                startRadius: 0,
                                endRadius: size.width * 0.55
                            ))
                        }
                        for index in 0..<12 {
                            let fraction = (Double(index) * 0.61_803_398_875 + time / 24).truncatingRemainder(dividingBy: 1)
                            let x = size.width * fraction
                            let y = size.height * (0.18 + Double((index * 7) % 13) / 13 * 0.64)
                            let diameter = 1.5 + Double(index % 3) * 0.45
                            let edgeFade = min(1, min(fraction, 1 - fraction) * 12)
                            let opacity = (self.reduceTransparency ? 0.45 : 0.32) * edgeFade
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)), with: .color(.white.opacity(opacity)))
                        }
                    }
                }
            }
        }
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

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
                content.buttonStyle(.glass).controlSize(self.spacious ? .extraLarge : .large).buttonBorderShape(self.circular ? .circle : .capsule)
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
        configuration.label
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(self.tone ?? (highlighted ? self.theme.palette.primaryText : self.theme.palette.secondaryText))
            .padding(.horizontal, self.circular ? 0 : 8)
            .frame(minWidth: height, minHeight: height)
            .contentShape(Rectangle())
            .opacity(self.isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .onHover { self.isHovered = $0 && self.isEnabled }
            .onChange(of: self.isEnabled) { _, enabled in
                if !enabled { self.isHovered = false }
            }
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
    }
}

extension View {
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
