import Foundation

enum CorrectionDiffEngine {
    struct Candidate: Equatable {
        let original: String
        let replacement: String
    }

    private struct DiffToken: Equatable {
        let text: String

        var matchKey: String {
            self.text.lowercased()
        }
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
        originalSegment: [DiffToken],
        editedSegment: [DiffToken],
        maxSegmentTokenCount: Int
    ) -> Candidate? {
        guard !originalSegment.isEmpty, !editedSegment.isEmpty else { return nil }
        guard originalSegment.count <= maxSegmentTokenCount, editedSegment.count <= maxSegmentTokenCount else { return nil }

        let originalPhrase = originalSegment.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let editedPhrase = editedSegment.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !originalPhrase.isEmpty, !editedPhrase.isEmpty else { return nil }
        guard originalPhrase.caseInsensitiveCompare(editedPhrase) != .orderedSame else { return nil }

        return Candidate(original: originalPhrase, replacement: editedPhrase)
    }

    private static func buildCaseOnlyCandidate(originalToken: DiffToken, editedToken: DiffToken) -> Candidate? {
        guard originalToken.text != editedToken.text else { return nil }
        guard originalToken.text.caseInsensitiveCompare(editedToken.text) == .orderedSame else { return nil }
        return Candidate(original: originalToken.text, replacement: editedToken.text)
    }

    private static func lcsIndexPairs(_ lhs: [DiffToken], _ rhs: [DiffToken]) -> [(Int, Int)] {
        let lhsCount = lhs.count
        let rhsCount = rhs.count
        guard lhsCount > 0, rhsCount > 0 else { return [] }

        var dp = Array(
            repeating: Array(repeating: 0, count: rhsCount + 1),
            count: lhsCount + 1
        )

        for lhsIndex in 1...lhsCount {
            for rhsIndex in 1...rhsCount {
                if lhs[lhsIndex - 1].matchKey == rhs[rhsIndex - 1].matchKey {
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
            if lhs[lhsIndex - 1].matchKey == rhs[rhsIndex - 1].matchKey {
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

    private nonisolated static func tokenize(_ text: String) -> [DiffToken] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map(Self.tokenText)
            .filter { !$0.isEmpty }
            .map(DiffToken.init(text:))
    }

    private nonisolated static func tokenText(_ rawToken: String) -> String {
        let characters = Array(rawToken.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !characters.isEmpty else { return "" }

        var startIndex = 0
        var endIndex = characters.count

        while startIndex < endIndex,
              Self.shouldTrimLeading(characters[startIndex], in: characters, at: startIndex, endIndex: endIndex) {
            startIndex += 1
        }

        while endIndex > startIndex,
              Self.shouldTrimTrailing(characters[endIndex - 1], in: characters, startIndex: startIndex, at: endIndex - 1) {
            endIndex -= 1
        }

        guard startIndex < endIndex else { return "" }
        return String(characters[startIndex..<endIndex])
    }

    private nonisolated static func shouldTrimLeading(
        _ character: Character,
        in characters: [Character],
        at index: Int,
        endIndex: Int
    ) -> Bool {
        guard Self.isPunctuation(character) else { return false }
        guard Self.isTechnicalLeadingEdge(character),
              index + 1 < endIndex,
              characters[index + 1].isLetter || characters[index + 1].isNumber
        else {
            return true
        }

        return false
    }

    private nonisolated static func shouldTrimTrailing(
        _ character: Character,
        in characters: [Character],
        startIndex: Int,
        at index: Int
    ) -> Bool {
        guard Self.isPunctuation(character) else { return false }
        guard Self.isTechnicalTrailingEdge(character),
              index > startIndex,
              characters[index - 1].isLetter || characters[index - 1].isNumber || Self.isTechnicalTrailingEdge(characters[index - 1])
        else {
            return true
        }

        return false
    }

    private nonisolated static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    private nonisolated static func isTechnicalLeadingEdge(_ character: Character) -> Bool {
        ".+$#".contains(character)
    }

    private nonisolated static func isTechnicalTrailingEdge(_ character: Character) -> Bool {
        "+#%".contains(character)
    }
}
