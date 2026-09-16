//
//  OverlayColorTheme.swift
//  Fluid
//
//  Centralized color, glow and appearance definitions for the recording overlay.
//
//  Every overlay surface (visualizer, orbital aura, hairline border, accent)
//  resolves its colors from a single palette so the themes never drift apart.
//

import SwiftUI

/// Resolved colors for one overlay theme.
struct OverlayPalette: Equatable {
    let primary: Color
    let secondary: Color
    let tertiary: Color
    /// Bright second highlight in the middle of the spectrum (magenta/pink for
    /// Aurora). It is what keeps the flagship theme from collapsing into "Blue":
    /// the layered Aurora draws it between the violet body and the warm accent.
    let highlight: Color
    /// Warm highlight used sparingly, never as a dominant hue.
    let accent: Color
    /// Stored so per-frame drawing never rebuilds the array.
    let gradientColors: [Color]

    init(primary: Color, secondary: Color, tertiary: Color, highlight: Color, accent: Color) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.highlight = highlight
        self.accent = accent
        self.gradientColors = [primary, secondary, tertiary]
    }

    /// Fixed completion tint. Deliberately not themed: a successful delivery
    /// reads as green in the reference concept sheet whatever the color theme.
    static let success = Color(hex: "#34C759") ?? Color.green

    /// Gradient that runs left to right, used by the ribbon and the rings.
    var horizontalGradient: LinearGradient {
        LinearGradient(colors: self.gradientColors, startPoint: .leading, endPoint: .trailing)
    }

    /// Gradient that runs bottom to top, used by the bar visualizers.
    var verticalGradient: LinearGradient {
        LinearGradient(colors: self.gradientColors, startPoint: .bottom, endPoint: .top)
    }

    /// Aurora mass gradient: cyan, blue, violet, magenta, a narrow warm band,
    /// then back to cyan. Every hue the reference sheet shows is present, and the
    /// transparency of the layers lets them mix on screen instead of reading as
    /// one flat colour ramp.
    var ribbonGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: self.tertiary, location: 0.00),
                .init(color: self.secondary, location: 0.22),
                .init(color: self.primary, location: 0.44),
                .init(color: self.highlight, location: 0.62),
                .init(color: self.accent, location: 0.80),
                .init(color: self.tertiary, location: 1.00),
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Atmosphere gradient for the outermost Aurora layer: cool hues only, so the
    /// wide background mass reads as depth rather than as a second voice body.
    var atmosphereGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: self.secondary.opacity(0.85), location: 0.00),
                .init(color: self.tertiary.opacity(0.95), location: 0.38),
                .init(color: self.primary.opacity(0.90), location: 0.70),
                .init(color: self.secondary.opacity(0.85), location: 1.00),
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Ordered hues used by the Wave row, so the theme's whole spectrum is
    /// visible across the bars instead of one flat hue. The first and last entry
    /// match, which lets the row close back on itself in cyan.
    var spectrumColors: [Color] {
        [self.tertiary, self.secondary, self.primary, self.highlight, self.accent, self.tertiary]
    }

    /// Nearest spectrum hue for a 0 ... 1 position. Deliberately cheap: it runs
    /// once per bar on every frame.
    func spectrumColor(at fraction: CGFloat) -> Color {
        let colors = self.spectrumColors
        guard colors.count > 1 else { return colors.first ?? self.primary }
        let clamped = min(max(fraction, 0), 1)
        let index = Int((clamped * CGFloat(colors.count - 1)).rounded())
        return colors[min(max(index, 0), colors.count - 1)]
    }

    /// Thin accent-layer gradient: magenta and warm light over a cyan tail. It is
    /// deliberately a minority of the composition.
    var accentLayerGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: self.tertiary.opacity(0.70), location: 0.00),
                .init(color: self.highlight, location: 0.40),
                .init(color: self.accent, location: 0.68),
                .init(color: self.highlight.opacity(0.70), location: 1.00),
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// Color themes shared by the visualizers and the orbital aura.
enum OverlayColorTheme: String, CaseIterable, Codable, Identifiable {
    case aurora
    case blue
    case purple
    case green
    case orange
    /// One user-chosen colour expanded into a full palette.
    case custom

