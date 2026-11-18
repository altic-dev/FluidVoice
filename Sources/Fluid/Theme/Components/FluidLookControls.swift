import SwiftUI

// Building blocks of the refined look (`AppTheme.Look`): the canvas and its sky, lit cards and
// keys, hairlines, page header and symbol tiles. Screens pass content only; colors, light and
// sizes come from the theme.

enum FluidActionRole {
    /// The one main action in a view.
    case primary
    /// Every other action.
    case secondary
}

enum FluidActionSize {
    /// Inside cards, rows and banners.
    case regular
    /// Pop-up and page footers.
    case large
}

/// A key-like capsule lit from above. Hover brightens, press darkens, drops the top light and
/// settles in; disabled fades and ignores the pointer.
struct FluidActionStyle: ButtonStyle {
    let role: FluidActionRole
    let size: FluidActionSize

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, role: self.role, size: self.size)
    }

    private struct ActionBody: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false
        let configuration: Configuration
        let role: FluidActionRole
        let size: FluidActionSize

        var body: some View {
            let isPressed = self.configuration.isPressed && self.isEnabled
            self.configuration.label
                .modifier(FluidActionPaint(role: self.role, size: self.size, isHovered: self.isHovered && self.isEnabled, isPressed: isPressed))
                .contentShape(Capsule())
                .contentShape(.focusEffect, Capsule())
                .scaleEffect(isPressed && !self.reduceMotion ? 0.97 : 1)
                .opacity(self.isEnabled ? 1 : 0.4)
                .onHover { self.isHovered = $0 }
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: self.isHovered)
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.08), value: isPressed)
        }
    }
}

/// The capsule's type, padding, fill and hover or press wash. Shared by the action button and by
/// `FluidActionLabel`, so a pill inside a clickable card looks exactly like a real one.
private struct FluidActionPaint: ViewModifier {
    @Environment(\.theme) private var theme
    let role: FluidActionRole
    let size: FluidActionSize
    let isHovered: Bool
    let isPressed: Bool

    func body(content: Content) -> some View {
        let action = self.role == .primary ? self.theme.look.primaryAction : self.theme.look.secondaryAction
        let wash = self.isPressed ? Color.black.opacity(0.14) : action.label.opacity(self.isHovered ? 0.08 : 0)
        content
            .font(.fluidSystem(size: self.size == .large ? 14 : 13, weight: .medium))
            .tracking(-0.12)
            .lineLimit(1)
            .foregroundStyle(action.label)
            .padding(.horizontal, self.size == .large ? 18 : 14)
            .padding(.vertical, self.size == .large ? 8 : 6)
            .fluidLit(action.body, in: Capsule(), isPressed: self.isPressed, wash: wash)
    }
}

/// Whether the clickable card around a view is hovered or pressed.
struct FluidCardInteraction: Equatable {
    var isHovered = false
    var isPressed = false
}

private struct FluidCardInteractionKey: EnvironmentKey {
    static let defaultValue = FluidCardInteraction()
}

extension EnvironmentValues {
    var fluidCardInteraction: FluidCardInteraction {
        get { self[FluidCardInteractionKey.self] }
        set { self[FluidCardInteractionKey.self] = newValue }
    }
}

/// An action pill inside a clickable card. The whole card is the control, so the pill takes its
/// hover and press from the card instead of the pointer.
struct FluidActionLabel: View {
    @Environment(\.fluidCardInteraction) private var interaction
    let title: String
    var role: FluidActionRole = .secondary
    var size: FluidActionSize = .regular

    var body: some View {
        Text(self.title)
            .modifier(FluidActionPaint(role: self.role, size: self.size, isHovered: self.interaction.isHovered, isPressed: self.interaction.isPressed))
            .accessibilityHidden(true)
    }
}

