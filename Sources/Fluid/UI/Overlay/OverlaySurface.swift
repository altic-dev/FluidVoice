//
//  OverlaySurface.swift
//  Fluid
//
//  Surface appearance (dark / light) and the custom theme derivation.
//

import AppKit
import SwiftUI

/// Which surface the overlay is drawn on.
///
/// Automatic follows the system appearance; Dark and Light force one. The
/// visualizer keeps its saturated palette in both cases - only the surface and
/// the foreground weights move, so a light overlay stays a light *glass*, never
/// a clinical white card.
enum OverlaySurfaceAppearance: String, CaseIterable, Codable, Identifiable {
    case automatic
    case dark
    case light

    static let fallback: OverlaySurfaceAppearance = .automatic

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    /// Resolves the effective surface for the current system appearance.
    func resolvesToLight(systemIsDark: Bool) -> Bool {
        switch self {
        case .automatic: return !systemIsDark
        case .dark: return false
        case .light: return true
        }
    }
}

/// Resolved surface colours and weights.
///
/// Kept separate from `OverlayPalette` on purpose: the palette describes the
/// light the overlay *emits*, this describes the surface it sits on.
struct OverlaySurfaceStyle: Equatable {
    let isLight: Bool
    /// Opaque-ish surface colour. The caller applies its own translucency.
    let fill: Color
    let primaryText: Color
    let secondaryText: Color
    let shadowOpacity: Double
    let sheenOpacity: Double
    /// Border and hairline opacity multiplier: hairlines need more contrast on a
    /// light surface to stay visible.
    let borderScale: Double
    /// True when there is no surface at all and the desktop shows through.
    ///
    /// Monochrome styles cannot pick a neutral that works on both a light and a
    /// dark desktop, so in this case they fall back to the theme's brightest hue
    /// instead of chasing the system appearance.
    var isChromeless: Bool = false

    static let dark = OverlaySurfaceStyle(
        isLight: false,
        fill: Color(hex: "#07080A") ?? Color.black,
        primaryText: Color.white.opacity(0.90),
        secondaryText: Color.white.opacity(0.62),
        shadowOpacity: 0.32,
        sheenOpacity: 0.055,
        borderScale: 1.0
    )

    static let light = OverlaySurfaceStyle(
        isLight: true,
        // Very light grey rather than white: the pill should read as frosted
        // glass over the user's window, not as a blank card.
        fill: Color(hex: "#E7E9EE") ?? Color(white: 0.91),
        primaryText: Color.black.opacity(0.86),
        secondaryText: Color.black.opacity(0.55),
        shadowOpacity: 0.18,
        sheenOpacity: 0.42,
        borderScale: 1.45
    )

    /// Used by the chromeless format, where the underlying pixels are unknown.
    static let chromeless = OverlaySurfaceStyle(
        isLight: false,
        fill: Color.clear,
        primaryText: Color.white.opacity(0.92),
        secondaryText: Color.white.opacity(0.62),
        shadowOpacity: 0,
        sheenOpacity: 0,
        borderScale: 1.0,
        isChromeless: true
    )

    static func resolve(isLight: Bool) -> OverlaySurfaceStyle {
        isLight ? .light : .dark
    }
}

/// Hex of the user-chosen primary colour for the Custom theme.
///
/// Held as a small mirror so the overlay components can resolve a palette
/// without depending on the full settings store. `SettingsStore` keeps it in
/// sync whenever the preference is read or written.
enum OverlayCustomTheme {
    static let defaultHex = "#8B5CF6"
    nonisolated(unsafe) static var hex: String = OverlayCustomTheme.defaultHex
}

extension OverlayPalette {
    /// Builds a harmonious four-colour palette from a single primary colour.
    ///
    /// The user picks one colour and the variations are derived in HSB, so the
    /// result keeps the same hue family instead of asking for four choices.
    static func derive(fromHex hex: String) -> OverlayPalette? {
        guard let base = NSColor(hex: hex) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard s > 0 || b > 0 else { return nil }

        func shifted(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> Color {
            var newHue = h + hue
            newHue -= floor(newHue) // wrap into 0 ..< 1
            let color = NSColor(
                hue: newHue,
                saturation: min(max(s * saturation, 0), 1),
                brightness: min(max(b * brightness, 0), 1),
                alpha: 1
            )
            return Color(nsColor: color)
        }

        return OverlayPalette(
            primary: shifted(hue: 0.00, saturation: 1.00, brightness: 0.82),
            secondary: shifted(hue: 0.06, saturation: 0.98, brightness: 1.06),
            tertiary: shifted(hue: 0.14, saturation: 0.82, brightness: 1.20),
            // A brighter neighbour on the warm side of the wheel. Without it a
            // Custom theme would render every Aurora layer from the same narrow
            // hue band and lose the multilayer read.
            highlight: shifted(hue: 0.10, saturation: 1.02, brightness: 1.16),
            // Opposite side of the wheel for a warm counterpoint, kept saturated
            // so it stays a minority accent rather than a muddy tint.
            accent: shifted(hue: -0.09, saturation: 1.05, brightness: 1.12)
        )
    }
}

extension Color {
    /// `#RRGGBB` for the current colour, used to persist the Custom theme.
    var overlayHexString: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return OverlayCustomTheme.defaultHex }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private extension NSColor {
    /// sRGB initialiser for a `#RRGGBB` string.
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "#", with: "")
        guard value.count == 6 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: value).scanHexInt64(&rgb) else { return nil }
        self.init(
            srgbRed: CGFloat((rgb & 0xFF0000) >> 16) / 255,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255,
            blue: CGFloat(rgb & 0x0000FF) / 255,
            alpha: 1
        )
    }
}
