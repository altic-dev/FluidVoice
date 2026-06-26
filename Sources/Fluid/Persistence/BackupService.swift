import Foundation

struct BackupFileVersion: Codable, Equatable {
    let major: Int
    let minor: Int

    static let current = BackupFileVersion(major: 1, minor: 0)
}

struct SettingsBackupPayload: Codable, Equatable {
    let selectedProviderID: String
    let selectedModelByProvider: [String: String]
    let savedProviders: [SettingsStore.SavedProvider]
    let modelReasoningConfigs: [String: SettingsStore.ModelReasoningConfig]
    let privateAIPrefixKVCacheEnabled: Bool?
    let selectedSpeechModel: SettingsStore.SpeechModel
    let selectedCohereLanguage: SettingsStore.CohereLanguage
    let selectedNemotronLanguage: SettingsStore.NemotronLanguage?
    let selectedAppleSpeechLocaleIdentifier: String?
    let hotkeyShortcut: HotkeyShortcut
    // Older backup files only contain hotkeyShortcut; nil restores that legacy single shortcut.
    // swiftlint:disable:next discouraged_optional_collection
    let primaryDictationShortcuts: [HotkeyShortcut]?
    let promptModeHotkeyShortcut: HotkeyShortcut
    let promptModeShortcutEnabled: Bool
    let promptModeSelectedPromptID: String?
    let secondaryDictationPromptOff: Bool?
    let commandModeHotkeyShortcut: HotkeyShortcut
    let commandModeShortcutEnabled: Bool
    let commandModeSelectedModel: String?
    let commandModeSelectedProviderID: String
    let commandModeConfirmBeforeExecute: Bool
    let commandModeLinkedToGlobal: Bool
    let rewriteModeHotkeyShortcut: HotkeyShortcut
    let rewriteModeShortcutEnabled: Bool
    let rewriteModeSelectedModel: String?
    let rewriteModeSelectedProviderID: String
    let rewriteModeLinkedToGlobal: Bool
    let cancelRecordingHotkeyShortcut: HotkeyShortcut
    let showThinkingTokens: Bool
    let hideFromDockAndAppSwitcher: Bool
    let showMainWindowAtLoginLaunch: Bool?
    let accentColorOption: SettingsStore.AccentColorOption
    let transcriptionStartSound: SettingsStore.TranscriptionStartSound
    let transcriptionSoundVolume: Float
    let transcriptionSoundIndependentVolume: Bool
    let autoUpdateCheckEnabled: Bool
    let betaReleasesEnabled: Bool
    let enableDebugLogs: Bool
    let shareAnonymousAnalytics: Bool
    let pressAndHoldMode: Bool
    let hotkeyMode: HotkeyActivationMode?
    let enableStreamingPreview: Bool
    let enableAIStreaming: Bool
    let copyTranscriptionToClipboard: Bool
    let textInsertionMode: SettingsStore.TextInsertionMode
    let preferredInputDeviceUID: String?
    let preferredOutputDeviceUID: String?
    let visualizerNoiseThreshold: Double
    let overlayPosition: SettingsStore.OverlayPosition
    let overlayBottomOffset: Double
    let overlaySize: SettingsStore.OverlaySize
    let transcriptionPreviewCharLimit: Int
    let userTypingWPM: Int
    let saveTranscriptionHistory: Bool
    let saveAudioWithTranscriptionHistory: Bool?
    let audioHistoryBudgetGB: Double?
    let notifyAIProcessingFailures: Bool?
    let weekendsDontBreakStreak: Bool
    let fillerWords: [String]
    let removeFillerWordsEnabled: Bool
    let gaavModeEnabled: Bool
    let gaavLowercaseFirstLetterEnabled: Bool?
    let gaavRemoveTrailingPeriodEnabled: Bool?
    let continuousDictationModeEnabled: Bool?
    let continuousDictationSpacingEnabled: Bool?
    let contextAwareCapitalizationEnabled: Bool?
    let pauseMediaDuringTranscription: Bool
    let vocabularyBoostingEnabled: Bool
    let customDictionaryEntries: [SettingsStore.CustomDictionaryEntry]
    let selectedDictationPromptID: String?
    let dictationPromptOff: Bool?
    let dictationPromptRoutingScope: SettingsStore.PromptRoutingScope?
    let editPromptOff: Bool?
    let selectedEditPromptID: String?
    let editPromptRoutingScope: SettingsStore.PromptRoutingScope?
    let defaultDictationPromptOverride: String?
    let defaultEditPromptOverride: String?
}

struct AppBackupDocument: Codable, Equatable {
    let schemaVersion: BackupFileVersion
    let appVersion: String
    let exportedAt: Date
    let settings: SettingsBackupPayload
    let promptProfiles: [SettingsStore.DictationPromptProfile]
    let appPromptBindings: [SettingsStore.AppPromptBinding]
    let transcriptionHistory: [TranscriptionHistoryEntry]
}

enum BackupServiceError: LocalizedError {
    case unsupportedSchemaVersion(BackupFileVersion)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "This backup uses an unsupported schema version (\(version.major).\(version.minor))."
        case .invalidJSON:
            return "The selected backup file is not a valid FluidVoice backup."
        }
    }
}

final class BackupService {
    static let shared = BackupService()

    private init() {}

    func makeBackupDocument() -> AppBackupDocument {
        AppBackupDocument(
            schemaVersion: .current,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            exportedAt: Date(),
            settings: SettingsStore.shared.makeBackupPayload(),
            promptProfiles: SettingsStore.shared.dictationPromptProfiles,
            appPromptBindings: SettingsStore.shared.appPromptBindings,
            transcriptionHistory: TranscriptionHistoryStore.shared.makeBackupPayload()
        )
    }

    func encode(_ document: AppBackupDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    func decode(_ data: Data) throws -> AppBackupDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let migratedData = Self.dataByMigratingLegacyPrivateAIKeys(in: data) ?? data

        do {
            let document = try decoder.decode(AppBackupDocument.self, from: migratedData)
            try self.validate(document)
            return document
        } catch let error as BackupServiceError {
            throw error
        } catch {
            throw BackupServiceError.invalidJSON
        }
    }

    func restore(_ document: AppBackupDocument) throws {
        try self.validate(document)
        SettingsStore.shared.restore(
            from: document.settings,
            promptProfiles: document.promptProfiles,
            appPromptBindings: document.appPromptBindings
        )
        TranscriptionHistoryStore.shared.restore(from: document.transcriptionHistory)
        NotificationCenter.default.post(name: .settingsBackupDidRestore, object: nil)
    }

    func suggestedFilename(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "FluidVoice_Backup_\(formatter.string(from: date)).json"
    }

    private func validate(_ document: AppBackupDocument) throws {
        guard document.schemaVersion.major == BackupFileVersion.current.major else {
            throw BackupServiceError.unsupportedSchemaVersion(document.schemaVersion)
        }
    }

    private static func dataByMigratingLegacyPrivateAIKeys(in data: Data) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var settings = root["settings"] as? [String: Any],
              settings["privateAIPrefixKVCacheEnabled"] == nil
        else {
            return nil
        }

        let legacyPrefixCacheKey = ["fluid", "Int", "elligence", "PrefixKVCacheEnabled"].joined()
        guard let legacyValue = settings[legacyPrefixCacheKey] else {
            return nil
        }

        settings["privateAIPrefixKVCacheEnabled"] = legacyValue
        root["settings"] = settings
        return try? JSONSerialization.data(withJSONObject: root)
    }
}

extension Notification.Name {
    static let settingsBackupDidRestore = Notification.Name("SettingsBackupDidRestore")
}
