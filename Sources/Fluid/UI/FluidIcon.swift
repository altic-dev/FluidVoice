import SwiftUI

struct FluidIcon: View {
    let size: CGFloat
    let lineWidth: CGFloat
    let color: Color

    init(size: CGFloat = 24, lineWidth: CGFloat = 2.5, color: Color = .white) {
        self.size = size
        self.lineWidth = lineWidth
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let padding: CGFloat = self.lineWidth / 2
            let workingRect = rect.insetBy(dx: padding, dy: padding)

            // Geometric F with strategic negative space and bold construction
            let path = Path { path in
                let width = workingRect.width
                let height = workingRect.height
                let strokeWidth = self.lineWidth

                // Define key points for geometric F construction
                let leftEdge = workingRect.minX
                _ = workingRect.maxX
                let topEdge = workingRect.minY
                _ = workingRect.maxY
                let middleY = workingRect.minY + (height * 0.4) // Slightly above center for better proportions

                // Top horizontal bar - full width, bold
                let topBarRect = CGRect(
                    x: leftEdge,
                    y: topEdge,
                    width: width,
                    height: strokeWidth
                )
                path.addRect(topBarRect)

                // Vertical spine - bold, geometric
                let spineRect = CGRect(
                    x: leftEdge,
                    y: topEdge,
                    width: strokeWidth,
                    height: height
                )
                path.addRect(spineRect)

                // Middle horizontal bar - 60% width for dynamic proportions
                let middleBarWidth = width * 0.6
                let middleBarRect = CGRect(
                    x: leftEdge,
                    y: middleY,
                    width: middleBarWidth,
                    height: strokeWidth
                )
                path.addRect(middleBarRect)
            }

            // Fill the geometric shapes (no stroke, pure geometry)
            context.fill(path, with: .color(self.color))

            // Optional: Add subtle inner highlight for premium feel
            if self.lineWidth > 2 {
                let highlightPath = Path { path in
                    let highlightOffset: CGFloat = 1
                    let adjustedRect = workingRect.insetBy(dx: highlightOffset, dy: highlightOffset)
                    let width = adjustedRect.width
                    let height = adjustedRect.height
                    let strokeWidth = max(1, lineWidth - 2)

                    let leftEdge = adjustedRect.minX
                    let topEdge = adjustedRect.minY
                    let middleY = adjustedRect.minY + (height * 0.4)

                    // Thinner inner elements for depth
                    let topBarRect = CGRect(x: leftEdge, y: topEdge, width: width, height: strokeWidth)
                    path.addRect(topBarRect)

                    let spineRect = CGRect(x: leftEdge, y: topEdge, width: strokeWidth, height: height)
                    path.addRect(spineRect)

                    let middleBarRect = CGRect(x: leftEdge, y: middleY, width: width * 0.6, height: strokeWidth)
                    path.addRect(middleBarRect)
                }

                context.fill(highlightPath, with: .color(self.color.opacity(0.3)))
            }
        }
        .frame(width: self.size, height: self.size)
    }
}

// Variants for different use cases
struct FluidIconFilled: View {
    let size: CGFloat
    let color: Color
    let backgroundColor: Color
    let cornerRadius: CGFloat

    init(size: CGFloat = 32, color: Color = .white, backgroundColor: Color = .blue, cornerRadius: CGFloat = 8) {
        self.size = size
        self.color = color
        self.backgroundColor = backgroundColor
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: self.cornerRadius)
                .fill(self.backgroundColor)
                .frame(width: self.size, height: self.size)

            FluidIcon(size: self.size * 0.6, lineWidth: self.size * 0.08, color: self.color)
        }
    }
}

