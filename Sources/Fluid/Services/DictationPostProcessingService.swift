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
        let selectedProviderID: String
        let configuredModel: String?

        if let dictationSlot {
            let selection = self.effectivePromptSelection(
                settings: settings,
                dictationSlot: dictationSlot,
                appBundleID: appBundleID
            )
            if selection == .off {
                return Self(providerID: "", providerKey: "", baseURL: "", model: "", apiKey: "")
            }
            if selection == .privateAI {
                return self.privateAIRoute(settings: settings)
            }

            let configuration = settings.dictationPromptConfiguration(for: selection)
            let providerID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !providerID.isEmpty, !model.isEmpty {
                selectedProviderID = providerID
                configuredModel = model
            } else {
                let hasAppBinding = settings.appPromptBinding(for: .dictate, appBundleID: appBundleID) != nil
                if selection == .default, !hasAppBinding, self.shouldUseLegacyPrivateAIRoute(
                    selectedProviderID: settings.selectedProviderID,
                    configuredProviderID: providerID,
                    configuredModel: model
                ) {
                    return self.privateAIRoute(settings: settings)
                }
                selectedProviderID = self.externalFallbackProviderID(from: settings.selectedProviderID)
                configuredModel = nil
            }
        } else {
            selectedProviderID = settings.selectedProviderID
            configuredModel = nil
        }

        let selectedModels = settings.selectedModelByProvider
        let providerKeys = settings.providerAPIKeys

        if let saved = settings.savedProviders.first(where: { $0.id == selectedProviderID }) {
            let key = "custom:\(saved.id)"
            return Self(
                providerID: selectedProviderID,
                providerKey: key,
                baseURL: saved.baseURL,
                model: configuredModel ?? selectedModels[key] ?? saved.models.first ?? "",
                apiKey: providerKeys[key] ?? providerKeys[selectedProviderID] ?? ""
            )
        }

        if ModelRepository.shared.isBuiltIn(selectedProviderID) {
            return Self(
                providerID: selectedProviderID,
                providerKey: selectedProviderID,
                baseURL: ModelRepository.shared.defaultBaseURL(for: selectedProviderID),
                model: configuredModel ?? selectedModels[selectedProviderID] ?? ModelRepository.shared.defaultModels(for: selectedProviderID).first ?? "",
                apiKey: providerKeys[selectedProviderID] ?? ""
            )
        }

        return Self(
            providerID: selectedProviderID,
            providerKey: selectedProviderID,
            baseURL: "",
            model: configuredModel ?? selectedModels[selectedProviderID] ?? "",
            apiKey: providerKeys[selectedProviderID] ?? ""
        )
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
        if let saved = settings.savedProviders.first(where: { $0.id == trimmedProviderID }) {
            let key = "custom:\(saved.id)"
            return Self(
                providerID: trimmedProviderID,
                providerKey: key,
                baseURL: saved.baseURL,
                model: trimmedModel,
                apiKey: settings.providerAPIKeys[key] ?? settings.providerAPIKeys[trimmedProviderID] ?? ""
            )
        }
        return Self(
            providerID: trimmedProviderID,
            providerKey: trimmedProviderID,
            baseURL: ModelRepository.shared.defaultBaseURL(for: trimmedProviderID),
            model: trimmedModel,
            apiKey: settings.providerAPIKeys[trimmedProviderID] ?? ""
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

    private static func effectivePromptSelection(
        settings: SettingsStore,
        dictationSlot: SettingsStore.DictationShortcutSlot,
        appBundleID: String?
    ) -> SettingsStore.DictationPromptSelection {
        let selection = settings.dictationPromptSelection(for: dictationSlot)
        guard selection != .off else { return selection }

        let usesOnlyAppBindings = settings.promptRoutingScope(for: .dictate) == .selectedAppsOnly
        let supportsAppOverride = SettingsStore.dictationSelectionSupportsAppOverride(selection)
        guard usesOnlyAppBindings || supportsAppOverride else { return selection }
        guard let binding = settings.appPromptBinding(for: .dictate, appBundleID: appBundleID) else {
            return usesOnlyAppBindings ? .off : selection
        }
        guard let promptID = binding.promptID,
              settings.dictationPromptProfiles.contains(where: {
                  $0.id == promptID && $0.mode.normalized == .dictate
              })
        else {
            return .default
        }
        return .profile(promptID)
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
}