    /// Used whenever a persisted or imported value cannot be resolved.
    static let fallback: OverlayColorTheme = .aurora

    /// Near-black pill surface. Deliberately not pure black so the border reads.
    static let surfaceHex = "#07080A"

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .aurora: return "Aurora"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .green: return "Green"
        case .orange: return "Orange"
        case .custom: return "Custom"
        }
    }

    /// Resolved palette. Backed by a cache because it is read on every audio
    /// tick while the overlay is drawn.
    var palette: OverlayPalette {
        if self == .custom {
            return OverlayPalette.derive(fromHex: OverlayCustomTheme.hex)
                ?? Self.cachedPalettes[.aurora]
                ?? Self.makePalette(for: .aurora)
        }
        return Self.cachedPalettes[self] ?? Self.makePalette(for: self)
    }

    /// Small swatch rendered in the settings chips.
    var swatchColors: [Color] {
        self.palette.gradientColors
    }

    private static let cachedPalettes: [OverlayColorTheme: OverlayPalette] = Dictionary(
        uniqueKeysWithValues: OverlayColorTheme.allCases
            .filter { $0 != .custom }
            .map { theme in
                (theme, OverlayColorTheme.makePalette(for: theme))
            }
    )

    private static func makePalette(for theme: OverlayColorTheme) -> OverlayPalette {
        switch theme {
        case .aurora:
            // The flagship theme is the only one that intentionally crosses the
            // colour wheel: cyan, blue, violet, magenta and a warm ember.
            return OverlayPalette(
                primary: Self.color("#8B5CF6", fallback: .purple),
                secondary: Self.color("#4D7CFE", fallback: .blue),
                tertiary: Self.color("#38D6E8", fallback: .cyan),
                highlight: Self.color("#FF5FA2", fallback: .pink),
                accent: Self.color("#FF9A5B", fallback: .orange)
            )
        case .blue:
            return OverlayPalette(
                primary: Self.color("#1E40AF", fallback: .blue),
                secondary: Self.color("#3B82F6", fallback: .blue),
                tertiary: Self.color("#22D3EE", fallback: .cyan),
                highlight: Self.color("#7DD3FC", fallback: .cyan),
                accent: Self.color("#93C5FD", fallback: .blue)
            )
        case .purple:
            return OverlayPalette(
                primary: Self.color("#6D28D9", fallback: .purple),
                secondary: Self.color("#A855F7", fallback: .purple),
                tertiary: Self.color("#C084FC", fallback: .purple),
                highlight: Self.color("#E879F9", fallback: .pink),
                accent: Self.color("#F5A9DC", fallback: .pink)
            )
        case .green:
            return OverlayPalette(
                primary: Self.color("#0F766E", fallback: .teal),
                secondary: Self.color("#10B981", fallback: .green),
                tertiary: Self.color("#34D399", fallback: .green),
                highlight: Self.color("#A7F3D0", fallback: .mint),
                accent: Self.color("#6EE7A8", fallback: .green)
            )
        case .orange:
            return OverlayPalette(
                primary: Self.color("#C2410C", fallback: .orange),
                secondary: Self.color("#F59E0B", fallback: .orange),
                tertiary: Self.color("#FDBA74", fallback: .orange),
                highlight: Self.color("#FCD34D", fallback: .yellow),
                accent: Self.color("#FFE0B2", fallback: .yellow)
            )
        case .custom:
            // Never reached through the cache; the resolved palette is derived
            // from the user colour so the fallback stays the branded default.
            return OverlayPalette.derive(fromHex: OverlayCustomTheme.hex)
                ?? OverlayPalette(
                    primary: Self.color("#8B5CF6", fallback: .purple),
                    secondary: Self.color("#4D7CFE", fallback: .blue),
                    tertiary: Self.color("#38D6E8", fallback: .cyan),
                    highlight: Self.color("#FF5FA2", fallback: .pink),
                    accent: Self.color("#FF9A5B", fallback: .orange)
                )
        }
    }

    private static func color(_ hex: String, fallback: Color) -> Color {
        Color(hex: hex) ?? fallback
    }
}

