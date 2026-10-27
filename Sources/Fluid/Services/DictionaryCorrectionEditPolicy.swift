import Foundation

/// Eligibility for automatic learning only. Manual dictionary entries remain unrestricted.
/// Keep this separate from observing edits and from acoustic matching so it can be replaced.
nonisolated enum DictionaryCorrectionEditPolicy {
    static func allows(heard: String, corrected: String) -> Bool {
        guard self.isSingleWord(heard), self.isSingleWord(corrected) else { return false }
        let before = heard.lowercased()
        let after = corrected.lowercased()
        // Preserve deliberate brand capitalization. Negative learning separately rejects it.
        guard before != after else { return heard != corrected }
        return !self.isInflection(base: before, changed: after) &&
            !self.isInflection(base: after, changed: before)
    }

    private static func isSingleWord(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 40 else { return false }
        // Apostrophes and hyphens remain valid within names; punctuation cannot join phrases.
        let connectors = CharacterSet(charactersIn: "'-’")
        return text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) ||
                CharacterSet.nonBaseCharacters.contains($0) || connectors.contains($0)
        }
    }

    private static func isInflection(base: String, changed: String) -> Bool {
        // These are narrow English spelling patterns, not arbitrary suffix/substring matching.
        // Do not apply English suffix rules to other scripts or short names such as Jo → Jos.
        guard base.count >= 3, base.utf8.allSatisfy({ (97...122).contains($0) }) else { return false }
        if changed == base + "'s" || changed == base + "’s" { return true }
        if !base.hasSuffix("s"), changed == base + "s" { return true }
        if ["s", "x", "z", "ch", "sh"].contains(where: base.hasSuffix), changed == base + "es" { return true }
        if base.hasSuffix("y"), let preceding = base.dropLast().last,
           !"aeiou".contains(preceding), changed == String(base.dropLast()) + "ies" { return true }
        // Require a longer stem for tense changes to preserve short spelling repairs.
        guard base.count >= 4 else { return false }
        if changed == base + "ed" || changed == base + "ing" { return true }
        if base.hasSuffix("e") {
            return changed == base + "d" || changed == String(base.dropLast()) + "ing"
        }
        return false
    }
}
