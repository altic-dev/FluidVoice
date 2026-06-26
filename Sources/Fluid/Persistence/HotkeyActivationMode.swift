import Foundation

enum HotkeyActivationMode: String, Codable, CaseIterable, Identifiable {
    case toggle, hold, automatic

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .toggle: return "Toggle"
        case .hold: return "Hold"
        case .automatic: return "Automatic (Both)"
        }
    }

    var description: String {
        switch self {
        case .toggle: return "Tap once to start, tap again to stop."
        case .hold: return "Record only while the shortcut is held."
        case .automatic: return "Tap to toggle, hold for push-to-talk."
        }
    }
}
