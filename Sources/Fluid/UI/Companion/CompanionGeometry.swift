//
//  CompanionGeometry.swift
//  Fluid
//
//  Pure geometry for one Companion frame.
//

import SwiftUI

/// Everything the Companion draws is derived from this value.
///
/// It is a function of the phase, the audio level and the variant tuning only,
/// so the companion moves because the slow drift or the voice moved - never
/// because of a random source. That is the same rule the overlay visualizers
/// follow, and it is what keeps the character calm instead of twitchy.
struct CompanionGeometry {
    let rect: CGRect
    let phase: CGFloat
    let level: CGFloat
    let tuning: CompanionTuning
    /// 0.55 subtle ... 1.5 expressive. Multiplies the travel, never the voice.
    let motion: CGFloat

    static let coreSteps = 44
    static let membraneSteps = 48

    // MARK: - Core

    /// Radius of the dark body. A little under a third of the box, so the
    /// membranes can wrap around it without leaving the canvas.
    var coreRadius: CGFloat {
        min(self.rect.width, self.rect.height) * 0.25
    }

    var center: CGPoint {
        CGPoint(x: self.rect.midX, y: self.rect.midY)
    }

    /// Closed silhouette of the dark core.
    func corePath() -> Path {
        var points: [CGPoint] = []
        for step in 0..<Self.coreSteps {
            let angle = CGFloat(step) / CGFloat(Self.coreSteps) * 2 * .pi
            let radius = self.coreRadius * self.coreShape(at: angle)
            points.append(CGPoint(
                x: self.center.x + cos(angle) * radius,
                y: self.center.y + sin(angle) * radius * 0.94
            ))
        }
        return Self.smoothClosedPath(points)
    }

    /// Low frequency silhouette modulation.
    ///
    /// Only even and three-fold terms: the body can never grow the single
    /// pointed lobe that would read as a teardrop, and it is never a plain
    /// circle either.
    private func coreShape(at angle: CGFloat) -> CGFloat {
        let breath = 1 + 0.026 * sin(self.phase * 0.7) + 0.10 * self.level * self.motion
        let body = 1
            + 0.062 * cos(2 * angle + 0.35)
            + 0.030 * cos(3 * angle + self.phase * 0.42)
            + 0.016 * cos(5 * angle - self.phase * 0.30)
        return breath * body
    }

    // MARK: - Membranes

    func membraneRadius(index: Int) -> CGFloat {
        let side = min(self.rect.width, self.rect.height)
        return side * (0.30 + 0.050 * CGFloat(index))
    }

    /// Angular coverage of a membrane, in radians.
    ///
    /// Always under a full turn: that opening is the difference between a draped
    /// ribbon and a ring around the body.
    func membraneSpan(index: Int) -> CGFloat {
        let seed = CGFloat(index) * 1.9 + 0.6
        let speed = self.tuning.speed * self.motion
        return 1.55 * CGFloat.pi + 0.22 * sin(seed + self.phase * speed * 0.3)
    }

