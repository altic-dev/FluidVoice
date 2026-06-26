@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class LLMClientThinkingTagTests: XCTestCase {
    private let client = LLMClient.shared

    // MARK: - Chat-completions message parser

    func testMessageResponseDropsContentThatIsAllThinking() {
        let message: [String: Any] = ["content": "<think>reasoning</think>"]

        let response = self.client.parseMessageResponse(message)

        XCTAssertTrue(response.content.isEmpty, "All-thinking replies must not leak raw <think> content downstream")
        XCTAssertEqual(response.thinking, "reasoning")
    }

    func testMessageResponseKeepsContentAfterThinking() {
        let message: [String: Any] = ["content": "<think>reasoning</think>Hello there"]

        let response = self.client.parseMessageResponse(message)

        XCTAssertEqual(response.content, "Hello there")
        XCTAssertEqual(response.thinking, "reasoning")
    }

    func testMessageResponseLeavesPlainContentUnchanged() {
        let message: [String: Any] = ["content": "Hello there"]

        let response = self.client.parseMessageResponse(message)

        XCTAssertEqual(response.content, "Hello there")
        XCTAssertNil(response.thinking)
    }

    // MARK: - Responses API parser

    func testResponsesResponseDropsContentThatIsAllThinking() throws {
        let json = self.responsesPayload(text: "<think>reasoning</think>")

        let response = try self.client.parseResponsesResponse(json)

        XCTAssertTrue(response.content.isEmpty, "All-thinking replies must not leak raw <think> content downstream")
        XCTAssertEqual(response.thinking, "reasoning")
    }

    func testResponsesResponseKeepsContentAfterThinking() throws {
        let json = self.responsesPayload(text: "<think>reasoning</think>Hello there")

        let response = try self.client.parseResponsesResponse(json)

        XCTAssertEqual(response.content, "Hello there")
        XCTAssertEqual(response.thinking, "reasoning")
    }

    // MARK: - Helpers

    private func responsesPayload(text: String) -> [String: Any] {
        let part: [String: Any] = ["type": "output_text", "text": text]
        let message: [String: Any] = ["type": "message", "content": [part]]
        return ["output": [message]]
    }
}
