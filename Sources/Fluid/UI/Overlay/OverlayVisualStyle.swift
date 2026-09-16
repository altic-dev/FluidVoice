//
//  OverlayVisualStyle.swift
//  Fluid
//
//  Visual styles available to the floating recording overlay.
//

import SwiftUI

/// The visual treatment used to draw live audio feedback inside the recording overlay.
///
/// A style only changes how the microphone level the ASR engine already publishes
/// is *rendered*. It never changes when audio is captured, when the engine starts
/// or stops, or when transcribed text is injected.
enum OverlayVisualStyle: String, CaseIterable, Codable, Identifiable {
    case minimal
    case aurora
    case wave
    case pulse
    /// The animated Companion character. It is a style, so it works in every
    /// format and follows the theme colours like the others.
    case companion

    /// Used whenever a persisted or imported value cannot be resolved.
    static let fallback: OverlayVisualStyle = .aurora

    var id: String {
        self.rawValue
    }

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .aurora: return "Aurora"
        case .wave: return "Wave"
        case .pulse: return "Pulse"
        case .companion: return "Companion"
        }
    }

    var summary: String {
        switch self {
        case .minimal: return "Sober monochrome level meter"
        case .aurora: return "Organic light ribbon with an orbital aura"
        case .wave: return "Symmetric waveform around the center line"
        case .pulse: return "Calm ring that breathes with your voice"
        case .companion: return "Animated companion that reacts to your voice"
        }
    }
}
