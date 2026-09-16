//
//  AuroraVisualizer.swift
//  Fluid
//
//  Aurora style: a living multilayer mass of light driven by the live microphone
//  level. Three translucent layers share one construction but never one motion.
//

import SwiftUI

/// One translucent layer of the Aurora mass.
///
/// Every layer is built the same way - a soft window, drifting lobes and an
/// audio-driven thickness - but each gets its own phase, direction, width,
/// height, vertical centre, palette and envelope channel. That is what makes the
/// composition read as one body of light WITH DEPTH instead of three copies of
/// the same outline nudged a few points apart, which is the thing that looks
/// artificial.
struct AuroraLayerSpec: Equatable {
    /// Outline resolution. Well above the envelope history so lobes read as
    /// curves, and still trivial for the CPU at 30 FPS.
    static let steps = 40

    /// Added to the global phase so the layers never move in lockstep.
    var phaseOffset: CGFloat
    /// Multiplier on the global phase: >1 is faster, <1 is slower.
    var speed: CGFloat
    /// Direction of the lobe drift. The accent layer drifts against the mass.
    var driftDirection: CGFloat
    /// Fraction of the canvas width the layer spans.
    var widthScale: CGFloat
    /// Fraction of the canvas height the layer's envelope spans.
    var heightScale: CGFloat
    /// Multiplies the thickness profile.
    var thicknessScale: CGFloat
    /// Vertical centre of the layer, as a fraction of the canvas height.
    var verticalOffset: CGFloat
    /// How far the lobe centres may wander, as a fraction of the width.
    var lobeDrift: CGFloat
    /// Base centre, width and weight of each Gaussian lobe.
    var lobeCenters: [CGFloat]
    var lobeWidths: [CGFloat]
    var lobeWeights: [CGFloat]
    /// Symmetric vertical bow of the centreline, as a fraction of layer height.
    /// Zero at both ends, maximum in the middle: the opposite of a global slope,
    /// so the composition never looks tilted.
    var bowAmount: CGFloat
    /// Zero-mean weave of the centreline along the layer, as a fraction of the
    /// layer height. This is what makes the band travel up and down around a
    /// horizontal axis - the __/\____ read - instead of drawing one flat lens.
    var weaveAmount: CGFloat
    /// Roughly how many times the centreline crosses its axis. Each layer picks a
    /// different count so the three never collapse into one thick sine wave.
    var weaveFrequency: CGFloat
    /// 0 = follow the smoothed level, 1 = follow the delayed history.
    var historyMix: CGFloat
    /// Fraction of the layer height that survives in silence.
    var idleAmplitude: CGFloat
}

extension AuroraLayerSpec {
    /// Layer A - atmosphere. Wide, cool, slow and highly transparent. It gives
    /// the mass depth and is allowed to grow more on one side than the other.
    static let atmosphere = AuroraLayerSpec(
        phaseOffset: 0.0,
        speed: 0.34,
        driftDirection: 1,
        widthScale: 1.06,
        heightScale: 1.00,
        thicknessScale: 0.78,
        verticalOffset: -0.14,
        lobeDrift: 0.058,
        lobeCenters: [0.18, 0.50, 0.82],
        lobeWidths: [0.20, 0.15, 0.18],
        lobeWeights: [0.70, 0.95, 0.62],
        bowAmount: 0.10,
        weaveAmount: 0.40,
        weaveFrequency: 1.35,
        historyMix: 0.22,
        idleAmplitude: 0.38
    )

    /// Layer B - the voice body. Brightest, organic, and the layer that follows
    /// the microphone level most directly.
    static let mass = AuroraLayerSpec(
        phaseOffset: 1.7,
        speed: 1.0,
        driftDirection: 1,
        widthScale: 1.0,
        heightScale: 1.00,
        thicknessScale: 1.20,
        verticalOffset: 0.0,
        lobeDrift: 0.05,
        lobeCenters: [0.25, 0.52, 0.79],
        lobeWidths: [0.105, 0.095, 0.11],
        lobeWeights: [0.88, 1.0, 0.82],
        bowAmount: 0.0,
        weaveAmount: 0.22,
        weaveFrequency: 2.15,
        historyMix: 0.72,
        idleAmplitude: 0.44
    )

