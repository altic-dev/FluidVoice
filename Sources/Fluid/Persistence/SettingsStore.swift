import AppKit
import ApplicationServices
import Combine
import Foundation
import ServiceManagement

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let defaults = UserDefaults.standard
    private let keychain = KeychainService.shared

    private init() {
        self.migrateProviderAPIKeysIfNeeded()
        self.scrubSavedProviderAPIKeys()
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
        static let hotkeyShortcutKey = "HotkeyShortcutKey"
        static let preferredInputDeviceUID = "PreferredInputDeviceUID"
        static let preferredOutputDeviceUID = "PreferredOutputDeviceUID"
        static let visualizerNoiseThreshold = "VisualizerNoiseThreshold"
        static let launchAtStartup = "LaunchAtStartup"
        static let showInDock = "ShowInDock"
        static let pressAndHoldMode = "PressAndHoldMode"
        static let enableStreamingPreview = "EnableStreamingPreview"
        static let enableAIStreaming = "EnableAIStreaming"
        static let copyTranscriptionToClipboard = "CopyTranscriptionToClipboard"
        static let autoUpdateCheckEnabled = "AutoUpdateCheckEnabled"
        static let lastUpdateCheckDate = "LastUpdateCheckDate"
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

        // Stats Keys
        static let userTypingWPM = "UserTypingWPM"

        // Filler Words
        static let fillerWords = "FillerWords"
        static let removeFillerWordsEnabled = "RemoveFillerWordsEnabled"

        // Transcription Provider (ASR)
        static let selectedTranscriptionProvider = "SelectedTranscriptionProvider"
        static let whisperModelSize = "WhisperModelSize"

        // Unified Speech Model (replaces above two)
        static let selectedSpeechModel = "SelectedSpeechModel"
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
            return value as? Bool ?? false // Default to false (disabled)
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

    var visualizerNoiseThreshold: Double {
        get {
            let value = self.defaults.double(forKey: Keys.visualizerNoiseThreshold)
            return value == 0.0 ? 0.4 : value // Default to 0.4 if not set
        }
        set { self.defaults.set(newValue, forKey: Keys.visualizerNoiseThreshold) }
    }

    // MARK: - Preferences Settings

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

        // Check if more than 24 hours have passed
        let dayInSeconds: TimeInterval = 24 * 60 * 60
        return Date().timeIntervalSince(lastCheck) >= dayInSeconds
    }

    func updateLastCheckDate() {
        self.lastUpdateCheckDate = Date()
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
        get {
            self.defaults
                .bool(forKey: Keys.commandModeLinkedToGlobal)
        } // Default to false (let user opt-in, or true if
        // preferred)
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
        if providerID == "openai" || providerID == "groq" {
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

    // MARK: - Speech Model (Unified ASR Model Selection)

    /// Unified speech recognition model selection.
    /// Replaces the old TranscriptionProviderOption + WhisperModelSize dual-setting.
    enum SpeechModel: String, CaseIterable, Identifiable, Codable {
        // MARK: - FluidAudio Models (Apple Silicon Only)

        case parakeetTDT = "parakeet-tdt"

        // MARK: - Whisper Models (Universal)

        case whisperTiny = "whisper-tiny"
        case whisperBase = "whisper-base"
        case whisperSmall = "whisper-small"
        case whisperMedium = "whisper-medium"
        case whisperLargeTurbo = "whisper-large-turbo"
        case whisperLarge = "whisper-large"

        var id: String { rawValue }

        // MARK: - Display Properties

        var displayName: String {
            switch self {
            case .parakeetTDT: return "Parakeet TDT"
            case .whisperTiny: return "Whisper Tiny"
            case .whisperBase: return "Whisper Base"
            case .whisperSmall: return "Whisper Small"
            case .whisperMedium: return "Whisper Medium"
            case .whisperLargeTurbo: return "Whisper Large Turbo"
            case .whisperLarge: return "Whisper Large"
            }
        }

        var languageSupport: String {
            switch self {
            case .parakeetTDT: return "25 Languages"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "99 Languages"
            }
        }

        var downloadSize: String {
            switch self {
            case .parakeetTDT: return "~500 MB"
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
            case .parakeetTDT: return true
            default: return false
            }
        }

        var isWhisperModel: Bool {
            switch self {
            case .parakeetTDT: return false
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

        /// Returns models available for the current Mac's architecture
        static var availableModels: [SpeechModel] {
            allCases.filter { model in
                !model.requiresAppleSilicon || CPUArchitecture.isAppleSilicon
            }
        }

        /// Default model for the current architecture
        static var defaultModel: SpeechModel {
            CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase
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
        DebugLogger.shared
            .info(
                "Migrated speech model settings: \(oldProvider)/\(oldWhisperSize) -> \(newModel.rawValue)",
                source: "SettingsStore"
            )

        return newModel
    }
}
