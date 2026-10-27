import Foundation

/// Original corrections provide both text and acoustic evidence for the same intended spelling.
/// These conservative thresholds are evaluated separately from the legacy three-recording preview.
nonisolated enum DictionaryPronunciationDecision {
    static func accepts(score: Float, heardText: String, profile: PronunciationDictionaryProfile) -> Bool {
        guard score.isFinite else { return false }
        return score >= self.requiredScore(heardText: heardText, profile: profile)
    }

    static func requiredScore(heardText: String, profile: PronunciationDictionaryProfile) -> Float {
        if let threshold = self.overrideThreshold(profile) { return threshold }
        guard profile.hasOriginalAudio else { return 0.70 }
        let heard = self.normalized(heardText)
        let knownVariant = profile.enrollments.contains {
            $0.observedText.map(self.normalized) == heard
        }
        return knownVariant ? 0.70 : 0.85
    }

    static func overrideThreshold(_ profile: PronunciationDictionaryProfile) -> Float? {
        guard let value = profile.matchThreshold, value.isFinite, (0.4...0.95).contains(value) else { return nil }
        return value
    }

    static func minimumSearchScore(profiles: [PronunciationDictionaryProfile]) -> Float {
        profiles.reduce(Float(0.70)) { min($0, self.overrideThreshold($1) ?? 0.70) }
    }

    /// A new spoken possessive is still the enrolled name. Preserve its grammatical ending,
    /// unless a recorded correction explicitly taught a possessive-to-nonpossessive replacement.
    static func labelPreservingPossessive(
        _ label: String, heardText: String, profile: PronunciationDictionaryProfile
    ) -> String {
        guard profile.hasOriginalAudio,
              let last = label.last, last.isLetter || last.isNumber,
              let suffix = self.possessiveSuffix(heardText),
              self.possessiveSuffix(label) == nil,
              !profile.enrollments.contains(where: {
                  $0.observedText.map { self.possessiveSuffix($0) != nil } ?? false
              })
        else { return label }
        return label + suffix
    }

    private static func possessiveSuffix(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard trimmed.lowercased().hasSuffix("'s") || trimmed.lowercased().hasSuffix("’s") else { return nil }
        return String(trimmed.suffix(2))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}
