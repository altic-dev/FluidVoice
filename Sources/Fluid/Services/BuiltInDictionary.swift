import Foundation

/// Spellings shipped with the app and applied by the text dictionary layer. They do not appear in
/// the Custom Dictionary list and cannot be edited or removed. A user entry with the same spelling
/// always takes precedence.
nonisolated enum BuiltInDictionary {
    static let entries: [SettingsStore.CustomDictionaryEntry] = [
        .init(triggers: ["claud", "clawed"], replacement: "Claude"),
        .init(triggers: ["post hoc"], replacement: "PostHog"),
        .init(triggers: ["huggingface", "hugging face"], replacement: "Hugging Face"),
        .init(triggers: ["fluid voice"], replacement: "FluidVoice"),
    ]

    /// Built-in entries without any spelling the user already maps, so the user's choice wins.
    static func entries(excludingSpellingsIn userEntries: [SettingsStore.CustomDictionaryEntry]) -> [SettingsStore.CustomDictionaryEntry] {
        let taken = Set(userEntries.flatMap(\.triggers).map { $0.lowercased() })
        return self.entries.compactMap { entry in
            let triggers = entry.triggers.filter { !taken.contains($0) }
            return triggers.isEmpty ? nil : SettingsStore.CustomDictionaryEntry(id: entry.id, triggers: triggers, replacement: entry.replacement)
        }
    }
}
