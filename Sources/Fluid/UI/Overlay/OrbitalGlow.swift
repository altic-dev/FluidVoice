//
//  OrbitalGlow.swift
//  Fluid
//
//  Subtle orbital aura that traces the pill outline.
//

import SwiftUI

/// A hairline themed border with one slow highlight travelling around it.
///
/// This is deliberately not a rainbow outline. The gradient is dominated by the
/// theme palette with a single brighter zone, the orbit speed is fixed, and the
/// audio level modulates opacity only - never the rotation. When Reduce Motion
/// is on, or the overlay is off screen, the angle is pinned and the timeline
/// stops entirely.
struct OrbitalGlow: View {
    let cornerRadius: CGFloat
    let palette: OverlayPalette
    let glow: OverlayGlowIntensity
    let level: CGFloat
    let isActive: Bool
    let reduceMotion: Bool
    /// Minimal style keeps the ring monochrome to stay sober.
    var isMonochrome: Bool = false
    /// Briefly brightens the aura on the completion flash.
    var isCompleting: Bool = false

    /// Seconds per revolution. Slow enough to read as ambient light.
    static let revolutionSeconds: Double = 5.5

    var body: some View {
        Group {
            if self.reduceMotion || !self.isActive {
                self.ring(angle: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !self.isActive)) { timeline in
                    self.ring(angle: Self.angle(for: timeline.date))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Deterministic angle in 0..<360 for a point in time.
    ///
    /// Wrapping every revolution keeps the value small over long uptimes and is
    /// visually seamless: 0 degrees and 360 degrees are the same rotation.
    static func angle(for date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        let withinRevolution = seconds.truncatingRemainder(dividingBy: Self.revolutionSeconds)
        return withinRevolution / Self.revolutionSeconds * 360
    }

    private func ring(angle: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
        let base = self.glow.auraOpacity(forLevel: self.level)
        // "Brief brightening of the halo" on completion, still bounded so it can
        // never flare.
        let opacity = self.isCompleting ? min(base * 1.9 + 0.10, 0.60) : base

        return ZStack {
            shape
                .strokeBorder(self.borderGradient(angle: angle), lineWidth: self.glow.auraStrokeWidth)
                .blur(radius: self.glow.auraBlurRadius)
                .opacity(opacity)

            shape
                .strokeBorder(self.borderGradient(angle: angle), lineWidth: self.glow.borderWidth)
                .opacity(min(opacity * 3.2, 0.9))
        }
    }

    private func borderGradient(angle: Double) -> AngularGradient {
        if self.isCompleting {
            return AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: OverlayPalette.success.opacity(0.35), location: 0.00),
                    .init(color: OverlayPalette.success.opacity(1.00), location: 0.20),
                    .init(color: self.palette.tertiary.opacity(0.75), location: 0.50),
                    .init(color: OverlayPalette.success.opacity(0.90), location: 0.78),
                    .init(color: OverlayPalette.success.opacity(0.35), location: 1.00),
                ]),
                center: .center,
                angle: .degrees(angle)
            )
        }

        if self.isMonochrome {
            return AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.white.opacity(0.04), location: 0.00),
                    .init(color: Color.white.opacity(0.62), location: 0.12),
                    .init(color: Color.white.opacity(0.30), location: 0.34),
                    .init(color: Color.white.opacity(0.06), location: 0.62),
                    .init(color: Color.white.opacity(0.22), location: 0.82),
                    .init(color: Color.white.opacity(0.04), location: 1.00),
                ]),
                center: .center,
                angle: .degrees(angle)
            )
        }

        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: self.palette.primary.opacity(0.04), location: 0.00),
                .init(color: self.palette.primary.opacity(0.85), location: 0.10),
                .init(color: self.palette.secondary.opacity(0.95), location: 0.26),
                .init(color: self.palette.tertiary.opacity(0.80), location: 0.42),
                .init(color: self.palette.primary.opacity(0.20), location: 0.62),
                .init(color: self.palette.secondary.opacity(0.30), location: 0.80),
                .init(color: self.palette.primary.opacity(0.04), location: 1.00),
            ]),
            center: .center,
            angle: .degrees(angle)
        )
    }
}
