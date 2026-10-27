import Foundation

/// A one-line excerpt of a result with the query words marked for bold.
///
/// Zeppelin returns ids and scores, not match positions, so the words are found
/// again here: case-insensitively and by prefix, which also covers the stemmed
/// forms a prefix reaches (`meeting` marks `meetings`). Forms a prefix does not
/// reach (`ran` for `run`) are not marked; the row still shows.
nonisolated enum AppSearchSnippet {
    /// Characters kept around the first match.
    static let window = 110

    static func words(in query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    static func make(_ text: String, query: String) -> AttributedString {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let words = self.words(in: query)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        // Excerpt around the earliest match, or the start of the text.
        let first = words
            .compactMap { flat.range(of: $0, options: options)?.lowerBound }
            .min() ?? flat.startIndex
        var start = first
        var leading = self.window / 4
        while start > flat.startIndex, leading > 0 {
            start = flat.index(before: start)
            leading -= 1
        }
        let end = flat.index(start, offsetBy: self.window, limitedBy: flat.endIndex) ?? flat.endIndex
        var excerpt = String(flat[start..<end])
        if start > flat.startIndex {
            excerpt = "…" + excerpt
        }
        if end < flat.endIndex {
            excerpt += "…"
        }

        var result = AttributedString(excerpt)
        for word in words {
            var searchFrom = excerpt.startIndex
            while let range = excerpt.range(of: word, options: options, range: searchFrom..<excerpt.endIndex) {
                if let attributed = Range(range, in: result) {
                    result[attributed].inlinePresentationIntent = .stronglyEmphasized
                }
                searchFrom = range.upperBound
            }
        }
        return result
    }
}
