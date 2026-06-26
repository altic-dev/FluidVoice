import Foundation

enum PrivateAIProviderPromptFormat {
    static var promptSelectionID: String {
        PrivateAIProviderFeature.shared.promptSelectionID
    }

    static func isAvailable(settings: SettingsStore = .shared) -> Bool {
        guard self.verifiedModelID(settings: settings) != nil else { return false }

        if settings.selectedProviderID == PrivateAIProviderFeature.shared.providerID {
            return true
        }

        return self.isSoleStoredVerifiedProvider(settings: settings)
    }

    static func verifiedModelID(settings: SettingsStore = .shared) -> String? {
        guard PrivateFeatures.privateAIProvider else { return nil }
        let key = self.providerKey(for: PrivateAIProviderFeature.shared.providerID)
        let configuredModelID = PrivateAIIntegrationService.configuredModelID
        let modelID = PrivateAIModelRegistry.canonicalModelID(for: settings.selectedModelByProvider[key] ?? configuredModelID) ?? configuredModelID
        guard let model = PrivateAIModelRegistry.model(id: modelID),
              PrivateAIIntegrationService.isModelInstalled(model),
              settings.verifiedProviderFingerprints[key] == PrivateAIProviderFeature.verificationFingerprint(for: modelID)
        else {
            return nil
        }

        return modelID
    }

    private static func isSoleStoredVerifiedProvider(settings: SettingsStore) -> Bool {
        let key = self.providerKey(for: PrivateAIProviderFeature.shared.providerID)
        let fingerprints = settings.verifiedProviderFingerprints
        guard fingerprints[key] != nil else { return false }
        return fingerprints.keys.allSatisfy { $0 == key }
    }

    private static func providerKey(for providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if ModelRepository.shared.isBuiltIn(trimmed) { return trimmed }
        if trimmed.hasPrefix("custom:") { return trimmed }
        return "custom:\(trimmed)"
    }
}
