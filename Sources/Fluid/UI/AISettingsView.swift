//
//  AISettingsView.swift
//  fluid
//
//  Extracted from ContentView.swift to reduce monolithic architecture.
//  Created: 2025-12-14
//

import SwiftUI
import AppKit
import Security

// MARK: - Connection Status Enum
enum AIConnectionStatus {
    case unknown, testing, success, failed
}

struct AISettingsView: View {
    @EnvironmentObject private var appServices: AppServices
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @Environment(\.theme) private var theme
    
    private var asr: ASRService { appServices.asr }
    
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
                speechRecognitionCard
                aiConfigurationCard
            }
            .padding(14)
        }
        .onAppear {
            appear = true
            loadSettings()
            
            // CRITICAL FIX: Refresh model status immediately on appear
            // This ensures the speech recognition card shows current download status
            asr.checkIfModelsExist()
        }
        .onChange(of: enableAIProcessing) { _, newValue in
            SettingsStore.shared.enableAIProcessing = newValue
            // Keep menu bar UI in sync when toggled from this screen
            menuBarManager.aiProcessingEnabled = newValue
        }
        .onChange(of: selectedModel) { _, newValue in
            if newValue != "__ADD_MODEL__" {
                selectedModelByProvider[currentProvider] = newValue
                SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
            }
        }
        .onChange(of: selectedProviderID) { _, newValue in
            SettingsStore.shared.selectedProviderID = newValue
        }
        .onChange(of: showKeychainPermissionAlert) { _, isPresented in
            guard isPresented else { return }
            presentKeychainAccessAlert(message: keychainPermissionMessage)
            showKeychainPermissionAlert = false
        }
    }
    
    // MARK: - Load Settings
    private func loadSettings() {
        selectedProviderID = SettingsStore.shared.selectedProviderID
        updateCurrentProvider()
        
        enableAIProcessing = SettingsStore.shared.enableAIProcessing
        availableModelsByProvider = SettingsStore.shared.availableModelsByProvider
        selectedModelByProvider = SettingsStore.shared.selectedModelByProvider
        providerAPIKeys = SettingsStore.shared.providerAPIKeys
        savedProviders = SettingsStore.shared.savedProviders
        
        // Normalize provider keys
        var normalized: [String: [String]] = [:]
        for (key, models) in availableModelsByProvider {
            let lower = key.lowercased()
            let newKey: String
            if lower == "openai" || lower == "groq" { newKey = lower }
            else { newKey = key.hasPrefix("custom:") ? key : "custom:\(key)" }
            let clean = Array(Set(models.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
            if !clean.isEmpty { normalized[newKey] = clean }
        }
        availableModelsByProvider = normalized
        SettingsStore.shared.availableModelsByProvider = normalized
        
        // Normalize selected model by provider
        var normalizedSel: [String: String] = [:]
        for (key, model) in selectedModelByProvider {
            let lower = key.lowercased()
            let newKey: String = (lower == "openai" || lower == "groq") ? lower : (key.hasPrefix("custom:") ? key : "custom:\(key)")
            if let list = normalized[newKey], list.contains(model) { normalizedSel[newKey] = model }
        }
        selectedModelByProvider = normalizedSel
        SettingsStore.shared.selectedModelByProvider = normalizedSel
        
        // Determine initial model list
        if let saved = savedProviders.first(where: { $0.id == selectedProviderID }) {
            availableModels = saved.models
            openAIBaseURL = saved.baseURL
        } else if let stored = availableModelsByProvider[currentProvider], !stored.isEmpty {
            availableModels = stored
        } else {
            availableModels = defaultModels(for: providerKey(for: selectedProviderID))
        }
        
        // Restore selected model
        if let sel = selectedModelByProvider[currentProvider], availableModels.contains(sel) {
            selectedModel = sel
        } else if let first = availableModels.first {
            selectedModel = first
        }
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
                                    asr.resetTranscriptionProvider()
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
                        .disabled(asr.isRunning)
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
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.palette.accent.opacity(0.2)))
                        }
                    }
                    
                    // Model status indicator
                    modelStatusView
                    
                    // Performance note
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(theme.palette.accent)
                            .font(.caption)
                        Text(SettingsStore.shared.selectedSpeechModel.isWhisperModel
                             ? "Whisper models support 99 languages and work on any Mac."
                             : "Parakeet TDT uses CoreML and Neural Engine for fastest transcription (25 languages) on Apple Silicon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial.opacity(0.3)))
                    
                    Divider().padding(.vertical, 4)
                    
                    // Filler Words Section
                    fillerWordsSection
                }
            }
            .padding(14)
        }
    }
    
    private var modelStatusView: some View {
        HStack(spacing: 12) {
            if asr.isDownloadingModel || asr.isLoadingModel {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(asr.isLoadingModel ? "Loading model…" : "Downloading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if asr.isAsrReady {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Text("Ready").font(.caption).foregroundStyle(.secondary)
                
                Button(action: { Task { await deleteModels() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            } else if asr.modelsExistOnDisk {
                Image(systemName: "doc.fill").foregroundStyle(theme.palette.accent).font(.caption)
                Text("Cached").font(.caption).foregroundStyle(.secondary)
                
                Button(action: { Task { await deleteModels() } }) {
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
                
                Button(action: { Task { await downloadModels() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download")
                    }
                    .font(.caption)
                    .foregroundStyle(theme.palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial.opacity(0.3))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1), lineWidth: 1))
        )
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
                Toggle("", isOn: $removeFillerWordsEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: removeFillerWordsEnabled) { _, newValue in
                        SettingsStore.shared.removeFillerWordsEnabled = newValue
                    }
            }
            
            if removeFillerWordsEnabled {
                FillerWordsEditor()
            }
        }
    }
    
    // MARK: - Model Download/Delete
    private func downloadModels() async {
        do {
            try await asr.ensureAsrReady()
        } catch {
            DebugLogger.shared.error("Failed to download models: \(error)", source: "AISettingsView")
        }
    }
    
    private func deleteModels() async {
        do {
            try await asr.clearModelCache()
        } catch {
            DebugLogger.shared.error("Failed to delete models: \(error)", source: "AISettingsView")
        }
    }
    
    // MARK: - Helper Functions
    private func providerKey(for providerID: String) -> String {
        if providerID == "openai" || providerID == "groq" { return providerID }
        return providerID.isEmpty ? currentProvider : "custom:\(providerID)"
    }
    
    private func providerDisplayName(for providerID: String) -> String {
        switch providerID {
        case "openai": return "OpenAI"
        case "groq": return "Groq"
        case "apple-intelligence": return "Apple Intelligence"
        default:
            return savedProviders.first(where: { $0.id == providerID })?.name ?? providerID.capitalized
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
        SettingsStore.shared.providerAPIKeys = providerAPIKeys
    }
    
    private func updateCurrentProvider() {
        let url = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.contains("openai.com") { currentProvider = "openai"; return }
        if url.contains("groq.com") { currentProvider = "groq"; return }
        currentProvider = providerKey(for: selectedProviderID)
    }
    
    private func saveSavedProviders() {
        SettingsStore.shared.savedProviders = savedProviders
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
        let pKey = providerKey(for: selectedProviderID)
        if SettingsStore.shared.hasCustomReasoningConfig(forModel: selectedModel, provider: pKey) {
            if let config = SettingsStore.shared.getReasoningConfig(forModel: selectedModel, provider: pKey) {
                return config.isEnabled
            }
        }
        let modelLower = selectedModel.lowercased()
        return modelLower.hasPrefix("gpt-5") || modelLower.contains("gpt-5.") ||
               modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") ||
               modelLower.contains("gpt-oss") || modelLower.hasPrefix("openai/") ||
               (modelLower.contains("deepseek") && modelLower.contains("reasoner"))
    }
    
    private func addNewModel() {
        guard !newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let modelName = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = providerKey(for: selectedProviderID)
        
        var list = availableModelsByProvider[key] ?? availableModels
        if !list.contains(modelName) {
            list.append(modelName)
            availableModelsByProvider[key] = list
            SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
            
            if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
                let updatedProvider = SettingsStore.SavedProvider(
                    id: savedProviders[providerIndex].id,
                    name: savedProviders[providerIndex].name,
                    baseURL: savedProviders[providerIndex].baseURL,
                    models: list
                )
                savedProviders[providerIndex] = updatedProvider
                saveSavedProviders()
            }
            
            availableModels = list
            selectedModel = modelName
            selectedModelByProvider[key] = modelName
            SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
        }
        
        showingAddModel = false
        newModelName = ""
    }
    
    // MARK: - Keychain Access Helpers
    private enum KeychainAccessCheckResult {
        case granted
        case denied(OSStatus)
    }
    
    private func handleAPIKeyButtonTapped() {
        switch probeKeychainAccess() {
        case .granted:
            newProviderApiKey = providerAPIKeys[currentProvider] ?? ""
            showAPIKeyEditor = true
        case .denied(let status):
            keychainPermissionMessage = keychainPermissionExplanation(for: status)
            showKeychainPermissionAlert = true
        }
    }
    
    private func probeKeychainAccess() -> KeychainAccessCheckResult {
        let service = "com.fluidvoice.provider-api-keys"
        let account = "fluidApiKeys"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
        }
    }
    
    // MARK: - API Connection Testing
    private func testAPIConnection() async {
        guard !isTestingConnection else { return }
        
        let apiKey = providerAPIKeys[currentProvider] ?? ""
        let baseURL = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = isLocalEndpoint(baseURL)
        
        if isLocal {
            guard !baseURL.isEmpty else {
                await MainActor.run {
                    connectionStatus = .failed
                    connectionErrorMessage = "Base URL is required"
                }
                return
            }
        } else {
            guard !apiKey.isEmpty && !baseURL.isEmpty else {
                await MainActor.run {
                    connectionStatus = .failed
                    connectionErrorMessage = "API key and base URL are required"
                }
                return
            }
        }
        
        await MainActor.run {
            isTestingConnection = true
            connectionStatus = .testing
            connectionErrorMessage = ""
        }
        
        do {
            let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let fullURL: String
            if endpoint.contains("/chat/completions") || endpoint.contains("/api/chat") || endpoint.contains("/api/generate") {
                fullURL = endpoint
            } else {
                fullURL = endpoint + "/chat/completions"
            }
            
            guard let url = URL(string: fullURL) else {
                await MainActor.run {
                    connectionStatus = .failed
                    connectionErrorMessage = "Invalid Base URL format"
                }
                return
            }
            
            let provKey = providerKey(for: selectedProviderID)
            let reasoningConfig = SettingsStore.shared.getReasoningConfig(forModel: selectedModel, provider: provKey)
            
            let modelLower = selectedModel.lowercased()
            let usesMaxCompletionTokens = modelLower.hasPrefix("gpt-5") || modelLower.contains("gpt-5.") ||
                                          modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3")
            
            var requestDict: [String: Any] = [
                "model": selectedModel,
                "messages": [["role": "user", "content": "test"]]
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
                    connectionStatus = .failed
                    connectionErrorMessage = "Failed to encode test request"
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
                        connectionStatus = .success
                        connectionErrorMessage = ""
                    }
                } else {
                    var errorMessage = "HTTP \(httpResponse.statusCode)"
                    
                    if let responseBody = String(data: data, encoding: .utf8),
                       let jsonData = responseBody.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                            errorMessage = message
                        } else if let message = json["message"] as? String {
                            errorMessage = message
                        }
                    }
                    
                    await MainActor.run {
                        connectionStatus = .failed
                        connectionErrorMessage = errorMessage
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
                connectionStatus = .failed
                connectionErrorMessage = error.localizedDescription
            }
        }
        
        await MainActor.run {
            isTestingConnection = false
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
                            .foregroundStyle(theme.palette.accent)
                        Text("API Configuration")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: { showHelp.toggle() }) {
                            Image(systemName: showHelp ? "questionmark.circle.fill" : "questionmark.circle")
                                .font(.system(size: 20))
                                .foregroundStyle(theme.palette.accent.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Divider().padding(.vertical, 3)
                    
                    // AI Enhancement Toggle
                    aiEnhancementToggle
                    
                    // Streaming Toggle
                    if enableAIProcessing && selectedProviderID != "apple-intelligence" {
                        streamingToggle
                    }
                    
                    // API Key Warning
                    if enableAIProcessing && selectedProviderID != "apple-intelligence" &&
                       !isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) &&
                       (providerAPIKeys[currentProvider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        apiKeyWarningView
                    }
                    
                    // Help Section
                    if showHelp { helpSectionView }
                    
                    Divider().padding(.vertical, 3)
                    
                    // Provider/Model Configuration
                    providerConfigurationSection
                }
                .padding(14)
            }
            .modifier(CardAppearAnimation(delay: 0.1, appear: $appear))
            
            // API Keys Guide
            apiKeysGuideCard
        }
    }
    
    private var aiEnhancementToggle: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enable AI Enhancement")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.palette.primaryText)
                Text("Automatically enhance transcriptions with AI")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.secondaryText)
            }
            Spacer()
            Toggle("", isOn: $enableAIProcessing)
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
                        .foregroundStyle(theme.palette.primaryText)
                    Text("Currently only Command Mode shows real-time streaming")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.secondaryText)
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
                helpStep("1", "Enable AI enhancement if needed")
                helpStep("2", "Add/choose any provider of your choice along with its API key")
                helpStep("3", "Add/choose any good model of your liking")
                helpStep("4", "If it's OpenAI compatible endpoint, then update the base URL")
                helpStep("5", "Once everything is set, click verify to check if the connection works")
            }
        }
        .padding(14)
        .background(theme.palette.accent.opacity(0.08))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.accent.opacity(0.2), lineWidth: 1))
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
            if selectedProviderID == "apple-intelligence" {
                HStack(spacing: 6) {
                    Image(systemName: "apple.logo").font(.caption2).foregroundStyle(theme.palette.accent)
                    Text("Powered by on-device Apple Intelligence").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(theme.palette.accent)
                    Text("Supports any OpenAI compatible API endpoints").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            
            Divider()
            
            providerPickerRow
            
            if showingEditProvider { editProviderSection }
            
            if selectedProviderID == "apple-intelligence" { appleIntelligenceBadge }
            
            // API Key Management
            if selectedProviderID != "apple-intelligence" {
                Divider()
                Button(action: { handleAPIKeyButtonTapped() }) {
                    Label("Add or Modify API Key", systemImage: "key.fill")
                        .labelStyle(.titleAndIcon).font(.caption)
                }
                .buttonStyle(GlassButtonStyle())
            }
            
            Divider()
            
            // Model Row
            if selectedProviderID == "apple-intelligence" {
                appleIntelligenceModelRow
            } else {
                standardModelRow
                if showingAddModel { addModelSection }
                if showingReasoningConfig { reasoningConfigSection }
            }
            
            Divider()
            
            // Connection Test
            if selectedProviderID != "apple-intelligence" {
                connectionTestSection
                if showingSaveProvider { addProviderSection }
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
            .background(LinearGradient(colors: [theme.palette.accent.opacity(0.15), theme.palette.accent.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
            .cornerRadius(6)
            
            Picker("", selection: $selectedProviderID) {
                Text("OpenAI").tag("openai")
                Text("Groq").tag("groq")
                if AppleIntelligenceService.isAvailable {
                    Text("Apple Intelligence").tag("apple-intelligence")
                }
                if !savedProviders.isEmpty {
                    Divider()
                    ForEach(savedProviders) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 200)
            .onChange(of: selectedProviderID) { _, newValue in
                handleProviderChange(newValue)
            }
            
            // Edit/Delete buttons for custom providers
            if !["openai", "groq", "apple-intelligence"].contains(selectedProviderID) {
                Button(action: { startEditingProvider() }) {
                    HStack(spacing: 4) { Image(systemName: "pencil"); Text("Edit") }.font(.caption)
                }
                .buttonStyle(CompactButtonStyle())
                
                Button(action: { deleteCurrentProvider() }) {
                    HStack(spacing: 4) { Image(systemName: "trash"); Text("Delete") }.font(.caption).foregroundStyle(.red)
                }
                .buttonStyle(CompactButtonStyle())
            }
            
            Button("+ Add Provider") {
                showingSaveProvider = true
                newProviderName = ""; newProviderBaseURL = ""; newProviderApiKey = ""; newProviderModels = ""
            }
            .buttonStyle(CompactButtonStyle())
        }
    }
    
    private func handleProviderChange(_ newValue: String) {
        switch newValue {
        case "openai":
            openAIBaseURL = "https://api.openai.com/v1"
            updateCurrentProvider()
            let key = "openai"
            availableModels = availableModelsByProvider[key] ?? defaultModels(for: key)
            selectedModel = selectedModelByProvider[key] ?? availableModels.first ?? selectedModel
        case "groq":
            openAIBaseURL = "https://api.groq.com/openai/v1"
            updateCurrentProvider()
            let key = "groq"
            availableModels = availableModelsByProvider[key] ?? defaultModels(for: key)
            selectedModel = selectedModelByProvider[key] ?? availableModels.first ?? selectedModel
        case "apple-intelligence":
            openAIBaseURL = ""
            updateCurrentProvider()
            availableModels = ["System Model"]
            selectedModel = "System Model"
        default:
            if let provider = savedProviders.first(where: { $0.id == newValue }) {
                openAIBaseURL = provider.baseURL
                updateCurrentProvider()
                let key = providerKey(for: newValue)
                availableModels = provider.models.isEmpty ? (availableModelsByProvider[key] ?? []) : provider.models
                selectedModel = selectedModelByProvider[key] ?? availableModels.first ?? selectedModel
            }
        }
    }
    
    private func startEditingProvider() {
        if let provider = savedProviders.first(where: { $0.id == selectedProviderID }) {
            editProviderName = provider.name
            editProviderBaseURL = provider.baseURL
            showingEditProvider = true
        }
    }
    
    private func deleteCurrentProvider() {
        savedProviders.removeAll { $0.id == selectedProviderID }
        saveSavedProviders()
        let key = providerKey(for: selectedProviderID)
        availableModelsByProvider.removeValue(forKey: key)
        selectedModelByProvider.removeValue(forKey: key)
        providerAPIKeys.removeValue(forKey: key)
        saveProviderAPIKeys()
        SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
        SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
        selectedProviderID = "openai"
        openAIBaseURL = "https://api.openai.com/v1"
        updateCurrentProvider()
        availableModels = defaultModels(for: "openai")
        selectedModel = availableModels.first ?? selectedModel
    }
    
    private var editProviderSection: some View {
        VStack(spacing: 12) {
            HStack { Text("Edit Provider").font(.headline).fontWeight(.semibold); Spacer() }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Provider name", text: $editProviderName).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base URL").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g., http://localhost:11434/v1", text: $editProviderBaseURL).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
            }
            HStack(spacing: 8) {
                Button("Save") { saveEditedProvider() }.buttonStyle(GlassButtonStyle())
                    .disabled(editProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { showingEditProvider = false; editProviderName = ""; editProviderBaseURL = "" }.buttonStyle(GlassButtonStyle())
            }
        }
        .padding(12)
        .background(theme.palette.cardBackground.opacity(0.5))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.palette.accent.opacity(0.3), lineWidth: 1))
        .padding(.vertical, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
    
    private func saveEditedProvider() {
        let name = editProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = editProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !base.isEmpty else { return }
        
        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let oldProvider = savedProviders[providerIndex]
            let updatedProvider = SettingsStore.SavedProvider(id: oldProvider.id, name: name, baseURL: base, models: oldProvider.models)
            savedProviders[providerIndex] = updatedProvider
            saveSavedProviders()
            openAIBaseURL = base
            updateCurrentProvider()
        }
        showingEditProvider = false
        editProviderName = ""; editProviderBaseURL = ""
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
        .background(RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.15)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.green.opacity(0.3), lineWidth: 1)))
    }
    
    private var appleIntelligenceModelRow: some View {
        HStack(spacing: 12) {
            HStack { Text("Model:").fontWeight(.medium) }
                .frame(width: 90, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(LinearGradient(colors: [theme.palette.accent.opacity(0.15), theme.palette.accent.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
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
                .background(LinearGradient(colors: [theme.palette.accent.opacity(0.15), theme.palette.accent.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
                .cornerRadius(6)
            
            Picker("", selection: $selectedModel) {
                ForEach(availableModels, id: \.self) { model in Text(model).tag(model) }
            }
            .pickerStyle(.menu).labelsHidden().frame(width: 200)
            
            if !["openai", "groq"].contains(selectedProviderID) {
                Button(action: { deleteSelectedModel() }) {
                    HStack(spacing: 4) { Image(systemName: "trash"); Text("Delete") }.font(.caption).foregroundStyle(.red)
                }
                .buttonStyle(CompactButtonStyle())
            }
            
            if !showingAddModel {
                Button("+ Add Model") { showingAddModel = true; newModelName = "" }.buttonStyle(CompactButtonStyle())
            }
            
            Button(action: { openReasoningConfig() }) {
                HStack(spacing: 4) {
                    Image(systemName: hasReasoningConfigForCurrentModel() ? "brain.fill" : "brain")
                    Text("Reasoning")
                }
                .font(.caption)
                .foregroundStyle(hasReasoningConfigForCurrentModel() ? theme.palette.accent : .secondary)
            }
            .buttonStyle(CompactButtonStyle())
        }
    }
    
    private func deleteSelectedModel() {
        let key = providerKey(for: selectedProviderID)
        var list = availableModelsByProvider[key] ?? availableModels
        list.removeAll { $0 == selectedModel }
        if list.isEmpty { list = defaultModels(for: key) }
        availableModelsByProvider[key] = list
        SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
        
        if let providerIndex = savedProviders.firstIndex(where: { $0.id == selectedProviderID }) {
            let updatedProvider = SettingsStore.SavedProvider(id: savedProviders[providerIndex].id, name: savedProviders[providerIndex].name, baseURL: savedProviders[providerIndex].baseURL, models: list)
            savedProviders[providerIndex] = updatedProvider
            saveSavedProviders()
        }
        
        availableModels = list
        selectedModel = list.first ?? ""
        selectedModelByProvider[key] = selectedModel
        SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
    }
    
    private func openReasoningConfig() {
        let pKey = providerKey(for: selectedProviderID)
        if let config = SettingsStore.shared.getReasoningConfig(forModel: selectedModel, provider: pKey) {
            editingReasoningParamName = config.parameterName
            editingReasoningParamValue = config.parameterValue
            editingReasoningEnabled = config.isEnabled
        } else {
            let modelLower = selectedModel.lowercased()
            if modelLower.hasPrefix("gpt-5") || modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") || modelLower.contains("gpt-oss") {
                editingReasoningParamName = "reasoning_effort"; editingReasoningParamValue = "low"; editingReasoningEnabled = true
            } else if modelLower.contains("deepseek") && modelLower.contains("reasoner") {
                editingReasoningParamName = "enable_thinking"; editingReasoningParamValue = "true"; editingReasoningEnabled = true
            } else {
                editingReasoningParamName = "reasoning_effort"; editingReasoningParamValue = "low"; editingReasoningEnabled = false
            }
        }
        showingReasoningConfig = true
    }
    
    private var addModelSection: some View {
        HStack(spacing: 8) {
            TextField("Enter model name", text: $newModelName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addNewModel() } }
            Button("Add") { addNewModel() }.buttonStyle(CompactButtonStyle())
                .disabled(newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { showingAddModel = false; newModelName = "" }.buttonStyle(CompactButtonStyle())
        }
        .padding(.leading, 122)
    }
    
    private var reasoningConfigSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "brain.head.profile").foregroundStyle(theme.palette.accent)
                Text("Reasoning Config for \(selectedModel)").font(.caption).fontWeight(.semibold)
                Spacer()
            }
            
            Toggle("Enable reasoning parameter", isOn: $editingReasoningEnabled).toggleStyle(.switch).font(.caption)
            
            if editingReasoningEnabled {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Parameter Name").font(.caption2).foregroundStyle(.secondary)
                        Picker("", selection: $editingReasoningParamName) {
                            Text("reasoning_effort").tag("reasoning_effort")
                            Text("enable_thinking").tag("enable_thinking")
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 150)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Value").font(.caption2).foregroundStyle(.secondary)
                        if editingReasoningParamName == "reasoning_effort" {
                            Picker("", selection: $editingReasoningParamValue) {
                                Text("minimal").tag("minimal"); Text("low").tag("low"); Text("medium").tag("medium"); Text("high").tag("high")
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 100)
                        } else {
                            Picker("", selection: $editingReasoningParamValue) {
                                Text("true").tag("true"); Text("false").tag("false")
                            }
                            .pickerStyle(.menu).labelsHidden().frame(width: 100)
                        }
                    }
                }
            }
            
            HStack(spacing: 8) {
                Button("Save") { saveReasoningConfig() }.buttonStyle(GlassButtonStyle())
                Button("Cancel") { showingReasoningConfig = false }.buttonStyle(CompactButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.palette.accent.opacity(0.08)).overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.palette.accent.opacity(0.2), lineWidth: 1)))
        .padding(.leading, 122)
        .transition(.opacity)
    }
    
    private func saveReasoningConfig() {
        let pKey = providerKey(for: selectedProviderID)
        if editingReasoningEnabled {
            let config = SettingsStore.ModelReasoningConfig(parameterName: editingReasoningParamName, parameterValue: editingReasoningParamValue, isEnabled: true)
            SettingsStore.shared.setReasoningConfig(config, forModel: selectedModel, provider: pKey)
        } else {
            let config = SettingsStore.ModelReasoningConfig(parameterName: "", parameterValue: "", isEnabled: false)
            SettingsStore.shared.setReasoningConfig(config, forModel: selectedModel, provider: pKey)
        }
        showingReasoningConfig = false
    }
    
    private var connectionTestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: { Task { await testAPIConnection() } }) {
                    Text(isTestingConnection ? "Verifying..." : "Verify Connection").font(.caption).fontWeight(.semibold)
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(isTestingConnection || (!isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) && (providerAPIKeys[currentProvider] ?? "").isEmpty))
            }
            
            // Connection Status Display
            if connectionStatus == .success {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    Text("Connection verified").font(.caption).foregroundStyle(.green)
                }
            } else if connectionStatus == .failed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connection failed").font(.caption).foregroundStyle(.red)
                        if !connectionErrorMessage.isEmpty {
                            Text(connectionErrorMessage).font(.caption2).foregroundStyle(.red.opacity(0.8)).lineLimit(1)
                        }
                    }
                }
            } else if connectionStatus == .testing {
                HStack(spacing: 8) {
                    ProgressView().frame(width: 16, height: 16)
                    Text("Verifying...").font(.caption).foregroundStyle(theme.palette.accent)
                }
            }
            
            // API Key Editor Sheet
            Color.clear.frame(height: 0)
                .sheet(isPresented: $showAPIKeyEditor) {
                    apiKeyEditorSheet
                }
        }
    }
    
    private var apiKeyEditorSheet: some View {
        VStack(spacing: 14) {
            Text("Enter \(providerDisplayName(for: selectedProviderID)) API Key").font(.headline)
            SecureField("API Key (optional for local endpoints)", text: $newProviderApiKey)
                .textFieldStyle(.roundedBorder).frame(width: 300)
            HStack(spacing: 12) {
                Button("Cancel") { showAPIKeyEditor = false }.buttonStyle(.bordered)
                Button("OK") {
                    let trimmedKey = newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    providerAPIKeys[currentProvider] = trimmedKey
                    saveProviderAPIKeys()
                    if connectionStatus != .unknown { connectionStatus = .unknown; connectionErrorMessage = "" }
                    showAPIKeyEditor = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isLocalEndpoint(openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) && newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 350, minHeight: 150)
    }
    
    private var addProviderSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("Provider name", text: $newProviderName).textFieldStyle(.roundedBorder).frame(width: 200)
                TextField("Base URL", text: $newProviderBaseURL).textFieldStyle(.roundedBorder).frame(width: 250)
            }
            HStack(spacing: 8) {
                SecureField("API Key (optional for local)", text: $newProviderApiKey).textFieldStyle(.roundedBorder).frame(width: 200)
                TextField("Models (comma-separated)", text: $newProviderModels).textFieldStyle(.roundedBorder).frame(width: 250)
            }
            HStack(spacing: 8) {
                Button("Save Provider") { saveNewProvider() }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(newProviderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { showingSaveProvider = false; newProviderName = ""; newProviderBaseURL = ""; newProviderApiKey = ""; newProviderModels = "" }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .transition(.opacity)
    }
    
    private func saveNewProvider() {
        let name = newProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = newProviderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let api = newProviderApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !base.isEmpty else { return }
        
        let modelsList = newProviderModels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let models = modelsList.isEmpty ? defaultModels(for: "openai") : modelsList
        
        let newProvider = SettingsStore.SavedProvider(name: name, baseURL: base, models: models)
        savedProviders.removeAll { $0.name.lowercased() == name.lowercased() }
        savedProviders.append(newProvider)
        saveSavedProviders()
        
        let key = providerKey(for: newProvider.id)
        providerAPIKeys[key] = api
        availableModelsByProvider[key] = models
        selectedModelByProvider[key] = models.first ?? selectedModel
        SettingsStore.shared.providerAPIKeys = providerAPIKeys
        SettingsStore.shared.availableModelsByProvider = availableModelsByProvider
        SettingsStore.shared.selectedModelByProvider = selectedModelByProvider
        
        selectedProviderID = newProvider.id
        openAIBaseURL = base
        updateCurrentProvider()
        availableModels = models
        selectedModel = models.first ?? selectedModel
        
        showingSaveProvider = false
        newProviderName = ""; newProviderBaseURL = ""; newProviderApiKey = ""; newProviderModels = ""
    }
    
    private var apiKeysGuideCard: some View {
        ThemedCard(style: .prominent, hoverEffect: false) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: { showAPIKeysGuide.toggle() }) {
                    HStack {
                        Image(systemName: "key.fill").font(.title3).foregroundStyle(.purple)
                        Text("Get API Keys").font(.headline).fontWeight(.semibold).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: showAPIKeysGuide ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                if showAPIKeysGuide {
                    VStack(alignment: .leading, spacing: 12) {
                        ProviderGuide(name: "OpenAI", url: "https://platform.openai.com/api-keys", baseURL: "https://api.openai.com/v1", keyPrefix: "sk-")
                        ProviderGuide(name: "Groq", url: "https://console.groq.com/keys", baseURL: "https://api.groq.com/openai/v1", keyPrefix: "gsk_")
                        ProviderGuide(name: "OpenRouter", url: "https://openrouter.ai/keys", baseURL: "https://openrouter.ai/api/v1", keyPrefix: "sk-or-")
                        
                        Divider()
                        
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill").font(.caption).foregroundStyle(theme.palette.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Any OpenAI compatible API endpoint is supported").font(.caption).fontWeight(.semibold)
                                Text("Use '+ Add Provider' to add custom providers like Ollama, LM Studio, etc.").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(theme.palette.accent.opacity(0.08))
                        .cornerRadius(8)
                    }
                    .transition(.opacity)
                }
            }
            .padding(14)
        }
        .modifier(CardAppearAnimation(delay: 0.2, appear: $appear))
    }
}
