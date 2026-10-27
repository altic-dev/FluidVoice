import Foundation

/// Prevents a rule from expanding a completed occurrence of its own replacement.
/// Only rules whose output contains a partial trigger need this extra scan.
nonisolated enum DictionaryReplacementProtection {
    static func replacingMatches(
        in text: String,
        regex: NSRegularExpression,
        template: String,
        canonical: NSRegularExpression?,
        onReplacement: ((NSRange, String, String) -> Void)? = nil
    ) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        guard canonical != nil || onReplacement != nil else {
            return regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: template)
        }
        let completed = canonical?.matches(in: text, range: fullRange).map(\.range) ?? []
        guard !completed.isEmpty || onReplacement != nil else {
            return regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: template)
        }

        var completedIndex = 0
        let matches = regex.matches(in: text, range: fullRange).filter { match in
            while completedIndex < completed.count, NSMaxRange(completed[completedIndex]) <= match.range.location {
                completedIndex += 1
            }
            guard completedIndex < completed.count else { return true }
            let range = completed[completedIndex]
            let isPartialTriggerInsideCompletedOutput = range.location <= match.range.location &&
                NSMaxRange(match.range) <= NSMaxRange(range) && match.range.length < range.length
            return !isPartialTriggerInsideCompletedOutput
        }
        guard !matches.isEmpty else { return text }
        let output = NSMutableString(string: text)
        for match in matches.reversed() {
            let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
            if let onReplacement {
                let heard = (text as NSString).substring(with: match.range)
                if heard != replacement {
                    onReplacement(match.range, heard, replacement)
                }
            }
            output.replaceCharacters(
                in: match.range,
                with: replacement
            )
        }
        return output as String
    }
}

/// Keep support logs bounded and on one line, including unusual user-defined rules.
nonisolated enum DictionaryReplacementDiagnostics {
    static let maximumEvents = 16

    static func quoted(_ text: String) -> String {
        let bounded = text.prefix(161)
        return (String(bounded.prefix(160)) + (bounded.count > 160 ? "…" : "")).debugDescription
    }
}
