import AppKit
import SwiftUI

/// The three soft colors the look's few hues come from: the sky behind a page and the aura on the
/// one card a page leads with. They follow the accent color setting. Each preset has a hand-picked set,
/// a custom color gets three soft shades around its hue, and a grey custom color keeps the look
/// colorless. The look decides how strongly each place shows them.
struct FluidLookTint: Equatable {
    let start: Color
    let middle: Color
    let end: Color

    var colors: [Color] { [self.start, self.middle, self.end] }

    /// fluidvoice.com's own sky, violet and pink.
    static let fluid = FluidLookTint(start: rgb(0x38bdf8), middle: rgb(0xa78bfa), end: rgb(0xf0abfc))

    static func preset(_ option: SettingsStore.AccentColorOption) -> FluidLookTint {
        switch option {
        case .cyan: FluidLookTint(start: self.rgb(0x5eead4), middle: self.rgb(0x38bdf8), end: self.rgb(0xa78bfa))
        case .green: FluidLookTint(start: self.rgb(0x86efac), middle: self.rgb(0x5eead4), end: self.rgb(0x7dd3fc))
        case .blue: .fluid
        case .purple: FluidLookTint(start: self.rgb(0xa78bfa), middle: self.rgb(0xf0abfc), end: self.rgb(0xfda4af))
        case .orange: FluidLookTint(start: self.rgb(0xfcd34d), middle: self.rgb(0xfdba74), end: self.rgb(0xf9a8d4))
        }
    }

    /// Three soft shades stepping warmer around a custom color's hue. A nearly grey color gives
    /// soft greys, so picking white or grey turns the look's color off.
    static func around(_ accent: Color) -> FluidLookTint {
        guard let hsb = HSB(accent), hsb.saturation >= 0.12 else {
            return FluidLookTint(start: Color(white: 0.78), middle: Color(white: 0.86), end: Color(white: 0.94))
        }
        return FluidLookTint(
            start: hsb.shifted(hue: -0.09, saturation: min(hsb.saturation, 0.7), brightness: 0.97),
            middle: hsb.shifted(hue: 0, saturation: min(hsb.saturation, 0.55), brightness: 0.98),
            end: hsb.shifted(hue: 0.08, saturation: min(hsb.saturation, 0.4), brightness: 0.99)
        )
    }

    /// The tint for the current accent color setting.
    static func current(_ settings: SettingsStore) -> FluidLookTint {
        settings.customAccentColorHex.flatMap { Color(hex: $0) }.map(self.around) ?? .preset(settings.accentColorOption)
    }

    /// Each color with its saturation and brightness changed, keeping its hue.
    func map(saturation: (Double) -> Double, brightness: (Double) -> Double) -> FluidLookTint {
        func shade(_ color: Color) -> Color {
            guard let hsb = HSB(color) else { return color }
            return hsb.shifted(hue: 0, saturation: saturation(hsb.saturation), brightness: brightness(hsb.brightness))
        }
        return FluidLookTint(start: shade(self.start), middle: shade(self.middle), end: shade(self.end))
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

/// A color's hue, saturation and brightness, read once in sRGB.
struct HSB {
    let hue: Double
    let saturation: Double
    let brightness: Double

    init?(_ color: Color) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        self.hue = Double(hue)
        self.saturation = Double(saturation)
        self.brightness = Double(brightness)
    }

    func shifted(hue shift: Double, saturation: Double, brightness: Double) -> Color {
        let hue = self.hue + shift
        return Color(
            hue: hue - hue.rounded(.down),
            saturation: min(1, max(0, saturation)),
            brightness: min(1, max(0, brightness))
        )
    }
}
