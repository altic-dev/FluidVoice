#if DICTIONARY_CORRECTION_STANDALONE
import Foundation

struct DictionaryLearningAudioEvidence {}
struct DictionaryNegativeCorrection {}

@main struct DictionaryCorrectionDetectorTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        self.checks += 1
        precondition(condition, message)
    }

    static func candidate(_ before: String, _ after: String) -> AutomaticDictionaryCorrectionCandidate? {
        let range = NSRange(location: 0, length: (before as NSString).length)
        guard let change = AutomaticDictionaryCorrectionDetector.textChange(before: before, after: after) else { return nil }
        let atEnd = AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(change, after: after, insertedRange: range)
        guard AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(change, insertedRange: range, allowsInsertionAtEnd: atEnd) else { return nil }
        return AutomaticDictionaryCorrectionDetector.candidate(before: before, after: after, insertedRange: range, allowsInsertionAtEnd: true)
    }

    static func main() {
        let rejected = [
            ("cat", "cats"), ("cats", "cat"), ("box", "boxes"), ("party", "parties"),
            ("file", "file's"), ("file", "file’s"), ("walk", "walked"), ("walk", "walking"),
            ("move", "moving"), ("move", "moved"), ("The cat sits", "The cats sits"),
            ("I use tools", "I use better tools"), ("I use tools daily", "I use tools often daily"),
            ("cat", "black cat"), ("cat", "cat today"), ("black cat", "cat"),
            ("hello", "hello"), ("hello", "hello!"), ("hello", ""),
            ("use foo now", "use bar baz now"), ("use foo now", "use bar,baz now"),
            ("use foo now", "use bar.baz now"), ("use foo now", "use bar/baz now"),
            ("I met foo bar today", "I met baz today"),
        ]
        for (before, after) in rejected {
            self.expect(self.candidate(before, after) == nil, "Reject \(before) → \(after)")
        }
        let accepted = [
            ("Jon", "John"), ("Barat", "Barath"), ("Barad", "Barath"),
            ("Dflash", "DFlash"), ("manimekali", "Manimekalai"), ("Jhon", "John"),
            ("O'Neal", "O'Neill"), ("Anne-Mari", "Anne-Marie"), ("Jose", "José"),
            ("Jo", "Jos"), ("東京", "京都"), ("foo", "Kubernetes"), ("helllo", "hello"),
        ]
        for (before, after) in accepted {
            let result = self.candidate(before, after)
            self.expect(result?.heardText == before && result?.correctedText == after, "Keep \(before) → \(after)")
        }
        let punctuated = self.candidate("I met Barat.", "I met Barath.")
        self.expect(punctuated?.heardText == "Barat" && punctuated?.correctedText == "Barath", "Sentence punctuation")
        let before = "Title: I met Barat"
        self.expect(
            AutomaticDictionaryCorrectionDetector.candidate(before: before, after: "Heading: I met Barat", insertedRange: (before as NSString).range(of: "I met Barat")) == nil,
            "Outside insertion"
        )
        // Evaluate the accumulated edit, as the observer does after rapid keystrokes.
        for intermediate in ["better t", "better to", "better too", "better tool", "better tools"] {
            self.expect(self.candidate("I use tools", "I use " + intermediate) == nil, "Typed phrase never becomes a word correction")
        }
        self.expect(self.candidate("I met Barat", "I met Barath") != nil, "Typed spelling repair")
        self.expect(self.candidate("I met Barat", "I met Barat") == nil, "Undo returns to original")
        print("\(self.checks) correction detector checks passed")
    }
}
#endif
