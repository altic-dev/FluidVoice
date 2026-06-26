import AppKit
import Combine
import CryptoKit
import Security
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AIEnhancementSettingsViewModel: ObservableObject {
    let settings: SettingsStore
    let menuBarManager: MenuBarManager
    let promptTest: DictationPromptTestCoordinator

    @Published var appear: Bool = false
    @Published var openAIBaseURL: String
    @Published var isDictationPromptOff: Bool = false
    @Published var isEditPromptOff: Bool = false

    // Model Management
    @Published var availableModelsByProvider: [String: [String]] = [:]
    @Published var selectedModelByProvider: [String: String] = [:]
    @Published var availableModels: [String] = []
    @Published var selectedModel: String = "" {
        didSet {
            guard self.selectedModel != "__ADD_MODEL__" else { return }
            guard !self.currentProvider.isEmpty else { return }
            self.selectedModelByProvider[self.currentProvider] = self.selectedModel
            self.settings.selectedModelByProvider = self.selectedModelByProvider
        }
    }

    @Published var showingAddModel: Bool = false
    @Published var newModelName: String = ""
    @Published var isFetchingModels: Bool = false
    @Published var refreshingProviderID: String? = nil
    @Published var fetchModelsError: String? = nil

    // Reasoning Configuration
    @Published var showingReasoningConfig: Bool = false
    @Published var editingReasoningParamName: String = "reasoning_effort"
    @Published var editingReasoningParamValue: String = "low"
    @Published var editingReasoningEnabled: Bool = false

    // Provider Management
    @Published var appleIntelligenceAvailable: Bool = false
    @Published var providerAPIKeys: [String: String] = [:]
    @Published var currentProvider: String = ""
    @Published var savedProviders: [SettingsStore.SavedProvider] = []
    @Published var selectedProviderID: String {
        didSet {
            self.settings.selectedProviderID = self.selectedProviderID
            self.syncPromptSelectionForSelectedProvider()
        }
    }

    // Connection Testing
    @Published var isTestingConnection: Bool = false
    @Published var connectionStatus: AIConnectionStatus = .unknown
    @Published var connectionErrorMessage: String = ""
    @Published var connectionStatusByProvider: [String: AIConnectionStatus] = [:]
    @Published var connectionErrorMessageByProvider: [String: String] = [:]
    @Published var fetchedModelsProviders: Set<String> = []
    @Published var editingAPIKeyProviders: Set<String> = []

    // UI State
    @Published var showHelp: Bool = false
    @Published var showingSaveProvider: Bool = false
    @Published var showAPIKeyEditor: Bool = false
    @Published var showingEditProvider: Bool = false

    // Provider Form State
    @Published var newProviderName: String = ""
    @Published var newProviderBaseURL: String = ""
    @Published var newProviderApiKey: String = ""
    @Published var newProviderModels: String = ""
    @Published var editProviderName: String = ""
    @Published var editProviderBaseURL: String = ""
    @Published var editProviderApiKey: String = ""

    // Keychain State
    @Published var showKeychainPermissionAlert: Bool = false
    @Published var keychainPermissionMessage: String = ""

    // Reasoning config change tracker (triggers view updates)
    @Published var reasoningConfigVersion: Int = 0

    // MARK: - Cached Provider Items (for scroll performance)

    // These are cached to avoid recomputing on every view body evaluation
    struct ProviderItemData: Identifiable, Hashable {
        let id: String
        let name: String
        let isBuiltIn: Bool
    }

    struct AppBindingTarget: Identifiable, Hashable {
        let bundleID: String
        let name: String

        var id: String { self.bundleID }
    }

    @Published var cachedProviderItems: [ProviderItemData] = []
    @Published var cachedVerifiedProviderItems: [ProviderItemData] = []
    @Published var cachedUnverifiedProviderItems: [ProviderItemData] = []

    // Dictation Prompt Profiles UI
    @Published var dictationPromptProfiles: [SettingsStore.DictationPromptProfile] = []
    @Published var appPromptBindings: [SettingsStore.AppPromptBinding] = []
    @Published var appPromptBindingErrorMessage: String = ""
    @Published var selectedDictationPromptID: String? = nil
    @Published var selectedEditPromptID: String? = nil
    @Published var promptEditorMode: PromptEditorMode? = nil
    @Published var draftPromptName: String = ""
    @Published var draftPromptText: String = ""
    @Published var draftPromptMode: SettingsStore.PromptMode = .dictate
    @Published var draftIncludeContext: Bool = false
    @Published var promptEditorSessionID: UUID = .init()
    @Published var pendingNewPromptConfiguration: SettingsStore.DictationPromptConfiguration?

    // Prompt Deletion UI
    @Published var showingDeletePromptConfirm: Bool = false
    @Published var pendingDeletePromptID: String? = nil
    @Published var pendingDeletePromptName: String = ""

    private var newPromptShortcutCancellable: AnyCancellable?

    init(settings: SettingsStore, menuBarManager: MenuBarManager, promptTest: DictationPromptTestCoordinator) {
        self.settings = settings
        self.menuBarManager = menuBarManager
        self.promptTest = promptTest
        self.openAIBaseURL = ""
        self.selectedProviderID = settings.selectedProviderID

        self.newPromptShortcutCancellable = NotificationCenter.default
            .publisher(for: .newPromptShortcutRecorded)
            .sink { [weak self] notification in
                guard let self,
                      let shortcut = notification.userInfo?["shortcut"] as? HotkeyShortcut
                else { return }
                var config = self.pendingNewPromptConfiguration ?? SettingsStore.DictationPromptConfiguration()
                config.shortcut = shortcut
                self.pendingNewPromptConfiguration = config
            }
    }

    func onAppear() {
        self.appear = true
        self.loadSettings()
    }

    // MARK: - Load Settings

    func loadSettings() {
        self.settings.normalizeProviderSelectionForCurrentVerificationState()
        self.settings.reconcilePromptStateAfterProfileChanges()
        self.selectedProviderID = self.settings.selectedProviderID

        self.availableModelsByProvider = self.settings.availableModelsByProvider
        self.selectedModelByProvider = self.settings.selectedModelByProvider
        self.appleIntelligenceAvailable = AppleIntelligenceService.isAvailable
        self.providerAPIKeys = self.settings.providerAPIKeys
        self.savedProviders = self.settings.savedProviders
        self.dictationPromptProfiles = self.settings.dictationPromptProfiles
        self.appPromptBindings = self.settings.appPromptBindings
        self.selectedDictationPromptID = self.settings.selectedDictationPromptID
        self.selectedEditPromptID = self.settings.selectedEditPromptID
        self.isDictationPromptOff = self.settings.isDictationPromptOff
        self.isEditPromptOff = self.settings.isEditPromptOff

        if !self.selectedProviderID.isEmpty,
           !ModelRepository.shared.isBuiltIn(self.selectedProviderID),
           self.savedProviders.contains(where: { $0.id == self.selectedProviderID }) == false
        {
            self.selectedProviderID = ""
        }

        // Normalize provider keys
        var normalized: [String: [String]] = [:]
        for (key, models) in self.availableModelsByProvider {
            let lower = key.lowercased()
            let newKey: String
            // Use ModelRepository to correctly identify ALL built-in providers
            if ModelRepository.shared.isBuiltIn(lower) {
                newKey = lower
            } else {
                newKey = key.hasPrefix("custom:") ? key : "custom:\(key)"
            }
            let clean = Array(Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
            if !clean.isEmpty { normalized[newKey] = clean }
        }
        self.availableModelsByProvider = normalized
        self.settings.availableModelsByProvider = normalized

        // Normalize selected model by provider
        var normalizedSel: [String: String] = [:]
        for (key, model) in self.selectedModelByProvider {
            let lower = key.lowercased()
            // Use ModelRepository to correctly identify ALL built-in providers
            let newKey: String = ModelRepository.shared.isBuiltIn(lower) ? lower :
                (key.hasPrefix("custom:") ? key : "custom:\(key)")
            if let list = normalized[newKey], list.contains(model) { normalizedSel[newKey] = model }
        }
        self.selectedModelByProvider = normalizedSel
        self.settings.selectedModelByProvider = normalizedSel
        self.normalizePrivateAIModels()

        // Determine initial model list AND set baseURL BEFORE calling updateCurrentProvider
        if let saved = savedProviders.first(where: { $0.id == selectedProviderID }) {
            let key = self.providerKey(for: self.selectedProviderID)
            self.availableModels = self.availableModelsByProvider[key] ?? []
            self.openAIBaseURL = saved.baseURL // Set this FIRST
        } else if ModelRepository.shared.isBuiltIn(self.selectedProviderID) {
            // Handle all built-in providers using ModelRepository
            self.openAIBaseURL = ModelRepository.shared.defaultBaseURL(for: self.selectedProviderID)
            self.availableModels = []
        } else {
            self.openAIBaseURL = ""
            self.availableModels = []
        }

        // NOW update currentProvider after openAIBaseURL is set correctly
        self.updateCurrentProvider()

        // Restore selected model/list for selected provider
        let selectedKey = self.providerKey(for: self.selectedProviderID)
        self.availableModels = self.availableModelsByProvider[selectedKey] ?? []
        self.selectedModel = self.selectedModelByProvider[selectedKey] ?? ""

        self.refreshVerifiedProviders()
        self.selectSoleVerifiedProviderIfNeeded()
        self.connectionStatus = self.connectionStatusByProvider[self.selectedProviderID] ?? .unknown
        self.refreshProviderItems()
        self.syncPromptSelectionForSelectedProvider()

        DebugLogger.shared.debug(
            "loadSettings complete: provider=\(self.selectedProviderID), currentProvider=\(self.currentProvider), model=\(self.selectedModel), baseURL=\(self.openAIBaseURL)",
            source: "AISettingsView"
        )
    }

    // MARK: - Helper Functions

    func providerKey(for providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Built-in providers use their ID directly
        if ModelRepository.shared.isBuiltIn(trimmed) { return trimmed }
        // Custom providers get "custom:" prefix (if not already present)
        if trimmed.hasPrefix("custom:") { return trimmed }
        return "custom:\(trimmed)"
    }

    func providerAPIKey(for providerID: String) -> String {
        let key = self.providerKey(for: providerID)
        return self.providerAPIKeys[key] ?? self.providerAPIKeys[providerID] ?? ""
    }

    func updateProviderAPIKey(_ apiKey: String, for providerID: String, persistEmptyValue: Bool = false) {
        let key = self.providerKey(for: providerID)
        let hadDraft = self.providerAPIKeys[key] != nil || self.providerAPIKeys[providerID] != nil
        self.providerAPIKeys[key] = apiKey
        if key != providerID {
            self.providerAPIKeys.removeValue(forKey: providerID)
        }
        if persistEmptyValue, hadDraft, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = self.saveProviderAPIKeys(invalidating: providerID)
        }
    }

    func providerDisplayName(for providerID: String) -> String {
        if PrivateFeatures.privateAIProvider, providerID == PrivateAIProviderFeature.shared.providerID {
            return ModelRepository.shared.displayName(for: providerID)
        }

        switch providerID {
        case "": return "No Provider"
        case "openai": return "OpenAI"
        case "groq": return "Groq"
        case "apple-intelligence": return "Apple Intelligence"
        default:
            return self.savedProviders.first(where: { $0.id == providerID })?.name ?? providerID.capitalized
        }
    }

    private func normalizePrivateAIModels() {
        guard PrivateFeatures.privateAIProvider else { return }

        let key = self.providerKey(for: PrivateAIProviderFeature.shared.providerID)
        let models = PrivateAIModelRegistry.modelIDs()
        let current = self.selectedModelByProvider[key] ?? ""
        let selected = PrivateAIModelRegistry.model(id: current)?.id ?? PrivateAIIntegrationService.configuredModelID

        self.availableModelsByProvider[key] = models
        self.selectedModelByProvider[key] = selected
        self.settings.availableModelsByProvider = self.availableModelsByProvider
        self.settings.selectedModelByProvider = self.selectedModelByProvider
        UserDefaults.standard.set(selected, forKey: PrivateAIIntegrationService.selectedModelDefaultsKey)
    }

    func connectionStatus(for providerID: String) -> AIConnectionStatus {
        self.connectionStatusByProvider[providerID] ?? .unknown
    }

    func connectionErrorMessage(for providerID: String) -> String {
        self.connectionErrorMessageByProvider[providerID] ?? ""
    }

    // MARK: - Provider Items Cache (for scroll performance)

    /// Refreshes the cached provider items. Call this when providers or connection status changes.
    func refreshProviderItems() {
        // Build the full provider list
        var items: [ProviderItemData] = []
        var seen = Set<String>()

        // Built-in providers list
        let builtInList = ModelRepository.shared.builtInProvidersList(
            includeAppleIntelligence: true,
            appleIntelligenceAvailable: self.appleIntelligenceAvailable
        )

        for provider in builtInList {
            guard !seen.contains(provider.id) else { continue }
            seen.insert(provider.id)
            items.append(ProviderItemData(id: provider.id, name: provider.name, isBuiltIn: true))
        }

        for provider in self.savedProviders {
            guard !seen.contains(provider.id) else { continue }
            seen.insert(provider.id)
            items.append(ProviderItemData(id: provider.id, name: provider.name, isBuiltIn: false))
        }

        self.cachedProviderItems = items
        self.cachedVerifiedProviderItems = items.filter { self.connectionStatus(for: $0.id) == .success }
        self.cachedUnverifiedProviderItems = items.filter { self.connectionStatus(for: $0.id) != .success }
    }

    func updateConnectionStatus(_ status: AIConnectionStatus, for providerID: String) {
        self.connectionStatusByProvider[providerID] = status
        if status != .failed {
            self.clearConnectionError(for: providerID)
        }
        if providerID == self.selectedProviderID {
            self.connectionStatus = status
        }
        // Refresh cached lists when verification status changes
        self.refreshProviderItems()
    }

    private func setConnectionError(_ message: String, for providerID: String) {
        self.connectionErrorMessageByProvider[providerID] = message
        if providerID == self.selectedProviderID {
            self.connectionErrorMessage = message
        }
    }

    private func clearConnectionError(for providerID: String) {
        self.connectionErrorMessageByProvider.removeValue(forKey: providerID)
        if providerID == self.selectedProviderID {
            self.connectionErrorMessage = ""
        }
    }

    func verifyAppleIntelligence() {
        let providerID = "apple-intelligence"
        let key = self.providerKey(for: providerID)
        self.settings.verifiedProviderFingerprints[key] = "apple-intelligence"
        self.updateConnectionStatus(.success, for: providerID)
    }

    func verifyPrivateAIProvider(model: PrivateAIRegisteredModel) async -> Bool {
        let providerID = PrivateAIProviderFeature.shared.providerID
        let key = self.providerKey(for: providerID)
        guard !self.isTestingConnection else { return false }

        self.isTestingConnection = true
        self.updateConnectionStatus(.testing, for: providerID)
        self.connectionErrorMessage = ""

        defer {
            self.isTestingConnection = false
        }

        guard PrivateAIIntegrationService.isModelInstalled(model) else {
            self.updateConnectionStatus(.failed, for: providerID)
            self.connectionErrorMessage = "\(model.displayName) is not installed."
            return false
        }

        do {
            let status = try await PrivateAIIntegrationService.shared.loadModel(model)
            switch status.state {
            case .ready:
                var fingerprints = self.settings.verifiedProviderFingerprints
                fingerprints[key] = self.privateAIFingerprint(for: model.id)
                self.settings.verifiedProviderFingerprints = fingerprints
                self.selectedModelByProvider[key] = model.id
                self.settings.selectedModelByProvider = self.selectedModelByProvider
                self.selectProviderForUse(providerID)
                self.updateConnectionStatus(.success, for: providerID)
                self.connectionErrorMessage = ""
                DebugLogger.shared.info(
                    "Private AI Provider verification succeeded for \(model.id)",
                    source: "AISettingsView"
                )
                return true
            default:
                self.updateConnectionStatus(.failed, for: providerID)
                self.connectionErrorMessage = status.message ?? "\(model.displayName) did not report ready."
                return false
            }
        } catch {
            self.updateConnectionStatus(.failed, for: providerID)
            self.connectionErrorMessage = self.privateAIErrorMessage(for: error)
            DebugLogger.shared.error(
                "Private AI Provider verification failed for \(model.id): \(self.connectionErrorMessage)",
                source: "AISettingsView"
            )
            return false
        }
    }

    func resetVerification(for providerID: String) {
        let key = self.providerKey(for: providerID)
        self.settings.verifiedProviderFingerprints.removeValue(forKey: key)
        self.updateConnectionStatus(.unknown, for: providerID)
        self.refreshProviderItems()
    }

    func isEditingAPIKey(for providerID: String) -> Bool {
        self.editingAPIKeyProviders.contains(self.providerKey(for: providerID))
    }

    func setEditingAPIKey(_ isEditing: Bool, for providerID: String) {
        let key = self.providerKey(for: providerID)
        if isEditing {
            self.editingAPIKeyProviders.insert(key)
        } else {
            self.editingAPIKeyProviders.remove(key)
        }
    }

    func hasFetchedModels(for providerID: String) -> Bool {
        self.fetchedModelsProviders.contains(self.providerKey(for: providerID))
    }

    func selectProvider(_ providerID: String) {
        self.selectProviderForUse(providerID)
        self.setEditingAPIKey(true, for: providerID)
    }

    private func selectProviderForUse(_ providerID: String) {
        self.selectedProviderID = providerID
        self.handleProviderChange(providerID)
        self.connectionStatus = self.connectionStatusByProvider[providerID] ?? .unknown
        self.connectionErrorMessage = self.connectionErrorMessage(for: providerID)
    }

    @discardableResult
    func saveProviderAPIKeys(invalidating providerID: String? = nil) -> Bool {
        let expected = self.sanitizedAPIKeys(self.providerAPIKeys)
        let invalidationTarget = providerID ?? self.selectedProviderID
        do {
            let persisted = try self.settings.saveProviderAPIKeys(self.providerAPIKeys)
            guard persisted == expected else {
                throw ProviderAPIKeySaveError.readbackMismatch
            }
            self.providerAPIKeys = persisted
            self.invalidateVerificationIfNeeded(for: invalidationTarget)
            return true
        } catch {
            self.invalidateVerificationIfNeeded(for: invalidationTarget)
            self.showKeychainPersistenceFailure(error)
            return false
        }
    }

    func createDraftProvider(named name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let draft = SettingsStore.SavedProvider(name: trimmed, baseURL: "", models: [])
        self.savedProviders.append(draft)
        self.saveSavedProviders()

        let key = self.providerKey(for: draft.id)
        self.availableModelsByProvider[key] = []
        self.selectedModelByProvider[key] = ""
        self.settings.availableModelsByProvider = self.availableModelsByProvider
        self.settings.selectedModelByProvider = self.selectedModelByProvider

        self.selectedProviderID = draft.id
        self.openAIBaseURL = ""
        self.updateCurrentProvider()
        self.availableModels = []
        self.selectedModel = ""
        self.updateConnectionStatus(.unknown, for: draft.id)
        self.refreshProviderItems()
        return draft.id
    }

    func updateCustomProviderName(_ name: String, for providerID: String) {
        guard let index = self.savedProviders.firstIndex(where: { $0.id == providerID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = self.savedProviders[index]
        let updated = SettingsStore.SavedProvider(
            id: current.id,
            name: trimmed,
            baseURL: current.baseURL,
            models: current.models
        )
        self.savedProviders[index] = updated
        self.saveSavedProviders()
    }

    func updateCustomProviderBaseURL(_ baseURL: String, for providerID: String) {
        guard let index = self.savedProviders.firstIndex(where: { $0.id == providerID }) else { return }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = self.savedProviders[index]
        let updated = SettingsStore.SavedProvider(
            id: current.id,
            name: current.name,
            baseURL: trimmed,
            models: current.models
        )
        self.savedProviders[index] = updated
        self.saveSavedProviders()

        if providerID == self.selectedProviderID {
            self.openAIBaseURL = trimmed
            self.updateCurrentProvider()
            self.invalidateVerification(for: providerID)
        }
    }

    func updateCurrentProvider() {
        let url = self.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.contains("openai.com") { self.currentProvider = "openai"; return }
        if url.contains("groq.com") { self.currentProvider = "groq"; return }
        self.currentProvider = self.providerKey(for: self.selectedProviderID)
    }

    func saveSavedProviders() {
        self.settings.savedProviders = self.savedProviders
        self.settings.availableModelsByProvider = self.availableModelsByProvider
        self.settings.selectedModelByProvider = self.selectedModelByProvider
        self.settings.selectedProviderID = self.selectedProviderID
        self.refreshProviderItems()
    }

    func isLocalEndpoint(_ urlString: String) -> Bool {
        return ModelRepository.shared.isLocalEndpoint(urlString)
    }

    func hasReasoningConfigForCurrentModel() -> Bool {
        let pKey = self.providerKey(for: self.selectedProviderID)
        if self.settings.hasCustomReasoningConfig(forModel: self.selectedModel, provider: pKey) {
            if let config = self.settings.getReasoningConfig(forModel: selectedModel, provider: pKey) {
                return config.isEnabled
            }
        }
        return self.settings.isReasoningModel(self.selectedModel)
    }

    func addNewModel() {
        guard !self.newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let modelName = self.newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = self.providerKey(for: self.selectedProviderID)

        var list = self.availableModelsByProvider[key] ?? self.availableModels
        if !list.contains(modelName) {
            list.append(modelName)
            self.availableModelsByProvider[key] = list
            self.settings.availableModelsByProvider = self.availableModelsByProvider

            if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
                let updatedProvider = SettingsStore.SavedProvider(
                    id: self.savedProviders[providerIndex].id,
                    name: self.savedProviders[providerIndex].name,
                    baseURL: self.savedProviders[providerIndex].baseURL,
                    models: list
                )
                self.savedProviders[providerIndex] = updatedProvider
                self.saveSavedProviders()
            }

            self.availableModels = list
            self.selectedModel = modelName
            self.selectedModelByProvider[key] = modelName
            self.settings.selectedModelByProvider = self.selectedModelByProvider
        }

        self.showingAddModel = false
        self.newModelName = ""
    }

    // MARK: - Keychain Access Helpers

    private enum KeychainAccessCheckResult {
        case granted
        case denied(OSStatus)
    }

    private enum ProviderAPIKeySaveError: LocalizedError {
        case readbackMismatch

        var errorDescription: String? {
            "Saved API key could not be read back from Keychain."
        }
    }

    func handleAPIKeyButtonTapped() {
        guard self.ensureKeychainAccessForAPIKeyEdit() else { return }
        self.newProviderApiKey = self.providerAPIKey(for: self.selectedProviderID)
        self.showAPIKeyEditor = true
    }

    @discardableResult
    func ensureKeychainAccessForAPIKeyEdit() -> Bool {
        switch self.probeKeychainAccess() {
        case .granted:
            return true
        case let .denied(status):
            self.keychainPermissionMessage = self.keychainPermissionExplanation(for: status)
            self.showKeychainPermissionAlert = true
            return false
        }
    }

    private func probeKeychainAccess() -> KeychainAccessCheckResult {
        let service = "com.fluidvoice.provider-api-keys"
        let account = "fluidApiKeys"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        var readQuery = query
        readQuery[kSecReturnData as String] = kCFBooleanTrue
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, nil)
        switch readStatus {
        case errSecSuccess:
            return .granted
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = (try? JSONEncoder().encode([String: String]())) ?? Data()

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                SecItemDelete(query as CFDictionary)
            }

            switch addStatus {
            case errSecSuccess, errSecDuplicateItem:
                return .granted
            case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
                return .denied(addStatus)
            default:
                return .denied(addStatus)
            }
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            return .denied(readStatus)
        default:
            return .denied(readStatus)
        }
    }

    private func keychainPermissionExplanation(for status: OSStatus) -> String {
        var message = "FluidVoice stores provider API keys securely in your macOS Keychain but does not currently have permission to access it."
        if let detail = SecCopyErrorMessageString(status, nil) as String? {
            message += "\n\nmacOS reported: \(detail) (\(status))"
        }
        message += "\n\nClick \"Always Allow\" when the Keychain prompt appears, or open Keychain Access > login > Passwords, locate the FluidVoice entry, and grant access."
        return message
    }

    private func keychainPersistenceExplanation(for error: Error) -> String {
        var message = "FluidVoice could not save the API key to your macOS Keychain, so this provider was not verified."
        if let keychainError = error as? KeychainServiceError {
            switch keychainError {
            case .invalidData:
                message += "\n\nmacOS returned unreadable Keychain data."
            case let .unhandled(status):
                if let detail = SecCopyErrorMessageString(status, nil) as String? {
                    message += "\n\nmacOS reported: \(detail) (\(status))"
                } else {
                    message += "\n\nmacOS reported Keychain status \(status)."
                }
            }
        } else {
            message += "\n\n\(error.localizedDescription)"
        }
        message += "\n\nClick \"Always Allow\" when the Keychain prompt appears, or open Keychain Access > login > Passwords, locate the FluidVoice entry, and grant access."
        return message
    }

    private func showKeychainPersistenceFailure(_ error: Error) {
        self.keychainPermissionMessage = self.keychainPersistenceExplanation(for: error)
        self.showKeychainPermissionAlert = true
    }

    private func sanitizedAPIKeys(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [String: String]()) { partialResult, pair in
            let sanitizedValue = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sanitizedValue.isEmpty == false else { return }
            partialResult[pair.key] = sanitizedValue
        }
    }

    private func hasProviderAPIKeyDraft(for providerID: String) -> Bool {
        let key = self.providerKey(for: providerID)
        return self.providerAPIKeys[key] != nil || self.providerAPIKeys[providerID] != nil
    }

    func presentKeychainAccessAlert(message: String) {
        let msg = message.isEmpty
            ? "FluidVoice stores provider API keys securely in your macOS Keychain. Please grant access by choosing \"Always Allow\" when prompted."
            : message

        let alert = NSAlert()
        alert.messageText = "Keychain Access Required"
        alert.informativeText = msg
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Keychain Access")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
                NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil
                )
            }
        }
    }

    // MARK: - API Connection Testing

    func testAPIConnection() async {
        guard !self.isTestingConnection else { return }

        let providerID = self.selectedProviderID
        let providerName = ModelRepository.shared.displayName(for: providerID)
        let baseURL = self.providerBaseURL(for: providerID)
        if self.hasProviderAPIKeyDraft(for: providerID), !self.saveProviderAPIKeys(invalidating: providerID) {
            self.updateConnectionStatus(.failed, for: providerID)
            self.setConnectionError("Could not save API key to Keychain. Grant access and try again.", for: providerID)
            return
        }
        let apiKey = self.providerAPIKey(for: providerID)
        let isLocal = self.isLocalEndpoint(baseURL)
        let isAnthropic = providerID == "anthropic" || baseURL.contains("anthropic.com")

        // Validate inputs with specific error messages
        if baseURL.isEmpty {
            await MainActor.run {
                self.updateConnectionStatus(.failed, for: providerID)
                self.setConnectionError("Base URL is required for \(providerName)", for: providerID)
            }
            return
        }

        if !isLocal && apiKey.isEmpty {
            await MainActor.run {
                self.updateConnectionStatus(.failed, for: providerID)
                self.setConnectionError("API key is required for \(providerName). Enter your API key above.", for: providerID)
            }
            return
        }

        let trimmedModel = self.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            await MainActor.run {
                self.updateConnectionStatus(.failed, for: providerID)
                self.setConnectionError("Select a model before verifying. You may need to add a model manually for \(providerName).", for: providerID)
            }
            return
        }
        let usesResponsesAPI = self.shouldVerifyWithResponsesAPI(baseURL: baseURL, model: trimmedModel)

        await MainActor.run {
            self.isTestingConnection = true
            self.updateConnectionStatus(.testing, for: providerID)
        }

        // Build the endpoint URL
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullURL: String

        if usesResponsesAPI {
            if endpoint.contains("/responses") {
                fullURL = endpoint
            } else if endpoint.contains("/chat/completions") {
                fullURL = endpoint.replacingOccurrences(of: "/chat/completions", with: "/responses")
            } else {
                fullURL = endpoint + "/responses"
            }
        } else if isAnthropic {
            // Anthropic uses /messages endpoint, not /chat/completions
            if endpoint.contains("/messages") {
                fullURL = endpoint
            } else {
                fullURL = endpoint + "/messages"
            }
        } else if endpoint.contains("/chat/completions") || endpoint.contains("/api/chat") || endpoint.contains("/api/generate") {
            fullURL = endpoint
        } else {
            fullURL = endpoint + "/chat/completions"
        }

        // Debug logging
        DebugLogger.shared.debug(
            "testAPIConnection: provider=\(providerID), model=\(trimmedModel), baseURL=\(endpoint), fullURL=\(fullURL), isAnthropic=\(isAnthropic), usesResponsesAPI=\(usesResponsesAPI)",
            source: "AISettingsView"
        )

        guard let url = URL(string: fullURL) else {
            await MainActor.run {
                self.updateConnectionStatus(.failed, for: providerID)
                self.setConnectionError("Invalid Base URL format: '\(endpoint)' could not be parsed as a URL", for: providerID)
            }
            return
        }

        // Build the request based on provider type
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        // Set authorization header (different for Anthropic)
        if !apiKey.isEmpty {
            if isAnthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }

        // Build request body (different format for Anthropic)
        let requestDict: [String: Any]
        let provKey = self.providerKey(for: providerID)
        let reasoningConfig = self.settings.getReasoningConfig(forModel: trimmedModel, provider: provKey)

        if usesResponsesAPI {
            var dict: [String: Any] = [
                "model": trimmedModel,
                "input": "test",
                "store": false,
                "max_output_tokens": 50,
            ]

            if let config = reasoningConfig, config.isEnabled {
                if config.parameterName == "reasoning_effort" {
                    dict["reasoning"] = ["effort": config.parameterValue]
                } else if config.parameterName == "enable_thinking" {
                    dict[config.parameterName] = config.parameterValue == "true"
                } else {
                    dict[config.parameterName] = config.parameterValue
                }
            }
            requestDict = dict
        } else if isAnthropic {
            // Anthropic API format
            requestDict = [
                "model": trimmedModel,
                "max_tokens": 10,
                "messages": [["role": "user", "content": "Hi"]],
            ]
        } else {
            // OpenAI-compatible format
            var dict: [String: Any] = [
                "model": trimmedModel,
                "messages": [["role": "user", "content": "test"]],
            ]

            let usesMaxCompletionTokens = self.settings.isReasoningModel(trimmedModel)
            if usesMaxCompletionTokens {
                dict["max_completion_tokens"] = 50
            } else {
                dict["max_tokens"] = 50
            }

            if let config = reasoningConfig, config.isEnabled {
                if config.parameterName == "enable_thinking" {
                    dict[config.parameterName] = config.parameterValue == "true"
                } else {
                    dict[config.parameterName] = config.parameterValue
                }
            }
            requestDict = dict
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestDict, options: []) else {
            await MainActor.run {
                self.updateConnectionStatus(.failed, for: providerID)
                self.setConnectionError("Internal error: Failed to create test request payload", for: providerID)
            }
            return
        }
        request.httpBody = jsonData

        // Make the request
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let statusCode = httpResponse.statusCode

                if statusCode >= 200, statusCode < 300 {
                    await MainActor.run {
                        self.updateConnectionStatus(.success, for: providerID)
                        self.setEditingAPIKey(false, for: providerID)
                        self.storeVerificationFingerprint(for: providerID, baseURL: baseURL, apiKey: apiKey)
                    }
                } else {
                    // Parse error response for more details
                    let errorMessage = self.interpretVerificationError(
                        statusCode: statusCode,
                        responseData: data
                    )
                    DebugLogger.shared.error(
                        "testAPIConnection failed: HTTP \(statusCode) for \(providerID), model=\(trimmedModel)\nError: \(errorMessage)\nResponse: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")",
                        source: "AISettingsView"
                    )
                    await MainActor.run {
                        self.updateConnectionStatus(.failed, for: providerID)
                        self.setConnectionError(errorMessage, for: providerID)
                    }
                }
            } else {
                await MainActor.run {
                    self.updateConnectionStatus(.failed, for: providerID)
                    self.setConnectionError("Unexpected response type from server", for: providerID)
                }
            }
        } catch {
            let errorMessage = self.interpretNetworkError(error, providerID: providerID)
            DebugLogger.shared.error(
                "testAPIConnection network error for \(providerID): \(error.localizedDescription)",
                source: "AISettingsView"
            )
            await MainActor.run {
                self.updateConnectionStatus(.failed, for: providerID)
                self.setConnectionError(errorMessage, for: providerID)
            }
        }

        await MainActor.run {
            self.isTestingConnection = false
        }
    }

    /// Returns the provider's HTTP error body unchanged so setup errors match the real API response.
    private func interpretVerificationError(statusCode: Int, responseData: Data) -> String {
        let responseBody = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let responseBody, !responseBody.isEmpty {
            return "HTTP \(statusCode): \(responseBody)"
        }
        return "HTTP \(statusCode)"
    }

    private func shouldVerifyWithResponsesAPI(baseURL: String, model: String) -> Bool {
        if baseURL.contains("/responses") {
            return true
        }

        guard let url = URL(string: baseURL),
              url.host?.lowercased() == "api.openai.com"
        else { return false }

        let modelLower = model.lowercased()
        return modelLower.hasPrefix("gpt-5") ||
            modelLower.hasPrefix("o1") ||
            modelLower.hasPrefix("o3") ||
            modelLower.hasPrefix("o4")
    }

    /// Interprets network errors with actionable guidance
    private func interpretNetworkError(_ error: Error, providerID: String) -> String {
        let providerName = ModelRepository.shared.displayName(for: providerID)
        let nsError = error as NSError

        switch nsError.code {
        case NSURLErrorTimedOut:
            return "Connection to \(providerName) timed out. Check if the base URL is correct and the service is available."
        case NSURLErrorCannotConnectToHost:
            if providerID == "ollama" || providerID == "lmstudio" {
                return "Cannot connect. Is the \(providerName) server running? Check that the local server is started."
            }
            return "Cannot connect to \(providerName). Check your internet connection and base URL."
        case NSURLErrorNetworkConnectionLost:
            return "Network connection lost while connecting to \(providerName). Check your internet connection."
        case NSURLErrorNotConnectedToInternet:
            return "No internet connection. Connect to the internet to verify \(providerName)."
        case NSURLErrorSecureConnectionFailed:
            return "SSL/TLS error connecting to \(providerName). The server's certificate may be invalid."
        case NSURLErrorCannotFindHost:
            return "Cannot find host. Check if the base URL for \(providerName) is spelled correctly."
        default:
            return "Network error: \(error.localizedDescription)"
        }
    }

    // MARK: - Provider/Model Handling

    func handleProviderChange(_ newValue: String) {
        if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.openAIBaseURL = ""
            self.updateCurrentProvider()
            self.availableModels = []
            self.selectedModel = ""
            return
        }

        // Handle Apple Intelligence specially (no base URL)
        if newValue == "apple-intelligence" {
            self.openAIBaseURL = ""
            self.updateCurrentProvider()
            self.availableModels = ["System Model"]
            self.selectedModel = "System Model"
            return
        }

        // Check if it's a built-in provider
        if ModelRepository.shared.isBuiltIn(newValue) {
            self.openAIBaseURL = ModelRepository.shared.defaultBaseURL(for: newValue)
            self.updateCurrentProvider()
            let key = self.providerKey(for: newValue)
            self.availableModels = self.availableModelsByProvider[key] ?? []
            self.selectedModel = self.selectedModelByProvider[key] ?? ""
            return
        }

        // Handle saved/custom providers
        if let provider = savedProviders.first(where: { $0.id == newValue }) {
            self.openAIBaseURL = provider.baseURL
            self.updateCurrentProvider()
            let key = self.providerKey(for: newValue)
            self.availableModels = self.availableModelsByProvider[key] ?? []
            self.selectedModel = self.selectedModelByProvider[key] ?? ""
        }
    }

    func startEditingProvider() {
        // Handle built-in providers
        if ModelRepository.shared.isBuiltIn(self.selectedProviderID) {
            self.editProviderName = ModelRepository.shared.displayName(for: self.selectedProviderID)
            self.editProviderBaseURL = self.openAIBaseURL // Use current URL (may have been customized)
            self.editProviderApiKey = self.providerAPIKey(for: self.selectedProviderID)
            self.showingEditProvider = true
            return
        }
        // Handle saved/custom providers
        if let provider = savedProviders.first(where: { $0.id == selectedProviderID }) {
            self.editProviderName = provider.name
            self.editProviderBaseURL = provider.baseURL
            self.editProviderApiKey = self.providerAPIKey(for: self.selectedProviderID)
            self.showingEditProvider = true
        }
    }

    func clearEditProviderDraft() {
        self.showingEditProvider = false
        self.editProviderName = ""
        self.editProviderBaseURL = ""
        self.editProviderApiKey = ""
    }

    @discardableResult
    func saveEditedProviderAPIKey() -> Bool {
        let previousAPIKeys = self.providerAPIKeys
        self.updateProviderAPIKey(self.editProviderApiKey, for: self.selectedProviderID)
        guard self.saveProviderAPIKeys(invalidating: self.selectedProviderID) else {
            self.providerAPIKeys = previousAPIKeys
            return false
        }
        return true
    }

    func deleteCurrentProvider() {
        self.savedProviders.removeAll { $0.id == self.selectedProviderID }
        self.saveSavedProviders()
        let key = self.providerKey(for: self.selectedProviderID)
        self.availableModelsByProvider.removeValue(forKey: key)
        self.selectedModelByProvider.removeValue(forKey: key)
        self.providerAPIKeys.removeValue(forKey: key)
        self.saveProviderAPIKeys()
        self.settings.verifiedProviderFingerprints.removeValue(forKey: key)
        self.settings.availableModelsByProvider = self.availableModelsByProvider
        self.settings.selectedModelByProvider = self.selectedModelByProvider
        self.selectedProviderID = ""
        self.openAIBaseURL = ""
        self.updateCurrentProvider()
        self.availableModels = []
        self.selectedModel = ""
        self.refreshVerifiedProviders()
        self.selectSoleVerifiedProviderIfNeeded()
    }

    func saveEditedProvider() {
        let name = self.editProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = self.editProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !base.isEmpty else { return }

        // For built-in providers, we just update the base URL (name is not editable)
        if ModelRepository.shared.isBuiltIn(self.selectedProviderID) {
            self.openAIBaseURL = base
            self.updateCurrentProvider()
            self.clearEditProviderDraft()
            self.invalidateVerification(for: self.selectedProviderID)
            return
        }

        // For saved/custom providers, update the full provider record
        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let oldProvider = self.savedProviders[providerIndex]
            let updatedProvider = SettingsStore.SavedProvider(id: oldProvider.id, name: name, baseURL: base, models: oldProvider.models)
            self.savedProviders[providerIndex] = updatedProvider
            self.saveSavedProviders()
            self.openAIBaseURL = base
            self.updateCurrentProvider()
        }
        self.clearEditProviderDraft()
        self.invalidateVerification(for: self.selectedProviderID)
    }

    func deleteSelectedModel() {
        let key = self.providerKey(for: self.selectedProviderID)
        var list = self.availableModelsByProvider[key] ?? self.availableModels
        list.removeAll { $0 == self.selectedModel }
        if list.isEmpty { list = ModelRepository.shared.defaultModels(for: key) }
        self.availableModelsByProvider[key] = list
        self.settings.availableModelsByProvider = self.availableModelsByProvider

        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let updatedProvider = SettingsStore.SavedProvider(
                id: self.savedProviders[providerIndex].id,
                name: self.savedProviders[providerIndex].name,
                baseURL: self.savedProviders[providerIndex].baseURL,
                models: list
            )
            self.savedProviders[providerIndex] = updatedProvider
            self.saveSavedProviders()
        }

        self.availableModels = list
        self.selectedModel = list.first ?? ""
        self.selectedModelByProvider[key] = self.selectedModel
        self.settings.selectedModelByProvider = self.selectedModelByProvider
    }

    func fetchModelsForCurrentProvider() async {
        self.refreshingProviderID = self.selectedProviderID
        self.isFetchingModels = true
        self.fetchModelsError = nil
        defer {
            self.isFetchingModels = false
            self.refreshingProviderID = nil
        }

        let baseURL = self.openAIBaseURL
        let key = self.providerKey(for: self.selectedProviderID)
        let shouldPersistKey = self.hasProviderAPIKeyDraft(for: self.selectedProviderID)
        if shouldPersistKey, !self.saveProviderAPIKeys(invalidating: self.selectedProviderID) {
            self.fetchModelsError = "Could not save API key to Keychain. Grant access and try again."
            return
        }
        let apiKey = self.providerAPIKey(for: self.selectedProviderID)

        do {
            let models = try await ModelRepository.shared.fetchModels(
                for: self.selectedProviderID,
                baseURL: baseURL,
                apiKey: apiKey
            )

            // Update state on main thread
            await MainActor.run {
                if models.isEmpty {
                    // Keep existing models if fetch returned empty
                    self.fetchModelsError = "No models returned from API"
                } else {
                    self.availableModels = models
                    self.availableModelsByProvider[key] = models
                    self.settings.availableModelsByProvider = self.availableModelsByProvider
                    self.fetchedModelsProviders.insert(key)

                    if let providerIndex = self.savedProviders.firstIndex(where: { $0.id == self.selectedProviderID }) {
                        let updatedProvider = SettingsStore.SavedProvider(
                            id: self.savedProviders[providerIndex].id,
                            name: self.savedProviders[providerIndex].name,
                            baseURL: self.savedProviders[providerIndex].baseURL,
                            models: models
                        )
                        self.savedProviders[providerIndex] = updatedProvider
                        self.saveSavedProviders()
                    }

                    // Select first model if current selection not in list
                    if !models.contains(self.selectedModel) {
                        self.selectedModel = models.first ?? ""
                        self.selectedModelByProvider[key] = self.selectedModel
                        self.settings.selectedModelByProvider = self.selectedModelByProvider
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.fetchModelsError = error.localizedDescription
            }
        }
    }

    func models(for providerID: String) -> [String] {
        let key = self.providerKey(for: providerID)
        if let cached = self.availableModelsByProvider[key], !cached.isEmpty {
            return cached
        }
        if let saved = self.savedProviders.first(where: { $0.id == providerID }), !saved.models.isEmpty {
            return saved.models
        }
        if ModelRepository.shared.isBuiltIn(providerID) {
            return ModelRepository.shared.defaultModels(for: providerID)
        }
        return []
    }

    func selectedModel(for providerID: String) -> String {
        let key = self.providerKey(for: providerID)
        let stored = (self.selectedModelByProvider[key] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        if providerID == self.selectedProviderID {
            return self.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    func selectModel(_ modelName: String, for providerID: String) {
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }

        let key = self.providerKey(for: providerID)
        self.selectedModelByProvider[key] = trimmedModel
        self.settings.selectedModelByProvider = self.selectedModelByProvider

        if providerID == self.selectedProviderID {
            self.availableModels = self.models(for: providerID)
            self.selectedModel = trimmedModel
            self.syncPromptSelectionForSelectedProvider()
        }
    }

    func fetchModels(for providerID: String) async {
        let baseURL = self.providerBaseURL(for: providerID)
        let key = self.providerKey(for: providerID)
        let shouldPersistKey = self.hasProviderAPIKeyDraft(for: providerID)

        self.refreshingProviderID = providerID
        self.isFetchingModels = true
        self.fetchModelsError = nil
        defer {
            self.isFetchingModels = false
            self.refreshingProviderID = nil
        }

        if shouldPersistKey, !self.saveProviderAPIKeys(invalidating: providerID) {
            self.fetchModelsError = "Could not save API key to Keychain. Grant access and try again."
            return
        }

        let apiKey = self.providerAPIKey(for: providerID)

        do {
            let models = try await ModelRepository.shared.fetchModels(
                for: providerID,
                baseURL: baseURL,
                apiKey: apiKey
            )

            await MainActor.run {
                guard !models.isEmpty else {
                    self.fetchModelsError = "No models returned from API"
                    return
                }

                self.availableModelsByProvider[key] = models
                self.settings.availableModelsByProvider = self.availableModelsByProvider
                self.fetchedModelsProviders.insert(key)

                if providerID == self.selectedProviderID {
                    self.availableModels = models
                    if !models.contains(self.selectedModel) {
                        self.selectedModel = models.first ?? ""
                    }
                }

                let selectedForProvider = self.selectedModelByProvider[key] ?? ""
                if !models.contains(selectedForProvider), let first = models.first {
                    self.selectedModelByProvider[key] = first
                    self.settings.selectedModelByProvider = self.selectedModelByProvider
                }

                if let providerIndex = self.savedProviders.firstIndex(where: { $0.id == providerID }) {
                    let updatedProvider = SettingsStore.SavedProvider(
                        id: self.savedProviders[providerIndex].id,
                        name: self.savedProviders[providerIndex].name,
                        baseURL: self.savedProviders[providerIndex].baseURL,
                        models: models
                    )
                    self.savedProviders[providerIndex] = updatedProvider
                    self.saveSavedProviders()
                }
            }
        } catch {
            await MainActor.run {
                self.fetchModelsError = error.localizedDescription
            }
        }
    }

    private func providerBaseURL(for providerID: String) -> String {
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }

        let currentBaseURL = self.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved = self.savedProviders.first(where: { $0.id == providerID }) {
            return saved.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ModelRepository.shared.isBuiltIn(providerID) {
            let defaultBaseURL = ModelRepository.shared.defaultBaseURL(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
            let openAIDefaultURL = ModelRepository.shared.defaultBaseURL(for: "openai").trimmingCharacters(in: .whitespacesAndNewlines)
            if providerID == self.selectedProviderID,
               !currentBaseURL.isEmpty,
               providerID == "openai" || currentBaseURL != openAIDefaultURL
            {
                return currentBaseURL
            }
            return defaultBaseURL
        }
        if providerID == self.selectedProviderID {
            return currentBaseURL
        }
        return ""
    }

    private func fingerprint(baseURL: String, apiKey: String) -> String? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only require baseURL - API key can be empty for local providers (Ollama, LM Studio, etc.)
        guard !trimmedBase.isEmpty else { return nil }
        let input = "\(trimmedBase)|\(trimmedKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func privateAIFingerprint(for modelID: String) -> String {
        PrivateAIProviderFeature.verificationFingerprint(for: modelID)
    }

    private func privateAIErrorMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }
        return String(describing: error)
    }

    private func storeVerificationFingerprint(for providerID: String, baseURL: String, apiKey: String) {
        guard let fingerprint = self.fingerprint(baseURL: baseURL, apiKey: apiKey) else { return }
        let key = self.providerKey(for: providerID)
        var fingerprints = self.settings.verifiedProviderFingerprints
        fingerprints[key] = fingerprint
        self.settings.verifiedProviderFingerprints = fingerprints
        self.updateConnectionStatus(.success, for: providerID)
        self.clearConnectionError(for: providerID)
    }

    private func invalidateVerificationIfNeeded(for providerID: String) {
        let key = self.providerKey(for: providerID)
        guard let stored = self.settings.verifiedProviderFingerprints[key] else { return }
        let baseURL = self.providerBaseURL(for: providerID)
        let apiKey = self.providerAPIKey(for: providerID)
        let current = self.fingerprint(baseURL: baseURL, apiKey: apiKey)
        if current != stored {
            self.settings.verifiedProviderFingerprints.removeValue(forKey: key)
            self.connectionStatusByProvider[providerID] = .unknown
            self.clearConnectionError(for: providerID)
        }
    }

    private func invalidateVerification(for providerID: String) {
        let key = self.providerKey(for: providerID)
        self.settings.verifiedProviderFingerprints.removeValue(forKey: key)
        self.connectionStatusByProvider[providerID] = .unknown
        self.clearConnectionError(for: providerID)
    }

    private func refreshVerifiedProviders() {
        var statuses = self.connectionStatusByProvider
        let providers = ModelRepository.builtInProviderIDs + self.savedProviders.map { $0.id }
        for providerID in providers {
            let key = self.providerKey(for: providerID)
            if providerID == "apple-intelligence" {
                if self.settings.verifiedProviderFingerprints[key] == "apple-intelligence" {
                    statuses[providerID] = .success
                } else if statuses[providerID] == .success {
                    statuses[providerID] = .unknown
                }
                continue
            }
            if providerID == PrivateAIProviderFeature.shared.providerID {
                if PrivateAIProviderPromptFormat.verifiedModelID(settings: self.settings) != nil {
                    statuses[providerID] = .success
                } else if statuses[providerID] == .success {
                    statuses[providerID] = .unknown
                }
                continue
            }
            guard let stored = self.settings.verifiedProviderFingerprints[key] else {
                if statuses[providerID] == .success { statuses[providerID] = .unknown }
                continue
            }
            let baseURL = self.providerBaseURL(for: providerID)
            let apiKey = self.providerAPIKey(for: providerID)
            let current = self.fingerprint(baseURL: baseURL, apiKey: apiKey)
            if current == stored {
                statuses[providerID] = .success
            } else if statuses[providerID] == .success {
                statuses[providerID] = .unknown
            }
        }
        self.connectionStatusByProvider = statuses
        self.connectionStatus = statuses[self.selectedProviderID] ?? .unknown
    }

    /// No-op: never auto-select a provider. The user's selection is sticky.
    /// The per-prompt shortcut system means each shortcut binds independently, so forcing a
    /// global default provider would silently override a user's deliberate "off" or alternate
    /// choice. Only onboarding sets the initial provider.
    private func selectSoleVerifiedProviderIfNeeded() {
        // Intentionally empty. Selection is sticky.
    }

    func openReasoningConfig() {
        let pKey = self.providerKey(for: self.selectedProviderID)
        if let config = self.settings.getReasoningConfig(forModel: selectedModel, provider: pKey) {
            self.editingReasoningParamName = config.parameterName
            self.editingReasoningParamValue = config.parameterValue
            self.editingReasoningEnabled = config.isEnabled
        } else {
            let modelLower = self.selectedModel.lowercased()
            if modelLower.hasPrefix("gpt-5") || modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") || modelLower.contains("gpt-oss") {
                self.editingReasoningParamName = "reasoning_effort"; self.editingReasoningParamValue = "low"; self.editingReasoningEnabled = true
            } else if modelLower.contains("deepseek"), modelLower.contains("reasoner") {
                self.editingReasoningParamName = "enable_thinking"; self.editingReasoningParamValue = "true"; self.editingReasoningEnabled = true
            } else {
                self.editingReasoningParamName = "reasoning_effort"; self.editingReasoningParamValue = "low"; self.editingReasoningEnabled = false
            }
        }
        self.showingReasoningConfig = true
    }

    func saveReasoningConfig() {
        let pKey = self.providerKey(for: self.selectedProviderID)
        if self.editingReasoningEnabled {
            let config = SettingsStore.ModelReasoningConfig(
                parameterName: self.editingReasoningParamName,
                parameterValue: self.editingReasoningParamValue,
                isEnabled: true
            )
            self.settings.setReasoningConfig(config, forModel: self.selectedModel, provider: pKey)
        } else {
            let config = SettingsStore.ModelReasoningConfig(parameterName: "", parameterValue: "", isEnabled: false)
            self.settings.setReasoningConfig(config, forModel: self.selectedModel, provider: pKey)
        }
        self.reasoningConfigVersion += 1 // Trigger view update
        self.showingReasoningConfig = false
    }

    /// Check if reasoning is enabled for a specific provider/model
    func isReasoningEnabled(for providerID: String) -> Bool {
        // Access reasoningConfigVersion to ensure view updates
        _ = self.reasoningConfigVersion

        let pKey = self.providerKey(for: providerID)
        let model = self.selectedModelByProvider[pKey] ?? ""
        guard let config = self.settings.getReasoningConfig(forModel: model, provider: pKey) else {
            return false
        }
        return config.isEnabled
    }

    func saveNewProvider() {
        let name = self.newProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = self.newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let api = self.newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !base.isEmpty else { return }

        let models: [String] = []

        let newProvider = SettingsStore.SavedProvider(name: name, baseURL: base, models: models)
        let key = self.providerKey(for: newProvider.id)
        if !api.isEmpty {
            var updatedAPIKeys = self.providerAPIKeys
            updatedAPIKeys[key] = api
            let previousAPIKeys = self.providerAPIKeys
            self.providerAPIKeys = updatedAPIKeys
            guard self.saveProviderAPIKeys(invalidating: newProvider.id) else {
                self.providerAPIKeys = previousAPIKeys
                return
            }
        }

        self.savedProviders.removeAll { $0.name.lowercased() == name.lowercased() }
        self.savedProviders.append(newProvider)
        self.saveSavedProviders()

        self.availableModelsByProvider[key] = models
        self.selectedModelByProvider[key] = models.first ?? self.selectedModel
        self.settings.availableModelsByProvider = self.availableModelsByProvider
        self.settings.selectedModelByProvider = self.selectedModelByProvider

        self.selectedProviderID = newProvider.id
        self.openAIBaseURL = base
        self.updateCurrentProvider()
        self.availableModels = models
        self.selectedModel = ""

        self.showingSaveProvider = false
        self.newProviderName = ""; self.newProviderBaseURL = ""; self.newProviderApiKey = ""; self.newProviderModels = ""
    }

    // MARK: - Prompt Editor / Test

    func promptPreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty prompt" }
        let singleLine = trimmed.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 120 ? String(singleLine.prefix(120)) + "…" : singleLine
    }

    /// Combine a user-visible body with the hidden base prompt to ensure role/intent is always present.
    func combinedDraftPrompt(_ text: String, mode: SettingsStore.PromptMode) -> String {
        let body = SettingsStore.stripBasePrompt(for: mode, from: text)
        return SettingsStore.combineBasePrompt(for: mode, with: body)
    }

    func requestDeletePrompt(_ profile: SettingsStore.DictationPromptProfile) {
        self.pendingDeletePromptID = profile.id
        self.pendingDeletePromptName = profile.name.isEmpty ? "Untitled Prompt" : profile.name
        self.showingDeletePromptConfirm = true
    }

    func clearPendingDeletePrompt() {
        self.showingDeletePromptConfirm = false
        self.pendingDeletePromptID = nil
        self.pendingDeletePromptName = ""
    }

    func deletePendingPrompt() {
        guard let id = self.pendingDeletePromptID else {
            self.clearPendingDeletePrompt()
            return
        }

        // Remove profile
        var profiles = self.settings.dictationPromptProfiles
        profiles.removeAll { $0.id == id }
        self.settings.dictationPromptProfiles = profiles
        self.settings.reconcilePromptStateAfterProfileChanges()

        // If the deleted profile was active, reset to Default
        if let deleted = self.dictationPromptProfiles.first(where: { $0.id == id }),
           self.settings.selectedPromptID(for: deleted.mode) == id
        {
            self.settings.setSelectedPromptID(nil, for: deleted.mode)
        }

        self.dictationPromptProfiles = self.settings.dictationPromptProfiles
        self.appPromptBindings = self.settings.appPromptBindings
        self.selectedDictationPromptID = self.settings.selectedDictationPromptID
        self.selectedEditPromptID = self.settings.selectedEditPromptID

        NotificationCenter.default.post(name: .dictationPromptShortcutsChanged, object: nil)
        self.clearPendingDeletePrompt()
    }

    func isAIPostProcessingConfiguredForDictation() -> Bool {
        DictationAIPostProcessingGate.isProviderConfigured()
    }

    func openDefaultPromptViewer(for mode: SettingsStore.PromptMode) {
        let normalizedMode = mode.normalized
        self.draftPromptMode = normalizedMode
        self.draftIncludeContext = (normalizedMode == .edit)
        self.draftPromptName = "Default \(normalizedMode.displayName)"
        if let override = self.settings.defaultPromptOverride(for: normalizedMode) {
            self.draftPromptText = SettingsStore.stripBasePrompt(for: normalizedMode, from: override)
        } else {
            self.draftPromptText = SettingsStore.defaultPromptBodyText(for: normalizedMode)
        }
        self.promptEditorSessionID = UUID()
        self.promptEditorMode = .defaultPrompt(mode: normalizedMode)
    }

    func openNewPromptEditor(prefillMode: SettingsStore.PromptMode = .edit) {
        self.draftPromptMode = prefillMode.normalized
        self.draftIncludeContext = (self.draftPromptMode == .edit)
        self.draftPromptName = ""
        self.draftPromptText = ""
        let defaultProviderID = self.defaultVerifiedPromptProviderID()
        let defaultModel = defaultProviderID.isEmpty ? "" : self.selectedModel(for: defaultProviderID)
        self.pendingNewPromptConfiguration = SettingsStore.DictationPromptConfiguration(
            shortcut: nil,
            providerID: defaultProviderID,
            modelName: defaultModel
        )
        self.promptEditorSessionID = UUID()
        self.promptEditorMode = .newPrompt(prefillMode: self.draftPromptMode)
    }

    func openPrivateAIPromptEditor() {
        self.draftPromptMode = .dictate
        self.draftPromptName = PrivateAIProviderFeature.displayName
        self.draftPromptText = ""
        self.promptEditorSessionID = UUID()
        self.promptEditorMode = .privateAI
    }

    func openEditor(for profile: SettingsStore.DictationPromptProfile) {
        self.draftPromptMode = profile.mode.normalized
        self.draftIncludeContext = (self.draftPromptMode == .edit) ? true : profile.includeContext
        self.draftPromptName = profile.name
        self.draftPromptText = SettingsStore.stripBasePrompt(for: self.draftPromptMode, from: profile.prompt)
        self.promptEditorSessionID = UUID()
        self.promptEditorMode = .edit(promptID: profile.id)
    }

    func closePromptEditor() {
        self.promptEditorMode = nil
        self.draftPromptName = ""
        self.draftPromptText = ""
        self.draftPromptMode = .dictate
        self.draftIncludeContext = false
        self.pendingNewPromptConfiguration = nil
        self.promptTest.deactivate()
    }

    func savePromptEditor(mode: PromptEditorMode) {
        if mode.isPrivateAI {
            self.settings.reconcilePromptStateAfterProfileChanges()
            self.dictationPromptProfiles = self.settings.dictationPromptProfiles
            self.appPromptBindings = self.settings.appPromptBindings
            self.closePromptEditor()
            return
        }

        // Default prompt is non-deletable; save it via the optional override (empty is allowed).
        if mode.isDefault {
            let body = SettingsStore.stripBasePrompt(for: self.draftPromptMode, from: self.draftPromptText)
            self.settings.setDefaultPromptOverride(body, for: self.draftPromptMode)
            self.closePromptEditor()
            return
        }

        let name = self.draftPromptName.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptBody = SettingsStore.stripBasePrompt(for: self.draftPromptMode, from: self.draftPromptText)
        let includeContext = (self.draftPromptMode.normalized == .edit) ? true : self.draftIncludeContext

        var profiles = self.settings.dictationPromptProfiles
        let now = Date()

        if let id = mode.editingPromptID,
           let idx = profiles.firstIndex(where: { $0.id == id })
        {
            let previous = profiles[idx]
            var updated = profiles[idx]
            updated.name = name
            updated.prompt = promptBody
            updated.mode = self.draftPromptMode.normalized
            updated.includeContext = includeContext
            updated.updatedAt = now
            profiles[idx] = updated

            if previous.mode != updated.mode,
               self.settings.selectedPromptID(for: previous.mode) == id
            {
                self.settings.setSelectedPromptID(nil, for: previous.mode)
            }
        } else {
            let newProfile = SettingsStore.DictationPromptProfile(
                name: name,
                prompt: promptBody,
                mode: self.draftPromptMode.normalized,
                includeContext: includeContext,
                createdAt: now,
                updatedAt: now
            )
            profiles.append(newProfile)

            if let pendingConfig = self.pendingNewPromptConfiguration,
               self.draftPromptMode.normalized == .dictate
            {
                self.settings.setDictationPromptConfiguration(pendingConfig, for: .profile(newProfile.id))
                if pendingConfig.shortcut != nil {
                    NotificationCenter.default.post(name: .dictationPromptShortcutsChanged, object: nil)
                }
            }
        }

        self.settings.dictationPromptProfiles = profiles
        self.settings.reconcilePromptStateAfterProfileChanges()
        self.dictationPromptProfiles = self.settings.dictationPromptProfiles
        self.appPromptBindings = self.settings.appPromptBindings
        self.selectedDictationPromptID = self.settings.selectedDictationPromptID
        self.selectedEditPromptID = self.settings.selectedEditPromptID
        self.closePromptEditor()
    }

    func appBindings(for mode: SettingsStore.PromptMode) -> [SettingsStore.AppPromptBinding] {
        self.appPromptBindings
            .filter { $0.mode.normalized == mode.normalized }
            .sorted { lhs, rhs in
                if lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) != .orderedSame {
                    return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
                }
                return lhs.appBundleID < rhs.appBundleID
            }
    }

    func appBindingTargets(for mode: SettingsStore.PromptMode) -> [AppBindingTarget] {
        let boundBundleIDs = Set(
            self.appBindings(for: mode)
                .map { self.normalizedBundleID($0.appBundleID) }
        )

        var candidatesByBundleID: [String: AppBindingTarget] = [:]

        if let focusedTarget = self.resolveBindingTargetApp() {
            let normalized = self.normalizedBundleID(focusedTarget.bundleID)
            if !boundBundleIDs.contains(normalized) {
                candidatesByBundleID[normalized] = AppBindingTarget(bundleID: normalized, name: focusedTarget.name)
            }
        }

        for application in NSWorkspace.shared.runningApplications {
            guard let target = self.bindingTarget(from: application) else { continue }
            let normalized = self.normalizedBundleID(target.bundleID)
            guard !boundBundleIDs.contains(normalized) else { continue }
            if candidatesByBundleID[normalized] == nil {
                candidatesByBundleID[normalized] = AppBindingTarget(bundleID: normalized, name: target.name)
            }
        }

        return candidatesByBundleID.values.sorted { lhs, rhs in
            if lhs.name.localizedCaseInsensitiveCompare(rhs.name) != .orderedSame {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.bundleID < rhs.bundleID
        }
    }

    func addAppPromptBinding(for mode: SettingsStore.PromptMode, appBundleID: String, appName: String) {
        let normalizedBundleID = self.normalizedBundleID(appBundleID)
        guard !normalizedBundleID.isEmpty else {
            self.appPromptBindingErrorMessage = "The selected app is missing a valid bundle identifier."
            return
        }

        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? normalizedBundleID : trimmedName
        let existingPromptID = self.settings.appPromptBinding(for: mode, appBundleID: normalizedBundleID)?.promptID
        let resolvedPromptID: String?
        if self.settings.promptRoutingScope(for: mode) == .selectedAppsOnly {
            resolvedPromptID = existingPromptID
        } else {
            resolvedPromptID = existingPromptID ?? self.selectedPromptID(for: mode)
        }

        self.appPromptBindingErrorMessage = ""
        self.settings.upsertAppPromptBinding(
            for: mode.normalized,
            appBundleID: normalizedBundleID,
            appName: resolvedName,
            promptID: resolvedPromptID
        )
        self.appPromptBindings = self.settings.appPromptBindings
    }

    func addCurrentAppPromptBinding(for mode: SettingsStore.PromptMode) {
        guard let target = self.resolveBindingTargetApp() else {
            self.appPromptBindingErrorMessage = "Could not detect a target app. Focus another app window (outside FluidVoice) and try again."
            DebugLogger.shared.info(
                "App prompt binding skipped: unable to resolve non-Fluid target app",
                source: "AISettingsView"
            )
            return
        }
        self.addAppPromptBinding(for: mode, appBundleID: target.bundleID, appName: target.name)
    }

    func addAppPromptBindingFromFilePicker(for mode: SettingsStore.PromptMode) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.message = "Pick an app to add an app-specific prompt override."
        panel.prompt = "Add App"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK, let appURL = panel.url else { return }

        guard let target = self.bindingTarget(fromApplicationURL: appURL) else {
            self.appPromptBindingErrorMessage = "Could not read that app. Please choose a valid .app bundle."
            return
        }

        self.addAppPromptBinding(for: mode, appBundleID: target.bundleID, appName: target.name)
    }

    func removeAppPromptBinding(_ binding: SettingsStore.AppPromptBinding) {
        self.settings.removeAppPromptBinding(id: binding.id)
        self.appPromptBindings = self.settings.appPromptBindings
    }

    func setPromptID(_ promptID: String?, for binding: SettingsStore.AppPromptBinding) {
        self.settings.upsertAppPromptBinding(
            for: binding.mode,
            appBundleID: binding.appBundleID,
            appName: binding.appName,
            promptID: promptID
        )
        self.appPromptBindings = self.settings.appPromptBindings
    }

    func promptName(for mode: SettingsStore.PromptMode, promptID: String?) -> String {
        guard let promptID = promptID,
              let profile = self.dictationPromptProfiles.first(where: {
                  $0.id == promptID &&
                      $0.mode.normalized == mode.normalized
              })
        else {
            return "Built-in Default"
        }

        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Prompt" : trimmed
    }

    func promptRoutingScope(for mode: SettingsStore.PromptMode) -> SettingsStore.PromptRoutingScope {
        self.settings.promptRoutingScope(for: mode)
    }

    func setPromptRoutingScope(_ scope: SettingsStore.PromptRoutingScope, for mode: SettingsStore.PromptMode) {
        self.settings.setPromptRoutingScope(scope, for: mode)
        self.selectedDictationPromptID = self.settings.selectedDictationPromptID
        self.selectedEditPromptID = self.settings.selectedEditPromptID
        self.isDictationPromptOff = self.settings.isDictationPromptOff
        self.isEditPromptOff = self.settings.isEditPromptOff
    }

    func isPrimaryDictationPromptSelectionOff() -> Bool {
        return self.settings.isDictationPromptOff
    }

    func isPromptSelectionOff(for mode: SettingsStore.PromptMode) -> Bool {
        self.settings.isPromptOff(for: mode)
    }

    func isPrivateAIPromptAvailable() -> Bool {
        PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
    }

    func isPrivateAIModelSelected() -> Bool {
        PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
    }

    func isPrivateAIPromptSelected() -> Bool {
        self.settings.dictationPromptSelection == .privateAI
    }

    func dictationPromptSelection(for slot: SettingsStore.DictationShortcutSlot) -> SettingsStore.DictationPromptSelection {
        self.settings.dictationPromptSelection(for: slot)
    }

    func isDictationPromptSelection(
        _ selection: SettingsStore.DictationPromptSelection,
        for slot: SettingsStore.DictationShortcutSlot
    ) -> Bool {
        if slot == .secondary, !self.settings.promptModeShortcutEnabled { return false }
        return self.settings.dictationPromptSelection(for: slot) == selection
    }

    func setDictationPromptSelection(
        _ selection: SettingsStore.DictationPromptSelection,
        for slot: SettingsStore.DictationShortcutSlot
    ) {
        guard selection != .privateAI || self.isPrivateAIPromptAvailable() else { return }
        self.settings.setDictationPromptSelection(selection, for: slot)
        self.refreshPromptSelectionState()
    }

    func setSecondaryDictationPromptSelection(_ selection: SettingsStore.DictationPromptSelection) {
        guard selection != .privateAI || self.isPrivateAIPromptAvailable() else { return }
        self.settings.promptModeShortcutEnabled = true
        self.settings.setDictationPromptSelection(selection, for: .secondary)
        self.refreshPromptSelectionState()
    }

    func secondaryDictationShortcutDisplay() -> String {
        self.settings.promptModeHotkeyShortcut.displayString
    }

    func verifiedPromptProviders() -> [ProviderItemData] {
        self.cachedVerifiedProviderItems.filter { provider in
            provider.id != PrivateAIProviderFeature.shared.providerID
        }
    }

    func defaultVerifiedPromptProviderID() -> String {
        let verified = self.verifiedPromptProviders()
        if verified.contains(where: { $0.id == self.selectedProviderID }) {
            return self.selectedProviderID
        }
        return verified.first?.id ?? ""
    }

    func activeDictationModelSummary(isPrivateAI: Bool = false) -> String {
        if isPrivateAI {
            return PrivateAIProviderFeature.displayName
        }

        let providerID = self.selectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty else { return "Choose provider first" }

        let providerName = self.providerDisplayName(for: providerID)
        let providerKey = self.providerKey(for: providerID)
        let modelName = (self.selectedModelByProvider[providerKey] ?? self.selectedModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else { return providerName }
        return "\(providerName) - \(modelName)"
    }

    func selectPrivateAIPromptIfAvailable() {
        guard self.isPrivateAIPromptAvailable() else { return }
        self.settings.setDictationPromptSelection(.privateAI)
        self.refreshPromptSelectionState()
    }

    /// No-op: never auto-force the dictation prompt selection. The user's choice is sticky.
    /// Each shortcut binds independently; forcing .privateAI when FI is selected would override
    /// a user's deliberate "off" or "default" choice.
    private func syncPromptSelectionForSelectedProvider() {
        // Intentionally empty. Selection is sticky.
    }

    func selectPrimaryDictationPromptOff() {
        self.settings.setDictationPromptSelection(.off)
        self.refreshPromptSelectionState()
    }

    func setPromptSelectionOff(_ isOff: Bool, for mode: SettingsStore.PromptMode) {
        self.settings.setPromptOff(isOff, for: mode)
        self.refreshPromptSelectionState()
    }

    private func refreshPromptSelectionState() {
        self.selectedDictationPromptID = self.settings.selectedDictationPromptID
        self.selectedEditPromptID = self.settings.selectedEditPromptID
        self.isDictationPromptOff = self.settings.isDictationPromptOff
        self.isEditPromptOff = self.settings.isEditPromptOff
    }

    private func resolveBindingTargetApp() -> (name: String, bundleID: String)? {
        if let pid = NotchContentState.shared.recordingTargetPID,
           let app = NSRunningApplication(processIdentifier: pid),
           let target = self.bindingTarget(from: app)
        {
            return target
        }

        if let app = ActiveAppMonitor.shared.activeApp,
           let target = self.bindingTarget(from: app)
        {
            return target
        }

        if let app = NSWorkspace.shared.frontmostApplication,
           let target = self.bindingTarget(from: app)
        {
            return target
        }

        return nil
    }

    private func bindingTarget(from application: NSRunningApplication) -> (name: String, bundleID: String)? {
        guard application.activationPolicy == .regular,
              let bundleID = application.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier
        else {
            return nil
        }

        let normalizedBundleID = self.normalizedBundleID(bundleID)
        guard !normalizedBundleID.isEmpty else { return nil }

        let trimmedName = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName = trimmedName.isEmpty ? normalizedBundleID : trimmedName
        return (name: resolvedName, bundleID: normalizedBundleID)
    }

    private func bindingTarget(fromApplicationURL appURL: URL) -> (name: String, bundleID: String)? {
        guard appURL.pathExtension.lowercased() == "app",
              let appBundle = Bundle(url: appURL),
              let bundleID = appBundle.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier
        else {
            return nil
        }

        let normalizedBundleID = self.normalizedBundleID(bundleID)
        guard !normalizedBundleID.isEmpty else { return nil }

        let displayName = (appBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleName = (appBundle.object(forInfoDictionaryKey: "CFBundleName") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackName = appURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedName = [displayName, bundleName, fallbackName]
            .first(where: { !$0.isEmpty }) ?? normalizedBundleID

        return (name: resolvedName, bundleID: normalizedBundleID)
    }

    private func normalizedBundleID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func selectedPromptID(for mode: SettingsStore.PromptMode) -> String? {
        switch mode.normalized {
        case .dictate:
            return self.selectedDictationPromptID
        case .edit:
            return self.selectedEditPromptID
        case .write, .rewrite:
            return self.selectedEditPromptID
        }
    }

    func setSelectedPromptID(_ id: String?, for mode: SettingsStore.PromptMode) {
        if mode.normalized == .dictate {
            if self.isPrivateAIModelSelected() {
                if id == nil {
                    self.settings.setDictationPromptSelection(.privateAI)
                }
            } else if let id {
                self.settings.setDictationPromptSelection(.profile(id))
            } else {
                self.settings.setDictationPromptSelection(.default)
            }
        } else {
            self.settings.setSelectedPromptID(id, for: mode.normalized)
        }
        self.selectedDictationPromptID = self.settings.selectedDictationPromptID
        self.selectedEditPromptID = self.settings.selectedEditPromptID
        self.isDictationPromptOff = self.settings.isDictationPromptOff
        self.isEditPromptOff = self.settings.isEditPromptOff
    }

    func hasDefaultPromptOverride(for mode: SettingsStore.PromptMode) -> Bool {
        self.settings.defaultPromptOverride(for: mode.normalized) != nil
    }

    func resetDefaultPromptOverride(for mode: SettingsStore.PromptMode) {
        self.settings.setDefaultPromptOverride(nil, for: mode.normalized)
    }

    func defaultPromptBodyPreview(for mode: SettingsStore.PromptMode) -> String {
        if let override = self.settings.defaultPromptOverride(for: mode) {
            return SettingsStore.stripBasePrompt(for: mode, from: override)
        }
        return SettingsStore.defaultPromptBodyText(for: mode)
    }
}
