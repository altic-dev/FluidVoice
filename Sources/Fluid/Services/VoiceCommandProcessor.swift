import Foundation

protocol VoiceCommandSettings {
    var voiceCommandsEnabled: Bool { get }
    var voiceCommandScratchWordCount: Int { get }
}

enum EditAction {
    case deleteLastWords(Int)
    case capitalizeLastWord
    case appendAfterLastWord(String)
    case insertNewline
}

struct VoiceCommand {
    let phrases: [String]
    let action: EditAction
}

enum VoiceCommandProcessor {
    static let commands: [VoiceCommand] = [
        .init(phrases: ["scratch that", "delete that"], action: .deleteLastWords(1)),
        .init(phrases: ["capitalize that"], action: .capitalizeLastWord),
        .init(phrases: ["slash that"], action: .appendAfterLastWord("/")),
        .init(phrases: ["new line", "new paragraph"], action: .insertNewline),
    ]

    static func detect(in input: String, settings: VoiceCommandSettings) -> (stripped: String, action: EditAction?) {
        guard settings.voiceCommandsEnabled else { return (input, nil) }
        if input.isEmpty { return ("", nil) }

        // TODO(v2): support "literal new line" escape hatch
        let normalized = self.normalizeForMatching(input)
            .replacingOccurrences(of: ", ", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        for command in self.commands {
            for phrase in command.phrases {
                guard normalized.hasSuffix(phrase) else { continue }

                let phraseStart = normalized.index(normalized.endIndex, offsetBy: -phrase.count)
                let atWordBoundary = phraseStart == normalized.startIndex
                    || normalized[normalized.index(before: phraseStart)] == " "
                guard atWordBoundary else { continue }

                let stripped = self.stripPhraseSuffix(phrase, from: input)
                return (stripped, command.action)
            }
        }

        return (input, nil)
    }

    static func apply(_ action: EditAction, to text: String, settings: VoiceCommandSettings) -> String {
        switch action {
        case .deleteLastWords:
            let count = settings.voiceCommandScratchWordCount
            var tokens = self.tokenize(text)
            if tokens.isEmpty { return "" }
            if count >= tokens.count { return "" }
            tokens.removeLast(count)
            return tokens.joined(separator: " ")

        case .capitalizeLastWord:
            var tokens = self.tokenize(text)
            guard let last = tokens.last else { return "" }
            let (stem, punct) = self.stripTrailingPunct(from: last)
            guard !stem.isEmpty else { return text }
            let capitalized = String(stem.prefix(1)).uppercased() + stem.dropFirst()
            tokens[tokens.count - 1] = capitalized + punct
            return tokens.joined(separator: " ")

        case let .appendAfterLastWord(suffix):
            var tokens = self.tokenize(text)
            guard let last = tokens.last else { return "" }
            let (stem, punct) = self.stripTrailingPunct(from: last)
            tokens[tokens.count - 1] = stem + suffix + punct
            return tokens.joined(separator: " ")

        case .insertNewline:
            return text + "\n"
        }
    }

    /// Lowercase, collapse whitespace, strip leading/trailing whitespace.
    private static func normalizeForMatching(_ s: String) -> String {
        return s.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Split on whitespace, filter empty.
    private static func tokenize(_ s: String) -> [String] {
        return s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Returns (stem, trailingPunct) where trailingPunct is the trailing
    /// punctuation characters stripped from the token (e.g. "word." -> ("word", "."))
    /// Only strip common trailing punctuation: . , ! ? ; :
    private static func stripTrailingPunct(from token: String) -> (stem: String, punct: String) {
        let punctSet: Set<Character> = [".", ",", "!", "?", ";", ":"]
        var stem = token
        var punct = ""
        while let last = stem.last, punctSet.contains(last) {
            punct = String(last) + punct
            stem.removeLast()
        }
        return (stem, punct)
    }

    /// Remove the matched phrase plus any preceding whitespace from the end of the
    /// original (un-normalized) input. The phrase may appear in the original with
    /// different casing/spacing/punctuation than the normalized form, so we strip
    /// a word-count's worth of trailing tokens equal to the phrase's word count.
    private static func stripPhraseSuffix(_ phrase: String, from input: String) -> String {
        let phraseWordCount = phrase.split(separator: " ").count
        var tokens = self.tokenize(input)
        guard tokens.count >= phraseWordCount else { return "" }
        tokens.removeLast(phraseWordCount)
        return tokens.joined(separator: " ")
    }
}
