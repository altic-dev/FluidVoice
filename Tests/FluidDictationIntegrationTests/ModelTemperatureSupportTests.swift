@testable import FluidVoice_Debug
import XCTest

// Temperature support is learned per model ID instead of only from a hand-kept
// name list, which broke on each new model release (Opus 4.7, Sonnet 5, Haiku 5.5).
// Sources: provider /models metadata, then HTTP 400 rejections at request time.

final class ModelTemperatureSupportTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.suiteName = "ModelTemperatureSupportTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        super.tearDown()
    }

    // MARK: - Parsing /models responses

    func testEntries_openRouterSupportedParameters() throws {
        // Shape verified against openrouter.ai/api/v1/models on 2026-10-08.
        let json = try self.json(#"""
        {"data": [
          {"id": "anthropic/claude-haiku-5.5", "supported_parameters": ["max_tokens", "reasoning", "tools"]},
          {"id": "openai/gpt-4o", "supported_parameters": ["max_tokens", "temperature", "top_p"]},
          {"id": "some/model-without-metadata"}
        ]}
        """#)

        let entries = ModelTemperatureSupport.entries(fromModelsResponse: json)

        XCTAssertEqual(entries, ["anthropic/claude-haiku-5.5": false, "openai/gpt-4o": true])
    }

    func testEntries_anthropicBudgetThinkingCapability() throws {
        // Anthropic has no sampling capability; models that dropped `budget_tokens`
        // thinking (thinking.types.enabled) also dropped `temperature`.
        let json = try self.json(#"""
        {"data": [
          {"id": "claude-haiku-5-5", "capabilities": {"thinking": {"supported": true, "types": {"enabled": {"supported": false}, "adaptive": {"supported": true}}}}},
          {"id": "claude-sonnet-4-6", "capabilities": {"thinking": {"supported": true, "types": {"enabled": {"supported": true}, "adaptive": {"supported": true}}}}}
        ]}
        """#)

        let entries = ModelTemperatureSupport.entries(fromModelsResponse: json)

        XCTAssertEqual(entries, ["claude-haiku-5-5": false, "claude-sonnet-4-6": true])
    }

    func testEntries_plainOpenAIListingRecordsNothing() throws {
        let json = try self.json(#"{"data": [{"id": "gpt-4.1", "object": "model"}]}"#)

        XCTAssertTrue(ModelTemperatureSupport.entries(fromModelsResponse: json).isEmpty)
    }

    @MainActor
    func testFetchModels_recordsTemperatureSupportFromListing() async throws {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        URLProtocol.registerClass(ModelsListingURLProtocol.self)
        defer { URLProtocol.unregisterClass(ModelsListingURLProtocol.self) }

        let models = try await ModelRepository.shared.fetchModels(
            for: "openrouter",
            baseURL: "https://models-listing.test/api/v1",
            apiKey: nil,
            temperatureSupport: store
        )

        XCTAssertEqual(models, ["anthropic/claude-haiku-5.5", "openai/gpt-4o"])
        XCTAssertEqual(store.isSupported("anthropic/claude-haiku-5.5"), false)
        XCTAssertEqual(store.isSupported("openai/gpt-4o"), true)
    }

    // MARK: - Store

    func testStore_recordsAndReadsCaseInsensitively() {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        XCTAssertNil(store.isSupported("Vendor/New-Model"))

        store.record(["Vendor/New-Model": false])

        XCTAssertEqual(store.isSupported("vendor/new-model"), false)
        XCTAssertEqual(ModelTemperatureSupport(defaults: self.defaults).isSupported("VENDOR/NEW-MODEL"), false)
    }

    // MARK: - SettingsStore resolution order

    @MainActor
    func testIsTemperatureUnsupported_usesLearnedValueForUnknownModel() {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        XCTAssertFalse(SettingsStore.shared.isTemperatureUnsupported("vendor/future-model", support: store))

        store.record(["vendor/future-model": false])

        XCTAssertTrue(SettingsStore.shared.isTemperatureUnsupported("vendor/future-model", support: store))
    }

    @MainActor
    func testIsTemperatureUnsupported_learnedValueOverridesNameList() {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        store.record(["claude-sonnet-5": true])

        XCTAssertFalse(SettingsStore.shared.isTemperatureUnsupported("claude-sonnet-5", support: store))
    }

    @MainActor
    func testIsTemperatureUnsupported_reasoningModelsIgnoreLearnedValue() {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        store.record(["o3": true])

        XCTAssertTrue(SettingsStore.shared.isTemperatureUnsupported("o3", support: store))
    }

    // MARK: - Learning from HTTP 400 at request time

    func testCall_retriesWithoutTemperatureAndRemembersModel() async throws {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        let client = self.makeClient(store: store)
        TemperatureRejectingURLProtocol.reset()

        let response = try await client.call(self.config(streaming: false))

        XCTAssertEqual(response.content, "Summary.")
        XCTAssertEqual(TemperatureRejectingURLProtocol.sentTemperatures, [true, false])
        XCTAssertEqual(store.isSupported("claude-haiku-5-5"), false)
    }

    func testCall_streamingRetriesWithoutTemperature() async throws {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        let client = self.makeClient(store: store)
        TemperatureRejectingURLProtocol.reset()

        let response = try await client.call(self.config(streaming: true))

        XCTAssertEqual(response.content, "Summary.")
        XCTAssertEqual(TemperatureRejectingURLProtocol.sentTemperatures, [true, false])
        XCTAssertEqual(store.isSupported("claude-haiku-5-5"), false)
    }

    func testCall_unrelated400IsNotRetried() async {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        let client = self.makeClient(store: store)
        TemperatureRejectingURLProtocol.reset()
        var config = self.config(streaming: false)
        config.extraParameters = ["fail_unrelated": true]

        do {
            _ = try await client.call(config)
            XCTFail("An unrelated 400 must surface to the caller")
        } catch LLMError.httpError(let status, _) {
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(TemperatureRejectingURLProtocol.sentTemperatures, [true])
        XCTAssertNil(store.isSupported("claude-haiku-5-5"))
    }

    // MARK: - Helpers

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func makeClient(store: ModelTemperatureSupport) -> LLMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TemperatureRejectingURLProtocol.self]
        return LLMClient(session: URLSession(configuration: configuration), temperatureSupport: store)
    }

    private func config(streaming: Bool) -> LLMClient.Config {
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Summarize"]],
            model: "claude-haiku-5-5",
            baseURL: "https://temperature-reject.test/v1",
            apiKey: "test",
            streaming: streaming,
            temperature: 0.2
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5
        return config
    }
}

/// Rejects any request body that carries `temperature` the way Anthropic does,
/// and answers normally otherwise.
private final class TemperatureRejectingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [Bool] = []

    static var sentTemperatures: [Bool] {
        self.lock.withLock { self.recorded }
    }

    static func reset() {
        self.lock.withLock { self.recorded = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "temperature-reject.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyJSON(of: request)
        let hasTemperature = body["temperature"] != nil
        Self.lock.withLock { Self.recorded.append(hasTemperature) }

        let streaming = body["stream"] as? Bool ?? false
        let failUnrelated = body["fail_unrelated"] as? Bool ?? false
        let status: Int
        let payload: String
        let contentType: String
        if failUnrelated {
            status = 400
            payload = #"{"error":{"message":"max_tokens is too large"}}"#
            contentType = "application/json"
        } else if hasTemperature {
            status = 400
            payload = #"{"error":{"code":"invalid_request_error","message":"`temperature` is deprecated for this model."}}"#
            contentType = "application/json"
        } else if streaming {
            status = 200
            payload = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Summary.\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            contentType = "text/event-stream"
        } else {
            status = 200
            payload = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Summary."},"finish_reason":"stop"}]}"#
            contentType = "application/json"
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyJSON(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// Serves a fixed OpenRouter-style `/models` listing.
private final class ModelsListingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "models-listing.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let payload = #"""
        {"data": [
          {"id": "openai/gpt-4o", "supported_parameters": ["temperature"]},
          {"id": "anthropic/claude-haiku-5.5", "supported_parameters": ["tools"]}
        ]}
        """#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
