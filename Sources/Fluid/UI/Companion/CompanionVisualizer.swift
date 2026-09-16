//
//  CompanionVisualizer.swift
//  Fluid
//
//  The optional Companion: an abstract dark core wrapped in fluid membranes.
//

import SwiftUI

/// Draws the Companion for one instant.
///
/// Pure consumer of state the dictation pipeline already publishes: the
/// microphone level and the lifecycle phase. It opens no audio path, owns no
/// timer of its own, and stops completely when it is not on screen.
struct CompanionVisualizer: View {
    let state: CompanionState
    let variant: CompanionVariant
    let themePalette: OverlayPalette
    let glow: OverlayGlowIntensity
    let accessories: Set<CompanionAccessory>
    let level: CGFloat
    let isActive: Bool
    let reduceMotion: Bool
    let motion: MotionIntensity

    /// Frozen phase for offscreen previews and tests. Inert at runtime.
    var previewPhase: CGFloat? = nil

    var body: some View {
        let palette = self.variant.palette(themePalette: self.themePalette)
        let tuning = self.variant.tuning
        Group {
            if let phase = self.previewPhase {
                self.canvas(phase: phase, palette: palette, tuning: tuning)
            } else if self.reduceMotion {
                // Reduce Motion: keep the silhouette, the palette and the audio
                // reaction, drop the continuous drift.
                self.canvas(phase: 1.1, palette: palette, tuning: tuning)
            } else {
                TimelineView(.animation(minimumInterval: self.frameInterval, paused: !self.isActive)) { timeline in
                    self.canvas(
                        phase: Self.phase(for: timeline.date),
                        palette: palette,
                        tuning: tuning
                    )
                }
            }
        }
        .compositingGroup()
        .allowsHitTesting(false)
    }

    /// Idle is the cheapest state; listening and thinking carry the audio
    /// reaction and get the full rate.
    private var frameInterval: TimeInterval {
        switch self.state {
        case .listening, .thinking, .typing: return 1.0 / 30.0
        case .idle, .completed, .error: return 1.0 / 18.0
        }
    }

