import Foundation

nonisolated enum MeetingMarkdownStyle: Hashable {
    case heading(level: Int), bold, italic, code, codeBlock, quote, listMarker, taskBox(isDone: Bool), done, link, marker
}

nonisolated struct MeetingMarkdownSpan: Hashable {
    let range: NSRange
    let style: MeetingMarkdownStyle
}

/// Shared by the styler and the list rules.
nonisolated func meetingMarkdownRegex(_ pattern: String) -> NSRegularExpression {
    // Patterns are literals; a failure is a programming error.
    try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) // swiftlint:disable:this force_try
}

/// Styles markdown in place. The text is never changed, so markers stay visible (dimmed via `.marker`).
/// Underscore emphasis (`_x_`, `__x__`) is not supported.
nonisolated enum MeetingMarkdownStyler {
    private static let heading = meetingMarkdownRegex(#"^(#{1,3})[ \t]+\S.*$"#)
    private static let quote = meetingMarkdownRegex(#"^[ \t]*(>)"#)
    private static let task = meetingMarkdownRegex(#"^[ \t]*([-*] \[([ xX])\])(?:[ \t](.*))?$"#)
    private static let list = meetingMarkdownRegex(#"^[ \t]*([-*]|\d+\.)[ \t]"#)
    private static let code = meetingMarkdownRegex(#"(`)([^`\n]+)(`)"#)
    private static let bold = meetingMarkdownRegex(#"(\*\*)(?=\S)(.+?)(?<=\S)(\*\*)"#)
    private static let italic = meetingMarkdownRegex(#"(?<![*\w])(\*)(?=[^\s*])([^*\n]+?)(?<=\S)(\*)(?![*\w])"#)
    private static let link = meetingMarkdownRegex(#"(\[)([^\]\n]+)(\]\([^)\s]+\))"#)

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
