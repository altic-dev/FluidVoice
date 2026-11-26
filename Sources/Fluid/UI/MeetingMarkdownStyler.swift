import Foundation

nonisolated enum MeetingMarkdownStyle: Hashable {
    case heading(level: Int), bold, italic, code, codeBlock, quote, listMarker, taskBox(isDone: Bool), done, link, marker
}

nonisolated struct MeetingMarkdownSpan: Hashable {
    let range: NSRange
    let style: MeetingMarkdownStyle
}

private nonisolated func markdownRegex(_ pattern: String) -> NSRegularExpression {
    // Patterns are literals; a failure is a programming error.
    try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) // swiftlint:disable:this force_try
}

/// Styles markdown in place. The text is never changed, so markers stay visible (dimmed via `.marker`).
/// Underscore emphasis (`_x_`, `__x__`) is not supported.
nonisolated enum MeetingMarkdownStyler {
    private static let heading = markdownRegex(#"^(#{1,3})[ \t]+\S.*$"#)
    private static let quote = markdownRegex(#"^[ \t]*(>)"#)
    private static let task = markdownRegex(#"^[ \t]*([-*] \[([ xX])\])(?:[ \t](.*))?$"#)
    private static let list = markdownRegex(#"^[ \t]*([-*]|\d+\.)[ \t]"#)
    private static let code = markdownRegex(#"(`)([^`\n]+)(`)"#)
    private static let bold = markdownRegex(#"(\*\*)(?=\S)(.+?)(?<=\S)(\*\*)"#)
    private static let italic = markdownRegex(#"(?<![*\w])(\*)(?=[^\s*])([^*\n]+?)(?<=\S)(\*)(?![*\w])"#)
    private static let link = markdownRegex(#"(\[)([^\]\n]+)(\]\([^)\s]+\))"#)

    static func spans(in text: String) -> [MeetingMarkdownSpan] {
        let string = text as NSString
        var spans: [MeetingMarkdownSpan] = []
        var inFence = false
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let trimmed = string.substring(with: line).trimmingCharacters(in: .whitespaces)
            if let fence = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil {
                // A fence closed on its own line ("```js x```") is a one-line code block, not an opening fence.
                let isOneLine = trimmed.dropFirst(3).contains(fence)
                if !isOneLine { inFence.toggle() }
                spans.append(.init(range: line, style: .codeBlock))
                if !isOneLine { spans.append(.init(range: line, style: .marker)) }
            } else if inFence {
                spans.append(.init(range: line, style: .codeBlock))
            } else {
                spans += self.lineSpans(text, line: line)
            }
        }
        return spans
    }

    private static func lineSpans(_ text: String, line: NSRange) -> [MeetingMarkdownSpan] {
        var spans: [MeetingMarkdownSpan] = []
        if let match = self.heading.firstMatch(in: text, range: line) {
            spans += [.init(range: match.range, style: .heading(level: match.range(at: 1).length)), .init(range: match.range(at: 1), style: .marker)]
        }
        if let match = self.quote.firstMatch(in: text, range: line) {
            spans += [.init(range: line, style: .quote), .init(range: match.range(at: 1), style: .marker)]
        }
        if let match = self.task.firstMatch(in: text, range: line) {
            let isDone = (text as NSString).substring(with: match.range(at: 2)) != " "
            spans.append(.init(range: match.range(at: 1), style: .taskBox(isDone: isDone)))
            if isDone, match.range(at: 3).length > 0 { spans.append(.init(range: match.range(at: 3), style: .done)) }
        } else if let match = self.list.firstMatch(in: text, range: line) {
            spans.append(.init(range: match.range(at: 1), style: .listMarker))
        }
        var codeRanges: [NSRange] = []
        for match in self.code.matches(in: text, range: line) {
            codeRanges.append(match.range)
            spans += [.init(range: match.range, style: .code), .init(range: match.range(at: 1), style: .marker), .init(range: match.range(at: 3), style: .marker)]
        }
        // Only markers inside code cancel a match, so "**see `x` here**" stays bold.
        let markersOutsideCode = { (match: NSTextCheckingResult) in
            [match.range(at: 1), match.range(at: 3)].allSatisfy { marker in !codeRanges.contains { NSIntersectionRange($0, marker).length > 0 } }
        }
        for (expression, style) in [(self.bold, MeetingMarkdownStyle.bold), (self.italic, .italic), (self.link, .link)] {
            for match in expression.matches(in: text, range: line) where markersOutsideCode(match) {
                let styled = style == .link ? match.range(at: 2) : match.range
                spans += [.init(range: styled, style: style), .init(range: match.range(at: 1), style: .marker), .init(range: match.range(at: 3), style: .marker)]
            }
        }
        return spans
    }
}

nonisolated enum MeetingMarkdownLists {
    enum ReturnAction: Equatable {
        case insert(String)
        /// Remove this many characters before the cursor (an empty list marker) and insert nothing.
        case endList(removeLength: Int)
        case none
    }

    private static let task = markdownRegex(#"^([ \t]*)([-*]) \[[ xX]\](?=[ \t]|$)[ \t]?(.*)$"#)
    private static let bullet = markdownRegex(#"^([ \t]*)([-*]) (.*)$"#)
    private static let ordered = markdownRegex(#"^([ \t]*)(\d+)\. (.*)$"#)
    private static let toggle = markdownRegex(#"^([ \t]*[-*] \[)([ xX])(\])(?=[ \t]|$)"#)

    /// `line` is the text from the start of the line to the cursor.
    static func returnAction(forLine line: String) -> ReturnAction {
        let string = line as NSString
        let full = NSRange(location: 0, length: string.length)
        func groups(_ expression: NSRegularExpression) -> (indent: String, marker: String, content: String)? {
            guard let match = expression.firstMatch(in: line, range: full) else { return nil }
            return (string.substring(with: match.range(at: 1)), string.substring(with: match.range(at: 2)), string.substring(with: match.range(at: 3)))
        }
        if let item = groups(self.task) {
            return item.content.isEmpty ? .endList(removeLength: string.length) : .insert("\n\(item.indent)\(item.marker) [ ] ")
        }
        if let item = groups(self.bullet) {
            return item.content.isEmpty ? .endList(removeLength: string.length) : .insert("\n\(item.indent)\(item.marker) ")
        }
        if let item = groups(self.ordered) {
            return item.content.isEmpty ? .endList(removeLength: string.length) : .insert("\n\(item.indent)\((Int(item.marker) ?? 0) + 1). ")
        }
        return .none
    }

    static func toggledTask(_ line: String) -> String? {
        let string = line as NSString
        guard let match = self.toggle.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) else { return nil }
        let isDone = string.substring(with: match.range(at: 2)) != " "
        return string.replacingCharacters(in: match.range(at: 2), with: isDone ? " " : "x")
    }
}
