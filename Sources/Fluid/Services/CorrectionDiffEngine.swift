import Foundation

enum CorrectionDiffEngine {
    struct Candidate: Equatable {
        let original: String
        let replacement: String
    }

    static func findCorrectionCandidates(
        original: String,
        edited: String,
        maxSegmentTokenCount: Int = 3
    ) -> [Candidate] {
        let originalTokens = tokenize(original)
        let editedTokens = tokenize(edited)
        guard !originalTokens.isEmpty, !editedTokens.isEmpty else { return [] }

        // Guard against quadratic DP blow-up. The LCS matrix is O(n*m) in
        // both time and memory. 500 tokens is generous for a dictation segment;
        // anything larger would stall the main queue for no meaningful gain.
        let maxTokenCount = 500
        guard originalTokens.count <= maxTokenCount, editedTokens.count <= maxTokenCount else { return [] }

        let anchorPairs = lcsIndexPairs(originalTokens, editedTokens)
        var candidates: [Candidate] = []
        var originalIndex = 0
        var editedIndex = 0

        for (anchorOriginal, anchorEdited) in anchorPairs {
            let originalSegment = Array(originalTokens[originalIndex..<anchorOriginal])
            let editedSegment = Array(editedTokens[editedIndex..<anchorEdited])
            if let candidate = buildCandidate(
                originalSegment: originalSegment,
                editedSegment: editedSegment,
                maxSegmentTokenCount: maxSegmentTokenCount
            ) {
                candidates.append(candidate)
            }

            if let candidate = buildCaseOnlyCandidate(
                originalToken: originalTokens[anchorOriginal],
                editedToken: editedTokens[anchorEdited]
            ) {
                candidates.append(candidate)
            }

            originalIndex = anchorOriginal + 1
            editedIndex = anchorEdited + 1
        }

        let originalTail = originalIndex < originalTokens.count ? Array(originalTokens[originalIndex...]) : []
        let editedTail = editedIndex < editedTokens.count ? Array(editedTokens[editedIndex...]) : []
        if let candidate = buildCandidate(
            originalSegment: originalTail,
            editedSegment: editedTail,
            maxSegmentTokenCount: maxSegmentTokenCount
        ) {
            candidates.append(candidate)
        }

        return candidates
    }

    private static func buildCandidate(
        originalSegment: [String],
        editedSegment: [String],
        maxSegmentTokenCount: Int
    ) -> Candidate? {
        guard !originalSegment.isEmpty, !editedSegment.isEmpty else { return nil }
        guard originalSegment.count <= maxSegmentTokenCount, editedSegment.count <= maxSegmentTokenCount else { return nil }

        let originalPhrase = originalSegment.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let editedPhrase = editedSegment.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !originalPhrase.isEmpty, !editedPhrase.isEmpty else { return nil }
        guard originalPhrase.caseInsensitiveCompare(editedPhrase) != .orderedSame else { return nil }

        return Candidate(original: originalPhrase, replacement: editedPhrase)
    }

    private static func buildCaseOnlyCandidate(originalToken: String, editedToken: String) -> Candidate? {
        guard originalToken != editedToken else { return nil }
        guard originalToken.caseInsensitiveCompare(editedToken) == .orderedSame else { return nil }
        return Candidate(original: originalToken, replacement: editedToken)
    }

    private static func lcsIndexPairs(_ lhs: [String], _ rhs: [String]) -> [(Int, Int)] {
        let lhsCount = lhs.count
        let rhsCount = rhs.count
        guard lhsCount > 0, rhsCount > 0 else { return [] }

        var dp = Array(
            repeating: Array(repeating: 0, count: rhsCount + 1),
            count: lhsCount + 1
        )

        for lhsIndex in 1...lhsCount {
            for rhsIndex in 1...rhsCount {
                if lhs[lhsIndex - 1].lowercased() == rhs[rhsIndex - 1].lowercased() {
                    dp[lhsIndex][rhsIndex] = dp[lhsIndex - 1][rhsIndex - 1] + 1
                } else {
                    dp[lhsIndex][rhsIndex] = max(dp[lhsIndex - 1][rhsIndex], dp[lhsIndex][rhsIndex - 1])
                }
            }
        }

        var pairs: [(Int, Int)] = []
        var lhsIndex = lhsCount
        var rhsIndex = rhsCount

        while lhsIndex > 0 && rhsIndex > 0 {
            if lhs[lhsIndex - 1].lowercased() == rhs[rhsIndex - 1].lowercased() {
                pairs.append((lhsIndex - 1, rhsIndex - 1))
                lhsIndex -= 1
                rhsIndex -= 1
            } else if dp[lhsIndex - 1][rhsIndex] > dp[lhsIndex][rhsIndex - 1] {
                lhsIndex -= 1
            } else {
                rhsIndex -= 1
            }
        }

        return pairs.reversed()
    }

    private static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
