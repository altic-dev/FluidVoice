import Foundation

nonisolated enum MeetingMarkdownLists {
    enum ReturnAction: Equatable {
        case insert(String)
        /// Remove this many characters before the cursor (an empty list marker) and insert nothing.
        case endList(removeLength: Int)
        case none
    }

    private static let task = meetingMarkdownRegex(#"^([ \t]*)([-*]) \[[ xX]\](?=[ \t]|$)[ \t]?(.*)$"#)
    private static let bullet = meetingMarkdownRegex(#"^([ \t]*)([-*]) (.*)$"#)
    private static let ordered = meetingMarkdownRegex(#"^([ \t]*)(\d+)\. (.*)$"#)
    private static let toggle = meetingMarkdownRegex(#"^([ \t]*[-*] \[)([ xX])(\])(?=[ \t]|$)"#)

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
