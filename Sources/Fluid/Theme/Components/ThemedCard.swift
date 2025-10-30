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

        content
            .padding(padding ?? theme.metrics.spacing.lg)
            .background(configuration.material, in: shape)
            .background(
                shape
                    .fill(configuration.background)
                    .overlay(
                        shape.stroke(
                            configuration.border.opacity(
                                isHovered && hoverEffect ? configuration.hoverBorderOpacity : configuration.borderOpacity
                            ),
                            lineWidth: configuration.borderWidth
                        )
                    )
                    .shadow(
                        color: configuration.shadow.color.opacity(
                            isHovered && hoverEffect ? min(configuration.shadow.opacity + configuration.hoverShadowBoost, 1.0) : configuration.shadow.opacity
                        ),
                        radius: configuration.shadow.radius,
                        x: configuration.shadow.x,
                        y: isHovered && hoverEffect ? configuration.shadow.y + 1 : configuration.shadow.y
                    )
            )
            .scaleEffect(isHovered && hoverEffect ? 1.01 : 1.0)
            .onHover { hovering in
                guard hoverEffect else { return }
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.18), value: isHovered)
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
            switch style {
            case .standard:
                background = theme.palette.cardBackground
                border = theme.palette.cardBorder
                borderOpacity = 0.28
                hoverBorderOpacity = 0.5
                borderWidth = 1
                material = theme.materials.card
                cornerRadius = theme.metrics.corners.lg
                shadow = theme.metrics.cardShadow
                hoverShadowBoost = 0.12
            case .prominent:
                background = theme.palette.elevatedCardBackground
                border = theme.palette.accent
                borderOpacity = 0.25
                hoverBorderOpacity = 0.55
                borderWidth = 1.2
                material = theme.materials.elevatedCard
                cornerRadius = theme.metrics.corners.lg
                shadow = theme.metrics.elevatedCardShadow
                hoverShadowBoost = 0.15
            case .subtle:
                background = theme.palette.contentBackground
                border = theme.palette.cardBorder
                borderOpacity = 0.18
                hoverBorderOpacity = 0.32
                borderWidth = 0.8
                material = theme.materials.card
                cornerRadius = theme.metrics.corners.md
                shadow = theme.metrics.cardShadow
                hoverShadowBoost = 0.08
            }
        }
    }
}