    /// A tapered ribbon that wraps most of the body, then opens.
    ///
    /// The band never closes into a ring: it covers roughly three quarters of the
    /// circumference and fades to a point at both ends, and its radius carries a
    /// strong two and three fold modulation, so it drapes around the body instead
    /// of orbiting it. Consecutive membranes spin in opposite directions. This is
    /// the difference between a membrane and a Saturn ring.
    func membranePath(index: Int) -> Path {
        let side = min(self.rect.width, self.rect.height)
        let base = self.membraneRadius(index: index)
        let seed = CGFloat(index) * 1.9 + 0.6
        let direction: CGFloat = index % 2 == 0 ? 1 : -1
        let speed = self.tuning.speed * self.motion
        let spin = self.phase * speed * 0.35 * direction
        // Outer ribbons travel a little less, so they cannot leave the canvas.
        let damp = 1 - 0.06 * CGFloat(index)

        let span = self.membraneSpan(index: index)
        let start = spin + seed + CGFloat(index) * 0.65
        let ribbonWidth = side * (0.085 - 0.010 * CGFloat(index))
        let offsetX = side * 0.020 * CGFloat(index - 1)
        let offsetY = -side * 0.012 * CGFloat(index - 1)
        let center = CGPoint(x: self.center.x + offsetX, y: self.center.y + offsetY)

        let steps = Self.membraneSteps
        var angles: [CGFloat] = []
        var radii: [CGFloat] = []
        var halfWidths: [CGFloat] = []
        for step in 0..<steps {
            let u = CGFloat(step) / CGFloat(steps - 1)
            let angle = start + span * u
            // Pointed ends, so the ribbon dissolves into the background instead of
            // stopping with a hard cut.
            let endTaper = pow(max(sin(u * CGFloat.pi), 0), 0.65)
            let radial = 1
                + self.tuning.wobble * 0.22 * damp * sin(2 * angle + self.phase * speed * 0.5 + seed)
                + self.tuning.wobble * 0.12 * damp * sin(3 * angle - self.phase * speed * 0.8 + seed * 1.3)
                + self.tuning.flutter * 0.07 * damp * sin(5 * angle + self.phase * speed * 1.4)
            let lift = -self.tuning.rise * 0.12 * sin(angle)
            let along = index % 2 == 0 ? u : 1 - u
            let thickness = ribbonWidth
                * (0.14 + 0.86 * pow(max(sin(along * CGFloat.pi * 1.5 + seed), 0), 1.1))
            angles.append(angle)
            // The membranes open up with the voice: the body gains real volume
            // while the user is speaking instead of only shifting shape.
            radii.append(base * (radial + lift) * (1 + 0.16 * self.level * self.motion))
            halfWidths.append(thickness * endTaper / 2)
        }

        // Scale the whole ribbon down if it would leave the canvas. The offset
        // centre is accounted for, so an outer ribbon cannot spill out sideways.
        // Scaling keeps the silhouette; clipping would flatten it against the edge.
        let xLimit = side * 0.5 - abs(offsetX)
        let yLimit = (side * 0.5 - abs(offsetY)) / 0.94
        let limit = max(min(side * 0.47, xLimit, yLimit), side * 0.1)
        let maxOuter = zip(radii, halfWidths).map { $0 + $1 }.max() ?? 0
        let fit = maxOuter > limit ? limit / maxOuter : 1

        var outer: [CGPoint] = []
        var inner: [CGPoint] = []
        for index in 0..<steps {
            outer.append(Self.point(
                center: center,
                angle: angles[index],
                radius: (radii[index] + halfWidths[index]) * fit
            ))
            inner.append(Self.point(
                center: center,
                angle: angles[index],
                radius: max((radii[index] - halfWidths[index]) * fit, side * 0.06)
            ))
        }
        inner.reverse()
        return Self.smoothClosedPath(outer + inner)
    }

    // MARK: - Embers

    /// Deterministic sparks. The same phase always draws the same embers.
    func emberPoints() -> [CGPoint] {
        let side = min(self.rect.width, self.rect.height)
        return (0..<self.tuning.emberCount).map { index in
            let seed = CGFloat(index) * 2.399
            let angle = seed + self.phase * 0.5 * self.tuning.speed * self.motion
            let radial = side * (0.34 + 0.10 * sin(seed * 3.1 + self.phase * 0.9))
            let lift = self.tuning.rise * side * 0.10 * (0.5 + 0.5 * sin(self.phase * 1.3 + seed))
            return CGPoint(
                x: self.center.x + cos(angle) * radial,
                y: self.center.y + sin(angle) * radial * 0.94 - lift
            )
        }
    }

    // MARK: - Face

    /// Eye centre. `sign` is -1 for the left eye and +1 for the right one.
    func eyeCenter(sign: Int) -> CGPoint {
        let offset = self.coreRadius * 0.42 * CGFloat(sign)
        return CGPoint(x: self.center.x + offset, y: self.center.y - self.coreRadius * 0.16)
    }

    func eyeSize() -> CGSize {
        let width = max(self.coreRadius * 0.30, 2)
        let height = max(self.coreRadius * 0.34 * (0.55 + 0.65 * self.level * self.motion), 1.4)
        return CGSize(width: width, height: height)
    }

    // MARK: - Helpers

    /// Closed Catmull-Rom style outline through the points, using the shared
    /// midpoint technique so every organic shape in the app is smoothed the same
    /// way.
    static func smoothClosedPath(_ points: [CGPoint]) -> Path {
        guard points.count > 2 else { return Path() }
        var path = Path()
        path.move(to: midpoint(points[points.count - 1], points[0]))
        for index in 0..<points.count {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(to: midpoint(current, next), control: current)
        }
        path.closeSubpath()
        return path
    }

    static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    /// One point on the (slightly vertically squashed) ring around the core.
    private static func point(center: CGPoint, angle: CGFloat, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius * 0.94)
    }
}
