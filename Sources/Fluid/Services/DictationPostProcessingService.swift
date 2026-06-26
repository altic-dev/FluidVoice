import Foundation

@MainActor
final class DictationPostProcessingService {
    static let shared = DictationPostProcessingService()

    private init() {}

    struct Result {
        let text: String
        let providerID: String
        let model: String
    }

    private struct ResolvedProvider {
        let providerID: String
        let providerKey: String
        let baseURL: String
        let model: String
        let apiKey: String
    }

    func process(_ inputText: String, dictationSlot: SettingsStore.DictationShortcutSlot = .primary) async throws -> Result {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(text: "", providerID: SettingsStore.shared.selectedProviderID, model: "")
        }

        let settings = SettingsStore.shared
        let resolved = self.resolveProvider(settings: settings, dictationSlot: dictationSlot)
        guard !resolved.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProcessingError.noVerifiedProvider
        }
        DebugLogger.shared.debug(
            "DictationPostProcessingService using provider=\(resolved.providerKey), model=\(resolved.model)",
            source: "DictationPostProcessingService"
        )

        let usesPrivateAISelection = settings.dictationPromptSelection(for: dictationSlot) == .privateAI
        let isPrivateAIProvider = resolved.providerID == PrivateAIProviderFeature.shared.providerID ||
            resolved.providerKey == PrivateAIProviderFeature.shared.providerID ||
            resolved.providerKey == "custom:\(PrivateAIProviderFeature.shared.providerID)"

        guard usesPrivateAISelection || !isPrivateAIProvider else {
            throw AIProcessingError.noVerifiedProvider
        }

        if usesPrivateAISelection,
           isPrivateAIProvider || PrivateAIIntegrationService.shouldHandleDictation(model: resolved.model)
        {
            let response = try await PrivateAIIntegrationService.shared.enhanceDictation(
                trimmed,
                runtime: PrivateAIIntegrationService.RuntimeConfiguration(
                    selectedProviderID: resolved.providerID,
                    providerKey: resolved.providerKey,
                    baseURL: resolved.baseURL,
                    model: resolved.model,
                    apiKey: resolved.apiKey,
                    localModelPath: PrivateAIIntegrationService.configuredLocalModelPath,
                    usesStablePromptPrefixKVCache: settings.privateAIPrefixKVCacheEnabled
                ),
                context: PrivateAIIntegrationService.AppContext(
                    appName: "",
                    bundleID: "",
                    windowTitle: "",
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                )
            )
            return Result(
                text: ASRService.applyGAAVFormatting(response.outputText),
                providerID: resolved.providerID,
                model: resolved.model
            )
        }

        let promptText = settings.effectiveDictationSystemPrompt(for: dictationSlot, appBundleID: nil)
        let systemPrompt = ""
        let userMessageContent = SettingsStore.renderDictationUserMessage(
            promptText: promptText,
            transcript: trimmed
        )

        if resolved.providerID == "apple-intelligence" {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let provider = AppleIntelligenceProvider()
                let output = try await provider.process(systemPrompt: systemPrompt, userText: userMessageContent)
                guard !output.isEmpty else { throw AIProcessingError.emptyResponse }
                return Result(text: ASRService.applyGAAVFormatting(output), providerID: resolved.providerID, model: resolved.model)
            }
            #endif
            return Result(text: trimmed, providerID: resolved.providerID, model: resolved.model)
        }

        guard !resolved.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProcessingError.missingModel(provider: resolved.providerKey)
        }

        let isLocal = ModelRepository.shared.isLocalEndpoint(resolved.baseURL)
        if !isLocal, resolved.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIProcessingError.missingAPIKey(provider: resolved.providerKey)
        }

        var extraParams: [String: Any] = [:]
        if let config = settings.getReasoningConfig(forModel: resolved.model, provider: resolved.providerKey), config.isEnabled {
            extraParams[config.parameterName] = config.parameterName == "enable_thinking"
                ? (config.parameterValue == "true")
                : config.parameterValue
        }

        var messages: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        messages.append(["role": "user", "content": userMessageContent])

        var config = LLMClient.Config(
            messages: messages,
            model: resolved.model,
            baseURL: resolved.baseURL,
            apiKey: resolved.apiKey,
            streaming: false,
            tools: [],
            temperature: settings.isTemperatureUnsupported(resolved.model) ? nil : 0.2,
            extraParameters: extraParams
        )
        config.timeoutSeconds = 120

        let response = try await LLMClient.shared.call(config)
        guard !response.content.isEmpty else {
            throw AIProcessingError.emptyResponse
        }
        return Result(
            text: ASRService.applyGAAVFormatting(response.content),
            providerID: resolved.providerID,
            model: resolved.model
        )
    }

    private func resolveProvider(settings: SettingsStore, dictationSlot: SettingsStore.DictationShortcutSlot) -> ResolvedProvider {
        if settings.dictationPromptSelection(for: dictationSlot) == .privateAI,
           let modelID = PrivateAIProviderPromptFormat.verifiedModelID(settings: settings)
        {
            let providerID = PrivateAIProviderFeature.shared.providerID
            return ResolvedProvider(
                providerID: providerID,
                providerKey: providerID,
                baseURL: ModelRepository.shared.defaultBaseURL(for: providerID),
                model: modelID,
                apiKey: ""
            )
        }

        let providerID = settings.selectedProviderID
        let selectedModels = settings.selectedModelByProvider
        let providerKeys = settings.providerAPIKeys

        if let saved = settings.savedProviders.first(where: { $0.id == providerID }) {
            let key = "custom:\(saved.id)"
            return ResolvedProvider(
                providerID: providerID,
                providerKey: key,
                baseURL: saved.baseURL,
                model: selectedModels[key] ?? saved.models.first ?? "",
                apiKey: providerKeys[key] ?? providerKeys[providerID] ?? ""
            )
        }

        if ModelRepository.shared.isBuiltIn(providerID) {
            return ResolvedProvider(
                providerID: providerID,
                providerKey: providerID,
                baseURL: ModelRepository.shared.defaultBaseURL(for: providerID),
                model: selectedModels[providerID] ?? ModelRepository.shared.defaultModels(for: providerID).first ?? "",
                apiKey: providerKeys[providerID] ?? ""
            )
        }

        return ResolvedProvider(
            providerID: providerID,
            providerKey: providerID,
            baseURL: "",
            model: selectedModels[providerID] ?? "",
            apiKey: providerKeys[providerID] ?? ""
        )
    }
}
