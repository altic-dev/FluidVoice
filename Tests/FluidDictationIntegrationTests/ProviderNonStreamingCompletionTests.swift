@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class ProviderNonStreamingCompletionTests: XCTestCase {
    private enum Wire: String, CaseIterable {
        case anthropic
        case gemini

        var protocolKind: OfficialProviderAuth.WireProtocol {
            self == .anthropic ? .anthropicMessages : .geminiCodeAssist
        }
    }

    func testCompletedNonStreamingResponsesDeliverText() async throws {
        for wire in Wire.allCases {
            let response = try await self.response(wire, scenario: "complete")
            XCTAssertEqual(response.content, "Finished.", wire.rawValue)
        }
    }

    func testTruncatedNonStreamingResponsesRejectPartialText() async {
        for wire in Wire.allCases {
            await self.assertRejected(wire, scenario: "truncated")
        }
    }

    func testMissingCompletionAndProviderFailuresRejectPartialText() async {
        for wire in Wire.allCases {
            for scenario in ["missing-reason", "failed", "provider-error"] {
                await self.assertRejected(wire, scenario: scenario)
            }
        }
    }

    func testMalformedToolsRejectOtherwiseCompletedResponses() async {
        for wire in Wire.allCases {
            await self.assertRejected(wire, scenario: "bad-tool")
        }
    }

    func testCompletedNonStreamingToolsPreserveArguments() async throws {
        for wire in Wire.allCases {
            let response = try await self.response(wire, scenario: "tool")
            let call = try XCTUnwrap(response.toolCalls.first)
            XCTAssertEqual(response.toolCalls.count, 1)
            XCTAssertEqual(call.name, "shell")
            XCTAssertEqual(call.arguments["command"] as? String, "ls")
        }
    }

    func testGeminiRejectsAnUnfinishedAdditionalCandidate() async {
        await self.assertRejected(.gemini, scenario: "unfinished-candidate")
    }

    private func assertRejected(_ wire: Wire, scenario: String) async {
        do {
            _ = try await self.response(wire, scenario: scenario)
            XCTFail("Unexpected successful \(wire.rawValue) \(scenario) response")
        } catch {
            XCTAssertTrue(error is LLMError, "Unexpected error: \(error)")
        }
    }

    private func response(_ wire: Wire, scenario: String) async throws -> LLMClient.Response {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NonStreamingCompletionFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://completion-fixture.test/\(wire.rawValue)/\(scenario)"))
        let config = LLMClient.Config(
            messages: [["role": "user", "content": "Edit"]],
            model: "fixture",
            baseURL: "",
            apiKey: "",
            streaming: false
        )
        return try await LLMClient(session: session).processNonStreaming(
            request: URLRequest(url: url),
            config: config,
            wireProtocol: wire.protocolKind
        )
    }
}

private final class NonStreamingCompletionFixture: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "completion-fixture.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try XCTUnwrap(self.request.url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            let body = Self.body(
                wire: url.deletingLastPathComponent().lastPathComponent,
                scenario: url.lastPathComponent
            )
            let bytes = try JSONSerialization.data(withJSONObject: body)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: bytes)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func body(wire: String, scenario: String) -> [String: Any] {
        if scenario == "provider-error" { return ["error": ["message": "Unavailable"]] }
        if wire == "anthropic" {
            let reason = scenario == "truncated" ? "max_tokens" : scenario == "failed" ? "refusal" : "end_turn"
            var body: [String: Any] = [
                "stop_reason": reason,
                "content": [["type": "text", "text": "Finished."]],
            ]
            if scenario == "missing-reason" { body.removeValue(forKey: "stop_reason") }
            if ["tool", "bad-tool"].contains(scenario) {
                body["stop_reason"] = "tool_use"
                body["content"] = [[
                    "type": "tool_use", "id": "call-1", "name": "shell",
                    "input": scenario == "bad-tool" ? "invalid" : ["command": "ls"] as Any,
                ]]
            }
            return body
        }
        let reason = scenario == "truncated" ? "MAX_TOKENS" : scenario == "failed" ? "SAFETY" : "STOP"
        var candidate: [String: Any] = [
            "finishReason": reason,
            "content": ["parts": [["text": "Finished."]]],
        ]
        if scenario == "missing-reason" { candidate.removeValue(forKey: "finishReason") }
        if ["tool", "bad-tool"].contains(scenario) {
            candidate["content"] = ["parts": [["functionCall": [
                "name": "shell", "args": scenario == "bad-tool" ? "invalid" : ["command": "ls"] as Any,
            ]]]]
        }
        var candidates = [candidate]
        if scenario == "unfinished-candidate" {
            candidates.append(["content": ["parts": [["text": "Partial"]]]])
        }
        return ["response": ["candidates": candidates]]
    }
}
