import AppKit
import Combine
import CryptoKit
import Security
import SwiftUI

@MainActor
final class AIEnhancementSettingsViewModel: ObservableObject {
    let settings: SettingsStore
    let menuBarManager: MenuBarManager
    let promptTest: DictationPromptTestCoordinator

    @Published var appear: Bool = false
    @Published var openAIBaseURL: String
    @Published var enableAIProcessing: Bool {
        didSet {
            guard self.enableAIProcessing != oldValue else { return }
            // Route through MenuBarManager so all UI surfaces (menu, settings, future overlay)
            // share one callable code path.
            self.menuBarManager.setAIProcessingEnabled(self.enableAIProcessing)
        }
    }

    // Model Management
    @Published var availableModelsByProvider: [String: [String]] = [:]
    @Published var selectedModelByProvider: [String: String] = [:]
    @Published var availableModels: [String] = ["gpt-4.1"]
    @Published var selectedModel: String = "gpt-4.1" {
        didSet {
            guard self.selectedModel != "__ADD_MODEL__" else { return }
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
    @Published var currentProvider: String = "openai"
    @Published var savedProviders: [SettingsStore.SavedProvider] = []
    @Published var selectedProviderID: String {
        didSet {
            self.settings.selectedProviderID = self.selectedProviderID
        }
    }

    // Connection Testing
    @Published var isTestingConnection: Bool = false
    @Published var connectionStatus: AIConnectionStatus = .unknown
    @Published var connectionErrorMessage: String = ""
    @Published var connectionStatusByProvider: [String: AIConnectionStatus] = [:]
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

    @Published var cachedProviderItems: [ProviderItemData] = []
    @Published var cachedVerifiedProviderItems: [ProviderItemData] = []
    @Published var cachedUnverifiedProviderItems: [ProviderItemData] = []

    // Dictation Prompt Profiles UI
    @Published var dictationPromptProfiles: [SettingsStore.DictationPromptProfile] = []
    @Published var selectedDictationPromptID: String? = nil
    @Published var selectedEditPromptID: String? = nil
    @Published var promptEditorMode: PromptEditorMode? = nil
    @Published var draftPromptName: String = ""
    @Published var draftPromptText: String = ""
    @Published var draftPromptMode: SettingsStore.PromptMode = .dictate
    @Published var draftIncludeContext: Bool = false
    @Published var promptEditorSessionID: UUID = .init()

    // Prompt Deletion UI
    @Published var showingDeletePromptConfirm: Bool = false
    @Published var pendingDeletePromptID: String? = nil
    @Published var pendingDeletePromptName: String = ""

    init(settings: SettingsStore, menuBarManager: MenuBarManager, promptTest: DictationPromptTestCoordinator) {
        self.settings = settings
        self.menuBarManager = menuBarManager
        self.promptTest = promptTest
        self.openAIBaseURL = ModelRepository.shared.defaultBaseURL(for: "openai")
        self.enableAIProcessing = settings.enableAIProcessing
        self.selectedProviderID = settings.selectedProviderID
    }

    func onAppear() {
        self.appear = true
        self.loadSettings()
    }

    // MARK: - Load Settings

    func loadSettings() {
        self.selectedProviderID = self.settings.selectedProviderID

        self.enableAIProcessing = self.settings.enableAIProcessing
        self.availableModelsByProvider = self.settings.availableModelsByProvider
        self.selectedModelByProvider = self.settings.selectedModelByProvider
        self.appleIntelligenceAvailable = AppleIntelligenceService.isAvailable
        self.providerAPIKeys = self.settings.providerAPIKeys
        self.savedProviders = self.settings.savedProviders
        self.dictationPromptProfiles = self.settings.dictationPromptProfiles
        self.selectedDictationPromptID = self.settings.selectedDictationPromptID
        self.selectedEditPromptID = self.settings.selectedEditPromptID

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
            self.availableModels = []
        }

        // NOW update currentProvider after openAIBaseURL is set correctly
        self.updateCurrentProvider()

        // Restore selected model/list for selected provider
        let selectedKey = self.providerKey(for: self.selectedProviderID)
        self.availableModels = self.availableModelsByProvider[selectedKey] ?? []
        self.selectedModel = self.selectedModelByProvider[selectedKey] ?? ""

        self.connectionStatus = self.connectionStatusByProvider[self.selectedProviderID] ?? .unknown
        self.refreshVerifiedProviders()
        self.refreshProviderItems()

        DebugLogger.shared.debug(
            "loadSettings complete: provider=\(self.selectedProviderID), currentProvider=\(self.currentProvider), model=\(self.selectedModel), baseURL=\(self.openAIBaseURL)",
            source: "AISettingsView"
        )
    }

    // MARK: - Helper Functions

    func providerKey(for providerID: String) -> String {
        // Built-in providers use their ID directly
        if ModelRepository.shared.isBuiltIn(providerID) { return providerID }
        // Custom providers get "custom:" prefix (if not already present)
        if providerID.hasPrefix("custom:") { return providerID }
        return providerID.isEmpty ? self.currentProvider : "custom:\(providerID)"
    }

    func providerDisplayName(for providerID: String) -> String {
        switch providerID {
        case "openai": return "OpenAI"
        case "groq": return "Groq"
        case "apple-intelligence": return "Apple Intelligence"
        default:
            return self.savedProviders.first(where: { $0.id == providerID })?.name ?? providerID.capitalized
        }
    }

    func connectionStatus(for providerID: String) -> AIConnectionStatus {
        self.connectionStatusByProvider[providerID] ?? .unknown
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
        if providerID == self.selectedProviderID {
            self.connectionStatus = status
        }
        // Refresh cached lists when verification status changes
        self.refreshProviderItems()
    }

    func verifyAppleIntelligence() {
        let providerID = "apple-intelligence"
        let key = self.providerKey(for: providerID)
        self.settings.verifiedProviderFingerprints[key] = "apple-intelligence"
        self.updateConnectionStatus(.success, for: providerID)
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
        self.selectedProviderID = providerID
        self.handleProviderChange(providerID)
        self.connectionStatus = self.connectionStatusByProvider[providerID] ?? .unknown
        self.setEditingAPIKey(true, for: providerID)
    }

    func saveProviderAPIKeys() {
        self.settings.providerAPIKeys = self.providerAPIKeys
        self.invalidateVerificationIfNeeded(for: self.selectedProviderID)
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

    func handleAPIKeyButtonTapped() {
        switch self.probeKeychainAccess() {
        case .granted:
            self.newProviderApiKey = self.providerAPIKeys[self.currentProvider] ?? ""
            self.showAPIKeyEditor = true
        case let .denied(status):
            self.keychainPermissionMessage = self.keychainPermissionExplanation(for: status)
            self.showKeychainPermissionAlert = true
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
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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
        let apiKey = self.providerAPIKeys[self.currentProvider] ?? ""
        let baseURL = self.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = self.isLocalEndpoint(baseURL)
        let isAnthropic = providerID == "anthropic" || baseURL.contains("anthropic.com")

        // Validate inputs with specific error messages
        if baseURL.isEmpty {
            await MainActor.run {
                self.updateConnectionStatus(.failed, for: providerID)
                self.connectionErrorMessage = "Base URL is required for \(providerName)"
            }
            return
        }

        if !isLocal && apiKey.isEmpty {
            await MainActor.run {
                self.updateConnectionStatus(.failed, for: providerID)
                self.connectionErrorMessage = "API key is required for \(providerName). Enter your API key above."
            }
            return
        }

        let trimmedModel = self.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            await MainActor.run {
                self.updateConnectionStatus(.failed, for: providerID)
                self.connectionErrorMessage = "Select a model before verifying. You may need to add a model manually for \(providerName)."
            }
            return
        }

        await MainActor.run {
            self.isTestingConnection = true
            self.updateConnectionStatus(.testing, for: providerID)
            self.connectionErrorMessage = ""
        }

        // Build the endpoint URL
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullURL: String

        if isAnthropic {
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
            "testAPIConnection: provider=\(providerID), model=\(trimmedModel), baseURL=\(endpoint), fullURL=\(fullURL), isAnthropic=\(isAnthropic)",
            source: "AISettingsView"
        )

        guard let url = URL(string: fullURL) else {
            await MainActor.run {
                self.updateConnectionStatus(.failed, for: providerID)
                self.connectionErrorMessage = "Invalid Base URL format: '\(endpoint)' could not be parsed as a URL"
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

        if isAnthropic {
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
                self.connectionErrorMessage = "Internal error: Failed to create test request payload"
            }
            return
        }
        request.httpBody = jsonData

        // Make the request
        do {
            let (data, response) = try await URLSession.shared.compatData(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let statusCode = httpResponse.statusCode

                if statusCode >= 200, statusCode < 300 {
                    await MainActor.run {
                        self.updateConnectionStatus(.success, for: providerID)
                        self.connectionErrorMessage = ""
                        self.setEditingAPIKey(false, for: providerID)
                        self.storeVerificationFingerprint(for: providerID, baseURL: baseURL, apiKey: apiKey)
                    }
                } else {
                    // Parse error response for more details
                    let errorMessage = self.interpretVerificationError(
                        statusCode: statusCode,
                        responseData: data,
                        providerID: providerID,
                        model: trimmedModel,
                        endpoint: fullURL
                    )
                    DebugLogger.shared.error(
                        "testAPIConnection failed: HTTP \(statusCode) for \(providerID), model=\(trimmedModel)\nError: \(errorMessage)\nResponse: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")",
                        source: "AISettingsView"
                    )
                    await MainActor.run {
                        self.updateConnectionStatus(.failed, for: providerID)
                        self.connectionErrorMessage = errorMessage
                    }
                }
            } else {
                await MainActor.run {
                    self.updateConnectionStatus(.failed, for: providerID)
                    self.connectionErrorMessage = "Unexpected response type from server"
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
                self.connectionErrorMessage = errorMessage
            }
        }

        await MainActor.run {
            self.isTestingConnection = false
        }
    }

    /// Interprets HTTP error responses with actionable guidance
    private func interpretVerificationError(statusCode: Int, responseData: Data, providerID: String, model: String, endpoint: String) -> String {
        let providerName = ModelRepository.shared.displayName(for: providerID)
        let responseBody = String(data: responseData, encoding: .utf8)?.lowercased() ?? ""

        switch statusCode {
        case 400:
            // Check for specific error patterns in response
            if responseBody.contains("model") {
                return "Invalid model '\(model)' for \(providerName). Check if the model name is correct."
            }
            if responseBody.contains("messages") || responseBody.contains("content") {
                return "Request format error for \(providerName). The API may have changed or the base URL is pointed at a different API."
            }
            return "Bad request (HTTP 400). Check that the base URL '\(endpoint)' is correct for \(providerName)."

        case 401:
            if responseBody.contains("invalid") || responseBody.contains("expired") {
                return "Invalid API key for \(providerName). Please verify your API key is correct and not expired."
            }
            if responseBody.contains("missing") {
                return "API key is missing. Enter your \(providerName) API key above."
            }
            return "Authentication failed (HTTP 401). Your \(providerName) API key may be invalid. Double-check the key."

        case 403:
            if responseBody.contains("permission") || responseBody.contains("access") {
                return "Permission denied. Your \(providerName) API key may not have access to this model."
            }
            if responseBody.contains("region") || responseBody.contains("country") {
                return "Access denied. \(providerName) may not be available in your region."
            }
            return "Forbidden (HTTP 403). Check your \(providerName) account permissions and subscription."

        case 404:
            if responseBody.contains("model") {
                return "Model '\(model)' not found on \(providerName). Check if the model name is spelled correctly."
            }
            return "Endpoint not found (HTTP 404). The base URL '\(endpoint)' may be incorrect for \(providerName)."

        case 422:
            if responseBody.contains("model") {
                return "Model '\(model)' is not valid for \(providerName). Try a different model."
            }
            return "Invalid request parameters for \(providerName). The model or configuration may be incorrect."

        case 429:
            return "Rate limited by \(providerName). Wait a moment and try again."

        case 500, 502, 503:
            return "\(providerName) server error (HTTP \(statusCode)). The service may be temporarily unavailable."

        case 529:
            return "\(providerName) is overloaded. Try again in a few moments."

        default:
            return "HTTP \(statusCode) from \(providerName). Check your API key, base URL, and model configuration."
        }
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
            self.showingEditProvider = true
            return
        }
        // Handle saved/custom providers
        if let provider = savedProviders.first(where: { $0.id == selectedProviderID }) {
            self.editProviderName = provider.name
            self.editProviderBaseURL = provider.baseURL
            self.showingEditProvider = true
        }
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
        // Reset to OpenAI
        self.selectedProviderID = "openai"
        self.openAIBaseURL = ModelRepository.shared.defaultBaseURL(for: "openai")
        self.updateCurrentProvider()
        // Use fetched models if available, fall back to defaults (same logic as handleProviderChange)
        self.availableModels = self.availableModelsByProvider["openai"] ?? ModelRepository.shared.defaultModels(for: "openai")
        self.selectedModel = self.selectedModelByProvider["openai"] ?? self.availableModels.first ?? ""
    }

    func saveEditedProvider() {
        let name = self.editProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = self.editProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !base.isEmpty else { return }

        // For built-in providers, we just update the base URL (name is not editable)
        if ModelRepository.shared.isBuiltIn(self.selectedProviderID) {
            self.openAIBaseURL = base
            self.updateCurrentProvider()
            self.showingEditProvider = false
            self.editProviderName = ""; self.editProviderBaseURL = ""
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
        self.showingEditProvider = false
        self.editProviderName = ""; self.editProviderBaseURL = ""
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
        let apiKey = self.providerAPIKeys[key] ?? self.providerAPIKeys[self.selectedProviderID]

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

    func fetchModels(for providerID: String) async {
        let baseURL = self.providerBaseURL(for: providerID)
        let key = self.providerKey(for: providerID)
        let apiKey = self.providerAPIKeys[key] ?? self.providerAPIKeys[providerID]

        self.refreshingProviderID = providerID
        self.isFetchingModels = true
        self.fetchModelsError = nil
        defer {
            self.isFetchingModels = false
            self.refreshingProviderID = nil
        }

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
        if providerID == self.selectedProviderID {
            return self.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let saved = self.savedProviders.first(where: { $0.id == providerID }) {
            return saved.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ModelRepository.shared.isBuiltIn(providerID) {
            return ModelRepository.shared.defaultBaseURL(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func storeVerificationFingerprint(for providerID: String, baseURL: String, apiKey: String) {
        guard let fingerprint = self.fingerprint(baseURL: baseURL, apiKey: apiKey) else { return }
        let key = self.providerKey(for: providerID)
        var fingerprints = self.settings.verifiedProviderFingerprints
        fingerprints[key] = fingerprint
        self.settings.verifiedProviderFingerprints = fingerprints
        self.connectionStatusByProvider[providerID] = .success
    }

    private func invalidateVerificationIfNeeded(for providerID: String) {
        let key = self.providerKey(for: providerID)
        guard let stored = self.settings.verifiedProviderFingerprints[key] else { return }
        let baseURL = self.providerBaseURL(for: providerID)
        let apiKey = self.providerAPIKeys[key] ?? ""
        let current = self.fingerprint(baseURL: baseURL, apiKey: apiKey)
        if current != stored {
            self.settings.verifiedProviderFingerprints.removeValue(forKey: key)
            self.connectionStatusByProvider[providerID] = .unknown
        }
    }

    private func invalidateVerification(for providerID: String) {
        let key = self.providerKey(for: providerID)
        self.settings.verifiedProviderFingerprints.removeValue(forKey: key)
        self.connectionStatusByProvider[providerID] = .unknown
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
            guard let stored = self.settings.verifiedProviderFingerprints[key] else {
                if statuses[providerID] == .success { statuses[providerID] = .unknown }
                continue
            }
            let baseURL = self.providerBaseURL(for: providerID)
            let apiKey = self.providerAPIKeys[key] ?? ""
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
        self.savedProviders.removeAll { $0.name.lowercased() == name.lowercased() }
        self.savedProviders.append(newProvider)
        self.saveSavedProviders()

        let key = self.providerKey(for: newProvider.id)
        self.providerAPIKeys[key] = api
        self.availableModelsByProvider[key] = models
        self.selectedModelByProvider[key] = models.first ?? self.selectedModel
        self.settings.providerAPIKeys = self.providerAPIKeys
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

        // If the deleted profile was active, reset to Default
        if let deleted = self.dictationPromptProfiles.first(where: { $0.id == id }),
           self.settings.selectedPromptID(for: deleted.mode) == id
        {
            self.settings.setSelectedPromptID(nil, for: deleted.mode)
        }

        self.dictationPromptProfiles = profiles
        self.selectedDictationPromptID = self.settings.selectedDictationPromptID
        self.selectedEditPromptID = self.settings.selectedEditPromptID

        self.clearPendingDeletePrompt()
    }

    func isAIPostProcessingConfiguredForDictation() -> Bool {
        DictationAIPostProcessingGate.isConfigured()
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
        self.draftPromptName = "New Prompt"
        self.draftPromptText = ""
        self.promptEditorSessionID = UUID()
        self.promptEditorMode = .newPrompt(prefillMode: self.draftPromptMode)
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
        self.promptTest.deactivate()
    }

    func savePromptEditor(mode: PromptEditorMode) {
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
        }

        self.settings.dictationPromptProfiles = profiles
        self.dictationPromptProfiles = profiles
        self.selectedDictationPromptID = self.settings.selectedDictationPromptID
        self.selectedEditPromptID = self.settings.selectedEditPromptID
        self.closePromptEditor()
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
        self.settings.setSelectedPromptID(id, for: mode.normalized)
        self.selectedDictationPromptID = self.settings.selectedDictationPromptID
        self.selectedEditPromptID = self.settings.selectedEditPromptID
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
