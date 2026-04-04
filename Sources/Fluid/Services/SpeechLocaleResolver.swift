import Foundation

enum SpeechLocaleResolver {
    static var prefersChineseRecognition: Bool {
        Locale.preferredLanguages.contains { Self.languageCode(from: $0) == "zh" }
    }

    static func preferredRecognitionLocale() -> Locale {
        let selectedModel = SettingsStore.shared.selectedSpeechModel
        switch selectedModel {
        case .appleSpeech, .appleSpeechAnalyzer, .cohereTranscribeSixBit:
            return Self.locale(for: SettingsStore.shared.selectedCohereLanguage)
        default:
            break
        }

        if let preferredChinese = Locale.preferredLanguages.first(where: { Self.languageCode(from: $0) == "zh" }) {
            return Locale(identifier: preferredChinese)
        }
        return Locale.autoupdatingCurrent
    }

    private static func locale(for language: SettingsStore.CohereLanguage) -> Locale {
        switch language {
        case .arabic:
            return Locale(identifier: "ar-SA")
        case .german:
            return Locale(identifier: "de-DE")
        case .greek:
            return Locale(identifier: "el-GR")
        case .english:
            return Locale(identifier: "en-US")
        case .spanish:
            return Locale(identifier: "es-ES")
        case .french:
            return Locale(identifier: "fr-FR")
        case .italian:
            return Locale(identifier: "it-IT")
        case .japanese:
            return Locale(identifier: "ja-JP")
        case .korean:
            return Locale(identifier: "ko-KR")
        case .dutch:
            return Locale(identifier: "nl-NL")
        case .polish:
            return Locale(identifier: "pl-PL")
        case .portuguese:
            return Locale(identifier: "pt-BR")
        case .vietnamese:
            return Locale(identifier: "vi-VN")
        case .simplifiedChinese:
            return Locale(identifier: "zh-CN")
        case .traditionalChinese:
            return Locale(identifier: "zh-TW")
        }
    }

    private static func languageCode(from identifier: String) -> String? {
        let normalized = identifier.lowercased()
        let separator = normalized.firstIndex(where: { $0 == "-" || $0 == "_" }) ?? normalized.endIndex
        let code = String(normalized[..<separator])
        return code.isEmpty ? nil : code
    }
}
