import Foundation

extension AIEnhancementSettingsViewModel {
    static let addedProviderIDsKey = "AISettingsAddedProviderIDs"

    /// Keep legacy connections discoverable even when their verification or credentials expire.
    func addedProviderItems(from items: [ProviderItemData]) -> [ProviderItemData] {
        let explicit = Set(UserDefaults.standard.stringArray(forKey: Self.addedProviderIDsKey) ?? [])
        let referenced = Set(self.settings.dictationPromptConfigurations.values.map(\.providerID))
        return items.filter { item in
            guard item.id != PrivateAIProviderFeature.shared.providerID else { return false }
            let key = self.providerKey(for: item.id)
            return !item.isBuiltIn || explicit.contains(item.id) || referenced.contains(item.id)
                || self.settings.selectedProviderID == item.id
                || !self.providerAPIKey(for: item.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || self.settings.verifiedProviderFingerprints[key] != nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Saves credentials first. Failure keeps the form open and creates no provider/model record.
    /// Does not select a provider, change shortcuts, fetch models, or start a network request.
    func addProvider(_ draft: ProviderSetupDraft) -> Bool {
        guard draft.isValid, !self.isTestingConnection, !self.isFetchingModels else { return false }
        let builtIn = !draft.providerID.isEmpty && ModelRepository.shared.isBuiltIn(draft.providerID)
        guard draft.providerID.isEmpty || builtIn else { return false }
        guard !builtIn || !self.cachedAddedProviderItems.contains(where: { $0.id == draft.providerID }) else { return false }
        let models = draft.trimmedModel.isEmpty ? (builtIn ? ModelRepository.shared.defaultModels(for: draft.providerID) : []) : [draft.trimmedModel]
        let provider = SettingsStore.SavedProvider(name: draft.trimmedName, baseURL: draft.trimmedBaseURL, models: models)
        let id = builtIn ? draft.providerID : provider.id
        let key = self.providerKey(for: id)
        let previousKeys = self.providerAPIKeys
        let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            self.updateProviderAPIKey(apiKey, for: id)
            guard self.saveProviderAPIKeys(invalidating: id) else {
                self.providerAPIKeys = previousKeys
                self.refreshProviderItems()
                return false
            }
        }
        if !builtIn { self.savedProviders.append(provider) }
        self.availableModelsByProvider[key] = models
        self.selectedModelByProvider[key] = models.first ?? ""
        var added = Set(UserDefaults.standard.stringArray(forKey: Self.addedProviderIDsKey) ?? [])
        added.insert(id)
        UserDefaults.standard.set(added.sorted(), forKey: Self.addedProviderIDsKey)
        self.saveSavedProviders()
        return true
    }
}
