import Foundation

extension SettingsStore {
    /// Language selection for the SenseVoiceSmall model. The raw values are stable
    /// persistence keys; `embedIndex` maps to the model's `lid_int_dict` language
    /// embedding input (auto = 0, Mandarin/zh = 3, Cantonese/yue = 13).
    enum SenseVoiceLanguage: String, CaseIterable, Identifiable, Codable {
        case cantonese
        case mandarin
        case auto

        var id: String { self.rawValue }

        /// SenseVoice `language` encoder input (embed index).
        var embedIndex: Int32 {
            switch self {
            case .auto: return 0
            case .mandarin: return 3
            case .cantonese: return 13
            }
        }

        var displayName: String {
            switch self {
            case .cantonese: return "Cantonese (粵語)"
            case .mandarin: return "Mandarin (國語)"
            case .auto: return "Auto Detect"
            }
        }
    }
}
