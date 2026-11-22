import Foundation

/// Immutable literal replacement rule shared by dictation and completed meeting turns.
nonisolated struct DictionaryReplacementRule {
    let entryID: UUID
    let trigger: String
    let regex: NSRegularExpression
    let template: String
    let canonical: NSRegularExpression?
    let changesOnlyFormatting: Bool
    let formattingOutputRegex: NSRegularExpression?

    static func compile(for entries: [SettingsStore.CustomDictionaryEntry]) -> [DictionaryReplacementRule] {
        var patterns: [DictionaryReplacementRule] = []

        for entry in entries {
            var canonical: NSRegularExpression?
            let replacementRange = NSRange(entry.replacement.startIndex..., in: entry.replacement)
            let replacementContent = self.lettersAndDigits(entry.replacement)
            for trigger in entry.triggers {
                guard !trigger.isEmpty else { continue }

                let consumesHorizontalSeparators = !entry.replacement.isEmpty &&
                    entry.replacement.allSatisfy(\.isWhitespace)
                let escapedTrigger = self.pattern(
                    for: trigger,
                    consumesHorizontalSeparators: consumesHorizontalSeparators
                )
                guard let regex = try? NSRegularExpression(
                    pattern: escapedTrigger,
                    options: entry.caseSensitive ? [] : .caseInsensitive
                ) else { continue }

                let needsProtection = regex.matches(in: entry.replacement, range: replacementRange).contains {
                    $0.range.length < replacementRange.length
                }
                if needsProtection, canonical == nil {
                    canonical = try? NSRegularExpression(pattern: self.pattern(for: entry.replacement), options: entry.caseSensitive ? [] : .caseInsensitive)
                }
                let triggerContent = self.lettersAndDigits(trigger)
                let changesOnlyFormatting = triggerContent == replacementContent && !triggerContent.isEmpty
                patterns.append(DictionaryReplacementRule(
                    entryID: entry.id,
                    trigger: trigger,
                    regex: regex,
                    template: NSRegularExpression.escapedTemplate(for: entry.replacement),
                    canonical: needsProtection ? canonical : nil,
                    changesOnlyFormatting: changesOnlyFormatting,
                    formattingOutputRegex: entry.caseSensitive && changesOnlyFormatting
                        ? try? NSRegularExpression(pattern: self.pattern(for: entry.replacement), options: .caseInsensitive)
                        : nil
                ))
            }
        }

        return patterns.sorted {
            $0.regex.pattern.utf16.count > $1.regex.pattern.utf16.count
        }
    }

    /// Restore only an initial occurrence known to have matched this rule before cleanup.
    /// An ordinary unmatched "Am I..." has no such provenance and must keep its capitalization.
    func restoringInitialOutput(in text: String) -> String {
        guard let outputRegex = self.formattingOutputRegex,
              let firstLetter = text.firstIndex(where: { $0.isLetter }),
              let match = outputRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              NSLocationInRange(NSRange(text.startIndex..<firstLetter, in: text).length, match.range)
        else { return text }
        let replacement = outputRegex.replacementString(for: match, in: text, offset: 0, template: self.template)
        return (text as NSString).replacingCharacters(in: match.range, with: replacement)
    }

    /// Reapplying content-changing rules after cleanup can expand or chain replacements twice.
    private static func lettersAndDigits(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    static func pattern(
        for trigger: String,
        consumesHorizontalSeparators: Bool = false
    ) -> String {
        let escapedTrigger = NSRegularExpression.escapedPattern(for: trigger)
        let prefix = self.startsWithWordCharacter(trigger) ? "\\b" : ""
        let suffix = self.endsWithWordCharacter(trigger) ? "\\b" : ""
        let separator = consumesHorizontalSeparators ? "[ \\t]*" : ""
        return separator + prefix + escapedTrigger + suffix + separator
    }

    private static func startsWithWordCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return self.isWordCharacter(scalar)
    }

    private static func endsWithWordCharacter(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else { return false }
        return self.isWordCharacter(scalar)
    }

    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
}