/// A whole card that is one button: the card surface with the shared hover and press fill over
/// all of it, a slight settle on press, and the keyboard-focus ring in the card's shape. Any
/// `FluidActionLabel` inside lights with it. Disabled cards show no hover. `isHighlighted` shows the
/// hover look without the pointer, for a card that marks keyboard focus that way. `leads` gives the
/// card the aura edge; only the one card a page leads with gets it.
struct FluidCardButtonStyle: ButtonStyle {
    var padding: CGFloat = 14
    var isHighlighted = false
    var leads = false

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, padding: self.padding, isHighlighted: self.isHighlighted, leads: self.leads)
    }

    private struct CardBody: View {
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false
        let configuration: Configuration
        let padding: CGFloat
        let isHighlighted: Bool
        let leads: Bool

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: FluidSurfaceCard<EmptyView>.cornerRadius, style: .continuous)
            let interaction = FluidCardInteraction(
                isHovered: (self.isHovered || self.isHighlighted) && self.isEnabled,
                isPressed: self.configuration.isPressed && self.isEnabled
            )
            let wash = FluidInteractionVisuals.fill(self.theme.palette, isHovered: interaction.isHovered, isPressed: interaction.isPressed)
            self.configuration.label
                .environment(\.fluidCardInteraction, interaction)
                .padding(self.padding)
                .fluidLit(self.theme.look.card, in: shape, isPressed: interaction.isPressed, wash: wash, aura: self.leads ? self.theme.look.aura : nil)
                .contentShape(shape)
                .contentShape(.focusEffect, shape)
                .scaleEffect(interaction.isPressed && !self.reduceMotion ? 0.99 : 1)
                .onHover { self.isHovered = $0 }
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.12), value: interaction.isHovered)
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.08), value: interaction.isPressed)
        }
    }
}

extension View {
    func fluidAction(_ role: FluidActionRole = .secondary, size: FluidActionSize = .regular) -> some View {
        self.buttonStyle(FluidActionStyle(role: role, size: size))
    }

    /// Makes a whole card one button. Put a `FluidActionLabel` inside to name the action.
    /// `leads` marks the one card a page leads with, which gets the aura edge.
    func fluidCardButton(padding: CGFloat = 14, isHighlighted: Bool = false, leads: Bool = false) -> some View {
        self.buttonStyle(FluidCardButtonStyle(padding: padding, isHighlighted: isHighlighted, leads: leads))
    }

    /// Paints the page background and its faint sky, including under the toolbar. Only for pages
    /// on the refined look.
    func fluidCanvas() -> some View {
        self.modifier(FluidCanvas())
    }

    /// A two-tone fill lit from above with a brighter top edge and a shadow, behind this view.
    /// `wash` tints the fill for hover or press without touching the content. `aura` lays the
    /// look's colored edge over the top of the plain one.
    func fluidLit<S: InsettableShape>(
        _ lit: AppTheme.Look.Lit,
        in shape: S,
        isPressed: Bool = false,
        wash: Color = .clear,
        aura: AppTheme.Look.Aura? = nil
    ) -> some View {
        self.modifier(FluidLitBackground(lit: lit, shape: shape, isPressed: isPressed, wash: wash, aura: aura))
    }
}

private struct FluidLitBackground<S: InsettableShape>: ViewModifier {
    let lit: AppTheme.Look.Lit
    let shape: S
    let isPressed: Bool
    let wash: Color
    let aura: AppTheme.Look.Aura?

