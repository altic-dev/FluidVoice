//
//  OverlayStyleThumbnail.swift
//  Fluid
//
//  Static miniature used by the Overlay settings style picker.
//

import SwiftUI

/// Frozen preview of a style so the settings picker reads at a glance.
///
/// Everything here is static: no audio subscription, no timeline and no state,
/// so a grid of four thumbnails costs nothing while Settings is open.
struct OverlayStyleThumbnail: View {
    let style: OverlayVisualStyle
    let palette: OverlayPalette
    let glow: OverlayGlowIntensity
    /// Surface the miniature is drawn on, so the card matches the real overlay.
    var surface: OverlaySurfaceStyle = .dark

    static let size = CGSize(width: 76, height: 34)

    /// Smooth hump used as a stand-in envelope for the Aurora ribbon.
    private static let auroraSamples: [CGFloat] = (0..<AudioEnvelopeFollower.historyLength).map { index in
        let t = CGFloat(index) / CGFloat(max(AudioEnvelopeFollower.historyLength - 1, 1))
        return 0.30 + 0.62 * sin(t * CGFloat.pi)
    }

    /// Bell shaped bar heights shared by the Wave preview.
    private static let waveHeights: [CGFloat] = [0.20, 0.42, 0.72, 0.95, 0.66, 0.86, 0.38, 0.22]

    /// Dot radii for the Minimal preview, taken from the same shared geometry
    /// the live `MinimalVisualizer` draws with, so the miniature cannot drift
    /// away from the real render.
    private static var minimalDotRadii: [CGFloat] { MinimalDotGeometry.previewRadii }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(self.surface.fill)

            self.content
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    self.palette.secondary.opacity(0.30 + 0.20 * self.glow.visualizerGlowScale),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    private var content: some View {
        switch self.style {
        case .minimal:
            self.dots(radii: Self.minimalDotRadii)
                .padding(.horizontal, 14)
        case .wave:
            // Same bar width and spacing as the pill's Wave layout constants.
            self.bars(heights: Self.waveHeights, width: 3, spacing: 2.5)
        case .aurora:
            // The real multilayer composition, frozen at one phase. Rendering the
            // production stack here means the miniature can never show a different
            // graphic from the one the overlay draws.
            AuroraComposition(
                palette: self.palette,
                glow: self.glow,
                samples: Self.auroraSamples,
                level: 0.6,
                phase: 0.9,
                showsBloom: false
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        case .companion:
            // Static Companion: frozen phase, no timeline, so a grid of cards
            // stays free while Settings is open.
            CompanionVisualizer(
                state: .listening,
                variant: .standard,
                themePalette: self.palette,
                glow: self.glow,
                accessories: [],
                level: 0.6,
                isActive: false,
                reduceMotion: true,
                motion: .normal,
                previewPhase: 1.2
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        case .pulse:
            ZStack {
                Circle()
                    .strokeBorder(self.palette.secondary.opacity(0.45), lineWidth: 1)
                    .frame(width: 22, height: 22)
                Circle()
                    .strokeBorder(self.palette.horizontalGradient, lineWidth: 1.4)
                    .frame(width: 13, height: 13)
                Circle()
                    .fill(self.palette.primary.opacity(0.9))
                    .frame(width: 4, height: 4)
            }
        }
    }

    /// Minimal preview: the same nine dot row as the live visualizer, rendered
    /// statically so Settings never starts an animation.
    private func dots(radii: [CGFloat]) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let neutral = GraphicsContext.Shading.color(self.surface.primaryText)
            let tint = GraphicsContext.Shading.color(self.palette.primary.opacity(0.20))
            let slot = size.width / CGFloat(max(radii.count, 1))
            for (index, radius) in radii.enumerated() {
                let center = CGPoint(x: slot * (CGFloat(index) + 0.5), y: size.height / 2)
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(Path(ellipseIn: rect), with: neutral)
                context.fill(Path(ellipseIn: rect), with: tint)
            }
        }
    }

    /// Themed bar row, shared by the Wave preview.
    private func bars(heights: [CGFloat], width: CGFloat, spacing: CGFloat) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let fill: GraphicsContext.Shading = .linearGradient(
                Gradient(colors: self.palette.gradientColors),
                startPoint: CGPoint(x: 0, y: size.height),
                endPoint: CGPoint(x: 0, y: 0)
            )
            let totalWidth = CGFloat(heights.count) * width + CGFloat(max(heights.count - 1, 0)) * spacing
            let originX = (size.width - totalWidth) / 2
            for (index, value) in heights.enumerated() {
                let barHeight = max(2, size.height * 0.78 * value)
                let rect = CGRect(
                    x: originX + CGFloat(index) * (width + spacing),
                    y: size.height / 2 - barHeight / 2,
                    width: width,
                    height: barHeight
                )
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: fill)
            }
        }
    }
}
