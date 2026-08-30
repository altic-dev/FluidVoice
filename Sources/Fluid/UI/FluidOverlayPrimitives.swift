import SwiftUI

enum FluidOverlayAngularBorderStops {
    static let dictationPill: [Gradient.Stop] = [
        .init(color: .white.opacity(0.06), location: 0),
        .init(color: .white.opacity(0.55), location: 0.13),
        .init(color: .white.opacity(0.10), location: 0.30),
        .init(color: .white.opacity(0.03), location: 0.55),
        .init(color: .white.opacity(0.22), location: 0.80),
        .init(color: .white.opacity(0.06), location: 1),
    ]
}

struct FluidOverlaySurfaceBase: View {
    struct Shadow {
        var opacity: Double
        var radius: CGFloat
        var y: CGFloat
    }

    var cornerRadius: CGFloat
    var shadow: Shadow?

    var body: some View {
        RoundedRectangle(cornerRadius: self.cornerRadius)
            .fill(Color.black)
            .shadow(
                color: Color.black.opacity(self.shadow?.opacity ?? 0),
                radius: self.shadow?.radius ?? 0,
                x: 0,
                y: self.shadow?.y ?? 0
            )
    }
}

struct FluidOverlayBorder: View {
    enum Style {
        case staticAngular(angle: Angle, lineWidth: CGFloat)
        case linear(topOpacity: Double, bottomOpacity: Double, lineWidth: CGFloat)
    }

    var cornerRadius: CGFloat
    var style: Style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: self.cornerRadius)
        switch self.style {
        case .staticAngular(let angle, let lineWidth):
            shape.strokeBorder(
                AngularGradient(
                    stops: FluidOverlayAngularBorderStops.dictationPill,
                    center: .center,
                    angle: angle
                ),
                lineWidth: lineWidth
            )
        case .linear(let topOpacity, let bottomOpacity, let lineWidth):
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(topOpacity),
                        Color.white.opacity(bottomOpacity),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: lineWidth
            )
        }
    }
}

struct FluidOverlaySurface: View {
    typealias Border = FluidOverlayBorder.Style
    typealias Shadow = FluidOverlaySurfaceBase.Shadow

    var cornerRadius: CGFloat
    var border: Border
    var shadow: Shadow?

    var body: some View {
        ZStack {
            FluidOverlaySurfaceBase(cornerRadius: self.cornerRadius, shadow: self.shadow)
            FluidOverlayBorder(cornerRadius: self.cornerRadius, style: self.border)
        }
    }
}

struct FluidOverlayLevelBars: View {
    var heights: [CGFloat]
    var width: CGFloat
    var spacing: CGFloat
    var cornerRadius: CGFloat
    var color: Color
    var glowColor: Color
    var glowRadius: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: self.spacing) {
            ForEach(Array(self.heights.enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: self.cornerRadius)
                    .fill(self.color)
                    .frame(width: self.width, height: height)
                    .shadow(color: self.glowColor, radius: self.glowRadius)
            }
        }
    }
}
