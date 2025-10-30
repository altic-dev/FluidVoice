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
        let cardShadow = theme.metrics.cardShadow

        return content
            .background(theme.materials.card, in: shape)
            .background {
                shape
                    .fill(theme.palette.cardBackground)
                    .overlay(
                        shape
                            .stroke(
                                theme.palette.cardBorder.opacity(isHovered ? 0.5 : 0.25),
                                lineWidth: isHovered ? 1.2 : 1
                            )
                    )
                    .shadow(
                        color: cardShadow.color.opacity(isHovered ? min(cardShadow.opacity + 0.1, 1.0) : cardShadow.opacity),
                        radius: isHovered ? cardShadow.radius + 2 : cardShadow.radius,
                        x: cardShadow.x,
                        y: isHovered ? cardShadow.y + 1 : cardShadow.y
                    )
            }
            .scaleEffect(isHovered && !excludeInteractiveElements ? 1.02 : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.18), value: isHovered)
    }
}

// MARK: - Button Hover Extension
extension View {
    func buttonHoverEffect() -> some View {
        self.modifier(ButtonHoverModifier())
    }
}

struct ButtonHoverModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @State private var isHovered = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .shadow(
                color: theme.palette.accent.opacity(isHovered ? 0.35 : 0.0),
                radius: isHovered ? 8 : 0,
                x: 0,
                y: isHovered ? 3 : 0
            )
            .onHover { hovering in 
                isHovered = hovering
            }
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
    }
}

// Removed CursorFollowingGlow - was causing performance issues
// struct CursorFollowingGlow: View {
//     @EnvironmentObject var mouseTracker: MousePositionTracker
//     let size: CGFloat
//     let intensity: Double
//
//     init(size: CGFloat = 300, intensity: Double = 0.2) {
//         self.size = size
//         self.intensity = intensity
//     }
//
//     var body: some View {
//         GeometryReader { geometry in
//             let relativeX = mouseTracker.relativePosition.x
//             let relativeY = mouseTracker.relativePosition.y
//
//             RadialGradient(
//                 colors: [
//                     Color.white.opacity(intensity * 0.6),
//                     Color.white.opacity(intensity * 0.3),
//                     Color.white.opacity(intensity * 0.1),
//                     Color.clear
//                 ],
//                 center: UnitPoint(x: relativeX, y: relativeY),
//                 startRadius: size * 0.1,
//                 endRadius: size * 0.5
//             )
//             .blendMode(.overlay)
//             .allowsHitTesting(false)
//             .animation(.easeInOut(duration: 0.25), value: mouseTracker.mousePosition)
//         }
//     }
// }



