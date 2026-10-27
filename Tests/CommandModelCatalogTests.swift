import Combine
import CryptoKit
import Foundation

// Isolated settings and credential snapshots; production catalog, adapter, and metadata run unchanged.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    var writes: [String] = []
    func object(forKey key: String) -> Any? { self.values[key] }
    func set(_ value: Any?, forKey key: String) {
        self.values[key] = value
        self.writes.append(key)
    }
}

enum PrivateFeatures { static let privateAIProvider = true }
enum PrivateAIModelTask { case dictation }
struct PrivateAIProviderFeature {
    static let shared = PrivateAIProviderFeature()
    static let displayName = "Fluid Intelligence"
    let providerID = "fluid"
    let providerName = "Fluid Intelligence"
    func modelIDs() -> [String] { ["fluid-dictation"] }
    func modelIDs(for _: PrivateAIModelTask) -> [String] { self.modelIDs() }
}

enum PrivateAIIntegrationService {
    static func shouldHandleDictation(model: String) -> Bool { model == "fluid-dictation" }
}

enum PrivateAIModelRegistry {
    struct Model { let displayName: String }
    static func canonicalModelID(for modelID: String) -> String? { modelID == "friendly-id" ? "friendly-canonical" : nil }
    static func model(id: String) -> Model? { id == "friendly-canonical" ? Model(displayName: "Friendly Display") : nil }
}

final class SettingsStore: ObservableObject {
    struct SavedProvider: Equatable {
        let id: String
        let name: String
        let baseURL: String
        var models: [String]
    }

    let objectWillChange = ObservableObjectPublisher()
    var writes: [String] = []
    var commandModeSelectedProviderID = "" { didSet { self.writes.append("commandProvider") } }
    var commandModeSelectedModel: String? { didSet { self.writes.append("commandModel") } }
    var selectedProviderID = "openai" { didSet { self.writes.append("globalProvider") } }
    var selectedModel: String? = "global-model" { didSet { self.writes.append("globalModel") } }
    var selectedModelByProvider = ["openai": "global-model"] { didSet { self.writes.append("providerDefaults") } }
    var rewriteModeSelectedProviderID = "anthropic" { didSet { self.writes.append("rewriteProvider") } }
    var rewriteModeSelectedModel = "rewrite-model" { didSet { self.writes.append("rewriteModel") } }
    var verifiedProviderFingerprints: [String: String] = [:] { didSet { self.writes.append("verification") } }
    var availableModelsByProvider: [String: [String]] = [:] { didSet { self.writes.append("modelLists") } }
    var savedProviders: [SavedProvider] = [] { didSet { self.writes.append("savedProviders") } }
    var credentials: [String: String] = [:]
    var credentialSnapshots = 0
    var providerAPIKeys: [String: String] {
        self.credentialSnapshots += 1
        return self.credentials
    }
}

