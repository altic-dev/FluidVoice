import Foundation

@main
struct VoiceTrainingAliasFilterTests {
    @MainActor
    static func main() async {
        let ordinary = ["NOW", "okay", "hello", "right now", "let’s do that", "fluid voice", "Apple", "May", "résumé", "こんにちは", "but", "you", "is"]
        let result = await VoiceTrainingAliasFilter.filter(ordinary + ["fluwidvois"])
        precondition(result.accepted == ordinary + ["fluwidvois"], "Normal words and phrases must remain teachable")
        precondition(result.rejected.isEmpty)

        let basic = ["the", "AND", "  a  ", "an.", "there!", "or"]
        let guarded = await VoiceTrainingAliasFilter.filter(basic + ["the voice", "and now", "now"])
        precondition(guarded.accepted == ["the voice", "and now", "now"])
        precondition(guarded.rejected == basic, "Only standalone basic words need a manual rule")
        precondition(guarded.rejectionMessage.contains("Replacement found these words:"))
        precondition(guarded.rejectionMessage.contains("“there”"))
        precondition(guarded.rejectionMessage.contains("single words"))
        let phrase = await VoiceTrainingAliasFilter.filter(["a an the", "the and", "there or"])
        precondition(phrase.accepted == ["a an the", "the and", "there or"], "Multiple basic words form a valid phrase")

        let invalid = ["123", "", "🙂", String(repeating: "x", count: 161)]
        let bounded = await VoiceTrainingAliasFilter.filter(invalid + Array(repeating: "hello", count: 25))
        precondition(bounded.accepted.count == 16, "Inspect at most twenty input samples")
        precondition(bounded.rejected == invalid)

        let task = Task { @MainActor in
            await VoiceTrainingAliasFilter.filter(["hello"])
        }
        task.cancel()
        let cancelled = await task.value
        precondition(cancelled.accepted.isEmpty)
        print("PASS: ordinary words, phrases, names, multilingual terms, basic-word guard, punctuation, invalid input, bounds, cancellation")
    }
}
