//
//  AISettingsView.swift
//  fluid
//
//  Extracted from ContentView.swift to reduce monolithic architecture.
//  Created: 2025-12-14
//

import AppKit
import Security
import SwiftUI

// MARK: - Connection Status Enum

enum AIConnectionStatus {
    case unknown, testing, success, failed
}

struct AISettingsView: View {
    @EnvironmentObject private var appServices: AppServices
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @Environment(\.theme) private var theme

    private var asr: ASRService { self.appServices.asr }

    // MARK: - State Variables (moved from ContentView)

    @State private var appear = false
    @State private var openAIBaseURL: String = "https://api.openai.com/v1"
    @State private var enableAIProcessing: Bool = false

    // Model Management
    @State private var availableModelsByProvider: [String: [String]] = [:]
    @State private var selectedModelByProvider: [String: String] = [:]
    @State private var availableModels: [String] = ["gpt-4.1"]
    @State private var selectedModel: String = "gpt-4.1"
    @State private var showingAddModel: Bool = false
    @State private var newModelName: String = ""

    // Reasoning Configuration
    @State private var showingReasoningConfig: Bool = false
    @State private var editingReasoningParamName: String = "reasoning_effort"
    @State private var editingReasoningParamValue: String = "low"
    @State private var editingReasoningEnabled: Bool = false

    // Provider Management
    @State private var providerAPIKeys: [String: String] = [:]
    @State private var currentProvider: String = "openai"
    @State private var savedProviders: [SettingsStore.SavedProvider] = []
    @State private var selectedProviderID: String = SettingsStore.shared.selectedProviderID

    // Connection Testing
    @State private var isTestingConnection: Bool = false
    @State private var connectionStatus: AIConnectionStatus = .unknown
    @State private var connectionErrorMessage: String = ""

    // UI State
    @State private var showHelp: Bool = false
    @State private var showingSaveProvider: Bool = false
    @State private var showAPIKeyEditor: Bool = false
    @State private var showAPIKeysGuide: Bool = false
    @State private var showingEditProvider: Bool = false

    // Provider Form State
    @State private var newProviderName: String = ""
    @State private var newProviderBaseURL: String = ""
    @State private var newProviderApiKey: String = ""
    @State private var newProviderModels: String = ""
    @State private var editProviderName: String = ""
    @State private var editProviderBaseURL: String = ""

    // Keychain State
    @State private var showKeychainPermissionAlert: Bool = false
    @State private var keychainPermissionMessage: String = ""

