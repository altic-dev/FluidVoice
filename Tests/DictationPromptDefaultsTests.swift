import Foundation

@main enum DictationPromptDefaultsTests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        let legacy = SettingsStore.legacyBaseDictationPromptText()
        let current = SettingsStore.baseDictationPromptText()
        let body = "Keep my terminology."
        check(SettingsStore.stripBasePrompt(for: .dictate, from: legacy + "\n\n" + body) == body, "Saved old default prefix is removed before recomposition")
        check(SettingsStore.stripBasePrompt(for: .dictate, from: current + "\n\n" + body) == body, "Current default prefix is removed before recomposition")
        check(SettingsStore.stripBasePrompt(for: .dictate, from: legacy.uppercased() + "\n\n" + body) == body, "Case-insensitive legacy recognition remains compatible")
        check(SettingsStore.stripBasePrompt(for: .dictate, from: body) == body, "Unrecognized authored text is unchanged")
        check(SettingsStore.stripBasePrompt(for: .dictate, from: body + "\n" + legacy) == body + "\n" + legacy, "Only a prefix is removed")
        check(SettingsStore.stripBasePrompt(for: .edit, from: legacy) == legacy, "Dictation migration cannot strip an edit prompt")
        let recomposed = SettingsStore.combineBasePrompt(for: .dictate, with: SettingsStore.stripBasePrompt(for: .dictate, from: legacy + "\n\n" + body))
        check(recomposed == current + "\n\n" + body, "Saved default gets one current base and its original instructions")
        check(SettingsStore.combineBasePrompt(for: .dictate, with: current + "\n\n" + body) == current + "\n\n" + body, "Current prefix is never duplicated")
        let custom = legacy + "\n\nTranslate to French.  "
        check(SettingsStore.customPromptBody(custom, mode: .dictate) == custom, "Explicit custom prompts retain their exact old wording and whitespace")
        check(SettingsStore.customPromptBody("", mode: .dictate).isEmpty, "Explicit blank custom prompt stays blank")
        let template = current + "\n\nClean this: ${transcript}"
        let request = DictationPromptRequest(promptText: template, transcript: "At present.")
        check(request.systemPrompt.isEmpty && request.userContent == current + "\n\nClean this: At present.", "Default templates keep the single-user contract")
        check(!current.contains("JSON field"), "Shared base must not claim an envelope that explicit templates do not have")
        let defaultPrompt = SettingsStore.combineBasePrompt(for: .dictate, with: SettingsStore.defaultDictationPromptBodyText())
        check(defaultPrompt.hasPrefix("Make the smallest edits needed"), "Default cleanup uses minimal edits")
        let defaultRequest = DictationPromptRequest(promptText: defaultPrompt, transcript: "um can you help me")
        check(defaultRequest.systemPrompt == defaultPrompt, "Default instructions stay in the system message")
        check(defaultRequest.userContent == "{\"transcript\":\"um can you help me\"}", "Default transcript matches the JSON envelope described in its body")
        print("Passed \(count) dictation default compatibility assertions")
    }
}
