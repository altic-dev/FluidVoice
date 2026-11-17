import SwiftUI

extension AppTheme {
    /// The refined look, after fluidvoice.com: black, white and grey only. A black canvas with a
    /// faint light at the top and fine grain, flat cards with a hairline edge, a white main action
    /// and quiet grey actions. Screens read these roles through the shared components in
    /// `Components/FluidLookControls.swift`, so restyling the app means changing values here.
    /// Do not add hues: the only color on a page should be a maker's own logo.
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

        /// Light and grain behind a page.
        struct Ambience {
            /// Faint light from the top left, gone by mid-page.
            let glow: Color
            /// Speckle color and strength. It is blended so it only shows where there is light.
            let grain: Color
            let grainOpacity: Double
        }

        /// Page background under the ambience.
        let canvas: Color
        /// Pop-up background: flat, no light or grain.
        let sheet: Color
        let ambience: Ambience
        /// Cards.
        let card: Lit
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
        /// Neutral fill for tiles and plain chips.
        let quietFill: Color
        let tileGlyph: Color
        /// The one main action in a view.
        let primaryAction: Action
        /// Every other action.
        let secondaryAction: Action

        static let dark = Look(
            canvas: Color.black,
            sheet: Color(red: 0.071, green: 0.071, blue: 0.075),
            ambience: Ambience(glow: Color.white.opacity(0.07), grain: Color.white, grainOpacity: 0.6),
            card: .flat(Color.white.opacity(0.04), edge: Color.white.opacity(0.08)),
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
            tileGlyph: Color.white.opacity(0.8),
            primaryAction: Action(body: .flat(Color.white), label: Color.black),
            secondaryAction: Action(body: .flat(Color.white.opacity(0.08)), label: Color.white.opacity(0.9))
        )

        static let light = Look(
            canvas: Color(red: 0.961, green: 0.961, blue: 0.965),
            sheet: Color.white,
            ambience: Ambience(glow: Color.white.opacity(0.7), grain: Color.black, grainOpacity: 0.08),
            card: .flat(Color.white, edge: Color.black.opacity(0.08)),
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
            tileGlyph: Color.black.opacity(0.7),
            primaryAction: Action(body: .flat(Color(red: 0.067, green: 0.067, blue: 0.075)), label: Color.white),
            secondaryAction: Action(body: .flat(Color.black.opacity(0.06)), label: Color.black.opacity(0.88))
        )
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
