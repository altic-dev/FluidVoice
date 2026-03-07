import SwiftUI

/// Central theme definition for the Fluid app. All colors, spacings and materials
/// should be defined here to keep styling consistent and easy to evolve.
struct AppTheme {
    struct Palette {
        let windowBackground: Color
        let contentBackground: Color
        let sidebarBackground: Color
        let cardBackground: Color
        let elevatedCardBackground: Color
        let toolbarBackground: Color
        let cardBorder: Color
        let separator: Color
        let primaryText: Color
        let secondaryText: Color
        let tertiaryText: Color
        let accent: Color
        let warning: Color
        let success: Color
    }

    struct Metrics {
        struct Spacing {
            let xs: CGFloat
            let sm: CGFloat
            let md: CGFloat
            let lg: CGFloat
            let xl: CGFloat
            let xxl: CGFloat

            static let standard = Spacing(
                xs: 4,
                sm: 8,
                md: 12,
                lg: 16,
                xl: 20,
                xxl: 28
            )
        }

        struct CornerRadius {
            let sm: CGFloat
            let md: CGFloat
            let lg: CGFloat
            let pill: CGFloat

            static let standard = CornerRadius(
                sm: 6,
                md: 10,
                lg: 16,
                pill: 999
            )
        }

        struct Shadow {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
            let opacity: Double

            static func subtle(color: Color, opacity: Double = 0.45) -> Shadow {
                Shadow(color: color, radius: 12, x: 0, y: 6, opacity: opacity)
            }
        }

        let spacing: Spacing
        let corners: CornerRadius
        let cardShadow: Shadow
        let elevatedCardShadow: Shadow
    }

    struct Materials {
        let window: Color
        let sidebar: Color
        let card: Color
        let elevatedCard: Color
        let toolbar: Color
    }

    let palette: Palette
    let metrics: Metrics
    let materials: Materials

    /// Default dark-forward theme tuned for macOS Sonoma / Sequoia aesthetics.
    static func dark(accent: Color) -> AppTheme {
        AppTheme(
            palette: Palette(
                windowBackground: Color(red: 0.07, green: 0.07, blue: 0.07),
                contentBackground: Color(red: 0.09, green: 0.09, blue: 0.09),
                sidebarBackground: Color(red: 0.06, green: 0.06, blue: 0.06),
                cardBackground: Color(red: 0.08, green: 0.08, blue: 0.08),
                elevatedCardBackground: Color(red: 0.11, green: 0.11, blue: 0.11),
                toolbarBackground: Color(red: 0.06, green: 0.06, blue: 0.06),

                cardBorder: Color.white.opacity(0.10),
                separator: Color.white.opacity(0.16),
                primaryText: Color(nsColor: .labelColor),
                secondaryText: Color(nsColor: .secondaryLabelColor),
                tertiaryText: Color(nsColor: .tertiaryLabelColor),
                accent: accent,
                warning: Color(nsColor: .systemOrange),
                success: accent
            ),
            metrics: Metrics(
                spacing: .standard,
                corners: .standard,
                cardShadow: .subtle(color: .black, opacity: 0.70),
                elevatedCardShadow: .subtle(color: .black, opacity: 0.80)
            ),
            materials: Materials(
                window: Color(white: 0.08, opacity: 0.85),
                sidebar: Color(white: 0.06, opacity: 0.80),
                card: Color(white: 0.10, opacity: 0.85),
                elevatedCard: Color(white: 0.12, opacity: 0.90),
                toolbar: Color(white: 0.06, opacity: 0.80)
            )
        )
    }

    static let dark = AppTheme.dark(accent: .fluidGreen)
}

// MARK: - Helpers
