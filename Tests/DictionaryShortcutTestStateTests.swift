import Foundation

@main
enum DictionaryShortcutTestStateTests {
    static func main() {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        for count in [0, 1, 2, 3] {
            expect(DictionaryCaptureAction.title(failed: true, count: count) == "Record again", "Every failed capture offers retry")
        }
        expect(DictionaryCaptureAction.title(failed: false, count: 0) == "Record", "First capture")
        expect(DictionaryCaptureAction.title(failed: false, count: 1) == "Record more", "Additional successful capture")

        var test = DictionaryShortcutTestState()
        test.receive("ModelOpt", word: "ModelOpt")
        expect(test.text.isEmpty && test.result == .none, "Ignore stale output on opening the page")
        for eligibility in [(false, true, false), (true, false, false), (true, true, true)] {
            test.begin(editorFocused: eligibility.0, appActive: eligibility.1, dictionaryCapture: eligibility.2)
            test.stopped()
            test.receive("ModelOpt", word: "ModelOpt")
            expect(test.phase == .idle && test.result == .none && test.text.isEmpty, "Ignore unfocused, external, and training captures")
        }
        test.edit("I typed ModelOpt")
        expect(test.result == .none && test.successes == 0, "Typing is not a successful speech test")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        guard let first = test.attemptID else { preconditionFailure("Missing first attempt") }
        test.receive("ModelOpt", word: "ModelOpt")
        expect(test.phase == .recording && test.text.isEmpty, "Do not grade a partial capture")
        test.stopped()
        test.receive("I use modelopt.", word: "ModelOpt")
        expect(test.result == .recognized && test.successes == 1 && test.phase == .idle, "Accept the completed focused capture")
        test.receive("Unrelated dictation", word: "ModelOpt")
        expect(test.text == "I use modelopt." && test.successes == 1, "Late output cannot replace a completed test")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.expire(first)
        expect(test.phase == .recording, "An old timeout cannot cancel the next attempt")
        test.stopped()
        test.receive("I use modelopt.", word: "ModelOpt")
        expect(test.successes == 2, "Identical consecutive dictations each count once")

        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.stopped()
        test.receive("Model optional", word: "ModelOpt")
        expect(test.result == .missed && test.successes == 2, "Only a real nonempty miss offers more examples")
        test.edit("ModelOpt")
        expect(test.result == .none && test.successes == 2, "Editing clears stale feedback without counting a success")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.stopped()
        test.receive("  ", word: "ModelOpt")
        expect(test.result == .empty && test.phase == .idle, "Silence is not a pronunciation mismatch")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.stopped()
        guard let expiringID = test.attemptID else { preconditionFailure("Missing expiring attempt") }
        test.expire(expiringID)
        expect(test.phase == .idle && test.result == .empty, "Missing output has a bounded exit")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.stopped()
        test.cancel()
        test.receive("ModelOpt", word: "ModelOpt")
        expect(test.phase == .idle && test.text.isEmpty && test.successes == 2, "Leaving the app ignores late output")

        let samples: [Float] = [0.1, -0.1]
        test.receiveAudio(samples)
        expect(test.recording == nil, "Unowned audio cannot become the current test")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        guard let currentID = test.attemptID else { preconditionFailure("Missing current attempt") }
        test.stopped()
        test.receiveAudio(samples)
        test.receive("Model optional", word: "ModelOpt")
        expect(test.recording?.id == currentID && test.recording?.text == test.text, "Audio must belong to the exact textbox attempt")
        expect(test.recording?.samples == samples, "Automatic scoring must work without saving history")
        test.edit(test.text)
        expect(test.recording?.id == currentID, "Identical binding updates preserve the current recording")
        test.edit("edited text")
        expect(test.recording == nil, "Manual edits must invalidate old audio scores")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.stopped()
        test.receiveAudio(samples)
        test.cancel()
        test.receive("late text", word: "ModelOpt")
        expect(test.recording == nil, "Cancelled audio cannot become a later score")
        let historyID = UUID()
        test.useHistory(id: historyID, text: "older sentence", url: URL(fileURLWithPath: "/tmp/old.wav"))
        expect(test.recording?.id == historyID && test.text == "older sentence", "History and textbox must move together")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        expect(test.recording == nil, "The next live attempt replaces history immediately")

        expect(DictionaryWordTestResult.containsWord("C++", in: "I write C++."), "Literal punctuation")
        expect(DictionaryWordTestResult.containsWord("Nemo-Gym", in: "Use nemo-gym today."), "Hyphenated words")
        expect(!DictionaryWordTestResult.containsWord("cat", in: "category"), "Whole words only")
        expect(!DictionaryWordTestResult.containsWord("", in: "hello"), "An empty target cannot pass")
        print("Dictionary shortcut tests passed: retry labels, focused output, repeated tests, misses, empty output, stale results, cancellation, timeout, and manual edits.")
    }
}
