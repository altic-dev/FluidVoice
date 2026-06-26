import Foundation

enum LocalAPI {
    static let defaultPort: UInt16 = 47_733
    static let maxRequestBytes = 25 * 1024 * 1024

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

    static func boundedLimit(from request: Request, default defaultValue: Int = 100, maximum: Int = 1000) -> Int {
        guard let raw = request.query["limit"], let value = Int(raw) else {
            return defaultValue
        }
        return max(1, min(value, maximum))
    }
}

@MainActor
protocol LocalAPIRouteHandler {
    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response
}
