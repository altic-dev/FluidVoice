import Foundation

/// Immutable literal replacement rule shared by dictation and completed meeting turns.
nonisolated struct DictionaryReplacementRule: Sendable {
    let entryID: UUID
    let trigger: String
    let regex: NSRegularExpression
    let template: String
    let canonical: NSRegularExpression?

    static func compile(for entries: [SettingsStore.CustomDictionaryEntry]) -> [DictionaryReplacementRule] {
        var patterns: [DictionaryReplacementRule] = []

        for entry in entries {
            var canonical: NSRegularExpression?
            let replacementRange = NSRange(entry.replacement.startIndex..., in: entry.replacement)
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
                    options: .caseInsensitive
                ) else { continue }

                let needsProtection = regex.matches(in: entry.replacement, range: replacementRange).contains {
                    $0.range.length < replacementRange.length
                }
                if needsProtection, canonical == nil {
                    canonical = try? NSRegularExpression(pattern: self.pattern(for: entry.replacement), options: .caseInsensitive)
                }
                patterns.append(DictionaryReplacementRule(
                    entryID: entry.id,
                    trigger: trigger,
                    regex: regex,
                    template: NSRegularExpression.escapedTemplate(for: entry.replacement),
                    canonical: needsProtection ? canonical : nil
                ))
            }
        }

        return patterns.sorted {
            $0.regex.pattern.utf16.count > $1.regex.pattern.utf16.count
        }
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
