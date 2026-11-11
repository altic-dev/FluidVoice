import Foundation

@main
enum TextNormalizationTests {
    struct Fixtures: Decodable {
        struct Case: Decodable {
            let input: String
            let expected: String
            let phase: FluidTextNormalizer.Phase?
            let languageCode: String?
            let repeatable: Bool?
            let preparedText: String?
        }

        let schemaVersion: Int
        let cases: [Case]
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/Fluid/TextNormalization/Resources/fluid-text-emoji-en.json"))
        guard let emoji = SpokenEmojiRules(data: data) else { fatalError("Invalid bundled emoji catalog") }
        let normalizer = FluidTextNormalizer(emoji: emoji)
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: root.appendingPathComponent("Tests/TextNormalization/fixtures.json")))
        precondition(fixtures.schemaVersion == 1)
        var failures = 0
        for fixture in fixtures.cases {
            let phase = fixture.phase ?? .afterCleanup
            let language = fixture.languageCode ?? "en"
            let candidate = fixture.preparedText.map { normalizer.preservingLiteralCommands(in: fixture.input, from: $0, languageCode: language) } ?? fixture.input
            let actual = normalizer.normalize(candidate, phase: phase, languageCode: language)
            if actual != fixture.expected {
                print("FAIL: \(fixture.input.debugDescription) -> \(actual.debugDescription); expected \(fixture.expected.debugDescription)")
                failures += 1
            }
            if fixture.repeatable ?? true, normalizer.normalize(actual, phase: phase, languageCode: language) != actual {
                print("FAIL repeated normalization: \(fixture.input.debugDescription)")
                failures += 1
            }
        }

        // Every shipped name must resolve, not just a hand-picked list of common emoji.
        guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = catalog["names"] as? [String: String] else { fatalError("Invalid test catalog") }
        for (name, symbol) in names where normalizer.normalize(name + " emoji", phase: .afterCleanup) != symbol {
            print("FAIL catalog name: \(name)")
            failures += 1
        }

        let input = "five billion parameters at one hundred twenty tokens per second fire emoji"
        let expected = "5B parameters at 120 tokens per second 🔥"
        let prepared = normalizer.normalize(input, phase: .beforeCleanup)
        precondition(prepared == expected)
        // Disabled cleanup and failed cleanup both finalize the prepared input.
        precondition(normalizer.normalize(prepared, phase: .afterCleanup) == expected)
        precondition(normalizer.normalize(input, phase: .afterCleanup) == expected)
        let escaped = normalizer.normalize("literal fire emoji", phase: .beforeCleanup)
        precondition(normalizer.normalize(escaped, phase: .afterCleanup) == "fire emoji")
        precondition(normalizer.normalize(" 5b parameters ", phase: .afterCleanup) == " 5B parameters ")
        precondition(normalizer.normalize(" 7m parameters ", phase: .afterCleanup) == " 7M parameters ")

        // Missing/corrupt/unsupported resources disable emoji only; quantities still work.
        precondition(SpokenEmojiRules(data: Data("broken".utf8)) == nil)
        var unsupported = catalog
        unsupported["schemaVersion"] = 2
        let unsupportedData = try JSONSerialization.data(withJSONObject: unsupported)
        precondition(SpokenEmojiRules(data: unsupportedData) == nil)
        precondition(FluidTextNormalizer().normalize(input, phase: .afterCleanup) == "5B parameters at 120 tokens per second fire emoji")
        let oversized = String(repeating: "five euros ", count: 7000)
        precondition(normalizer.normalize(oversized, phase: .afterCleanup) == oversized)
        precondition(normalizer.normalize("five euros\0fire emoji", phase: .afterCleanup) == "five euros\0fire emoji")

        // Immutable instances can be shared safely across rapid, independent dictations.
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let phase: FluidTextNormalizer.Phase = index.isMultiple(of: 2) ? .beforeCleanup : .afterCleanup
            precondition(normalizer.normalize(input, phase: phase) == expected)
        }
        #if TEST_APP_ADAPTER
        await NormalizationLoadingTests.run(data: data)
        #endif
        if failures > 0 { exit(1) }
        print("PASS: \(fixtures.cases.count) fixtures, \(names.count) catalog names, cleanup boundaries, resource failures, input bounds, 200 concurrent calls")
    }
}
