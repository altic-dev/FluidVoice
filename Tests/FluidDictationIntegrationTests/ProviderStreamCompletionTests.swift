@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class ProviderStreamCompletionTests: XCTestCase {
    private enum Wire: String, CaseIterable { case responses, anthropic, gemini }

    func testCompletedStreamsDeliverAllText() async throws {
        for wire in Wire.allCases {
            let response = try await self.response(wire, scenario: "complete")
            XCTAssertEqual(response.content, "Finished.", wire.rawValue)
        }
    }

    func testPrematureEOFNeverDeliversPartialText() async {
        for wire in Wire.allCases {
            await self.assertRejected(wire, scenario: "incomplete")
        }
    }

    func testFailedTerminalStatesNeverDeliverPartialText() async {
        for wire in Wire.allCases {
            await self.assertRejected(wire, scenario: "failed")
        }
    }

    func testMalformedToolArgumentsRejectCompletedStreams() async {
        for wire in [Wire.responses, .anthropic] {
            await self.assertRejected(wire, scenario: "bad-tool")
        }
    }

    func testGeminiRequiresEveryReceivedCandidateToFinish() async {
        await self.assertRejected(.gemini, scenario: "unfinished-candidate")
    }

    private func assertRejected(_ wire: Wire, scenario: String) async {
        do {
            _ = try await self.response(wire, scenario: scenario)
            XCTFail("Unexpected successful \(wire.rawValue) \(scenario) response")
        } catch {
            guard error is LLMError else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    private func response(_ wire: Wire, scenario: String) async throws -> LLMClient.Response {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = LLMClient(session: session)
        let url = try XCTUnwrap(URL(string: "https://stream-fixture.test/\(wire.rawValue)/\(scenario)"))
        let request = URLRequest(url: url)
        let config = LLMClient.Config(messages: [["role": "user", "content": "Edit"]],
                                      model: "fixture",
                                      baseURL: "",
                                      apiKey: "")
        switch wire {
        case .responses: return try await client.processResponsesStreaming(request: request, config: config)
        case .anthropic: return try await client.processAnthropicStreaming(request: request, config: config)
        case .gemini: return try await client.processGeminiStreaming(request: request, config: config)
        }
    }
}

private final class CompletionFixtureProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "stream-fixture.test" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = self.request.url else { return }
        let wire = url.deletingLastPathComponent().lastPathComponent
        let scenario = url.lastPathComponent
        let events = Self.events(wire: wire, scenario: scenario)
        let body = events.map { "data: \($0)\n\n" }.joined()
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        ) else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(body.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func events(wire: String, scenario: String) -> [String] {
        switch wire {
        case "responses":
            let text = #"{"type":"response.output_text.delta","delta":"Finished."}"#
            if scenario == "incomplete" { return [text] }
            if scenario == "failed" { return [text, #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#] }
            let done = #"{"type":"response.completed","response":{"status":"completed"}}"#
            if scenario == "bad-tool" {
                return [#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","name":"test_tool","arguments":"{"}}"#, done]
            }
            return [text, done]
        case "anthropic":
            let text = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Finished."}}"#
            if scenario == "incomplete" { return [text] }
            if scenario == "failed" { return [text, #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#, #"{"type":"message_stop"}"#] }
            if scenario == "bad-tool" {
                return [#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","name":"test_tool","input":{}}}"#,
                        #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{"}}"#, #"{"type":"message_stop"}"#]
            }
            return [text, #"{"type":"message_stop"}"#]
        default:
            if scenario == "unfinished-candidate" {
                return [#"{"candidates":[{"index":0,"content":{"parts":[{"text":"Done"}]},"finishReason":"STOP"},{"index":1,"content":{"parts":[{"text":"Partial"}]}}]}"#]
            }
            let text = #"{"response":{"candidates":[{"content":{"parts":[{"text":"Finished."}]}}]}}"#
            if scenario == "incomplete" { return [text] }
            let reason = scenario == "failed" ? "MAX_TOKENS" : "STOP"
            return [text, "{\"response\":{\"candidates\":[{\"finishReason\":\"\(reason)\"}]}}"]
        }
    }
}
