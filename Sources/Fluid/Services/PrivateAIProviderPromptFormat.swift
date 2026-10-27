import Foundation

enum PrivateAIProviderPromptFormat {
    static var promptSelectionID: String {
        PrivateAIProviderFeature.shared.promptSelectionID
    }

    static func isAvailable(settings: SettingsStore = .shared) -> Bool {
        self.verifiedModelID(settings: settings) != nil
    }

    /// Immutable settings only. Resolving this may query the model directory, so
    /// presentation callers resolve it on a worker, never while drawing a view.
    nonisolated struct VerificationInput: Equatable, Sendable {
        let providerAvailable: Bool
        let selectedModelID: String?
        let providerFingerprint: String?
        let modelFingerprints: [String: String]
        let backendPreference: String?
        let configuredModelSelection: String?
        let configuredLocalModelPath: String?

        @MainActor
        init(settings: SettingsStore) {
            let key = PrivateAIProviderPromptFormat.providerKey(for: PrivateAIProviderFeature.shared.providerID)
            self.providerAvailable = PrivateAIProviderFeature.shared.isAvailable
            self.selectedModelID = settings.selectedModelByProvider[key]
            self.providerFingerprint = settings.verifiedProviderFingerprints[key]
            self.modelFingerprints = settings.verifiedPrivateAIModelFingerprints
            self.backendPreference = UserDefaults.standard.string(forKey: SettingsStore.privateAIBackendPreferenceDefaultsKey)
            self.configuredModelSelection = UserDefaults.standard.string(forKey: PrivateAIProviderFeature.shared.selectedModelDefaultsKey)
            self.configuredLocalModelPath = UserDefaults.standard.string(forKey: PrivateAIProviderFeature.shared.localModelPathDefaultsKey)
        }

        func verifiedModelID(recheckInstallation: Bool = false) -> String? {
            let configured = PrivateAIIntegrationService.configuredModelID
            let modelID = PrivateAIModelRegistry.canonicalModelID(for: self.selectedModelID ?? configured) ?? configured
            return self.verifiedModelID(for: modelID, recheckInstallation: recheckInstallation)
        }

        func verifiedModelID(for selectedModelID: String, recheckInstallation: Bool = false) -> String? {
            guard self.providerAvailable else { return nil }
            let modelID = PrivateAIModelRegistry.canonicalModelID(for: selectedModelID) ?? selectedModelID
            let fingerprint = PrivateAIProviderFeature.verificationFingerprint(for: modelID, backendPreference: self.backendPreference)
            guard let model = PrivateAIModelRegistry.model(id: modelID),
                  PrivateAIIntegrationService.isModelInstalled(model, useCache: !recheckInstallation),
                  self.modelFingerprints[modelID] == fingerprint || self.providerFingerprint == fingerprint
            else { return nil }
            return modelID
        }
    }

    static func verifiedModelID(settings: SettingsStore = .shared) -> String? {
        VerificationInput(settings: settings).verifiedModelID()
    }

    static func verifiedModelID(for selectedModelID: String, settings: SettingsStore = .shared) -> String? {
        VerificationInput(settings: settings).verifiedModelID(for: selectedModelID)
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
