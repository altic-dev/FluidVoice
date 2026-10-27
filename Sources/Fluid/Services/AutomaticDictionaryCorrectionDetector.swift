import Foundation

struct AutomaticDictionaryCorrectionCandidate: Equatable, Identifiable {
    let id = UUID()
    let heardText: String
    let correctedText: String
    var sourceUTF16Range: NSRange?
    var audioEvidence: DictionaryLearningAudioEvidence?
    var negativeCorrection: DictionaryNegativeCorrection?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.heardText == rhs.heardText && lhs.correctedText == rhs.correctedText
            && lhs.sourceUTF16Range == rhs.sourceUTF16Range
    }
}

struct AutomaticDictionaryTextChange: Equatable {
    let oldRange: NSRange
    let newRange: NSRange
}

enum AutomaticDictionaryCorrectionDetector {
    private static let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: ".,!?;:\"“”‘’()[]{}")
    )
    private static let boundaryCharacters = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: ",!?;:\"“”()[]{}<>")
    )
    private static let maxCandidateLength = 40
    private static let maxCombinedLength = 70

    static func textChange(before: String, after: String) -> AutomaticDictionaryTextChange? {
        guard before != after else { return nil }

        let oldText = before as NSString
        let newText = after as NSString
        let sharedLength = min(oldText.length, newText.length)
        var prefixLength = 0

        while prefixLength < sharedLength,
              oldText.character(at: prefixLength) == newText.character(at: prefixLength)
        {
            prefixLength += 1
        }

        var suffixLength = 0
        let oldRemaining = oldText.length - prefixLength
        let newRemaining = newText.length - prefixLength
        while suffixLength < min(oldRemaining, newRemaining),
              oldText.character(at: oldText.length - suffixLength - 1) ==
              newText.character(at: newText.length - suffixLength - 1)
        {
            suffixLength += 1
        }

        return AutomaticDictionaryTextChange(
            oldRange: NSRange(
                location: prefixLength,
                length: oldText.length - prefixLength - suffixLength
            ),
            newRange: NSRange(
                location: prefixLength,
                length: newText.length - prefixLength - suffixLength
            )
        )
    }

    static func isChangeInsideInsertedRange(
        _ change: AutomaticDictionaryTextChange,
        insertedRange: NSRange,
        allowsInsertionAtEnd: Bool = false
    ) -> Bool {
        guard insertedRange.location != NSNotFound, insertedRange.length > 0 else { return false }
        let insertedEnd = NSMaxRange(insertedRange)

        if change.oldRange.length == 0 {
            return change.oldRange.location >= insertedRange.location &&
                (change.oldRange.location < insertedEnd ||
                    (allowsInsertionAtEnd && change.oldRange.location == insertedEnd))
        }

        return change.oldRange.location >= insertedRange.location &&
            NSMaxRange(change.oldRange) <= insertedEnd
    }

    static func candidate(
        before: String,
        after: String,
        insertedRange: NSRange,
        allowsInsertionAtEnd: Bool = false
    ) -> AutomaticDictionaryCorrectionCandidate? {
        guard let change = self.textChange(before: before, after: after),
              self.isChangeInsideInsertedRange(
                  change,
                  insertedRange: insertedRange,
                  allowsInsertionAtEnd: allowsInsertionAtEnd
              )
        else {
            return nil
        }

        let oldTokenRange = self.expandedTokenRange(in: before, around: change.oldRange)
        let newTokenRange = self.expandedTokenRange(in: after, around: change.newRange)
        guard oldTokenRange.location >= insertedRange.location,
              NSMaxRange(oldTokenRange) <= NSMaxRange(insertedRange)
        else {
            return nil
        }

        let heard = self.cleanedCandidate((before as NSString).substring(with: oldTokenRange))
        let corrected = self.cleanedCandidate((after as NSString).substring(with: newTokenRange))
        guard self.isValidCandidate(heard),
              self.isValidCandidate(corrected),
              self.isMeaningfulCorrection(heard: heard, corrected: corrected),
              DictionaryCorrectionEditPolicy.allows(heard: heard, corrected: corrected),
              heard != corrected,
              heard.count + corrected.count <= self.maxCombinedLength
        else {
            return nil
        }

        return AutomaticDictionaryCorrectionCandidate(
            heardText: heard,
            correctedText: corrected,
            sourceUTF16Range: NSRange(location: oldTokenRange.location - insertedRange.location, length: oldTokenRange.length)
        )
    }

    static func isWordContinuationAtInsertedRangeEnd(
        _ change: AutomaticDictionaryTextChange,
        after: String,
        insertedRange: NSRange
    ) -> Bool {
        guard change.oldRange.length == 0,
              change.oldRange.location == NSMaxRange(insertedRange),
              NSMaxRange(change.newRange) <= (after as NSString).length
        else { return false }
        let insertedText = (after as NSString).substring(with: change.newRange)
        return !insertedText.isEmpty && insertedText.unicodeScalars.allSatisfy {
            !self.boundaryCharacters.contains($0)
        }
    }

    static func correctedTokenRange(before: String, after: String) -> NSRange? {
        guard let change = self.textChange(before: before, after: after) else { return nil }
        return self.expandedTokenRange(in: after, around: change.newRange)
    }

    static func selectionTouchesCandidate(_ selection: NSRange, candidateRange: NSRange) -> Bool {
        guard selection.location != NSNotFound, candidateRange.location != NSNotFound else { return false }
        if selection.length == 0 {
            return selection.location >= candidateRange.location &&
                selection.location <= NSMaxRange(candidateRange)
        }
        return NSIntersectionRange(selection, candidateRange).length > 0
    }

    static func changeContinuesCandidate(
        _ change: AutomaticDictionaryTextChange,
        after: String,
        candidateRange: NSRange
    ) -> Bool {
        if change.oldRange.length > 0 {
            return NSIntersectionRange(change.oldRange, candidateRange).length > 0
        }

        guard change.oldRange.location >= candidateRange.location,
              change.oldRange.location <= NSMaxRange(candidateRange)
        else {
            return false
        }

        guard change.oldRange.location == NSMaxRange(candidateRange) else { return true }
        let text = after as NSString
        guard change.newRange.location != NSNotFound,
              NSMaxRange(change.newRange) <= text.length
        else {
            return false
        }
        let insertedText = text.substring(with: change.newRange)
        return insertedText.unicodeScalars.allSatisfy { !self.boundaryCharacters.contains($0) }
    }

    private static func expandedTokenRange(in text: String, around range: NSRange) -> NSRange {
        let nsText = text as NSString
        let safeLocation = max(0, min(range.location, nsText.length))
        let safeEnd = max(safeLocation, min(NSMaxRange(range), nsText.length))
        var start = safeLocation
        var end = safeEnd

        while start > 0, !self.isBoundary(nsText.character(at: start - 1)) {
            start -= 1
        }
        while end < nsText.length, !self.isBoundary(nsText.character(at: end)) {
            end += 1
        }

        return NSRange(location: start, length: end - start)
    }

    private static func isBoundary(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return self.boundaryCharacters.contains(scalar)
    }

    private static func cleanedCandidate(_ value: String) -> String {
        value.trimmingCharacters(in: self.edgeCharacters)
    }

    private static func isValidCandidate(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= self.maxCandidateLength,
              value.rangeOfCharacter(from: .alphanumerics) != nil
        else {
            return false
        }

        let words = value.split(whereSeparator: { $0.isWhitespace })
        return words.count == 1
    }

    private static func isMeaningfulCorrection(heard: String, corrected: String) -> Bool {
        let heardCharacters = heard.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let correctedCharacters = corrected.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard heardCharacters.count >= 2,
              correctedCharacters.count >= 2,
              heardCharacters.contains(where: { CharacterSet.letters.contains($0) }),
              correctedCharacters.contains(where: { CharacterSet.letters.contains($0) })
        else {
            return false
        }

        let heardSemantic = String(String.UnicodeScalarView(heardCharacters))
        let correctedSemantic = String(String.UnicodeScalarView(correctedCharacters))
        return heardSemantic != correctedSemantic
    }
}
