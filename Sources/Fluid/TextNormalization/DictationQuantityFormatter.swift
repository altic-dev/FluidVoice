import Foundation

/// Bounded, stateless rules for finalized dictation; never used on audio or partial captions.
/// Run after cleanup as well as before it so an LLM spelling quantities out cannot undo the format.
nonisolated enum DictationQuantityFormatter {
    private static let number = DictationNumberParser.phrasePattern
    private static let boundary = "(?<![\\p{L}\\p{M}\\p{N}_.,€£$+/@#\\\\−-])"
    private static let ending = "(?![\\p{L}\\p{M}\\p{N}_])"
    private static let money = regex(
        boundary + "(" + number + ")[ \\t]+(euros?|dollars?|British pounds?|pounds? sterling|pounds?)"
            + "(?![ \\t]+cents?\\b)(?:[ \\t]+and[ \\t]+(" + number + ")[ \\t]+(cents?|pence|penny))?" + ending
    )
    private static let minorMoney = regex(boundary + "(" + number + ")[ \\t]+(euro cents?|US cents?|pence|penny)" + ending)
    private static let parameters = regex(boundary + "(" + number + ")[ \\t]*(b|m)?[ \\t]+parameters?" + ending)
    private static let tokens = regex(boundary + "(" + number + ")[ \\t]+tokens?(?:[ \\t]+per[ \\t]+second|[ \\t]*/[ \\t]*(?:second|sec|s))" + ending)
    private static let precedingNumber = regex("\\b(?:" + DictationNumberParser.tokenPattern.replacingOccurrences(of: "|and", with: "") + "|trillion|quadrillion|quintillion|minus|negative|plus)[ \\t-]+$")

    static func format(_ text: String) -> String {
        guard !text.isEmpty, text.utf8.count <= 65_536 else { return text }
        var result = self.replace(text, using: self.money) { match, source in
            guard let amount = self.value(1, match, source) else { return nil }
            let unit = self.capture(2, match, source).lowercased()
            let minorUnit = self.capture(4, match, source).lowercased()
            // Bare pounds may describe weight. Only explicit sterling or pence disambiguates it.
            if ["pound", "pounds"].contains(unit), !["pence", "penny"].contains(minorUnit) { return nil }
            let symbol = unit.hasPrefix("euro") ? "€" : (unit.hasPrefix("dollar") ? "$" : "£")
            let minor = self.value(3, match, source)
            if match.range(at: 3).location != NSNotFound {
                guard let minor, minor >= 0, minor < 100,
                      self.isInteger(minor), self.isInteger(amount),
                      symbol == "£" ? ["pence", "penny"].contains(minorUnit) : ["cent", "cents"].contains(minorUnit)
                else { return nil }
            }
            let value = amount + (minor ?? 0) / 100
            guard self.isInteger(value * 100) else { return nil }
            return symbol + self.moneyString(value, includeCents: minor != nil)
        }
        result = self.replace(result, using: self.minorMoney, protecting: self.money) { match, source in
            guard let value = self.value(1, match, source), self.isInteger(value), value < 100 else { return nil }
            let unit = self.capture(2, match, source).lowercased()
            if unit == "pence" || unit == "penny" { return DictationNumberParser.string(value) + "p" }
            return (unit.hasPrefix("euro") ? "€" : "$") + self.moneyString(value / 100, includeCents: true)
        }
        result = self.replace(result, using: self.parameters) { match, source in
            guard var value = self.value(1, match, source) else { return nil }
            let suffixInput = self.capture(2, match, source).lowercased()
            if !suffixInput.isEmpty {
                let words = self.capture(1, match, source).lowercased().split(whereSeparator: { !$0.isLetter })
                guard !words.contains(where: { ["thousand", "million", "billion"].contains(String($0)) }) else { return nil }
            }
            switch suffixInput {
            case "b": value *= 1_000_000_000
            case "m": value *= 1_000_000
            default: break
            }
            guard self.isInteger(value) else { return nil }
            let suffix: String
            if value >= 1_000_000_000 {
                value /= 1_000_000_000
                suffix = "B"
            } else if value >= 1_000_000 {
                value /= 1_000_000
                suffix = "M"
            } else {
                suffix = ""
            }
            return DictationNumberParser.string(value) + suffix + (value == 1 && suffix.isEmpty ? " parameter" : " parameters")
        }
        return self.replace(result, using: self.tokens) { match, source in
            guard let value = self.value(1, match, source) else { return nil }
            return DictationNumberParser.string(value) + (value == 1 ? " token per second" : " tokens per second")
        }
    }

    private static func replace(_ text: String, using expression: NSRegularExpression, protecting extra: NSRegularExpression? = nil, transform: (NSTextCheckingResult, NSString) -> String?) -> String {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        let protectedRanges = TextNormalizationProtection.ranges(in: text) + (extra?.matches(in: text, range: range).map(\.range) ?? [])
        let matches = expression.matches(in: text, range: range)
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            // Never turn the tail of an unsupported number or signed amount into a different quantity.
            let prefixRange = NSRange(location: max(0, match.range.location - 32), length: min(32, match.range.location))
            let prefix = source.substring(with: prefixRange)
            guard self.precedingNumber.firstMatch(in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)) == nil,
                  let replacement = transform(match, source) else { continue }
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    private static func capture(_ index: Int, _ match: NSTextCheckingResult, _ source: NSString) -> String {
        let range = match.range(at: index)
        return range.location == NSNotFound ? "" : source.substring(with: range)
    }

    private static func value(_ index: Int, _ match: NSTextCheckingResult, _ source: NSString) -> Decimal? {
        DictationNumberParser.parse(self.capture(index, match, source))
    }

    private static func isInteger(_ value: Decimal) -> Bool {
        var original = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &original, 0, .plain)
        return value == rounded
    }

    private static func moneyString(_ value: Decimal, includeCents: Bool) -> String {
        let text = DictationNumberParser.string(value)
        if let dot = text.firstIndex(of: ".") {
            return text + String(repeating: "0", count: max(0, 2 - text.distance(from: text.index(after: dot), to: text.endIndex)))
        }
        return text + (includeCents ? ".00" : "")
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // All patterns are static, authored here, and exercised by the standalone regression suite.
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            preconditionFailure("Invalid static quantity expression")
        }
        return expression
    }
}
