@testable import Voix_Debug
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
}
