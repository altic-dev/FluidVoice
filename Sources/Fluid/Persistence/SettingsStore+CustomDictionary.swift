import Foundation

extension SettingsStore {
    /// A custom dictionary entry that maps multiple misheard/alternate spellings to a correct replacement.
    /// For example: ["fluid voice", "fluid boys"] -> "FluidVoice"
    struct CustomDictionaryEntry: Codable, Identifiable, Hashable {
        let id: UUID
        /// Words/phrases to look for (case-insensitive matching)
        var triggers: [String]
        /// The correct replacement text
        var replacement: String

        init(triggers: [String], replacement: String) {
            self.id = UUID()
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }

        init(id: UUID, triggers: [String], replacement: String) {
            self.id = id
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }
    }

    enum AutoLearnSuggestionStatus: String, Codable, Hashable {
        case pending
        case dismissed
    }

    struct AutoLearnSuggestion: Codable, Identifiable, Hashable {
        let id: UUID
        var originalText: String
        var replacement: String
        var occurrences: Int
        var lastObservedAt: Date
        var status: AutoLearnSuggestionStatus
        var dismissedAtOccurrenceCount: Int?

        init(
            id: UUID = UUID(),
            originalText: String,
            replacement: String,
            occurrences: Int = 1,
            lastObservedAt: Date = Date(),
            status: AutoLearnSuggestionStatus = .pending,
            dismissedAtOccurrenceCount: Int? = nil
        ) {
            self.id = id
            self.originalText = originalText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            self.occurrences = occurrences
            self.lastObservedAt = lastObservedAt
            self.status = status
            self.dismissedAtOccurrenceCount = dismissedAtOccurrenceCount
        }
    }
}

extension Notification.Name {
    static let autoLearnSuggestionsDidChange = Notification.Name("AutoLearnSuggestionsDidChange")
}