    func body(content: Content) -> some View {
        content
            .background {
                if let aura {
                    FluidAuraBloom(aura: aura, shape: self.shape)
                }
            }
            .background {
                self.shape
                    .fill(LinearGradient(colors: [self.lit.top, self.lit.bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(self.shape.fill(self.wash))
                    .shadow(color: self.isPressed ? .clear : self.lit.shadow, radius: self.lit.shadowRadius, y: self.lit.shadowY)
            }
            .overlay {
                self.shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [self.isPressed ? self.lit.edgeBottom : self.lit.edgeTop, self.lit.edgeBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .overlay {
                if let aura {
                    FluidAuraEdge(aura: aura, shape: self.shape)
                }
            }
    }
}

/// How far down a shape the aura reaches before it is gone.
private let fluidAuraFade = LinearGradient(
    stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.6)],
    startPoint: .top,
    endPoint: .bottom
)

/// The aura line over a shape's plain edge: one point of color across the top, fading out down the
/// sides so the plain edge carries on below. Static.
private struct FluidAuraEdge<S: InsettableShape>: View {
    let aura: AppTheme.Look.Aura
    let shape: S

    var body: some View {
        self.shape
            .strokeBorder(LinearGradient(stops: self.aura.stops, startPoint: .leading, endPoint: .trailing), lineWidth: 1)
            .mask(fluidAuraFade)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The light around a lead card, drawn once under it: a soft haze of the aura colors centred on its
/// top edge, and a blurred copy of the edge so the line glows like neon, both fading down the
/// sides. One Canvas, redrawn only when the card's size or colors change, so scrolling past it
/// costs nothing.
private struct FluidAuraBloom<S: InsettableShape>: View {
    /// How far the light reaches past the card's edges.
    private static var reach: CGFloat { 72 }

    let aura: AppTheme.Look.Aura
    let shape: S

    var body: some View {
        Canvas { context, size in
            let reach = Self.reach
            let card = CGRect(x: reach, y: reach, width: size.width - reach * 2, height: size.height - reach * 2)
            guard card.width > 1, card.height > 1 else { return }

            // Haze: an ellipse as wide as the card and twice the reach tall, brightest at the
            // middle of the top edge.
            var haze = context
            haze.translateBy(x: card.midX, y: card.minY)
            haze.scaleBy(x: card.width / 2, y: reach)
            haze.fill(
                Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: self.aura.tint.middle.opacity(self.aura.hazeOpacity), location: 0),
                        .init(color: self.aura.tint.start.opacity(self.aura.hazeOpacity * 0.4), location: 0.5),
                        .init(color: .clear, location: 1),
                    ]),
                    center: .zero,
                    startRadius: 0,
                    endRadius: 1
                )
            )

            // Neon: the edge line, blurred, fading out down the sides.
            var glow = context
            glow.opacity = self.aura.haloOpacity
            glow.clipToLayer { layer in
                layer.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(colors: [.black, .clear]),
                        startPoint: CGPoint(x: 0, y: card.minY),
                        endPoint: CGPoint(x: 0, y: card.minY + card.height * 0.6)
                    )
                )
            }
            glow.addFilter(.blur(radius: 7))
            glow.stroke(
                self.shape.path(in: card),
                with: .linearGradient(
                    Gradient(stops: self.aura.stops),
                    startPoint: CGPoint(x: card.minX, y: 0),
                    endPoint: CGPoint(x: card.maxX, y: 0)
                ),
                lineWidth: 2
            )
        }
        .padding(-Self.reach)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FluidCanvas: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.background { FluidAmbientBackground(base: self.theme.look.canvas).ignoresSafeArea() }
    }
}

/// A base color with the look's faint sky, after fluidvoice.com: a warm light from the top left and
/// a fainter cool one from the top right, both gone by mid-page. Smooth, with no texture. Static:
/// no animation, no timers.
struct FluidAmbientBackground: View {
    /// The lit area stops growing past this height, so tall windows stay dark below it.
    private static let lightHeight: CGFloat = 768

    @Environment(\.theme) private var theme
    let base: Color

    var body: some View {
        let ambience = self.theme.look.ambience
        ZStack {
            self.base
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = min(geometry.size.height, Self.lightHeight)
                Self.light(ambience.glow)
                    .frame(width: width * 1.1, height: height * 0.9)
                    .position(x: width * 0.1, y: 0)
                Self.light(ambience.farGlow)
                    .frame(width: width * 0.8, height: height * 0.8)
                    .position(x: width, y: height * 0.2)
            }
        }
        .compositingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// An ellipse of light that fades out at 70% of its radius.
    private static func light(_ color: Color) -> some View {
        EllipticalGradient(colors: [color, .clear], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.35)
    }
}

/// A card in the look's card surface. `leads` gives it the aura edge; only the one card a page
/// leads with gets it.
struct FluidSurfaceCard<Content: View>: View {
    static var cornerRadius: CGFloat { 14 }

    @Environment(\.theme) private var theme
    var padding: CGFloat = 14
    var leads = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        self.content()
            .padding(self.padding)
            .fluidLit(
                self.theme.look.card,
                in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous),
                aura: self.leads ? self.theme.look.aura : nil
            )
    }
}

/// A progress bar for a lead card: a quiet track with the aura colors filling it from the left and
/// glowing softly. Callers name it for accessibility.
struct FluidAuraBar: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    var height: CGFloat = 8

    var body: some View {
        let aura = self.theme.look.aura
        GeometryReader { geometry in
            let filled = geometry.size.width * min(1, max(0, self.fraction.isFinite ? self.fraction : 0))
            ZStack(alignment: .leading) {
                Capsule().fill(self.theme.look.quietFill)
                // The fill glows softly, like the lead card's edge.
                Capsule()
                    .fill(aura.ink)
                    .frame(width: filled)
                    .blur(radius: self.height)
                    .opacity(aura.haloOpacity)
                Capsule()
                    .fill(aura.ink)
                    .frame(width: filled)
            }
        }
        .frame(height: self.height)
    }
}

