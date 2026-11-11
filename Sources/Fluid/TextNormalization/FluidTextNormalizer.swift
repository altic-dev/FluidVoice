import Foundation

/// App-independent English formatting. Call once at each boundary of AI cleanup.
/// The caller owns language selection, resource loading, capitalization and delivery.
nonisolated struct FluidTextNormalizer: Sendable {
    enum Phase: String, Codable, Sendable {
        case beforeCleanup
        case afterCleanup
    }

    static let maximumUTF8Length = 65_536
    private let emoji: SpokenEmojiRules?

    init(emoji: SpokenEmojiRules? = nil) {
        self.emoji = emoji
    }

    func normalize(_ text: String, phase: Phase, languageCode: String = "en") -> String {
        let language = languageCode.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        guard language == "en", !text.isEmpty, !text.contains("\0"),
              text.utf8.count <= Self.maximumUTF8Length else { return text }
        let symbols = self.emoji?.apply(to: text, phase: phase) ?? text
        return DictationQuantityFormatter.format(symbols)
    }

    /// If cleanup discards an explicit literal escape, preserve the prepared transcription.
    /// Apply this before the host's capitalization/spacing, then finalize once afterward.
    func preservingLiteralCommands(in cleanedText: String, from preparedText: String, languageCode: String = "en") -> String {
        let language = languageCode.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        guard language == "en", let emoji = self.emoji,
              preparedText.utf8.count <= Self.maximumUTF8Length, cleanedText.utf8.count <= Self.maximumUTF8Length,
              preparedText.range(of: "literal", options: .caseInsensitive) != nil else { return cleanedText }
        let required = emoji.literalNames(in: preparedText)
        guard !required.isEmpty else { return cleanedText }
        var retained = Dictionary(emoji.literalNames(in: cleanedText).map { ($0, 1) }, uniquingKeysWith: +)
        for name in required {
            guard let count = retained[name], count > 0 else { return preparedText }
            retained[name] = count - 1
        }
        return cleanedText
    }
}

/// Shared exclusions keep quantities and emoji out of code, links and email addresses.
nonisolated enum TextNormalizationProtection {
    private static let expression = expression("https?://[^\\s]+|[\\w.+-]+@[^\\s]+")
    private static let backticks = expression("`+")

    static func ranges(in text: String) -> [NSRange] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        var protected = self.expression.matches(in: text, range: fullRange).map(\.range)
        let delimiters = self.backticks.matches(in: text, range: fullRange).map(\.range)
        // Index matching delimiter lengths once, so many unmatched runs cannot
        // cause repeated scans. Shorter runs inside a code span are literal text.
        var nextByLength: [Int: Int] = [:]
        var closingIndices = [Int?](repeating: nil, count: delimiters.count)
        for index in delimiters.indices.reversed() {
            let length = delimiters[index].length
            closingIndices[index] = nextByLength[length]
            nextByLength[length] = index
        }
        var index = 0
        while index < delimiters.count {
            let opening = delimiters[index]
            guard let closing = closingIndices[index] else {
                // Keep incomplete dictated code unchanged through the end.
                protected.append(NSRange(location: opening.location, length: fullRange.length - opening.location))
                break
            }
            protected.append(NSRange(location: opening.location, length: NSMaxRange(delimiters[closing]) - opening.location))
            index = closing + 1
        }
        return protected
    }

    static func expression(_ pattern: String) -> NSRegularExpression {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            preconditionFailure("Invalid static text normalization expression")
        }
        return expression
    }
}
