import Foundation

struct DictationProviderRoute: Equatable {
    let providerID: String
    let providerKey: String
    let baseURL: String
    let model: String
    let apiKey: String

    var usesPrivateAI: Bool {
        self.providerID == PrivateAIProviderFeature.shared.providerID ||
            self.providerKey == PrivateAIProviderFeature.shared.providerID ||
            self.providerKey == "custom:\(PrivateAIProviderFeature.shared.providerID)"
    }

    static func resolve(
        settings: SettingsStore,
        dictationSlot: SettingsStore.DictationShortcutSlot? = nil,
        appBundleID: String? = nil
    ) -> Self {
        guard let dictationSlot else {
            return self.build(settings: settings, selectedProviderID: settings.selectedProviderID, configuredModel: nil)
        }
        let selection = settings.resolvedDictationPromptSelection(for: dictationSlot, appBundleID: appBundleID)
        switch self.modelChoice(settings: settings, selection: selection, appBundleID: appBundleID) {
        case .none:
            return Self(providerID: "", providerKey: "", baseURL: "", model: "", apiKey: "")
        case .privateAI:
            return self.privateAIRoute(settings: settings)
        case let .provider(providerID, model):
            return self.build(settings: settings, selectedProviderID: providerID, configuredModel: model)
        }
    }

    /// Model routing without credentials or private-model installation checks.
    /// The overlay can snapshot this on main and resolve its display name off main.
    enum ModelChoice: Equatable, Sendable {
        case none
        case privateAI
        case provider(String, String?)
    }

    /// Capture only the intended route here. Installation verification belongs
    /// on the warmup worker, never in the microphone's started callback.
    static func privateAIWarmupVerification(
        settings: SettingsStore,
        slot: SettingsStore.DictationShortcutSlot,
        appBundleID: String?
    ) -> PrivateAIProviderPromptFormat.VerificationInput? {
        let selection = settings.resolvedDictationPromptSelection(for: slot, appBundleID: appBundleID, privateAIAvailable: true)
        switch self.modelChoice(settings: settings, selection: selection, appBundleID: appBundleID) {
        case .none: return nil
        case .privateAI: break
        case let .provider(providerID, _):
            let privateID = PrivateAIProviderFeature.shared.providerID
            guard providerID == privateID || providerID == "custom:\(privateID)" else { return nil }
        }
        return .init(settings: settings)
    }

    static func modelChoice(
        settings: SettingsStore,
        selection: SettingsStore.DictationPromptSelection,
        appBundleID: String?
    ) -> ModelChoice {
        if selection == .off { return .none }
        if selection == .privateAI { return .privateAI }
        let configuration = settings.dictationPromptConfiguration(for: selection)
        let providerID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !providerID.isEmpty, !model.isEmpty { return .provider(providerID, model) }
        let hasAppBinding = settings.appPromptBinding(for: .dictate, appBundleID: appBundleID) != nil
        if selection == .default, !hasAppBinding, self.shouldUseLegacyPrivateAIRoute(
            selectedProviderID: settings.selectedProviderID,
            configuredProviderID: providerID,
            configuredModel: model
        ) {
            return .privateAI
        }
        return .provider(self.externalFallbackProviderID(from: settings.selectedProviderID), nil)
    }

    static func modelID(settings: SettingsStore, providerID: String, configuredModel: String?) -> String {
        if let configuredModel { return configuredModel }
        let selectedModels = settings.selectedModelByProvider
        if let saved = settings.savedProviders.first(where: { $0.id == providerID }) {
            return selectedModels["custom:\(saved.id)"] ?? saved.models.first ?? ""
        }
        if ModelRepository.shared.isBuiltIn(providerID) {
            return selectedModels[providerID] ?? ModelRepository.shared.defaultModels(for: providerID).first ?? ""
        }
        return selectedModels[providerID] ?? ""
    }

