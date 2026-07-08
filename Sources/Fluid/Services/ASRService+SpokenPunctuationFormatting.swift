import Foundation

extension ASRService {
    static func applySpokenPunctuationFormatting(
        _ text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> String {
        guard SettingsStore.shared.autoConvertPunctuationEnabled else { return text }
        return SpokenPunctuationFormatter.apply(
            text,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle
        )
    }
}

private enum SpokenPunctuationFormatter {
    private struct FormattingContext {
        let appName: String?
        let bundleID: String?
        let windowTitle: String?

        var isAtSignPunctuationApp: Bool {
            let haystack = [self.appName, self.bundleID, self.windowTitle]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return haystack.contains("codex") ||
                haystack.contains("chatgpt") ||
                haystack.contains("claude") ||
                haystack.contains("cursor") ||
                haystack.contains("windsurf") ||
                haystack.contains("xcode") ||
                haystack.contains("visual studio code") ||
                haystack.contains("vscode") ||
                haystack.contains("terminal") ||
                haystack.contains("iterm") ||
                haystack.contains("warp") ||
                haystack.contains("ghostty") ||
                haystack.contains("kitty") ||
                haystack.contains("alacritty") ||
                haystack.contains("slack") ||
                haystack.contains("discord") ||
                haystack.contains("teams")
        }
    }

    private enum Spacing {
        case rightAttached
        case leftAttached
        case noSpaceAround
        case spaceAround
        case toggleDoubleQuote
        case toggleSingleQuote
    }

    private struct PhraseRule {
        let words: [String]
        let symbol: String
        let spacing: Spacing
        var requiresSymbolContext = false
        var requiresDotContext = false
        var requiresSlashPathContext = false
        var requiresAtSignPunctuationApp = false
    }

    private enum Token {
        case word(original: String, normalized: String)
        case text(String)

        var normalizedWord: String? {
            if case let .word(_, normalized) = self { return normalized }
            return nil
        }

        var text: String? {
            switch self {
            case let .word(original, _):
                return original
            case let .text(text):
                return text
            }
        }

        var isHorizontalWhitespaceText: Bool {
            guard case let .text(text) = self, !text.isEmpty else { return false }
            return text.allSatisfy(\.isHorizontalWhitespace)
        }
    }

    private enum OutputPart {
        case text(String)
        case punctuation(symbol: String, spacing: Spacing)

        var isHorizontalWhitespaceText: Bool {
            guard case let .text(text) = self, !text.isEmpty else { return false }
            return text.allSatisfy(\.isHorizontalWhitespace)
        }
    }

    private static let rulesByFirstWord: [String: [PhraseRule]] = {
        let rules = Self.makeRules()
        let grouped = Dictionary(grouping: rules) { $0.words.first ?? "" }
        return grouped.mapValues {
            $0.sorted {
                if $0.words.count != $1.words.count { return $0.words.count > $1.words.count }
                return $0.words.joined(separator: " ").count > $1.words.joined(separator: " ").count
            }
        }
    }()

