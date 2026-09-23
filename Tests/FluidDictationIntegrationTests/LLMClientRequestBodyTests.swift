@testable import FluidVoice_Debug
import Foundation
import XCTest

// Regression tests for https://github.com/altic-dev/FluidVoice/issues/295
// Ollama and compatible OpenAI-format providers treat an absent `stream` key as true.
// The fix is to always send the key explicitly, whether streaming or not.

@MainActor
final class LLMClientRequestBodyTests: XCTestCase {
    func testDictationStreamingFallbackSkipsTransportFailuresAndCancellation() {
        XCTAssertFalse(
            DictationStreamingFallbackPolicy.shouldRetryWithoutStreaming(
                after: LLMError.networkError(URLError(.notConnectedToInternet))
            )
        )
        XCTAssertFalse(
            DictationStreamingFallbackPolicy.shouldRetryWithoutStreaming(after: CancellationError())
        )
        XCTAssertFalse(
            DictationStreamingFallbackPolicy.shouldRetryWithoutStreaming(
                after: LLMError.invalidRequest("missing prompt")
            )
        )
    }

    func testDictationStreamingFallbackRetriesProtocolFailure() {
        XCTAssertTrue(
            DictationStreamingFallbackPolicy.shouldRetryWithoutStreaming(after: LLMError.invalidResponse)
        )
        XCTAssertTrue(
            DictationStreamingFallbackPolicy.shouldRetryWithoutStreaming(
                after: LLMError.httpError(400, "streaming unsupported")
            )
        )
    }

    private func config(streaming: Bool) -> LLMClient.Config {
        LLMClient.Config(
            messages: [["role": "user", "content": "hello"]],
            model: "llama3",
            baseURL: "http://localhost:11434/v1",
            apiKey: "",
            streaming: streaming
        )
    }

    private func config(messages: [[String: Any]]) -> LLMClient.Config {
        LLMClient.Config(
            messages: messages,
            model: "llama3",
            baseURL: "http://localhost:11434/v1",
            apiKey: "",
            streaming: false
        )
    }

    // MARK: - Chat Completions endpoint

    func testChatCompletionsBody_streamFalse_keyIsPresentAndFalse() {
        let body = LLMClient.shared.buildChatCompletionsBody(self.config(streaming: false))
        XCTAssertNotNil(body["stream"], "stream key must be present when streaming=false — absent key breaks Ollama-compatible providers")
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testChatCompletionsBody_streamTrue_keyIsPresentAndTrue() {
        let body = LLMClient.shared.buildChatCompletionsBody(self.config(streaming: true))
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    // MARK: - Responses endpoint

    func testResponsesBody_streamFalse_keyIsPresentAndFalse() {
        let body = LLMClient.shared.buildResponsesBody(self.config(streaming: false))
        XCTAssertNotNil(body["stream"], "stream key must be present when streaming=false")
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testResponsesBody_streamTrue_keyIsPresentAndTrue() {
        let body = LLMClient.shared.buildResponsesBody(self.config(streaming: true))
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    // MARK: - Dictation custom prompt resolution

    func testCustomPromptOnly_omitsBasePromptFromEffectivePromptAndRequestBody() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            self.resetPromptSettings(settings)

            let profile = SettingsStore.DictationPromptProfile(
                name: "Gemma",
                prompt: "Clean this transcript. Return corrected text only.",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [profile]
            settings.selectedDictationPromptID = profile.id

            let prompt = settings.effectiveDictationSystemPrompt(for: .primary)
            XCTAssertEqual(prompt, profile.prompt)

            let userMessage = SettingsStore.renderDictationUserMessage(
                promptText: prompt,
                transcript: "hello comma world"
            )
            let body = LLMClient.shared.buildChatCompletionsBody(self.config(messages: [["role": "user", "content": userMessage]]))
            let messageContents = self.chatMessageContents(from: body)

            XCTAssertFalse(messageContents.contains { $0.contains(Self.basePromptMarker) })
            XCTAssertTrue(messageContents.contains { $0.contains(profile.prompt) })
        }
    }

    func testCustomPromptOnly_newProfilesNeverPrependBasePrompt() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            self.resetPromptSettings(settings)

            let profile = SettingsStore.DictationPromptProfile(
                name: "Back Compat",
                prompt: "Use my cleanup rules.",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [profile]
            settings.selectedDictationPromptID = profile.id

            XCTAssertEqual(
                settings.effectiveDictationSystemPrompt(for: .primary),
                profile.prompt
            )
        }
    }

    func testCustomPromptOnly_defaultPromptStillUsesBuiltInPrompt() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            self.resetPromptSettings(settings)

            let prompt = settings.effectiveDictationSystemPrompt(for: .primary)
            XCTAssertFalse(prompt.isEmpty)
            XCTAssertEqual(prompt, SettingsStore.defaultSystemPromptText(for: .dictate))
        }
    }

