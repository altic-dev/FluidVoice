import Foundation

nonisolated enum LocalAPI {
    static let defaultPort: UInt16 = 47_733
    static let maxRequestBytes = 500 * 1024 * 1024

    struct Configuration {
        let enabled: Bool
        let port: UInt16

        static var current: Configuration {
            let defaults = UserDefaults.standard
            let enabled: Bool
            if defaults.object(forKey: "LocalAPIEnabled") == nil {
                enabled = false
            } else {
                enabled = defaults.bool(forKey: "LocalAPIEnabled")
            }

            let rawPort = defaults.integer(forKey: "LocalAPIPort")
            let port = rawPort > 0 && rawPort <= Int(UInt16.max) ? UInt16(rawPort) : LocalAPI.defaultPort
            return Configuration(enabled: enabled, port: port)
        }
    }

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data

        init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    struct ErrorBody: Encodable {
        let error: String
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
        do {
            let body = try Self.encoder.encode(value)
            return Response(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: body
            )
        } catch {
            return Self.error("Failed to encode response.", status: 500)
        }
    }

    static func empty(status: Int = 204) -> Response {
        Response(status: status)
    }

    static func error(_ message: String, status: Int) -> Response {
        let body = (try? Self.encoder.encode(ErrorBody(error: message))) ?? Data()
        return Response(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }

    /// Blocks DNS rebinding. A loopback peer is not enough: a web page whose host name resolves to
    /// 127.0.0.1 also connects from loopback. So the Host header must name this server as loopback,
    /// and requests that carry Origin (sent by browsers, not by local CLI or agent clients) are refused.
    /// Returns the 403 response to send, or nil when the request may be routed.
    static func untrustedRequestRejection(host: String?, hasOrigin: Bool, port: UInt16) -> Response? {
        if hasOrigin {
            return self.error("Browser requests are not allowed.", status: 403)
        }
        let loopbackNames = ["127.0.0.1", "localhost", "[::1]"]
        var allowedHosts = Set(loopbackNames.map { "\($0):\(port)" })
        // On port 80, HTTP clients send Host without the port.
        if port == 80 {
            allowedHosts.formUnion(loopbackNames)
        }
        guard let host = host?.lowercased(), allowedHosts.contains(host) else {
            return Self.error("Host not allowed.", status: 403)
        }
        return nil
    }

    static func boundedLimit(from request: Request, default defaultValue: Int = 100, maximum: Int = 1000) -> Int {
        guard let raw = request.query["limit"], let value = Int(raw) else {
            return defaultValue
        }
        return max(1, min(value, maximum))
    }
}

@MainActor
protocol LocalAPIRouteHandler: Sendable {
    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response
}
