import Foundation

/// A local form value, never a live settings binding. Cancel simply discards it.
struct ProviderSetupDraft {
    var providerID = "" {
        didSet { if self.providerID != oldValue { self.invalidateFetchedModels() } }
    }

    var name = ""
    var baseURL = "" {
        didSet {
            if self.trimmedBaseURL != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                self.invalidateFetchedModels()
            }
        }
    }

    var apiKey = "" {
        didSet { if self.apiKey != oldValue { self.invalidateFetchedModels() } }
    }

    /// Direct assignments come from manual entry, even when the ID matches a fetched model.
    var model = "" {
        didSet { self.modelWasFetched = false }
    }

    var fetchedModels: [String] = []
    private var modelWasFetched = false

    init(providerID: String = "", name: String = "", baseURL: String = "", apiKey: String = "", model: String = "") {
        self.providerID = providerID
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    mutating func selectFetchedModel(_ model: String) {
        guard self.fetchedModels.contains(model) else { return }
        self.model = model
        self.modelWasFetched = true
    }

    @discardableResult
    mutating func applyFetchedModels(_ models: [String], for identity: [String]) -> Bool {
        guard self.connectionIdentity == identity else { return false }
        self.fetchedModels = Array(Set(models)).sorted()
        if self.model.isEmpty || self.modelWasFetched {
            let selected = self.fetchedModels.contains(self.model) ? self.model : (self.fetchedModels.first ?? "")
            self.model = selected
            self.modelWasFetched = !selected.isEmpty
        }
        return true
    }

    private mutating func invalidateFetchedModels() {
        self.fetchedModels = []
        if self.modelWasFetched { self.model = "" }
    }

    var connectionIdentity: [String] { [self.providerID, self.trimmedBaseURL, self.apiKey] }

    func modelsToSave(defaults: [String]) -> [String] {
        let models = self.fetchedModels.isEmpty ? defaults : self.fetchedModels
        guard !self.trimmedModel.isEmpty else { return models }
        return [self.trimmedModel] + models.filter { $0 != self.trimmedModel }
    }

    var trimmedName: String { self.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedModel: String { self.model.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedBaseURL: String { self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    var requiresAPIKey: Bool { !self.providerID.isEmpty && !["ollama", "lmstudio"].contains(self.providerID) }
    var isValid: Bool {
        guard !self.requiresAPIKey || !self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !self.trimmedName.isEmpty, let url = URL(string: self.trimmedBaseURL),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil
        else { return false }
        return true
    }
}
