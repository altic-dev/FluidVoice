@testable import FluidVoice_Debug
import XCTest

// Regression tests for `LLMClient.stripThinkingTags`.
//
// Models that emit a proper <think>…</think> block can still leak a stray </think>
// later in their answer. The orphan pass (meant for Nemotron's no-opening-tag
// "thoughts</think>response" output) used to reclassify every character between the
// real close and the stray close as thinking, dropping it from the visible response.

@MainActor
final class StripThinkingTagsTests: XCTestCase {
    private let client = LLMClient.shared

    /// A stray closing tag after a real <think>…</think> block must not eat the
    /// answer text that precedes it. Previously "The literal " was moved into
    /// thinking and removed from the response.
    func testStrayCloseAfterRealThinkBlockKeepsContent() {
        let result = self.client.stripThinkingTags(
            "<think>reasoning here</think>The literal </think> tag is stray."
        )

        XCTAssertEqual(result.thinking, "reasoning here", "only the real think block is thinking")
        XCTAssertTrue(result.content.contains("The literal"), "content before the stray close must stay visible")
        XCTAssertTrue(result.content.contains("tag is stray"), "content after the stray close must stay visible")
    }

    /// Nemotron-style output has no opening tag and uses </think> as the separator:
    /// everything before it is thinking, everything after is content. This must keep
    /// working (the orphan pass is still applied when no opening tag was present).
    func testOrphanCloseWithoutOpeningTagStillSplits() {
        let result = self.client.stripThinkingTags("reasoning here</think>Hello world.")

        XCTAssertEqual(result.thinking, "reasoning here")
        XCTAssertEqual(result.content, "Hello world.")
    }

    /// The `<thinking>` variant of the Nemotron separator is handled the same way.
    func testOrphanCloseWithoutOpeningTagSupportsLongFormTag() {
        let result = self.client.stripThinkingTags("thoughts</thinking>response")

        XCTAssertEqual(result.thinking, "thoughts")
        XCTAssertEqual(result.content, "response")
    }

    /// A normal, well-formed <think>…</think> block is unchanged.
    func testProperThinkBlockIsUnchanged() {
        let result = self.client.stripThinkingTags("<think>reasoning here</think>Hello world.")

        XCTAssertEqual(result.thinking, "reasoning here")
        XCTAssertEqual(result.content, "Hello world.")
    }

    /// Plain content with no thinking tags at all is returned verbatim.
    func testPlainContentWithNoTagsIsUnchanged() {
        let result = self.client.stripThinkingTags("Just a normal response with no tags at all.")

        XCTAssertEqual(result.thinking, "")
        XCTAssertEqual(result.content, "Just a normal response with no tags at all.")
    }
}
