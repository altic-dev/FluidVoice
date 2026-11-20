import Foundation

/// Separate from key bindings: changing send behavior must not rebind or stop a hotkey.
struct DictationAutoSendPreferences {
    static let key = "AutoSendDictationShortcuts"
    let defaults: UserDefaults

    var shortcuts: [HotkeyShortcut] {
        get {
            guard let data = self.defaults.data(forKey: Self.key),
                  let value = try? JSONDecoder().decode([HotkeyShortcut].self, from: data)
            else { return [] }
            return value
        }
        nonmutating set {
            var unique: [HotkeyShortcut] = []
            for shortcut in newValue where !unique.contains(shortcut) {
                unique.append(shortcut)
            }
            guard let data = try? JSONEncoder().encode(unique) else { return }
            self.defaults.set(data, forKey: Self.key)
        }
    }

    func isEnabled(for shortcut: HotkeyShortcut?) -> Bool {
        guard let shortcut else { return false }
        return self.shortcuts.contains(shortcut)
    }

    func retain(_ configured: [HotkeyShortcut]) {
        let previous = self.shortcuts
        let retained = previous.filter { configured.contains($0) }
        if retained != previous { self.shortcuts = retained }
    }
}

/// Auto-send never submits an existing draft when no new dictation was produced.
enum DictationAutoSendPolicy {
    static let sendDelay: TimeInterval = 1

    static func shouldSend(enabled: Bool, route: ContentView.DictationOutputRoute, cancelled: Bool, text: String) -> Bool {
        enabled && route == .normal && !cancelled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
