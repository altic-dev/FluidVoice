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
    let vocabularyBoostingEnabled: Bool
    let customDictionaryEntries: [SettingsStore.CustomDictionaryEntry]
    // Added in auto-learn dictionary PR — decode with defaults for older backups.
    let autoLearnCustomDictionaryEnabled: Bool
    let autoLearnCustomDictionarySuggestions: [SettingsStore.AutoLearnSuggestion]
    let selectedDictationPromptID: String?
    let dictationPromptOff: Bool?
    let selectedEditPromptID: String?
    let defaultDictationPromptOverride: String?
    let defaultEditPromptOverride: String?

    private enum CodingKeys: String, CodingKey {
        case selectedProviderID, selectedModelByProvider, savedProviders, modelReasoningConfigs
        case selectedSpeechModel, selectedCohereLanguage
        case hotkeyShortcut, promptModeHotkeyShortcut, promptModeShortcutEnabled
        case promptModeSelectedPromptID, secondaryDictationPromptOff
        case commandModeHotkeyShortcut, commandModeShortcutEnabled
        case commandModeSelectedModel, commandModeSelectedProviderID
        case commandModeConfirmBeforeExecute, commandModeLinkedToGlobal
        case rewriteModeHotkeyShortcut, rewriteModeShortcutEnabled
        case rewriteModeSelectedModel, rewriteModeSelectedProviderID, rewriteModeLinkedToGlobal
        case cancelRecordingHotkeyShortcut
        case showThinkingTokens, hideFromDockAndAppSwitcher
        case accentColorOption, transcriptionStartSound
        case transcriptionSoundVolume, transcriptionSoundIndependentVolume
        case autoUpdateCheckEnabled, betaReleasesEnabled, enableDebugLogs, shareAnonymousAnalytics
        case pressAndHoldMode, enableStreamingPreview, enableAIStreaming
        case copyTranscriptionToClipboard, textInsertionMode
        case preferredInputDeviceUID, preferredOutputDeviceUID
        case visualizerNoiseThreshold, overlayPosition, overlayBottomOffset, overlaySize
        case transcriptionPreviewCharLimit, userTypingWPM
        case saveTranscriptionHistory, notifyAIProcessingFailures, weekendsDontBreakStreak
        case fillerWords, removeFillerWordsEnabled
        case gaavModeEnabled, pauseMediaDuringTranscription
        case vocabularyBoostingEnabled, customDictionaryEntries
        case autoLearnCustomDictionaryEnabled, autoLearnCustomDictionarySuggestions
        case selectedDictationPromptID, dictationPromptOff
        case selectedEditPromptID
        case defaultDictationPromptOverride, defaultEditPromptOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedProviderID = try container.decode(String.self, forKey: .selectedProviderID)
        self.selectedModelByProvider = try container.decode([String: String].self, forKey: .selectedModelByProvider)
        self.savedProviders = try container.decode([SettingsStore.SavedProvider].self, forKey: .savedProviders)
        self.modelReasoningConfigs = try container.decode([String: SettingsStore.ModelReasoningConfig].self, forKey: .modelReasoningConfigs)
        self.selectedSpeechModel = try container.decode(SettingsStore.SpeechModel.self, forKey: .selectedSpeechModel)
        self.selectedCohereLanguage = try container.decode(SettingsStore.CohereLanguage.self, forKey: .selectedCohereLanguage)
        self.hotkeyShortcut = try container.decode(HotkeyShortcut.self, forKey: .hotkeyShortcut)
        self.promptModeHotkeyShortcut = try container.decode(HotkeyShortcut.self, forKey: .promptModeHotkeyShortcut)
        self.promptModeShortcutEnabled = try container.decode(Bool.self, forKey: .promptModeShortcutEnabled)
        self.promptModeSelectedPromptID = try container.decodeIfPresent(String.self, forKey: .promptModeSelectedPromptID)
        self.secondaryDictationPromptOff = try container.decodeIfPresent(Bool.self, forKey: .secondaryDictationPromptOff)
        self.commandModeHotkeyShortcut = try container.decode(HotkeyShortcut.self, forKey: .commandModeHotkeyShortcut)
        self.commandModeShortcutEnabled = try container.decode(Bool.self, forKey: .commandModeShortcutEnabled)
        self.commandModeSelectedModel = try container.decodeIfPresent(String.self, forKey: .commandModeSelectedModel)
        self.commandModeSelectedProviderID = try container.decode(String.self, forKey: .commandModeSelectedProviderID)
        self.commandModeConfirmBeforeExecute = try container.decode(Bool.self, forKey: .commandModeConfirmBeforeExecute)
        self.commandModeLinkedToGlobal = try container.decode(Bool.self, forKey: .commandModeLinkedToGlobal)
        self.rewriteModeHotkeyShortcut = try container.decode(HotkeyShortcut.self, forKey: .rewriteModeHotkeyShortcut)
        self.rewriteModeShortcutEnabled = try container.decode(Bool.self, forKey: .rewriteModeShortcutEnabled)
        self.rewriteModeSelectedModel = try container.decodeIfPresent(String.self, forKey: .rewriteModeSelectedModel)
        self.rewriteModeSelectedProviderID = try container.decode(String.self, forKey: .rewriteModeSelectedProviderID)
        self.rewriteModeLinkedToGlobal = try container.decode(Bool.self, forKey: .rewriteModeLinkedToGlobal)
        self.cancelRecordingHotkeyShortcut = try container.decode(HotkeyShortcut.self, forKey: .cancelRecordingHotkeyShortcut)
        self.showThinkingTokens = try container.decode(Bool.self, forKey: .showThinkingTokens)
        self.hideFromDockAndAppSwitcher = try container.decode(Bool.self, forKey: .hideFromDockAndAppSwitcher)
        self.accentColorOption = try container.decode(SettingsStore.AccentColorOption.self, forKey: .accentColorOption)
        self.transcriptionStartSound = try container.decode(SettingsStore.TranscriptionStartSound.self, forKey: .transcriptionStartSound)
        self.transcriptionSoundVolume = try container.decode(Float.self, forKey: .transcriptionSoundVolume)
        self.transcriptionSoundIndependentVolume = try container.decode(Bool.self, forKey: .transcriptionSoundIndependentVolume)
        self.autoUpdateCheckEnabled = try container.decode(Bool.self, forKey: .autoUpdateCheckEnabled)
        self.betaReleasesEnabled = try container.decode(Bool.self, forKey: .betaReleasesEnabled)
        self.enableDebugLogs = try container.decode(Bool.self, forKey: .enableDebugLogs)
        self.shareAnonymousAnalytics = try container.decode(Bool.self, forKey: .shareAnonymousAnalytics)
        self.pressAndHoldMode = try container.decode(Bool.self, forKey: .pressAndHoldMode)
        self.enableStreamingPreview = try container.decode(Bool.self, forKey: .enableStreamingPreview)
        self.enableAIStreaming = try container.decode(Bool.self, forKey: .enableAIStreaming)
        self.copyTranscriptionToClipboard = try container.decode(Bool.self, forKey: .copyTranscriptionToClipboard)
        self.textInsertionMode = try container.decode(SettingsStore.TextInsertionMode.self, forKey: .textInsertionMode)
        self.preferredInputDeviceUID = try container.decodeIfPresent(String.self, forKey: .preferredInputDeviceUID)
        self.preferredOutputDeviceUID = try container.decodeIfPresent(String.self, forKey: .preferredOutputDeviceUID)
        self.visualizerNoiseThreshold = try container.decode(Double.self, forKey: .visualizerNoiseThreshold)
        self.overlayPosition = try container.decode(SettingsStore.OverlayPosition.self, forKey: .overlayPosition)
        self.overlayBottomOffset = try container.decode(Double.self, forKey: .overlayBottomOffset)
        self.overlaySize = try container.decode(SettingsStore.OverlaySize.self, forKey: .overlaySize)
        self.transcriptionPreviewCharLimit = try container.decode(Int.self, forKey: .transcriptionPreviewCharLimit)
        self.userTypingWPM = try container.decode(Int.self, forKey: .userTypingWPM)
        self.saveTranscriptionHistory = try container.decode(Bool.self, forKey: .saveTranscriptionHistory)
        self.notifyAIProcessingFailures = try container.decodeIfPresent(Bool.self, forKey: .notifyAIProcessingFailures)
        self.weekendsDontBreakStreak = try container.decode(Bool.self, forKey: .weekendsDontBreakStreak)
        self.fillerWords = try container.decode([String].self, forKey: .fillerWords)
        self.removeFillerWordsEnabled = try container.decode(Bool.self, forKey: .removeFillerWordsEnabled)
        self.gaavModeEnabled = try container.decode(Bool.self, forKey: .gaavModeEnabled)
        self.pauseMediaDuringTranscription = try container.decode(Bool.self, forKey: .pauseMediaDuringTranscription)
        self.vocabularyBoostingEnabled = try container.decode(Bool.self, forKey: .vocabularyBoostingEnabled)
        self.customDictionaryEntries = try container.decode([SettingsStore.CustomDictionaryEntry].self, forKey: .customDictionaryEntries)
        // Backward-compatible defaults for keys added by auto-learn dictionary PR.
        self.autoLearnCustomDictionaryEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoLearnCustomDictionaryEnabled) ?? false
        self.autoLearnCustomDictionarySuggestions = try container.decodeIfPresent([SettingsStore.AutoLearnSuggestion].self, forKey: .autoLearnCustomDictionarySuggestions) ?? []
        self.selectedDictationPromptID = try container.decodeIfPresent(String.self, forKey: .selectedDictationPromptID)
        self.dictationPromptOff = try container.decodeIfPresent(Bool.self, forKey: .dictationPromptOff)
        self.selectedEditPromptID = try container.decodeIfPresent(String.self, forKey: .selectedEditPromptID)
        self.defaultDictationPromptOverride = try container.decodeIfPresent(String.self, forKey: .defaultDictationPromptOverride)
        self.defaultEditPromptOverride = try container.decodeIfPresent(String.self, forKey: .defaultEditPromptOverride)
    }

    // Memberwise init for programmatic construction (backup export).
    init(
        selectedProviderID: String,
        selectedModelByProvider: [String: String],
        savedProviders: [SettingsStore.SavedProvider],
        modelReasoningConfigs: [String: SettingsStore.ModelReasoningConfig],
        selectedSpeechModel: SettingsStore.SpeechModel,
        selectedCohereLanguage: SettingsStore.CohereLanguage,
        hotkeyShortcut: HotkeyShortcut,
        promptModeHotkeyShortcut: HotkeyShortcut,
        promptModeShortcutEnabled: Bool,
        promptModeSelectedPromptID: String?,
        secondaryDictationPromptOff: Bool?,
        commandModeHotkeyShortcut: HotkeyShortcut,
        commandModeShortcutEnabled: Bool,
        commandModeSelectedModel: String?,
        commandModeSelectedProviderID: String,
        commandModeConfirmBeforeExecute: Bool,
        commandModeLinkedToGlobal: Bool,
        rewriteModeHotkeyShortcut: HotkeyShortcut,
        rewriteModeShortcutEnabled: Bool,
        rewriteModeSelectedModel: String?,
        rewriteModeSelectedProviderID: String,
        rewriteModeLinkedToGlobal: Bool,
        cancelRecordingHotkeyShortcut: HotkeyShortcut,
        showThinkingTokens: Bool,
        hideFromDockAndAppSwitcher: Bool,
        accentColorOption: SettingsStore.AccentColorOption,
        transcriptionStartSound: SettingsStore.TranscriptionStartSound,
        transcriptionSoundVolume: Float,
        transcriptionSoundIndependentVolume: Bool,
        autoUpdateCheckEnabled: Bool,
        betaReleasesEnabled: Bool,
        enableDebugLogs: Bool,
        shareAnonymousAnalytics: Bool,
        pressAndHoldMode: Bool,
        enableStreamingPreview: Bool,
        enableAIStreaming: Bool,
        copyTranscriptionToClipboard: Bool,
        textInsertionMode: SettingsStore.TextInsertionMode,
        preferredInputDeviceUID: String?,
        preferredOutputDeviceUID: String?,
        visualizerNoiseThreshold: Double,
        overlayPosition: SettingsStore.OverlayPosition,
        overlayBottomOffset: Double,
        overlaySize: SettingsStore.OverlaySize,
        transcriptionPreviewCharLimit: Int,
        userTypingWPM: Int,
        saveTranscriptionHistory: Bool,
        notifyAIProcessingFailures: Bool? = nil,
        weekendsDontBreakStreak: Bool,
        fillerWords: [String],
        removeFillerWordsEnabled: Bool,
        gaavModeEnabled: Bool,
        pauseMediaDuringTranscription: Bool,
        vocabularyBoostingEnabled: Bool,
        customDictionaryEntries: [SettingsStore.CustomDictionaryEntry],
        autoLearnCustomDictionaryEnabled: Bool = false,
        autoLearnCustomDictionarySuggestions: [SettingsStore.AutoLearnSuggestion] = [],
        selectedDictationPromptID: String?,
        dictationPromptOff: Bool?,
        selectedEditPromptID: String?,
        defaultDictationPromptOverride: String?,
        defaultEditPromptOverride: String?
    ) {
        self.selectedProviderID = selectedProviderID
        self.selectedModelByProvider = selectedModelByProvider
        self.savedProviders = savedProviders
        self.modelReasoningConfigs = modelReasoningConfigs
        self.selectedSpeechModel = selectedSpeechModel
        self.selectedCohereLanguage = selectedCohereLanguage
        self.hotkeyShortcut = hotkeyShortcut
        self.promptModeHotkeyShortcut = promptModeHotkeyShortcut
        self.promptModeShortcutEnabled = promptModeShortcutEnabled
        self.promptModeSelectedPromptID = promptModeSelectedPromptID
        self.secondaryDictationPromptOff = secondaryDictationPromptOff
        self.commandModeHotkeyShortcut = commandModeHotkeyShortcut
        self.commandModeShortcutEnabled = commandModeShortcutEnabled
        self.commandModeSelectedModel = commandModeSelectedModel
        self.commandModeSelectedProviderID = commandModeSelectedProviderID
        self.commandModeConfirmBeforeExecute = commandModeConfirmBeforeExecute
        self.commandModeLinkedToGlobal = commandModeLinkedToGlobal
        self.rewriteModeHotkeyShortcut = rewriteModeHotkeyShortcut
        self.rewriteModeShortcutEnabled = rewriteModeShortcutEnabled
        self.rewriteModeSelectedModel = rewriteModeSelectedModel
        self.rewriteModeSelectedProviderID = rewriteModeSelectedProviderID
        self.rewriteModeLinkedToGlobal = rewriteModeLinkedToGlobal
        self.cancelRecordingHotkeyShortcut = cancelRecordingHotkeyShortcut
        self.showThinkingTokens = showThinkingTokens
        self.hideFromDockAndAppSwitcher = hideFromDockAndAppSwitcher
        self.accentColorOption = accentColorOption
        self.transcriptionStartSound = transcriptionStartSound
        self.transcriptionSoundVolume = transcriptionSoundVolume
        self.transcriptionSoundIndependentVolume = transcriptionSoundIndependentVolume
        self.autoUpdateCheckEnabled = autoUpdateCheckEnabled
        self.betaReleasesEnabled = betaReleasesEnabled
        self.enableDebugLogs = enableDebugLogs
        self.shareAnonymousAnalytics = shareAnonymousAnalytics
        self.pressAndHoldMode = pressAndHoldMode
        self.enableStreamingPreview = enableStreamingPreview
        self.enableAIStreaming = enableAIStreaming
        self.copyTranscriptionToClipboard = copyTranscriptionToClipboard
        self.textInsertionMode = textInsertionMode
        self.preferredInputDeviceUID = preferredInputDeviceUID
        self.preferredOutputDeviceUID = preferredOutputDeviceUID
        self.visualizerNoiseThreshold = visualizerNoiseThreshold
        self.overlayPosition = overlayPosition
        self.overlayBottomOffset = overlayBottomOffset
        self.overlaySize = overlaySize
        self.transcriptionPreviewCharLimit = transcriptionPreviewCharLimit
        self.userTypingWPM = userTypingWPM
        self.saveTranscriptionHistory = saveTranscriptionHistory
        self.notifyAIProcessingFailures = notifyAIProcessingFailures
        self.weekendsDontBreakStreak = weekendsDontBreakStreak
        self.fillerWords = fillerWords
        self.removeFillerWordsEnabled = removeFillerWordsEnabled
        self.gaavModeEnabled = gaavModeEnabled
        self.pauseMediaDuringTranscription = pauseMediaDuringTranscription
        self.vocabularyBoostingEnabled = vocabularyBoostingEnabled
        self.customDictionaryEntries = customDictionaryEntries
        self.autoLearnCustomDictionaryEnabled = autoLearnCustomDictionaryEnabled
        self.autoLearnCustomDictionarySuggestions = autoLearnCustomDictionarySuggestions
        self.selectedDictationPromptID = selectedDictationPromptID
        self.dictationPromptOff = dictationPromptOff
        self.selectedEditPromptID = selectedEditPromptID
        self.defaultDictationPromptOverride = defaultDictationPromptOverride
        self.defaultEditPromptOverride = defaultEditPromptOverride
    }
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
