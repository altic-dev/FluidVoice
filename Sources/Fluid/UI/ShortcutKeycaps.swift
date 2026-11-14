import Foundation

/// Turns a shortcut's full name ("Left ⌘ + Left ⌥ + Left ⌃ + M") into the keycaps shown in a
/// shortcut field (["⌃", "⌥", "⌘", "M"]): modifiers first in the usual Mac order, the word
/// "Left" dropped from combinations, and hard-to-read keys spelled out.
enum ShortcutKeycaps {
    private static let modifierOrder = ["⌃", "⌥", "⇧", "⌘", "fn"]
    private static let spelledOut = [
        "`": "Backtick", "'": "Quote", ",": "Comma", ".": "Period", ";": "Semicolon",
        "Escape": "esc", "Delete": "delete", "Return": "return", "Space": "space", "Tab": "tab",
    ]

    static func caps(for displayString: String) -> [String] {
        let parts = displayString
            .components(separatedBy: " + ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return parts.map { self.spelledOut[$0] ?? $0 } }

        let trimmed = parts.map { $0.hasPrefix("Left ") ? String($0.dropFirst("Left ".count)) : $0 }
        let modifiers = trimmed.enumerated()
            .compactMap { index, part in self.modifierRank(part).map { (index, part, $0) } }
            .sorted { ($0.2, $0.0) < ($1.2, $1.0) }
            .map(\.1)
        let keys = trimmed.filter { self.modifierRank($0) == nil }.map { self.spelledOut[$0] ?? $0 }
        return modifiers + keys
    }

    /// Position of a modifier in the usual Mac order, or nil for a normal key.
    private static func modifierRank(_ part: String) -> Int? {
        let symbol = part.hasPrefix("Right ") ? String(part.dropFirst("Right ".count)) : part
        return self.modifierOrder.firstIndex(of: symbol)
    }
}
