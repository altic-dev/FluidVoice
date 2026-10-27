import Foundation

@main
struct DictionaryReplacementDiagnosticsTests {
    static func main() throws {
        let regex = try NSRegularExpression(pattern: "\\bbut\\b", options: .caseInsensitive)
        let input = "🙂 But wait, but don't change butter."
        var events: [(NSRange, String, String)] = []
        let output = DictionaryReplacementProtection.replacingMatches(
            in: input,
            regex: regex,
            template: "buddamthss",
            canonical: nil,
            onReplacement: { events.append(($0, $1, $2)) }
        )
        precondition(output == "🙂 buddamthss wait, buddamthss don't change butter.")
        precondition(events.count == 2)
        precondition(Set(events.map { $0.1 }) == Set(["But", "but"]))
        for event in events {
            precondition((input as NSString).substring(with: event.0) == event.1)
            precondition(event.2 == "buddamthss")
        }
        precondition(output == DictionaryReplacementProtection.replacingMatches(
            in: input, regex: regex, template: "buddamthss", canonical: nil
        ), "Diagnostics must not change output")

        let canonical = try NSRegularExpression(pattern: "\\bbut better\\b", options: .caseInsensitive)
        events.removeAll()
        let protected = DictionaryReplacementProtection.replacingMatches(
            in: "but better but",
            regex: regex,
            template: "but better",
            canonical: canonical,
            onReplacement: { events.append(($0, $1, $2)) }
        )
        precondition(protected == "but better but better")
        precondition(events.count == 1 && events[0].0.location == 11)

        events.removeAll()
        for text in ["but", "butter", "", "no match"] {
            precondition(DictionaryReplacementProtection.replacingMatches(
                in: text,
                regex: regex,
                template: "but",
                canonical: nil,
                onReplacement: { events.append(($0, $1, $2)) }
            ) == text)
        }
        precondition(events.isEmpty, "Unchanged text must not report a replacement")

        let quoted = DictionaryReplacementDiagnostics.quoted("a\n\t\"b")
        precondition(!quoted.contains("\n") && !quoted.contains("\t"))
        precondition(quoted.contains("\\n") && quoted.contains("\\\""))
        precondition(DictionaryReplacementDiagnostics.quoted(String(repeating: "x", count: 10_000)).count == 163)
        print("PASS: replacement diagnostics, original UTF-16 ranges, canonical protection, no-ops, bounded escaping")
    }
}
