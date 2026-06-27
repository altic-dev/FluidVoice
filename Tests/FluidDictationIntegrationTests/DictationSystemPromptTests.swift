@testable import FluidVoice_Debug
import XCTest

// Regression tests for https://github.com/altic-dev/FluidVoice/issues/388
// AI enhancement instructions must be sent in the system role, not the user message.
// Previously, DictationPostProcessingService hardcoded systemPrompt = "" and folded
// the instruction text into the user message alongside the transcript.

@MainActor
final class DictationSystemPromptTests: XCTestCase {
    // MARK: - effectiveDictationSystemPrompt

    func testEffectiveDictationSystemPrompt_returnsConfiguredPrompt() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            let custom = SettingsStore.DictationPromptProfile(
                name: "Test Profile",
                prompt: "Clean up the transcript. Remove filler words.",
                mode: .dictate
            )
            settings.dictationPromptProfiles = [custom]
            settings.selectedDictationPromptID = custom.id

            let result = settings.effectiveDictationSystemPrompt(for: .primary)
            XCTAssertFalse(result.isEmpty, "effectiveDictationSystemPrompt must return the configured prompt, not an empty string")
            XCTAssertTrue(result.contains("Clean up the transcript"), "system prompt must include the custom instruction text")
        }
    }

    func testEffectiveDictationSystemPrompt_offSelection_returnsDefault() {
        self.withPromptSettingsRestored {
            let settings = SettingsStore.shared
            settings.setDictationPromptSelection(.off)

            // When off, effectiveDictationSystemPrompt falls back to the built-in default,
            // which is non-empty. This ensures the system field is never silently blank.
            let result = settings.effectiveDictationSystemPrompt(for: .primary)
            XCTAssertFalse(result.isEmpty, "built-in default prompt must be non-empty")
        }
    }

    // MARK: - renderSystemPrompt (${transcript} placeholder in the system role)

    func testRenderSystemPrompt_noPlaceholder_returnsPromptUnchanged() {
        let prompt = "Clean up the transcript."
        let result = SettingsStore.renderSystemPrompt(promptText: prompt, transcript: "hello world")
        XCTAssertEqual(result, prompt, "prompt without placeholder must be returned unchanged")
    }

    func testRenderSystemPrompt_transcriptPlaceholder_isSubstitutedInSystemRole() {
        // Users can embed ${transcript} in their system prompt template so the transcript
        // appears inline in their instructions. renderSystemPrompt must substitute it before
        // the prompt is sent to the provider as the system message.
        let prompt = "Rewrite cleanly: \(SettingsStore.transcriptPlaceholder)"
        let transcript = "um so like yeah"
        let result = SettingsStore.renderSystemPrompt(promptText: prompt, transcript: transcript)
        XCTAssertEqual(result, "Rewrite cleanly: um so like yeah")
    }

    // MARK: - Helpers

    private func withPromptSettingsRestored(_ run: () -> Void) {
        let keys = [
            "DictationPromptProfiles",
            "SelectedDictationPromptID",
            "DictationPromptOff",
        ]
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in keys {
            if let v = defaults.object(forKey: key) { snapshot[key] = v }
        }
        defer {
            for key in keys {
                if let v = snapshot[key] { defaults.set(v, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        run()
    }
}
