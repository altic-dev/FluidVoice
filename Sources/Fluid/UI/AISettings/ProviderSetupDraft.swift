import Foundation

/// A local form value, never a live settings binding. Cancel simply discards it.
struct ProviderSetupDraft {
    var providerID = ""
    var name = ""
    var baseURL = ""
    var apiKey = ""
    var model = ""
    var fetchedModels: [String] = []

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
