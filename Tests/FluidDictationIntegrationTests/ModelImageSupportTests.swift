@testable import FluidVoice_Debug
import XCTest

// Command Mode sends screenshots only to models that accept images. Support is read from
// provider listings where they say, and otherwise learned when a request with an image is rejected.

final class ModelImageSupportTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.suiteName = "ModelImageSupportTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        super.tearDown()
    }

    // MARK: - Listings

    func testEntries_openRouterInputModalities() throws {
        let json = try self.json(#"""
        {"data": [
          {"id": "openai/gpt-4o", "architecture": {"input_modalities": ["text", "image"]}},
          {"id": "deepseek/deepseek-r1", "architecture": {"input_modalities": ["text"]}},
          {"id": "some/model-without-metadata"}
        ]}
        """#)

        XCTAssertEqual(ModelImageSupport.entries(fromModelsResponse: json), ["openai/gpt-4o": true, "deepseek/deepseek-r1": false])
    }

    func testEntries_anthropicImageInputCapability() throws {
        let json = try self.json(#"""
        {"data": [
          {"id": "claude-sonnet-5-5", "capabilities": {"image_input": {"supported": true}, "thinking": {"supported": true}}},
          {"id": "claude-text-only", "capabilities": {"image_input": {"supported": false}}}
        ]}
        """#)

        XCTAssertEqual(ModelImageSupport.entries(fromModelsResponse: json), ["claude-sonnet-5-5": true, "claude-text-only": false])
    }

    func testEntries_lmStudioListings() throws {
        let v1 = try self.json(#"""
        {"models": [
          {"type": "llm", "key": "google/gemma-4-26b-a4b", "capabilities": {"vision": true, "trained_for_tool_use": true}},
          {"type": "llm", "key": "deepseek/deepseek-r1", "capabilities": {"vision": false}},
          {"type": "embedding", "key": "nomic-embed-text"}
        ]}
        """#)
        let v0 = try self.json(#"{"data": [{"id": "qwen2-vl-7b-instruct", "type": "vlm"}, {"id": "llama-3.2-3b", "type": "llm"}]}"#)

        XCTAssertEqual(ModelImageSupport.entries(fromModelsResponse: v1), ["google/gemma-4-26b-a4b": true, "deepseek/deepseek-r1": false])
        XCTAssertEqual(ModelImageSupport.entries(fromModelsResponse: v0), ["qwen2-vl-7b-instruct": true, "llama-3.2-3b": false])
    }

    func testEntries_plainListingsRecordNothing() throws {
        let openAI = try self.json(#"{"data": [{"id": "gpt-4.1", "object": "model"}]}"#)
        let google = try self.json(#"{"models": [{"name": "models/gemini-2.5-pro"}]}"#)

        XCTAssertTrue(ModelImageSupport.entries(fromModelsResponse: openAI).isEmpty)
        XCTAssertTrue(ModelImageSupport.entries(fromModelsResponse: google).isEmpty)
    }

    // MARK: - Rejections

    func testImageRejection_matchesTextOnlyErrors() {
        XCTAssertTrue(ModelImageSupport.isImageRejection(#"{"error": {"message": "This model does not support image input"}}"#))
        XCTAssertTrue(ModelImageSupport.isImageRejection("Model does not support vision"))
        XCTAssertTrue(ModelImageSupport.isImageRejection("messages[3].content: expected a string, got an array"))
        XCTAssertTrue(ModelImageSupport.isImageRejection("Invalid content type: image_url is only supported by multimodal models"))
    }

    func testImageRejection_ignoresUnrelatedAndOversizedErrors() {
        XCTAssertFalse(ModelImageSupport.isImageRejection("Rate limit reached for requests"))
        XCTAssertFalse(ModelImageSupport.isImageRejection("Image exceeds the maximum allowed dimensions"))
        XCTAssertFalse(ModelImageSupport.isImageRejection("image too large: 21 MB"))
    }

    // MARK: - Local servers

    func testLocalServerRoot_stripsOpenAIPathOnlyForLocalHosts() {
        XCTAssertEqual(ModelImageSupport.localServerRoot("http://localhost:11434/v1")?.absoluteString, "http://localhost:11434")
        XCTAssertEqual(ModelImageSupport.localServerRoot("http://127.0.0.1:1234/v1/")?.absoluteString, "http://127.0.0.1:1234")
        XCTAssertNil(ModelImageSupport.localServerRoot("https://api.openai.com/v1"))
    }

    // MARK: - Store

    func testStore_keepsEndpointsSeparate() {
        let store = ModelImageSupport(defaults: self.defaults)
        XCTAssertNil(store.isSupported("llava", baseURL: "http://localhost:11434/v1"))

        store.record(["llava": true], baseURL: "http://localhost:11434/v1")
        store.record(["llava": false], baseURL: "https://gateway.test/v1")

        XCTAssertEqual(ModelImageSupport(defaults: self.defaults).isSupported("LLAVA", baseURL: "http://localhost:11434/v1/"), true)
        XCTAssertEqual(store.isSupported("llava", baseURL: "https://gateway.test/v1"), false)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
