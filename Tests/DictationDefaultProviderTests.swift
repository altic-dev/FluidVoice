import Foundation

// Minimal settings types let the production read-only resolver run without launching the app.
enum SettingsStore {
    enum DictationPromptSelection: Equatable { case off, `default`, privateAI, profile(String) }
    struct DictationPromptConfiguration { var providerID: String; var modelName: String }
}

@main
enum DictationDefaultProviderTests {
    static func main() {
        func resolve(_ selection: SettingsStore.DictationPromptSelection, _ global: String, _ provider: String = "", _ model: String = "") -> String {
            DictationDefaultProvider.providerID(
                selection: selection,
                configuration: .init(providerID: provider, modelName: model),
                selectedProviderID: global,
                privateProviderID: "fluid-1"
            )
        }
        precondition(resolve(.off, "openai", "openrouter", "model") == "")
        precondition(resolve(.privateAI, "openai") == "fluid-1")
        precondition(resolve(.default, "openai") == "openai")
        precondition(resolve(.default, "openai", " openrouter ", " model ") == "openrouter")
        precondition(resolve(.profile("style"), "openai", "custom-provider", "model") == "custom-provider")
        precondition(resolve(.default, "fluid-1") == "fluid-1")
        precondition(resolve(.profile("style"), "fluid-1") == "")
        precondition(resolve(.default, "fluid-1", "openai", "") == "")
        precondition(resolve(.default, "openai", "openrouter", "") == "openai")
        precondition(resolve(.default, "openai", "", "model") == "openai")
        precondition(DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: false, hasModel: true, isVerified: true, verificationFailed: false) == "API key missing")
        precondition(DictationDefaultProvider.setupIssue(requiresAPIKey: false, hasAPIKey: false, hasModel: true, isVerified: true, verificationFailed: false) == nil)
        precondition(DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: true, hasModel: false, isVerified: false, verificationFailed: false) == "Choose a model")
        precondition(DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: true, hasModel: true, isVerified: false, verificationFailed: false) == nil, "Optional verification must not block a configured provider")
        precondition(DictationDefaultProvider.setupIssue(requiresAPIKey: true, hasAPIKey: true, hasModel: true, isVerified: false, verificationFailed: true) == "Verification failed")
        print("PASS: 10 default-provider cases and 5 setup-status cases")
    }
}
