import Foundation

/// Presentation only. Picker tags, history records and API requests keep their original IDs.
enum ModelDisplayName {
    static func forID(_ modelID: String) -> String {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = PrivateAIModelRegistry.canonicalModelID(for: id) ?? id
        guard let model = PrivateAIModelRegistry.model(id: canonical), !model.displayName.isEmpty else { return id }
        return model.displayName.replacingOccurrences(of: "Fluid-1", with: "Fluid 1")
    }
}