    func testCustomPromptOnly_omitsBasePromptForAppBoundCustomPrompt() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            self.resetPromptSettings(settings)

            let global = SettingsStore.DictationPromptProfile(
                name: "Global",
                prompt: "Global cleanup rules.",
                mode: .dictate
            )
            let mail = SettingsStore.DictationPromptProfile(
                name: "Mail",
                prompt: "Mail cleanup rules only.",
                mode: .dictate
            )

            settings.dictationPromptProfiles = [global, mail]
            settings.selectedDictationPromptID = nil
            settings.appPromptBindings = [
                SettingsStore.AppPromptBinding(
                    mode: .dictate,
                    appBundleID: "com.apple.mail",
                    appName: "Mail",
                    promptID: mail.id
                ),
            ]

            XCTAssertEqual(
                settings.effectiveDictationSystemPrompt(for: .primary, appBundleID: "com.apple.mail"),
                mail.prompt
            )
            XCTAssertEqual(
                settings.effectiveDictationSystemPrompt(for: .primary, appBundleID: "com.apple.notes"),
                SettingsStore.defaultSystemPromptText(for: .dictate)
            )
        }
    }

    func testCustomPromptOnly_shortcutProfileOverrideOmitsBasePrompt() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            self.resetPromptSettings(settings)

            let profile = SettingsStore.DictationPromptProfile(
                name: "Cleaner",
                prompt: "Normalize the transcript. Output only the cleaned text.",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [profile]

            XCTAssertEqual(
                settings.shortcutOverrideSystemPrompt(for: profile),
                profile.prompt
            )

            XCTAssertEqual(
                settings.shortcutOverrideSystemPrompt(for: profile),
                profile.prompt
            )
        }
    }

    func testCustomPromptOnly_emptyExplicitProfileDoesNotFallBackToDefault() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            self.resetPromptSettings(settings)
            let profile = SettingsStore.DictationPromptProfile(name: "Blank", prompt: "")
            settings.dictationPromptProfiles = [profile]
            settings.selectedDictationPromptID = profile.id
            XCTAssertEqual(settings.effectiveDictationSystemPrompt(for: .primary), "")
            XCTAssertEqual(SettingsStore.renderDictationUserMessage(promptText: "", transcript: "hello"), "hello")
        }
    }

    private static let basePromptMarker = "You are a voice-to-text dictation cleaner"

    func testAppVisitOverrideUsesActualPromptAndDoesNotPersist() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            self.resetPromptSettings(settings)
            let session = DictationAppSession.shared
            let previousApp = session.appID
            defer { session.activate(previousApp ?? "test.finished") }
            let saved = SettingsStore.DictationPromptProfile(name: "App rule", prompt: "App rule body", mode: .dictate)
            let manual = SettingsStore.DictationPromptProfile(name: "Temporary", prompt: "Temporary body", mode: .dictate)
            settings.dictationPromptProfiles = [saved, manual]
            settings.appPromptBindings = [.init(mode: .dictate, appBundleID: "test.editor", appName: "Editor", promptID: saved.id)]
            let originalSelection = settings.dictationPromptSelection(for: .primary)
            session.activate("test.other")
            session.activate("test.editor")
            XCTAssertEqual(settings.resolvedDictationPromptSelection(for: .primary, appBundleID: "test.editor"), .profile(saved.id))
            session.select(.profile(manual.id), slot: .primary, appID: "test.editor")
            XCTAssertEqual(settings.resolvedDictationPromptSelection(for: .primary, appBundleID: "test.editor"), .profile(manual.id))
            XCTAssertEqual(settings.effectiveDictationSystemPrompt(for: .primary, appBundleID: "test.editor"), "Temporary body")
            session.activate("test.editor")
            XCTAssertEqual(settings.dictationPromptDisplayName(for: .primary, appBundleID: "test.editor"), "Temporary")
            session.select(.off, slot: .primary, appID: "test.editor")
            XCTAssertEqual(settings.dictationOverlayLabel(for: .primary, appBundleID: "test.editor"), "Basic")
            XCTAssertFalse(DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: "test.editor"))
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), originalSelection)
            XCTAssertEqual(settings.appPromptBindings.first?.promptID, saved.id)
            session.activate("test.other")
            session.activate("test.editor")
            XCTAssertEqual(settings.resolvedDictationPromptSelection(for: .primary, appBundleID: "test.editor"), .profile(saved.id))
            XCTAssertEqual(settings.effectiveDictationSystemPrompt(for: .primary, appBundleID: "test.editor"), "App rule body")
            settings.dictationPromptRoutingScope = .selectedAppsOnly
            session.activate("test.unbound")
            XCTAssertEqual(settings.resolvedDictationPromptSelection(for: .primary, appBundleID: "test.unbound"), .off)
            session.select(.profile(manual.id), slot: .primary, appID: "test.unbound")
            XCTAssertEqual(settings.resolvedDictationPromptSelection(for: .primary, appBundleID: "test.unbound"), .profile(manual.id))
            XCTAssertEqual(settings.effectiveDictationSystemPrompt(for: .primary, appBundleID: "test.unbound"), "Temporary body")
        }
    }

    private func resetPromptSettings(_ settings: SettingsStore) {
        settings.dictationPromptProfiles = []
        settings.appPromptBindings = []
        settings.selectedDictationPromptID = nil
        settings.isDictationPromptOff = false
        settings.dictationPromptRoutingScope = .allApps
        settings.defaultDictationPromptOverride = nil
    }

    func testStopSnapshotSurvivesAppSwitchAndSettingsChanges() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            self.resetPromptSettings(settings)
            let configurations = settings.dictationPromptConfigurations
            let fingerprints = settings.verifiedProviderFingerprints
            let session = DictationAppSession.shared
            let previousApp = session.appID
            defer {
                settings.dictationPromptConfigurations = configurations
                settings.verifiedProviderFingerprints = fingerprints
                session.activate(previousApp ?? "test.finished")
            }
            let profile = SettingsStore.DictationPromptProfile(name: "Stop rule", prompt: "Use the stop-time prompt.")
            settings.dictationPromptProfiles = [profile]
            settings.setDictationPromptConfiguration(.init(providerID: "ollama", modelName: "stop-model"), for: .profile(profile.id))
            settings.verifiedProviderFingerprints["ollama"] = DictationAIPostProcessingGate.providerFingerprint(
                baseURL: ModelRepository.shared.defaultBaseURL(for: "ollama"), apiKey: settings.providerAPIKeys["ollama"] ?? ""
            )
            session.activate("test.stop")
            session.select(.profile(profile.id), slot: .primary, appID: "test.stop")
            let target = TypingService.RecordingTargetContext(id: UUID(), pid: 123, bundleIdentifier: "test.stop", window: nil, element: nil)
            let info = (name: "Stop app", bundleId: "test.stop", windowTitle: "Stop window")
            let snapshot = DictationStopSnapshot.capture(target: target, appInfo: info, slot: .primary, precedingText: "Before cursor")
            XCTAssertTrue(snapshot.usesAI)
            session.select(.off, slot: .primary, appID: "test.stop")
            let basic = DictationStopSnapshot.capture(target: target, appInfo: info, slot: .primary, precedingText: "")
            session.activate("test.next")
            settings.setDictationPromptConfiguration(.init(providerID: "openai", modelName: "different-cloud-model"), for: .profile(profile.id))
            settings.dictationPromptProfiles = []
            XCTAssertEqual(snapshot.route.providerID, "ollama")
            XCTAssertEqual(snapshot.route.model, "stop-model")
            XCTAssertEqual(snapshot.systemPrompt, "Use the stop-time prompt.")
            XCTAssertEqual(snapshot.target?.id, target.id)
            XCTAssertEqual(snapshot.appInfo.bundleId, "test.stop")
            XCTAssertEqual(snapshot.precedingText, "Before cursor")
            XCTAssertFalse(basic.usesAI)
            XCTAssertTrue(basic.route.providerID.isEmpty)
            let missing = DictationStopSnapshot.capture(target: nil, appInfo: info, slot: .primary, precedingText: "")
            XCTAssertFalse(missing.usesAI)
        }
    }

    func testOverlayPickMadeInAnotherAppStillAppliesToTheStartingField() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            self.resetPromptSettings(settings)
            let session = DictationAppSession.shared
            let previousApp = session.appID
            defer { session.activate(previousApp ?? "test.finished") }
            let profile = SettingsStore.DictationPromptProfile(name: "Casual", prompt: "Keep it casual.")
            settings.dictationPromptProfiles = [profile]
            // Recording started in Notes; the user switched to Slack and picked
            // Casual there. Return-to-starting-field delivers into Notes.
            session.activate("test.slack")
            session.select(.profile(profile.id), slot: .primary, appID: "test.slack")
            XCTAssertEqual(DictationStopSnapshot.promptResolutionAppID(slot: .primary, targetBundleID: "test.notes"), "test.slack")
            let target = TypingService.RecordingTargetContext(id: UUID(), pid: 7, bundleIdentifier: "test.notes", window: nil, element: nil)
            let info = (name: "Notes", bundleId: "test.notes", windowTitle: "")
            let snapshot = DictationStopSnapshot.capture(target: target, appInfo: info, slot: .primary, precedingText: "")
            XCTAssertEqual(snapshot.systemPrompt, "Keep it casual.")
            XCTAssertEqual(snapshot.appInfo.bundleId, "test.notes")
            // Without a pick, the delivery target's own rules apply.
            session.select(.off, slot: .primary, appID: "test.slack")
            session.activate("test.other")
            XCTAssertEqual(DictationStopSnapshot.promptResolutionAppID(slot: .primary, targetBundleID: "test.notes"), "test.notes")
        }
    }

    func testStopSnapshotDefersWindowTitleAndPrecedingText() {
        let target = TypingService.RecordingTargetContext(id: UUID(), pid: 321, bundleIdentifier: "test.defer", window: nil, element: nil)
        let info = (name: "Defer app", bundleId: "test.defer", windowTitle: "")
        var snapshot = DictationStopSnapshot.capture(target: target, appInfo: info, slot: .primary, precedingText: "", readsContextFromFocusedField: true)
        XCTAssertTrue(snapshot.readsContextFromFocusedField)
        XCTAssertEqual(snapshot.appInfo.windowTitle, "")
        snapshot.completeContext(windowTitle: "Draft", precedingText: "Hello ")
        XCTAssertEqual(snapshot.appInfo.windowTitle, "Draft")
        XCTAssertEqual(snapshot.precedingText, "Hello ")
        // Missing reads keep the stop-time values instead of clearing them.
        snapshot.completeContext(windowTitle: nil, precedingText: nil)
        XCTAssertEqual(snapshot.appInfo.windowTitle, "Draft")
        XCTAssertEqual(snapshot.precedingText, "Hello ")
    }

    func testMainWindowEndsAppVisitButOverlayDoesNot() {
        let session = DictationAppSession.shared
        let previousApp = session.appID
        defer { session.activate(previousApp ?? "test.finished") }
        session.activate("test.editor")
        session.select(.off, slot: .primary, appID: "test.editor")
        session.activate(Bundle.main.bundleIdentifier, isMainWindow: false)
        XCTAssertEqual(session.choice(for: .primary, appID: "test.editor"), .off)
        session.activate(Bundle.main.bundleIdentifier, isMainWindow: true)
        XCTAssertEqual(session.appID, Bundle.main.bundleIdentifier)
        session.activate("test.editor")
        XCTAssertNil(session.choice(for: .primary, appID: "test.editor"))
    }

    func testStopTargetUsesEndFieldWithoutChangingExplicitStartingFieldPolicy() {
        let start = TypingService.RecordingTargetContext(id: UUID(), pid: 1, bundleIdentifier: "start", window: nil, element: nil)
        let end = TypingService.RecordingTargetContext(id: UUID(), pid: 2, bundleIdentifier: "end", window: nil, element: nil)
        XCTAssertEqual(DictationStopSnapshot.selectTarget(current: end, original: start, returnToStartingField: false, ownOverlayFocused: false)?.id, end.id)
        XCTAssertEqual(DictationStopSnapshot.selectTarget(current: end, original: start, returnToStartingField: true, ownOverlayFocused: false)?.id, start.id)
        XCTAssertEqual(DictationStopSnapshot.selectTarget(current: end, original: start, returnToStartingField: false, ownOverlayFocused: true)?.id, start.id)
        XCTAssertNil(DictationStopSnapshot.selectTarget(current: nil, original: start, returnToStartingField: false, ownOverlayFocused: false))
    }

    private func withPromptSettingsRestored(run: () -> Void) {
        let settings = SettingsStore.shared
        let profiles = settings.dictationPromptProfiles
        let appBindings = settings.appPromptBindings
        let selectedDictationPromptID = settings.selectedDictationPromptID
        let isDictationPromptOff = settings.isDictationPromptOff
        let dictationPromptRoutingScope = settings.dictationPromptRoutingScope
        let defaultDictationPromptOverride = settings.defaultDictationPromptOverride

        defer {
            settings.dictationPromptProfiles = profiles
            settings.appPromptBindings = appBindings
            settings.selectedDictationPromptID = selectedDictationPromptID
            settings.isDictationPromptOff = isDictationPromptOff
            settings.dictationPromptRoutingScope = dictationPromptRoutingScope
            settings.defaultDictationPromptOverride = defaultDictationPromptOverride
        }

        run()
    }

    private func chatMessageContents(from body: [String: Any]) -> [String] {
        guard let messages = body["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { $0["content"] as? String }
    }
}

