import Foundation

/// Whether a model accepts images, per endpoint and model ID. Learned from model listings,
/// local server endpoints, and rejected requests that carried an image.
final nonisolated class ModelImageSupport: @unchecked Sendable {
    static let shared = ModelImageSupport(defaults: .standard)

    private static let defaultsKey = "ModelImageSupportByEndpoint"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var probed = Set<String>()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func isSupported(_ model: String, baseURL: String) -> Bool? {
        self.lock.withLock { self.stored()[ModelTemperatureSupport.key(model, baseURL: baseURL)] }
    }

    func record(_ entries: [String: Bool], baseURL: String) {
        guard !entries.isEmpty else { return }
        self.lock.withLock {
            var stored = self.stored()
            for (model, supported) in entries {
                stored[ModelTemperatureSupport.key(model, baseURL: baseURL)] = supported
            }
            self.defaults.set(stored, forKey: Self.defaultsKey)
        }
    }

    /// Reads image support from a model listing. Models without usable metadata are omitted.
    /// - OpenRouter: `architecture.input_modalities` contains "image".
    /// - Anthropic: `capabilities.image_input.supported`.
    /// - LM Studio: `models[].capabilities.vision` keyed by `key` (v1), or `type: "vlm"` (older v0 listings).
    static func entries(fromModelsResponse json: [String: Any]) -> [String: Bool] {
        var entries: [String: Bool] = [:]
        for model in json["data"] as? [[String: Any]] ?? [] {
            guard let id = model["id"] as? String else { continue }
            if let modalities = (model["architecture"] as? [String: Any])?["input_modalities"] as? [String] {
                entries[id] = modalities.contains("image")
            } else if let imageInput = (model["capabilities"] as? [String: Any])?["image_input"] as? [String: Any],
                      let supported = imageInput["supported"] as? Bool
            {
                entries[id] = supported
            } else if let type = model["type"] as? String, type == "llm" || type == "vlm" {
                entries[id] = type == "vlm"
            }
        }
        for model in json["models"] as? [[String: Any]] ?? [] {
            guard let key = model["key"] as? String, let type = model["type"] as? String, type == "llm" || type == "vlm" else { continue }
            entries[key] = (model["capabilities"] as? [String: Any])?["vision"] as? Bool ?? (type == "vlm")
        }
        return entries
    }

    /// Whether an error body from a request that carried an image says images aren't accepted.
    /// Text-only servers word this many ways, including rejecting non-string message content.
    static func isImageRejection(_ body: String) -> Bool {
        let text = body.lowercased()
        if ["too large", "too big", "exceed", "maximum size"].contains(where: text.contains) { return false }
        if ["image", "vision", "multimodal", "modalit"].contains(where: text.contains) { return true }
        return text.contains("content") && text.contains("string")
    }

    /// Ollama and LM Studio report vision support only on their native endpoints, not on `/v1/models`.
    /// Asks once per model per launch; a server that answers neither stays unknown.
    func probeLocalServer(model: String, baseURL: String) async {
        let key = ModelTemperatureSupport.key(model, baseURL: baseURL)
        let shouldProbe = self.lock.withLock { self.probed.insert(key).inserted }
        guard shouldProbe, let root = Self.localServerRoot(baseURL) else { return }

        if let capabilities = await Self.json(root.appendingPathComponent("api/show"), body: ["model": model])?["capabilities"] as? [String] {
            self.record([model: capabilities.contains("vision")], baseURL: baseURL)
            return
        }
        if let listing = await Self.json(root.appendingPathComponent("api/v1/models")) {
            let entries = Self.entries(fromModelsResponse: listing)
            if let supported = entries[model] {
                self.record([model: supported], baseURL: baseURL)
            }
        }
    }

    static func localServerRoot(_ baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local")
        else { return nil }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.hasSuffix("/v1") { path.removeLast(3) }
        components.path = path
        return components.url
    }

    // swiftlint:disable:next discouraged_optional_collection
    private static func json(_ url: URL, body: [String: Any]? = nil) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func stored() -> [String: Bool] {
        self.defaults.dictionary(forKey: Self.defaultsKey) as? [String: Bool] ?? [:]
    }
}
