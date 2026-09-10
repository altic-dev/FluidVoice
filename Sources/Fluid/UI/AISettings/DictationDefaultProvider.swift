import Foundation

/// Identifies the main shortcut's provider without reading credentials or app-specific overrides.
enum DictationDefaultProvider {
    static func setupIssue(requiresAPIKey: Bool, hasAPIKey: Bool, hasModel: Bool, isVerified: Bool, verificationFailed: Bool) -> String? {
        if requiresAPIKey, !hasAPIKey { return "API key missing" }
        if !hasModel { return "Choose a model" }
        if verificationFailed { return "Verification failed" }
        // A test is optional; only missing setup prevents use.
        return nil
    }

    static func providerID(
        selection: SettingsStore.DictationPromptSelection,
        configuration: SettingsStore.DictationPromptConfiguration,
        selectedProviderID: String,
        privateProviderID: String
    ) -> String {
        if selection == .off { return "" }
        if selection == .privateAI { return privateProviderID }
        let providerID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !providerID.isEmpty, !model.isEmpty { return providerID }
        if selection == .default, selectedProviderID == privateProviderID,
           providerID.isEmpty, model.isEmpty { return privateProviderID }
        let fallback = selectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback == privateProviderID ? "" : fallback
    }
}
