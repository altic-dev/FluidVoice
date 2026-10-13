//
//  MinimalVisualizer.swift
//  Fluid
//
//  Minimal style: a restrained monochrome dot matrix.
//

import SwiftUI

/// Shared geometry for the Minimal dot row.
///
/// The live visualizer and the Settings miniature both read their dot count,
/// radius bounds and taper from here, so the picture shown in Settings can
/// never drift away from what the overlay actually draws.
enum MinimalDotGeometry {
    static let dotCount = 9
    static let minimumRadius: CGFloat = 1.1
    static let maximumRadius: CGFloat = 3.4
    /// How strongly the ends of the row are damped relative to the centre.
    static let endTaperScale: CGFloat = 0.45
    static let minimumTaper: CGFloat = 0.35

    /// Fewest dots worth drawing, used by the smallest canvases.
    static let minimumDotCount = 5
    /// Roughly how much width one dot plus its gap needs.
    private static let preferredDotPitch: CGFloat = 5.6

    /// Dots that suit a canvas of the given width.
    ///
    /// The row stays the same graphic in every format; only its density adapts,
    /// so the circular orb gets a few calm dots instead of nine cramped ones.
    static func dotCount(forWidth width: CGFloat) -> Int {
        guard width > 0 else { return MinimalDotGeometry.dotCount }
        let fitted = Int((width / MinimalDotGeometry.preferredDotPitch).rounded(.down))
        return min(max(fitted, MinimalDotGeometry.minimumDotCount), MinimalDotGeometry.dotCount)
    }

    /// 0 ... 1 weight that softens the outer dots.
    static func taper(at index: Int, count: Int = MinimalDotGeometry.dotCount) -> CGFloat {
        let centerDistance = abs(CGFloat(index) - CGFloat(count - 1) / 2)
        let maxDistance = max(CGFloat(count - 1) / 2, 1)
        return max(MinimalDotGeometry.minimumTaper, 1 - (centerDistance / maxDistance) * MinimalDotGeometry.endTaperScale)
    }

    /// Dot radius for a 0 ... 1 energy sample.
    static func radius(energy: CGFloat, at index: Int, count: Int = MinimalDotGeometry.dotCount) -> CGFloat {
        let tapered = min(max(energy * MinimalDotGeometry.taper(at: index, count: count), 0), 1)
        return MinimalDotGeometry.minimumRadius
            + (MinimalDotGeometry.maximumRadius - MinimalDotGeometry.minimumRadius) * tapered
    }

    /// Static stand-in envelope used by the Settings miniature: a calm hump, as
    /// when the user is speaking at a normal level.
    static let previewEnergies: [CGFloat] = (0..<MinimalDotGeometry.dotCount).map { index in
        let t = CGFloat(index) / max(CGFloat(MinimalDotGeometry.dotCount - 1), 1)
        return 0.32 + 0.62 * sin(t * CGFloat.pi)
    }

    /// Radii the miniature draws, derived from the same formula as the live row.
    static var previewRadii: [CGFloat] {
        MinimalDotGeometry.previewEnergies.enumerated().map { index, energy in
            MinimalDotGeometry.radius(energy: energy, at: index)
        }
    }
}

/// The most sober style: a horizontal row of small dots, as drawn in the
/// reference concept sheet.
///
/// It deliberately avoids blur filters and timelines so the graphic cost stays
/// at the floor while the overlay is on screen. The dots never disappear - they
/// shrink to a quiet baseline instead, so the pill still reads as alive.
struct MinimalVisualizer: View {
    let level: CGFloat
    let isActive: Bool
    let palette: OverlayPalette
    /// Drives the optional soft halo. Subtle stays completely filter-free.
    let glow: OverlayGlowIntensity
    let noiseThreshold: CGFloat
    /// Surface the dots sit on. The neutral dot colour has to follow it or the
    /// monochrome row disappears on a light surface.
    var surface: OverlaySurfaceStyle

    @State private var follower: AudioEnvelopeFollower

    /// Optional seeded energy for offscreen previews and tests. Production call
    /// sites never pass it, so the live path is unchanged: at runtime the
    /// follower is fed by the microphone level the engine already publishes.
    init(
        level: CGFloat,
        isActive: Bool,
        palette: OverlayPalette,
        glow: OverlayGlowIntensity,
        noiseThreshold: CGFloat,
        surface: OverlaySurfaceStyle = .dark,
        previewLevel: CGFloat? = nil
    ) {
        self.level = level
        self.isActive = isActive
        self.palette = palette
        self.glow = glow
        self.noiseThreshold = noiseThreshold
        self.surface = surface
        self._follower = State(
            initialValue: previewLevel.map(AudioEnvelopeFollower.preview) ?? AudioEnvelopeFollower()
        )
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let count = MinimalDotGeometry.dotCount(forWidth: size.width)

            // A soft halo only at the stronger glow presets. It keeps the row
            // luminous like the reference sheet without paying for a blur at
            // Subtle, where the style is meant to be at its cheapest.
            if self.glow != .subtle {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 2.2 * CGFloat(self.glow.visualizerGlowScale)))
                    layer.opacity = 0.55 * self.glow.visualizerGlowScale
                    self.drawDots(into: &layer, size: size, count: count)
                }
            }

            self.drawDots(into: &context, size: size, count: count)
        }
        .onChange(of: self.level) { _, newLevel in
            self.follower.update(
                with: AudioEnvelopeFollower.normalized(newLevel, noiseThreshold: self.noiseThreshold)
            )
        }
        .onChange(of: self.isActive) { _, active in
            guard !active else { return }
            self.follower.reset()
        }
    }

    private func drawDots(into context: inout GraphicsContext, size: CGSize, count: Int) {
        for index in 0..<count {
            let radius = self.dotRadius(at: index, count: count)
            let center = self.dotCenter(at: index, count: count, in: size)
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(self.dotColor))
        }
    }

    /// The dots are drawn in the theme's own hue rather than a monochrome
    /// neutral, as in the reference sheet. On a light surface the brightest hue
    /// would wash out, so the deeper `primary` is used instead.
    private var dotColor: Color {
        self.surface.isLight ? self.palette.primary : self.palette.tertiary
    }

    private func dotCenter(at index: Int, count: Int, in size: CGSize) -> CGPoint {
        let slot = size.width / CGFloat(max(count, 1))
        return CGPoint(x: slot * (CGFloat(index) + 0.5), y: size.height / 2)
    }

    private func dotRadius(at index: Int, count: Int) -> CGFloat {
        MinimalDotGeometry.radius(energy: self.dotEnergy(at: index, count: count), at: index, count: count)
    }

    /// Reads the shared delay line so the dots ripple with the voice instead of
    /// flickering. The taper towards the ends of the row lives in
    /// `MinimalDotGeometry` so the Settings miniature shares it.
    private func dotEnergy(at index: Int, count: Int) -> CGFloat {
        let historySpan = max(AudioEnvelopeFollower.historyLength - 1, 1)
        let step = max(count - 1, 1)
        let sample = self.follower.delayedSample(at: index * historySpan / step)
        return min(max(sample, 0), 1)
    }
}
