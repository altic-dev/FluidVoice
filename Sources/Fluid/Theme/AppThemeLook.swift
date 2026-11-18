import SwiftUI

extension AppTheme {
    /// The refined look, after fluidvoice.com: black, white and grey, with one quiet color pattern.
    /// A smooth black canvas with a faint sky at the top, flat cards with a hairline edge, a white
    /// main action and quiet grey actions. Screens read these roles through the shared components
    /// in `Components/FluidLookControls.swift`, so restyling the app means changing values here.
    /// The only hues are the tint (the sky, and the aura on the one card a page leads with and the
    /// field being typed in), which follows the accent color setting, and a maker's own logo.
    ///
    /// Pages move onto this look one at a time. A page that has moved paints its background with
    /// `.fluidCanvas()`; once every page has, the window paints it and the older palette roles go.
    struct Look {
        /// A surface: its fill (top and bottom may differ for a lit look), its edge and its shadow.
        /// The current look keeps every surface flat with no shadow.
        struct Lit {
            let top: Color
            let bottom: Color
            let edgeTop: Color
            let edgeBottom: Color
            let shadow: Color
            let shadowRadius: CGFloat
            let shadowY: CGFloat

            static func flat(_ fill: Color, edge: Color = .clear) -> Lit {
                Lit(top: fill, bottom: fill, edgeTop: edge, edgeBottom: edge, shadow: .clear, shadowRadius: 0, shadowY: 0)
            }
        }

        struct Action {
            let body: Lit
            let label: Color
        }

        /// The faint sky behind a page.
        struct Ambience {
            /// Faint warm light from the top left, gone by mid-page.
            let glow: Color
            /// A fainter, cooler light from the top right.
            let farGlow: Color
        }

        /// The look's soft colors, after fluidvoice.com, taken from the tint the accent color setting
        /// picks. As an edge they run across the top of a shape and fade out down its sides, with a
        /// faint light just inside; only the one card a page leads with and the field being typed
        /// in get it. Inside a lead card they also fill its progress bar and week dots, so all the
        /// color on a page sits in one place. Never animated.
        struct Aura {
            let tint: FluidLookTint
            /// The plain edge the colored part fades into at both ends.
            let rest: Color
            /// How strongly the edge glows, like neon, around a lead card's top edge; 0 hides it.
            let haloOpacity: Double
            /// How strongly the colors haze the page around a lead card's top edge; 0 hides it.
            let hazeOpacity: Double

            var colors: [Color] { self.tint.colors }

            /// The edge's colors from left to right; the ends match the plain edge.
            var stops: [Gradient.Stop] {
                [
                    .init(color: self.rest, location: 0),
                    .init(color: self.tint.start, location: 0.25),
                    .init(color: self.tint.middle, location: 0.55),
                    .init(color: self.tint.end, location: 0.8),
                    .init(color: self.rest, location: 1),
                ]
            }

            /// The colors as one left-to-right gradient, for progress fills and chart lines.
            var ink: LinearGradient {
                LinearGradient(colors: self.colors, startPoint: .leading, endPoint: .trailing)
            }

            /// The color at a point along the gradient: 0 is the left end, 1 the right.
            func color(at position: Double) -> Color {
                let scaled = min(1, max(0, position.isFinite ? position : 0)) * 2
                return scaled <= 1
                    ? self.tint.start.mix(with: self.tint.middle, by: scaled)
                    : self.tint.middle.mix(with: self.tint.end, by: scaled - 1)
            }
        }

        /// Page background under the ambience.
        let canvas: Color
        /// Pop-up background: flat, no sky.
        let sheet: Color
        let ambience: Ambience
        /// Cards.
        let card: Lit
        let aura: Aura
        /// Flat fill for bands inside a card or pop-up.
        let surface: Color
        /// Edges of flat groups such as metric tiles.
        let edge: Color
        /// Lines between rows and sections.
        let divider: Color
        let text: Color
        let secondaryText: Color
        /// Small labels, column headers and notes.
        let tertiaryText: Color
        /// Dot or mark for "in use", "supported" and similar.
        let highlight: Color
        let highlightText: Color
        let highlightFill: Color
        /// Neutral fill for tiles and plain chips. Also the empty track of a bar or heatmap.
        let quietFill: Color
        /// Ink for data: chart bars and lines, filled heatmap squares and progress fills.
        /// Lighter steps of it show less; the track under it is `quietFill`.
        let data: Color
        let tileGlyph: Color
        /// The selected row in a sidebar. Opaque, because the system list paints it as a solid fill.
        let selection: Color
        /// A switch that is on.
        let switchOn: Color
        /// The one main action in a view.
        let primaryAction: Action
        /// Every other action.
        let secondaryAction: Action

        static let dark = Look.dark(tint: .fluid)
        static let light = Look.light(tint: .fluid)

