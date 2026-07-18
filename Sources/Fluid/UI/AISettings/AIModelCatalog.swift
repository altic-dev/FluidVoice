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
}
