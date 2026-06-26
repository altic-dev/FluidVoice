import Foundation
import Network

@MainActor
final class LocalAPIServer {
    static let shared = LocalAPIServer()

    private let router = LocalAPIRouter()
    private let queue = DispatchQueue(label: "fluidvoice.local-api", qos: .utility)
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: LocalAPIConnectionHandler] = [:]
    private(set) var port: UInt16 = LocalAPI.defaultPort

    private init() {}

    func start() {
        let config = LocalAPI.Configuration.current
        guard config.enabled else {
            DebugLogger.shared.info("Local API disabled", source: "LocalAPIServer")
            return
        }

        if self.listener != nil {
            return
        }

        do {
            guard let port = NWEndpoint.Port(rawValue: config.port) else {
                DebugLogger.shared.error("Local API invalid port", source: "LocalAPIServer")
                return
            }

            let parameters = NWParameters.tcp

            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                guard Self.isLoopback(connection.endpoint) else {
                    connection.cancel()
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self else {
                        connection.cancel()
                        return
                    }

                    let handler = LocalAPIConnectionHandler(connection: connection, router: self.router)
                    let id = ObjectIdentifier(handler)
                    handler.onClose = { [weak self] in
                        Task { @MainActor in
                            self?.activeConnections[id] = nil
                        }
                    }
                    self.activeConnections[id] = handler
                    handler.start(on: self.queue)
                }
            }
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    self.handleState(state)
                }
            }

            self.port = config.port
            self.listener = listener
            listener.start(queue: self.queue)
        } catch {
            DebugLogger.shared.error("Local API failed to start: \(error.localizedDescription)", source: "LocalAPIServer")
        }
    }

    func stop() {
        for handler in self.activeConnections.values {
            handler.cancel()
        }
        self.activeConnections.removeAll()
        self.listener?.cancel()
        self.listener = nil
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            DebugLogger.shared.info("Local API listening on http://127.0.0.1:\(self.port)", source: "LocalAPIServer")
        case let .failed(error):
            DebugLogger.shared.error("Local API listener failed: \(error.localizedDescription)", source: "LocalAPIServer")
            self.listener?.cancel()
            self.listener = nil
        case .cancelled:
            self.listener = nil
        default:
            break
        }
    }

    private nonisolated static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }

        switch host {
        case let .name(name, _):
            return name.caseInsensitiveCompare("localhost") == .orderedSame
        case let .ipv4(address):
            return "\(address)" == "127.0.0.1"
        case let .ipv6(address):
            return "\(address)" == "::1"
        @unknown default:
            return false
        }
    }
}

@MainActor
private final class LocalAPIConnectionHandler {
    private let connection: NWConnection
    private let router: LocalAPIRouter
    private var buffer = Data()
    private var isClosed = false
    var onClose: (() -> Void)?

    init(connection: NWConnection, router: LocalAPIRouter) {
        self.connection = connection
        self.router = router
    }

    func start(on queue: DispatchQueue) {
        self.connection.start(queue: queue)
        self.receive()
    }

    func cancel() {
        self.close()
    }

    private func receive() {
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil || isComplete {
                    self.close()
                    return
                }

                if let data {
                    self.buffer.append(data)
                }

                guard self.buffer.count <= LocalAPI.maxRequestBytes else {
                    self.send(LocalAPI.error("Request too large.", status: 413))
                    return
                }

                switch self.parseRequestIfComplete() {
                case let .request(request):
                    let response = await self.router.route(request)
                    self.send(response)
                case let .failure(response):
                    self.send(response)
                case .incomplete:
                    self.receive()
                }
            }
        }
    }

    private func send(_ response: LocalAPI.Response) {
        let body = response.body
        var headers = response.headers
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "close"

        let statusLine = "HTTP/1.1 \(response.status) \(Self.reasonPhrase(for: response.status))\r\n"
        let headerLines = headers
            .map { "\($0.key): \($0.value)\r\n" }
            .sorted()
            .joined()
        var data = Data((statusLine + headerLines + "\r\n").utf8)
        data.append(body)

        self.connection.send(content: data, completion: .contentProcessed { [connection] _ in
            connection.cancel()
            Task { @MainActor [weak self] in
                self?.close()
            }
        })
    }

    private func close() {
        guard !self.isClosed else { return }
        self.isClosed = true
        self.connection.cancel()
        self.onClose?()
    }

    private enum ParsedRequest {
        case incomplete
        case request(LocalAPI.Request)
        case failure(LocalAPI.Response)
    }

    private func parseRequestIfComplete() -> ParsedRequest {
        guard let headerEnd = self.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return .incomplete
        }

        let headerData = self.buffer[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(LocalAPI.error("Malformed request.", status: 400))
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .incomplete }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            return .failure(LocalAPI.error("Malformed request.", status: 400))
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
            guard let parsedContentLength = Int(rawContentLength), parsedContentLength >= 0 else {
                return .failure(LocalAPI.error("Invalid Content-Length.", status: 400))
            }
            guard parsedContentLength <= LocalAPI.maxRequestBytes else {
                return .failure(LocalAPI.error("Request too large.", status: 413))
            }
            contentLength = parsedContentLength
        } else {
            contentLength = 0
        }

        let bodyStart = headerEnd.upperBound
        let requestEnd = bodyStart + contentLength
        guard requestEnd <= LocalAPI.maxRequestBytes else {
            return .failure(LocalAPI.error("Request too large.", status: 413))
        }
        guard self.buffer.count >= requestEnd else {
            return .incomplete
        }

        let body = Data(self.buffer[bodyStart..<requestEnd])
        let parsedTarget = Self.parseTarget(parts[1])
        return .request(LocalAPI.Request(
            method: parts[0].uppercased(),
            path: parsedTarget.path,
            query: parsedTarget.query,
            headers: headers,
            body: body
        ))
    }

    private static func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
        let base = target.hasPrefix("http") ? target : "http://127.0.0.1\(target)"
        guard let components = URLComponents(string: base) else {
            return (target, [:])
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard !item.name.isEmpty else { continue }
            query[item.name] = item.value ?? ""
        }

        return (components.path.isEmpty ? "/" : components.path, query)
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}
