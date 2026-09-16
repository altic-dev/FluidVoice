//
//  NotchHaloRim.swift
//  Fluid
//
//  Light that lives under the notch cutout.
//

import SwiftUI

/// The themed light under the notch.
///
/// Three stacked pieces, all drawn inside the notch content area, so the
/// DynamicNotchKit presentation shape is never touched:
///
/// 1. a wide, very soft diffuse glow that spills left and right of the cutout's
///    underside - the impression that the notch itself emits a little light;
/// 2. a short warm ember in the middle, the minority hue of the reference;
/// 3. the hairline rim that hugs the cutout, faded towards the top so it reads as
///    light coming out from under the black shape rather than a ring around it.
///
/// Nothing here animates on its own: every opacity follows the audio level the
/// notch already publishes.
struct NotchHaloRim: View {
    let palette: OverlayPalette
    let glow: OverlayGlowIntensity
    let level: CGFloat

    /// Corner radius of the content it hugs.
    var cornerRadius: CGFloat = 9

    var body: some View {
        ZStack {
            // Wide cool glow under the cutout.
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            self.palette.secondary.opacity(self.underGlowOpacity),
                            self.palette.secondary.opacity(0),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 44
                    )
                )
                .frame(height: 16)
                .offset(y: 5)
                .blur(radius: max(5.0 * CGFloat(self.glow.visualizerGlowScale), 1.5))
                .allowsHitTesting(false)

            // Warm ember, kept a minority of the composition.
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            self.palette.accent.opacity(self.underGlowOpacity * 0.85),
                            self.palette.accent.opacity(0),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 20
                    )
                )
                .frame(width: 52, height: 11)
                .offset(y: 6)
                .blur(radius: 4)
                .allowsHitTesting(false)

            // The hairline that hugs the cutout. Cyan at both ends, the voice
            // hues through the middle, so it belongs to the same palette as the
            // premium styles.
            RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            self.palette.tertiary.opacity(self.rimOpacity),
                            self.palette.primary.opacity(self.rimOpacity),
                            self.palette.highlight.opacity(self.rimOpacity),
                            self.palette.tertiary.opacity(self.rimOpacity),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: self.rimWidth
                )
                .blur(radius: self.blurRadius)
                .mask(
                    // Fade the rim out towards the top: only the underside reads.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: .clear, location: 0.42),
                            .init(color: .white.opacity(0.55), location: 0.78),
                            .init(color: .white, location: 1.00),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)
        }
    }

    /// Bright enough to actually read on the black cutout, still bounded so it
    /// never turns into a glowing ring around the notch.
    static func rimOpacity(glow: OverlayGlowIntensity, level: CGFloat) -> Double {
        let base = 0.55 * glow.visualizerGlowScale
        let voiced = 0.80 + 0.55 * Double(min(max(level, 0), 1))
        return min(base * voiced, 0.85)
    }

    private var rimOpacity: Double {
        Self.rimOpacity(glow: self.glow, level: self.level)
    }

    /// The wide diffuse glow stays fainter than the rim: it is atmosphere, not a
    /// second light source. It still follows the voice so the notch feels alive.
    private var underGlowOpacity: Double {
        let base = 0.30 * self.glow.visualizerGlowScale
        let voiced = 0.70 + 0.60 * Double(min(max(self.level, 0), 1))
        return min(base * voiced, 0.55)
    }

    private var rimWidth: CGFloat {
        max(self.glow.borderWidth * 1.15, 0.9)
    }

    private var blurRadius: CGFloat {
        max(self.glow.auraBlurRadius * 0.28, 1.2)
    }
}
