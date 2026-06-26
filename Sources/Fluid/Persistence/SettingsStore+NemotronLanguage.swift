import Foundation

extension SettingsStore {
    struct NemotronLanguage: RawRepresentable, CaseIterable, Identifiable, Codable, Hashable {
        let rawValue: String

        var id: String { self.rawValue }

        nonisolated init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.rawValue = try container.decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self.rawValue)
        }

        static let auto = Self(rawValue: "auto")
        static let english = Self(rawValue: "en")

        static let allCases: [Self] = [
            "auto", "es", "it", "pt", "hi", "ko", "en", "de-DE", "fr", "ru",
            "tr", "vi-VN", "nl", "ja-JP", "ar", "uk", "pl", "nb-NO", "fi",
            "zh-CN", "cs", "bg", "sk", "sv", "hr", "ro", "et", "da", "hu",
            "el-GR", "he-IL", "lt-LT", "sl-SI", "lv-LV", "mt-MT", "th-TH", "nn-NO",
        ].map(Self.init(rawValue:))

        static func supportedLanguage(rawValue: String) -> Self? {
            let mappedValue = self.legacyRawValueMap[rawValue] ?? rawValue
            return self.allCases.first { $0.rawValue == mappedValue }
        }

        var displayName: String {
            if let name = Self.displayNames[self.rawValue] {
                return name
            }

            let normalized = Self.normalizedIdentifier(self.rawValue)
            let localized = Locale.current.localizedString(forIdentifier: normalized)
                ?? Locale(identifier: "en_US").localizedString(forIdentifier: normalized)
            if let localized, localized.isEmpty == false {
                return "\(localized) (\(self.rawValue))"
            }
            return self.rawValue
        }

        var compactDisplayName: String {
            switch self.rawValue {
            case "auto": return "Auto"
            case "hi": return "Hindi"
            case "en": return "English"
            default:
                return self.displayName
                    .components(separatedBy: " (")
                    .first ?? self.displayName
            }
        }

        private static let displayNames: [String: String] = [
            "auto": "Auto Detect",
            "es": "Spanish (es-US, es-ES)",
            "it": "Italian (it-IT)",
            "pt": "Portuguese (pt-BR, pt-PT)",
            "hi": "Hindi (hi-IN)",
            "ko": "Korean (ko-KR)",
            "en": "English (en-US, en-GB)",
            "de-DE": "German (de-DE)",
            "fr": "French (fr-FR, fr-CA)",
            "ru": "Russian (ru-RU)",
            "tr": "Turkish (tr-TR)",
            "vi-VN": "Vietnamese (vi-VN)",
            "nl": "Dutch (nl-NL)",
            "ja-JP": "Japanese (ja-JP)",
            "ar": "Arabic (ar-AR)",
            "uk": "Ukrainian (uk)",
            "pl": "Polish (pl-PL) - Alpha",
            "nb-NO": "Norwegian Bokmal (nb-NO) - Alpha",
            "fi": "Finnish (fi-FI) - Alpha",
            "zh-CN": "Mandarin (zh-CN) - Alpha",
            "cs": "Czech (cs-CZ) - Alpha",
            "bg": "Bulgarian (bg-BG) - Alpha",
            "sk": "Slovak (sk-SK) - Alpha",
            "sv": "Swedish (sv-SE) - Alpha",
            "hr": "Croatian (hr-HR) - Alpha",
            "ro": "Romanian (ro-RO) - Alpha",
            "et": "Estonian (et-EE) - Alpha",
            "da": "Danish (da-DK) - Alpha",
            "hu": "Hungarian (hu-HU) - Alpha",
            "el-GR": "Greek (el-GR) - Experimental",
            "he-IL": "Hebrew (he-IL) - Experimental",
            "lt-LT": "Lithuanian (lt-LT) - Experimental",
            "sl-SI": "Slovenian (sl-SI) - Experimental",
            "lv-LV": "Latvian (lv-LV) - Experimental",
            "mt-MT": "Maltese (mt-MT) - Experimental",
            "th-TH": "Thai (th-TH) - Experimental",
            "nn-NO": "Norwegian Nynorsk (nn-NO) - Experimental",
        ]

        private static let legacyRawValueMap: [String: String] = [
            "el": "el-GR",
            "lt": "lt-LT",
            "lv": "lv-LV",
            "sl": "sl-SI",
        ]

        private static func normalizedIdentifier(_ identifier: String) -> String {
            switch identifier {
            case "enGB": return "en-GB"
            case "esES": return "es-ES"
            default: return identifier
            }
        }
    }
}
