import Foundation

/// Flags a microphone turn as remote audio picked up through speaker bleed.
nonisolated enum MeetingEchoDetector {
    static let minimumMicWords = 4
    static let minimumMatchedContentWords = 2
    /// Measured on one real call: echo 0.65-1.00 at any length, non-echo 0.00-0.33.
    static let containmentThreshold = 0.5

    /// Below this the ratio quantises too coarsely to trust a partial hit; demand a total match.
    static let minimumContentWordsForPartialMatch = 4

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "so", "to", "of", "in", "on", "it", "is",
        "was", "i", "you", "we", "they", "that", "this", "like", "just", "know", "yeah",
        "ok", "okay", "right", "mean", "my", "me",
    ]

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func contentWords(_ text: String) -> Set<String> {
        Set(self.normalizedWords(text).filter { !self.stopwords.contains($0) })
    }

    /// Containment, not Jaccard: Jaccard punishes echo's length mismatch (real pair scored 0.17).
    static func containment(micText: String, remoteText: String) -> Double {
        let micWords = self.contentWords(micText)
        guard !micWords.isEmpty else { return 0 }
        let remoteWords = self.contentWords(remoteText)
        guard !remoteWords.isEmpty else { return 0 }
        return Double(micWords.intersection(remoteWords).count) / Double(micWords.count)
    }

    static func isLikelyEcho(micText: String, remoteText: String) -> Bool {
        guard self.normalizedWords(micText).count >= self.minimumMicWords else { return false }
        let matchedContentWords = self.contentWords(micText).intersection(self.contentWords(remoteText)).count
        guard matchedContentWords >= self.minimumMatchedContentWords else { return false }
        let score = self.containment(micText: micText, remoteText: remoteText)
        if self.contentWords(micText).count < self.minimumContentWordsForPartialMatch {
            return score >= 1
        }
        return score >= self.containmentThreshold
    }
}