// Advanced variant with sophisticated negative space
struct FluidIconAdvanced: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 24, color: Color = .white) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let workingRect = rect.insetBy(dx: self.size * 0.1, dy: self.size * 0.1)

            // Create sophisticated F with angular cuts and negative space
            let path = Path { path in
                let width = workingRect.width
                let height = workingRect.height
                let strokeWidth = max(2, size * 0.12)
                let cutAngle: CGFloat = 0.3 // For dynamic angular cuts

                // Main geometric construction points
                let leftX = workingRect.minX
                _ = workingRect.maxX
                let topY = workingRect.minY
                let bottomY = workingRect.maxY
                let middleY = workingRect.minY + (height * 0.38)

                // Vertical spine with angular top cut
                path.move(to: CGPoint(x: leftX, y: bottomY))
                path.addLine(to: CGPoint(x: leftX, y: topY + strokeWidth * cutAngle))
                path.addLine(to: CGPoint(x: leftX + strokeWidth * cutAngle, y: topY))
                path.addLine(to: CGPoint(x: leftX + strokeWidth, y: topY))
                path.addLine(to: CGPoint(x: leftX + strokeWidth, y: bottomY))
                path.closeSubpath()

                // Top horizontal bar with dynamic width
                let topBarWidth = width * 0.85
                path.move(to: CGPoint(x: leftX, y: topY))
                path.addLine(to: CGPoint(x: leftX + topBarWidth, y: topY))
                path.addLine(to: CGPoint(x: leftX + topBarWidth - strokeWidth * cutAngle, y: topY + strokeWidth))
                path.addLine(to: CGPoint(x: leftX, y: topY + strokeWidth))
                path.closeSubpath()

                // Middle bar with angular cut
                let middleBarWidth = width * 0.55
                path.move(to: CGPoint(x: leftX, y: middleY))
                path.addLine(to: CGPoint(x: leftX + middleBarWidth, y: middleY))
                path.addLine(to: CGPoint(x: leftX + middleBarWidth - strokeWidth * cutAngle, y: middleY + strokeWidth))
                path.addLine(to: CGPoint(x: leftX, y: middleY + strokeWidth))
                path.closeSubpath()
            }

            context.fill(path, with: .color(self.color))

            // Add premium inner glow effect
            let glowPath = Path { path in
                let inset: CGFloat = 1
                let adjustedRect = workingRect.insetBy(dx: inset, dy: inset)
                let strokeWidth = max(1, size * 0.08)
                let width = adjustedRect.width
                let height = adjustedRect.height

                let leftX = adjustedRect.minX
                let topY = adjustedRect.minY
                let middleY = adjustedRect.minY + (height * 0.38)

                // Simplified inner elements for glow
                path.addRect(CGRect(x: leftX, y: topY, width: strokeWidth, height: height))
                path.addRect(CGRect(x: leftX, y: topY, width: width * 0.8, height: strokeWidth))
                path.addRect(CGRect(x: leftX, y: middleY, width: width * 0.5, height: strokeWidth))
            }

            context.fill(glowPath, with: .color(self.color.opacity(0.4)))
        }
        .frame(width: self.size, height: self.size)
    }
}

// Preview for development
#Preview("Fluid Icon Variants") {
    VStack(spacing: 20) {
        Text("Standard Geometric F")
            .font(.headline)

        HStack(spacing: 20) {
            FluidIcon(size: 24, color: .white)
                .background(Color.black.opacity(0.3))

            FluidIcon(size: 32, color: .blue)

            FluidIcon(size: 48, color: .primary)
        }

        Text("Advanced Angular F")
            .font(.headline)

        HStack(spacing: 20) {
            FluidIconAdvanced(size: 24, color: .white)
                .background(Color.black.opacity(0.3))

            FluidIconAdvanced(size: 32, color: .blue)

            FluidIconAdvanced(size: 48, color: .primary)
        }

        HStack(spacing: 20) {
            FluidIconFilled(size: 32, backgroundColor: .blue)
            FluidIconFilled(size: 40, backgroundColor: .purple)
            FluidIconFilled(size: 48, backgroundColor: .green)
        }

        // Large version for app icon
        FluidIconFilled(size: 80, backgroundColor: .black, cornerRadius: 16)
    }
    .padding()
    .background(Color.gray.opacity(0.1))
}
