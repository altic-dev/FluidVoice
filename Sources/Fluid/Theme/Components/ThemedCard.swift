import SwiftUI

enum ThemedCardStyle {
    case standard
    case prominent
    case subtle
}

struct ThemedCard<Content: View>: View {
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private let style: ThemedCardStyle
    private let hoverEffect: Bool
    private let padding: CGFloat?
    private let content: Content

    init(
        style: ThemedCardStyle = .standard,
        padding: CGFloat? = nil,
        hoverEffect: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.padding = padding
        self.hoverEffect = hoverEffect
        self.content = content()
    }

    var body: some View {
        let configuration = CardConfiguration(style: style, theme: theme)
        let shape = RoundedRectangle(cornerRadius: configuration.cornerRadius, style: .continuous)

        self.content
            .padding(self.padding ?? self.theme.metrics.cardSurface.defaultPadding)
            .background(configuration.material, in: shape)
            .background(
                shape
                    .fill(configuration.background)
                    .overlay(
                        shape.stroke(
                            configuration.border.opacity(
                                self.isHovered && self.hoverEffect ? configuration.hoverBorderOpacity : configuration.borderOpacity
                            ),
                            lineWidth: configuration.borderWidth
                        )
                    )
                    .shadow(
                        color: configuration.shadow.color.opacity(
                            self.isHovered && self.hoverEffect ? min(configuration.shadow.opacity + configuration.hoverShadowBoost, 1.0) : configuration.shadow.opacity
                        ),
                        radius: configuration.shadow.radius,
                        x: configuration.shadow.x,
                        y: self.isHovered && self.hoverEffect ? configuration.shadow.y + 1 : configuration.shadow.y
                    )
            )
            .scaleEffect(self.isHovered && self.hoverEffect ? 1.01 : 1.0)
            .onHover { hovering in
                guard self.hoverEffect else { return }
                self.isHovered = hovering
            }
            .animation(.easeOut(duration: 0.18), value: self.isHovered)
    }
}

// MARK: - Configuration

private extension ThemedCard {
    struct CardConfiguration {
        let background: Color
        let border: Color
        let borderOpacity: Double
        let hoverBorderOpacity: Double
        let borderWidth: CGFloat
        let material: Material
        let cornerRadius: CGFloat
        let shadow: AppTheme.Metrics.Shadow
        let hoverShadowBoost: Double

        init(style: ThemedCardStyle, theme: AppTheme) {
            let cardSurface = theme.metrics.cardSurface
            let variant: AppTheme.Metrics.CardSurface.Variant

            switch style {
            case .standard:
                variant = cardSurface.standard
                self.background = theme.palette.cardBackground
                self.border = theme.palette.cardBorder
                self.material = theme.materials.card
                self.cornerRadius = theme.metrics.corners.lg
                self.shadow = theme.metrics.cardShadow
            case .prominent:
                variant = cardSurface.prominent
                self.background = theme.palette.elevatedCardBackground
                self.border = theme.palette.accent
                self.material = theme.materials.elevatedCard
                self.cornerRadius = theme.metrics.corners.lg
                self.shadow = theme.metrics.elevatedCardShadow
            case .subtle:
                variant = cardSurface.subtle
                self.background = theme.palette.contentBackground
                self.border = theme.palette.cardBorder
                self.material = theme.materials.card
                self.cornerRadius = theme.metrics.corners.md
                self.shadow = theme.metrics.cardShadow
            }

            self.borderOpacity = variant.borderOpacity
            self.hoverBorderOpacity = variant.hoverBorderOpacity
            self.borderWidth = variant.borderWidth
            self.hoverShadowBoost = variant.hoverShadowBoost
        }
    }
}
