import Foundation

/// Exact names and explicit aliases live in JSON; this matcher has no OS or keyboard dependency.
nonisolated struct SpokenEmojiRules: Sendable {
    private struct Catalog: Decodable {
        let schemaVersion: Int
        let language: String
        let maximumNameWords: Int
        let names: [String: String]
        let unsupportedNames: [String]
    }

    private static let words = TextNormalizationProtection.expression("[\\p{L}\\p{M}\\p{N}]+")
    private let names: [String: String]
    private let maximumNameWords: Int
    private let unsupportedNames: NSRegularExpression?

    init?(data: Data) {
        guard data.count <= 2_000_000,
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              catalog.schemaVersion == 1, catalog.language == "en", catalog.maximumNameWords == 5,
              !catalog.names.isEmpty, catalog.names.count <= 10_000,
              catalog.unsupportedNames.count <= 1000,
              catalog.unsupportedNames.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              catalog.names.allSatisfy({ name, emoji in
                  let words = name.split(separator: " ", omittingEmptySubsequences: false)
                  return !words.isEmpty && words.count <= 5 && words.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber } }
                      && name == name.lowercased() && emoji.count == 1
              })
        else { return nil }
        self.names = catalog.names
        self.maximumNameWords = catalog.maximumNameWords
        let unsupported = catalog.unsupportedNames.map { name in
            name.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[ \\t-]+")
        }.joined(separator: "|")
        self.unsupportedNames = unsupported.isEmpty ? nil : TextNormalizationProtection.expression("\\b(?:" + unsupported + ")[ \\t]+emoji\\b")
    }

    private struct Match {
        let range: NSRange
        let emoji: String
        let literalName: String?
        let literalText: String?
    }

    func apply(to text: String, phase: FluidTextNormalizer.Phase) -> String {
        let result = NSMutableString(string: text)
        for match in self.matches(in: text).reversed() {
            if let literal = match.literalText {
                if phase == .afterCleanup { result.replaceCharacters(in: match.range, with: literal) }
            } else {
                result.replaceCharacters(in: match.range, with: match.emoji)
            }
        }
        return result as String
    }

    func literalNames(in text: String) -> [String] {
        self.matches(in: text).compactMap(\.literalName)
    }

    private func matches(in text: String) -> [Match] {
        guard text.range(of: "emoji", options: .caseInsensitive) != nil else { return [] }
        let source = text as NSString
        let words = Self.words.matches(in: text, range: NSRange(location: 0, length: source.length))
        // A known name beyond the five-word limit must not degrade to its last word's emoji.
        let protected = TextNormalizationProtection.ranges(in: text)
            + (self.unsupportedNames?.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range) ?? [])
        var matches: [Match] = []
        var consumedEnd = 0
        for trigger in words.indices where source.substring(with: words[trigger].range).lowercased() == "emoji" {
            let starts = self.candidateStarts(before: trigger, words: words, source: source, consumedEnd: consumedEnd)
            for start in starts.reversed() {
                let name = words[start..<trigger].map { source.substring(with: $0.range).lowercased() }.joined(separator: " ")
                guard let emoji = self.names[name] else { continue }
                let range = NSRange(location: words[start].range.location, length: NSMaxRange(words[trigger].range) - words[start].range.location)
                guard !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                      !Self.isIdentifierEdge(source, at: range.location - 1),
                      !Self.isIdentifierEdge(source, at: NSMaxRange(range), trailing: true) else { break }
                let literal = start > 0 && source.substring(with: words[start - 1].range).lowercased() == "literal"
                    && Self.isGap(source, from: NSMaxRange(words[start - 1].range), to: range.location)
                if literal {
                    guard !Self.isIdentifierEdge(source, at: words[start - 1].range.location - 1) else { break }
                    let escapedRange = NSRange(location: words[start - 1].range.location, length: NSMaxRange(range) - words[start - 1].range.location)
                    matches.append(Match(range: escapedRange, emoji: emoji, literalName: name, literalText: source.substring(with: range)))
                } else {
                    matches.append(Match(range: range, emoji: emoji, literalName: nil, literalText: nil))
                }
                consumedEnd = NSMaxRange(range)
                break
            }
        }
        return matches
    }

    private func candidateStarts(before trigger: Int, words: [NSTextCheckingResult], source: NSString, consumedEnd: Int) -> [Int] {
        var starts: [Int] = []
        var cursor = trigger
        while cursor > 0, starts.count < self.maximumNameWords {
            let previous = words[cursor - 1].range
            guard previous.location >= consumedEnd,
                  Self.isGap(source, from: NSMaxRange(previous), to: words[cursor].range.location) else { break }
            starts.append(cursor - 1)
            cursor -= 1
        }
        return starts
    }

    private static func isIdentifierEdge(_ source: NSString, at position: Int, trailing: Bool = false) -> Bool {
        guard position >= 0, position < source.length else { return false }
        let character = source.substring(with: NSRange(location: position, length: 1))
        if trailing, [".", "'", "’"].contains(character) {
            guard position + 1 < source.length else { return false }
            let next = source.substring(with: NSRange(location: position + 1, length: 1))
            return next.contains { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        return "_./@#\\-".contains(character)
    }

    private static func isGap(_ source: NSString, from start: Int, to end: Int) -> Bool {
        guard end > start else { return false }
        return source.substring(with: NSRange(location: start, length: end - start)).allSatisfy { $0 == " " || $0 == "\t" || $0 == "-" }
    }
}
