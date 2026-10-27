import Foundation

/// Text rules go first: words covered by a saved spelling, or already spelled correctly, belong to
/// the text layer and an audio match never touches them. An audio match replaces only the other
/// words, and always a whole run of words that looks like the target, never half of a mishearing.
nonisolated enum DictionaryAudioSpan {
    private static let maximumRunLength = 5
    /// In the grey zone the written words must look at least this much like the word or a saved
    /// spelling (1 = identical). Real grey-zone uses scored 0.57-0.86, e.g. "boob tea" for Booptie.
    static let greyZoneMinimumResemblance = 0.5
    /// A neighbouring word joins only when it makes the run clearly closer, so a stray letter
    /// shared with the target ("is" + "Nickdom" against "Snigdham") does not pull it in.
    private static let joinMargin = 0.1

    /// Lowercased letters and digits only, so "Nickdom?" and "nickdom" compare equal.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Indices of transcript words that a saved spelling, or an already correct word, covers.
    static func textClaimed(words: [String], entries: [SettingsStore.CustomDictionaryEntry]) -> Set<Int> {
        let tokens = words.map(self.normalized)
        var claimed = Set<Int>()
        for entry in entries {
            for phrase in entry.triggers + [entry.replacement] {
                let parts = phrase.split(whereSeparator: \.isWhitespace).map { self.normalized(String($0)) }.filter { !$0.isEmpty }
                guard !parts.isEmpty, parts.count <= tokens.count else { continue }
                for start in 0...(tokens.count - parts.count) where Array(tokens[start..<(start + parts.count)]) == parts {
                    claimed.formUnion(start..<(start + parts.count))
                }
            }
        }
        return claimed
    }

    /// The contiguous run of unclaimed words, starting from the words the match touched, that looks
    /// most like one of `targets`. Neighbouring words join only while they make the run look closer.
    static func span(words: [String], touched: [Int], claimed: Set<Int>, targets: [String]) -> ClosedRange<Int>? {
        let tokens = words.map(self.normalized)
        let goals = targets.map(self.normalized).filter { !$0.isEmpty }
        guard !goals.isEmpty else { return nil }
        func score(_ run: ClosedRange<Int>) -> Double {
            let text = run.map { tokens[$0] }.joined()
            return goals.map { self.similarity(text, $0) }.max() ?? 0
        }
        func free(_ index: Int) -> Bool { tokens.indices.contains(index) && !claimed.contains(index) }

        var best: (run: ClosedRange<Int>, score: Double)?
        for group in self.groups(touched.filter(free).sorted()) {
            var run = group
            var current = score(run)
            while true {
                var options: [(run: ClosedRange<Int>, gain: Double)] = []
                if free(run.lowerBound - 1), run.count < self.maximumRunLength {
                    let grown = (run.lowerBound - 1)...run.upperBound
                    options.append((grown, score(grown) - current - self.joinMargin))
                }
                if free(run.upperBound + 1), run.count < self.maximumRunLength {
                    let grown = run.lowerBound...(run.upperBound + 1)
                    options.append((grown, score(grown) - current - self.joinMargin))
                }
                if run.count > 1 {
                    for shrunk in [(run.lowerBound + 1)...run.upperBound, run.lowerBound...(run.upperBound - 1)] {
                        options.append((shrunk, score(shrunk) - current))
                    }
                }
                guard let next = options.max(by: { $0.gain < $1.gain }), next.gain > 1e-9 else { break }
                run = next.run
                current = score(next.run)
            }
            if best.map({ current > $0.score }) ?? true { best = (run, current) }
        }
        return best?.run
    }

    /// How much a run of words looks like the closest target, 0-1.
    static func resemblance(words: [String], run: ClosedRange<Int>, targets: [String]) -> Double {
        guard run.lowerBound >= 0, run.upperBound < words.count else { return 0 }
        let text = run.map { self.normalized(words[$0]) }.joined()
        return targets.map { self.similarity(text, self.normalized($0)) }.max() ?? 0
    }

    /// 1 for identical text, falling toward 0 as more letters must change.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var previous = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var row = [i] + [Int](repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = row
        }
        let distance = x.isEmpty ? y.count : previous[y.count]
        return 1 - Double(distance) / Double(max(x.count, y.count))
    }

    private static func groups(_ sorted: [Int]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for index in sorted {
            if let last = result.last, last.upperBound + 1 == index {
                result[result.count - 1] = last.lowerBound...index
            } else {
                result.append(index...index)
            }
        }
        return result
    }
}
