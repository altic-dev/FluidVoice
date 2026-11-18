import SwiftUI

struct FluidPencilShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        path.move(to: point(0.12, 0.88))
        path.addLine(to: point(0.19, 0.62))
        path.addLine(to: point(0.69, 0.12))
        path.addQuadCurve(to: point(0.82, 0.12), control: point(0.755, 0.055))
        path.addLine(to: point(0.88, 0.18))
        path.addQuadCurve(to: point(0.88, 0.31), control: point(0.945, 0.245))
        path.addLine(to: point(0.38, 0.81))
        path.closeSubpath()
        path.move(to: point(0.62, 0.19))
        path.addLine(to: point(0.81, 0.38))
        path.move(to: point(0.19, 0.62))
        path.addLine(to: point(0.38, 0.81))
        return path
    }
}

struct FluidHoverIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverContent(configuration: configuration)
    }

    private struct HoverContent: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.theme) private var theme
        @State private var isHovered = false

        var body: some View {
            self.configuration.label
                // Grey like every other quiet control: the symbol darkens and a soft fill shows.
                .foregroundStyle(self.isHovered && self.isEnabled ? self.theme.look.text : self.theme.look.secondaryText)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 7).fill(
                    FluidInteractionVisuals.fill(
                        self.theme.palette,
                        isHovered: self.isEnabled && self.isHovered,
                        isPressed: self.isEnabled && self.configuration.isPressed
                    )
                ))
                .contentShape(Rectangle())
                .opacity(self.isEnabled ? 1 : 0.4)
                .onHover { self.isHovered = $0 }
        }
    }
}