    private static func phase(for date: Date) -> CGFloat {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 240)
    }

    private func canvas(phase: CGFloat, palette: OverlayPalette, tuning: CompanionTuning) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            self.draw(into: &context, size: size, phase: phase, palette: palette, tuning: tuning)
        }
    }

    // MARK: - Drawing

    private func draw(
        into context: inout GraphicsContext,
        size: CGSize,
        phase: CGFloat,
        palette: OverlayPalette,
        tuning: CompanionTuning
    ) {
        let rect = CGRect(origin: .zero, size: size)
        let geometry = CompanionGeometry(
            rect: rect,
            phase: phase,
            level: min(max(self.level, 0), 1),
            tuning: tuning,
            motion: self.motion.scale
        )
        let glowScale = CGFloat(self.glow.visualizerGlowScale)
        let colors = [palette.tertiary, palette.primary, palette.highlight, palette.secondary, palette.accent]

        self.drawAura(into: &context, geometry: geometry, palette: palette, tuning: tuning, glowScale: glowScale)

        // Membranes: a blurred light pass, then the ribbon itself.
        for index in 0..<max(tuning.membraneCount, 1) {
            let path = geometry.membranePath(index: index)
            let color = colors[index % colors.count]
            let baseOpacity = 0.58 - 0.06 * Double(index)
            if self.glow != .subtle {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 3.0 * glowScale))
                    layer.opacity = 0.55 * glowScale
                    layer.fill(path, with: .color(color))
                }
            }
            context.fill(path, with: .color(color.opacity(max(baseOpacity, 0.30))))
        }

        self.drawListeningRipples(into: &context, geometry: geometry, palette: palette)

        self.drawCore(into: &context, geometry: geometry, palette: palette, glowScale: glowScale)
        self.drawFace(into: &context, geometry: geometry, palette: palette)
        self.drawAccessories(into: &context, geometry: geometry, palette: palette)
        self.drawEmbers(into: &context, geometry: geometry, palette: palette)
    }

    private func drawAura(
        into context: inout GraphicsContext,
        geometry: CompanionGeometry,
        palette: OverlayPalette,
        tuning: CompanionTuning,
        glowScale: CGFloat
    ) {
        let radius = geometry.membraneRadius(index: max(tuning.membraneCount - 1, 0)) * 1.25
        let opacity = min(0.18 * Double(tuning.coreGlow) * Double(glowScale), 0.30)
        let rect = CGRect(
            x: geometry.center.x - radius,
            y: geometry.center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [palette.secondary.opacity(opacity), palette.secondary.opacity(0)]),
                center: geometry.center,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    /// Small waves that appear while the Companion is listening: two rings that
    /// expand and fade, driven by the voice. Rare and contextual - never a
    /// permanent particle system.
    private func drawListeningRipples(
        into context: inout GraphicsContext,
        geometry: CompanionGeometry,
        palette: OverlayPalette
    ) {
        guard self.state == .listening || self.state == .typing else { return }
        let energy = min(max(self.level, 0), 1)
        guard energy > 0.05 else { return }

        let side = min(geometry.rect.width, geometry.rect.height)
        let baseRadius = geometry.coreRadius * 1.15
        for index in 0..<2 {
            let progress = (geometry.phase * 0.30 + CGFloat(index) * 0.5)
                .truncatingRemainder(dividingBy: 1)
            let radius = baseRadius + side * 0.26 * progress
            let alpha = (1 - progress) * 0.28 * Double(energy)
            guard alpha > 0.01 else { continue }
            let rect = CGRect(
                x: geometry.center.x - radius,
                y: geometry.center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let color = index == 0 ? palette.tertiary : palette.highlight
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(color.opacity(alpha)),
                lineWidth: max(side * 0.012 * (1 - progress), 0.6)
            )
        }
    }

    private func drawCore(
        into context: inout GraphicsContext,
        geometry: CompanionGeometry,
        palette: OverlayPalette,
        glowScale: CGFloat
    ) {
        let core = geometry.corePath()
        // Dark body. Never pure black, so the rim has something to sit against.
        context.fill(
            core,
            with: .radialGradient(
                Gradient(colors: [
                    Color(hex: "#181B26") ?? Color.black,
                    Color(hex: "#05060A") ?? Color.black,
                ]),
                center: CGPoint(x: geometry.center.x, y: geometry.center.y - geometry.coreRadius * 0.45),
                startRadius: 0,
                endRadius: geometry.coreRadius * 1.65
            )
        )
        // Light reflected from below, so the body reads as a volume rather than a
        // flat sticker.
        context.fill(
            core,
            with: .linearGradient(
                Gradient(colors: [
                    Color.clear,
                    palette.secondary.opacity(min(0.24 * Double(glowScale), 0.34)),
                ]),
                startPoint: CGPoint(x: geometry.center.x, y: geometry.center.y),
                endPoint: CGPoint(x: geometry.center.x, y: geometry.center.y + geometry.coreRadius)
            )
        )
        context.stroke(
            core,
            with: .linearGradient(
                Gradient(colors: [
                    palette.tertiary.opacity(0.85),
                    palette.primary.opacity(0.70),
                    palette.highlight.opacity(0.80),
                ]),
                startPoint: CGPoint(x: geometry.rect.minX, y: geometry.center.y),
                endPoint: CGPoint(x: geometry.rect.maxX, y: geometry.center.y)
            ),
            lineWidth: max(1.0 * glowScale, 0.8)
        )
    }

    private func drawFace(
        into context: inout GraphicsContext,
        geometry: CompanionGeometry,
        palette: OverlayPalette
    ) {
        let face = Color.white.opacity(0.92)
        let size = geometry.eyeSize()
        let stroke = StrokeStyle(lineWidth: max(size.width * 0.28, 1.3), lineCap: .round)
        for sign in [-1, 1] {
            let center = geometry.eyeCenter(sign: sign)
            switch self.state {
            case .idle:
                context.stroke(
                    Self.eyeArc(center: center, width: size.width, curvingUp: false),
                    with: .color(face),
                    style: stroke
                )
            case .completed:
                context.stroke(
                    Self.eyeArc(center: center, width: size.width, curvingUp: true),
                    with: .color(face),
                    style: stroke
                )
            case .listening:
                let radius = size.width * 0.44
                let eye = Path(roundedRect: CGRect(
                    x: center.x - radius,
                    y: center.y - size.height * 0.5,
                    width: radius * 2,
                    height: size.height
                ), cornerRadius: radius)
                // A soft glow so "I am listening" is unmistakable at a glance.
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: max(size.width * 0.9, 1.5)))
                    layer.opacity = 0.55
                    layer.fill(eye, with: .color(palette.tertiary))
                }
                context.fill(eye, with: .color(face))
            case .thinking:
                // Two small pupils that glance sideways, so the state reads as
                // "working on it" without any text.
                let shift = size.width * 0.34 * sin(geometry.phase * 0.9 + CGFloat(sign))
                let radius = size.width * 0.30
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - radius + shift,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(face)
                )
            case .typing:
                let bar = CGRect(
                    x: center.x - size.width * 0.46,
                    y: center.y - max(size.width * 0.10, 0.7),
                    width: size.width * 0.92,
                    height: max(size.width * 0.20, 1.4)
                )
                context.fill(Path(roundedRect: bar, cornerRadius: bar.height / 2), with: .color(face))
            case .error:
                context.stroke(
                    Self.crossPath(center: center, size: size.width * 0.55),
                    with: .color(face),
                    style: stroke
                )
            }
        }
        // A tiny neutral mouth keeps the face readable without making it human.
        let mouthWidth = size.width * 0.9
        let mouthY = geometry.center.y + geometry.coreRadius * 0.34
        var mouth = Path()
        mouth.move(to: CGPoint(x: geometry.center.x - mouthWidth / 2, y: mouthY))
        mouth.addQuadCurve(
            to: CGPoint(x: geometry.center.x + mouthWidth / 2, y: mouthY),
            control: CGPoint(
                x: geometry.center.x,
                y: mouthY + (self.state == .error ? -size.width * 0.30 : size.width * 0.34)
            )
        )
        context.stroke(
            mouth,
            with: .color(palette.tertiary.opacity(0.55)),
            style: StrokeStyle(lineWidth: max(size.width * 0.16, 1.0), lineCap: .round)
        )
    }

    private func drawAccessories(
        into context: inout GraphicsContext,
        geometry: CompanionGeometry,
        palette: OverlayPalette
    ) {
        let radius = geometry.coreRadius
        let stroke = max(radius * 0.16, 1.2)

        if self.accessories.contains(.halo) {
            let rect = CGRect(
                x: geometry.center.x - radius * 0.80,
                y: geometry.center.y - radius * 1.78,
                width: radius * 1.60,
                height: radius * 0.42
            )
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: radius * 0.5))
                layer.opacity = 0.55
                layer.stroke(Path(ellipseIn: rect), with: .color(palette.accent), lineWidth: stroke)
            }
            context.stroke(Path(ellipseIn: rect), with: .color(palette.accent.opacity(0.95)), lineWidth: stroke)
        }

        if self.accessories.contains(.hat) {
            let crownWidth = radius * 1.10
            let crownHeight = radius * 0.62
            let top = geometry.center.y - radius * 1.32
            var crown = Path()
            crown.move(to: CGPoint(x: geometry.center.x - crownWidth / 2, y: top + crownHeight))
            crown.addLine(to: CGPoint(x: geometry.center.x - crownWidth * 0.36, y: top))
            crown.addLine(to: CGPoint(x: geometry.center.x + crownWidth * 0.36, y: top))
            crown.addLine(to: CGPoint(x: geometry.center.x + crownWidth / 2, y: top + crownHeight))
            crown.closeSubpath()
            context.fill(crown, with: .color(palette.primary.opacity(0.94)))
            let brim = CGRect(
                x: geometry.center.x - crownWidth * 0.74,
                y: top + crownHeight - stroke * 0.5,
                width: crownWidth * 1.48,
                height: stroke * 1.6
            )
            context.fill(
                Path(roundedRect: brim, cornerRadius: brim.height / 2),
                with: .color(palette.highlight.opacity(0.95))
            )
        }

        if self.accessories.contains(.glasses) {
            let lensRadius = radius * 0.38
            for sign in [-1, 1] {
                let center = geometry.eyeCenter(sign: sign)
                let rect = CGRect(
                    x: center.x - lensRadius,
                    y: center.y - lensRadius,
                    width: lensRadius * 2,
                    height: lensRadius * 2
                )
                context.stroke(Path(ellipseIn: rect), with: .color(palette.tertiary.opacity(0.95)), lineWidth: stroke)
            }
            var bridge = Path()
            bridge.move(to: CGPoint(x: geometry.center.x - radius * 0.12, y: geometry.center.y - radius * 0.16))
            bridge.addLine(to: CGPoint(x: geometry.center.x + radius * 0.12, y: geometry.center.y - radius * 0.16))
            context.stroke(bridge, with: .color(palette.tertiary.opacity(0.95)), lineWidth: stroke * 0.8)
        }

        if self.accessories.contains(.scarf) {
            let band = CGRect(
                x: geometry.center.x - radius * 0.80,
                y: geometry.center.y + radius * 0.60,
                width: radius * 1.60,
                height: radius * 0.34
            )
            context.fill(
                Path(roundedRect: band, cornerRadius: band.height / 2),
                with: .color(palette.highlight.opacity(0.95))
            )
            let tail = CGRect(
                x: geometry.center.x + radius * 0.30,
                y: band.maxY - radius * 0.06,
                width: radius * 0.26,
                height: radius * 0.48
            )
            context.fill(
                Path(roundedRect: tail, cornerRadius: tail.width / 2),
                with: .color(palette.accent.opacity(0.9))
            )
        }
    }

    private func drawEmbers(
        into context: inout GraphicsContext,
        geometry: CompanionGeometry,
        palette: OverlayPalette
    ) {
        guard geometry.tuning.emberCount > 0 else { return }
        let side = min(geometry.rect.width, geometry.rect.height)
        let radius = max(side * 0.018, 0.8)
        let warm = geometry.tuning.emberWarmth > 0.5 ? palette.accent : palette.tertiary
        for point in geometry.emberPoints() {
            context.fill(
                Path(ellipseIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(warm.opacity(0.85))
            )
        }
    }

    // MARK: - Face helpers

    private static func eyeArc(center: CGPoint, width: CGFloat, curvingUp: Bool) -> Path {
        let half = width * 0.55
        let depth = width * 0.40 * (curvingUp ? -1 : 1)
        var path = Path()
        path.move(to: CGPoint(x: center.x - half, y: center.y))
        path.addQuadCurve(
            to: CGPoint(x: center.x + half, y: center.y),
            control: CGPoint(x: center.x, y: center.y + depth)
        )
        return path
    }

    private static func crossPath(center: CGPoint, size: CGFloat) -> Path {
        let half = size / 2
        var path = Path()
        path.move(to: CGPoint(x: center.x - half, y: center.y - half))
        path.addLine(to: CGPoint(x: center.x + half, y: center.y + half))
        path.move(to: CGPoint(x: center.x + half, y: center.y - half))
        path.addLine(to: CGPoint(x: center.x - half, y: center.y + half))
        return path
    }
}
