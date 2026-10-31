import Foundation

/// User-confirmed voice captures may contain correctly spelled words and phrases.
/// Only standalone grammatical basics require an explicit manual replacement.
@MainActor
enum VoiceTrainingAliasFilter {
    struct Result {
        let accepted: [String]
        let rejected: [String]

        @MainActor var rejectionMessage: String {
            let words = Set(self.rejected.prefix(20).map(VoiceTrainingAliasFilter.normalizedAlias))
                .intersection(VoiceTrainingAliasFilter.basicWords).sorted()
            guard !words.isEmpty else {
                return "No usable word was captured. Try recording again, or add a manual replacement."
            }
            let found = words.map { "“\($0)”" }.joined(separator: ", ")
            return "Replacement found these words: \(found). These single words are too broad to replace automatically. Add a manual replacement if intended."
        }
    }

    private static let basicWords: Set<String> = [
        "a", "an", "the", "there", "and", "or",
    ]

    private static func normalizedAlias(_ alias: String) -> String {
        alias.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    static func filter(_ aliases: [String], manuallyConfirmed: Set<String> = []) async -> Result {
        guard !Task.isCancelled else { return Result(accepted: [], rejected: aliases) }
        // Training already caps captures at twenty; bound this entry point independently.
        let accepted = aliases.prefix(20).filter { alias in
            guard !alias.isEmpty, alias.count <= 160 else { return false }
            if manuallyConfirmed.contains(alias) { return true }
            guard alias.contains(where: \.isLetter) else { return false }
            let normalized = self.normalizedAlias(alias)
            return !self.basicWords.contains(normalized)
        }
        let acceptedSet = Set(accepted)
        return Result(accepted: accepted, rejected: aliases.filter { !acceptedSet.contains($0) })
    }
}