    private static func build(settings: SettingsStore, selectedProviderID: String, configuredModel: String?) -> Self {
        let model = self.modelID(settings: settings, providerID: selectedProviderID, configuredModel: configuredModel)
        let providerKeys = settings.providerAPIKeys

        if let saved = settings.savedProviders.first(where: { $0.id == selectedProviderID }) {
            let key = "custom:\(saved.id)"
            return Self(
                providerID: selectedProviderID,
                providerKey: key,
                baseURL: saved.baseURL,
                model: model,
                apiKey: providerKeys[key] ?? providerKeys[selectedProviderID] ?? ""
            )
        }

        if ModelRepository.shared.isBuiltIn(selectedProviderID) {
            return Self(
                providerID: selectedProviderID,
                providerKey: selectedProviderID,
                baseURL: ModelRepository.shared.defaultBaseURL(for: selectedProviderID),
                model: model,
                apiKey: providerKeys[selectedProviderID] ?? ""
            )
        }

        return Self(
            providerID: selectedProviderID,
            providerKey: selectedProviderID,
            baseURL: "",
            model: model,
            apiKey: providerKeys[selectedProviderID] ?? ""
        )
    }

    /// Where `.default` would route for dictation, regardless of what is selected now.
    /// Mirrors the `.default` branch of `resolve` so the picker can drop an option that
    /// would otherwise render as "Default · Unavailable".
    static func resolveDictationDefault(settings: SettingsStore, appBundleID: String? = nil) -> Self {
        let configuration = settings.dictationPromptConfiguration(for: .default)
        let providerID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !providerID.isEmpty, !model.isEmpty {
            return self.build(settings: settings, selectedProviderID: providerID, configuredModel: model)
        }
        let hasAppBinding = settings.appPromptBinding(for: .dictate, appBundleID: appBundleID) != nil
        if !hasAppBinding, self.shouldUseLegacyPrivateAIRoute(
            selectedProviderID: settings.selectedProviderID,
            configuredProviderID: providerID,
            configuredModel: model
        ) {
            return self.privateAIRoute(settings: settings)
        }
        return self.build(
            settings: settings,
            selectedProviderID: self.externalFallbackProviderID(from: settings.selectedProviderID),
            configuredModel: nil
        )
    }

    /// True when picking "Default" would actually reach a configured, verified provider.
    static func isDictationDefaultAvailable(settings: SettingsStore, appBundleID: String? = nil) -> Bool {
        let route = self.resolveDictationDefault(settings: settings, appBundleID: appBundleID)
        guard !route.providerID.isEmpty, !route.model.isEmpty else { return false }
        return DictationAIPostProcessingGate.isProviderConfigured(providerID: route.providerID, model: route.model)
    }

    static func privateAIRoute(settings: SettingsStore) -> Self {
        guard let modelID = PrivateAIProviderPromptFormat.verifiedModelID(settings: settings) else {
            return Self(providerID: "", providerKey: "", baseURL: "", model: "", apiKey: "")
        }
        return Self(
            providerID: PrivateAIProviderFeature.shared.providerID,
            providerKey: PrivateAIProviderFeature.shared.providerID,
            baseURL: ModelRepository.shared.defaultBaseURL(for: PrivateAIProviderFeature.shared.providerID),
            model: modelID,
            apiKey: ""
        )
    }

    static func resolve(settings: SettingsStore, providerID: String, model: String) -> Self {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerKeys = settings.providerAPIKeys
        if let saved = settings.savedProviders.first(where: { $0.id == trimmedProviderID }) {
            let key = "custom:\(saved.id)"
            return Self(
                providerID: trimmedProviderID,
                providerKey: key,
                baseURL: saved.baseURL,
                model: trimmedModel,
                apiKey: providerKeys[key] ?? providerKeys[trimmedProviderID] ?? ""
            )
        }
        return Self(
            providerID: trimmedProviderID,
            providerKey: trimmedProviderID,
            baseURL: ModelRepository.shared.defaultBaseURL(for: trimmedProviderID),
            model: trimmedModel,
            apiKey: providerKeys[trimmedProviderID] ?? ""
        )
    }

