import Foundation

final class LocalAPIRouter {
    private struct RouteKey: Hashable {
        let method: String
        let path: String
    }

    private var routes: [RouteKey: LocalAPIRouteHandler] = [:]

    init() {
        self.register(method: "GET", path: "/v1/health", handler: HealthController())

        let history = HistoryAPIController()
        self.register(method: "GET", path: "/v1/history", handler: history)

        let dictionary = DictionaryAPIController()
        self.register(method: "GET", path: "/v1/dictionary/replacements", handler: dictionary)
        self.register(method: "POST", path: "/v1/dictionary/replacements", handler: dictionary)
        self.register(method: "GET", path: "/v1/dictionary/custom-words", handler: dictionary)
        self.register(method: "POST", path: "/v1/dictionary/custom-words", handler: dictionary)

        let inference = InferenceAPIController()
        self.register(method: "POST", path: "/v1/transcribe", handler: inference)
        self.register(method: "POST", path: "/v1/postprocess", handler: inference)
    }

    func register(method: String, path: String, handler: LocalAPIRouteHandler) {
        let key = RouteKey(method: method.uppercased(), path: path)
        self.routes[key] = handler
    }

    func route(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        let key = RouteKey(method: request.method.uppercased(), path: request.path)
        guard let handler = self.routes[key] else {
            if self.routes.keys.contains(where: { $0.path == request.path }) {
                return LocalAPI.error("Method not allowed.", status: 405)
            }
            return LocalAPI.error("Route not found.", status: 404)
        }
        return await handler.handle(request)
    }
}

private struct HealthController: LocalAPIRouteHandler {
    struct Body: Encodable {
        let status: String
        let version: String
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        guard request.method == "GET" else {
            return LocalAPI.error("Method not allowed.", status: 405)
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return LocalAPI.json(Body(status: "ok", version: version))
    }
}