    /// Layer C - the accent. Thin, offset, drifting the other way. It reveals the
    /// depth of the motion; it is never a progress line.
    static let accent = AuroraLayerSpec(
        phaseOffset: 3.4,
        speed: 1.38,
        driftDirection: -1,
        widthScale: 0.88,
        heightScale: 0.70,
        thicknessScale: 0.58,
        verticalOffset: 0.15,
        lobeDrift: 0.072,
        lobeCenters: [0.28, 0.55, 0.76],
        lobeWidths: [0.09, 0.07, 0.10],
        lobeWeights: [0.75, 1.0, 0.68],
        bowAmount: 0.12,
        weaveAmount: 0.55,
        weaveFrequency: 3.10,
        historyMix: 0.90,
        idleAmplitude: 0.26
    )
}

/// Pure geometry for one Aurora layer at one phase.
///
/// Everything is a function of the samples and the phase, so the shape only ever
/// moves because the voice or the slow drift moved. No random source anywhere.
struct AuroraLayerGeometry {
    let rect: CGRect
    let spec: AuroraLayerSpec
    let samples: [CGFloat]
    let level: CGFloat
    let phase: CGFloat
    /// Global movement budget. Multiplies displacement only, never the voice.
    var motion: CGFloat = 1

    func upperPoint(at step: Int) -> CGPoint {
        let frame = self.frame(at: step)
        return CGPoint(x: frame.x, y: frame.y - frame.upper)
    }

    func lowerPoint(at step: Int) -> CGPoint {
        let frame = self.frame(at: step)
        return CGPoint(x: frame.x, y: frame.y + frame.lower)
    }

    /// Horizontal centre of each lobe, used by the localised bloom.
    func lobeCenters() -> [CGFloat] {
        let drift = self.spec.lobeDrift * self.spec.driftDirection * self.motion
        let phase = self.phase * self.spec.speed
        return self.spec.lobeCenters.enumerated().map { index, base in
            let offset = drift * sin(
                phase * (0.30 + 0.06 * CGFloat(index))
                    + self.spec.phaseOffset
                    + CGFloat(index) * 1.9
            )
            return min(max(base + offset, 0.06), 0.94)
        }
    }

    private func layerRect() -> CGRect {
        let width = self.rect.width * self.spec.widthScale
        let height = self.rect.height * self.spec.heightScale
        return CGRect(
            x: self.rect.midX - width / 2,
            y: self.rect.midY + self.rect.height * self.spec.verticalOffset - height / 2,
            width: width,
            height: height
        )
    }

    private func frame(at step: Int) -> (x: CGFloat, y: CGFloat, upper: CGFloat, lower: CGFloat) {
        let t = CGFloat(step) / CGFloat(max(AuroraLayerSpec.steps - 1, 1))
        let layer = self.layerRect()
        let halfHeight = layer.height / 2

        // Blunt-ended window. A window that reaches zero pinches the outline into
        // the two points of a lens, which is exactly the wavy-line read we are
        // moving away from; keeping a floor makes the silhouette a rounded mass.
        let window = 0.42 + 0.58 * pow(sin(t * CGFloat.pi), 0.55)

        let lobes = self.lobeProfile(at: t)

        // Newest speech sits at the head of the shape, older samples trail away.
        let delayed = self.sample(t: t)
        let voice = self.level * (1 - self.spec.historyMix) + delayed * self.spec.historyMix
        let energy = min(max(voice * 1.12, 0), 1)

        // Idle keeps a recognisable silhouette at a whisper; the lobes then vary
        // the thickness instead of flattening it. The lobe term stays deep so the
        // outline keeps visible valleys rather than one convex blob.
        let thickness = halfHeight * self.spec.thicknessScale
            * window
            * (self.spec.idleAmplitude + (1 - self.spec.idleAmplitude) * energy)
            * (0.55 + 0.45 * lobes)

        // A symmetric bow keeps the centre of the mass exactly where it is, so
        // the composition can never look globally tilted: it is zero at both ends
        // and at its strongest in the middle, the opposite of a global slope.
        let bow = self.spec.bowAmount * halfHeight * self.motion * sin(t * CGFloat.pi)
            * sin(self.phase * self.spec.speed * 0.55 + self.spec.phaseOffset)

        // Zero-mean weave: the band travels above and below its centreline, so it
        // reads as a ribbon crossing a horizontal axis rather than as one globally
        // sloped line. The accent layer weaves the other way on purpose.
        let weavePhase = self.phase * self.spec.speed
        let weave = (self.spec.weaveAmount / 1.45) * halfHeight * self.motion * self.spec.driftDirection * (
            sin(t * CGFloat.pi * self.spec.weaveFrequency + weavePhase * 0.8 + self.spec.phaseOffset)
                + 0.45 * sin(
                    t * CGFloat.pi * self.spec.weaveFrequency * 2.37
                        + weavePhase * 0.5
                        + self.spec.phaseOffset * 1.7
                )
        )

        // A small, slowly reversing lean. Enough for the mass to feel alive,
        // never enough for one side of the outline to read as heavier.
        let lean = 0.5 + 0.06 * sin(
            self.phase * self.spec.speed * 0.43 + t * 2.4 + self.spec.phaseOffset
        )

        return (
            x: layer.minX + layer.width * t,
            y: layer.midY + bow + weave,
            upper: thickness * lean,
            lower: thickness * (1 - lean)
        )
    }