    static func externalFallbackProviderID(from providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == PrivateAIProviderFeature.shared.providerID ? "" : trimmed
    }

    static func shouldUseLegacyPrivateAIRoute(
        selectedProviderID: String,
        configuredProviderID: String,
        configuredModel: String
    ) -> Bool {
        selectedProviderID == PrivateAIProviderFeature.shared.providerID &&
            configuredProviderID.isEmpty && configuredModel.isEmpty
    }

    static func allowsPrivateAIRoute(
        selection: SettingsStore.DictationPromptSelection,
        selectedProviderID: String
    ) -> Bool {
        selection == .privateAI ||
            (selection == .default && selectedProviderID == PrivateAIProviderFeature.shared.providerID)
    }

    static func resolveForPostProcessing(
        settings: SettingsStore,
        dictationSlot: SettingsStore.DictationShortcutSlot
    ) -> Self {
        if settings.dictationPromptSelection(for: dictationSlot) == .privateAI {
            return self.privateAIRoute(settings: settings)
        }
        if settings.promptRoutingScope(for: .dictate) == .selectedAppsOnly {
            return self.resolve(settings: settings)
        }
        return self.resolve(settings: settings, dictationSlot: dictationSlot)
    }
}

@MainActor
final class DictationPostProcessingService {
    static let shared = DictationPostProcessingService()

    private init() {}

    struct Result {
        let text: String
        let providerID: String
        let model: String
    }

    func process(_ inputText: String, dictationSlot: SettingsStore.DictationShortcutSlot = .primary) async throws -> Result {
        guard let summaryActivity = MeetingSummaryActivityCoordinator.shared.beginProcessing() else {
            throw MeetingModelResidencyError.busy
        }
        defer { MeetingSummaryActivityCoordinator.shared.endProcessing(summaryActivity) }

        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(text: "", providerID: SettingsStore.shared.selectedProviderID, model: "")
        }

        let settings = SettingsStore.shared
        let resolved = DictationProviderRoute.resolveForPostProcessing(
            settings: settings,
            dictationSlot: dictationSlot
        )
        guard !resolved.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProcessingError.noVerifiedProvider
        }
        DebugLogger.shared.debug(
            "DictationPostProcessingService using provider=\(resolved.providerKey), model=\(resolved.model)",
            source: "DictationPostProcessingService"
        )

        let allowsPrivateAIRoute = DictationProviderRoute.allowsPrivateAIRoute(
            selection: settings.dictationPromptSelection(for: dictationSlot),
            selectedProviderID: settings.selectedProviderID
        )
        guard allowsPrivateAIRoute || !resolved.usesPrivateAI else {
            throw AIProcessingError.noVerifiedProvider
        }

        if allowsPrivateAIRoute,
           resolved.usesPrivateAI || PrivateAIIntegrationService.shouldHandleDictation(model: resolved.model)
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
                    usesStablePromptPrefixKVCache: settings.privateAIPrefixKVCacheEnabled,
                    usesFluid1Boost: settings.privateAIBoostEnabled,
                    contextTokenLimit: settings.privateAIContextTokenLimit
                ),
                context: PrivateAIIntegrationService.AppContext(
                    appName: "",
                    bundleID: "",
                    windowTitle: "",
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                )
            )
            settings.recordFluidIntelligenceUse(output: response.outputText)
            return Result(
                text: ASRService.applyGAAVFormatting(response.outputText),
                providerID: resolved.providerID,
                model: resolved.model
            )
        }

        let promptText = settings.effectiveDictationSystemPrompt(for: dictationSlot, appBundleID: nil)
        let request = DictationPromptRequest(promptText: promptText, transcript: trimmed)

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

        var config = LLMClient.Config(
            messages: request.messages,
            model: resolved.model,
            baseURL: resolved.baseURL,
            apiKey: resolved.apiKey,
            streaming: false,
            tools: [],
            temperature: settings.isTemperatureUnsupported(resolved.model, baseURL: resolved.baseURL) ? nil : 0.2,
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
}
