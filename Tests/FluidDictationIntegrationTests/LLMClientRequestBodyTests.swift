@testable import FluidVoice_Debug
import XCTest

// Regression tests for https://github.com/altic-dev/FluidVoice/issues/295
// Ollama and compatible OpenAI-format providers treat an absent `stream` key as true.
// The fix is to always send the key explicitly, whether streaming or not.

@MainActor
final class LLMClientRequestBodyTests: XCTestCase {
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

    func testCodexSubscriptionForcesStreamingWithoutChangingOtherProviders() {
        XCTAssertTrue(
            LLMClient.effectiveStreaming(
                providerID: OfficialProviderAuth.codexProviderID,
                requested: false
            )
        )
        XCTAssertFalse(LLMClient.effectiveStreaming(providerID: "openai", requested: false))
        XCTAssertFalse(
            LLMClient.effectiveStreaming(
                providerID: GrokSubscriptionAuth.providerID,
                requested: false
            )
        )
        XCTAssertTrue(LLMClient.effectiveStreaming(providerID: "openai", requested: true))
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
            settings.sendCustomPromptOnly = true

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

    func testCustomPromptOnly_defaultFalsePrependsBasePrompt() {
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
            settings.sendCustomPromptOnly = false

            XCTAssertEqual(
                settings.effectiveDictationSystemPrompt(for: .primary),
                SettingsStore.combineBasePrompt(for: .dictate, with: profile.prompt)
            )
        }
    }

    func testCustomPromptOnly_defaultPromptStillUsesBuiltInPrompt() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            self.resetPromptSettings(settings)

            settings.sendCustomPromptOnly = true

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
            settings.sendCustomPromptOnly = true

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

    // MARK: - Official provider OAuth adapters (#819)

