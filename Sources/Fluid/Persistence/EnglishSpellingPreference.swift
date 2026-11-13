import Foundation

/// Regional English spelling for dictation cleanup / Fluid Intelligence.
/// Apple Speech locale selection is separate; this only appends a prompt instruction.
struct EnglishSpellingPreference: RawRepresentable, Equatable, Hashable, Codable {
    let rawValue: String

    static let automatic = EnglishSpellingPreference(identifier: "automatic")
    static let enUS = EnglishSpellingPreference(identifier: "en-US")
    static let enGB = EnglishSpellingPreference(identifier: "en-GB")
    static let enAU = EnglishSpellingPreference(identifier: "en-AU")
    static let enCA = EnglishSpellingPreference(identifier: "en-CA")

    private init(identifier: String) {
        self.rawValue = identifier
    }

    /// Unknown or empty values map to `automatic`.
    init(rawValue: String) {
        self.init(storedValue: rawValue)
    }

    /// Parse a persisted string. Unknown, empty, and missing values are `automatic`.
    init(storedValue: String?) {
        let trimmed = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch trimmed {
        case "en-US":
            self = .enUS
        case "en-GB":
            self = .enGB
        case "en-AU":
            self = .enAU
        case "en-CA":
            self = .enCA
        case "automatic":
            self = .automatic
        default:
            self = .automatic
        }
    }

    /// Short spelling instruction for cleanup models. `automatic` has none.
    func spellingInstruction() -> String? {
        switch self.rawValue {
        case "en-US":
            return "Use American English spelling (for example color, organize, center, enrollment). Keep the original language and meaning; do not translate."
        case "en-GB":
            return "Use British English spelling (for example colour, organise, centre, enrolment). Keep the original language and meaning; do not translate."
        case "en-AU":
            return "Use Australian English spelling (for example colour, organise, centre, enrolment). Keep the original language and meaning; do not translate."
        case "en-CA":
            return "Use Canadian English spelling (for example colour, organize, centre, enrolment). Keep the original language and meaning; do not translate."
        default:
            return nil
        }
    }

    /// Append the spelling instruction when present. Idempotent. Leaves `automatic` unchanged.
    func applying(to prompt: String) -> String {
        guard let instruction = self.spellingInstruction() else {
            return prompt
        }
        if prompt.contains(instruction) {
            return prompt
        }
        if prompt.isEmpty {
            return instruction
        }
        return "\(prompt)\n\n\(instruction)"
    }
}
