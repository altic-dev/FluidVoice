import Combine
import CryptoKit
import Foundation

extension SettingsStore {
    private var commandModeLinkedToGlobalKey: String { "CommandModeLinkedToGlobal" }

    var commandModeLinkedToGlobal: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: self.commandModeLinkedToGlobalKey) as? Bool {
                return value
            }
            return true
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.commandModeLinkedToGlobalKey)
        }
    }

    var effectiveCommandModeProviderID: String {
        if self.commandModeLinkedToGlobal {
            return self.supportedCommandModeProviderID(self.selectedProviderID) ?? ""
        }

        if let providerID = self.supportedCommandModeProviderID(self.commandModeSelectedProviderID) {
            return providerID
        }

        return ""
    }

    var effectiveCommandModeSelectedModel: String {
        let providerID = self.effectiveCommandModeProviderID
        let models = self.commandModeModels(for: providerID)

        if self.commandModeLinkedToGlobal,
           self.supportedCommandModeProviderID(self.selectedProviderID) == providerID
        {
            let key = ModelRepository.shared.providerKey(for: providerID)
            return self.providerScopedModel(self.selectedModelByProvider[key], in: models)
                ?? self.providerScopedModel(self.selectedModel, in: models)
                ?? models.first
                ?? ""
        }

        return self.providerScopedModel(self.commandModeSelectedModel, in: models)
            ?? models.first
            ?? ""
    }

    var commandModeReadinessIssue: String? {
        let sourceProviderID = self.commandModeLinkedToGlobal ? self.selectedProviderID : self.commandModeSelectedProviderID
        if self.isPrivateAIProviderID(sourceProviderID) {
            return "\(PrivateAIProviderFeature.displayName) for Command Mode is coming soon. Choose a model from a verified chat provider."
        }

        let providerID = self.effectiveCommandModeProviderID
        guard !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Command Mode needs a verified chat provider."
        }

        let model = self.effectiveCommandModeSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return "Command Mode needs a selected chat model."
        }

        if self.isUnsupportedCommandModeModel(model) {
            return "Command Mode needs a chat model. The selected model is not supported by the chat/completions endpoint."
        }

        guard self.isCommandModeProviderVerified(providerID) else {
            if self.commandModeLinkedToGlobal {
                return "Command Mode needs a verified chat provider. Choose a verified model, or verify a provider in AI Providers."
            }
            return "Command Mode needs a verified chat provider. Verify this provider in AI Providers before using Command Mode."
        }

        return nil
    }

    func commandModeModels(for providerID: String) -> [String] {
        let canonicalKey = ModelRepository.shared.providerKey(for: providerID)
        let keys = [canonicalKey] + ModelRepository.shared.providerKeys(for: providerID).filter { $0 != canonicalKey }.sorted()
        let storedList = keys.lazy
            .compactMap { self.availableModelsByProvider[$0] }
            .first { !$0.isEmpty }

        let models: [String]
        if let storedList {
            models = storedList
        } else if let saved = self.commandModeSavedProvider(for: providerID), !saved.models.isEmpty {
            models = saved.models
        } else {
            models = ModelRepository.shared.defaultModels(for: providerID)
        }
        var seen = Set<String>()
        return models.compactMap { rawModel in
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return !model.isEmpty && seen.insert(model).inserted ? model : nil
        }
    }

    /// Build on presentation/catalog events, not while rendering rows. Credentials use the existing process cache.
    func commandModeModelCatalog() -> [CommandModelOption] {
        let apiKeys = self.providerAPIKeys
        let providers = ModelRepository.shared.builtInProvidersList() + self.savedProviders.map { (id: $0.id, name: $0.name) }
        var seenProviders = Set<String>()
        var options: [CommandModelOption] = []
        for provider in providers {
            let providerID = provider.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ModelRepository.shared.providerKey(for: providerID)
            guard !providerID.isEmpty, !self.isPrivateAIProviderID(providerID),
                  seenProviders.insert(key).inserted,
                  self.isCommandModeProviderVerified(providerID, apiKeys: apiKeys) else { continue }
            var seenModels = Set<String>()
            for rawModel in self.commandModeModels(for: providerID) {
                let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !model.isEmpty, !self.isUnsupportedCommandModeModel(model), seenModels.insert(model).inserted else { continue }
                options.append(CommandModelOption(
                    providerID: providerID,
                    providerName: provider.name,
                    modelID: model,
                    displayName: ModelDisplayName.forID(model)
                ))
            }
        }
        return options
    }

    /// A chooser selection is local to Command Mode; global and Edit Mode routes stay unchanged.
    @discardableResult
    func selectCommandModeModel(_ option: CommandModelOption) -> Bool {
        let key = ModelRepository.shared.providerKey(for: option.providerID)
        guard let current = self.commandModeModelCatalog().first(where: {
            ModelRepository.shared.providerKey(for: $0.providerID) == key && $0.modelID == option.modelID
        }) else { return false }
        self.commandModeSelectedProviderID = current.providerID
        self.commandModeSelectedModel = current.modelID
        self.commandModeLinkedToGlobal = false
        return true
    }

    private func supportedCommandModeProviderID(_ providerID: String) -> String? {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !self.isPrivateAIProviderID(trimmed) else { return nil }
        return trimmed
    }

    func isCommandModeProviderVerified(_ providerID: String) -> Bool {
        self.isCommandModeProviderVerified(providerID, apiKeys: self.providerAPIKeys)
    }

    private func isCommandModeProviderVerified(_ providerID: String, apiKeys: [String: String]) -> Bool {
        guard !self.isPrivateAIProviderID(providerID) else { return false }
        let key = ModelRepository.shared.providerKey(for: providerID)
        guard let stored = self.verifiedProviderFingerprints[key] else { return false }

        let baseURL = self.commandModeProviderBaseURL(for: providerID)
        // Match getAPIKey exactly: the registered ID takes precedence, then its canonical key.
        let apiKey = apiKeys[providerID] ?? apiKeys[key] ?? ""
        return self.commandModeProviderFingerprint(baseURL: baseURL, apiKey: apiKey) == stored
    }

    private func commandModeSavedProvider(for providerID: String) -> SavedProvider? {
        let key = ModelRepository.shared.providerKey(for: providerID)
        return self.savedProviders.first { ModelRepository.shared.providerKey(for: $0.id) == key }
    }

    private func commandModeProviderBaseURL(for providerID: String) -> String {
        if let saved = self.commandModeSavedProvider(for: providerID) {
            return saved.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ModelRepository.shared.isBuiltIn(providerID) {
            return ModelRepository.shared.defaultBaseURL(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func commandModeProviderFingerprint(baseURL: String, apiKey: String) -> String? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return nil }
        let input = "\(trimmedBase)|\(trimmedKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isPrivateAIProviderID(_ providerID: String) -> Bool {
        PrivateFeatures.privateAIProvider &&
            providerID.trimmingCharacters(in: .whitespacesAndNewlines) == PrivateAIProviderFeature.shared.providerID
    }

    private func isUnsupportedCommandModeModel(_ model: String) -> Bool {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if PrivateAIIntegrationService.shouldHandleDictation(model: value) {
            return true
        }
        if value.contains("embedding") || value.contains("rerank") || value.contains("moderation") {
            return true
        }
        if value.hasPrefix("tts-") || value.hasPrefix("whisper-") || value.hasPrefix("dall-e") {
            return true
        }
        return value == "davinci" || value == "curie" || value == "babbage" || value == "ada"
    }

    private func nonEmptyModel(_ model: String?) -> String? {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func providerScopedModel(_ model: String?, in models: [String]) -> String? {
        guard let model = self.nonEmptyModel(model), models.contains(model) else { return nil }
        return model
    }
}