    func testCodexCredentialDecoderImportsChatGPTSessionWithoutRefreshTokenExposure() throws {
        let token = self.jwt(["sub": "user-123", "email": "person@example.com", "exp": 2_000_000_000])
        let data = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": token,
                "refresh_token": "owned-by-codex",
                "account_id": "account-456",
            ],
        ])

        let credential = try OfficialProviderAuth.decodeCodexCredential(from: data)
        XCTAssertEqual(credential.accessToken, token)
        XCTAssertEqual(credential.accountID, "account-456")
        XCTAssertEqual(credential.accountLabel, "person@example.com")
    }

    func testCodexDeviceAuthorizationDecodesPublicBrowserFlow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "device_auth_id": "device-auth-secret",
            "user_code": "WXYZ-9876",
            "interval": "5",
        ])

        let authorization = try CodexSubscriptionAuth.decodeDeviceAuthorization(from: data, now: now)
        XCTAssertEqual(authorization.userCode, "WXYZ-9876")
        XCTAssertEqual(authorization.pollingInterval, 5)
        XCTAssertEqual(authorization.expiresAt, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(authorization.browserURL.absoluteString, "https://auth.openai.com/codex/device")
    }

    func testCodexOAuthTokenDecoderPreservesRotatingSessionIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let idToken = self.jwt([
            "email": "chatgpt@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "account-123"],
        ])
        let initialData = try JSONSerialization.data(withJSONObject: [
            "id_token": idToken,
            "access_token": "codex-access",
            "refresh_token": "codex-refresh",
            "expires_in": 3600,
        ])

        let initial = try CodexSubscriptionAuth.decodeOAuthSession(from: initialData, now: now)
        XCTAssertEqual(initial.accountID, "account-123")
        XCTAssertEqual(initial.accountLabel, "chatgpt@example.com")
        XCTAssertEqual(initial.refreshToken, "codex-refresh")

        let refreshedData = try JSONSerialization.data(withJSONObject: [
            "access_token": "codex-access-rotated",
            "expires_in": 1800,
        ])
        let refreshed = try CodexSubscriptionAuth.decodeOAuthSession(
            from: refreshedData,
            previousRefreshToken: initial.refreshToken,
            previousAccountID: initial.accountID,
            previousEmail: initial.email,
            now: now
        )
        XCTAssertEqual(refreshed.accessToken, "codex-access-rotated")
        XCTAssertEqual(refreshed.refreshToken, "codex-refresh")
        XCTAssertEqual(refreshed.accountID, "account-123")
        XCTAssertEqual(refreshed.accountLabel, "chatgpt@example.com")
    }

    func testOAuthRefreshCoalescerSharesOneInFlightOperation() async throws {
        let coalescer = InFlightTaskCoalescer<String>()
        var refreshCount = 0

        let first = Task { @MainActor in
            try await coalescer.value {
                refreshCount += 1
                try await Task.sleep(nanoseconds: 25_000_000)
                return "rotated-access-token"
            }
        }
        await Task.yield()
        let second = Task { @MainActor in
            try await coalescer.value {
                refreshCount += 1
                return "unexpected-second-refresh"
            }
        }

        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, "rotated-access-token")
        XCTAssertEqual(secondValue, "rotated-access-token")
        XCTAssertEqual(refreshCount, 1)
    }

    func testOAuthRefreshCoalescerCancelsAndAwaitsActiveRefresh() async {
        let coalescer = InFlightTaskCoalescer<String>()
        var observedCancellation = false
        let refresh = Task { @MainActor in
            try await coalescer.value {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    return "stale-rotated-token"
                } catch is CancellationError {
                    observedCancellation = true
                    throw CancellationError()
                }
            }
        }
        await Task.yield()

        await coalescer.cancelAndWait()

        XCTAssertTrue(observedCancellation)
        do {
            _ = try await refresh.value
            XCTFail("The refresh should be cancelled before disconnect can delete its credential")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testOAuthTransportCancellationRemainsCancellation() {
        XCTAssertThrowsError(
            try OfficialProviderAuth.rethrowCancellation(URLError(.cancelled))
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNoThrow(
            try OfficialProviderAuth.rethrowCancellation(URLError(.notConnectedToInternet))
        )
    }

    func testCodexAndGrokPollingPreserveTransportCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let codexAuthorization = CodexSubscriptionAuth.DeviceAuthorization(
            deviceAuthID: "device-auth",
            userCode: "ABCD-1234",
            pollingInterval: 0,
            expiresAt: now.addingTimeInterval(60)
        )
        do {
            _ = try await CodexSubscriptionAuth.completeDeviceAuthorization(
                codexAuthorization,
                session: session,
                now: { now }
            )
            XCTFail("Codex polling should preserve cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let grokAuthorization = try GrokSubscriptionAuth.DeviceAuthorization(
            deviceCode: "device-code",
            userCode: "ABCD-1234",
            verificationURL: XCTUnwrap(URL(string: "https://auth.x.ai/device")),
            verificationCompleteURL: nil,
            pollingInterval: 0,
            expiresAt: now.addingTimeInterval(60)
        )
        do {
            _ = try await GrokSubscriptionAuth.completeDeviceAuthorization(
                grokAuthorization,
                session: session,
                now: { now }
            )
            XCTFail("Grok polling should preserve cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testClaudeCredentialDecoderImportsOfficialCredentialShape() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": [
                "accessToken": "claude-oauth-access",
                "refreshToken": "owned-by-claude",
                "expiresAt": 2_000_000_000_000,
                "email": "claude@example.com",
            ],
        ])

        let credential = try OfficialProviderAuth.decodeClaudeCredential(from: data)
        XCTAssertEqual(credential.accessToken, "claude-oauth-access")
        XCTAssertEqual(credential.accountLabel, "claude@example.com")
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testGeminiCredentialDecoderSupportsLegacyCLIFile() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "access_token": "google-access",
            "refresh_token": "owned-by-gemini",
            "expiry_date": 2_000_000_000_000,
        ])

        let credential = try OfficialProviderAuth.decodeGeminiCredential(
            from: data,
            accountLabel: "google@example.com"
        )
        XCTAssertEqual(credential.accessToken, "google-access")
        XCTAssertEqual(credential.accountLabel, "google@example.com")
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testGeminiProjectUsesOfficialCLIEnvironmentContract() throws {
        XCTAssertEqual(
            try OfficialProviderAuth.configuredGeminiProject(environment: [
                "GOOGLE_CLOUD_PROJECT": "workspace-project",
                "GOOGLE_CLOUD_PROJECT_ID": "fallback-project",
            ]),
            "workspace-project"
        )
        XCTAssertThrowsError(
            try OfficialProviderAuth.configuredGeminiProject(environment: [
                "GOOGLE_CLOUD_PROJECT": "1234567890",
            ])
        )
    }

    func testGeminiProjectCacheIsScopedToCredentialAndAvoidsRepeatedSetup() async throws {
        let cache = CredentialScopedValueCache<String>()
        let firstKey = OfficialProviderAuth.geminiProjectCacheKey(
            accountLabel: "first@example.com",
            accessToken: "first-access-token"
        )
        let secondKey = OfficialProviderAuth.geminiProjectCacheKey(
            accountLabel: "second@example.com",
            accessToken: "second-access-token"
        )
        var loadCount = 0

        let first = try await cache.value(for: firstKey) {
            loadCount += 1
            return "projects/first"
        }
        let cached = try await cache.value(for: firstKey) {
            loadCount += 1
            return "unexpected-reload"
        }
        let second = try await cache.value(for: secondKey) {
            loadCount += 1
            return "projects/second"
        }

        XCTAssertEqual(first, "projects/first")
        XCTAssertEqual(cached, "projects/first")
        XCTAssertEqual(second, "projects/second")
        XCTAssertEqual(loadCount, 2)
        XCTAssertNotEqual(firstKey, secondKey)
        XCTAssertFalse(firstKey.contains("first-access-token"))
    }

    func testGrokCredentialDecoderSelectsOAuthSessionAndIgnoresAPIKey() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "https://api.x.ai::legacy": [
                "key": "xai-api-key",
                "auth_mode": "api_key",
                "create_time": "2027-01-01T00:00:00Z",
            ],
            "https://auth.x.ai::openid profile offline_access": [
                "key": "grok-oauth-access",
                "auth_mode": "oidc",
                "create_time": "2027-01-02T00:00:00Z",
                "expires_at": "2027-02-02T00:00:00Z",
                "oidc_issuer": "https://auth.x.ai",
                "user_id": "grok-user-1",
                "email": "grok@example.com",
            ],
        ])

        let credential = try GrokSubscriptionAuth.decodeCredential(
            from: data,
            grokHome: URL(fileURLWithPath: "/tmp/test-grok-home", isDirectory: true),
            now: now
        )
        XCTAssertEqual(credential.accessToken, "grok-oauth-access")
        XCTAssertEqual(credential.userID, "grok-user-1")
        XCTAssertEqual(credential.accountLabel, "grok@example.com")
        XCTAssertEqual(credential.requestHeaders["X-XAI-Token-Auth"], "xai-grok-cli")
        XCTAssertEqual(credential.requestHeaders["x-grok-user-id"], "grok-user-1")
        XCTAssertEqual(credential.requestHeaders["x-grok-client-identifier"], "fluidvoice")
        XCTAssertEqual(ModelRepository.shared.defaultBaseURL(for: GrokSubscriptionAuth.providerID), GrokSubscriptionAuth.proxyBaseURL)
    }

    func testGrokDeviceLoginKeepsTheOfficialSubscriptionRoutingContract() {
        XCTAssertEqual(
            GrokSubscriptionAuth.deviceAuthorizationScopes,
            [
                "openid",
                "profile",
                "email",
                "offline_access",
                "grok-cli:access",
                "api:access",
                "conversations:read",
                "conversations:write",
                "workspaces:read",
                "workspaces:write",
            ]
        )
        XCTAssertEqual(GrokSubscriptionAuth.deviceAuthorizationReferrer, "grok-build")

        let headers = GrokSubscriptionAuth.proxyRequestHeaders(
            userID: "grok-user-2",
            grokHome: URL(fileURLWithPath: "/tmp/no-grok-install", isDirectory: true)
        )
        XCTAssertEqual(headers["X-XAI-Token-Auth"], "xai-grok-cli")
        XCTAssertEqual(headers["x-authenticateresponse"], "authenticate-response")
        XCTAssertEqual(headers["x-grok-client-mode"], "interactive")
        XCTAssertEqual(headers["x-grok-client-identifier"], "fluidvoice")
        XCTAssertEqual(headers["x-grok-user-id"], "grok-user-2")
        XCTAssertEqual(headers["x-userid"], "grok-user-2")
    }

    func testGrokDeviceAuthorizationBuildsSafeBrowserChallenge() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "device_code": "device-secret",
            "user_code": "ABCD-1234",
            "verification_uri": "https://auth.x.ai/device",
            "expires_in": 600,
            "interval": 5,
        ])

        let authorization = try GrokSubscriptionAuth.decodeDeviceAuthorization(from: data, now: now)
        XCTAssertEqual(authorization.userCode, "ABCD-1234")
        XCTAssertEqual(authorization.pollingInterval, 5)
        XCTAssertEqual(authorization.expiresAt, now.addingTimeInterval(600))
        XCTAssertEqual(
            authorization.browserURL.absoluteString,
            "https://auth.x.ai/device?user_code=ABCD-1234"
        )
    }

    func testGrokDeviceAuthorizationRejectsUntrustedVerificationURL() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "device_code": "device-secret",
            "user_code": "ABCD-1234",
            "verification_uri": "https://phishing.invalid/device",
            "expires_in": 600,
        ])

        XCTAssertThrowsError(try GrokSubscriptionAuth.decodeDeviceAuthorization(from: data))
    }

    func testGrokOAuthTokenDecoderRetainsRefreshTokenAndAccountIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let idToken = self.jwt([
            "sub": "grok-user-2",
            "email": "signed-in@example.com",
        ])
        let initialData = try JSONSerialization.data(withJSONObject: [
            "access_token": "fluidvoice-grok-access",
            "refresh_token": "fluidvoice-grok-refresh",
            "expires_in": 3600,
            "scope": "openid offline_access api:access",
            "id_token": idToken,
        ])

        let initial = try GrokSubscriptionAuth.decodeOAuthSession(from: initialData, now: now)
        XCTAssertEqual(initial.accessToken, "fluidvoice-grok-access")
        XCTAssertEqual(initial.refreshToken, "fluidvoice-grok-refresh")
        XCTAssertEqual(initial.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(initial.userID, "grok-user-2")
        XCTAssertEqual(initial.accountLabel, "signed-in@example.com")

        let refreshData = try JSONSerialization.data(withJSONObject: [
            "access_token": "rotated-access",
            "expires_in": 1800,
        ])
        let refreshed = try GrokSubscriptionAuth.decodeOAuthSession(
            from: refreshData,
            previousRefreshToken: initial.refreshToken,
            previousUserID: initial.userID,
            previousEmail: initial.email,
            now: now
        )
        XCTAssertEqual(refreshed.accessToken, "rotated-access")
        XCTAssertEqual(refreshed.refreshToken, "fluidvoice-grok-refresh")
        XCTAssertEqual(refreshed.userID, "grok-user-2")
        XCTAssertEqual(refreshed.accountLabel, "signed-in@example.com")
    }

    func testOfficialLoginFingerprintDoesNotContainOrDependOnRotatingAccessToken() {
        let first = OfficialProviderAuth.configurationFingerprint(
            providerID: GrokSubscriptionAuth.providerID,
            baseURL: "https://one.invalid",
            apiKey: "access-one"
        )
        let second = OfficialProviderAuth.configurationFingerprint(
            providerID: GrokSubscriptionAuth.providerID,
            baseURL: "https://two.invalid",
            apiKey: "access-two"
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, OfficialProviderAuth.verificationFingerprint(for: GrokSubscriptionAuth.providerID))
    }

    func testAnthropicMessagesBodyConvertsSystemToolsAndToolResults() throws {
        let config = LLMClient.Config(
            providerID: OfficialProviderAuth.claudeProviderID,
            messages: [
                ["role": "system", "content": "Be concise."],
                ["role": "user", "content": "List files"],
                [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [[
                        "id": "call-1",
                        "type": "function",
                        "function": ["name": "shell", "arguments": "{\"command\":\"ls\"}"],
                    ]],
                ],
                ["role": "tool", "tool_call_id": "call-1", "content": "file.txt"],
            ],
            model: "claude-sonnet-4-6",
            baseURL: "https://api.anthropic.com/v1",
            apiKey: "",
            streaming: false,
            tools: [[
                "type": "function",
                "function": [
                    "name": "shell",
                    "description": "Run a command",
                    "parameters": ["type": "object"],
                ],
            ]],
            maxTokens: 128
        )

        let body = LLMClient.shared.buildAnthropicMessagesBody(config)
        XCTAssertEqual(body["system"] as? String, "Be concise.")
        XCTAssertEqual(body["max_tokens"] as? Int, 128)
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        let assistantBlocks = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.first?["type"] as? String, "tool_use")
        let resultBlocks = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(resultBlocks.first?["type"] as? String, "tool_result")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "shell")
    }

    func testGeminiCodeAssistBodyWrapsProjectAndConvertsRoles() throws {
        let config = LLMClient.Config(
            providerID: OfficialProviderAuth.geminiProviderID,
            messages: [
                ["role": "system", "content": "Be concise."],
                ["role": "user", "content": "Hello"],
                ["role": "assistant", "content": "Hi"],
            ],
            model: "gemini-2.5-flash",
            baseURL: "https://cloudcode-pa.googleapis.com/v1internal",
            apiKey: "",
            streaming: true,
            temperature: 0.2,
            maxTokens: 64
        )

        let body = LLMClient.shared.buildGeminiCodeAssistBody(config, project: "projects/example")
        XCTAssertEqual(body["model"] as? String, "gemini-2.5-flash")
        XCTAssertEqual(body["project"] as? String, "projects/example")
        let request = try XCTUnwrap(body["request"] as? [String: Any])
        let system = try XCTUnwrap(request["systemInstruction"] as? [String: Any])
        let systemParts = try XCTUnwrap(system["parts"] as? [[String: Any]])
        XCTAssertEqual(systemParts.first?["text"] as? String, "Be concise.")
        let contents = try XCTUnwrap(request["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.map { $0["role"] as? String }, ["user", "model"])
        let generation = try XCTUnwrap(request["generationConfig"] as? [String: Any])
        XCTAssertEqual(generation["maxOutputTokens"] as? Int, 64)
    }

    func testGeminiThoughtSignatureIsParsedAndReplayedWithFunctionCall() throws {
        let parsed = LLMClient.shared.geminiParts(from: [
            "response": [
                "candidates": [[
                    "content": [
                        "parts": [[
                            "functionCall": [
                                "id": "call-gemini",
                                "name": "execute_terminal_command",
                                "args": ["command": "pwd"],
                            ],
                            "thoughtSignature": "opaque-gemini-thought",
                        ]],
                    ],
                ]],
            ],
        ])
        let toolCall = try XCTUnwrap(parsed.toolCalls.first)
        XCTAssertEqual(toolCall.thoughtSignature, "opaque-gemini-thought")

        let config = LLMClient.Config(
            providerID: OfficialProviderAuth.geminiProviderID,
            messages: [
                [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [[
                        "id": toolCall.id,
                        "type": "function",
                        "thought_signature": toolCall.thoughtSignature as Any,
                        "function": [
                            "name": toolCall.name,
                            "arguments": "{\"command\":\"pwd\"}",
                        ],
                    ]],
                ],
                ["role": "tool", "tool_call_id": toolCall.id, "content": "/tmp"],
            ],
            model: "gemini-2.5-flash",
            baseURL: "https://cloudcode-pa.googleapis.com/v1internal",
            apiKey: "",
            streaming: true
        )

        let body = LLMClient.shared.buildGeminiCodeAssistBody(config, project: "projects/example")
        let request = try XCTUnwrap(body["request"] as? [String: Any])
        let contents = try XCTUnwrap(request["contents"] as? [[String: Any]])
        let modelParts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertEqual(modelParts.first?["thoughtSignature"] as? String, "opaque-gemini-thought")
    }

    func testCommandHistoryPersistsOpaqueProviderContinuationState() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let message = ChatMessage(
            role: .assistant,
            content: "Running a command",
            toolCall: ChatMessage.ToolCall(
                id: "call-1",
                command: "pwd",
                workingDirectory: "/tmp",
                purpose: "Inspect the working directory",
                thoughtSignature: "opaque-gemini-thought"
            ),
            responsesContinuationItems: [
                LLMClient.ResponsesContinuationItem(
                    id: "reasoning-1",
                    encryptedContent: "opaque-codex-reasoning"
                ),
            ],
            responsesContinuationScope: "credential-scope",
            timestamp: timestamp
        )

        let decoded = try JSONDecoder().decode(
            ChatMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(decoded, message)
    }

    func testCommandHistoryDecodesBeforeContinuationStateWasPersisted() throws {
        let message = ChatMessage(role: .assistant, content: "Legacy history")
        let encoded = try JSONEncoder().encode(message)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "responsesContinuationItems")
        object.removeValue(forKey: "responsesContinuationScope")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: legacyData)
        XCTAssertEqual(decoded.responsesContinuationItems, [])
        XCTAssertNil(decoded.responsesContinuationScope)
    }

    func testOfficialProvidersHaveBundledModelsAndBaseURLs() {
        for providerID in OfficialProviderAuth.providerIDs {
            XCTAssertTrue(ModelRepository.shared.isBuiltIn(providerID))
            XCTAssertFalse(ModelRepository.shared.defaultModels(for: providerID).isEmpty)
            XCTAssertFalse(ModelRepository.shared.defaultBaseURL(for: providerID).isEmpty)
        }
    }

    func testAPIKeyProvidersRemainAvailableBesideOfficialLoginProviders() {
        let providerPairs = [
            (apiKey: "openai", login: OfficialProviderAuth.codexProviderID),
            (apiKey: "anthropic", login: OfficialProviderAuth.claudeProviderID),
            (apiKey: "google", login: OfficialProviderAuth.geminiProviderID),
            (apiKey: "xai", login: GrokSubscriptionAuth.providerID),
        ]
        let providerIDs = Set(ModelRepository.shared.builtInProvidersList().map(\.id))

        for pair in providerPairs {
            XCTAssertNotEqual(pair.apiKey, pair.login)
            XCTAssertTrue(providerIDs.contains(pair.apiKey))
            XCTAssertTrue(providerIDs.contains(pair.login))
            XCTAssertEqual(ModelRepository.shared.providerWebsiteURL(for: pair.apiKey)?.label, "Get API Key")
        }
    }

    func testAPIKeyFingerprintStillTracksTheConfiguredKeyAndBaseURL() {
        let original = OfficialProviderAuth.configurationFingerprint(
            providerID: "openai",
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test-one"
        )
        let changedKey = OfficialProviderAuth.configurationFingerprint(
            providerID: "openai",
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test-two"
        )
        let changedBaseURL = OfficialProviderAuth.configurationFingerprint(
            providerID: "openai",
            baseURL: "https://gateway.example/v1",
            apiKey: "sk-test-one"
        )

        XCTAssertNotNil(original)
        XCTAssertNotEqual(original, changedKey)
        XCTAssertNotEqual(original, changedBaseURL)
    }

    func testCodexLoginUsesInstructionsWithoutChangingOpenAIAPIKeyResponsesBody() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "Be concise."],
            ["role": "user", "content": "Hello"],
        ]
        let apiKeyConfig = LLMClient.Config(
            providerID: "openai",
            messages: messages,
            model: "gpt-4.1",
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            streaming: false
        )
        let loginConfig = LLMClient.Config(
            providerID: OfficialProviderAuth.codexProviderID,
            messages: messages,
            model: "gpt-5.6-sol",
            baseURL: "https://chatgpt.com/backend-api/codex",
            apiKey: "",
            streaming: false
        )

        let apiKeyBody = LLMClient.shared.buildResponsesBody(apiKeyConfig)
        XCTAssertNil(apiKeyBody["instructions"])
        let apiKeyInput = try XCTUnwrap(apiKeyBody["input"] as? [[String: Any]])
        XCTAssertEqual(apiKeyInput.first?["role"] as? String, "system")

        let loginBody = LLMClient.shared.buildResponsesBody(loginConfig)
        XCTAssertEqual(loginBody["instructions"] as? String, "Be concise.")
        let loginInput = try XCTUnwrap(loginBody["input"] as? [[String: Any]])
        XCTAssertEqual(loginInput.count, 1)
        XCTAssertEqual(loginInput.first?["role"] as? String, "user")
    }

    func testCodexLoginOmitsUnsupportedOutputTokenLimitWithoutChangingAPIKeyResponsesBody() {
        let messages: [[String: Any]] = [["role": "user", "content": "Reply with OK."]]
        let apiKeyConfig = LLMClient.Config(
            providerID: "openai",
            messages: messages,
            model: "gpt-5",
            baseURL: "https://api.openai.com/v1",
            apiKey: "sk-test",
            streaming: true,
            maxTokens: 16
        )
        let loginConfig = LLMClient.Config(
            providerID: OfficialProviderAuth.codexProviderID,
            messages: messages,
            model: "gpt-5.6-luna",
            baseURL: "https://chatgpt.com/backend-api/codex",
            apiKey: "",
            streaming: true,
            maxTokens: 16
        )

        let apiKeyBody = LLMClient.shared.buildResponsesBody(apiKeyConfig)
        XCTAssertEqual(apiKeyBody["max_output_tokens"] as? Int, 16)

        let loginBody = LLMClient.shared.buildResponsesBody(loginConfig)
        XCTAssertNil(loginBody["max_output_tokens"])
    }

    func testCodexLoginReplaysEncryptedReasoningBeforeToolContinuation() throws {
        let reasoningItem = try XCTUnwrap(LLMClient.shared.responsesContinuationItem(from: [
            "type": "reasoning",
            "id": "rs_123",
            "encrypted_content": "opaque-reasoning-state",
        ]))
        let config = LLMClient.Config(
            providerID: OfficialProviderAuth.codexProviderID,
            messages: [
                [
                    "role": "assistant",
                    "content": "",
                    "responses_continuation_items": [reasoningItem.inputItem],
                    "responses_continuation_scope": "codex-account-scope",
                    "tool_calls": [[
                        "id": "call-1",
                        "type": "function",
                        "function": [
                            "name": "execute_terminal_command",
                            "arguments": "{\"command\":\"pwd\"}",
                        ],
                    ]],
                ],
                ["role": "tool", "tool_call_id": "call-1", "content": "/tmp"],
            ],
            model: "gpt-5.6-sol",
            baseURL: "https://chatgpt.com/backend-api/codex",
            apiKey: "",
            streaming: true,
            responsesContinuationScope: "codex-account-scope"
        )

        let body = LLMClient.shared.buildResponsesBody(config)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String }, ["reasoning", "function_call", "function_call_output"])
        XCTAssertEqual(input[0]["id"] as? String, "rs_123")
        XCTAssertEqual(input[0]["encrypted_content"] as? String, "opaque-reasoning-state")
        XCTAssertEqual(input[1]["call_id"] as? String, "call-1")
        XCTAssertEqual(input[2]["call_id"] as? String, "call-1")

        let switchedConfig = LLMClient.Config(
            providerID: GrokSubscriptionAuth.providerID,
            messages: config.messages,
            model: "grok-code-fast-1",
            baseURL: GrokSubscriptionAuth.proxyBaseURL,
            apiKey: "",
            streaming: true,
            responsesContinuationScope: "different-provider-scope"
        )
        let switchedBody = LLMClient.shared.buildResponsesBody(switchedConfig)
        let switchedInput = try XCTUnwrap(switchedBody["input"] as? [[String: Any]])
        XCTAssertEqual(switchedInput.map { $0["type"] as? String }, ["function_call", "function_call_output"])
    }

    func testResponsesContinuationScopeChangesAcrossAccountsAndProviders() {
        let firstSession = OfficialProviderAuth.Session(
            providerID: OfficialProviderAuth.codexProviderID,
            accessToken: "rotating-access-token",
            baseURL: CodexSubscriptionAuth.baseURL,
            wireProtocol: .responses,
            headers: ["ChatGPT-Account-ID": "account-1"],
            accountLabel: "first@example.com",
            project: nil
        )
        let rotatedSession = OfficialProviderAuth.Session(
            providerID: OfficialProviderAuth.codexProviderID,
            accessToken: "new-access-token",
            baseURL: CodexSubscriptionAuth.baseURL,
            wireProtocol: .responses,
            headers: ["ChatGPT-Account-ID": "account-1"],
            accountLabel: "first@example.com",
            project: nil
        )
        let secondSession = OfficialProviderAuth.Session(
            providerID: OfficialProviderAuth.codexProviderID,
            accessToken: "other-access-token",
            baseURL: CodexSubscriptionAuth.baseURL,
            wireProtocol: .responses,
            headers: ["ChatGPT-Account-ID": "account-2"],
            accountLabel: "second@example.com",
            project: nil
        )

        let firstScope = OfficialProviderAuth.responsesContinuationScope(
            providerID: OfficialProviderAuth.codexProviderID,
            baseURL: CodexSubscriptionAuth.baseURL,
            apiKey: "",
            session: firstSession
        )
        let rotatedScope = OfficialProviderAuth.responsesContinuationScope(
            providerID: OfficialProviderAuth.codexProviderID,
            baseURL: CodexSubscriptionAuth.baseURL,
            apiKey: "",
            session: rotatedSession
        )
        let secondScope = OfficialProviderAuth.responsesContinuationScope(
            providerID: OfficialProviderAuth.codexProviderID,
            baseURL: CodexSubscriptionAuth.baseURL,
            apiKey: "",
            session: secondSession
        )
        let apiKeyScope = OfficialProviderAuth.responsesContinuationScope(
            providerID: "openai",
            baseURL: "https://api.openai.com/v1",
            apiKey: "api-key",
            session: nil
        )

        XCTAssertEqual(firstScope, rotatedScope)
        XCTAssertNotEqual(firstScope, secondScope)
        XCTAssertNotEqual(firstScope, apiKeyScope)
        XCTAssertFalse(firstScope.contains("rotating-access-token"))
    }

    func testResponsesStreamingRejectsTerminalFailuresAndVerificationRequiresOutput() throws {
        let events: [[String: Any]] = [
            ["type": "error", "message": "quota exhausted"],
            ["type": "response.failed", "response": ["error": ["message": "model unavailable"]]],
            ["type": "response.incomplete", "response": ["incomplete_details": ["reason": "max_output_tokens"]]],
        ]

        for event in events {
            let error = try XCTUnwrap(LLMClient.responsesStreamingTerminalError(from: event))
            guard case let .invalidRequest(message) = error else {
                return XCTFail("Expected a Responses terminal failure")
            }
            XCTAssertTrue(message.contains("Responses API stream failed"))
        }
        XCTAssertNil(LLMClient.responsesStreamingTerminalError(from: ["type": "response.completed"]))
        XCTAssertFalse(LLMClient.Response(thinking: nil, content: "", toolCalls: []).hasUsableVerificationOutput)
        XCTAssertTrue(LLMClient.Response(thinking: nil, content: "OK", toolCalls: []).hasUsableVerificationOutput)
    }

    func testOfficialProviderGuideLabelsUseGuideIconContract() throws {
        for providerID in OfficialProviderAuth.providerIDs {
            let info = try XCTUnwrap(OfficialProviderAuth.info(for: providerID))
            XCTAssertTrue(info.setupLabel.contains("Guide"))
        }
    }

    func testOfficialProviderSignInTaskCoordinatorCancelsAndAwaitsMatchingTask() async {
        let coordinator = OfficialProviderSignInTaskCoordinator()
        var observedCancellation = false

        XCTAssertTrue(coordinator.start(providerID: CodexSubscriptionAuth.providerID) {
            while !Task.isCancelled {
                await Task.yield()
            }
            observedCancellation = true
        })
        XCTAssertEqual(coordinator.providerID, CodexSubscriptionAuth.providerID)

        let didCancel = await coordinator.cancelAndWait(providerID: CodexSubscriptionAuth.providerID)
        XCTAssertTrue(didCancel)
        XCTAssertTrue(observedCancellation)
        XCTAssertNil(coordinator.providerID)
    }

    private static let basePromptMarker = "You are a voice-to-text dictation cleaner"

    private func resetPromptSettings(_ settings: SettingsStore) {
        settings.dictationPromptProfiles = []
        settings.appPromptBindings = []
        settings.selectedDictationPromptID = nil
        settings.isDictationPromptOff = false
        settings.dictationPromptRoutingScope = .allApps
        settings.defaultDictationPromptOverride = nil
        settings.sendCustomPromptOnly = false
    }

    private func withPromptSettingsRestored(run: () -> Void) {
        let settings = SettingsStore.shared
        let profiles = settings.dictationPromptProfiles
        let appBindings = settings.appPromptBindings
        let selectedDictationPromptID = settings.selectedDictationPromptID
        let isDictationPromptOff = settings.isDictationPromptOff
        let dictationPromptRoutingScope = settings.dictationPromptRoutingScope
        let defaultDictationPromptOverride = settings.defaultDictationPromptOverride
        let sendCustomPromptOnly = settings.sendCustomPromptOnly

        defer {
            settings.dictationPromptProfiles = profiles
            settings.appPromptBindings = appBindings
            settings.selectedDictationPromptID = selectedDictationPromptID
            settings.isDictationPromptOff = isDictationPromptOff
            settings.dictationPromptRoutingScope = dictationPromptRoutingScope
            settings.defaultDictationPromptOverride = defaultDictationPromptOverride
            settings.sendCustomPromptOnly = sendCustomPromptOnly
        }

        run()
    }

    private func chatMessageContents(from body: [String: Any]) -> [String] {
        guard let messages = body["messages"] as? [[String: Any]] else { return [] }
        return messages.compactMap { $0["content"] as? String }
    }

    private func jwt(_ claims: [String: Any]) -> String {
        let header = Data("{\"alg\":\"none\"}".utf8).base64EncodedString()
        let payload = (try? JSONSerialization.data(withJSONObject: claims).base64EncodedString()) ?? ""
        func base64URL(_ value: String) -> String {
            value.replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }
}

private class CancellingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}