@MainActor
final class LLMClientStreamingTests: XCTestCase {
    // Regression test for https://github.com/altic-dev/FluidVoice/issues/445
    func testReasoningContentDeltaPreservesChunkedToolCall() async throws {
        let client = self.makeClient()
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Show the working directory"]],
            model: "qwen3.5:9b",
            baseURL: "https://issue-445.test/v1",
            apiKey: "",
            streaming: true
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5

        let response = try await client.call(config)

        XCTAssertEqual(response.thinking, "I should inspect the current directory.")
        XCTAssertEqual(response.content, "")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.id, "call_445")
        XCTAssertEqual(response.toolCalls.first?.name, "run_terminal")
        XCTAssertEqual(response.toolCalls.first?.getString("command"), "pwd")
    }

    func testTagBasedReasoningStillPreservesChunkedToolCall() async throws {
        let client = self.makeClient()
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Show the working directory"]],
            model: "qwen-thinking",
            baseURL: "https://issue-445.test/tag-parser/v1",
            apiKey: "",
            streaming: true
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5

        let response = try await client.call(config)

        XCTAssertEqual(response.thinking, "Inspecting.")
        XCTAssertEqual(response.content, "Ready.")
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.id, "call_tag_control")
        XCTAssertEqual(response.toolCalls.first?.name, "run_terminal")
        XCTAssertEqual(response.toolCalls.first?.getString("command"), "pwd")
    }

    /// Qwen3 Thinking-2507 templates open the think block in the prompt, so the stream
    /// only carries the closing tag.
    func testTagParserSplitsReasoningWhenOnlyCloseTagStreams() async throws {
        let client = self.makeClient()
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Clean this up"]],
            model: "qwen3-30b-a3b-thinking-2507",
            baseURL: "https://issue-445.test/orphan-close/v1",
            apiKey: "",
            streaming: true
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5

        let response = try await client.call(config)

        XCTAssertEqual(response.thinking, "Reasoning.")
        XCTAssertEqual(response.content, "Ready.")
    }

    func testTagParserSplitsOnEarliestCloseTag() async throws {
        let client = self.makeClient()
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Clean this up"]],
            model: "qwen3-30b-a3b-thinking-2507",
            baseURL: "https://issue-445.test/mixed-close/v1",
            apiKey: "",
            streaming: true
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5

        let response = try await client.call(config)

        XCTAssertEqual(response.thinking, "Reasoning.")
        XCTAssertEqual(response.content, "Ready. Done.")
    }

    func testStreamingDecodeAndCallbacksStayOffMainThread() async throws {
        let client = self.makeClient()
        let probe = LLMCallbackThreadProbe()
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Keep UI responsive"]],
            model: "qwen-thinking",
            baseURL: "https://issue-445.test/tag-parser/v1",
            apiKey: "",
            streaming: true
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5
        config.onContentChunk = { _ in probe.recordCallback() }

        let response = try await client.call(config)

        XCTAssertEqual(response.content, "Ready.")
        XCTAssertGreaterThan(probe.callbackCount, 0)
        XCTAssertFalse(probe.sawMainThread)
    }

    private func makeClient() -> LLMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue445StreamURLProtocol.self]
        return LLMClient(session: URLSession(configuration: configuration))
    }
}

