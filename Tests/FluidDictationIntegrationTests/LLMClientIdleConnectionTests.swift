@testable import FluidVoice_Debug
import Foundation
import Network
import XCTest

// Regression tests for https://github.com/altic-dev/FluidVoice/issues/1016
// A pooled connection that sat idle can be dead on some network paths, and the first
// request on it stalls ~6.5 s before failing with -1005. After an idle gap the client
// must open a fresh connection; back-to-back requests must keep reusing one.

final class LLMClientIdleConnectionTests: XCTestCase {
    private var server: KeepAliveServer!

    override func setUpWithError() throws {
        self.server = try KeepAliveServer()
    }

    override func tearDown() {
        self.server.stop()
    }

    func testRequestAfterIdleGapOpensFreshConnection() async throws {
        let client = self.makeClient(idleConnectionLimit: 0.2)

        _ = try await client.call(self.config())
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = try await client.call(self.config())

        XCTAssertEqual(self.server.requestCount, 2)
        XCTAssertEqual(self.server.connectionCount, 2)
    }

    func testBackToBackRequestsReuseConnection() async throws {
        let client = self.makeClient(idleConnectionLimit: 60)

        _ = try await client.call(self.config())
        _ = try await client.call(self.config())

        XCTAssertEqual(self.server.requestCount, 2)
        XCTAssertEqual(self.server.connectionCount, 1)
    }

    // MARK: - Helpers

    private func makeClient(idleConnectionLimit: TimeInterval) -> LLMClient {
        LLMClient(
            session: URLSession(configuration: .ephemeral),
            idleConnectionLimit: idleConnectionLimit
        )
    }

    private func config() -> LLMClient.Config {
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Hello"]],
            model: "test-model",
            baseURL: "http://127.0.0.1:\(self.server.port)/v1",
            apiKey: "test",
            streaming: false
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5
        return config
    }
}

/// Minimal HTTP/1.1 server that keeps connections alive and counts how many it accepts.
private final class KeepAliveServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LLMClientIdleConnectionTests.server")
    private let lock = NSLock()
    private var accepted: [NWConnection] = []
    private var requests = 0
    private(set) var port: UInt16 = 0

    var connectionCount: Int {
        self.lock.withLock { self.accepted.count }
    }

    var requestCount: Int {
        self.lock.withLock { self.requests }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        self.listener = try NWListener(using: parameters)
        self.listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.accepted.append(connection) }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }

        let ready = DispatchSemaphore(value: 0)
        self.listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        self.listener.start(queue: self.queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = self.listener.port?.rawValue else {
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    func stop() {
        self.listener.cancel()
        self.lock.withLock { self.accepted }.forEach { $0.cancel() }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let request = Self.completeRequestLength(in: buffer) {
                buffer.removeFirst(request)
                self.lock.withLock { self.requests += 1 }
                self.respond(on: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func respond(on connection: NWConnection) {
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Hi."},"finish_reason":"stop"}]}"#
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in })
    }

    /// Byte length of the first full request (headers plus Content-Length body), or nil if incomplete.
    private static func completeRequestLength(in buffer: Data) -> Int? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headers = (String(bytes: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? "").lowercased()
        let contentLength = headers
            .components(separatedBy: "\r\n")
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let total = buffer.distance(from: buffer.startIndex, to: headerEnd.upperBound) + contentLength
        return buffer.count >= total ? total : nil
    }
}