    /// Sum of the Gaussian lobes, clamped to 0 ... 1.
    private func lobeProfile(at t: CGFloat) -> CGFloat {
        let centers = self.lobeCenters()
        var total: CGFloat = 0
        for index in 0..<centers.count {
            let distance = (t - centers[index]) / self.spec.lobeWidths[index]
            total += self.spec.lobeWeights[index] * exp(-distance * distance)
        }
        return min(max(total, 0), 1)
    }

    /// Envelope value at t, linearly interpolated across the history so the
    /// shape has no visible sample steps.
    private func sample(t: CGFloat) -> CGFloat {
        guard self.samples.count > 1 else { return self.level }
        let position = t * CGFloat(self.samples.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, self.samples.count - 1)
        let fraction = position - CGFloat(lower)
        let start = self.samples[max(lower, 0)]
        let end = self.samples[upper]
        return start + (end - start) * fraction
    }
}

/// One closed organic layer, drawn from AuroraLayerGeometry.
struct AuroraLayerShape: Shape {
    var spec: AuroraLayerSpec
    var samples: [CGFloat]
    var level: CGFloat
    var phase: CGFloat
    var motion: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        let geometry = AuroraLayerGeometry(
            rect: rect,
            spec: self.spec,
            samples: self.samples,
            level: self.level,
            phase: self.phase,
            motion: self.motion
        )
        let steps = AuroraLayerSpec.steps
        var path = Path()
        var previous: CGPoint?

        for step in 0..<steps {
            let point = geometry.upperPoint(at: step)
            if let previous {
                path.addQuadCurve(to: Self.midpoint(previous, point), control: previous)
            } else {
                path.move(to: point)
            }
            previous = point
        }
        if let previous {
            path.addLine(to: previous)
        }

        previous = nil
        for step in stride(from: steps - 1, through: 0, by: -1) {
            let point = geometry.lowerPoint(at: step)
            if let previous {
                path.addQuadCurve(to: Self.midpoint(previous, point), control: previous)
            } else {
                path.addLine(to: point)
            }
            previous = point
        }
        path.closeSubpath()
        return path
    }

    private static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }
}

/// The full Aurora composition for one phase.
///
/// Split out of AuroraVisualizer so the Settings miniature can render exactly the
/// same stack - no timeline, no audio - and therefore cannot drift away from what
/// the overlay actually draws.
struct AuroraComposition: View {
    let palette: OverlayPalette
    let glow: OverlayGlowIntensity
    let samples: [CGFloat]
    let level: CGFloat
    let phase: CGFloat
    /// Global movement budget. Multiplies displacement only, never the voice.
    var motion: CGFloat = 1
    /// The bloom is skipped by the static Settings miniature, where it would be
    /// pure cost on a 76 x 34 card.
    var showsBloom: Bool = true

    var body: some View {
        let energy = min(max(self.level, 0), 1)
        let glowScale = CGFloat(self.glow.visualizerGlowScale)
        let bloom = min(0.60 * self.glow.visualizerGlowScale, 0.85)

        ZStack {
            // Layer A - atmosphere. A cool, wide ribbon above the mass, seen
            // through it rather than painted behind it.
            AuroraLayerShape(spec: .atmosphere, samples: self.samples, level: energy, phase: self.phase, motion: self.motion)
                .fill(self.palette.atmosphereGradient)
                .blur(radius: max(2.6 * glowScale, 0.4))
                .opacity(0.34 + 0.24 * Double(energy))

            // Layer B - soft bloom of the voice body.
            AuroraLayerShape(spec: .mass, samples: self.samples, level: energy, phase: self.phase, motion: self.motion)
                .fill(self.palette.ribbonGradient)
                .blur(radius: max(2.2 * glowScale, 0.3))
                .opacity(0.30 + 0.28 * Double(energy))

            // Layer B - the mass itself. Held a little under full opacity so the
            // cool atmosphere still shows through it: that overlap is what reads
            // as translucent layers rather than one painted band.
            AuroraLayerShape(spec: .mass, samples: self.samples, level: energy, phase: self.phase, motion: self.motion)
                .fill(self.palette.ribbonGradient)
                .opacity(0.86)

            // Brighter core, so the middle reads as a light source rather than a
            // uniformly filled band.
            AuroraLayerShape(spec: .mass, samples: self.samples, level: energy, phase: self.phase, motion: self.motion)
                .fill(Color.white.opacity(0.16))
                .scaleEffect(y: 0.56)
                .blur(radius: 1.5)
                .opacity(0.26 + 0.58 * Double(energy))

            // Layer C - thin warm accent below the mass, drifting against it.
            AuroraLayerShape(spec: .accent, samples: self.samples, level: energy, phase: self.phase, motion: self.motion)
                .fill(self.palette.accentLayerGradient)
                .blur(radius: 1.0)
                .opacity(0.38 + 0.45 * Double(energy))

            if self.showsBloom {
                self.lobeBloom(phase: self.phase, energy: energy, opacity: bloom)
            }
        }
    }

