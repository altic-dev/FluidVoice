import CryptoKit
import Foundation

/// Shared gating logic for whether dictation AI post-processing is usable/configured.
enum DictationAIPostProcessingGate {
    /// Returns true if dictation AI post-processing should be allowed, given current settings.
    /// - Requires dictation prompt selection to not be `Off`
    /// - Requires the selected provider connection to still be verified
    static func isConfigured() -> Bool {
        self.isConfigured(for: .primary, appBundleID: nil)
    }

    static func isConfigured(for slot: SettingsStore.DictationShortcutSlot, appBundleID: String? = nil) -> Bool {
        let settings = SettingsStore.shared
        let promptSelection = settings.dictationPromptSelection(for: slot)
        guard promptSelection != .off else { return false }
        if let appBundleID,
           settings.promptRoutingScope(for: .dictate) == .selectedAppsOnly,
           !settings.hasAppPromptBinding(for: .dictate, appBundleID: appBundleID)
        {
            return false
        }

        if promptSelection == .privateAI {
            return self.isPrivateProviderConfigured(settings: settings)
        }

        if self.isSelectedPrivateProvider(settings: settings) { return false }

        return self.isProviderConfigured()
    }

    /// Returns true if the selected AI provider is currently verified/configured,
    /// regardless of the AI toggle or prompt selection. Used to gate prompt-mode hotkey AI processing.
    static func isProviderConfigured() -> Bool {
        let settings = SettingsStore.shared
        let providerID = settings.selectedProviderID
        if PrivateFeatures.privateAIProvider,
           providerID == PrivateAIProviderFeature.shared.providerID
        {
            return self.isPrivateProviderConfigured(settings: settings)
        }

        let key = self.providerKey(for: providerID)
        guard let storedFingerprint = settings.verifiedProviderFingerprints[key] else { return false }

        if providerID == "apple-intelligence" {
            return storedFingerprint == "apple-intelligence" && AppleIntelligenceService.isAvailable
        }

        let baseURL = self.baseURL(for: providerID, settings: settings)
        let apiKey = (settings.getAPIKey(for: providerID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.isLocalEndpoint(baseURL) || !apiKey.isEmpty else { return false }

        return self.providerFingerprint(baseURL: baseURL, apiKey: apiKey) == storedFingerprint
    }

    static func baseURL(for providerID: String, settings: SettingsStore) -> String {
        if let saved = settings.savedProviders.first(where: { $0.id == providerID }) {
            return saved.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Use ModelRepository for all built-in providers (openai, groq, cerebras, google, openrouter, ollama, lmstudio)
        if ModelRepository.shared.isBuiltIn(providerID) {
            return ModelRepository.shared.defaultBaseURL(for: providerID)
        }
        // Unknown provider: fail closed instead of silently treating it as OpenAI.
        return ""
    }

    static func providerKey(for providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if ModelRepository.shared.isBuiltIn(trimmed) { return trimmed }
        if trimmed.hasPrefix("custom:") { return trimmed }
        return "custom:\(trimmed)"
    }

    static func providerFingerprint(baseURL: String, apiKey: String) -> String? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty else { return nil }

        let input = "\(trimmedBase)|\(trimmedKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isPrivateProviderConfigured(settings: SettingsStore) -> Bool {
        PrivateAIProviderPromptFormat.verifiedModelID(settings: settings) != nil
    }

    private static func isSelectedPrivateProvider(settings: SettingsStore) -> Bool {
        PrivateFeatures.privateAIProvider &&
            settings.selectedProviderID == PrivateAIProviderFeature.shared.providerID
    }

    static func isLocalEndpoint(_ urlString: String) -> Bool {
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
}
