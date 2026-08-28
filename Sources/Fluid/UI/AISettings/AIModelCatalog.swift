import Foundation

enum AIModelCatalog {
    struct Addition: Equatable {
        let modelID: String
        let models: [String]
    }

    static func merged(
        discoveredModels: [String],
        customModels: [String]
    ) -> [String] {
        self.normalized(discoveredModels + customModels)
    }

    static func adding(_ enteredModel: String, to models: [String]) -> Addition? {
        guard let modelID = self.normalized([enteredModel]).first else { return nil }
        return Addition(
            modelID: modelID,
            models: self.normalized(models + [modelID])
        )
    }

    static func normalized(_ models: [String]) -> [String] {
        var seen: Set<String> = []
        return models.compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    static func migratedLegacyCustomModels(
        cachedModelsByProvider: [String: [String]],
        savedModelsByProvider: [String: [String]]
    ) -> [String: [String]] {
        var migrated: [String: [String]] = [:]

        func providerKey(_ providerID: String) -> String {
            let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            let lower = trimmed.lowercased()
            if ModelRepository.shared.isBuiltIn(lower) {
                return lower
            }
            return trimmed.hasPrefix("custom:") ? trimmed : "custom:\(trimmed)"
        }

        func appendedManualModels(_ models: [String]) -> [String] {
            let normalizedInOrder = models
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard normalizedInOrder.count > 1,
                  let firstAppendedIndex = (1..<normalizedInOrder.count).first(where: {
                      normalizedInOrder[$0] < normalizedInOrder[$0 - 1]
                  })
            else {
                return []
            }
            return self.normalized(Array(normalizedInOrder[firstAppendedIndex...]))
        }

        for source in [cachedModelsByProvider, savedModelsByProvider] {
            for (providerID, models) in source {
                let key = providerKey(providerID)
                let appendedModels = appendedManualModels(models)
                if !key.isEmpty, !appendedModels.isEmpty {
                    migrated[key] = self.merged(
                        discoveredModels: migrated[key] ?? [],
                        customModels: appendedModels
                    )
                }
            }
        }

        return migrated
    }
}
