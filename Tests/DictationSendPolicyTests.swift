import Foundation

@main
enum DictationSendPolicyTests {
    static func main() {
        struct Case {
            let name: String
            let automatic: Bool
            let spoken: Bool
            let text: String
            let eligible: Bool
            let expected: DictationSendPolicy.Action?
        }
        let cases: [Case] = [
            .init(name: "off only inserts text", automatic: false, spoken: false, text: "Hello.", eligible: true, expected: nil),
            .init(name: "every dictation presses Enter without a phrase", automatic: true, spoken: false, text: "Hello.", eligible: true, expected: .enter),
            .init(name: "repeated dictation still requests Enter", automatic: true, spoken: false, text: "Hello.", eligible: true, expected: .enter),
            .init(name: "empty dictation does not submit an existing draft", automatic: true, spoken: false, text: "", eligible: true, expected: nil),
            .init(name: "whitespace does not submit", automatic: true, spoken: false, text: " \n\t ", eligible: true, expected: nil),
            .init(name: "explicit spoken command keeps its configured key", automatic: true, spoken: true, text: "Hello.", eligible: true, expected: .spokenSend),
            .init(name: "spoken send works independently", automatic: false, spoken: true, text: "Hello.", eligible: true, expected: .spokenSend),
            .init(name: "spoken send can still send an existing draft", automatic: false, spoken: true, text: "", eligible: true, expected: .spokenSend),
            .init(name: "cancelled or sandboxed output cannot auto send", automatic: true, spoken: false, text: "Hello.", eligible: false, expected: nil),
            .init(name: "cancelled spoken output cannot send", automatic: true, spoken: true, text: "Hello.", eligible: false, expected: nil),
        ]
        for test in cases {
            let actual = DictationSendPolicy.action(
                automaticEnterEnabled: test.automatic,
                spokenSendRequested: test.spoken,
                text: test.text,
                deliveryEligible: test.eligible
            )
            precondition(actual == test.expected, test.name)
        }
        // Enabling automatic Enter alone must not interpret ordinary words as
        // Spoken Send commands or silently strip them from the transcript.
        let parse = SpokenSendParser.parseArmed("Please send it", phrase: "send it", enabled: false, wasArmed: false)
        precondition(parse.text == "Please send it" && !parse.shouldSend, "automatic Enter preserves normal speech")
        precondition(DictationSendPolicy.action(automaticEnterEnabled: true, spokenSendRequested: parse.shouldSend, text: parse.text, deliveryEligible: true) == .enter)
        print("PASS: \(cases.count + 2) dictation send cases, including phrase-free Enter, empty output, cancellation and Spoken Send coexistence")
    }
}