private final nonisolated class LLMCallbackThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCallbackCount = 0
    private var recordedMainThreadCallback = false

    var callbackCount: Int {
        self.lock.withLock { self.recordedCallbackCount }
    }

    var sawMainThread: Bool {
        self.lock.withLock { self.recordedMainThreadCallback }
    }

    func recordCallback() {
        self.lock.withLock {
            self.recordedCallbackCount += 1
            self.recordedMainThreadCallback = self.recordedMainThreadCallback || Thread.isMainThread
        }
    }
}

private class Issue445StreamURLProtocol: URLProtocol {
    // The empty-string `content` fields are load-bearing: HEAD skips tool calls only
    // when `delta["content"] as? String` succeeds, so replacing them with null defangs the regression.
    private static let separateReasoningFixture = #"""
    data: {"choices":[{"index":0,"delta":{"reasoning_content":"I should inspect the current directory.","content":"","tool_calls":[{"index":0,"id":"call_445","type":"function","function":{"name":"run_terminal","arguments":"{\"command\":\""}}]}}]}

    data: {"choices":[{"index":0,"delta":{"content":"","tool_calls":[{"index":0,"function":{"arguments":"pwd\"}"}}]},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """#

    private static let tagParserFixture = #"""
    data: {"choices":[{"index":0,"delta":{"content":"<think>Inspecting.</think>Ready.","tool_calls":[{"index":0,"id":"call_tag_control","type":"function","function":{"name":"run_terminal","arguments":"{\"command\":\""}}]}}]}

    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"pwd\"}"}}]},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """#

    private static let orphanCloseFixture = #"""
    data: {"choices":[{"index":0,"delta":{"content":"Reasoning.</thi"}}]}

    data: {"choices":[{"index":0,"delta":{"content":"nk>Ready."},"finish_reason":"stop"}]}

    data: [DONE]

    """#

    private static let mixedCloseFixture = #"""
    data: {"choices":[{"index":0,"delta":{"content":"Reasoning.</thinking>Ready.</think> Done."},"finish_reason":"stop"}]}

    data: [DONE]

    """#

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "issue-445.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let fixture = if url.path.contains("orphan-close") {
            Self.orphanCloseFixture
        } else if url.path.contains("mixed-close") {
            Self.mixedCloseFixture
        } else if url.path.contains("tag-parser") {
            Self.tagParserFixture
        } else {
            Self.separateReasoningFixture
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
