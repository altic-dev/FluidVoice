import Foundation

@main
enum ProviderModelVerificationStoreTests {
    @MainActor
    static func main() {
        let defaults = UserDefaults(suiteName: "fluidvoice.model-verification-tests.\(UUID().uuidString)")!
        defer { defaults.removeObject(forKey: ProviderModelVerificationStore.defaultsKey) }
        let store = ProviderModelVerificationStore(defaults: defaults)
        func identity(_ model: String, key: String = "secret", endpoint: String = "https://example.com/v1", provider: String = "openrouter") -> String {
            ProviderModelVerificationStore.identity(providerID: provider, baseURL: endpoint, apiKey: key, model: model)
        }
        let first = identity("model-a")
        let second = identity("model-b")
        precondition(!store.contains(first))
        store.recordSuccess(first)
        precondition(store.contains(first) && !store.contains(second), "Changing models must not reuse another model's check")
        store.recordSuccess(second)
        precondition(store.contains(first) && store.contains(second), "Switching back should remember success")
        let reloaded = ProviderModelVerificationStore(defaults: defaults)
        precondition(reloaded.contains(first) && reloaded.contains(second), "Success must survive relaunch")
        precondition(!store.contains(identity("model-a", key: "changed")))
        precondition(!store.contains(identity("model-a", endpoint: "https://other.example/v1")))
        precondition(!store.contains(identity("model-a", provider: "other-provider")))
        precondition(identity(" model-a ") == first)
        store.remove(first)
        precondition(!store.contains(first) && store.contains(second), "Failed recheck affects only its model identity")
        for index in 0..<300 {
            store.recordSuccess(identity("model-\(index)"), now: Date(timeIntervalSince1970: Double(index)))
        }
        let saved = defaults.dictionary(forKey: ProviderModelVerificationStore.defaultsKey)!
        precondition(saved.count == ProviderModelVerificationStore.maximumEntries)
        precondition(saved.keys.allSatisfy { $0.count == 64 && !$0.contains("secret") })
        precondition(!store.contains(identity("model-0")) && store.contains(identity("model-299")))
        defaults.set(["bad": Double.nan], forKey: ProviderModelVerificationStore.defaultsKey)
        precondition(!ProviderModelVerificationStore(defaults: defaults).contains(first))
        print("PASS: per-model persistence, model/key/endpoint/provider isolation, failure removal, bounded history and invalid data")
    }
}