    /// Localised light where the lobes are - not a uniform halo around
    /// everything. Without it the glow follows the whole silhouette equally,
    /// which is the flat look the reference sheet avoids.
    private func lobeBloom(phase: CGFloat, energy: CGFloat, opacity: Double) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard opacity > 0.001, size.width > 1, size.height > 1 else { return }
            let geometry = AuroraLayerGeometry(
                rect: CGRect(origin: .zero, size: size),
                spec: .mass,
                samples: [],
                level: energy,
                phase: phase
            )
            let centers = geometry.lobeCenters()
            let radius = max(size.width * 0.22, 6)
            for index in centers.indices {
                let weight = AuroraLayerSpec.mass.lobeWeights[index]
                let alpha = min(opacity * Double(weight) * (0.35 + 0.65 * Double(energy)), 0.80)
                guard alpha > 0.005 else { continue }
                let center = CGPoint(x: centers[index] * size.width, y: size.height / 2)
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                let shading = GraphicsContext.Shading.radialGradient(
                    Gradient(colors: [
                        self.palette.highlight.opacity(alpha),
                        self.palette.highlight.opacity(0),
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                )
                context.fill(Path(ellipseIn: rect), with: shading)
            }
        }
        .blur(radius: 3.0)
        .allowsHitTesting(false)
    }
}

/// Aurora visualizer: a soft multilayer mass of light with a brighter core and a
/// warm ember at its head.
struct AuroraVisualizer: View {
    let level: CGFloat
    let isActive: Bool
    let palette: OverlayPalette
    let glow: OverlayGlowIntensity
    let reduceMotion: Bool
    let noiseThreshold: CGFloat
    /// Global movement budget from Settings.
    let motion: MotionIntensity

    @State private var follower: AudioEnvelopeFollower

    /// Optional seeded energy for offscreen previews and tests. Production call
    /// sites never pass it, so the live path is unchanged: at runtime the
    /// follower is fed by the microphone level the engine already publishes.
    init(
        level: CGFloat,
        isActive: Bool,
        palette: OverlayPalette,
        glow: OverlayGlowIntensity,
        reduceMotion: Bool,
        noiseThreshold: CGFloat,
        motion: MotionIntensity = .normal,
        previewLevel: CGFloat? = nil
    ) {
        self.level = level
        self.isActive = isActive
        self.palette = palette
        self.glow = glow
        self.reduceMotion = reduceMotion
        self.noiseThreshold = noiseThreshold
        self.motion = motion
        self._follower = State(
            initialValue: previewLevel.map(AudioEnvelopeFollower.preview) ?? AudioEnvelopeFollower()
        )
    }

    var body: some View {
        Group {
            if self.reduceMotion {
                // Reduce Motion: keep the gradient and the audio response, drop
                // the continuous drift entirely.
                AuroraComposition(
                    palette: self.palette,
                    glow: self.glow,
                    samples: self.follower.history,
                    level: self.follower.smoothed,
                    phase: 0.8,
                    motion: self.motion.scale
                )
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !self.isActive)) { timeline in
                    AuroraComposition(
                        palette: self.palette,
                        glow: self.glow,
                        samples: self.follower.history,
                        level: self.follower.smoothed,
                        phase: Self.phase(for: timeline.date),
                        motion: self.motion.scale
                    )
                }
            }
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

    /// Slow drift so the mass never looks like a static graphic. It is far
    /// slower than the audio response, so the voice always drives the motion the
    /// user actually reads.
    private static func phase(for date: Date) -> CGFloat {
        let seconds = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 240)
        return CGFloat(seconds) * 1.05
    }
}
