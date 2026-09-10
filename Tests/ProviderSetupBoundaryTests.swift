import Foundation

// Compile the production draft/save adapter against isolated settings and Keychain doubles.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: [String]] = [:]
    // Match Foundation UserDefaults, including an absent key.
    // swiftlint:disable:next discouraged_optional_collection
    func stringArray(forKey key: String) -> [String]? { values[key] }
    func set(_ value: [String], forKey key: String) { values[key] = value }
}
struct PrivateAIProviderFeature {
    static let shared = PrivateAIProviderFeature()
    let providerID = "fluid"
}
struct ModelRepository {
    static let shared = ModelRepository()
    func isBuiltIn(_ id: String) -> Bool { ["openai", "ollama", "fluid"].contains(id) }
    func defaultModels(for id: String) -> [String] { ["default-model"] }
}
final class SettingsStore {
    struct SavedProvider {
        var id = UUID().uuidString
        let name: String
        let baseURL: String
        let models: [String]
    }
    struct Configuration: Equatable {
        var providerID: String
        var modelName = "model"
        var shortcut = "keep-shortcut"
    }
    var selectedProviderID = "fluid"
    var selectedModel: String? = "mini"
    var rewriteModeSelectedProviderID = ""
    var rewriteModeSelectedModel: String?
    var commandModeSelectedProviderID = ""
    var commandModeSelectedModel: String?
    var availableModelsByProvider: [String: [String]] = [:]
    var selectedModelByProvider: [String: String] = [:]
    var dictationPromptConfigurations: [String: Configuration] = [:]
    var verifiedProviderFingerprints: [String: String] = [:]
}
final class AIEnhancementSettingsViewModel {
    struct ProviderItemData {
        let id: String
        let name: String
        let isBuiltIn: Bool
    }
    let settings = SettingsStore()
    var isTestingConnection = false
    var isFetchingModels = false
    var selectedProviderID = "openai"
    var managedOriginalKey: String?
    var fetchedModelsProviders: Set<String> = []
    var providerAPIKeys: [String: String] = [:]
    var savedProviders: [SettingsStore.SavedProvider] = []
    var availableModelsByProvider: [String: [String]] = [:]
    var selectedModelByProvider: [String: String] = ["fluid": "mini"]
    var cachedAddedProviderItems: [ProviderItemData] = []
    var failKeychain = false
    var saves = 0
    var keySaves = 0
    var persistedKeys: [String: String] = [:]
    func providerKey(for id: String) -> String { id }
    func providerAPIKey(for id: String) -> String { providerAPIKeys[id] ?? "" }
    func updateProviderAPIKey(_ value: String, for id: String) { providerAPIKeys[id] = value }
    func saveProviderAPIKeys(invalidating id: String) -> Bool {
        keySaves += 1
        guard !failKeychain else { return false }
        persistedKeys = providerAPIKeys
        return true
    }
    func hasProviderAPIKeyDraft(for id: String) -> Bool { providerAPIKeys[id] != nil }
    func refreshProviderItems() {
        let items = [ProviderItemData(id: "openai", name: "OpenAI", isBuiltIn: true),
                     ProviderItemData(id: "ollama", name: "Ollama", isBuiltIn: true),
                     ProviderItemData(id: "fluid", name: "Fluid", isBuiltIn: true)]
            + savedProviders.map { ProviderItemData(id: $0.id, name: $0.name, isBuiltIn: false) }
        cachedAddedProviderItems = addedProviderItems(from: items)
    }
    func saveSavedProviders() { saves += 1; refreshProviderItems() }
    func clearEditProviderDraft() {}
    func finishConfiguringProvider() { selectedProviderID = settings.selectedProviderID }
    func refreshVerifiedProviders() {}
    func selectSoleVerifiedProviderIfNeeded() {}
}

@main enum ProviderSetupBoundaryTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        let vm = AIEnhancementSettingsViewModel()
        vm.refreshProviderItems()
        check(vm.cachedAddedProviderItems.isEmpty, "Fresh catalog stays hidden")
        var draft = ProviderSetupDraft(name: "Local", baseURL: "http://localhost:1234/v1", model: "tiny")
        check(draft.isValid && vm.saves == 0, "Editing a valid draft has no persistence effects")
        draft.baseURL = "file:///tmp/model"
        check(!draft.isValid && !vm.addProvider(draft), "Reject non-HTTP endpoints without persistence")
        draft.baseURL = "https://user:secret@example.com"
        check(!draft.isValid, "Reject credentials embedded in URL")
        draft.baseURL = "http://localhost:1234/v1"
        draft.apiKey = "test-key"
        vm.failKeychain = true
        check(!vm.addProvider(draft) && vm.savedProviders.isEmpty && vm.providerAPIKeys.isEmpty && vm.saves == 0,
              "Keychain failure keeps records, keys, and model maps unchanged")
        vm.failKeychain = false
        check(vm.addProvider(draft) && vm.savedProviders.count == 1, "Explicit Add saves a custom provider")
        check(vm.settings.selectedProviderID == "fluid" && vm.selectedModelByProvider["fluid"] == "mini", "Adding does not change current route/model")
        check(vm.addProvider(draft) && vm.savedProviders.count == 2, "Same display name cannot overwrite another provider")
        check(vm.cachedAddedProviderItems.count == 2, "Saved custom providers appear without verification")
        let builtIn = ProviderSetupDraft(providerID: "ollama", name: "Ollama", baseURL: "http://localhost:11434/v1")
        check(vm.addProvider(builtIn), "Keyless local provider can be added")
        check(!vm.addProvider(builtIn), "Duplicate built-in Add is rejected")
        check(vm.cachedAddedProviderItems.contains { $0.id == "ollama" }, "Keyless provider remains visible via explicit membership")
        vm.providerAPIKeys["openai"] = "expired-key"
        vm.refreshProviderItems()
        check(vm.cachedAddedProviderItems.contains { $0.id == "openai" }, "Unverified legacy credentials remain discoverable")
        vm.providerAPIKeys.removeValue(forKey: "openai")
        vm.settings.dictationPromptConfigurations["legacy"] = .init(providerID: "openai")
        vm.refreshProviderItems()
        check(vm.cachedAddedProviderItems.contains { $0.id == "openai" }, "Referenced provider stays visible after credentials disappear")
        vm.isFetchingModels = true
        check(!vm.addProvider(draft), "In-flight editor request blocks another Add")
        let source = try String(contentsOfFile: "Sources/Fluid/UI/AISettingsView+AIConfiguration.swift", encoding: .utf8)
        let manager = source.components(separatedBy: "private var externalProviderManager: some View")[1]
            .components(separatedBy: "private var legacyAIConfigurationCard")[0]
        check(!manager.contains("Use for shortcut") && !manager.contains("Edit details"), "External manager has no duplicate editor or shortcut assignment action")
        check(source.contains(".onSubmit {") && source.contains("self.viewModel.addNewModel()"), "Manual model input retains Enter-to-add behavior")
        check(source.contains(".accessibilityLabel(\"Add model\")"), "Model add button remains accessible")
        check(source.contains("if isCustom || managementLayout"), "Built-in management exposes removal")
        let removal = AIEnhancementSettingsViewModel()
        removal.providerAPIKeys = ["openai": "remove-key", "other": "keep-key"]
        removal.settings.dictationPromptConfigurations = [
            "affected": .init(providerID: "openai"),
            "unrelated": .init(providerID: "other"),
        ]
        removal.settings.rewriteModeSelectedProviderID = "openai"
        removal.settings.rewriteModeSelectedModel = "old"
        removal.settings.commandModeSelectedProviderID = "other"
        removal.settings.commandModeSelectedModel = "keep-model"
        removal.availableModelsByProvider = ["openai": ["old"], "other": ["keep"]]
        removal.selectedModelByProvider["openai"] = "old"
        UserDefaults.standard.set(["openai", "other"], forKey: AIEnhancementSettingsViewModel.addedProviderIDsKey)
        let before = removal.settings.dictationPromptConfigurations
        removal.failKeychain = true
        check(!removal.deleteCurrentProvider(), "Failed credential removal must fail the operation")
        check(removal.providerAPIKeys["openai"] == "remove-key" && removal.saves == 0, "Failed removal restores keys without saving provider changes")
        check(removal.settings.dictationPromptConfigurations == before, "Failed removal preserves assignments")
        check(UserDefaults.standard.stringArray(forKey: AIEnhancementSettingsViewModel.addedProviderIDsKey) == ["openai", "other"], "Failed removal preserves explicit membership")
        removal.failKeychain = false
        removal.isFetchingModels = true
        check(!removal.deleteCurrentProvider(), "Busy editor cannot remove a provider")
        removal.isFetchingModels = false
        check(removal.deleteCurrentProvider(), "Built-in removal succeeds")
        check(removal.settings.selectedProviderID == "fluid" && removal.settings.selectedModel == "mini", "Removing another provider preserves the default")
        check(removal.settings.dictationPromptConfigurations["affected"]?.providerID == "", "Removed provider cannot remain referenced")
        check(removal.settings.dictationPromptConfigurations["affected"]?.shortcut == "keep-shortcut", "Removal preserves hotkeys")
        check(removal.settings.dictationPromptConfigurations["unrelated"] == before["unrelated"], "Unrelated prompt assignment is unchanged")
        check(removal.settings.rewriteModeSelectedProviderID.isEmpty && removal.settings.rewriteModeSelectedModel == nil, "Affected rewrite route is cleared")
        check(removal.settings.commandModeSelectedProviderID == "other" && removal.settings.commandModeSelectedModel == "keep-model", "Unrelated command route is unchanged")
        check(removal.providerAPIKeys == ["other": "keep-key"] && removal.availableModelsByProvider["other"] == ["keep"], "Unrelated provider credentials and models survive")
        check(!removal.cachedAddedProviderItems.contains { $0.id == "openai" }, "Removed built-in disappears from added providers")
        removal.selectedProviderID = "ollama"
        removal.settings.selectedProviderID = "ollama"
        check(removal.deleteCurrentProvider() && removal.settings.selectedProviderID.isEmpty && removal.settings.selectedModel == nil, "Removing the default clears its model without selecting another provider")
        removal.selectedProviderID = "fluid"
        check(!removal.deleteCurrentProvider(), "External provider removal cannot remove private AI")
        let closing = AIEnhancementSettingsViewModel()
        closing.providerAPIKeys["openai"] = "edited-key"
        closing.managedOriginalKey = "edited-key"
        closing.failKeychain = true
        check(closing.saveManagedProviderBeforeClosing("openai") && closing.keySaves == 0, "Unchanged key closes without any Keychain write, even if writes would fail")
        closing.managedOriginalKey = "old-key"
        closing.failKeychain = true
        check(!closing.saveManagedProviderBeforeClosing("openai"), "Keychain failure keeps Manage open")
        check(closing.providerAPIKeys["openai"] == "edited-key" && closing.settings.selectedProviderID == "fluid", "Failed close preserves the draft and default")
        closing.failKeychain = false
        check(closing.saveManagedProviderBeforeClosing("openai") && closing.persistedKeys["openai"] == "edited-key", "Done persists an edited key without verification or model refresh")
        let savedCount = closing.keySaves
        closing.selectedProviderID = "fluid"
        check(closing.saveManagedProviderBeforeClosing("openai") && closing.keySaves == savedCount, "Removal cleanup must not save a different selected provider")
        closing.selectedProviderID = "ollama"
        check(closing.saveManagedProviderBeforeClosing("ollama") && closing.keySaves == savedCount, "Keyless provider close does not touch Keychain")
        closing.isTestingConnection = true
        check(!closing.saveManagedProviderBeforeClosing("ollama"), "Busy editor cannot dismiss")
        check(manager.contains(".interactiveDismissDisabled()"), "Interactive dismissal cannot bypass failed persistence")
        let historySource = try String(contentsOfFile: "Sources/Fluid/UI/TranscriptionHistoryView.swift", encoding: .utf8)
        let audioRequest = historySource.components(separatedBy: "private struct AudioAvailabilityRequest")[1]
            .components(separatedBy: "private var filteredEntries")[0]
        check(!audioRequest.contains("selectedEntry") && !audioRequest.contains("selectedID"), "Row selection cannot restart audio scans")
        print("Passed \(count) provider setup assertions")
    }
}
