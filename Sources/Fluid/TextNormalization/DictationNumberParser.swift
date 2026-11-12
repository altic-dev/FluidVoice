import Foundation

/// Strict English quantities for dictation rules. Unsupported forms stay untouched.
nonisolated enum DictationNumberParser {
    static let small: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Decimal] = [
        "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    static let tokenPattern = "(?:[0-9]+(?:,[0-9]{3})*(?:\\.[0-9]+)?|"
        + (small.keys.sorted() + ["hundred", "thousand", "million", "billion", "and", "point"]).joined(separator: "|") + ")"
    static let phrasePattern = "(?:[0-9]+(?:,[0-9]{3})*(?:\\.[0-9]+)?|" + small.keys.sorted().joined(separator: "|") + ")" + "(?:[ \\t-]+" + tokenPattern + "){0,15}"

    static func parse(_ text: String) -> Decimal? {
        let words = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "-" }).map(String.init)
        guard !words.isEmpty, words.count <= 16, words.allSatisfy({ $0.count <= 18 }) else { return nil }
        var total: Decimal = 0
        var group: [String] = []
        var previousScale: Decimal = 1_000_000_000_000
        for word in words {
            if let scale = scales[word] {
                guard scale < previousScale, let value = self.group(group), value > 0, value < 1000 else { return nil }
                total += value * scale
                previousScale = scale
                group.removeAll(keepingCapacity: true)
            } else {
                group.append(word)
            }
        }
        if group.first == "and", total > 0 {
            group.removeFirst()
            guard !group.isEmpty else { return nil }
        }
        guard group.isEmpty || self.group(group) != nil else { return nil }
        let tail = self.group(group) ?? 0
        guard tail < previousScale else { return nil }
        return total + tail
    }

    private static func group(_ words: [String]) -> Decimal? {
        guard !words.isEmpty else { return nil }
        if words.count == 1, let first = words.first, first.first?.isNumber == true {
            return Decimal(string: first.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
        }
        if let point = words.firstIndex(of: "point") {
            guard point > 0, point < words.count - 1,
                  let integer = self.integer(Array(words[..<point])) else { return nil }
            let digits = words[(point + 1)...].compactMap { word -> String? in
                if let value = small[word], value < 10 { return String(value) }
                if word.count == 1, word.first?.isNumber == true { return word }
                return nil
            }
            guard digits.count == words.count - point - 1, digits.count <= 6 else { return nil }
            return Decimal(string: "\(integer).\(digits.joined())", locale: Locale(identifier: "en_US_POSIX"))
        }
        return self.integer(words).map { Decimal($0) }
    }

    private static func integer(_ words: [String]) -> Int? {
        if words.count == 1 { return self.small[words[0]] ?? Int(words[0]) }
        if words.count >= 2, words[1] == "hundred", let leading = small[words[0]], (1...9).contains(leading) {
            var rest = Array(words.dropFirst(2))
            if rest.isEmpty { return leading * 100 }
            if rest.first == "and" { rest.removeFirst() }
            guard let value = self.underHundred(rest), value > 0 else { return nil }
            return leading * 100 + value
        }
        return self.underHundred(words)
    }

    private static func underHundred(_ words: [String]) -> Int? {
        if words.count == 1 { return self.small[words[0]] }
        guard words.count == 2, let tens = small[words[0]], tens >= 20, tens % 10 == 0,
              let units = small[words[1]], (1...9).contains(units) else { return nil }
        return tens + units
    }

    static func string(_ number: Decimal) -> String {
        NSDecimalNumber(decimal: number).stringValue
    }
}
