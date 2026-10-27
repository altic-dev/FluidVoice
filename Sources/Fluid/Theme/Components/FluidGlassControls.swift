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

/// Core Animation moves the decoration without scheduling SwiftUI layout on every frame.
private struct FluidRecordInvitationSurface: NSViewRepresentable {
    let animate: Bool
    let recording: Bool
    let reduceTransparency: Bool

    func makeNSView(context: Context) -> FluidRecordInvitationLayerView {
        FluidRecordInvitationLayerView()
    }

    func updateNSView(_ view: FluidRecordInvitationLayerView, context: Context) {
        view.configure(animate: self.animate, recording: self.recording, reduceTransparency: self.reduceTransparency)
    }
}

private final class FluidRecordInvitationLayerView: NSView {
    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let dots = (0..<12).map { _ in CALayer() }
    private var animate = false
    private var recording = false
    private var reduceTransparency = false
    private var lastSize: CGSize?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.masksToBounds = true
        self.gradient.startPoint = CGPoint(x: 0, y: 0.5)
        self.gradient.endPoint = CGPoint(x: 1, y: 0.5)
        self.layer?.addSublayer(self.gradient)
        self.glow.type = .radial
        self.glow.colors = [NSColor.white.withAlphaComponent(0.12).cgColor, NSColor.clear.cgColor]
        self.glow.startPoint = CGPoint(x: 0.5, y: 0.35)
        self.glow.endPoint = CGPoint(x: 1, y: 0.9)
        self.layer?.addSublayer(self.glow)
        for dot in self.dots {
            self.layer?.addSublayer(dot)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func configure(animate: Bool, recording: Bool, reduceTransparency: Bool) {
        guard self.lastSize == nil || self.animate != animate || self.recording != recording || self.reduceTransparency != reduceTransparency else { return }
        self.animate = animate
        self.recording = recording
        self.reduceTransparency = reduceTransparency
        self.lastSize = nil
        self.needsLayout = true
    }

    override func layout() {
        super.layout()
        guard self.bounds.width > 0, self.bounds.height > 0, self.lastSize != self.bounds.size else { return }
        self.lastSize = self.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layer?.cornerRadius = self.bounds.height / 2
        self.gradient.frame = self.bounds
        self.gradient.colors = self.recording ? [NSColor.systemRed.cgColor, NSColor.systemRed.cgColor] : [
            NSColor(srgbRed: 0.09, green: 0.34, blue: 0.78, alpha: 1).cgColor,
            NSColor(srgbRed: 0.15, green: 0.49, blue: 0.94, alpha: 1).cgColor,
            NSColor(srgbRed: 0.07, green: 0.35, blue: 0.82, alpha: 1).cgColor,
        ]
        self.glow.frame = self.bounds
        self.glow.isHidden = self.recording || self.reduceTransparency
        self.glow.removeAllAnimations()
        if self.animate, !self.glow.isHidden {
            let drift = CABasicAnimation(keyPath: "startPoint")
            drift.fromValue = CGPoint(x: 0.22, y: 0.35)
            drift.toValue = CGPoint(x: 0.78, y: 0.35)
            drift.duration = 12
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.glow.add(drift, forKey: "drift")
        }
        for (index, dot) in self.dots.enumerated() {
            dot.removeAllAnimations()
            dot.isHidden = self.recording
            let fraction = (Double(index) * 0.61_803_398_875).truncatingRemainder(dividingBy: 1)
            let diameter = 1.5 + Double(index % 3) * 0.45
            let opacity = self.reduceTransparency ? 0.45 : 0.32
            dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2
            dot.backgroundColor = NSColor.white.cgColor
            dot.position = CGPoint(x: self.bounds.width * fraction, y: self.bounds.height * (0.18 + Double((index * 7) % 13) / 13 * 0.64))
            dot.opacity = Float(opacity * min(1, min(fraction, 1 - fraction) * 12))
            if self.animate, !self.recording {
                let travel = CABasicAnimation(keyPath: "position.x")
                travel.fromValue = 0
                travel.toValue = self.bounds.width
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, opacity, opacity, 0]
                fade.keyTimes = [0, 0.0833, 0.9167, 1]
                let motion = CAAnimationGroup()
                motion.animations = [travel, fade]
                motion.duration = 24
                motion.timeOffset = fraction * 24
                motion.repeatCount = .infinity
                dot.add(motion, forKey: "motion")
            }
        }
        CATransaction.commit()
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
