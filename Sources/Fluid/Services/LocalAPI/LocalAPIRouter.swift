import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import NIOFoundationEssentialsCompat

nonisolated struct LocalAPIRouter: HTTPResponder {
    typealias Context = BasicRequestContext

    private let responder: RouterResponder<Context>
    private let paths: Set<String>
    private let port: UInt16

    @MainActor
    init(
        port: UInt16 = LocalAPI.defaultPort,
        meetingStore: any MeetingSessionStoring = MeetingSessionStore.shared,
        liveTranscript: any MeetingLiveTranscriptProviding = MeetingCoordinatorLiveTranscriptProvider()
    ) {
        let meetings = MeetingAPIController(store: meetingStore, liveTranscript: liveTranscript)
        let dictionary = DictionaryAPIController()
        let inference = InferenceAPIController()
        let routes: [(HTTPRequest.Method, String, any LocalAPIRouteHandler)] = [
            (.get, "/v1/health", HealthController()),
            (.get, "/v1/history", HistoryAPIController()),
            (.get, "/v1/meetings", meetings),
            (.get, "/v1/meetings/transcript", meetings),
            (.get, "/v1/meetings/live", meetings),
            (.get, "/v1/dictionary/replacements", dictionary),
            (.post, "/v1/dictionary/replacements", dictionary),
            (.get, "/v1/dictionary/custom-words", dictionary),
            (.post, "/v1/dictionary/custom-words", dictionary),
            (.post, "/v1/transcribe", inference),
            (.post, "/v1/postprocess", inference),
        ]

        let router = Router(context: Context.self)
        for (method, path, handler) in routes {
            router.on(RouterPath(path), method: method) { request, _ in
                try await Self.handle(request, with: handler)
            }
        }
        self.responder = router.buildResponder()
        self.paths = Set(routes.map { $0.1 })
        self.port = port
    }

    func respond(to request: Request, context: Context) async throws -> Response {
        // The HTTP/1 codec moves the Host header into :authority.
        let host = request.head.authority
        if request.headers.contains(where: { $0.name.canonicalName == "host" }) {
            return Self.makeResponse(LocalAPI.error("Host not allowed.", status: 403))
        }
        if let rejection = LocalAPI.untrustedRequestRejection(
            host: host,
            hasOrigin: request.headers.contains(.origin),
            port: self.port
        ) {
            return Self.makeResponse(rejection)
        }

        // Preserve the original URL decoding and exact path matching.
        let target = "http://127.0.0.1" + (request.head.path ?? "/")
        guard let components = URLComponents(string: target), self.paths.contains(components.path) else {
            return Self.makeResponse(LocalAPI.error("Route not found.", status: 404))
        }
        var head = request.head
        head.path = components.path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        var response = try await self.responder.respond(to: Request(head: head, body: request.body), context: context)
        if context.endpointPath == "NotFound" {
            response = Self.makeResponse(LocalAPI.error("Method not allowed.", status: 405))
        }
        if components.path == "/v1/meetings/live" {
            response.headers[.cacheControl] = "no-store"
        }
        return response
    }

    private static func handle(_ request: Request, with handler: any LocalAPIRouteHandler) async throws -> Response {
        if let length = request.headers[.contentLength], let count = UInt64(length),
           count > LocalAPI.maxRequestBytes {
            return Self.makeResponse(LocalAPI.error("Request too large.", status: 413))
        }

        let body: ByteBuffer
        do {
            body = try await request.body.collect(upTo: LocalAPI.maxRequestBytes)
        } catch is NIOTooManyBytesError {
            return Self.makeResponse(LocalAPI.error("Request too large.", status: 413))
        }

        var headers: [String: String] = [:]
        for field in request.headers {
            headers[field.name.canonicalName] = field.value
        }
        headers["host"] = request.head.authority

        var query: [String: String] = [:]
        if let target = request.head.path, let items = URLComponents(string: target)?.queryItems {
            for item in items where !item.name.isEmpty {
                query[item.name] = item.value
            }
        }
        let response = await handler.handle(LocalAPI.Request(
            method: request.method.rawValue,
            path: request.uri.path,
            query: query,
            headers: headers,
            body: Data(buffer: body)
        ))
        return Self.makeResponse(response)
    }

    private static func makeResponse(_ local: LocalAPI.Response) -> Response {
        var headers = HTTPFields()
        for (name, value) in local.headers {
            if let field = HTTPField.Name(name) {
                headers[field] = value
            }
        }
        var response = Response(
            status: .init(code: local.status),
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: local.body))
        )
        response.headers[.connection] = "close"
        // Hummingbird inserts Content-Length for known-size bodies, including zero.
        if local.status == 204 || local.status == 304 {
            response.headers[.contentLength] = nil
        }
        return response
    }
}

private struct HealthController: LocalAPIRouteHandler {
    struct Body: Encodable {
        let status: String
        let version: String
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return LocalAPI.json(Body(status: "ok", version: version))
    }
}
