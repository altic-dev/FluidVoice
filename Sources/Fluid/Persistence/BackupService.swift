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
    let selectedSpeechModel: SettingsStore.SpeechModel
    let selectedCohereLanguage: SettingsStore.CohereLanguage
    let hotkeyShortcut: HotkeyShortcut
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
    let notifyAIProcessingFailures: Bool?
    let weekendsDontBreakStreak: Bool
    let fillerWords: [String]
    let removeFillerWordsEnabled: Bool
    let gaavModeEnabled: Bool
    let pauseMediaDuringTranscription: Bool
    /// Lossless capture of the unified media-behaviour enum (none / pause /
    /// duck). Optional so that backups created by older builds (which only
    /// wrote the legacy bool) still decode cleanly. New builds prefer this
    /// field on restore and fall back to the bool only when it's nil.
    let mediaBehaviorDuringTranscription: SettingsStore.MediaBehaviorDuringTranscription?
    let vocabularyBoostingEnabled: Bool
    let customDictionaryEntries: [SettingsStore.CustomDictionaryEntry]
    let selectedDictationPromptID: String?
    let dictationPromptOff: Bool?
    let dictationPromptRoutingScope: SettingsStore.PromptRoutingScope?
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

        do {
            let document = try decoder.decode(AppBackupDocument.self, from: data)
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
}

extension Notification.Name {
    static let settingsBackupDidRestore = Notification.Name("SettingsBackupDidRestore")
}
