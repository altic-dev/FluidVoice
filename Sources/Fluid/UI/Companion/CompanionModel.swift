//
//  CompanionModel.swift
//  Fluid
//
//  Settings model for the optional Companion: size, corner, presence, the
//  elemental variants and the accessory slots.
//

import SwiftUI

/// Fixed metrics shared by the Companion style and its settings.
nonisolated enum CompanionMetrics {
    /// Side of the Companion canvas at scale 1.0.
    ///
    /// This is the size the Companion used to reach at 200%: the reference look
    /// is now what "reset to 100%" gives, and the user can only grow from there.
    static let baseSide: CGFloat = 96
}

/// The elemental variants. Same soul, different material.
enum CompanionVariant: String, CaseIterable, Codable, Identifiable {
    case standard = "default"
    case fire
    case water
    case wind
    case earth
    case aurora
    case gothic

    static let fallback: CompanionVariant = .standard

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Default"
        case .fire: return "Fire"
        case .water: return "Water"
        case .wind: return "Wind"
        case .earth: return "Earth"
        case .aurora: return "Aurora"
        case .gothic: return "Gothic"
        }
    }

    var summary: String {
        switch self {
        case .standard: return "Balanced membranes in your theme colours"
        case .fire: return "Warm palette, pointed rising ribbons, rare embers"
        case .water: return "Cool fluid membranes, slower and rounder"
        case .wind: return "Thin quick ribbons and small fragments"
        case .earth: return "Stable green mass, calm and grounded"
        case .aurora: return "Flagship multilayer light"
        case .gothic: return "Dark plum body with crimson accents"
        }
    }

    /// Fixed palette for variants with their own identity. Default, Aurora and
    /// the theme-driven variants return nil and use the overlay theme palette, so
    /// the Companion reuses the colour engine instead of duplicating it.
    var fixedPalette: OverlayPalette? {
        switch self {
        case .standard, .aurora:
            return nil
        case .fire:
            return OverlayPalette(
                primary: Color(hex: "#FF4D2E") ?? .red,
                secondary: Color(hex: "#FF8A3D") ?? .orange,
                tertiary: Color(hex: "#FFC15E") ?? .yellow,
                highlight: Color(hex: "#FF3D7F") ?? .pink,
                accent: Color(hex: "#FFE0A3") ?? .yellow
            )
        case .water:
            return OverlayPalette(
                primary: Color(hex: "#1D4ED8") ?? .blue,
                secondary: Color(hex: "#38BDF8") ?? .cyan,
                tertiary: Color(hex: "#22D3EE") ?? .cyan,
                highlight: Color(hex: "#A5F3FC") ?? .cyan,
                accent: Color(hex: "#60A5FA") ?? .blue
            )
        case .wind:
            return OverlayPalette(
                primary: Color(hex: "#67E8F9") ?? .cyan,
                secondary: Color(hex: "#A5F3FC") ?? .cyan,
                tertiary: Color(hex: "#E0F7FF") ?? .white,
                highlight: Color(hex: "#FFFFFF") ?? .white,
                accent: Color(hex: "#BAE6FD") ?? .cyan
            )
        case .earth:
            return OverlayPalette(
                primary: Color(hex: "#166534") ?? .green,
                secondary: Color(hex: "#22C55E") ?? .green,
                tertiary: Color(hex: "#86EFAC") ?? .green,
                highlight: Color(hex: "#BEF264") ?? .green,
                accent: Color(hex: "#A3E635") ?? .green
            )
        case .gothic:
            return OverlayPalette(
                primary: Color(hex: "#6D28D9") ?? .purple,
                secondary: Color(hex: "#A21CAF") ?? .purple,
                tertiary: Color(hex: "#E11D48") ?? .red,
                highlight: Color(hex: "#FB7185") ?? .pink,
                accent: Color(hex: "#F43F5E") ?? .pink
            )
        }
    }

    var tuning: CompanionTuning {
        switch self {
        case .standard:
            return CompanionTuning(membraneCount: 3, speed: 1.0, sharpness: 0.50, rise: 0.00,
                                   flutter: 0.16, wobble: 0.34, coreGlow: 0.32, emberCount: 0, emberWarmth: 0.5)
        case .fire:
            return CompanionTuning(membraneCount: 3, speed: 1.45, sharpness: 0.86, rise: 0.34,
                                   flutter: 0.34, wobble: 0.44, coreGlow: 0.46, emberCount: 5, emberWarmth: 1.0)
        case .water:
            return CompanionTuning(membraneCount: 3, speed: 0.70, sharpness: 0.24, rise: -0.05,
                                   flutter: 0.18, wobble: 0.56, coreGlow: 0.36, emberCount: 2, emberWarmth: 0.15)
        case .wind:
            return CompanionTuning(membraneCount: 4, speed: 1.60, sharpness: 0.95, rise: 0.10,
                                   flutter: 0.30, wobble: 0.60, coreGlow: 0.20, emberCount: 0, emberWarmth: 0.0)
        case .earth:
            return CompanionTuning(membraneCount: 2, speed: 0.50, sharpness: 0.16, rise: -0.10,
                                   flutter: 0.10, wobble: 0.28, coreGlow: 0.26, emberCount: 0, emberWarmth: 0.3)
        case .aurora:
            return CompanionTuning(membraneCount: 4, speed: 0.95, sharpness: 0.55, rise: 0.05,
                                   flutter: 0.22, wobble: 0.50, coreGlow: 0.50, emberCount: 2, emberWarmth: 0.7)
        case .gothic:
            return CompanionTuning(membraneCount: 3, speed: 0.85, sharpness: 0.68, rise: 0.02,
                                   flutter: 0.18, wobble: 0.40, coreGlow: 0.52, emberCount: 3, emberWarmth: 0.9)
        }
    }

    func palette(themePalette: OverlayPalette) -> OverlayPalette {
        self.fixedPalette ?? themePalette
    }
}