    // Filler Words State - local state to ensure UI reactivity
    @State private var removeFillerWordsEnabled: Bool = SettingsStore.shared.removeFillerWordsEnabled

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                self.speechRecognitionCard
                self.aiConfigurationCard
            }
            .padding(14)
        }
        .onAppear {
            self.appear = true
            self.loadSettings()

            // CRITICAL FIX: Refresh model status immediately on appear
            // This ensures the speech recognition card shows current download status
            // Use async variant for accurate detection (especially for AppleSpeechAnalyzerProvider)
            Task {
                await self.asr.checkIfModelsExistAsync()
            }
        }
        .onChange(of: self.enableAIProcessing) { _, newValue in
            SettingsStore.shared.enableAIProcessing = newValue
            // Keep menu bar UI in sync when toggled from this screen
            self.menuBarManager.aiProcessingEnabled = newValue
        }
        .onChange(of: self.selectedModel) { _, newValue in
            if newValue != "__ADD_MODEL__" {
                self.selectedModelByProvider[self.currentProvider] = newValue
                SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider
            }
        }
        .onChange(of: self.selectedProviderID) { _, newValue in
            SettingsStore.shared.selectedProviderID = newValue
        }
        .onChange(of: self.showKeychainPermissionAlert) { _, isPresented in
            guard isPresented else { return }
            self.presentKeychainAccessAlert(message: self.keychainPermissionMessage)
            self.showKeychainPermissionAlert = false
        }
    }

    // MARK: - Load Settings

    private func loadSettings() {
        self.selectedProviderID = SettingsStore.shared.selectedProviderID

        self.enableAIProcessing = SettingsStore.shared.enableAIProcessing
        self.availableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        self.selectedModelByProvider = SettingsStore.shared.selectedModelByProvider
        self.providerAPIKeys = SettingsStore.shared.providerAPIKeys
        self.savedProviders = SettingsStore.shared.savedProviders

        // Normalize provider keys
        var normalized: [String: [String]] = [:]
        for (key, models) in self.availableModelsByProvider {
            let lower = key.lowercased()
            let newKey: String
            if lower == "openai" || lower == "groq" {
                newKey = lower
            } else {
                newKey = key.hasPrefix("custom:") ? key : "custom:\(key)"
            }
            let clean = Array(Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
            if !clean.isEmpty { normalized[newKey] = clean }
        }
        self.availableModelsByProvider = normalized
        SettingsStore.shared.availableModelsByProvider = normalized

        // Normalize selected model by provider
        var normalizedSel: [String: String] = [:]
        for (key, model) in self.selectedModelByProvider {
            let lower = key.lowercased()
            let newKey: String = (lower == "openai" || lower == "groq") ? lower :
                (key.hasPrefix("custom:") ? key : "custom:\(key)")
            if let list = normalized[newKey], list.contains(model) { normalizedSel[newKey] = model }
        }
        self.selectedModelByProvider = normalizedSel
        SettingsStore.shared.selectedModelByProvider = normalizedSel

        // Determine initial model list AND set baseURL BEFORE calling updateCurrentProvider
        if let saved = savedProviders.first(where: { $0.id == selectedProviderID }) {
            self.availableModels = saved.models
            self.openAIBaseURL = saved.baseURL // Set this FIRST
        } else if self.selectedProviderID == "openai" {
            self.openAIBaseURL = "https://api.openai.com/v1"
            self.availableModels = self.availableModelsByProvider["openai"] ?? self.defaultModels(for: "openai")
        } else if self.selectedProviderID == "groq" {
            self.openAIBaseURL = "https://api.groq.com/openai/v1"
            self.availableModels = self.availableModelsByProvider["groq"] ?? self.defaultModels(for: "groq")
        } else {
            self.availableModels = self.defaultModels(for: self.providerKey(for: self.selectedProviderID))
        }

        // NOW update currentProvider after openAIBaseURL is set correctly
        self.updateCurrentProvider()

        // Restore selected model using the correct currentProvider
        if let sel = selectedModelByProvider[currentProvider], availableModels.contains(sel) {
            self.selectedModel = sel
        } else if let first = availableModels.first {
            self.selectedModel = first
        }

        DebugLogger.shared.debug("loadSettings complete: provider=\(self.selectedProviderID), currentProvider=\(self.currentProvider), model=\(self.selectedModel), baseURL=\(self.openAIBaseURL)", source: "AISettingsView")
    }

    // MARK: - Speech Recognition Card

    private var speechRecognitionCard: some View {
        ThemedCard(hoverEffect: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "brain.head.profile")
                        .font(.title2)
                        .foregroundStyle(.white)
                    Text("Speech Recognition")
                        .font(.title3)
                        .fontWeight(.semibold)
                }

                VStack(alignment: .leading, spacing: 10) {
                    // Single unified model picker
                    HStack(spacing: 12) {
                        Text("Model")
                            .fontWeight(.medium)
                        Spacer()
                        Menu(SettingsStore.shared.selectedSpeechModel.displayName) {
                            ForEach(SettingsStore.SpeechModel.availableModels) { model in
                                Button {
                                    SettingsStore.shared.selectedSpeechModel = model
                                    self.asr.resetTranscriptionProvider()
                                } label: {
                                    HStack {
                                        Text(model.displayName)
                                        Spacer()
                                        Text("\(model.languageSupport) • \(model.downloadSize)")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .disabled(self.asr.isRunning)
                    }

                    // Model info badges
                    HStack(spacing: 8) {
                        Label(SettingsStore.shared.selectedSpeechModel.languageSupport, systemImage: "globe")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))

                        Label(SettingsStore.shared.selectedSpeechModel.downloadSize, systemImage: "arrow.down.circle")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))

                        Spacer()

                        if !SettingsStore.shared.selectedSpeechModel.isWhisperModel {
                            Text("Apple Silicon")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(self.theme.palette.accent.opacity(0.2)))
                        }
                    }

                    // Model status indicator
                    self.modelStatusView

                    // Performance note
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(self.theme.palette.accent)
                            .font(.caption)
                        Text(self.modelDescriptionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial.opacity(0.3)))

                    Divider().padding(.vertical, 4)

                    // Filler Words Section
                    self.fillerWordsSection
                }
            }
            .padding(14)
        }
    }

    /// Returns the appropriate description text for the currently selected speech model
    private var modelDescriptionText: String {
        let model = SettingsStore.shared.selectedSpeechModel
        switch model {
        case .appleSpeech:
            return "Apple Speech (Legacy) uses on-device recognition. No download required, works on Intel and Apple Silicon."
        case .appleSpeechAnalyzer:
            return "Apple Speech uses advanced on-device recognition with fast, accurate transcription. Requires macOS 26+."
        case .parakeetTDT:
            return "Parakeet TDT uses CoreML and Neural Engine for fastest transcription (25 languages) on Apple Silicon."
        default:
            return "Whisper models support 99 languages and work on any Mac."
        }
    }

    private var modelStatusView: some View {
        HStack(spacing: 12) {
            if self.asr.isDownloadingModel || self.asr.isLoadingModel {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(self.asr.isLoadingModel ? "Loading model…" : "Downloading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if self.asr.isAsrReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Text("Ready").font(.caption).foregroundStyle(.secondary)

                Button(action: { Task { await self.deleteModels() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else if self.asr.modelsExistOnDisk {
                Image(systemName: "doc.fill").foregroundStyle(self.theme.palette.accent).font(.caption)
                Text("Cached").font(.caption).foregroundStyle(.secondary)

                Button(action: { Task { await self.deleteModels() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "arrow.down.circle").foregroundStyle(.orange).font(.caption)

                Button(action: { Task { await self.downloadModels() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download")
                    }
                    .font(.caption)
                    .foregroundStyle(self.theme.palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(.ultraThinMaterial.opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1), lineWidth: 1)))
    }

    private var fillerWordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remove Filler Words").font(.body)
                    Text("Automatically remove filler sounds like 'um', 'uh', 'er' from transcriptions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: self.$removeFillerWordsEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: self.removeFillerWordsEnabled) { _, newValue in
                        SettingsStore.shared.removeFillerWordsEnabled = newValue
                    }
            }

            if self.removeFillerWordsEnabled {
                FillerWordsEditor()
            }
        }
    }

    // MARK: - Model Download/Delete

    private func downloadModels() async {
        do {
            try await self.asr.ensureAsrReady()
        } catch {
            DebugLogger.shared.error("Failed to download models: \(error)", source: "AISettingsView")
        }
    }

    private func deleteModels() async {
        do {
            try await self.asr.clearModelCache()
        } catch {
            DebugLogger.shared.error("Failed to delete models: \(error)", source: "AISettingsView")
        }
    }

    // MARK: - Helper Functions

    private func providerKey(for providerID: String) -> String {
        if providerID == "openai" || providerID == "groq" { return providerID }
        return providerID.isEmpty ? self.currentProvider : "custom:\(providerID)"
    }

    private func providerDisplayName(for providerID: String) -> String {
        switch providerID {
        case "openai": return "OpenAI"
        case "groq": return "Groq"
        case "apple-intelligence": return "Apple Intelligence"
        default:
            return self.savedProviders.first(where: { $0.id == providerID })?.name ?? providerID.capitalized
        }
    }

    private func defaultModels(for providerKey: String) -> [String] {
        switch providerKey {
        case "openai": return ["gpt-4.1"]
        case "groq": return ["openai/gpt-oss-120b"]
        default: return []
        }
    }

    private func saveProviderAPIKeys() {
        SettingsStore.shared.providerAPIKeys = self.providerAPIKeys
    }

    private func updateCurrentProvider() {
        let url = self.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.contains("openai.com") { self.currentProvider = "openai"; return }
        if url.contains("groq.com") { self.currentProvider = "groq"; return }
        self.currentProvider = self.providerKey(for: self.selectedProviderID)
    }

    private func saveSavedProviders() {
        SettingsStore.shared.savedProviders = self.savedProviders
    }

    private func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host else { return false }
        let hostLower = host.lowercased()
        if hostLower == "localhost" || hostLower == "127.0.0.1" { return true }
        if hostLower.hasPrefix("127.") || hostLower.hasPrefix("10.") || hostLower.hasPrefix("192.168.") { return true }
        if hostLower.hasPrefix("172.") {
            let components = hostLower.split(separator: ".")
            if components.count >= 2, let secondOctet = Int(components[1]), secondOctet >= 16 && secondOctet <= 31 {
                return true
            }
        }
        return false
    }

    private func hasReasoningConfigForCurrentModel() -> Bool {
        let pKey = self.providerKey(for: self.selectedProviderID)
        if SettingsStore.shared.hasCustomReasoningConfig(forModel: self.selectedModel, provider: pKey) {
            if let config = SettingsStore.shared.getReasoningConfig(forModel: selectedModel, provider: pKey) {
                return config.isEnabled
            }
        }
        return SettingsStore.shared.isReasoningModel(self.selectedModel)
    }

    private func addNewModel() {
        guard !self.newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let modelName = self.newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = self.providerKey(for: self.selectedProviderID)

        var list = self.availableModelsByProvider[key] ?? self.availableModels
        if !list.contains(modelName) {
            list.append(modelName)
            self.availableModelsByProvider[key] = list
            SettingsStore.shared.availableModelsByProvider = self.availableModelsByProvider

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
            SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider
        }

        self.showingAddModel = false
        self.newModelName = ""
    }

    // MARK: - Keychain Access Helpers

    private enum KeychainAccessCheckResult {
        case granted
        case denied(OSStatus)
    }

    private func handleAPIKeyButtonTapped() {
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

    @MainActor
    private func presentKeychainAccessAlert(message: String) {
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

    private func testAPIConnection() async {
        guard !self.isTestingConnection else { return }

        let apiKey = self.providerAPIKeys[self.currentProvider] ?? ""
        let baseURL = self.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = self.isLocalEndpoint(baseURL)

        if isLocal {
            guard !baseURL.isEmpty else {
                await MainActor.run {
                    self.connectionStatus = .failed
                    self.connectionErrorMessage = "Base URL is required"
                }
                return
            }
        } else {
            guard !apiKey.isEmpty, !baseURL.isEmpty else {
                await MainActor.run {
                    self.connectionStatus = .failed
                    self.connectionErrorMessage = "API key and base URL are required"
                }
                return
            }
        }

        await MainActor.run {
            self.isTestingConnection = true
            self.connectionStatus = .testing
            self.connectionErrorMessage = ""
        }

        do {
            let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let fullURL: String
            if endpoint.contains("/chat/completions") || endpoint.contains("/api/chat") || endpoint
                .contains("/api/generate")
            {
                fullURL = endpoint
            } else {
                fullURL = endpoint + "/chat/completions"
            }

            // Debug logging to diagnose test failures
            DebugLogger.shared.debug("testAPIConnection: provider=\(self.selectedProviderID), model=\(self.selectedModel), baseURL=\(endpoint), fullURL=\(fullURL)", source: "AISettingsView")

            guard let url = URL(string: fullURL) else {
                await MainActor.run {
                    self.connectionStatus = .failed
                    self.connectionErrorMessage = "Invalid Base URL format"
                }
                return
            }

            let provKey = self.providerKey(for: self.selectedProviderID)
            let reasoningConfig = SettingsStore.shared.getReasoningConfig(forModel: self.selectedModel, provider: provKey)

            let usesMaxCompletionTokens = SettingsStore.shared.isReasoningModel(self.selectedModel)

            var requestDict: [String: Any] = [
                "model": selectedModel,
                "messages": [["role": "user", "content": "test"]],
            ]

            if usesMaxCompletionTokens {
                requestDict["max_completion_tokens"] = 50
            } else {
                requestDict["max_tokens"] = 50
            }

            if let config = reasoningConfig, config.isEnabled {
                if config.parameterName == "enable_thinking" {
                    requestDict[config.parameterName] = config.parameterValue == "true"
                } else {
                    requestDict[config.parameterName] = config.parameterValue
                }
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: requestDict, options: []) else {
                await MainActor.run {
                    self.connectionStatus = .failed
                    self.connectionErrorMessage = "Failed to encode test request"
                }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30

            if !isLocal {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            request.httpBody = jsonData

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if (200...299).contains(httpResponse.statusCode) {
                    await MainActor.run {
                        self.connectionStatus = .success
                        self.connectionErrorMessage = ""
                    }
                } else {
                    var errorMessage = "HTTP \(httpResponse.statusCode)"

                    if let responseBody = String(data: data, encoding: .utf8),
                       let jsonData = responseBody.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
                    {
                        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                            errorMessage = message
                        } else if let message = json["message"] as? String {
                            errorMessage = message
                        }
                    }

                    await MainActor.run {
                        self.connectionStatus = .failed
                        self.connectionErrorMessage = errorMessage
                    }
                }
            }
        } catch let urlError as URLError {
            var errorMessage: String
            switch urlError.code {
            case .timedOut: errorMessage = "Request timed out - server not responding"
            case .cannotConnectToHost: errorMessage = "Cannot connect to host - check URL"
            case .notConnectedToInternet: errorMessage = "No internet connection"
            default: errorMessage = urlError.localizedDescription
            }

            await MainActor.run {
                connectionStatus = .failed
                connectionErrorMessage = errorMessage
            }
        } catch {
            await MainActor.run {
                self.connectionStatus = .failed
                self.connectionErrorMessage = error.localizedDescription
            }
        }

        await MainActor.run {
            self.isTestingConnection = false
        }
    }

    // MARK: - AI Configuration Card

    private var aiConfigurationCard: some View {
        VStack(spacing: 14) {
            ThemedCard(style: .prominent, hoverEffect: false) {
                VStack(alignment: .leading, spacing: 12) {
                    // Header
                    HStack {
                        Image(systemName: "key.fill")
                            .font(.title3)
                            .foregroundStyle(self.theme.palette.accent)
                        Text("API Configuration")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: { self.showHelp.toggle() }) {
                            Image(systemName: self.showHelp ? "questionmark.circle.fill" : "questionmark.circle")
                                .font(.system(size: 20))
                                .foregroundStyle(self.theme.palette.accent.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().padding(.vertical, 3)

                    // AI Enhancement Toggle
                    self.aiEnhancementToggle

                    // Streaming Toggle
                    if self.enableAIProcessing && self.selectedProviderID != "apple-intelligence" {
                        self.streamingToggle
                        self.showThinkingTokensToggle
                    }

                    // API Key Warning
                    if self.enableAIProcessing && self.selectedProviderID != "apple-intelligence" &&
                        !self.isLocalEndpoint(self.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) &&
                        (self.providerAPIKeys[self.currentProvider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        self.apiKeyWarningView
                    }

                    // Help Section
                    if self.showHelp { self.helpSectionView }

                    Divider().padding(.vertical, 3)

                    // Provider/Model Configuration
                    self.providerConfigurationSection
                }
                .padding(14)
            }
            .modifier(CardAppearAnimation(delay: 0.1, appear: self.$appear))

            // API Keys Guide
            self.apiKeysGuideCard
        }
    }

    private var aiEnhancementToggle: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable AI Enhancement")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(self.theme.palette.primaryText)
                Text("Automatically enhance transcriptions with AI")
                    .font(.system(size: 13))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Spacer()
            Toggle("", isOn: self.$enableAIProcessing)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 4)
    }

    private var streamingToggle: some View {
        Group {
            Divider().padding(.vertical, 3)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enable Streaming")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text("Currently only Command Mode shows real-time streaming")
                        .font(.system(size: 13))
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { SettingsStore.shared.enableAIStreaming },
                    set: { SettingsStore.shared.enableAIStreaming = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.horizontal, 4)
        }
    }

    private var showThinkingTokensToggle: some View {
        Group {
            Divider().padding(.vertical, 3)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show Thinking Tokens")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(self.theme.palette.primaryText)
                    Text("Display AI reasoning in Command and Rewrite modes (when available)")
                        .font(.system(size: 13))
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { SettingsStore.shared.showThinkingTokens },
                    set: { SettingsStore.shared.showThinkingTokens = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.horizontal, 4)
        }
    }

    private var apiKeyWarningView: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            Text("API key required for AI enhancement to work")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 4)
    }

    private var helpSectionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                Text("Quick Start Guide").font(.subheadline).fontWeight(.semibold)
            }
            VStack(alignment: .leading, spacing: 6) {
                self.helpStep("1", "Enable AI enhancement if needed")
                self.helpStep("2", "Add/choose any provider of your choice along with its API key")
                self.helpStep("3", "Add/choose any good model of your liking")
                self.helpStep("4", "If it's OpenAI compatible endpoint, then update the base URL")
                self.helpStep("5", "Once everything is set, click verify to check if the connection works")
            }
        }
        .padding(14)
        .background(self.theme.palette.accent.opacity(0.08))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(self.theme.palette.accent.opacity(0.2), lineWidth: 1))
        .padding(.horizontal, 4)
        .transition(.opacity)
    }

    private func helpStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption).fontWeight(.semibold).frame(width: 16, alignment: .trailing)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var providerConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Compatibility note
            if self.selectedProviderID == "apple-intelligence" {
                HStack(spacing: 6) {
                    Image(systemName: "apple.logo").font(.caption2).foregroundStyle(self.theme.palette.accent)
                    Text("Powered by on-device Apple Intelligence").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(self.theme.palette.accent)
                    Text("Supports any OpenAI compatible API endpoints").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }

            Divider()

            self.providerPickerRow

            if self.showingEditProvider { self.editProviderSection }

            if self.selectedProviderID == "apple-intelligence" { self.appleIntelligenceBadge }

            // API Key Management
            if self.selectedProviderID != "apple-intelligence" {
                Divider()
                Button(action: { self.handleAPIKeyButtonTapped() }) {
                    Label("Add or Modify API Key", systemImage: "key.fill")
                        .labelStyle(.titleAndIcon).font(.caption)
                }
                .buttonStyle(GlassButtonStyle())
            }

            Divider()

            // Model Row
            if self.selectedProviderID == "apple-intelligence" {
                self.appleIntelligenceModelRow
            } else {
                self.standardModelRow
                if self.showingAddModel { self.addModelSection }
                if self.showingReasoningConfig { self.reasoningConfigSection }
            }

            Divider()

            // Connection Test
            if self.selectedProviderID != "apple-intelligence" {
                self.connectionTestSection
                if self.showingSaveProvider { self.addProviderSection }
            }
        }
        .padding(.horizontal, 4)
    }

    private var providerPickerRow: some View {
        HStack(spacing: 12) {
            HStack {
                Text("Provider:").fontWeight(.medium)
            }
            .frame(width: 90, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(LinearGradient(colors: [self.theme.palette.accent.opacity(0.15), self.theme.palette.accent.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
            .cornerRadius(6)

            Picker("", selection: self.$selectedProviderID) {
                Text("OpenAI").tag("openai")
                Text("Groq").tag("groq")
                if AppleIntelligenceService.isAvailable {
                    Text("Apple Intelligence").tag("apple-intelligence")
                }
                if !self.savedProviders.isEmpty {
                    Divider()
                    ForEach(self.savedProviders) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 200)
            .onChange(of: self.selectedProviderID) { _, newValue in
                self.handleProviderChange(newValue)
            }

            // Edit/Delete buttons for custom providers
            if !["openai", "groq", "apple-intelligence"].contains(self.selectedProviderID) {
                Button(action: { self.startEditingProvider() }) {
                    HStack(spacing: 4) { Image(systemName: "pencil"); Text("Edit") }.font(.caption)
                }
                .buttonStyle(CompactButtonStyle())

                Button(action: { self.deleteCurrentProvider() }) {
                    HStack(spacing: 4) { Image(systemName: "trash"); Text("Delete") }.font(.caption).foregroundStyle(.red)
                }
                .buttonStyle(CompactButtonStyle())
            }

            Button("+ Add Provider") {
                self.showingSaveProvider = true
                self.newProviderName = ""; self.newProviderBaseURL = ""; self.newProviderApiKey = ""; self.newProviderModels = ""
            }
            .buttonStyle(CompactButtonStyle())
        }
    }

    private func handleProviderChange(_ newValue: String) {
        switch newValue {
        case "openai":
            self.openAIBaseURL = "https://api.openai.com/v1"
            self.updateCurrentProvider()
            let key = "openai"
            self.availableModels = self.availableModelsByProvider[key] ?? self.defaultModels(for: key)
            self.selectedModel = self.selectedModelByProvider[key] ?? self.availableModels.first ?? self.selectedModel
        case "groq":
            self.openAIBaseURL = "https://api.groq.com/openai/v1"
            self.updateCurrentProvider()
            let key = "groq"
            self.availableModels = self.availableModelsByProvider[key] ?? self.defaultModels(for: key)
            self.selectedModel = self.selectedModelByProvider[key] ?? self.availableModels.first ?? self.selectedModel
        case "apple-intelligence":
            self.openAIBaseURL = ""
            self.updateCurrentProvider()
            self.availableModels = ["System Model"]
            self.selectedModel = "System Model"
        default:
            if let provider = savedProviders.first(where: { $0.id == newValue }) {
                self.openAIBaseURL = provider.baseURL
                self.updateCurrentProvider()
                let key = self.providerKey(for: newValue)
                self.availableModels = provider.models.isEmpty ? (self.availableModelsByProvider[key] ?? []) : provider.models
                self.selectedModel = self.selectedModelByProvider[key] ?? self.availableModels.first ?? self.selectedModel
            }
        }
    }

    private func startEditingProvider() {
        if let provider = savedProviders.first(where: { $0.id == selectedProviderID }) {
            self.editProviderName = provider.name
            self.editProviderBaseURL = provider.baseURL
            self.showingEditProvider = true
        }
    }

    private func deleteCurrentProvider() {
        self.savedProviders.removeAll { $0.id == self.selectedProviderID }
        self.saveSavedProviders()
        let key = self.providerKey(for: self.selectedProviderID)
        self.availableModelsByProvider.removeValue(forKey: key)
        self.selectedModelByProvider.removeValue(forKey: key)
        self.providerAPIKeys.removeValue(forKey: key)
        self.saveProviderAPIKeys()
        SettingsStore.shared.availableModelsByProvider = self.availableModelsByProvider
        SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider
        self.selectedProviderID = "openai"
        self.openAIBaseURL = "https://api.openai.com/v1"
        self.updateCurrentProvider()
        self.availableModels = self.defaultModels(for: "openai")
        self.selectedModel = self.availableModels.first ?? self.selectedModel
    }

    private var editProviderSection: some View {
        VStack(spacing: 12) {
            HStack { Text("Edit Provider").font(.headline).fontWeight(.semibold); Spacer() }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Provider name", text: self.$editProviderName).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g., http://localhost:11434/v1", text: self.$editProviderBaseURL).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
            }
            HStack(spacing: 8) {
                Button("Save") { self.saveEditedProvider() }.buttonStyle(GlassButtonStyle())
                    .disabled(self.editProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.editProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { self.showingEditProvider = false; self.editProviderName = ""; self.editProviderBaseURL = "" }.buttonStyle(GlassButtonStyle())
            }
        }
        .padding(12)
        .background(self.theme.palette.cardBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(self.theme.palette.accent.opacity(0.3), lineWidth: 1))
        .padding(.vertical, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func saveEditedProvider() {
        let name = self.editProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = self.editProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !base.isEmpty else { return }

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
    }

    private var appleIntelligenceBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.logo").font(.system(size: 14))
            Text("On-Device").fontWeight(.medium)
            Text("•").foregroundStyle(.secondary)
            Image(systemName: "lock.shield.fill").font(.system(size: 12))
            Text("Private").fontWeight(.medium)
        }
        .font(.caption).foregroundStyle(.green)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.15))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                .green.opacity(0.3),
                lineWidth: 1
            )))
    }

    private var appleIntelligenceModelRow: some View {
        HStack(spacing: 12) {
            HStack { Text("Model:").fontWeight(.medium) }
                .frame(width: 90, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(LinearGradient(colors: [self.theme.palette.accent.opacity(0.15), self.theme.palette.accent.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
                .cornerRadius(6)
            Text("System Language Model").foregroundStyle(.secondary).font(.system(.body))
            Spacer()
        }
    }

    private var standardModelRow: some View {
        HStack(spacing: 12) {
            HStack { Text("Model:").fontWeight(.medium) }
                .frame(width: 90, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(LinearGradient(colors: [self.theme.palette.accent.opacity(0.15), self.theme.palette.accent.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
                .cornerRadius(6)

            Picker("", selection: self.$selectedModel) {
                ForEach(self.availableModels, id: \.self) { model in Text(model).tag(model) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 200)

            if !["openai", "groq"].contains(self.selectedProviderID) {
                Button(action: { self.deleteSelectedModel() }) {
                    HStack(spacing: 4) { Image(systemName: "trash"); Text("Delete") }.font(.caption).foregroundStyle(.red)
                }
                .buttonStyle(CompactButtonStyle())
            }

            if !self.showingAddModel {
                Button("+ Add Model") { self.showingAddModel = true; self.newModelName = "" }.buttonStyle(CompactButtonStyle())
            }

            Button(action: { self.openReasoningConfig() }) {
                HStack(spacing: 4) {
                    Image(systemName: self.hasReasoningConfigForCurrentModel() ? "brain.fill" : "brain")
                    Text("Reasoning")
                }
                .font(.caption)
                .foregroundStyle(self.hasReasoningConfigForCurrentModel() ? self.theme.palette.accent : .secondary)
            }
            .buttonStyle(CompactButtonStyle())
        }
    }

    private func deleteSelectedModel() {
        let key = self.providerKey(for: self.selectedProviderID)
        var list = self.availableModelsByProvider[key] ?? self.availableModels
        list.removeAll { $0 == self.selectedModel }
        if list.isEmpty { list = self.defaultModels(for: key) }
        self.availableModelsByProvider[key] = list
        SettingsStore.shared.availableModelsByProvider = self.availableModelsByProvider

        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let updatedProvider = SettingsStore.SavedProvider(id: self.savedProviders[providerIndex].id, name: self.savedProviders[providerIndex].name, baseURL: self.savedProviders[providerIndex].baseURL, models: list)
            self.savedProviders[providerIndex] = updatedProvider
            self.saveSavedProviders()
        }

        self.availableModels = list
        self.selectedModel = list.first ?? ""
        self.selectedModelByProvider[key] = self.selectedModel
        SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider
    }

    private func openReasoningConfig() {
        let pKey = self.providerKey(for: self.selectedProviderID)
        if let config = SettingsStore.shared.getReasoningConfig(forModel: selectedModel, provider: pKey) {
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

    private var addModelSection: some View {
        HStack(spacing: 8) {
            TextField("Enter model name", text: self.$newModelName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !self.newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.addNewModel() } }
            Button("Add") { self.addNewModel() }.buttonStyle(CompactButtonStyle())
                .disabled(self.newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { self.showingAddModel = false; self.newModelName = "" }.buttonStyle(CompactButtonStyle())
        }
        .padding(.leading, 122)
    }

    private var reasoningConfigSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "brain.head.profile").foregroundStyle(self.theme.palette.accent)
                Text("Reasoning Config for \(self.selectedModel)").font(.caption).fontWeight(.semibold)
                Spacer()
            }

            Toggle("Enable reasoning parameter", isOn: self.$editingReasoningEnabled).toggleStyle(.switch).font(.caption)

            if self.editingReasoningEnabled {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Parameter Name").font(.caption2).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: {
                                // Map current value to picker options
                                if self.editingReasoningParamName == "reasoning_effort" {
                                    return "reasoning_effort"
                                } else if self.editingReasoningParamName == "enable_thinking" {
                                    return "enable_thinking"
                                } else {
                                    return "custom"
                                }
                            },
                            set: { newValue in
                                if newValue == "custom" {
                                    // Keep the current value for custom editing
                                    if self.editingReasoningParamName == "reasoning_effort" || self.editingReasoningParamName == "enable_thinking" {
                                        self.editingReasoningParamName = ""
                                    }
                                } else {
                                    self.editingReasoningParamName = newValue
                                }
                            }
                        )) {
                            Text("reasoning_effort").tag("reasoning_effort")
                            Text("enable_thinking").tag("enable_thinking")
                            Text("Custom...").tag("custom")
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 150)
                    }

                    // Show TextField for custom parameter name
                    if self.editingReasoningParamName != "reasoning_effort" && self.editingReasoningParamName != "enable_thinking" {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom Name").font(.caption2).foregroundStyle(.secondary)
                            TextField("e.g., thinking_budget", text: self.$editingReasoningParamName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Value").font(.caption2).foregroundStyle(.secondary)
                        if self.editingReasoningParamName == "reasoning_effort" {
                            Picker("", selection: self.$editingReasoningParamValue) {
                                Text("none").tag("none"); Text("minimal").tag("minimal"); Text("low").tag("low"); Text("medium").tag("medium"); Text("high").tag("high")
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 100)
                        } else if self.editingReasoningParamName == "enable_thinking" {
                            Picker("", selection: self.$editingReasoningParamValue) {
                                Text("true").tag("true"); Text("false").tag("false")
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 100)
                        } else {
                            // Free-form value for custom parameters
                            TextField("value", text: self.$editingReasoningParamValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Save") { self.saveReasoningConfig() }.buttonStyle(GlassButtonStyle())
                Button("Cancel") { self.showingReasoningConfig = false }.buttonStyle(CompactButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(self.theme.palette.accent.opacity(0.08)).overlay(RoundedRectangle(cornerRadius: 8).stroke(self.theme.palette.accent.opacity(0.2), lineWidth: 1)))
        .padding(.leading, 122)
        .transition(.opacity)
    }

    private func saveReasoningConfig() {
        let pKey = self.providerKey(for: self.selectedProviderID)
        if self.editingReasoningEnabled {
            let config = SettingsStore.ModelReasoningConfig(parameterName: self.editingReasoningParamName, parameterValue: self.editingReasoningParamValue, isEnabled: true)
            SettingsStore.shared.setReasoningConfig(config, forModel: self.selectedModel, provider: pKey)
        } else {
            let config = SettingsStore.ModelReasoningConfig(parameterName: "", parameterValue: "", isEnabled: false)
            SettingsStore.shared.setReasoningConfig(config, forModel: self.selectedModel, provider: pKey)
        }
        self.showingReasoningConfig = false
    }

    private var connectionTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: { Task { await self.testAPIConnection() } }) {
                    Text(self.isTestingConnection ? "Verifying..." : "Verify Connection").font(.caption).fontWeight(.semibold)
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(self.isTestingConnection || (!self.isLocalEndpoint(self.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) && (self.providerAPIKeys[self.currentProvider] ?? "").isEmpty))
            }

            // Connection Status Display
            if self.connectionStatus == .success {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text("Connection verified").font(.caption).foregroundStyle(.green)
                }
            } else if self.connectionStatus == .failed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection failed").font(.caption).foregroundStyle(.red)
                        if !self.connectionErrorMessage.isEmpty {
                            Text(self.connectionErrorMessage).font(.caption2).foregroundStyle(.red.opacity(0.8)).lineLimit(1)
                        }
                    }
                }
            } else if self.connectionStatus == .testing {
                HStack(spacing: 8) {
                    ProgressView().frame(width: 16, height: 16)
                    Text("Verifying...").font(.caption).foregroundStyle(self.theme.palette.accent)
                }
            }

            // API Key Editor Sheet
            Color.clear.frame(height: 0)
                .sheet(isPresented: self.$showAPIKeyEditor) {
                    self.apiKeyEditorSheet
                }
        }
    }

    private var apiKeyEditorSheet: some View {
        VStack(spacing: 14) {
            Text("Enter \(self.providerDisplayName(for: self.selectedProviderID)) API Key").font(.headline)
            SecureField("API Key (optional for local endpoints)", text: self.$newProviderApiKey)
                .textFieldStyle(.roundedBorder).frame(width: 300)
            HStack(spacing: 12) {
                Button("Cancel") { self.showAPIKeyEditor = false }.buttonStyle(.bordered)
                Button("OK") {
                    let trimmedKey = self.newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.providerAPIKeys[self.currentProvider] = trimmedKey
                    self.saveProviderAPIKeys()
                    if self.connectionStatus != .unknown { self.connectionStatus = .unknown; self.connectionErrorMessage = "" }
                    self.showAPIKeyEditor = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!self.isLocalEndpoint(self.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) && self.newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 350, minHeight: 150)
    }

    private var addProviderSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("Provider name", text: self.$newProviderName).textFieldStyle(.roundedBorder).frame(width: 200)
                TextField("Base URL", text: self.$newProviderBaseURL).textFieldStyle(.roundedBorder).frame(width: 250)
            }
            HStack(spacing: 8) {
                SecureField("API Key (optional for local)", text: self.$newProviderApiKey).textFieldStyle(.roundedBorder).frame(width: 200)
                TextField("Models (comma-separated)", text: self.$newProviderModels).textFieldStyle(.roundedBorder).frame(width: 250)
            }
            HStack(spacing: 8) {
                Button("Save Provider") { self.saveNewProvider() }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(self.newProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { self.showingSaveProvider = false; self.newProviderName = ""; self.newProviderBaseURL = ""; self.newProviderApiKey = ""; self.newProviderModels = "" }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(self.newProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self
                        .newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") {
                    self.showingSaveProvider = false; self.newProviderName = ""; self.newProviderBaseURL = ""; self
                        .newProviderApiKey = ""; self.newProviderModels = ""
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
        .transition(.opacity)
    }

    private func saveNewProvider() {
        let name = self.newProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = self.newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let api = self.newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !base.isEmpty else { return }

        let modelsList = self.newProviderModels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let models = modelsList.isEmpty ? self.defaultModels(for: "openai") : modelsList

        let newProvider = SettingsStore.SavedProvider(name: name, baseURL: base, models: models)
        self.savedProviders.removeAll { $0.name.lowercased() == name.lowercased() }
        self.savedProviders.append(newProvider)
        self.saveSavedProviders()

        let key = self.providerKey(for: newProvider.id)
        self.providerAPIKeys[key] = api
        self.availableModelsByProvider[key] = models
        self.selectedModelByProvider[key] = models.first ?? self.selectedModel
        SettingsStore.shared.providerAPIKeys = self.providerAPIKeys
        SettingsStore.shared.availableModelsByProvider = self.availableModelsByProvider
        SettingsStore.shared.selectedModelByProvider = self.selectedModelByProvider

        self.selectedProviderID = newProvider.id
        self.openAIBaseURL = base
        self.updateCurrentProvider()
        self.availableModels = models
        self.selectedModel = models.first ?? self.selectedModel

        self.showingSaveProvider = false
        self.newProviderName = ""; self.newProviderBaseURL = ""; self.newProviderApiKey = ""; self.newProviderModels = ""
    }

    private var apiKeysGuideCard: some View {
        ThemedCard(style: .prominent, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: { self.showAPIKeysGuide.toggle() }) {
                    HStack {
                        Image(systemName: "key.fill").font(.title3).foregroundStyle(.purple)
                        Text("Get API Keys").font(.headline).fontWeight(.semibold).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: self.showAPIKeysGuide ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if self.showAPIKeysGuide {
                    VStack(alignment: .leading, spacing: 12) {
                        ProviderGuide(name: "OpenAI", url: "https://platform.openai.com/api-keys", baseURL: "https://api.openai.com/v1", keyPrefix: "sk-")
                        ProviderGuide(name: "Groq", url: "https://console.groq.com/keys", baseURL: "https://api.groq.com/openai/v1", keyPrefix: "gsk_")
                        ProviderGuide(name: "OpenRouter", url: "https://openrouter.ai/keys", baseURL: "https://openrouter.ai/api/v1", keyPrefix: "sk-or-")

                        Divider()

                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill").font(.caption).foregroundStyle(self.theme.palette.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Any OpenAI compatible API endpoint is supported").font(.caption)
                                    .fontWeight(.semibold)
                                Text("Use '+ Add Provider' to add custom providers like Ollama, LM Studio, etc.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(self.theme.palette.accent.opacity(0.08))
                        .cornerRadius(8)
                    }
                    .transition(.opacity)
                }
            }
            .padding(14)
        }
        .modifier(CardAppearAnimation(delay: 0.2, appear: self.$appear))
    }
}
