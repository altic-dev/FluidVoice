@testable import FluidVoice_Debug
import Foundation
import XCTest

/// OpenAI-compatible streams key each tool call by `index` and split its arguments across chunks.
final class LLMClientStreamingToolCallTests: XCTestCase {
    func testParallelToolCallsAreParsedSeparately() async throws {
        let response = try await self.call(streaming: [
            #"{"choices":[{"index":0,"delta":{"role":"assistant","content":"Found 3 lists. Now let me get the reminders in each one."}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"execute_terminal_command","arguments":""}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"echo work\","}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"execute_terminal_command","arguments":""}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"purpose\":\"executing\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"command\":\"echo groceries\",\"purpose\":\"executing\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])

        XCTAssertEqual(response.content, "Found 3 lists. Now let me get the reminders in each one.")
        XCTAssertEqual(response.toolCalls.map(\.id), ["call_a", "call_b"])
        XCTAssertEqual(response.toolCalls.map { $0.getString("command") }, ["echo work", "echo groceries"])
    }

    func testSingleToolCallAfterTextIsParsed() async throws {
        let response = try await self.call(streaming: [
            #"{"choices":[{"index":0,"delta":{"content":"Checking."}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"execute_terminal_command","arguments":"{\"command\":"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"ls\",\"purpose\":\"checking\"}"}}]}}]}"#,
        ])

        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.id, "call_a")
        XCTAssertEqual(response.toolCalls.first?.getString("command"), "ls")
    }

    // MARK: - Helpers

    private func call(streaming events: [String]) async throws -> LLMClient.Response {
        StreamingToolCallURLProtocol.payload = events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingToolCallURLProtocol.self]
        let suiteName = "LLMClientStreamingToolCallTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = LLMClient(
            session: URLSession(configuration: configuration),
            temperatureSupport: ModelTemperatureSupport(defaults: defaults)
        )
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "List all reminders I have"]],
            model: "fixture-model",
            baseURL: "https://streaming-tool-call.test/v1",
            apiKey: "test",
            streaming: true,
            tools: [TerminalService.toolDefinition]
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5
        return try await client.call(config)
    }
}

private final class StreamingToolCallURLProtocol: URLProtocol {
    nonisolated(unsafe) static var payload = ""

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "streaming-tool-call.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
