import Combine
import Foundation

extension SettingsStore {
    var englishSpellingPreference: EnglishSpellingPreference {
        get {
            EnglishSpellingPreference(
                storedValue: UserDefaults.standard.string(forKey: EnglishSpellingKeys.preference)
            )
        }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: EnglishSpellingKeys.preference)
        }
    }

    /// Append the stored English spelling instruction to a cleanup prompt.
    /// Empty prompts stay empty so an "off" path does not become a spelling-only prompt.
    func applyingEnglishSpellingPreference(to prompt: String) -> String {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return prompt
        }
        return self.englishSpellingPreference.applying(to: prompt)
    }
}

private enum EnglishSpellingKeys {
    static let preference = "EnglishSpellingPreference"
}
