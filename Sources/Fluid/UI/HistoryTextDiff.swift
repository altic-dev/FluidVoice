import Foundation

/// Bounded, presentation-only word/punctuation comparison. Whitespace is preserved verbatim.
struct HistoryTextDiff: Sendable {
    struct Run: Equatable, Sendable {
        var text: String
        let changed: Bool
    }

    let original: [Run]
    let final: [Run]
    var hasChanges: Bool { self.original.contains { $0.changed } || self.final.contains { $0.changed } }

    static func compare(original: String, final: String) -> HistoryTextDiff? {
        guard original.utf8.count + final.utf8.count <= 24_000 else { return nil }
        let pattern = #"\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        func tokens(_ text: String) -> [String] {
            expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { String(text[$0]) }
            }
        }
        let before = tokens(original)
        let after = tokens(final)
        guard before.count + after.count <= 2048 else { return nil }
        let changes = after.difference(from: before)
        var removed = Set<Int>()
        var added = Set<Int>()
        for change in changes {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): added.insert(offset)
            }
        }
        func runs(_ tokens: [String], changed: Set<Int>) -> [Run] {
            var result: [Run] = []
            for (index, token) in tokens.enumerated() {
                let isChanged = changed.contains(index)
                if result.last?.changed == isChanged {
                    result[result.count - 1].text += token
                } else {
                    result.append(Run(text: token, changed: isChanged))
                }
            }
            return result
        }
        return HistoryTextDiff(original: runs(before, changed: removed), final: runs(after, changed: added))
    }
}
