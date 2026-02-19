import AppKit
import ApplicationServices
import Combine
import Foundation
import ServiceManagement
import SwiftUI
#if canImport(FluidAudio)
import FluidAudio
#endif

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let transcriptionPreviewCharLimitRange: ClosedRange<Int> = 50...800
    static let transcriptionPreviewCharLimitStep = 50
    static let defaultTranscriptionPreviewCharLimit = 150
    private let defaults = UserDefaults.standard
    private let keychain = KeychainService.shared

    private init() {
        self.migrateProviderAPIKeysIfNeeded()
        self.scrubSavedProviderAPIKeys()
        self.migrateDictationPromptProfilesIfNeeded()
    }

    // Keys
    private enum Keys {
        static let enableAIProcessing = "EnableAIProcessing"
        static let enableDebugLogs = "EnableDebugLogs"
        static let availableAIModels = "AvailableAIModels"
        static let availableModelsByProvider = "AvailableModelsByProvider"
        static let selectedAIModel = "SelectedAIModel"
        static let selectedModelByProvider = "SelectedModelByProvider"
        static let selectedProviderID = "SelectedProviderID"
        static let providerAPIKeys = "ProviderAPIKeys"
        static let providerAPIKeyIdentifiers = "ProviderAPIKeyIdentifiers"
        static let savedProviders = "SavedProviders"
        static let verifiedProviderFingerprints = "VerifiedProviderFingerprints"
        static let shareAnonymousAnalytics = "ShareAnonymousAnalytics"
        static let fluid1InterestCaptured = "Fluid1InterestCaptured"
        static let hotkeyShortcutKey = "HotkeyShortcutKey"
        static let preferredInputDeviceUID = "PreferredInputDeviceUID"
        static let preferredOutputDeviceUID = "PreferredOutputDeviceUID"
        static let syncAudioDevicesWithSystem = "SyncAudioDevicesWithSystem"
        static let visualizerNoiseThreshold = "VisualizerNoiseThreshold"
        static let launchAtStartup = "LaunchAtStartup"
        static let showInDock = "ShowInDock"
        static let accentColorOption = "AccentColorOption"
        static let enableTranscriptionSounds = "EnableTranscriptionSounds"
        static let transcriptionStartSound = "TranscriptionStartSound"
        static let transcriptionSoundVolume = "TranscriptionSoundVolume"
        static let transcriptionSoundIndependentVolume = "TranscriptionSoundIndependentVolume"
        static let pressAndHoldMode = "PressAndHoldMode"
        static let enableStreamingPreview = "EnableStreamingPreview"
        static let enableAIStreaming = "EnableAIStreaming"
        static let copyTranscriptionToClipboard = "CopyTranscriptionToClipboard"
        static let autoUpdateCheckEnabled = "AutoUpdateCheckEnabled"
        static let lastUpdateCheckDate = "LastUpdateCheckDate"
        static let updatePromptSnoozedUntil = "UpdatePromptSnoozedUntil"
        static let snoozedUpdateVersion = "SnoozedUpdateVersion"
        static let playgroundUsed = "PlaygroundUsed"

        // Command Mode Keys
        static let commandModeSelectedModel = "CommandModeSelectedModel"
        static let commandModeSelectedProviderID = "CommandModeSelectedProviderID"
        static let commandModeHotkeyShortcut = "CommandModeHotkeyShortcut"
        static let commandModeConfirmBeforeExecute = "CommandModeConfirmBeforeExecute"
        static let commandModeLinkedToGlobal = "CommandModeLinkedToGlobal"
        static let commandModeShortcutEnabled = "CommandModeShortcutEnabled"

        // Rewrite Mode Keys
        static let rewriteModeHotkeyShortcut = "RewriteModeHotkeyShortcut"
        static let rewriteModeSelectedModel = "RewriteModeSelectedModel"
        static let rewriteModeSelectedProviderID = "RewriteModeSelectedProviderID"
        static let rewriteModeLinkedToGlobal = "RewriteModeLinkedToGlobal"

        // Model Reasoning Config Keys
        static let modelReasoningConfigs = "ModelReasoningConfigs"
        static let rewriteModeShortcutEnabled = "RewriteModeShortcutEnabled"
        static let showThinkingTokens = "ShowThinkingTokens"

        // Stats Keys
        static let userTypingWPM = "UserTypingWPM"
        static let saveTranscriptionHistory = "SaveTranscriptionHistory"

        // Filler Words
        static let fillerWords = "FillerWords"
        static let removeFillerWordsEnabled = "RemoveFillerWordsEnabled"

        // GAAV Mode (removes capitalization and trailing punctuation)
        static let gaavModeEnabled = "GAAVModeEnabled"

        // Custom Dictionary
        static let customDictionaryEntries = "CustomDictionaryEntries"

        // Transcription Provider (ASR)
        static let selectedTranscriptionProvider = "SelectedTranscriptionProvider"
        static let whisperModelSize = "WhisperModelSize"

        // Unified Speech Model (replaces above two)
        static let selectedSpeechModel = "SelectedSpeechModel"

        // Overlay Position
        static let overlayPosition = "OverlayPosition"
        static let overlayBottomOffset = "OverlayBottomOffset"
        static let overlaySize = "OverlaySize"
        static let transcriptionPreviewCharLimit = "TranscriptionPreviewCharLimit"

        // Media Playback Control
        static let pauseMediaDuringTranscription = "PauseMediaDuringTranscription"

        // Custom Dictation Prompt
        static let customDictationPrompt = "CustomDictationPrompt"

        // Dictation Prompt Profiles (multi-prompt system)
        static let dictationPromptProfiles = "DictationPromptProfiles"
        static let selectedDictationPromptID = "SelectedDictationPromptID"

        // Default Dictation Prompt Override (optional)
        // nil   => use built-in default prompt
        // ""    => use empty system prompt
        // other => use custom default prompt text
        static let defaultDictationPromptOverride = "DefaultDictationPromptOverride"

        // Streak Settings
        static let weekendsDontBreakStreak = "WeekendsDontBreakStreak"
    }

    // MARK: - Dictation Prompt Profiles (Multi-prompt)

    struct DictationPromptProfile: Codable, Identifiable, Hashable {
        let id: String
        var name: String
        var prompt: String
        var createdAt: Date
        var updatedAt: Date

        init(
            id: String = UUID().uuidString,
            name: String,
            prompt: String,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.prompt = prompt
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    /// User-defined dictation prompt profiles (named system prompts for dictation cleanup).
    /// The built-in default prompt is not stored here.
    var dictationPromptProfiles: [DictationPromptProfile] {
        get {
            guard let data = self.defaults.data(forKey: Keys.dictationPromptProfiles),
                  let decoded = try? JSONDecoder().decode([DictationPromptProfile].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.dictationPromptProfiles)
            } else {
                // If encoding fails, avoid writing corrupt data.
                self.defaults.removeObject(forKey: Keys.dictationPromptProfiles)
            }
        }
    }

    /// Selected dictation prompt profile ID. `nil` means "Default".
    var selectedDictationPromptID: String? {
        get {
            let value = self.defaults.string(forKey: Keys.selectedDictationPromptID)
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : value
        }
        set {
            objectWillChange.send()
            if let id = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                self.defaults.set(id, forKey: Keys.selectedDictationPromptID)
            } else {
                self.defaults.removeObject(forKey: Keys.selectedDictationPromptID)
            }
        }
    }

    /// Convenience: currently selected profile, or nil if Default/invalid selection.
    var selectedDictationPromptProfile: DictationPromptProfile? {
        guard let id = self.selectedDictationPromptID else { return nil }
        return self.dictationPromptProfiles.first(where: { $0.id == id })
    }

    /// Optional override for the built-in default dictation system prompt.
    /// - nil: use the built-in default prompt
    /// - empty string: use an empty system prompt
    /// - otherwise: use the provided text as the default prompt
    var defaultDictationPromptOverride: String? {
        get {
            // Distinguish "not set" from "set to empty string"
            guard self.defaults.object(forKey: Keys.defaultDictationPromptOverride) != nil else {
                return nil
            }
            return self.defaults.string(forKey: Keys.defaultDictationPromptOverride) ?? ""
        }
        set {
            objectWillChange.send()
            if let value = newValue {
                self.defaults.set(value, forKey: Keys.defaultDictationPromptOverride) // allow empty
            } else {
                self.defaults.removeObject(forKey: Keys.defaultDictationPromptOverride)
            }
        }
    }

    /// Hidden base prompt: role/intent only (not exposed in UI).
    static func baseDictationPromptText() -> String {
        """
        You are a voice-to-text dictation cleaner. Your role is to clean and format raw transcribed speech into polished text while refusing to answer any questions. Never answer questions about yourself or anything else.

        ## Core Rules:
        1. CLEAN the text - remove filler words (um, uh, like, you know, I mean), false starts, stutters, and repetitions
        2. FORMAT properly - add correct punctuation, capitalization, and structure
        3. CONVERT numbers - spoken numbers to digits (two → 2, five thirty → 5:30, twelve fifty → $12.50)
        4. EXECUTE commands - handle "new line", "period", "comma", "bold X", "header X", "bullet point", etc.
        5. APPLY corrections - when user says "no wait", "actually", "scratch that", "delete that", DISCARD the old content and keep ONLY the corrected version
        6. PRESERVE intent - keep the user's meaning, just clean the delivery
        7. EXPAND abbreviations - thx → thanks, pls → please, u → you, ur → your/you're, gonna → going to

        ## Critical:
        - Output ONLY the cleaned text
        - Do NOT answer questions - just clean them
        - DO NOT EVER ANSWER TO QUESTIONS
        - Do NOT add explanations or commentary
        - Do NOT wrap in quotes unless the input had quotes
        - Do NOT add filler words (um, uh) to the output
        - PRESERVE ordinals in lists: "first call client, second review contract" → keep "First" and "Second"
        - PRESERVE politeness words: "please", "thank you" at end of sentences
        """
    }

    /// Built-in default dictation prompt body that users may view/edit.
    static func defaultDictationPromptBodyText() -> String {
        """
        ## Self-Corrections:
        When user corrects themselves, DISCARD everything before the correction trigger:
        - Triggers: "no", "wait", "actually", "scratch that", "delete that", "no no", "cancel", "never mind", "sorry", "oops"
        - Example: "buy milk no wait buy water" → "Buy water." (NOT "Buy milk. Buy water.")
        - Example: "tell John no actually tell Sarah" → "Tell Sarah."
        - If correction cancels entirely: "send email no wait cancel that" → "" (empty)

        ## Multi-Command Chains:
        When multiple commands are chained, execute ALL of them in sequence:
        - "make X bold no wait make Y bold" → **Y** (correction + formatting)
        - "header shopping bullet milk no eggs" → # Shopping\n- Eggs (header + correction + bullet)
        - "the price is fifty no sixty dollars" → The price is $60. (correction + number)

        ## Emojis:
        - Convert spoken emoji names: "smiley face" → 😊 (NOT 😀), "thumbs up" → 👍, "heart emoji" → ❤️, "fire emoji" → 🔥
        - Keep emojis if user includes them
        - Do NOT add emojis unless user explicitly asks for them (e.g., "joke about cats" → NO 😺)
        """
    }

    /// Join hidden base with a body, avoiding duplicate base text.
    static func combineBasePrompt(with body: String) -> String {
        let base = self.baseDictationPromptText().trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // If body already starts with base, return as-is to avoid double-prepending.
        if trimmedBody.lowercased().hasPrefix(base.lowercased()) {
            return trimmedBody
        }

        // If body is empty, return just the base.
        guard !trimmedBody.isEmpty else { return base }

        return "\(base)\n\n\(trimmedBody)"
    }

    /// Remove the hidden base prompt prefix if it was persisted previously.
    static func stripBaseDictationPrompt(from text: String) -> String {
        let base = self.baseDictationPromptText().trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try exact and case-insensitive prefix removal
        if trimmed.hasPrefix(base) {
            let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: base.count)
            return trimmed[bodyStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let range = trimmed.lowercased().range(of: base.lowercased()), range.lowerBound == trimmed.lowercased().startIndex {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: base.count)
            return trimmed[idx...].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    /// Built-in default dictation system prompt shared across the app.
    static func defaultDictationPromptText() -> String {
        self.combineBasePrompt(with: self.defaultDictationPromptBodyText())
    }

    // MARK: - Model Reasoning Configuration

    /// Configuration for model-specific reasoning/thinking parameters
    struct ModelReasoningConfig: Codable, Equatable {
        /// The parameter name to use (e.g., "reasoning_effort", "enable_thinking", "thinking")
        var parameterName: String

        /// The value to use for the parameter (e.g., "low", "medium", "high", "none", "true")
        var parameterValue: String

        /// Whether this config is enabled (allows disabling without deleting)
        var isEnabled: Bool

        init(parameterName: String = "reasoning_effort", parameterValue: String = "low", isEnabled: Bool = true) {
            self.parameterName = parameterName
            self.parameterValue = parameterValue
            self.isEnabled = isEnabled
        }

        /// Common presets for different model types
        static let openAIGPT5 = ModelReasoningConfig(
            parameterName: "reasoning_effort",
            parameterValue: "low",
            isEnabled: true
        )
        static let openAIO1 = ModelReasoningConfig(
            parameterName: "reasoning_effort",
            parameterValue: "medium",
            isEnabled: true
        )
        static let groqGPTOSS = ModelReasoningConfig(
            parameterName: "reasoning_effort",
            parameterValue: "low",
            isEnabled: true
        )
        static let deepSeekReasoner = ModelReasoningConfig(
            parameterName: "enable_thinking",
            parameterValue: "true",
            isEnabled: true
        )
        static let disabled = ModelReasoningConfig(parameterName: "", parameterValue: "", isEnabled: false)
    }

    struct SavedProvider: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let baseURL: String
        let apiKey: String
        let models: [String]

        init(id: String = UUID().uuidString, name: String, baseURL: String, apiKey: String = "", models: [String] = []) {
            self.id = id
            self.name = name
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.models = models
        }
    }

    var enableAIProcessing: Bool {
        get { self.defaults.bool(forKey: Keys.enableAIProcessing) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableAIProcessing)
        }
    }

    /// Anonymous analytics toggle (default: ON). Uses default-true semantics so existing installs
    /// upgrading to a version that includes analytics do not silently default to OFF.
    var shareAnonymousAnalytics: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.shareAnonymousAnalytics)
            if value == nil { return true }
            return self.defaults.bool(forKey: Keys.shareAnonymousAnalytics)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.shareAnonymousAnalytics)
        }
    }

    var fluid1InterestCaptured: Bool {
        get { self.defaults.bool(forKey: Keys.fluid1InterestCaptured) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.fluid1InterestCaptured)
        }
    }

    var availableModels: [String] {
        get { (self.defaults.array(forKey: Keys.availableAIModels) as? [String]) ?? [] }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.availableAIModels)
        }
    }

    var availableModelsByProvider: [String: [String]] {
        get { (self.defaults.dictionary(forKey: Keys.availableModelsByProvider) as? [String: [String]]) ?? [:] }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.availableModelsByProvider)
        }
    }

    var enableDebugLogs: Bool {
        get { self.defaults.bool(forKey: Keys.enableDebugLogs) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableDebugLogs)
            DebugLogger.shared.refreshLoggingEnabled()
        }
    }

    var selectedModel: String? {
        get { self.defaults.string(forKey: Keys.selectedAIModel) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.selectedAIModel)
        }
    }

    var selectedModelByProvider: [String: String] {
        get { (self.defaults.dictionary(forKey: Keys.selectedModelByProvider) as? [String: String]) ?? [:] }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.selectedModelByProvider)
        }
    }

    var providerAPIKeys: [String: String] {
        get { (try? self.keychain.fetchAllKeys()) ?? [:] }
        set {
            objectWillChange.send()
            self.persistProviderAPIKeys(newValue)
        }
    }

    /// Securely retrieve API key for a provider, handling custom prefix logic
    func getAPIKey(for providerID: String) -> String? {
        let keys = self.providerAPIKeys
        // Try exact match first
        if let key = keys[providerID] { return key }

        // Try canonical key format (custom:ID)
        let canonical = self.canonicalProviderKey(for: providerID)
        return keys[canonical]
    }

    var selectedProviderID: String {
        get { self.defaults.string(forKey: Keys.selectedProviderID) ?? "openai" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.selectedProviderID)
        }
    }

    var savedProviders: [SavedProvider] {
        get {
            guard let data = defaults.data(forKey: Keys.savedProviders),
                  let decoded = try? JSONDecoder().decode([SavedProvider].self, from: data) else { return [] }
            return decoded
        }
        set {
            objectWillChange.send()
            let sanitized = newValue.map { provider -> SavedProvider in
                if provider.apiKey.isEmpty { return provider }
                return SavedProvider(
                    id: provider.id,
                    name: provider.name,
                    baseURL: provider.baseURL,
                    apiKey: "",
                    models: provider.models
                )
            }
            if let encoded = try? JSONEncoder().encode(sanitized) {
                self.defaults.set(encoded, forKey: Keys.savedProviders)
            }
        }
    }

    /// Check if the current AI provider is fully configured (API key/baseURL + selected model)
    var isAIConfigured: Bool {
        let providerID = self.selectedProviderID

        // 1. Apple Intelligence is always considered configured
        if providerID == "apple-intelligence" { return true }

        // 2. Get base URL to check for local endpoints
        var baseURL = ""
        if let saved = self.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = saved.baseURL
        } else {
            baseURL = ModelRepository.shared.defaultBaseURL(for: providerID)
        }

        let isLocal = ModelRepository.shared.isLocalEndpoint(baseURL)

        // 3. Check for API key and selected model
        let key = self.canonicalProviderKey(for: providerID)
        let hasApiKey = !(self.providerAPIKeys[key]?.isEmpty ?? true)

        let selectedModel = self.selectedModelByProvider[key]
        let hasSelectedModel = !(selectedModel?.isEmpty ?? true)
        let hasDefaultModel = !ModelRepository.shared.defaultModels(for: providerID).isEmpty
        let hasModel = hasSelectedModel || hasDefaultModel

        return (isLocal || hasApiKey) && hasModel
    }

    /// The base URL for the currently selected AI provider
    var activeBaseURL: String {
        let providerID = self.selectedProviderID
        if let saved = self.savedProviders.first(where: { $0.id == providerID }) {
            return saved.baseURL
        }
        return ModelRepository.shared.defaultBaseURL(for: providerID)
    }

    var hotkeyShortcut: HotkeyShortcut {
        get {
            if let data = defaults.data(forKey: Keys.hotkeyShortcutKey),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            return HotkeyShortcut(keyCode: 61, modifierFlags: [])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.hotkeyShortcutKey)
            }
        }
    }

    var pressAndHoldMode: Bool {
        get { self.defaults.bool(forKey: Keys.pressAndHoldMode) }
        set { self.defaults.set(newValue, forKey: Keys.pressAndHoldMode) }
    }

    var enableStreamingPreview: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableStreamingPreview)
            return value as? Bool ?? true // Default to true (enabled)
        }
        set { self.defaults.set(newValue, forKey: Keys.enableStreamingPreview) }
    }

    var enableAIStreaming: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableAIStreaming)
            return value as? Bool ?? true // Default to true (enabled)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableAIStreaming)
        }
    }

    var copyTranscriptionToClipboard: Bool {
        get { self.defaults.bool(forKey: Keys.copyTranscriptionToClipboard) }
        set { self.defaults.set(newValue, forKey: Keys.copyTranscriptionToClipboard) }
    }

    var preferredInputDeviceUID: String? {
        get { self.defaults.string(forKey: Keys.preferredInputDeviceUID) }
        set { self.defaults.set(newValue, forKey: Keys.preferredInputDeviceUID) }
    }

    var preferredOutputDeviceUID: String? {
        get { self.defaults.string(forKey: Keys.preferredOutputDeviceUID) }
        set { self.defaults.set(newValue, forKey: Keys.preferredOutputDeviceUID) }
    }

    /// When enabled, changing audio devices in FluidVoice will also update macOS system audio settings.
    /// ALWAYS TRUE: Independent mode removed due to CoreAudio aggregate device limitations (OSStatus -10851)
    var syncAudioDevicesWithSystem: Bool {
        get {
            // Always return true - independent mode doesn't work for Bluetooth/aggregate devices
            return true
        }
        set {
            // No-op: sync mode is always enabled
            // Kept for backward compatibility but value is ignored
            _ = newValue
        }
    }

    var visualizerNoiseThreshold: Double {
        get {
            let value = self.defaults.double(forKey: Keys.visualizerNoiseThreshold)
            return value == 0.0 ? 0.4 : value // Default to 0.4 if not set
        }
        set {
            // Clamp between 0.0 and 0.95 to avoid division by zero issues in visualizers
            let clamped = max(min(newValue, 0.95), 0.0)
            self.defaults.set(clamped, forKey: Keys.visualizerNoiseThreshold)
        }
    }

    // MARK: - Overlay Position

    /// Size options for the recording overlay
    enum OverlaySize: String, CaseIterable {
        case small
        case medium
        case large

        var displayName: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    /// Position options for the recording overlay
    enum OverlayPosition: String, CaseIterable {
        case top // Top of screen (notch area or floating)
        case bottom // Bottom of screen

        var displayName: String {
            switch self {
            case .top: return "Top of Screen"
            case .bottom: return "Bottom of Screen"
            }
        }
    }

    /// Where the recording overlay appears (default: bottom)
    var overlayPosition: OverlayPosition {
        get {
            guard let raw = self.defaults.string(forKey: Keys.overlayPosition),
                  let position = OverlayPosition(rawValue: raw)
            else {
                return .bottom // Default to bottom (menu overlay)
            }
            return position
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.overlayPosition)
        }
    }

    /// Vertical offset for the bottom overlay (distance from bottom of screen/dock)
    var overlayBottomOffset: Double {
        get {
            let value = self.defaults.double(forKey: Keys.overlayBottomOffset)
            return value == 0.0 ? 80.0 : value // Default to 80.0
        }
        set {
            objectWillChange.send()
            // Clamp between a safe range (20px to 1000px)
            // Even though slider is 20-500, we clamp for safety
            let clamped = max(min(newValue, 1000.0), 10.0)
            self.defaults.set(clamped, forKey: Keys.overlayBottomOffset)

            // Post notification for live update if overlay is visible
            NotificationCenter.default.post(name: NSNotification.Name("OverlayOffsetChanged"), object: nil)
        }
    }

    /// The size of the recording overlay (default: medium)
    var overlaySize: OverlaySize {
        get {
            guard let raw = self.defaults.string(forKey: Keys.overlaySize),
                  let size = OverlaySize(rawValue: raw)
            else {
                return .medium // Default to medium
            }
            return size
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.overlaySize)

            // Post notification for live update if overlay is visible
            NotificationCenter.default.post(name: NSNotification.Name("OverlaySizeChanged"), object: nil)
        }
    }

    /// How many recent transcription characters show in overlays (default: 150)
    var transcriptionPreviewCharLimit: Int {
        get {
            let stored = self.defaults.object(forKey: Keys.transcriptionPreviewCharLimit) as? NSNumber
            let value = stored?.intValue ?? Self.defaultTranscriptionPreviewCharLimit
            return Self.normalizedTranscriptionPreviewCharLimit(value)
        }
        set {
            let clamped = Self.normalizedTranscriptionPreviewCharLimit(newValue)
            guard clamped != self.transcriptionPreviewCharLimit else { return }

            objectWillChange.send()
            self.defaults.set(clamped, forKey: Keys.transcriptionPreviewCharLimit)
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionPreviewCharLimitChanged"),
                object: nil
            )
        }
    }

    private static func normalizedTranscriptionPreviewCharLimit(_ value: Int) -> Int {
        let range = Self.transcriptionPreviewCharLimitRange
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        let offset = clamped - range.lowerBound
        let snappedOffset = Int((Double(offset) / Double(Self.transcriptionPreviewCharLimitStep)).rounded())
            * Self.transcriptionPreviewCharLimitStep
        return max(range.lowerBound, min(range.upperBound, range.lowerBound + snappedOffset))
    }

    // MARK: - Preferences Settings

    enum AccentColorOption: String, CaseIterable, Identifiable {
        case cyan = "Cyan"
        case green = "Green"
        case blue = "Blue"
        case purple = "Purple"
        case orange = "Orange"

        var id: String { self.rawValue }

        var hex: String {
            switch self {
            case .cyan: return "#3AC8C6"
            case .green: return "#22C55E"
            case .blue: return "#3B82F6"
            case .purple: return "#A855F7"
            case .orange: return "#F59E0B"
            }
        }
    }

    enum TranscriptionStartSound: String, CaseIterable, Identifiable {
        case fluidSfx1 = "fluid_sfx_1"
        case fluidSfx2 = "fluid_sfx_2"
        case fluidSfx3 = "fluid_sfx_3"
        case fluidSfx4 = "fluid_sfx_4"

        var id: String { self.rawValue }

        var displayName: String {
            switch self {
            case .fluidSfx1: return "Fluid SFX 1"
            case .fluidSfx2: return "Fluid SFX 2"
            case .fluidSfx3: return "Fluid SFX 3"
            case .fluidSfx4: return "Fluid SFX 4"
            }
        }

        var soundFileName: String {
            switch self {
            case .fluidSfx1: return "FV_start"
            case .fluidSfx2: return "FV_start_2"
            case .fluidSfx3: return "sfx_3"
            case .fluidSfx4: return "sfx_4"
            }
        }
    }

    var accentColorOption: AccentColorOption {
        get {
            guard let raw = self.defaults.string(forKey: Keys.accentColorOption),
                  let option = AccentColorOption(rawValue: raw)
            else {
                return .cyan
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.accentColorOption)
        }
    }

    var accentColor: Color {
        Color(hex: self.accentColorOption.hex) ?? Color(red: 0.227, green: 0.784, blue: 0.776)
    }

    var enableTranscriptionSounds: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableTranscriptionSounds)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableTranscriptionSounds)
        }
    }

    var transcriptionSoundVolume: Float {
        get {
            let value = self.defaults.object(forKey: Keys.transcriptionSoundVolume)
            return (value as? Float) ?? 1.0
        }
        set {
            objectWillChange.send()
            let clamped = max(0.0, min(1.0, newValue))
            self.defaults.set(clamped, forKey: Keys.transcriptionSoundVolume)
        }
    }

    var transcriptionSoundIndependentVolume: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.transcriptionSoundIndependentVolume)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.transcriptionSoundIndependentVolume)
        }
    }

    var transcriptionStartSound: TranscriptionStartSound {
        get {
            guard let raw = self.defaults.string(forKey: Keys.transcriptionStartSound),
                  let option = TranscriptionStartSound(rawValue: raw)
            else {
                return .fluidSfx4
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.transcriptionStartSound)
        }
    }

    var launchAtStartup: Bool {
        get { self.defaults.bool(forKey: Keys.launchAtStartup) }
        set {
            self.defaults.set(newValue, forKey: Keys.launchAtStartup)
            // Update launch agent registration
            self.updateLaunchAtStartup(newValue)
        }
    }

    // MARK: - Initialization Methods

    func initializeAppSettings() {
        #if os(macOS)
        // Apply dock visibility setting on app launch
        let dockVisible = self.showInDock
        DebugLogger.shared.info("Initializing app with dock visibility: \(dockVisible)", source: "SettingsStore")

        // Set activation policy based on saved preference
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(dockVisible ? .regular : .accessory)
        }
        #endif
    }

    var showInDock: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.showInDock)
            return value as? Bool ?? true // Default to true if not set
        }
        set {
            self.defaults.set(newValue, forKey: Keys.showInDock)
            // Update dock visibility
            self.updateDockVisibility(newValue)
        }
    }

    var autoUpdateCheckEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.autoUpdateCheckEnabled)
            return value as? Bool ?? true // Default to enabled
        }
        set {
            self.defaults.set(newValue, forKey: Keys.autoUpdateCheckEnabled)
        }
    }

    var lastUpdateCheckDate: Date? {
        get {
            return self.defaults.object(forKey: Keys.lastUpdateCheckDate) as? Date
        }
        set {
            self.defaults.set(newValue, forKey: Keys.lastUpdateCheckDate)
        }
    }

    // MARK: - Update Check Helper

    func shouldCheckForUpdates() -> Bool {
        guard self.autoUpdateCheckEnabled else { return false }

        guard let lastCheck = lastUpdateCheckDate else {
            // Never checked before, should check
            return true
        }

        // Check if more than 1 hour has passed
        let hourInSeconds: TimeInterval = 60 * 60
        return Date().timeIntervalSince(lastCheck) >= hourInSeconds
    }

    func updateLastCheckDate() {
        self.lastUpdateCheckDate = Date()
    }

    // MARK: - Update Prompt Snooze

    /// Date until which update prompts are snoozed (user clicked "Later")
    var updatePromptSnoozedUntil: Date? {
        get { self.defaults.object(forKey: Keys.updatePromptSnoozedUntil) as? Date }
        set { self.defaults.set(newValue, forKey: Keys.updatePromptSnoozedUntil) }
    }

    /// The version that was snoozed (to allow prompting for newer versions)
    var snoozedUpdateVersion: String? {
        get { self.defaults.string(forKey: Keys.snoozedUpdateVersion) }
        set { self.defaults.set(newValue, forKey: Keys.snoozedUpdateVersion) }
    }

    /// Check if we should show the update prompt for a given version
    /// Returns false if user snoozed this version within the last 24 hours
    func shouldShowUpdatePrompt(forVersion version: String) -> Bool {
        // If a different (newer) version is available, always show
        if let snoozedVersion = snoozedUpdateVersion, snoozedVersion != version {
            return true
        }

        // Check if snooze period has expired
        guard let snoozedUntil = updatePromptSnoozedUntil else {
            return true // Never snoozed, show prompt
        }

        return Date() >= snoozedUntil
    }

    /// Snooze update prompts for 24 hours for the given version
    func snoozeUpdatePrompt(forVersion version: String) {
        let snoozeUntil = Date().addingTimeInterval(24 * 60 * 60) // 24 hours
        self.updatePromptSnoozedUntil = snoozeUntil
        self.snoozedUpdateVersion = version
        DebugLogger.shared.info("Update prompt snoozed for version \(version) until \(snoozeUntil)", source: "SettingsStore")
    }

    /// Clear the snooze (e.g., when update is installed)
    func clearUpdateSnooze() {
        self.updatePromptSnoozedUntil = nil
        self.snoozedUpdateVersion = nil
    }

    var playgroundUsed: Bool {
        get { self.defaults.bool(forKey: Keys.playgroundUsed) }
        set { self.defaults.set(newValue, forKey: Keys.playgroundUsed) }
    }

    // MARK: - Command Mode Settings

    var commandModeSelectedModel: String? {
        get { self.defaults.string(forKey: Keys.commandModeSelectedModel) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.commandModeSelectedModel)
        }
    }

    var commandModeSelectedProviderID: String {
        get { self.defaults.string(forKey: Keys.commandModeSelectedProviderID) ?? "openai" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.commandModeSelectedProviderID)
        }
    }

    var commandModeLinkedToGlobal: Bool {
        get { self.defaults.bool(forKey: Keys.commandModeLinkedToGlobal) } // Default to false (let user opt-in, or true if preferred)
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.commandModeLinkedToGlobal)
        }
    }

    var commandModeShortcutEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.commandModeShortcutEnabled)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.commandModeShortcutEnabled)
        }
    }

    var commandModeHotkeyShortcut: HotkeyShortcut {
        get {
            if let data = defaults.data(forKey: Keys.commandModeHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            // Default to Right Command key (keyCode: 54, no modifiers for the key itself)
            return HotkeyShortcut(keyCode: 54, modifierFlags: [])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.commandModeHotkeyShortcut)
            }
        }
    }

    var commandModeConfirmBeforeExecute: Bool {
        get {
            // Default to true (safer - ask before running commands)
            let value = self.defaults.object(forKey: Keys.commandModeConfirmBeforeExecute)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.commandModeConfirmBeforeExecute)
        }
    }

    // MARK: - Rewrite Mode Settings

    var rewriteModeHotkeyShortcut: HotkeyShortcut {
        get {
            if let data = defaults.data(forKey: Keys.rewriteModeHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            // Default to Option+R (keyCode: 15 is R, with Option modifier)
            return HotkeyShortcut(keyCode: 15, modifierFlags: [.option])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.rewriteModeHotkeyShortcut)
            }
        }
    }

    var rewriteModeSelectedModel: String? {
        get { self.defaults.string(forKey: Keys.rewriteModeSelectedModel) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.rewriteModeSelectedModel)
        }
    }

    var rewriteModeSelectedProviderID: String {
        get { self.defaults.string(forKey: Keys.rewriteModeSelectedProviderID) ?? "openai" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.rewriteModeSelectedProviderID)
        }
    }

    var rewriteModeLinkedToGlobal: Bool {
        get {
            // Default to true - sync with global settings by default
            let value = self.defaults.object(forKey: Keys.rewriteModeLinkedToGlobal)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.rewriteModeLinkedToGlobal)
        }
    }

    // MARK: - Model Reasoning Configuration

    /// Per-model reasoning configuration storage
    /// Key format: "provider:model" (e.g., "openai:gpt-5.1", "groq:gpt-oss-120b")
    var modelReasoningConfigs: [String: ModelReasoningConfig] {
        get {
            guard let data = defaults.data(forKey: Keys.modelReasoningConfigs),
                  let decoded = try? JSONDecoder().decode([String: ModelReasoningConfig].self, from: data)
            else {
                return [:]
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.modelReasoningConfigs)
            }
        }
    }

    /// Get reasoning config for a specific model, with smart defaults for known models
    func getReasoningConfig(forModel model: String, provider: String) -> ModelReasoningConfig? {
        let key = "\(provider):\(model)"

        // First check if user has a custom config
        if let customConfig = modelReasoningConfigs[key] {
            return customConfig.isEnabled ? customConfig : nil
        }

        // Apply smart defaults for known model patterns
        let modelLower = model.lowercased()

        // OpenAI gpt-5.x models
        if modelLower.hasPrefix("gpt-5") || modelLower.contains("gpt-5.") {
            return .openAIGPT5
        }

        // OpenAI o1/o3 reasoning models
        if modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") {
            return .openAIO1
        }

        // Groq gpt-oss models
        if modelLower.contains("gpt-oss") || modelLower.hasPrefix("openai/") {
            return .groqGPTOSS
        }

        // DeepSeek reasoner models
        if modelLower.contains("deepseek"), modelLower.contains("reasoner") {
            return .deepSeekReasoner
        }

        // No reasoning config needed for standard models (gpt-4.x, claude, llama, etc.)
        return nil
    }

    /// Set reasoning config for a specific model
    func setReasoningConfig(_ config: ModelReasoningConfig?, forModel model: String, provider: String) {
        let key = "\(provider):\(model)"
        var configs = self.modelReasoningConfigs

        if let config = config {
            configs[key] = config
        } else {
            configs.removeValue(forKey: key)
        }

        self.modelReasoningConfigs = configs
    }

    /// Check if a model has a custom (user-defined) reasoning config
    func hasCustomReasoningConfig(forModel model: String, provider: String) -> Bool {
        let key = "\(provider):\(model)"
        return self.modelReasoningConfigs[key] != nil
    }

    var rewriteModeShortcutEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.rewriteModeShortcutEnabled)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.rewriteModeShortcutEnabled)
        }
    }

    /// Global check if a model is a reasoning model (requires special params/max_completion_tokens)
    func isReasoningModel(_ model: String) -> Bool {
        let modelLower = model.lowercased()
        return modelLower.hasPrefix("gpt-5") ||
            modelLower.contains("gpt-5.") ||
            modelLower.hasPrefix("o1") ||
            modelLower.hasPrefix("o3") ||
            modelLower.contains("gpt-oss") ||
            modelLower.hasPrefix("openai/") ||
            (modelLower.contains("deepseek") && modelLower.contains("reasoner"))
    }

    /// Whether to display thinking tokens in the UI (Command Mode, Rewrite Mode)
    /// If false, thinking tokens are extracted but not shown to user
    var showThinkingTokens: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.showThinkingTokens)
            return value as? Bool ?? true // Default to true (show thinking)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.showThinkingTokens)
        }
    }

    /// Stored verification fingerprints per provider key (hash of baseURL + apiKey).
    var verifiedProviderFingerprints: [String: String] {
        get {
            guard let data = self.defaults.data(forKey: Keys.verifiedProviderFingerprints),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            else {
                return [:]
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.verifiedProviderFingerprints)
            } else {
                self.defaults.removeObject(forKey: Keys.verifiedProviderFingerprints)
            }
        }
    }

    // MARK: - Stats Settings

    /// User's typing speed in words per minute (for time saved calculation)
    var userTypingWPM: Int {
        get {
            let value = self.defaults.integer(forKey: Keys.userTypingWPM)
            return value > 0 ? value : 40 // Default to 40 WPM
        }
        set {
            objectWillChange.send()
            self.defaults.set(max(1, min(200, newValue)), forKey: Keys.userTypingWPM) // Clamp 1-200
        }
    }

    /// When enabled, weekends (Saturday/Sunday) don't break the usage streak
    var weekendsDontBreakStreak: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.weekendsDontBreakStreak)
            return value as? Bool ?? true // Default to true (weekends don't break streak)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.weekendsDontBreakStreak)
        }
    }

    // MARK: - Custom Dictation Prompt

    /// Custom system prompt for dictation mode. When empty, uses the default built-in prompt.
    var customDictationPrompt: String {
        get { self.defaults.string(forKey: Keys.customDictationPrompt) ?? "" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.customDictationPrompt)
        }
    }

    /// Whether to save transcription history for stats tracking
    /// When disabled, transcriptions are not stored and stats won't update
    var saveTranscriptionHistory: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.saveTranscriptionHistory)
            return value as? Bool ?? true // Default to true (save history)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.saveTranscriptionHistory)
        }
    }

    // MARK: - Private Methods

    private func persistProviderAPIKeys(_ values: [String: String]) {
        let trimmed = self.sanitizeAPIKeys(values)
        do {
            try self.keychain.storeAllKeys(trimmed)
        } catch {
            DebugLogger.shared.error(
                "Failed to persist provider API keys: \(error.localizedDescription)",
                source: "SettingsStore"
            )
        }
    }

    private func migrateProviderAPIKeysIfNeeded() {
        self.defaults.removeObject(forKey: Keys.providerAPIKeyIdentifiers)

        var merged = (try? self.keychain.fetchAllKeys()) ?? [:]
        var didMutate = false

        if let legacyDefaults = defaults.dictionary(forKey: Keys.providerAPIKeys) as? [String: String],
           legacyDefaults.isEmpty == false
        {
            merged.merge(self.sanitizeAPIKeys(legacyDefaults)) { _, new in new }
            didMutate = true
        }
        self.defaults.removeObject(forKey: Keys.providerAPIKeys)

        if let legacyKeychain = try? keychain.legacyProviderEntries(),
           legacyKeychain.isEmpty == false
        {
            merged.merge(self.sanitizeAPIKeys(legacyKeychain)) { _, new in new }
            didMutate = true
            try? self.keychain.removeLegacyEntries(providerIDs: Array(legacyKeychain.keys))
        }

        if didMutate {
            self.persistProviderAPIKeys(merged)
        }
    }

    private func migrateDictationPromptProfilesIfNeeded() {
        // Migration path from legacy single prompt to multi-prompt profiles.
        // If user had a legacy custom dictation prompt, convert it to a profile and select it.
        let legacyPrompt = self.customDictationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyPrompt.isEmpty else { return }

        // If profiles already exist, just clear the legacy prompt so we don't keep two sources of truth.
        if self.dictationPromptProfiles.isEmpty == false {
            self.customDictationPrompt = ""
            // If selection points to nowhere, reset to default to avoid confusion.
            if let id = self.selectedDictationPromptID,
               self.dictationPromptProfiles.contains(where: { $0.id == id }) == false
            {
                self.selectedDictationPromptID = nil
            }
            return
        }

        let profile = DictationPromptProfile(
            name: "My Custom Prompt",
            prompt: legacyPrompt,
            createdAt: Date(),
            updatedAt: Date()
        )
        self.dictationPromptProfiles = [profile]
        self.selectedDictationPromptID = profile.id
        self.customDictationPrompt = ""
        DebugLogger.shared.info("Migrated legacy custom dictation prompt to a prompt profile", source: "SettingsStore")
    }

    private func scrubSavedProviderAPIKeys() {
        guard let data = defaults.data(forKey: Keys.savedProviders),
              var decoded = try? JSONDecoder().decode([SavedProvider].self, from: data) else { return }

        var didModify = false
        for index in decoded.indices {
            let provider = decoded[index]
            let trimmed = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }

            let keyID = self.canonicalProviderKey(for: provider.id)
            do {
                try self.keychain.storeKey(trimmed, for: keyID)
                didModify = true
            } catch {
                DebugLogger.shared
                    .error(
                        "Failed to migrate API key for \(provider.name): \(error.localizedDescription)",
                        source: "SettingsStore"
                    )
            }

            decoded[index] = SavedProvider(
                id: provider.id,
                name: provider.name,
                baseURL: provider.baseURL,
                apiKey: "",
                models: provider.models
            )
        }

        if didModify,
           let encoded = try? JSONEncoder().encode(decoded)
        {
            self.defaults.set(encoded, forKey: Keys.savedProviders)
        }

        // No need to track migrated IDs; consolidated storage keeps them together.
    }

    private func canonicalProviderKey(for providerID: String) -> String {
        // Built-in providers use their ID directly
        if ModelRepository.shared.isBuiltIn(providerID) {
            return providerID
        }
        if providerID.hasPrefix("custom:") {
            return providerID
        }
        return "custom:\(providerID)"
    }

    private func sanitizeAPIKeys(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [String: String]()) { partialResult, pair in
            let sanitizedValue = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sanitizedValue.isEmpty == false else { return }
            partialResult[pair.key] = sanitizedValue
        }
    }

    private func updateLaunchAtStartup(_ enabled: Bool) {
        #if os(macOS)
        // Note: SMAppService.mainApp requires the app to be signed with Developer ID
        // and have proper entitlements. This may not work in development builds.
        let service = SMAppService.mainApp

        do {
            if enabled {
                try service.register()
                DebugLogger.shared.info("Successfully registered for launch at startup", source: "SettingsStore")
            } else {
                try service.unregister()
                DebugLogger.shared.info("Successfully unregistered from launch at startup", source: "SettingsStore")
            }
        } catch {
            DebugLogger.shared.error("Failed to update launch at startup: \(error)", source: "SettingsStore")
            // In development, this is expected to fail without proper signing/entitlements
            // The setting is still saved and will work when the app is properly signed
        }
        #endif
    }

    private func updateDockVisibility(_ visible: Bool) {
        #if os(macOS)
        // IMPORTANT: This is a simplified implementation for development
        // In production, consider these approaches:
        // 1. Use LSUIElement in Info.plist to control default dock visibility
        // 2. Implement a proper helper app or service for dock management
        // 3. Use NSApplication.shared.setActivationPolicy() for better control

        // For now, we'll try multiple approaches with fallbacks

        DebugLogger.shared.debug(
            "Attempting to update dock visibility to: \(visible ? "visible" : "hidden")",
            source: "SettingsStore"
        )

        // Method 1: Try the deprecated TransformProcessType (may not work on all systems)
        let transformState = visible ? ProcessApplicationTransformState(kProcessTransformToForegroundApplication)
            : ProcessApplicationTransformState(kProcessTransformToUIElementApplication)

        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        let result = TransformProcessType(&psn, transformState)

        if result == 0 {
            DebugLogger.shared.info("✓ Dock visibility updated using TransformProcessType", source: "SettingsStore")
        } else {
            DebugLogger.shared
                .warning(
                    "⚠️ TransformProcessType failed (error: \(result)). This is expected on some macOS versions.",
                    source: "SettingsStore"
                )
            DebugLogger.shared.debug(
                "   The setting is saved and will be applied when possible.",
                source: "SettingsStore"
            )
        }

        // Method 2: Try to notify the system of the change
        // This may help with some system caches
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
            DebugLogger.shared.info(
                "✓ Activation policy updated to: \(visible ? "regular" : "accessory")",
                source: "SettingsStore"
            )
        }

        // Store the intended state for reference
        UserDefaults.standard.set(visible, forKey: "IntendedDockVisibility")
        DebugLogger.shared.info("✓ Dock visibility preference saved: \(visible)", source: "SettingsStore")
        #endif
    }

    // MARK: - Filler Words

    static let defaultFillerWords = [
        "um",
        "uh",
        "er",
        "ah",
        "eh",
        "umm",
        "uhh",
        "err",
        "ahh",
        "ehh",
        "hmm",
        "hm",
        "mm",
        "mmm",
        "erm",
        "urm",
        "ugh",
    ]

    var fillerWords: [String] {
        get {
            if let stored = defaults.array(forKey: Keys.fillerWords) as? [String] {
                return stored
            }
            return Self.defaultFillerWords
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.fillerWords)
        }
    }

    var removeFillerWordsEnabled: Bool {
        get { self.defaults.object(forKey: Keys.removeFillerWordsEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.removeFillerWordsEnabled)
        }
    }

    // MARK: - GAAV Mode

    /// GAAV Mode: Removes first letter capitalization and trailing period from transcriptions.
    /// Useful for search queries, form fields, or casual text input where sentence formatting is unwanted.
    /// Feature requested by maxgaav – thank you for the suggestion!
    var gaavModeEnabled: Bool {
        get { self.defaults.object(forKey: Keys.gaavModeEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.gaavModeEnabled)
        }
    }

    // MARK: - Media Playback Control

    /// When enabled, automatically pauses system media playback when transcription starts.
    /// Only resumes if FluidVoice was the one that paused it.
    var pauseMediaDuringTranscription: Bool {
        get { self.defaults.object(forKey: Keys.pauseMediaDuringTranscription) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.pauseMediaDuringTranscription)
        }
    }

    // MARK: - Custom Dictionary

    /// A custom dictionary entry that maps multiple misheard/alternate spellings to a correct replacement.
    /// For example: ["fluid voice", "fluid boys"] -> "FluidVoice"
    struct CustomDictionaryEntry: Codable, Identifiable, Hashable {
        let id: UUID
        /// Words/phrases to look for (case-insensitive matching)
        var triggers: [String]
        /// The correct replacement text
        var replacement: String

        init(triggers: [String], replacement: String) {
            self.id = UUID()
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }

        init(id: UUID, triggers: [String], replacement: String) {
            self.id = id
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }
    }

    /// Custom dictionary entries for word replacement
    var customDictionaryEntries: [CustomDictionaryEntry] {
        get {
            guard let data = defaults.data(forKey: Keys.customDictionaryEntries),
                  let decoded = try? JSONDecoder().decode([CustomDictionaryEntry].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.customDictionaryEntries)
            }
        }
    }

    // MARK: - Speech Model (Unified ASR Model Selection)

    /// Unified speech recognition model selection.
    /// Replaces the old TranscriptionProviderOption + WhisperModelSize dual-setting.
    enum SpeechModel: String, CaseIterable, Identifiable, Codable {
        // MARK: - FluidAudio Models (Apple Silicon Only)

        case parakeetTDT = "parakeet-tdt"
        case parakeetTDTv2 = "parakeet-tdt-v2"

        // MARK: - Apple Native

        case appleSpeech = "apple-speech"
        case appleSpeechAnalyzer = "apple-speech-analyzer"

        // MARK: - Whisper Models (Universal)

        case whisperTiny = "whisper-tiny"
        case whisperBase = "whisper-base"
        case whisperSmall = "whisper-small"
        case whisperMedium = "whisper-medium"
        case whisperLargeTurbo = "whisper-large-turbo" // temporarily disabled in UI
        case whisperLarge = "whisper-large"

        var id: String { rawValue }

        // MARK: - Display Properties

        var displayName: String {
            switch self {
            case .parakeetTDT: return "Parakeet TDT v3 (Multilingual)"
            case .parakeetTDTv2: return "Parakeet TDT v2 (English Only)"
            case .appleSpeech: return "Apple ASR Legacy"
            case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
            case .whisperTiny: return "Whisper Tiny"
            case .whisperBase: return "Whisper Base"
            case .whisperSmall: return "Whisper Small"
            case .whisperMedium: return "Whisper Medium"
            case .whisperLargeTurbo: return "Whisper Large Turbo (Disabled)"
            case .whisperLarge: return "Whisper Large"
            }
        }

        var languageSupport: String {
            switch self {
            case .parakeetTDT: return "25 Languages"
            case .parakeetTDTv2: return "English Only (Higher Accuracy)"
            case .appleSpeech: return "System Languages"
            case .appleSpeechAnalyzer: return "EN, ES, FR, DE, IT, JA, KO, PT, ZH"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "99 Languages"
            }
        }

        var downloadSize: String {
            switch self {
            case .parakeetTDT: return "~500 MB"
            case .parakeetTDTv2: return "~500 MB"
            case .appleSpeech: return "Built-in (Zero Download)"
            case .appleSpeechAnalyzer: return "Built-in"
            case .whisperTiny: return "~75 MB"
            case .whisperBase: return "~142 MB"
            case .whisperSmall: return "~466 MB"
            case .whisperMedium: return "~1.5 GB"
            case .whisperLargeTurbo: return "~1.6 GB"
            case .whisperLarge: return "~2.9 GB"
            }
        }

        var requiresAppleSilicon: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2: return true
            default: return false
            }
        }

        var isWhisperModel: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .appleSpeech, .appleSpeechAnalyzer: return false
            default: return true
            }
        }

        /// The ggml filename for Whisper models
        var whisperModelFile: String? {
            switch self {
            case .whisperTiny: return "ggml-tiny.bin"
            case .whisperBase: return "ggml-base.bin"
            case .whisperSmall: return "ggml-small.bin"
            case .whisperMedium: return "ggml-medium.bin"
            case .whisperLargeTurbo: return "ggml-large-v3-turbo.bin"
            case .whisperLarge: return "ggml-large-v3.bin"
            default: return nil
            }
        }

        /// The short model name for whisper.cpp internal usage
        var whisperModelName: String? {
            switch self {
            case .whisperTiny: return "tiny"
            case .whisperBase: return "base"
            case .whisperSmall: return "small"
            case .whisperMedium: return "medium"
            case .whisperLargeTurbo: return "large-v3-turbo"
            case .whisperLarge: return "large-v3"
            default: return nil
            }
        }

        // MARK: - Architecture Filtering

        /// Requires macOS 26 (Tahoe) or later
        var requiresMacOS26: Bool {
            switch self {
            case .appleSpeechAnalyzer: return true
            default: return false
            }
        }

        /// Returns models available for the current Mac's architecture and OS
        static var availableModels: [SpeechModel] {
            allCases.filter { model in
                if model == .whisperLargeTurbo {
                    return false
                }
                // Filter by Apple Silicon requirement
                if model.requiresAppleSilicon, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                // Filter by macOS 26 requirement
                if model.requiresMacOS26 {
                    if #available(macOS 26.0, *) {
                        return true
                    } else {
                        return false
                    }
                }
                return true
            }
        }

        /// Default model for the current architecture
        static var defaultModel: SpeechModel {
            CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase
        }

        // MARK: - UI Card Metadata

        /// Human-readable marketing name for the card UI
        var humanReadableName: String {
            switch self {
            case .parakeetTDT: return "Blazing Fast - Multilingual"
            case .parakeetTDTv2: return "Blazing Fast - English"
            case .appleSpeech: return "Apple ASR Legacy"
            case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
            case .whisperTiny: return "Fast & Light"
            case .whisperBase: return "Standard Choice"
            case .whisperSmall: return "Balanced Speed & Accuracy"
            case .whisperMedium: return "Medium Quality"
            case .whisperLargeTurbo: return "Higher Quality but Faster"
            case .whisperLarge: return "Maximum Accuracy"
            }
        }

        /// One-line description for the card UI
        var cardDescription: String {
            switch self {
            case .parakeetTDT:
                return "Fast multilingual transcription with 25 languages. Best for everyday use."
            case .parakeetTDTv2:
                return "Optimized for English accuracy and fastest transcription."
            case .appleSpeech:
                return "Built-in macOS speech recognition. No download required."
            case .appleSpeechAnalyzer:
                return "Advanced and modern on-device recognition for newer macOS devices."
            case .whisperTiny:
                return "Minimal resource usage. Best for older Macs or battery life."
            case .whisperBase:
                return "Good balance of speed and accuracy. Works on any Mac."
            case .whisperSmall:
                return "Better accuracy than Base. Moderate resource usage."
            case .whisperMedium:
                return "High accuracy for demanding tasks. Requires more memory."
            case .whisperLargeTurbo:
                return "Near-maximum accuracy with optimized speed."
            case .whisperLarge:
                return "Best possible accuracy. Large download and memory usage."
            }
        }

        /// Minimum recommended RAM in GB for this model to run safely
        var requiredMemoryGB: Double {
            switch self {
            case .parakeetTDT, .parakeetTDTv2:
                return 4.0
            case .appleSpeech, .appleSpeechAnalyzer:
                return 2.0 // Built-in, minimal overhead
            case .whisperTiny:
                return 2.0
            case .whisperBase:
                return 3.0
            case .whisperSmall:
                return 4.0
            case .whisperMedium:
                return 6.0
            case .whisperLargeTurbo:
                return 8.0
            case .whisperLarge:
                return 10.0 // Large model needs ~6-8GB working memory + model size
            }
        }

        /// Warning text for models with high memory requirements, nil if no warning needed
        var memoryWarning: String? {
            switch self {
            case .whisperLarge:
                return "⚠️ Requires 10GB+ RAM. May crash on systems with limited memory."
            case .whisperLargeTurbo:
                return "⚠️ Requires 8GB+ RAM. May be unstable on some systems."
            case .whisperMedium:
                return "Requires 6GB+ RAM for stable operation."
            default:
                return nil
            }
        }

        /// Speed rating (1-5, higher is faster)
        var speedRating: Int {
            switch self {
            case .parakeetTDT: return 5
            case .parakeetTDTv2: return 5
            case .appleSpeech: return 4
            case .appleSpeechAnalyzer: return 4
            case .whisperTiny: return 4
            case .whisperBase: return 4
            case .whisperSmall: return 3
            case .whisperMedium: return 2
            case .whisperLargeTurbo: return 3
            case .whisperLarge: return 1
            }
        }

        /// Accuracy rating (1-5, higher is more accurate)
        var accuracyRating: Int {
            switch self {
            case .parakeetTDT: return 5
            case .parakeetTDTv2: return 5
            case .appleSpeech: return 4
            case .appleSpeechAnalyzer: return 4
            case .whisperTiny: return 2
            case .whisperBase: return 3
            case .whisperSmall: return 4
            case .whisperMedium: return 4
            case .whisperLargeTurbo: return 5
            case .whisperLarge: return 5
            }
        }

        /// Exact speed percentage (0.0 - 1.0) for the liquid bars
        var speedPercent: Double {
            switch self {
            case .parakeetTDT: return 1.0
            case .parakeetTDTv2: return 1.0
            case .appleSpeech: return 0.60
            case .appleSpeechAnalyzer: return 0.85
            case .whisperTiny: return 0.90
            case .whisperBase: return 0.80
            case .whisperSmall: return 0.60
            case .whisperMedium: return 0.40
            case .whisperLargeTurbo: return 0.65
            case .whisperLarge: return 0.20
            }
        }

        /// Exact accuracy percentage (0.0 - 1.0) for the liquid bars
        var accuracyPercent: Double {
            switch self {
            case .parakeetTDT: return 0.95
            case .parakeetTDTv2: return 0.98
            case .appleSpeech: return 0.60
            case .appleSpeechAnalyzer: return 0.80
            case .whisperTiny: return 0.40
            case .whisperBase: return 0.60
            case .whisperSmall: return 0.70
            case .whisperMedium: return 0.80
            case .whisperLargeTurbo: return 0.95
            case .whisperLarge: return 1.00
            }
        }

        /// Optional badge text for the card (e.g., "FluidVoice Pick")
        var badgeText: String? {
            switch self {
            case .parakeetTDT: return "FluidVoice Pick"
            case .parakeetTDTv2: return "FluidVoice Pick"
            case .appleSpeechAnalyzer: return "New"
            default: return nil
            }
        }

        /// Optimization level for Apple Silicon (for display)
        var appleSiliconOptimized: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .appleSpeechAnalyzer:
                return true
            default:
                return false
            }
        }

        /// Whether this model supports real-time streaming/chunk processing.
        /// Large Whisper models are too slow for streaming, so they only do final transcription on stop.
        var supportsStreaming: Bool {
            switch self {
            case .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return false // Too slow for real-time chunk processing
            default:
                return true // All other models support streaming
            }
        }

        /// Provider category for tab grouping
        enum Provider: String, CaseIterable {
            case nvidia = "NVIDIA"
            case apple = "Apple"
            case openai = "OpenAI"
        }

        /// Which provider this model belongs to
        var provider: Provider {
            switch self {
            case .parakeetTDT, .parakeetTDTv2:
                return .nvidia
            case .appleSpeech, .appleSpeechAnalyzer:
                return .apple
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return .openai
            }
        }

        /// Get models filtered by provider
        static func models(for provider: Provider) -> [SpeechModel] {
            self.availableModels.filter { $0.provider == provider }
        }

        /// Whether this model is built-in or already downloaded on disk
        var isInstalled: Bool {
            switch self {
            case .appleSpeech, .appleSpeechAnalyzer:
                return true
            case .parakeetTDT:
                // Hardcoded path check for NVIDIA v3
                return Self.parakeetCacheDirectory(version: "parakeet-tdt-0.6b-v3-coreml")
            case .parakeetTDTv2:
                // Hardcoded path check for NVIDIA v2
                return Self.parakeetCacheDirectory(version: "parakeet-tdt-0.6b-v2-coreml")
            default:
                // Whisper models
                guard let whisperFile = self.whisperModelFile else { return false }
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("WhisperModels")
                let modelURL = directory?.appendingPathComponent(whisperFile)
                return modelURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }
        }

        private static func parakeetCacheDirectory(version: String) -> Bool {
            #if canImport(FluidAudio)
            let baseCacheDir = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
            let modelDir = baseCacheDir.appendingPathComponent(version)
            return FileManager.default.fileExists(atPath: modelDir.path)
            #else
            let baseCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent(version)
            return baseCacheDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            #endif
        }

        /// Brand/provider name for the model (NVIDIA, Apple, OpenAI)
        var brandName: String {
            switch self {
            case .parakeetTDT, .parakeetTDTv2:
                return "NVIDIA"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "Apple"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "OpenAI"
            }
        }

        /// Whether this model uses Apple's SF Symbol for branding (apple.logo)
        var usesAppleLogo: Bool {
            switch self {
            case .appleSpeech, .appleSpeechAnalyzer: return true
            default: return false
            }
        }

        /// Brand color for the provider badge
        var brandColorHex: String {
            switch self {
            case .parakeetTDT, .parakeetTDTv2:
                return "#76B900"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "#A2AAAD" // Apple Gray
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "#10A37F" // OpenAI Teal
            }
        }
    }

    // MARK: - Transcription Provider (ASR)

    /// Available transcription providers
    enum TranscriptionProviderOption: String, CaseIterable, Identifiable {
        case auto
        case fluidAudio
        case whisper

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "Automatic (Recommended)"
            case .fluidAudio: return "FluidAudio (Apple Silicon)"
            case .whisper: return "Whisper (Intel/Universal)"
            }
        }

        var description: String {
            switch self {
            case .auto: return "Uses FluidAudio on Apple Silicon, Whisper on Intel"
            case .fluidAudio: return "Fast CoreML-based transcription optimized for M-series chips"
            case .whisper: return "whisper.cpp - CPU-based, works on any Mac"
            }
        }
    }

    /// Available Whisper model sizes
    enum WhisperModelSize: String, CaseIterable, Identifiable {
        case tiny = "ggml-tiny.bin"
        case base = "ggml-base.bin"
        case small = "ggml-small.bin"
        case medium = "ggml-medium.bin"
        case large = "ggml-large-v3.bin"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .tiny: return "Tiny (~75 MB)"
            case .base: return "Base (~142 MB)"
            case .small: return "Small (~466 MB)"
            case .medium: return "Medium (~1.5 GB)"
            case .large: return "Large (~2.9 GB)"
            }
        }

        var description: String {
            switch self {
            case .tiny: return "Fastest, lower accuracy"
            case .base: return "Good balance of speed and accuracy"
            case .small: return "Better accuracy, slower"
            case .medium: return "High accuracy, requires more memory"
            case .large: return "Best accuracy, large download"
            }
        }
    }

    /// Selected transcription provider - defaults to "auto" which picks based on architecture
    var selectedTranscriptionProvider: TranscriptionProviderOption {
        get {
            guard let rawValue = defaults.string(forKey: Keys.selectedTranscriptionProvider),
                  let option = TranscriptionProviderOption(rawValue: rawValue)
            else {
                return .auto
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedTranscriptionProvider)
        }
    }

    /// Selected Whisper model size - defaults to "base"
    var whisperModelSize: WhisperModelSize {
        get {
            guard let rawValue = defaults.string(forKey: Keys.whisperModelSize),
                  let size = WhisperModelSize(rawValue: rawValue)
            else {
                return .base
            }
            return size
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.whisperModelSize)
        }
    }

    // MARK: - Unified Speech Model Selection

    /// The selected speech recognition model.
    /// This unified setting replaces the old TranscriptionProviderOption + WhisperModelSize combination.
    var selectedSpeechModel: SpeechModel {
        get {
            // Check if already using new system
            if let rawValue = defaults.string(forKey: Keys.selectedSpeechModel),
               let model = SpeechModel(rawValue: rawValue)
            {
                // Validate model is available on this architecture
                if model.requiresAppleSilicon && !CPUArchitecture.isAppleSilicon {
                    return .whisperBase
                }
                return model
            }

            // Migration: Convert old settings to new SpeechModel
            return self.migrateToSpeechModel()
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedSpeechModel)
        }
    }

    /// Migrates old TranscriptionProviderOption + WhisperModelSize settings to new SpeechModel
    private func migrateToSpeechModel() -> SpeechModel {
        let oldProvider = self.defaults.string(forKey: Keys.selectedTranscriptionProvider) ?? "auto"
        let oldWhisperSize = self.defaults.string(forKey: Keys.whisperModelSize) ?? "ggml-base.bin"

        let newModel: SpeechModel

        switch oldProvider {
        case "whisper":
            // Map old whisper size to new model
            switch oldWhisperSize {
            case "ggml-tiny.bin": newModel = .whisperTiny
            case "ggml-base.bin": newModel = .whisperBase
            case "ggml-small.bin": newModel = .whisperSmall
            case "ggml-medium.bin": newModel = .whisperMedium
            case "ggml-large-v3.bin": newModel = .whisperLarge
            default: newModel = .whisperBase
            }
        case "fluidAudio":
            newModel = CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase
        default: // "auto"
            newModel = SpeechModel.defaultModel
        }

        // Persist the migrated value
        self.defaults.set(newModel.rawValue, forKey: Keys.selectedSpeechModel)
        DebugLogger.shared.info("Migrated speech model settings: \(oldProvider)/\(oldWhisperSize) -> \(newModel.rawValue)", source: "SettingsStore")

        return newModel
    }
}