        /// The sky is the tint's end and middle colors turned dim and grey, like fluidvoice.com's.
        static func dark(tint: FluidLookTint) -> Look {
            let sky = tint.map(saturation: { $0 * 0.45 }, brightness: { _ in 0.59 })
            let farSky = tint.map(saturation: { $0 }, brightness: { _ in 0.59 })
            return Look(
                canvas: Color.black,
                sheet: Color(red: 0.071, green: 0.071, blue: 0.075),
                ambience: Ambience(
                    glow: sky.end.opacity(0.3),
                    farGlow: farSky.middle.opacity(0.16)
                ),
                card: .flat(Color.white.opacity(0.04), edge: Color.white.opacity(0.08)),
                aura: Aura(tint: tint, rest: Color.white.opacity(0.14), haloOpacity: 0.6, hazeOpacity: 0.16),
                surface: Color.white.opacity(0.025),
                edge: Color.white.opacity(0.08),
                divider: Color.white.opacity(0.06),
                text: Color.white,
                secondaryText: Color.white.opacity(0.6),
                tertiaryText: Color.white.opacity(0.4),
                highlight: Color.white.opacity(0.85),
                highlightText: Color.white.opacity(0.8),
                highlightFill: Color.white.opacity(0.08),
                quietFill: Color.white.opacity(0.06),
                data: Color.white.opacity(0.85),
                tileGlyph: Color.white.opacity(0.8),
                selection: Color(white: 0.2),
                switchOn: Color(white: 0.55),
                primaryAction: Action(body: .flat(Color.white), label: Color.black),
                secondaryAction: Action(body: .flat(Color.white.opacity(0.08)), label: Color.white.opacity(0.9))
            )
        }

        /// The sky is a faint wash of the tint's end and middle colors. The aura uses deeper
        /// shades of the tint so they hold up on white.
        static func light(tint: FluidLookTint) -> Look {
            let sky = tint.map(saturation: { _ in 0.06 }, brightness: { _ in 1 })
            let farSky = tint.map(saturation: { _ in 0.08 }, brightness: { _ in 1 })
            let ink = tint.map(saturation: { min(1, $0 + 0.15) }, brightness: { $0 * 0.88 })
            return Look(
                canvas: Color(red: 0.961, green: 0.961, blue: 0.965),
                sheet: Color.white,
                ambience: Ambience(
                    glow: sky.end.opacity(0.9),
                    farGlow: farSky.middle.opacity(0.8)
                ),
                card: .flat(Color.white, edge: Color.black.opacity(0.08)),
                aura: Aura(tint: ink, rest: Color.black.opacity(0.08), haloOpacity: 0.4, hazeOpacity: 0.1),
                surface: Color.black.opacity(0.025),
                edge: Color.black.opacity(0.08),
                divider: Color.black.opacity(0.07),
                text: Color.black.opacity(0.88),
                secondaryText: Color.black.opacity(0.58),
                tertiaryText: Color.black.opacity(0.42),
                highlight: Color.black.opacity(0.8),
                highlightText: Color.black.opacity(0.75),
                highlightFill: Color.black.opacity(0.06),
                quietFill: Color.black.opacity(0.05),
                data: Color.black.opacity(0.78),
                tileGlyph: Color.black.opacity(0.7),
                selection: Color(white: 0.89),
                switchOn: Color(white: 0.2),
                primaryAction: Action(body: .flat(Color(red: 0.067, green: 0.067, blue: 0.075)), label: Color.white),
                secondaryAction: Action(body: .flat(Color.black.opacity(0.06)), label: Color.black.opacity(0.88))
            )
        }
    }
}

/// Text sizes for the refined look. Each role carries its own size, weight and letter spacing,
/// so screens never pick raw sizes.
enum FluidTextRole {
    /// Page heading.
    case pageTitle
    /// One line under a page or panel heading.
    case subtitle
    /// Pop-up heading.
    case sheetTitle
    /// Heading of a detail panel.
    case detailTitle
    /// Title over a group of settings rows.
    case groupTitle
    /// Name of the thing a card or row is about.
    case itemTitle
    /// Name in a dense list row.
    case rowTitle
    /// Running text and fact rows.
    case body
    /// Small labels, column headers, notes and status.
    case label
    /// Big number in a metric tile.
    case metric
    /// Number in a list column.
    case value

    var size: CGFloat {
        switch self {
        case .pageTitle: 34
        case .subtitle: 15
        case .sheetTitle: 17
        case .detailTitle: 22
        case .groupTitle: 15
        case .itemTitle: 20
        case .rowTitle: 14
        case .body: 13
        case .label: 12
        case .metric: 22
        case .value: 16
        }
    }

    var weight: Font.Weight {
        switch self {
        case .pageTitle, .subtitle, .body, .label: .regular
        default: .medium
        }
    }

    /// Page headings use the serif voice of the Dashboard greeting; everything else is sans.
    var design: Font.Design {
        self == .pageTitle ? .serif : .default
    }

    /// Letter spacing as a share of the size; larger text sits tighter.
    var tracking: CGFloat {
        switch self {
        case .pageTitle: -0.015
        case .detailTitle, .metric: -0.02
        default: -0.01
        }
    }

    var font: Font { .fluidSystem(size: self.size, weight: self.weight, design: self.design) }
}

extension View {
    func fluidText(_ role: FluidTextRole) -> some View {
        self.font(role.font).tracking(role.size * role.tracking)
    }
}
