//
//  WaveVisualizer.swift
//  Fluid
//
//  Wave style: symmetric bars around the center line, fed by the delay line.
//

import SwiftUI

/// Vertical bars mirrored around the center line.
///
/// Bar heights are read from the shared delay line instead of an independent
/// random source, so the waveform is genuinely correlated with the microphone
/// level, stays smooth and never jitters.
///
/// Each bar takes its colour from the theme's ordered spectrum, so the Aurora
/// theme shows cyan - blue - violet - magenta - warm across the row instead of
/// collapsing into Blue.
struct WaveVisualizer: View {
    let level: CGFloat
    let isActive: Bool
    let palette: OverlayPalette
    let glow: OverlayGlowIntensity
    let noiseThreshold: CGFloat
    let barCount: Int
    let barWidth: CGFloat
    let barSpacing: CGFloat

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
        barCount: Int,
        barWidth: CGFloat,
        barSpacing: CGFloat,
        previewLevel: CGFloat? = nil
    ) {
        self.level = level
        self.isActive = isActive
        self.palette = palette
        self.glow = glow
        self.noiseThreshold = noiseThreshold
        self.barCount = barCount
        self.barWidth = barWidth
        self.barSpacing = barSpacing
        self._follower = State(
            initialValue: previewLevel.map(AudioEnvelopeFollower.preview) ?? AudioEnvelopeFollower()
        )
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            if self.glow != .subtle {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 2.6 * CGFloat(self.glow.visualizerGlowScale)))
                    layer.opacity = 0.5 * self.glow.visualizerGlowScale
                    self.drawBars(into: &layer, size: size)
                }
            }

            self.drawBars(into: &context, size: size)
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

    private func drawBars(into context: inout GraphicsContext, size: CGSize) {
        // Light from above: the top of the canvas is brighter than the bottom, so
        // each bar keeps some vertical relief even though its colour is flat.
        let sheen = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.0)]),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: 0, y: size.height)
        )
        for index in 0..<self.barCount {
            let rect = self.barRect(at: index, in: size)
            let path = Path(roundedRect: rect, cornerRadius: rect.width / 2)
            let fraction = self.barCount > 1 ? CGFloat(index) / CGFloat(self.barCount - 1) : 0.5
            context.fill(path, with: .color(self.palette.spectrumColor(at: fraction)))
            context.fill(path, with: sheen)
        }
    }

    private func barRect(at index: Int, in size: CGSize) -> CGRect {
        let totalWidth = CGFloat(self.barCount) * self.barWidth
            + CGFloat(max(self.barCount - 1, 0)) * self.barSpacing
        let originX = (size.width - totalWidth) / 2 + CGFloat(index) * (self.barWidth + self.barSpacing)
        let minimumHeight: CGFloat = 2
        let availableHeight = max(size.height - minimumHeight, 0)
        let energy = self.barEnergy(at: index)
        let height = minimumHeight + availableHeight * energy
        return CGRect(
            x: originX,
            y: size.height / 2 - height / 2,
            width: self.barWidth,
            height: height
        )
    }

    private func barEnergy(at index: Int) -> CGFloat {
        let historySpan = max(AudioEnvelopeFollower.historyLength - 1, 1)
        let step = max(self.barCount - 1, 1)
        let offset = index * historySpan / step
        let sample = self.follower.delayedSample(at: offset)

        // Lift quiet and normal speech so a change in volume is unmistakable,
        // while leaving the top of the range uncompressed so loud speech still
        // reads clearly taller than normal speech.
        let boosted = pow(min(max(sample, 0), 1), 0.74)

        let centerDistance = abs(CGFloat(index) - CGFloat(self.barCount - 1) / 2)
        let maxDistance = max(CGFloat(self.barCount - 1) / 2, 1)
        let normalized = min(centerDistance / maxDistance, 1)
        // A shallower taper than before: the outer bars stay part of the row
        // instead of shrinking into it.
        let taper = max(0.38, 1.0 - normalized * 0.56)
        let variation = 0.92 + 0.08 * cos(CGFloat(index) * 1.45)
        return min(max(boosted * taper * variation, 0), 1)
    }
}