@main enum CommandModelCatalogTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        self.checks += 1
    }

    static func verify(_ settings: SettingsStore, id: String, baseURL: String, key: String) {
        let providerKey = ModelRepository.shared.providerKey(for: id)
        settings.credentials[providerKey] = key
        let digest = SHA256.hash(data: Data("\(baseURL)|\(key)".utf8))
        settings.verifiedProviderFingerprints[providerKey] = digest.map { String(format: "%02x", $0) }.joined()
    }

    static func fixture() -> SettingsStore {
        UserDefaults.standard.values = [:]
        UserDefaults.standard.writes = []
        let settings = SettingsStore()
        settings.savedProviders = [
            .init(id: "custom-a", name: "My Gateway", baseURL: "https://gateway.test/v1", models: ["saved-fallback"]),
            .init(id: "custom:custom-a", name: "Duplicate alias", baseURL: "https://gateway.test/v1", models: ["alias-fallback"]),
            .init(id: "custom-b", name: "Home Server", baseURL: "http://localhost:1235/v1", models: ["friendly-id"]),
            .init(id: "unverified", name: "Not Verified", baseURL: "https://unverified.test/v1", models: ["hidden-model"]),
        ]
        settings.availableModelsByProvider = [
            "openai": ["shared-model", " shared-model ", "chat-beta", "", "text-embedding-3", "rerank-v2", "moderation-v1", "tts-one", "whisper-one", "dall-e-3", "davinci", "fluid-dictation"],
            "custom:custom-a": ["shared-model", "custom-chat"],
            "custom-a": ["old-alias-model"],
            "fluid": ["fluid-dictation"],
        ]
        self.verify(settings, id: "openai", baseURL: ModelRepository.shared.defaultBaseURL(for: "openai"), key: "openai-key")
        self.verify(settings, id: "anthropic", baseURL: ModelRepository.shared.defaultBaseURL(for: "anthropic"), key: "anthropic-key")
        self.verify(settings, id: "custom-a", baseURL: "https://gateway.test/v1", key: "gateway-key")
        self.verify(settings, id: "custom-b", baseURL: "http://localhost:1235/v1", key: "")
        settings.verifiedProviderFingerprints["fluid"] = "ignored-private-verification"
        settings.writes = []
        return settings
    }

    static func main() {
        self.catalogIncludesEveryEligibleProvider()
        self.searchMatchesRawDisplayAndProviderNames()
        self.selectionChangesOnlyCommandMode()
        self.staleSelectionsHaveNoEffects()
        self.customAliasesResolveConsistently()
        self.verifiedKeylessAndCredentialPrecedenceStayCompatible()
        print("Command model catalog: \(self.checks) checks passed")
    }

    static func catalogIncludesEveryEligibleProvider() {
        let settings = self.fixture()
        let options = settings.commandModeModelCatalog()
        self.check(Set(options.map(\.providerID)) == Set(["openai", "anthropic", "custom-a", "custom-b"]), "Catalog includes all verified built-in and saved providers, excluding unverified and private providers")
        self.check(options.filter { $0.providerID == "openai" }.map(\.modelID) == ["shared-model", "chat-beta"], "Unsupported, empty, and duplicate models do not appear")
        self.check(options.filter { $0.providerID == "custom-a" }.map(\.modelID) == ["shared-model", "custom-chat"], "Canonical configured models take precedence over stale alias and saved fallback lists")
        self.check(options.contains { $0.providerID == "custom-b" && $0.modelID == "friendly-id" && $0.displayName == "Friendly Display" }, "Saved custom model lists and existing display names are used when no fetched list exists")
        self.check(options.contains { $0.providerID == "anthropic" && $0.modelID == "claude-sonnet-4-20250514" }, "Built-in fallback comes from the existing repository catalog")
        let shared = options.filter { $0.modelID == "shared-model" }
        self.check(shared.count == 2 && Set(shared.map(\.id)).count == 2, "The same model on different providers has distinct row identities")
        self.check(Set(options.map(\.id)).count == options.count, "Custom provider aliases cannot duplicate options")
        self.check(settings.credentialSnapshots == 1, "One catalog refresh reads only one credential snapshot")
        self.check(settings.writes.isEmpty && UserDefaults.standard.writes.isEmpty, "Building the catalog never changes settings or verification")
        let trickyA = CommandModelOption(providerID: "a", providerName: "A", modelID: "bc:d", displayName: "x")
        let trickyB = CommandModelOption(providerID: "ab", providerName: "B", modelID: "c:d", displayName: "x")
        self.check(trickyA.id != trickyB.id, "Composite identity remains collision-free when IDs contain separators")
    }

    static func searchMatchesRawDisplayAndProviderNames() {
        let settings = self.fixture()
        let options = settings.commandModeModelCatalog()
        self.check(CommandModelCatalog.filtered(options, query: "  \n ") == options, "Empty search preserves the full catalog and its order")
        self.check(CommandModelCatalog.filtered(options, query: "CHAT-BETA").map(\.modelID) == ["chat-beta"], "Search matches raw model IDs case-insensitively")
        self.check(CommandModelCatalog.filtered(options, query: "friendly display").map(\.modelID) == ["friendly-id"], "Search matches a model's display name")
        self.check(CommandModelCatalog.filtered(options, query: "MY GATEWAY").allSatisfy { $0.providerID == "custom-a" }, "Search matches custom provider names case-insensitively")
        self.check(CommandModelCatalog.filtered(options, query: "gateway shared").map(\.providerID) == ["custom-a"], "Search terms can span provider and model names")
        self.check(CommandModelCatalog.filtered(options, query: "custom-b").map(\.modelID) == ["friendly-id"], "Search also matches raw provider IDs")
        self.check(CommandModelCatalog.filtered(options, query: "missing model").isEmpty, "No match does not fall back to unrelated models")
        self.check(settings.credentialSnapshots == 1 && settings.writes.isEmpty, "Typing in search only filters the immutable snapshot")
    }

    static func selectionChangesOnlyCommandMode() {
        let settings = self.fixture()
        let option = settings.commandModeModelCatalog().first { $0.providerID == "custom-a" && $0.modelID == "custom-chat" }
        guard let option else { preconditionFailure("Verified fixture option missing") }
        let fingerprints = settings.verifiedProviderFingerprints
        let modelLists = settings.availableModelsByProvider
        let saved = settings.savedProviders
        self.check(settings.commandModeLinkedToGlobal, "Legacy linked mode starts enabled")
        self.check(settings.selectCommandModeModel(option), "A verified catalog row can be selected while linked")
        self.check(settings.commandModeSelectedProviderID == "custom-a" && settings.commandModeSelectedModel == "custom-chat" && !settings.commandModeLinkedToGlobal, "Selection sets provider and model together, then uses Command Mode's local route")
        self.check(settings.effectiveCommandModeProviderID == "custom-a" && settings.effectiveCommandModeSelectedModel == "custom-chat", "The effective route resolves to the chosen pair")
        self.check(settings.selectedProviderID == "openai" && settings.selectedModel == "global-model" && settings.selectedModelByProvider == ["openai": "global-model"], "Dictation and provider defaults stay unchanged")
        self.check(settings.rewriteModeSelectedProviderID == "anthropic" && settings.rewriteModeSelectedModel == "rewrite-model", "Edit Mode stays unchanged")
        self.check(settings.verifiedProviderFingerprints == fingerprints && settings.availableModelsByProvider == modelLists && settings.savedProviders == saved, "Selection never modifies verification or configured model lists")
        self.check(settings.writes == ["commandProvider", "commandModel"] && UserDefaults.standard.writes == ["CommandModeLinkedToGlobal"], "Only the three local Command Mode settings are written")
    }

    static func staleSelectionsHaveNoEffects() {
        for change in ["unverified", "key changed", "URL changed", "model removed", "provider removed"] {
            let settings = self.fixture()
            guard let option = settings.commandModeModelCatalog().first(where: { $0.providerID == "custom-a" }) else { preconditionFailure("Missing fixture option") }
            switch change {
            case "unverified": settings.verifiedProviderFingerprints.removeValue(forKey: "custom:custom-a")
            case "key changed": settings.credentials["custom:custom-a"] = "replacement-key"
            case "URL changed": settings.savedProviders = [.init(id: "custom-a", name: "Changed", baseURL: "https://changed.test/v1", models: [])]
            case "model removed": settings.availableModelsByProvider["custom:custom-a"] = ["replacement-model"]
            default: settings.savedProviders = []
            }
            settings.writes = []
            self.check(!settings.selectCommandModeModel(option), "A stale selection is rejected after \(change)")
            self.check(settings.commandModeSelectedProviderID.isEmpty && settings.commandModeSelectedModel == nil && settings.commandModeLinkedToGlobal, "Rejected \(change) selection leaves the active route untouched")
            self.check(settings.writes.isEmpty && UserDefaults.standard.writes.isEmpty, "Rejected \(change) selection has no settings writes")
        }
        let settings = self.fixture()
        for model in ["text-embedding-3", "whisper-one", "missing", ""] {
            let forged = CommandModelOption(providerID: "openai", providerName: "OpenAI", modelID: model, displayName: model)
            self.check(!settings.selectCommandModeModel(forged), "Unsupported or invented model rows cannot select a route")
        }
        self.check(settings.writes.isEmpty && UserDefaults.standard.writes.isEmpty, "Invalid model attempts leave all persisted settings unchanged")
    }

    static func customAliasesResolveConsistently() {
        let settings = self.fixture()
        self.check(settings.isCommandModeProviderVerified("custom:custom-a"), "Canonical custom-provider aliases verify against their saved URL and credentials")
        self.check(settings.commandModeModels(for: "custom:custom-a") == settings.commandModeModels(for: "custom-a"), "Canonical and raw provider IDs share deterministic model resolution")
        let alias = CommandModelOption(providerID: "custom:custom-a", providerName: "Old label", modelID: "custom-chat", displayName: "Old display")
        self.check(settings.selectCommandModeModel(alias) && settings.commandModeSelectedProviderID == "custom-a", "Alias selection resolves to the currently registered provider identity")
        settings.availableModelsByProvider.removeValue(forKey: "custom:custom-a")
        self.check(settings.commandModeModels(for: "custom-a") == ["old-alias-model"], "A legacy raw-key model list remains usable when the canonical list is absent")
    }

    static func verifiedKeylessAndCredentialPrecedenceStayCompatible() {
        let settings = self.fixture()
        settings.savedProviders.append(.init(id: "keyless", name: "Verified keyless", baseURL: "https://keyless.test/v1", models: ["keyless-chat"]))
        self.verify(settings, id: "keyless", baseURL: "https://keyless.test/v1", key: "")
        self.check(settings.commandModeModelCatalog().contains { $0.providerID == "keyless" }, "An already verified keyless remote server remains eligible")
        settings.credentials["custom-a"] = "raw-key-takes-precedence"
        self.check(!settings.commandModeModelCatalog().contains { $0.providerID == "custom-a" }, "Verification uses the same exact-ID credential precedence as requests")
        settings.savedProviders.append(.init(id: "custom:raw-only", name: "Canonical registration", baseURL: "https://raw.test/v1", models: ["raw-chat"]))
        self.verify(settings, id: "custom:raw-only", baseURL: "https://raw.test/v1", key: "raw-secret")
        settings.credentials["raw-only"] = settings.credentials.removeValue(forKey: "custom:raw-only")
        self.check(!settings.commandModeModelCatalog().contains { $0.providerID == "custom:raw-only" }, "Canonical registration cannot verify with a raw alias that getAPIKey would not send")
        settings.credentials["custom:raw-only"] = "raw-secret"
        self.check(settings.commandModeModelCatalog().contains { $0.providerID == "custom:raw-only" }, "Canonical registration becomes eligible with the actual request credential")
    }
}
