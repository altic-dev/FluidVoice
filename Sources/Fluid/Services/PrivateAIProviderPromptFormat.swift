import Foundation

enum PrivateAIProviderPromptFormat {
    static var promptSelectionID: String {
        PrivateAIProviderFeature.shared.promptSelectionID
    }

    static func isAvailable(settings: SettingsStore = .shared) -> Bool {
        self.verifiedModelID(settings: settings) != nil
    }

    static func verifiedModelID(settings: SettingsStore = .shared) -> String? {
        let key = self.providerKey(for: PrivateAIProviderFeature.shared.providerID)
        let configuredModelID = PrivateAIIntegrationService.configuredModelID
        let modelID = PrivateAIModelRegistry.canonicalModelID(for: settings.selectedModelByProvider[key] ?? configuredModelID) ?? configuredModelID
        return self.verifiedModelID(for: modelID, settings: settings)
    }

    static func verifiedModelID(for selectedModelID: String, settings: SettingsStore = .shared) -> String? {
        guard PrivateFeatures.privateAIProvider else { return nil }
        let key = self.providerKey(for: PrivateAIProviderFeature.shared.providerID)
        let modelID = PrivateAIModelRegistry.canonicalModelID(for: selectedModelID) ?? selectedModelID
        let expectedFingerprint = PrivateAIProviderFeature.verificationFingerprint(for: modelID)
        guard let model = PrivateAIModelRegistry.model(id: modelID),
              PrivateAIIntegrationService.isModelInstalled(model),
              self.hasStoredVerification(
                  for: modelID,
                  providerKey: key,
                  expectedFingerprint: expectedFingerprint,
                  settings: settings
              )
        else {
            return nil
        }

        return modelID
    }

    static func hasStoredVerification(
        for modelID: String,
        providerKey: String,
        expectedFingerprint: String,
        settings: SettingsStore = .shared
    ) -> Bool {
        settings.verifiedPrivateAIModelFingerprints[modelID] == expectedFingerprint ||
            settings.verifiedProviderFingerprints[providerKey] == expectedFingerprint
    }

    private static func providerKey(for providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if ModelRepository.shared.isBuiltIn(trimmed) { return trimmed }
        if trimmed.hasPrefix("custom:") { return trimmed }
        return "custom:\(trimmed)"
    }
}