/// How strongly the overlay glows. Subtle is genuinely restrained; Vivid stays
/// premium instead of saturating into a gaming look.
/// Advanced glow fine tuning applied on top of the Subtle / Normal / Vivid
/// preset, exactly like `OverlayCustomTheme` mirrors the custom colour: the
/// overlay components read the resolved values without depending on the
/// settings store. `SettingsStore` keeps it in sync on read and write.
enum OverlayGlowTuning {
    static let range: ClosedRange<Double> = 0.5...1.5
    static let neutral: Double = 1.0
    nonisolated(unsafe) static var strength: Double = OverlayGlowTuning.neutral

    /// Reads are clamped so a corrupt preference cannot flare the overlay.
    static var clampedStrength: Double {
        min(max(strength, range.lowerBound), range.upperBound)
    }
}

enum OverlayGlowIntensity: String, CaseIterable, Codable, Identifiable {
    case subtle
    case normal
    case vivid

    /// Used whenever a persisted or imported value cannot be resolved.
    static let fallback: OverlayGlowIntensity = .normal

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .subtle: return "Subtle"
        case .normal: return "Normal"
        case .vivid: return "Vivid"
        }
    }

    /// Opacity of the orbital aura while the user is silent.
    var auraBaseOpacity: Double {
        let base: Double
        switch self {
        case .subtle: base = 0.10
        case .normal: base = 0.16
        case .vivid: base = 0.19
        }
        // Bounded so even Vivid at 150% stays a gentle light rather than a flare.
        return min(base * OverlayGlowTuning.clampedStrength, 0.30)
    }

    /// The hairline border stays close to one point at every intensity.
    ///
    /// The advanced strength moves it far less than the aura: a hairline that
    /// scales linearly stops reading as a hairline.
    var borderWidth: CGFloat {
        let base: CGFloat
        switch self {
        case .subtle: base = 0.9
        case .normal: base = 1.0
        case .vivid: base = 1.15
        }
        let adjustment = (CGFloat(OverlayGlowTuning.clampedStrength) - 1) * 0.35
        return max(base + adjustment, 0.5)
    }

    var auraStrokeWidth: CGFloat {
        let base: CGFloat
        switch self {
        case .subtle: base = 2.4
        case .normal: base = 3.2
        case .vivid: base = 4.2
        }
        return base * CGFloat(OverlayGlowTuning.clampedStrength)
    }

    var auraBlurRadius: CGFloat {
        let base: CGFloat
        switch self {
        case .subtle: base = 4.0
        case .normal: base = 6.5
        case .vivid: base = 9.0
        }
        return base * CGFloat(OverlayGlowTuning.clampedStrength)
    }

    /// Multiplier applied to the soft glow behind the visualizers.
    var visualizerGlowScale: Double {
        let base: Double
        switch self {
        case .subtle: base = 0.5
        case .normal: base = 1.0
        case .vivid: base = 1.5
        }
        return base * OverlayGlowTuning.clampedStrength
    }

    /// Aura opacity for a normalized 0...1 audio level.
    ///
    /// The target is roughly 10-15% in silence, 18-22% at normal speech and
    /// 25-30% at a vocal peak. Volume modulates intensity only - never the
    /// speed at which the highlight travels around the capsule.
    func auraOpacity(forLevel level: CGFloat) -> Double {
        let clamped = Double(min(max(level, 0), 1))
        let modulated = self.auraBaseOpacity * (0.85 + 0.85 * clamped)
        return min(max(modulated, 0), 0.42)
    }
}

/// The overlay appearance settings resolved into one value.
struct OverlayAppearance: Equatable {
    let style: OverlayVisualStyle
    let theme: OverlayColorTheme
    let glow: OverlayGlowIntensity
    let showsTargetAppIcon: Bool
    let surface: OverlaySurfaceAppearance

    static let fallback = OverlayAppearance(
        style: .fallback,
        theme: .fallback,
        glow: .fallback,
        showsTargetAppIcon: true,
        surface: .fallback
    )

    var palette: OverlayPalette {
        self.theme.palette
    }

    /// Surface weights for the current system appearance.
    func surfaceStyle(systemIsDark: Bool) -> OverlaySurfaceStyle {
        OverlaySurfaceStyle.resolve(isLight: self.surface.resolvesToLight(systemIsDark: systemIsDark))
    }
}