    static func apply(
        _ text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> String {
        guard !text.isEmpty else { return text }

        let context = FormattingContext(appName: appName, bundleID: bundleID, windowTitle: windowTitle)
        let tokens = self.tokenize(text)
        guard tokens.contains(where: { $0.normalizedWord != nil }) else {
            return text
        }

        var output: [OutputPart] = []
        var index = 0
        while index < tokens.count {
            if let match = self.matchRule(in: tokens, at: index, context: context) {
                output.append(.punctuation(symbol: match.rule.symbol, spacing: match.rule.spacing))
                index = match.endIndex
            } else if let text = tokens[index].text {
                output.append(.text(text))
                index += 1
            } else {
                index += 1
            }
        }

        return self.render(self.removingGeneratedCommaNoise(from: output))
    }

    private static func makeRules() -> [PhraseRule] {
        self.rules(
            symbol: ",",
            spacing: .rightAttached,
            phrases: ["comma"]
        ) +
            self.rules(
                symbol: ".",
                spacing: .rightAttached,
                phrases: ["period", "full stop"]
            ) +
            self.rules(
                symbol: ".",
                spacing: .noSpaceAround,
                phrases: ["dot"],
                requiresDotContext: true
            ) +
            self.rules(
                symbol: "?",
                spacing: .rightAttached,
                phrases: ["question mark", "questionmark"]
            ) +
            self.rules(
                symbol: "!",
                spacing: .rightAttached,
                phrases: ["exclamation mark", "exclamation point", "bang"]
            ) +
            self.rules(
                symbol: ":",
                spacing: .rightAttached,
                phrases: ["colon"]
            ) +
            self.rules(
                symbol: ";",
                spacing: .rightAttached,
                phrases: ["semicolon", "semi colon"]
            ) +
            self.rules(
                symbol: "...",
                spacing: .rightAttached,
                phrases: ["ellipsis", "dot dot dot", "three dots"]
            ) +
            self.rules(
                symbol: "/",
                spacing: .noSpaceAround,
                phrases: ["slash", "forward slash", "forwardslash"],
                requiresSlashPathContext: true
            ) +
            self.rules(
                symbol: "\\",
                spacing: .noSpaceAround,
                phrases: ["backslash", "back slash"]
            ) +
            self.rules(
                symbol: "-",
                spacing: .noSpaceAround,
                phrases: ["hyphen"]
            ) +
            self.rules(
                symbol: "-",
                spacing: .spaceAround,
                phrases: ["dash", "minus sign"]
            ) +
            self.rules(
                symbol: "—",
                spacing: .spaceAround,
                phrases: ["em dash", "long dash"]
            ) +
            self.rules(
                symbol: "–",
                spacing: .spaceAround,
                phrases: ["en dash"]
            ) +
            self.rules(
                symbol: "(",
                spacing: .leftAttached,
                phrases: ["open parenthesis", "open parentheses", "left parenthesis", "left parentheses", "open paren", "left paren"]
            ) +
            self.rules(
                symbol: ")",
                spacing: .rightAttached,
                phrases: ["close parenthesis", "close parentheses", "right parenthesis", "right parentheses", "close paren", "right paren"]
            ) +
            self.rules(
                symbol: "[",
                spacing: .leftAttached,
                phrases: ["open bracket", "left bracket", "open square bracket", "left square bracket"]
            ) +
            self.rules(
                symbol: "]",
                spacing: .rightAttached,
                phrases: ["close bracket", "right bracket", "close square bracket", "right square bracket"]
            ) +
            self.rules(
                symbol: "{",
                spacing: .leftAttached,
                phrases: ["open brace", "left brace", "open curly brace", "left curly brace", "open curly bracket", "left curly bracket"]
            ) +
            self.rules(
                symbol: "}",
                spacing: .rightAttached,
                phrases: ["close brace", "right brace", "close curly brace", "right curly brace", "close curly bracket", "right curly bracket"]
            ) +
            self.rules(
                symbol: "<",
                spacing: .leftAttached,
                phrases: ["open angle bracket", "left angle bracket", "less than sign"]
            ) +
            self.rules(
                symbol: ">",
                spacing: .rightAttached,
                phrases: ["close angle bracket", "right angle bracket", "greater than sign"]
            ) +
            self.rules(
                symbol: "\"",
                spacing: .toggleDoubleQuote,
                phrases: ["quote", "quotes", "quotation mark", "double quote"]
            ) +
            self.rules(
                symbol: "\"",
                spacing: .leftAttached,
                phrases: ["open quote", "opening quote", "open double quote", "opening double quote"]
            ) +
            self.rules(
                symbol: "\"",
                spacing: .rightAttached,
                phrases: ["close quote", "closing quote", "close double quote", "closing double quote"]
            ) +
            self.rules(
                symbol: "'",
                spacing: .toggleSingleQuote,
                phrases: ["single quote"]
            ) +
            self.rules(
                symbol: "'",
                spacing: .noSpaceAround,
                phrases: ["apostrophe"]
            ) +
            self.rules(
                symbol: "@",
                spacing: .noSpaceAround,
                phrases: ["at the rate"]
            ) +
            self.rules(
                symbol: "@",
                spacing: .noSpaceAround,
                phrases: ["at sign", "commercial at"],
                requiresAtSignPunctuationApp: true
            ) +
            self.rules(
                symbol: "&",
                spacing: .spaceAround,
                phrases: ["ampersand", "and sign"]
            ) +
            self.rules(
                symbol: "+",
                spacing: .spaceAround,
                phrases: ["plus sign"]
            ) +
            self.rules(
                symbol: "+",
                spacing: .spaceAround,
                phrases: ["plus"],
                requiresSymbolContext: true
            ) +
            self.rules(
                symbol: "=",
                spacing: .spaceAround,
                phrases: ["equals sign", "equal sign"]
            ) +
            self.rules(
                symbol: "=",
                spacing: .spaceAround,
                phrases: ["equal", "equals"],
                requiresSymbolContext: true
            ) +
            self.rules(
                symbol: "%",
                spacing: .rightAttached,
                phrases: ["percent sign", "percentage sign", "percent"]
            ) +
            self.rules(
                symbol: "$",
                spacing: .leftAttached,
                phrases: ["dollar sign", "dollar"]
            ) +
            self.rules(
                symbol: "#",
                spacing: .noSpaceAround,
                phrases: ["hash", "hash sign", "hashtag", "pound sign", "number sign"]
            ) +
            self.rules(
                symbol: "*",
                spacing: .noSpaceAround,
                phrases: ["asterisk", "star symbol"]
            ) +
            self.rules(
                symbol: "_",
                spacing: .noSpaceAround,
                phrases: ["underscore"]
            ) +
            self.rules(
                symbol: "|",
                spacing: .noSpaceAround,
                phrases: ["pipe", "vertical bar"]
            ) +
            self.rules(
                symbol: "~",
                spacing: .noSpaceAround,
                phrases: ["tilde"]
            ) +
            self.rules(
                symbol: "^",
                spacing: .noSpaceAround,
                phrases: ["caret"]
            ) +
            self.rules(
                symbol: "`",
                spacing: .noSpaceAround,
                phrases: ["backtick", "back tick"]
            )
    }

    private static func rules(
        symbol: String,
        spacing: Spacing,
        phrases: [String],
        requiresSymbolContext: Bool = false,
        requiresDotContext: Bool = false,
        requiresSlashPathContext: Bool = false,
        requiresAtSignPunctuationApp: Bool = false
    ) -> [PhraseRule] {
        phrases.compactMap { phrase in
            let words = phrase
                .split(separator: " ")
                .map { String($0).lowercased() }
                .filter { !$0.isEmpty }
            guard !words.isEmpty else { return nil }
            return PhraseRule(
                words: words,
                symbol: symbol,
                spacing: spacing,
                requiresSymbolContext: requiresSymbolContext,
                requiresDotContext: requiresDotContext,
                requiresSlashPathContext: requiresSlashPathContext,
                requiresAtSignPunctuationApp: requiresAtSignPunctuationApp
            )
        }
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var isBuildingWord = false

        func flushCurrent() {
            guard !current.isEmpty else { return }
            if isBuildingWord {
                tokens.append(.word(original: current, normalized: current.lowercased()))
            } else {
                tokens.append(.text(current))
            }
            current = ""
        }

        for character in text {
            let isWord = character.isPunctuationPhraseWordCharacter
            if current.isEmpty {
                current.append(character)
                isBuildingWord = isWord
            } else if isWord == isBuildingWord {
                current.append(character)
            } else {
                flushCurrent()
                current.append(character)
                isBuildingWord = isWord
            }
        }
        flushCurrent()
        return tokens
    }

    private static func matchRule(
        in tokens: [Token],
        at index: Int,
        context: FormattingContext
    ) -> (rule: PhraseRule, endIndex: Int)? {
        guard let firstWord = tokens[index].normalizedWord,
              let candidates = self.rulesByFirstWord[firstWord]
        else {
            return nil
        }

        for rule in candidates {
            var cursor = index
            var matched = true
            for (wordIndex, expectedWord) in rule.words.enumerated() {
                if wordIndex > 0 {
                    guard cursor < tokens.count, tokens[cursor].isHorizontalWhitespaceText else {
                        matched = false
                        break
                    }
                    while cursor < tokens.count, tokens[cursor].isHorizontalWhitespaceText {
                        cursor += 1
                    }
                }
                guard cursor < tokens.count, tokens[cursor].normalizedWord == expectedWord else {
                    matched = false
                    break
                }
                cursor += 1
            }
            if matched,
               !rule.requiresSymbolContext ||
               self.hasSymbolContext(in: tokens, startIndex: index, endIndex: cursor),
               !rule.requiresDotContext ||
               self.hasDotContext(in: tokens, startIndex: index, endIndex: cursor),
               !rule.requiresSlashPathContext ||
               self.hasSlashPathContext(in: tokens, startIndex: index, endIndex: cursor),
               !rule.requiresAtSignPunctuationApp || context.isAtSignPunctuationApp
            {
                return (rule, cursor)
            }
        }

        return nil
    }

    private static func hasSymbolContext(in tokens: [Token], startIndex: Int, endIndex: Int) -> Bool {
        let previous = self.significantToken(before: startIndex, in: tokens)
        let next = self.significantToken(atOrAfter: endIndex, in: tokens)

        if let previous, let next {
            return self.isSymbolContextToken(previous) || self.isSymbolContextToken(next) ||
                (self.isShortSymbolOperand(previous) && self.isShortSymbolOperand(next))
        }

        if let previous {
            return self.isSymbolContextToken(previous)
        }

        if let next {
            return self.isSymbolContextToken(next)
        }

        return false
    }

    private static func hasDotContext(in tokens: [Token], startIndex: Int, endIndex: Int) -> Bool {
        let previousIndex = self.significantTokenIndex(before: startIndex, in: tokens)
        let nextIndex = self.significantTokenIndex(atOrAfter: endIndex, in: tokens)
        let previous = previousIndex.map { tokens[$0] }
        let next = nextIndex.map { tokens[$0] }

        if previous.map(self.isPathSymbolText) == true || next.map(self.isPathSymbolText) == true {
            return true
        }

        let previousWord = previous?.normalizedWord
        let nextWord = next?.normalizedWord
        if let previousWord, let nextWord {
            if self.dotSuffixWords.contains(nextWord) {
                return !self.dotRejectedPreviousWords.contains(previousWord)
            }
            if self.dotPrefixWords.contains(previousWord) {
                return true
            }
            return self.isShortSymbolOperand(tokens[previousIndex ?? startIndex]) &&
                self.isShortSymbolOperand(tokens[nextIndex ?? endIndex])
        }

        if let previousWord {
            return self.dotPrefixWords.contains(previousWord)
        }

        if let nextWord {
            return self.dotSuffixWords.contains(nextWord)
        }

        return false
    }

    private static func hasSlashPathContext(in tokens: [Token], startIndex: Int, endIndex: Int) -> Bool {
        if self.hasSlashPathContextToken(before: startIndex, in: tokens) ||
            self.hasSlashPathContextToken(atOrAfter: endIndex, in: tokens)
        {
            return true
        }

        if let previousSlashIndex = self.significantTokenIndex(before: startIndex, in: tokens),
           self.isSpokenSlashToken(tokens[previousSlashIndex])
        {
            return self.hasSlashPathContextToken(before: previousSlashIndex, in: tokens)
        }

        if let nextSlashIndex = self.significantTokenIndex(atOrAfter: endIndex, in: tokens),
           self.isSpokenSlashToken(tokens[nextSlashIndex])
        {
            return self.hasSlashPathContextToken(atOrAfter: nextSlashIndex + 1, in: tokens)
        }

        return false
    }

    private static func hasSlashPathContextToken(before index: Int, in tokens: [Token]) -> Bool {
        guard let tokenIndex = self.significantTokenIndex(before: index, in: tokens) else { return false }
        return self.isSlashPathContextToken(tokens[tokenIndex])
    }

    private static func hasSlashPathContextToken(atOrAfter index: Int, in tokens: [Token]) -> Bool {
        guard let tokenIndex = self.significantTokenIndex(atOrAfter: index, in: tokens) else { return false }
        return self.isSlashPathContextToken(tokens[tokenIndex])
    }

    private static func significantToken(before index: Int, in tokens: [Token]) -> Token? {
        guard let tokenIndex = self.significantTokenIndex(before: index, in: tokens) else { return nil }
        return tokens[tokenIndex]
    }

    private static func significantTokenIndex(before index: Int, in tokens: [Token]) -> Int? {
        guard index > 0 else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            if !tokens[cursor].isHorizontalWhitespaceText {
                return cursor
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        return nil
    }

    private static func significantToken(atOrAfter index: Int, in tokens: [Token]) -> Token? {
        guard let tokenIndex = self.significantTokenIndex(atOrAfter: index, in: tokens) else { return nil }
        return tokens[tokenIndex]
    }

    private static func significantTokenIndex(atOrAfter index: Int, in tokens: [Token]) -> Int? {
        var cursor = index
        while cursor < tokens.count {
            if !tokens[cursor].isHorizontalWhitespaceText {
                return cursor
            }
            cursor += 1
        }
        return nil
    }

    private static func isSymbolContextToken(_ token: Token) -> Bool {
        switch token {
        case let .word(_, normalized):
            return self.rulesByFirstWord[normalized]?.contains { $0.symbol != "," && $0.symbol != "." } == true
        case let .text(text):
            return text.contains { self.symbolCommaCleanupCharacters.contains($0) }
        }
    }

    private static func isShortSymbolOperand(_ token: Token) -> Bool {
        switch token {
        case let .word(_, normalized):
            return normalized.count <= 2 || normalized.allSatisfy(\.isASCIIDigit)
        case let .text(text):
            return text.contains { self.symbolCommaCleanupCharacters.contains($0) }
        }
    }

    private static func isSlashPathContextToken(_ token: Token) -> Bool {
        switch token {
        case let .word(_, normalized):
            return self.slashPathContextWords.contains(normalized) ||
                self.dotSuffixWords.contains(normalized) ||
                normalized.allSatisfy(\.isASCIIDigit)
        case .text:
            return self.isPathSymbolText(token)
        }
    }

    private static func isPathSymbolText(_ token: Token) -> Bool {
        guard case let .text(text) = token else { return false }
        return text.contains { self.pathContextCharacters.contains($0) }
    }

    private static func isSpokenSlashToken(_ token: Token) -> Bool {
        token.normalizedWord == "slash" || token.normalizedWord == "forwardslash"
    }

    private static func removingGeneratedCommaNoise(from parts: [OutputPart]) -> [OutputPart] {
        guard parts.contains(where: { part in
            if case let .punctuation(symbol, _) = part { return symbol == "," }
            return false
        }) else {
            return parts
        }

        var result: [OutputPart] = []
        for index in parts.indices {
            if case let .punctuation(symbol, _) = parts[index],
               symbol == ",",
               self.shouldRemoveGeneratedComma(at: index, in: parts)
            {
                continue
            }
            result.append(parts[index])
        }
        return result
    }

    private static func shouldRemoveGeneratedComma(at index: Int, in parts: [OutputPart]) -> Bool {
        let previous = self.significantPart(before: index, in: parts)
        let next = self.significantPart(after: index, in: parts)

        if self.isGeneratedPunctuationPair(previous, next) {
            return true
        }

        if case let .some(.punctuation(symbol, _)) = next,
           symbol == "%",
           self.partEndsWithASCIIDigit(previous)
        {
            return true
        }

        return false
    }

    private static func significantPart(before index: Int, in parts: [OutputPart]) -> OutputPart? {
        guard index > 0 else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            if !parts[cursor].isHorizontalWhitespaceText {
                return parts[cursor]
            }
            if cursor == 0 { break }
            cursor -= 1
        }
        return nil
    }

    private static func significantPart(after index: Int, in parts: [OutputPart]) -> OutputPart? {
        var cursor = index + 1
        while cursor < parts.count {
            if !parts[cursor].isHorizontalWhitespaceText {
                return parts[cursor]
            }
            cursor += 1
        }
        return nil
    }

    private static func isGeneratedPunctuationPair(_ previous: OutputPart?, _ next: OutputPart?) -> Bool {
        guard case let .punctuation(previousSymbol, _) = previous,
              case let .punctuation(nextSymbol, _) = next,
              let previousCharacter = previousSymbol.first,
              let nextCharacter = nextSymbol.first
        else {
            return false
        }
        return self.punctuationPairCommaCleanupCharacters.contains(previousCharacter) &&
            self.punctuationPairCommaCleanupCharacters.contains(nextCharacter)
    }

    private static func partEndsWithASCIIDigit(_ part: OutputPart?) -> Bool {
        guard case let .text(text) = part else { return false }
        return text.last?.isASCIIDigit == true
    }

    private static func render(_ parts: [OutputPart]) -> String {
        var result = ""
        var index = 0
        var shouldOpenDoubleQuote = true
        var shouldOpenSingleQuote = true

        while index < parts.count {
            switch parts[index] {
            case let .text(text):
                result += text
                index += 1

            case let .punctuation(symbol, spacing):
                let resolvedSpacing: Spacing
                switch spacing {
                case .toggleDoubleQuote:
                    resolvedSpacing = shouldOpenDoubleQuote ? .leftAttached : .rightAttached
                    shouldOpenDoubleQuote.toggle()
                case .toggleSingleQuote:
                    resolvedSpacing = shouldOpenSingleQuote ? .leftAttached : .rightAttached
                    shouldOpenSingleQuote.toggle()
                default:
                    resolvedSpacing = spacing
                }

                switch resolvedSpacing {
                case .rightAttached:
                    self.removeTrailingHorizontalWhitespace(from: &result)
                    result += symbol
                    index += 1
                case .leftAttached:
                    result += symbol
                    index = self.indexSkippingWhitespace(after: index, in: parts)
                case .noSpaceAround:
                    self.removeTrailingHorizontalWhitespace(from: &result)
                    result += symbol
                    index = self.indexSkippingWhitespace(after: index, in: parts)
                case .spaceAround:
                    self.removeTrailingHorizontalWhitespace(from: &result)
                    if !result.isEmpty, result.last?.isNewline != true {
                        result += " "
                    }
                    result += symbol
                    index = self.indexSkippingWhitespace(after: index, in: parts)
                    if self.hasFollowingNonWhitespacePart(in: parts, from: index) {
                        result += " "
                    }
                case .toggleDoubleQuote, .toggleSingleQuote:
                    index += 1
                }
            }
        }

        return result
    }

    private static func removeTrailingHorizontalWhitespace(from text: inout String) {
        while text.last?.isHorizontalWhitespace == true {
            text.removeLast()
        }
    }

    private static func indexSkippingWhitespace(after index: Int, in parts: [OutputPart]) -> Int {
        var nextIndex = index + 1
        while nextIndex < parts.count {
            guard case let .text(text) = parts[nextIndex], text.allSatisfy(\.isHorizontalWhitespace) else {
                break
            }
            nextIndex += 1
        }
        return nextIndex
    }

    private static func hasFollowingNonWhitespacePart(in parts: [OutputPart], from index: Int) -> Bool {
        guard index < parts.count else { return false }
        for part in parts[index...] {
            switch part {
            case let .text(text):
                if text.contains(where: { !$0.isHorizontalWhitespace }) {
                    return true
                }
            case .punctuation:
                return true
            }
        }
        return false
    }

    private static let symbolCommaCleanupCharacters = Set<Character>(
        ["+", "=", "%", "-", "—", "–", "/", "\\", "@", "#", "$", "&", "*", "_", "|", "~", "^", "<", ">"]
    )

    private static let pathContextCharacters = Set<Character>(
        [".", "/", "\\", ":", "@", "_", "~"]
    )

    private static let dotSuffixWords: Set<String> = [
        "ai", "app", "c", "ca", "co", "com", "cpp", "css", "dev", "edu", "go",
        "gov", "h", "hpp", "html", "in", "io", "js", "json", "md", "me", "mm",
        "net", "org", "plist", "py", "rb", "rs", "sh", "swift", "ts", "txt",
        "uk", "us", "xml", "yaml", "yml", "zip",
    ]

    private static let dotPrefixWords: Set<String> = [
        "api", "app", "cdn", "docs", "file", "ftp", "http", "https", "localhost",
        "server", "staging", "v1", "v2", "v3", "web", "www",
    ]

    private static let dotRejectedPreviousWords: Set<String> = [
        "a", "an", "my", "our", "that", "the", "their", "this", "your",
    ]

    private static let slashPathContextWords: Set<String> = [
        "api", "applications", "bin", "desktop", "documents", "downloads", "etc",
        "file", "files", "folder", "home", "http", "https", "lib", "library",
        "local", "path", "private", "src", "source", "sources", "tmp", "url",
        "user", "users", "usr", "var", "volumes", "www",
    ]

    private static let punctuationPairCommaCleanupCharacters = Set<Character>(
        ["+", "=", "%", "-", "—", "–", "/", "\\", "@", "#", "$", "&", "*", "_", "|", "~", "^", "<", ">", "(", ")", "[", "]", "{", "}", "\"", "'", "`", ".", "?", "!", ":", ";"]
    )
}

private extension Character {
    var isPunctuationPhraseWordCharacter: Bool {
        self.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    var isHorizontalWhitespace: Bool {
        self.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }

    var isASCIIDigit: Bool {
        guard self.unicodeScalars.count == 1, let scalar = self.unicodeScalars.first else { return false }
        return (48...57).contains(scalar.value)
    }
}
