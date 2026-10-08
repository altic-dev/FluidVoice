@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingSummaryProviderTests: XCTestCase {
    func testMeetingSelectionPersistsWithoutChangingGlobalSelections() throws {
        let suite = "MeetingSummaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openai", forKey: "SelectedProviderID")
        defaults.set("dictation-model", forKey: "SelectedModel")
        let preferences = MeetingSummaryPreferences(defaults: defaults)
        XCTAssertEqual(preferences.selection.providerID, "", "A new install has no summary provider until one is chosen")
        preferences.selection.providerID = "openrouter"
        preferences.selection.modelsByProvider["openrouter"] = "summary-model"
        let restored = MeetingSummaryPreferences(defaults: defaults)
        XCTAssertEqual(restored.selection, preferences.selection)
        XCTAssertEqual(defaults.string(forKey: "SelectedProviderID"), "openai")
        XCTAssertEqual(defaults.string(forKey: "SelectedModel"), "dictation-model")
    }

    func testPreReleaseSelectionsStartFresh() throws {
        let suite = "MeetingSummaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stale = MeetingSummarySelection(providerID: "meeting:claude-cli", modelsByProvider: ["openai": "summary-model"])
        try defaults.set(JSONEncoder().encode(stale), forKey: "MeetingSummarySelection")
        let preferences = MeetingSummaryPreferences(defaults: defaults)
        XCTAssertEqual(preferences.selection.providerID, "")
        XCTAssertEqual(preferences.selection.modelsByProvider["openai"], "summary-model")
    }

    func testLegacySummaryLoadsWithoutProviderMetadata() throws {
        let data = Data(#"{"transcriptHash":"old","modelID":"local-summary","text":"Previous summary"}"#.utf8)
        let saved = try JSONDecoder().decode(MeetingSummaryController.SavedSummary.self, from: data)
        XCTAssertEqual(saved.text, "Previous summary")
        XCTAssertEqual(saved.provenance, "Fluid Intelligence · local-summary")
        XCTAssertNil(saved.generatedAt)
    }

    func testMetadataRoundTripsAndDoesNotContainCredentials() throws {
        let route = self.route()
        let saved = MeetingSummaryController.SavedSummary(
            transcriptHash: "hash",
            modelID: route.modelID,
            text: "Summary",
            providerID: route.providerID,
            providerName: route.providerName,
            configurationHash: route.configurationHash,
            promptVersion: 1,
            generatedAt: Date()
        )
        let data = try JSONEncoder().encode(saved)
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).contains(route.apiKey))
        XCTAssertEqual(try JSONDecoder().decode(MeetingSummaryController.SavedSummary.self, from: data).provenance, route.provenance)
    }

    func testConfiguredProviderUsesTranscriptAsDataAndPreservesReasoningSettings() throws {
        let route = self.route()
        let config = MeetingSummaryRemoteService().configuration(transcript: "Maya: ship Friday", kind: .actions, route: route)
        XCTAssertEqual(config.messages.last?["content"] as? String, "Maya: ship Friday")
        XCTAssertTrue((config.messages.first?["content"] as? String)?.contains("Action items") == true)
        XCTAssertEqual(config.baseURL, route.baseURL)
        XCTAssertEqual(config.apiKey, route.apiKey)
        XCTAssertFalse(config.streaming)
        XCTAssertTrue(config.tools.isEmpty)
        XCTAssertEqual(config.timeoutSeconds, 180)
        XCTAssertEqual(config.maxRetries, 1)
        XCTAssertEqual(config.extraParameters["enable_thinking"] as? Bool, false)
        XCTAssertNil(config.temperature)
        let request = try LLMClient.shared.buildRequest(config)
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.example/v1/chat/completions")
    }

    func testRemoteGenerationWorksWithoutLocalModelAndRejectsEmptyOutput() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeetingSummaryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = MeetingSummaryRemoteService(session: session)
        let summary = try await service.generate(transcript: "Discuss release", kind: .executive, route: self.route())
        XCTAssertEqual(summary, "Release agreed")
        do {
            _ = try await service.generate(transcript: "Discuss release", kind: .executive, route: self.route(baseURL: "https://empty.example/v1"))
            XCTFail("Empty responses must not replace the saved summary")
        } catch { XCTAssertTrue(error is MeetingPostProcessingError) }
    }

    func testIncompleteRemoteResponsesAreRejectedBeforeReturningSummary() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeetingSummaryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = MeetingSummaryRemoteService(session: session)
        for endpoint in [
            "https://length.example/v1",
            "https://filtered.example/v1",
            "https://incomplete.example/v1/responses",
            "https://partial-item.example/v1/responses",
            "https://details.example/v1/responses",
        ] {
            do {
                _ = try await service.generate(transcript: "Discuss release", kind: .executive, route: self.route(baseURL: endpoint))
                XCTFail("Partial content must not reach the controller's save path: \(endpoint)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("incomplete summary"), "\(endpoint): \(error)")
            }
        }
        let complete = try await service.generate(transcript: "Discuss release", kind: .executive, route: self.route(baseURL: "https://complete.example/v1/responses"))
        XCTAssertEqual(complete, "Release agreed")
    }

    func testOversizedInputFailsBeforeNetworkRequest() async {
        do {
            _ = try await MeetingSummaryRemoteService().generate(transcript: String(repeating: "a", count: 512_001), kind: .executive, route: self.route())
            XCTFail("Oversized input must not be truncated or sent")
        } catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
    }

    func testCancelledRequestDoesNotStartTransport() async {
        let route = self.route()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingSummaryRemoteService().generate(transcript: "Meeting", kind: .executive, route: route)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testProviderSpecificNormalStopsAreNotTreatedAsIncomplete() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeetingSummaryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = MeetingSummaryRemoteService(session: session)
        for endpoint in ["https://eos.example/v1", "https://end-turn.example/v1"] {
            let summary = try await service.generate(transcript: "Discuss release", kind: .executive, route: self.route(baseURL: endpoint))
            XCTAssertEqual(summary, "Release agreed", endpoint)
        }
    }

    func testReasoningModelsGetCommandModeOutputBudget() {
        var route = self.route()
        XCTAssertNil(MeetingSummaryRemoteService().configuration(transcript: "Meeting", kind: .executive, route: route).maxTokens)
        route.isReasoningModel = true
        XCTAssertEqual(MeetingSummaryRemoteService().configuration(transcript: "Meeting", kind: .executive, route: route).maxTokens, 32_000)
    }

    func testRouteRequiresProviderAndVerifiedModel() {
        let settings = SettingsStore.shared
        XCTAssertThrowsError(try MeetingSummaryRoute.resolve(.init(), settings: settings)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Choose a provider"), "\(error)")
        }
        XCTAssertThrowsError(try MeetingSummaryRoute.resolve(.init(providerID: "openai"), settings: settings)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Choose a summary model"), "\(error)")
        }
        let unverified = MeetingSummarySelection(providerID: "openai", modelsByProvider: ["openai": "model-\(UUID().uuidString)"])
        XCTAssertThrowsError(try MeetingSummaryRoute.resolve(unverified, settings: settings)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unavailable"), "\(error)")
        }
    }

    private func route(baseURL: String = "https://gateway.example/v1/") -> MeetingSummaryRoute {
        MeetingSummaryRoute(
            providerID: "fixture",
            providerName: "Fixture",
            modelID: "summary-model",
            baseURL: baseURL,
            apiKey: "fixture-key-never-persist",
            reasoning: .init(parameterName: "enable_thinking", parameterValue: "false"),
            supportsTemperature: false
        )
    }
}

private class MeetingSummaryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = self.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
        let text = url.host == "empty.example" ? "" : "Release agreed"
        let json: [String: Any]
        if url.path.contains("/responses") {
            json = [
                "status": url.host == "incomplete.example" ? "incomplete" : "completed",
                "incomplete_details": url.host == "details.example" ? ["reason": "max_output_tokens"] : NSNull(),
                "output": [[
                    "type": "message",
                    "status": url.host == "partial-item.example" ? "incomplete" : "completed",
                    "content": [["type": "output_text", "text": text]],
                ]],
            ]
        } else {
            let reason: String
            switch url.host {
            case "length.example": reason = "length"
            case "filtered.example": reason = "content_filter"
            case "eos.example": reason = "eos"
            case "end-turn.example": reason = "end_turn"
            default: reason = "stop"
            }
            json = ["choices": [["message": ["content": text], "finish_reason": reason]]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
