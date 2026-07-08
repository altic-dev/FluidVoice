import Foundation

struct DictationLiteralOutputPlan: Equatable {
    enum Step: Equatable {
        case text(String)
    }

    let steps: [Step]

    var plainText: String {
        self.steps.reduce(into: "") { result, step in
            if case let .text(text) = step {
                result += text
            }
        }
    }

    static func plain(_ text: String) -> DictationLiteralOutputPlan {
        DictationLiteralOutputPlan(steps: [.text(text)])
    }
}

extension ASRService {
    static func applyDictationLiteralFormatting(
        _ text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> String {
        DictationLiteralFormatter.applyDictationLiteralFormatting(
            text,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle
        )
    }

    static func applySlashCommandFormatting(_ text: String) -> String {
        DictationLiteralFormatter.applySlashCommandFormatting(text)
    }

    static func applyMentionFormatting(
        _ text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> String {
        DictationLiteralFormatter.applyMentionFormatting(
            text,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle
        )
    }

    static func makeDictationLiteralOutputPlan(
        for text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> DictationLiteralOutputPlan {
        DictationLiteralFormatter.makeOutputPlan(
            for: text,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle
        )
    }

    static func applyTerminalLiteralAutocompleteSpacing(
        _ text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> String {
        DictationLiteralFormatter.applyTerminalLiteralAutocompleteSpacing(
            text,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle
        )
    }
}

private enum DictationLiteralFormatter {
    private enum SlashCommandMatchKind {
        case literal
        case spoken
    }

    private static let slashCommandLiteralRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])/\s+([A-Za-z][A-Za-z0-9_-]{1,39})(?![A-Za-z0-9_-])"#,
        options: []
    )

    private static let slashCommandSpokenRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_])(?:forward\s+slash|slash)\s+([A-Za-z][A-Za-z0-9_-]{1,39})(?![A-Za-z0-9_-])"#,
        options: []
    )

    private static let slashCommandRejectedTokens: Set<String> = [
        "a", "an", "and", "as", "at", "back", "backslash", "be", "been", "being",
        "bin", "by", "comma", "desktop", "documents", "dot", "downloads", "etc",
        "for", "forward", "from", "home", "in", "is", "library", "local", "mark",
        "of", "on", "or", "period", "private", "question", "quote", "quotes",
        "semicolon", "slash", "slashes", "source", "sources", "src", "the", "tmp",
        "to", "user", "users", "usr", "var", "volumes", "was", "were", "with",
        "without",
    ]

    private static let slashCommandSpokenLeadInWords: Set<String> = [
        "call", "choose", "do", "enter", "execute", "open", "pick", "press", "run",
        "say", "select", "send", "start", "try", "type", "use", "write",
    ]

    private enum MentionMatchKind {
        case explicit
        case relaxed
    }

    private static let explicitMentionRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_@])(?i:(?:at\s+(?:sign|the\s+rate)|tag|mention))\s+([A-Za-z][A-Za-z0-9_.-]*(?:\s+[A-Z][A-Za-z0-9_.-]*){0,2})(?![A-Za-z0-9_.-])"#,
        options: []
    )

    private static let relaxedMentionRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_@])[Aa]t\s+([A-Z][A-Za-z0-9_.-]*(?:\s+[A-Z][A-Za-z0-9_.-]*){0,2})(?![A-Za-z0-9_.-])"#,
        options: []
    )

    private static let terminalMentionTokenRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_@])@([A-Za-z][A-Za-z0-9_.-]*(?:\s+[A-Z][A-Za-z0-9_.-]*){0,2})$"#,
        options: []
    )

    private static let standaloneSlashCommandRegex = try? NSRegularExpression(
        pattern: #"^/[A-Za-z][A-Za-z0-9_-]{1,39}$"#,
        options: []
    )

    private static let mentionRejectedTokens: Set<String> = [
        "a", "an", "airport", "breakfast", "brunch", "class", "dinner", "home",
        "hotel", "house", "lunch", "meeting", "night", "noon", "office", "place",
        "restaurant", "school", "shop", "store", "the", "today", "tomorrow",
        "work", "yesterday",
    ]

    private static let relaxedMentionLeadInWords: Set<String> = [
        "add", "ask", "cc", "dm", "hello", "hey", "hi", "invite", "message",
        "notify", "ping", "send", "tag", "tell",
    ]

    static func applyDictationLiteralFormatting(
        _ text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> String {
        let commandFormatted = self.applySlashCommandFormatting(text)
        return self.applyMentionFormatting(
            commandFormatted,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle
        )
    }

    static func applySlashCommandFormatting(_ text: String) -> String {
        guard !text.isEmpty,
              text.contains("/") || text.range(of: "slash", options: .caseInsensitive) != nil
        else {
            return text
        }

        let literalFormatted = self.replacingSlashCommandMatches(
            in: text,
            regex: self.slashCommandLiteralRegex,
            kind: .literal
        )
        return self.replacingSlashCommandMatches(
            in: literalFormatted,
            regex: self.slashCommandSpokenRegex,
            kind: .spoken
        )
    }

    static func applyMentionFormatting(
        _ text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> String {
        guard !text.isEmpty,
              text.range(of: "at ", options: .caseInsensitive) != nil ||
              text.range(of: "tag ", options: .caseInsensitive) != nil ||
              text.range(of: "mention ", options: .caseInsensitive) != nil
        else {
            return text
        }

        let explicitFormatted = self.replacingMentionMatches(
            in: text,
            regex: self.explicitMentionRegex,
            kind: .explicit
        )
        guard self.isRelaxedMentionApp(appName: appName, bundleID: bundleID, windowTitle: windowTitle) else {
            return explicitFormatted
        }
        return self.replacingMentionMatches(
            in: explicitFormatted,
            regex: self.relaxedMentionRegex,
            kind: .relaxed
        )
    }

    static func makeOutputPlan(
        for text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> DictationLiteralOutputPlan {
        .plain(
            self.applyTerminalLiteralAutocompleteSpacing(
                text,
                appName: appName,
                bundleID: bundleID,
                windowTitle: windowTitle
            )
        )
    }

    static func applyTerminalLiteralAutocompleteSpacing(
        _ text: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil
    ) -> String {
        guard text.last?.isHorizontalWhitespace == true else { return text }

        let withoutTrailingWhitespace = self.removingTrailingHorizontalWhitespace(from: text)
        guard !withoutTrailingWhitespace.isEmpty else { return text }

        if self.isSlashCommandAutocompleteApp(appName: appName, bundleID: bundleID, windowTitle: windowTitle),
           self.matchesWholeString(withoutTrailingWhitespace, regex: self.standaloneSlashCommandRegex)
        {
            return withoutTrailingWhitespace
        }

        if self.isRelaxedMentionApp(appName: appName, bundleID: bundleID, windowTitle: windowTitle),
           self.matchesTerminalToken(withoutTrailingWhitespace, regex: self.terminalMentionTokenRegex)
        {
            return withoutTrailingWhitespace
        }

        return text
    }

    private static func replacingSlashCommandMatches(
        in text: String,
        regex: NSRegularExpression?,
        kind: SlashCommandMatchKind
    ) -> String {
        guard let regex else { return text }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let token = source.substring(with: match.range(at: 1))
            guard self.isValidSlashCommandToken(token) else { continue }
            if kind == .spoken,
               !self.hasSpokenSlashCommandContext(in: source, matchLocation: match.range.location)
            {
                continue
            }
            result.replaceCharacters(in: match.range, with: "/\(token.lowercased())")
        }

        return result as String
    }

    private static func isValidSlashCommandToken(_ token: String) -> Bool {
        let lowercased = token.lowercased()
        guard !self.slashCommandRejectedTokens.contains(lowercased),
              lowercased.first?.isASCIIAlphabetic == true,
              lowercased.last?.isASCIICommandTokenCharacter == true
        else {
            return false
        }

        return lowercased.allSatisfy(\.isASCIICommandTokenCharacter)
    }

    private static func hasSpokenSlashCommandContext(in text: NSString, matchLocation: Int) -> Bool {
        guard matchLocation > 0 else { return true }
        let prefix = text.substring(to: matchLocation).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return true }

        if let last = prefix.unicodeScalars.last,
           CharacterSet(charactersIn: ".!?:;([{").contains(last)
        {
            return true
        }

        let words = prefix.split { scalar in
            !(scalar.isASCIIAlphabetic || scalar.isASCIIDigit || scalar == "-" || scalar == "_")
        }
        guard let previousWord = words.last else { return true }
        return self.slashCommandSpokenLeadInWords.contains(String(previousWord).lowercased())
    }

    private static func replacingMentionMatches(
        in text: String,
        regex: NSRegularExpression?,
        kind: MentionMatchKind
    ) -> String {
        guard let regex else { return text }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let name = source.substring(with: match.range(at: 1))
            guard self.isValidMentionName(name, kind: kind),
                  !self.isPossessiveMentionMatch(in: source, match: match)
            else {
                continue
            }
            if kind == .relaxed,
               !self.hasRelaxedMentionContext(in: source, matchLocation: match.range.location)
            {
                continue
            }
            result.replaceCharacters(in: match.range, with: "@\(name.trimmingCharacters(in: .whitespaces))")
        }

        return result as String
    }

    private static func isValidMentionName(_ name: String, kind: MentionMatchKind) -> Bool {
        let tokens = name
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty, tokens.count <= 3 else { return false }

        for token in tokens {
            let lowercased = token.lowercased()
            guard !self.mentionRejectedTokens.contains(lowercased),
                  token.allSatisfy(\.isASCIIMentionTokenCharacter)
            else {
                return false
            }
            if kind == .relaxed,
               token.first?.isASCIIAlphabetic != true ||
               token.first?.isUppercase != true
            {
                return false
            }
        }

        return true
    }

    private static func isPossessiveMentionMatch(in text: NSString, match: NSTextCheckingResult) -> Bool {
        let end = match.range.location + match.range.length
        guard end < text.length else { return false }
        let next = text.substring(with: NSRange(location: end, length: 1))
        return next == "'" || next == "’"
    }

    private static func hasRelaxedMentionContext(in text: NSString, matchLocation: Int) -> Bool {
        guard matchLocation > 0 else { return true }
        let prefix = text.substring(to: matchLocation).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return true }

        if let last = prefix.unicodeScalars.last,
           CharacterSet(charactersIn: ".!?:;([{").contains(last)
        {
            return true
        }

        let words = prefix.split { scalar in
            !(scalar.isASCIIAlphabetic || scalar.isASCIIDigit || scalar == "-" || scalar == "_")
        }
        guard let previousWord = words.last else { return true }
        return self.relaxedMentionLeadInWords.contains(String(previousWord).lowercased())
    }

    private static func isRelaxedMentionApp(appName: String?, bundleID: String?, windowTitle: String?) -> Bool {
        let haystack = [appName, bundleID, windowTitle]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return haystack.contains("slack") ||
            haystack.contains("discord") ||
            haystack.contains("teams")
    }

    private static func isSlashCommandAutocompleteApp(appName: String?, bundleID: String?, windowTitle: String?) -> Bool {
        let haystack = [appName, bundleID, windowTitle]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return haystack.contains("codex") ||
            haystack.contains("chatgpt") ||
            haystack.contains("claude") ||
            haystack.contains("cursor") ||
            haystack.contains("windsurf")
    }

    private static func matchesWholeString(_ text: String, regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range) else { return false }
        return match.range.location == 0 && match.range.length == range.length
    }

    private static func matchesTerminalToken(_ text: String, regex: NSRegularExpression?) -> Bool {
        guard let regex else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func removingTrailingHorizontalWhitespace(from text: String) -> String {
        var result = text
        while result.last?.isHorizontalWhitespace == true {
            result.removeLast()
        }
        return result
    }
}

private extension Character {
    var isASCIIAlphabetic: Bool {
        guard self.unicodeScalars.count == 1, let scalar = self.unicodeScalars.first else { return false }
        return (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    var isASCIIDigit: Bool {
        guard self.unicodeScalars.count == 1, let scalar = self.unicodeScalars.first else { return false }
        return (48...57).contains(scalar.value)
    }

    var isASCIICommandTokenCharacter: Bool {
        self.isASCIIAlphabetic || self.isASCIIDigit || self == "-" || self == "_"
    }

    var isASCIIMentionTokenCharacter: Bool {
        self.isASCIIAlphabetic || self.isASCIIDigit || self == "-" || self == "_" || self == "."
    }

    var isHorizontalWhitespace: Bool {
        self.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }
}