/// How the membranes and the core behave for one variant.
///
/// Kept as plain values on purpose: the seven variants share one parametric
/// engine, so there is no separate drawing path per element.
struct CompanionTuning: Equatable {
    var membraneCount: Int
    var speed: CGFloat
    /// Lower values are rounder, higher values narrower and more pointed.
    var sharpness: CGFloat
    /// Positive values lift the ribbons; Fire uses this for rising energy.
    var rise: CGFloat
    /// High frequency trembling.
    var flutter: CGFloat
    /// Low frequency radius modulation.
    var wobble: CGFloat
    var coreGlow: CGFloat
    var emberCount: Int
    /// 0 = cool sparks, 1 = warm sparks.
    var emberWarmth: CGFloat
}

/// Where an accessory is attached.
enum CompanionAccessorySlot: String, CaseIterable, Codable, Identifiable {
    case head
    case face
    case body
    case aura

    var id: String { self.rawValue }
}

/// The small free local customisation set.
enum CompanionAccessory: String, CaseIterable, Codable, Identifiable {
    case hat
    case glasses
    case scarf
    case halo

    static let fallback: Set<CompanionAccessory> = []

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .hat: return "Hat"
        case .glasses: return "Glasses"
        case .scarf: return "Scarf"
        case .halo: return "Halo"
        }
    }

    var slot: CompanionAccessorySlot {
        switch self {
        case .hat: return .head
        case .glasses: return .face
        case .scarf: return .body
        case .halo: return .aura
        }
    }
}

/// How much movement the overlays and the companion are allowed.
enum MotionIntensity: String, CaseIterable, Codable, Identifiable {
    case subtle
    case normal
    case expressive

    static let fallback: MotionIntensity = .normal

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .subtle: return "Subtle"
        case .normal: return "Normal"
        case .expressive: return "Expressive"
        }
    }

    /// Multiplier applied to membrane travel and to the audio reaction.
    var scale: CGFloat {
        switch self {
        case .subtle: return 0.55
        case .normal: return 1.0
        case .expressive: return 1.5
        }
    }
}

/// The state the companion is expressing.
///
/// Derived only from signals the dictation pipeline already publishes, so the
/// companion can never add a new source of truth (or a new audio path).
enum CompanionState: String, CaseIterable, Codable {
    case idle
    case listening
    case thinking
    case typing
    case completed
    case error

    static func resolve(
        isPresented: Bool,
        isProcessing: Bool,
        didComplete: Bool,
        hasFailure: Bool,
        hasTranscription: Bool
    ) -> CompanionState {
        if hasFailure { return .error }
        if didComplete { return .completed }
        if isProcessing { return .thinking }
        if isPresented { return hasTranscription ? .typing : .listening }
        return .idle
    }
}
