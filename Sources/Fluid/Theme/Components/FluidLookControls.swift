import AppKit
import SwiftUI

// Building blocks of the refined look (`AppTheme.Look`): the lit canvas, grain, lit cards and
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
/// hover look without the pointer, for a card that marks keyboard focus that way.
struct FluidCardButtonStyle: ButtonStyle {
    var padding: CGFloat = 14
    var isHighlighted = false

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, padding: self.padding, isHighlighted: self.isHighlighted)
    }

    private struct CardBody: View {
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false
        let configuration: Configuration
        let padding: CGFloat
        let isHighlighted: Bool

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
                .fluidLit(self.theme.look.card, in: shape, isPressed: interaction.isPressed, wash: wash)
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
    func fluidCardButton(padding: CGFloat = 14, isHighlighted: Bool = false) -> some View {
        self.buttonStyle(FluidCardButtonStyle(padding: padding, isHighlighted: isHighlighted))
    }

    /// Paints the page background, light and grain, including under the toolbar. Only for pages
    /// on the refined look.
    func fluidCanvas() -> some View {
        self.modifier(FluidCanvas())
    }

    /// A two-tone fill lit from above with a brighter top edge and a shadow, behind this view.
    /// `wash` tints the fill for hover or press without touching the content.
    func fluidLit<S: InsettableShape>(_ lit: AppTheme.Look.Lit, in shape: S, isPressed: Bool = false, wash: Color = .clear) -> some View {
        self.modifier(FluidLitBackground(lit: lit, shape: shape, isPressed: isPressed, wash: wash))
    }
}

private struct FluidLitBackground<S: InsettableShape>: ViewModifier {
    let lit: AppTheme.Look.Lit
    let shape: S
    let isPressed: Bool
    let wash: Color

    func body(content: Content) -> some View {
        content
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
    }
}

private struct FluidCanvas: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.background { FluidAmbientBackground(base: self.theme.look.canvas).ignoresSafeArea() }
    }
}

/// A base color with the look's faint top light and fine grain, after fluidvoice.com: one light
/// from the top left, gone by mid-page. The grain is laid on with an overlay blend, so it shows
/// only where there is light and the dark stays clean. Static: no animation, no timers.
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
            }
            Image(nsImage: FluidGrainTile.image)
                .renderingMode(.template)
                .interpolation(.none)
                .resizable(resizingMode: .tile)
                .foregroundStyle(ambience.grain)
                .opacity(ambience.grainOpacity)
                .blendMode(.overlay)
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

/// One tile of sparse speckles, made once and tiled. Tinted and faded by the caller.
private enum FluidGrainTile {
    static let image: NSImage = {
        let side = 128
        let image = NSImage(size: NSSize(width: side, height: side))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4,
            bitsPerPixel: 32
        ), let pixels = rep.bitmapData else { return image }
        // A fixed seed keeps the pattern identical on every launch and every page.
        var state: UInt32 = 0x2f6b1d35
        for index in 0..<side * side {
            state = state &* 1_664_525 &+ 1_013_904_223
            // Sparse speckles: about a third of the pixels stay empty, the rest ramp up.
            let noise = Double(state >> 24) / 255
            let strength = UInt8((min(1, max(0, noise * 2.2 - 0.7)) * 255).rounded())
            for channel in 0..<4 {
                pixels[index * 4 + channel] = strength
            }
        }
        rep.size = NSSize(width: side, height: side)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }()
}

/// A card in the look's card surface.
struct FluidSurfaceCard<Content: View>: View {
    static var cornerRadius: CGFloat { 14 }

    @Environment(\.theme) private var theme
    var padding: CGFloat = 14
    @ViewBuilder let content: () -> Content

    var body: some View {
        self.content()
            .padding(self.padding)
            .fluidLit(self.theme.look.card, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
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
/// Keyboard focus shows as a hairline edge, not a colored ring.
struct FluidSearchField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    let placeholder: String
    @FocusState private var isFocused: Bool

    var body: some View {
        let look = self.theme.look
        let shape = RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
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
        .background(look.quietFill, in: shape)
        .overlay(shape.strokeBorder(self.isFocused ? look.tertiaryText : .clear, lineWidth: 1).allowsHitTesting(false))
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
