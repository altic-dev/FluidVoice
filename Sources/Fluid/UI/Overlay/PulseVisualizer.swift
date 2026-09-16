//
//  PulseVisualizer.swift
//  Fluid
//
//  Pulse style: a calm ring that breathes with the voice, wrapped in a slow
//  circular Aurora wave.
//

import SwiftUI

/// Circular level indicator.
///
/// Two ideas stacked: the breathing ring Pulse always had, and a thin wavy ring
/// that turns around it like a small circular Aurora. Both follow the damped
/// envelope, and the wave is drawn with the theme spectrum and rotated by its
/// own phase, so it genuinely changes colour as it travels.
struct PulseVisualizer: View {
    let level: CGFloat
    let isActive: Bool
    let palette: OverlayPalette
    let glow: OverlayGlowIntensity
    let noiseThreshold: CGFloat
    let reduceMotion: Bool

    @State private var follower: AudioEnvelopeFollower

    /// Seeded energy for offscreen previews and tests. Inert at runtime.
    init(
        level: CGFloat,
        isActive: Bool,
        palette: OverlayPalette,
        glow: OverlayGlowIntensity,
        noiseThreshold: CGFloat,
        reduceMotion: Bool = false,
        previewLevel: CGFloat? = nil
    ) {
        self.level = level
        self.isActive = isActive
        self.palette = palette
        self.glow = glow
        self.noiseThreshold = noiseThreshold
        self.reduceMotion = reduceMotion
        self._follower = State(
            initialValue: previewLevel.map(AudioEnvelopeFollower.preview) ?? AudioEnvelopeFollower()
        )
    }

    private var energy: CGFloat {
        min(max(self.follower.smoothed, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let energy = self.energy
            let glowScale = CGFloat(self.glow.visualizerGlowScale)
            // Every dimension is a fraction of the shortest side, so the style
            // fits the pill, the orb and the chromeless canvas alike.
            let unit = max(min(proxy.size.width, proxy.size.height), 8)

            ZStack {
                self.rings(unit: unit, energy: energy, glowScale: glowScale)
                self.wave(unit: unit, energy: energy, glowScale: glowScale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.easeOut(duration: 0.18), value: self.energy)
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

    // MARK: - Breathing rings

    @ViewBuilder
    private func rings(unit: CGFloat, energy: CGFloat, glowScale: CGFloat) -> some View {
        ZStack {
            // Outer diffuse layer: the ring's light bleeding into the surface.
            Circle()
                .strokeBorder(
                    self.palette.secondary.opacity(0.14 + 0.30 * Double(energy)),
                    lineWidth: unit * (0.05 + 0.07 * energy)
                )
                .frame(width: unit * (0.74 + 0.42 * energy), height: unit * (0.74 + 0.42 * energy))
                .blur(radius: max(3.0 * glowScale, 0.6))

            // Sharp core.
            Circle()
                .strokeBorder(
                    self.palette.horizontalGradient,
                    lineWidth: unit * (0.045 + 0.05 * energy)
                )
                .frame(width: unit * (0.46 + 0.30 * energy), height: unit * (0.46 + 0.30 * energy))
                .shadow(
                    color: self.palette.tertiary.opacity(0.18 + 0.34 * Double(energy)),
                    radius: 3 * glowScale
                )

            // One localised highlight, lit from one side.
            Circle()
                .trim(from: 0.04, to: 0.28)
                .stroke(
                    self.palette.highlight.opacity(0.30 + 0.50 * Double(energy)),
                    style: StrokeStyle(lineWidth: unit * (0.06 + 0.05 * energy), lineCap: .round)
                )
                .frame(width: unit * (0.46 + 0.30 * energy), height: unit * (0.46 + 0.30 * energy))
                .rotationEffect(.degrees(-118))

            // Null point.
            Circle()
                .fill(self.palette.primary.opacity(0.85))
                .frame(
                    width: max(unit * (0.13 + 0.11 * energy), 2.5),
                    height: max(unit * (0.13 + 0.11 * energy), 2.5)
                )
        }
    }

    // MARK: - Circular Aurora wave

    @ViewBuilder
    private func wave(unit: CGFloat, energy: CGFloat, glowScale: CGFloat) -> some View {
        if self.reduceMotion {
            // Reduce Motion: keep the coloured wave, drop the travel.
            self.waveRing(unit: unit, energy: energy, glowScale: glowScale, phase: 0.8)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !self.isActive)) { timeline in
                self.waveRing(
                    unit: unit,
                    energy: energy,
                    glowScale: glowScale,
                    phase: Self.phase(for: timeline.date)
                )
            }
        }
    }

    /// A closed wave that travels around the ring.
    ///
    /// The whole layer is rotated by the phase as well, so the spectrum colours
    /// travel with the wave: that is what makes the ring change colour instead of
    /// merely changing shape.
    private func waveRing(unit: CGFloat, energy: CGFloat, glowScale: CGFloat, phase: CGFloat) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseRadius = unit * (0.40 + 0.05 * energy)
            let amplitude = baseRadius * (0.035 + 0.075 * energy)
            let steps = 84
            var path = Path()
            for step in 0...steps {
                let theta = CGFloat(step) / CGFloat(steps) * 2 * .pi
                let radius = baseRadius
                    + amplitude * sin(3 * theta + phase)
                    + amplitude * 0.55 * sin(5 * theta - phase * 0.7)
                let point = CGPoint(
                    x: center.x + cos(theta) * radius,
                    y: center.y + sin(theta) * radius
                )
                if step == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()

            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: self.palette.spectrumColors),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: size.width, y: size.height)
            )
            let lineWidth = max(unit * (0.028 + 0.022 * energy), 0.8)

            if self.glow != .subtle {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 3.0 * glowScale))
                    layer.opacity = 0.55 * glowScale
                    layer.stroke(path, with: shading, lineWidth: lineWidth * 2.2)
                }
            }
            context.stroke(path, with: shading, lineWidth: lineWidth)
        }
        .rotationEffect(.degrees(Double(phase) * 26))
        .allowsHitTesting(false)
    }

    private static func phase(for date: Date) -> CGFloat {
        let seconds = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 120)
        return CGFloat(seconds) * 0.9
    }
}
