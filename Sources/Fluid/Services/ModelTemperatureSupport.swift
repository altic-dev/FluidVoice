import Foundation

/// Remembers, per model ID, whether a model accepts the `temperature` parameter.
///
/// Filled from provider `/models` listings (see `ModelRepository.fetchModels`) and from
/// HTTP 400 rejections at request time (see `LLMClient.call`), so new models work without
/// editing the name list in `SettingsStore.isTemperatureUnsupported`. Keyed by model ID
/// alone: a model that rejects `temperature` on one provider rejects it on all of them.
final nonisolated class ModelTemperatureSupport: @unchecked Sendable {
    static let shared = ModelTemperatureSupport(defaults: .standard)

    private static let defaultsKey = "ModelTemperatureSupport"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// `true` = accepts `temperature`, `false` = rejects it, `nil` = unknown.
    func isSupported(_ model: String) -> Bool? {
        self.lock.withLock { self.stored()[Self.key(model)] }
    }

    func record(_ entries: [String: Bool]) {
        guard !entries.isEmpty else { return }
        self.lock.withLock {
            var stored = self.stored()
            for (model, supported) in entries {
                stored[Self.key(model)] = supported
            }
            self.defaults.set(stored, forKey: Self.defaultsKey)
        }
    }

    /// Reads temperature support from a `/models` response. Models without usable metadata are omitted.
    /// - OpenRouter lists accepted request parameters in `supported_parameters`.
    /// - Anthropic has no sampling capability, but every model that dropped `budget_tokens`
    ///   thinking (`capabilities.thinking.types.enabled`) also dropped `temperature`.
    static func entries(fromModelsResponse json: [String: Any]) -> [String: Bool] {
        guard let models = json["data"] as? [[String: Any]] else { return [:] }
        var entries: [String: Bool] = [:]
        for model in models {
            guard let id = model["id"] as? String else { continue }
            if let parameters = model["supported_parameters"] as? [String] {
                entries[id] = parameters.contains("temperature")
            } else if let capabilities = model["capabilities"] as? [String: Any],
                      let thinking = capabilities["thinking"] as? [String: Any],
                      let types = thinking["types"] as? [String: Any],
                      let budgetThinking = types["enabled"] as? [String: Any],
                      let supported = budgetThinking["supported"] as? Bool
            {
                entries[id] = supported
            }
        }
        return entries
    }

    private func stored() -> [String: Bool] {
        self.defaults.dictionary(forKey: Self.defaultsKey) as? [String: Bool] ?? [:]
    }

    private static func key(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
