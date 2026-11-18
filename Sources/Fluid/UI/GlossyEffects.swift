import SwiftUI

// MARK: - Hoverable Glossy Card Component

struct HoverableGlossyCard<Content: View>: View {
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private let content: Content
    private let excludeInteractiveElements: Bool

    init(excludeInteractiveElements: Bool = false, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.excludeInteractiveElements = excludeInteractiveElements
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.metrics.corners.lg, style: .continuous)
        let cardShadow = self.theme.metrics.cardShadow

        return self.content
            .background(self.theme.materials.card, in: shape)
            .background {
                shape
                    .fill(self.theme.palette.cardBackground)
                    .overlay(
                        shape
                            .stroke(
                                self.theme.palette.cardBorder.opacity(self.isHovered ? 0.5 : 0.25),
                                lineWidth: self.isHovered ? 1.2 : 1
                            )
                    )
                    .shadow(
                        color: cardShadow.color.opacity(self.isHovered ? min(cardShadow.opacity + 0.1, 1.0) : cardShadow.opacity),
                        radius: self.isHovered ? cardShadow.radius + 2 : cardShadow.radius,
                        x: cardShadow.x,
                        y: self.isHovered ? cardShadow.y + 1 : cardShadow.y
                    )
            }
            .scaleEffect(self.isHovered && !self.excludeInteractiveElements ? 1.02 : 1.0)
            .onHover { hovering in
                self.isHovered = hovering
            }
            .animation(.easeOut(duration: 0.18), value: self.isHovered)
    }
}

// MARK: - Button Hover Extension

extension View {
    func buttonHoverEffect() -> some View {
        modifier(ButtonHoverModifier())
    }
}

struct ButtonHoverModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(self.isHovered ? FluidInteractionVisuals.hoverScale : 1.0)
            .shadow(
                color: self.theme.palette.accent.opacity(self.isHovered ? 0.35 : 0.0),
                radius: self.isHovered ? 8 : 0,
                x: 0,
                y: self.isHovered ? 3 : 0
            )
            .onHover { hovering in
                self.isHovered = hovering
            }
            .animation(FluidInteractionVisuals.hoverAnimation, value: self.isHovered)
    }
}
