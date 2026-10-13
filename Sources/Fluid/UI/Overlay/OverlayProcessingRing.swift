//
//  OverlayProcessingRing.swift
//  Fluid
//
//  Themed ring shown while the engine is still refining or delivering text.
//

import SwiftUI

/// Replaces the generic system spinner with a themed gradient arc.
///
/// It only exists while the overlay is on screen and Reduce Motion is off, so
/// nothing keeps redrawing once the pill has been parked.
struct OverlayProcessingRing: View {
    let palette: OverlayPalette
    let glow: OverlayGlowIntensity
    let isActive: Bool
    let reduceMotion: Bool
    /// Minimal style keeps the ring monochrome to stay sober.
    var isMonochrome: Bool = false

    /// Seconds per revolution for the working arc.
    static let revolutionSeconds: Double = 1.2

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

    /// Deterministic angle in 0..<360, wrapped every revolution.
    static func angle(for date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        let withinRevolution = seconds.truncatingRemainder(dividingBy: Self.revolutionSeconds)
        return withinRevolution / Self.revolutionSeconds * 360
    }

    private func ring(angle: Double) -> some View {
        ZStack {
            Circle()
                .strokeBorder(self.trackColor.opacity(0.18), lineWidth: 1.6)

            Circle()
                .trim(from: 0, to: 0.34)
                .stroke(self.track, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .rotationEffect(.degrees(angle))

            Circle()
                .trim(from: 0, to: 0.34)
                .stroke(self.track, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .rotationEffect(.degrees(angle))
                .blur(radius: 2.6 * CGFloat(self.glow.visualizerGlowScale))
                .opacity(0.55 * self.glow.visualizerGlowScale)
        }
    }

    private var trackColor: Color {
        self.isMonochrome ? Color.white : self.palette.primary
    }

    private var track: AngularGradient {
        let colors = self.isMonochrome
            ? [Color.white.opacity(0.25), Color.white.opacity(0.95)]
            : [self.palette.primary, self.palette.secondary, self.palette.tertiary]
        return AngularGradient(gradient: Gradient(colors: colors), center: .center)
    }
}
