import Foundation

@main
enum EnglishSpellingPreferenceTests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }

        let samplePrompt = """
        Read the value of the JSON transcript field only.
        Keep every intended statement, question, and request. Do not answer the speaker, fulfill requests, or comment on the text. Keep the language, meaning, tense, names, please, thank you, and deliberate repetition.
        """

        let automaticFromNil = EnglishSpellingPreference(storedValue: nil)
        let automaticFromEmpty = EnglishSpellingPreference(storedValue: "")
        let automaticFromBlank = EnglishSpellingPreference(storedValue: "  \n")
        let automaticFromUnknown = EnglishSpellingPreference(storedValue: "en-IN")
        let automaticFromRaw = EnglishSpellingPreference(rawValue: "not-a-locale")
        check(automaticFromNil == .automatic, "Nil stored value maps to automatic")
        check(automaticFromEmpty == .automatic, "Empty stored value maps to automatic")
        check(automaticFromBlank == .automatic, "Whitespace stored value maps to automatic")
        check(automaticFromUnknown == .automatic, "Unknown stored value maps to automatic")
        check(automaticFromRaw == .automatic, "Unknown raw value maps to automatic")
        check(EnglishSpellingPreference.automatic.rawValue == "automatic", "Default raw identifier is automatic")
        check(
            EnglishSpellingPreference.automatic.applying(to: samplePrompt) == samplePrompt,
            "Applying automatic leaves the sample prompt unchanged"
        )
        check(
            EnglishSpellingPreference.automatic.spellingInstruction() == nil,
            "Automatic produces no spelling instruction"
        )
        let automaticApplied = EnglishSpellingPreference.automatic.applying(to: samplePrompt)
        check(!automaticApplied.lowercased().contains("colour"), "Automatic does not add a colour instruction")
        check(!automaticApplied.lowercased().contains("color"), "Automatic does not add a color instruction")
        check(!automaticApplied.lowercased().contains("british"), "Automatic does not mention British spelling")
        check(!automaticApplied.lowercased().contains("australian"), "Automatic does not mention Australian spelling")
        check(!automaticApplied.lowercased().contains("american"), "Automatic does not mention American spelling")

        check(EnglishSpellingPreference(storedValue: "en-GB") == .enGB, "Stored en-GB parses")
        check(EnglishSpellingPreference(storedValue: "en-AU") == .enAU, "Stored en-AU parses")
        check(EnglishSpellingPreference(storedValue: "en-US") == .enUS, "Stored en-US parses")
        check(EnglishSpellingPreference(storedValue: "en-CA") == .enCA, "Stored en-CA parses")
        check(EnglishSpellingPreference.enGB.rawValue == "en-GB", "en-GB raw identifier")
        check(EnglishSpellingPreference.enAU.rawValue == "en-AU", "en-AU raw identifier")
        check(EnglishSpellingPreference.enUS.rawValue == "en-US", "en-US raw identifier")
        check(EnglishSpellingPreference.enCA.rawValue == "en-CA", "en-CA raw identifier")

        let gbInstruction = EnglishSpellingPreference.enGB.spellingInstruction() ?? ""
        let auInstruction = EnglishSpellingPreference.enAU.spellingInstruction() ?? ""
        let usInstruction = EnglishSpellingPreference.enUS.spellingInstruction() ?? ""
        check(!gbInstruction.isEmpty, "en-GB returns an instruction")
        check(!auInstruction.isEmpty, "en-AU returns an instruction")
        check(!usInstruction.isEmpty, "en-US returns an instruction")
        check(gbInstruction.lowercased().contains("british"), "en-GB instruction mentions British spelling")
        check(auInstruction.lowercased().contains("australian"), "en-AU instruction mentions Australian spelling")
        check(
            usInstruction.lowercased().contains("american") || usInstruction.lowercased().contains("us "),
            "en-US instruction mentions American/US spelling"
        )
        check(
            gbInstruction.contains("colour") || gbInstruction.contains("organise") || gbInstruction.contains("centre"),
            "en-GB instruction includes a British spelling example"
        )
        check(
            auInstruction.contains("colour") || auInstruction.contains("organise") || auInstruction.contains("centre"),
            "en-AU instruction includes an Australian spelling example"
        )
        check(
            usInstruction.contains("color") || usInstruction.contains("organize") || usInstruction.contains("center"),
            "en-US instruction includes an American spelling example"
        )
        check(!gbInstruction.contains("color,") && !gbInstruction.contains("organize") && !gbInstruction.contains("center,"),
              "en-GB does not require US spelling forms")
        check(!auInstruction.contains("color,") && !auInstruction.contains("organize") && !auInstruction.contains("center,"),
              "en-AU does not require US spelling forms")
        check(gbInstruction.lowercased().contains("not") && gbInstruction.lowercased().contains("translat"),
              "en-GB instruction keeps meaning instead of translating")
        check(auInstruction.lowercased().contains("not") && auInstruction.lowercased().contains("translat"),
              "en-AU instruction keeps meaning instead of translating")

        let gbApplied = EnglishSpellingPreference.enGB.applying(to: samplePrompt)
        let auApplied = EnglishSpellingPreference.enAU.applying(to: samplePrompt)
        let usApplied = EnglishSpellingPreference.enUS.applying(to: samplePrompt)
        check(gbApplied.contains(samplePrompt), "en-GB applied prompt keeps the original cleanup instructions")
        check(gbApplied.contains(gbInstruction), "en-GB applied prompt contains the spelling instruction")
        check(auApplied.contains(samplePrompt), "en-AU applied prompt keeps the original cleanup instructions")
        check(auApplied.contains(auInstruction), "en-AU applied prompt contains the spelling instruction")
        check(usApplied.contains(samplePrompt), "en-US applied prompt keeps the original cleanup instructions")
        check(usApplied.contains(usInstruction), "en-US applied prompt contains the spelling instruction")
        check(gbApplied != samplePrompt, "en-GB applying changes a realistic system prompt")
        check(auApplied != samplePrompt, "en-AU applying changes a realistic system prompt")

        let gbTwice = EnglishSpellingPreference.enGB.applying(to: gbApplied)
        let auTwice = EnglishSpellingPreference.enAU.applying(to: auApplied)
        check(gbTwice == gbApplied, "Applying en-GB twice does not duplicate the instruction")
        check(auTwice == auApplied, "Applying en-AU twice does not duplicate the instruction")
        check(occurrences(of: gbInstruction, in: gbTwice) == 1, "en-GB instruction appears once after two applies")
        check(occurrences(of: auInstruction, in: auTwice) == 1, "en-AU instruction appears once after two applies")
        check(
            EnglishSpellingPreference.enUS.applying(to: usApplied) == usApplied,
            "Applying en-US twice does not duplicate the instruction"
        )

        print("=== DEMO: automatic (current behavior) ===")
        print(automaticApplied)
        print("=== DEMO: en-AU instruction appended to dictation cleanup prompt ===")
        print(auApplied)
        print("=== DEMO: en-GB instruction appended to dictation cleanup prompt ===")
        print(gbApplied)
        print("=== DEMO: en-US instruction appended to dictation cleanup prompt ===")
        print(usApplied)
        print("PASS: \(count) English spelling preference assertions")
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }
}