/// One dot per day, oldest first. A day with dictation takes its color along the aura; a quiet
/// day stays on the track.
struct FluidAuraDots: View {
    @Environment(\.theme) private var theme
    let active: [Bool]
    var size: CGFloat = 8

    var body: some View {
        let look = self.theme.look
        HStack(spacing: self.size * 0.75) {
            ForEach(self.active.indices, id: \.self) { index in
                Circle()
                    .fill(self.active[index] ? look.aura.color(at: Double(index) / Double(max(1, self.active.count - 1))) : look.quietFill)
                    .frame(width: self.size, height: self.size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A one-point line between rows or sections.
struct FluidHairline: View {
    @Environment(\.theme) private var theme
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(self.theme.look.divider)
            .frame(width: self.axis == .vertical ? 1 : nil, height: self.axis == .horizontal ? 1 : nil)
            .accessibilityHidden(true)
    }
}

/// A search box inside a page or list: a quiet grey field with a clear button once there is text.
/// Keyboard focus shows as the field chrome's edge, not the system ring.
struct FluidSearchField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    let placeholder: String
    @FocusState private var isFocused: Bool

    var body: some View {
        let look = self.theme.look
        HStack(spacing: self.theme.metrics.spacing.xs + 2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(look.tertiaryText)
                .accessibilityHidden(true)
            TextField(self.placeholder, text: self.$text)
                .textFieldStyle(.plain)
                .foregroundStyle(look.text)
                .focused(self.$isFocused)
            if !self.text.isEmpty {
                Button { self.text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .fluidGlassAction(circular: true, quiet: true)
                .accessibilityLabel("Clear search")
            }
        }
        .fluidText(.body)
        .padding(.leading, self.theme.metrics.spacing.sm + 2)
        .frame(height: 32)
        .fluidFieldChrome(isFocused: self.isFocused, padding: 0)
    }
}

private struct FluidAuraEdgeModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.theme) private var theme
    let shape: S
    let isOn: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if self.isOn {
                FluidAuraEdge(aura: self.theme.look.aura, shape: self.shape)
            }
        }
    }
}

/// The surface of a text field or editor: a quiet grey fill and, while it has keyboard focus, a
/// hairline edge with the aura across its top instead of the system ring. The caller owns the
/// focus state.
private struct FluidFieldChrome: ViewModifier {
    @Environment(\.theme) private var theme
    let isFocused: Bool
    let padding: CGFloat?

    func body(content: Content) -> some View {
        let look = self.theme.look
        let shape = RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
        content
            .padding(self.padding ?? self.theme.metrics.spacing.md)
            .background(look.quietFill, in: shape)
            .overlay(shape.strokeBorder(self.isFocused ? look.tertiaryText : .clear, lineWidth: 1).allowsHitTesting(false))
            .overlay {
                if self.isFocused {
                    FluidAuraEdge(aura: look.aura, shape: shape)
                }
            }
    }
}

extension View {
    /// The aura line alone across the top of `shape`, for the one selected row in a long list.
    func fluidAuraEdge<S: InsettableShape>(_ shape: S, isOn: Bool = true) -> some View {
        self.modifier(FluidAuraEdgeModifier(shape: shape, isOn: isOn))
    }

    /// Puts a text field or editor on the look's input surface. `padding` defaults to the
    /// theme's medium spacing; pass 0 when the content lays out its own insets.
    func fluidFieldChrome(isFocused: Bool, padding: CGFloat? = nil) -> some View {
        self.modifier(FluidFieldChrome(isFocused: isFocused, padding: padding))
    }
}

/// A symbol on a neutral rounded tile.
struct FluidGlyphTile: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: self.systemImage)
            .font(.fluidSystem(size: self.size * 0.48, weight: .medium))
            .foregroundStyle(self.theme.look.tileGlyph)
            .frame(width: self.size, height: self.size)
            .background(self.theme.look.quietFill, in: RoundedRectangle(cornerRadius: self.size * 0.29, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Page headline, optionally with one line under it. The toolbar already shows the page name,
/// so the headline is a sentence about the page, like the Dashboard greeting, never the name again.
struct FluidPageHeader: View {
    @Environment(\.theme) private var theme
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title)
                .fluidText(.pageTitle)
                .foregroundStyle(self.theme.look.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .fluidText(.subtitle)
                    .foregroundStyle(self.theme.look.secondaryText)
            }
        }
    }
}
