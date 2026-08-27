@testable import FluidVoice_Debug
import XCTest

// Regression tests for the Anthropic `temperature` deprecation handling.
// Newer Anthropic models (Opus 4.7+, Sonnet 5, Fable/Mythos 5) reject the `temperature`
// parameter with HTTP 400 "`temperature` is deprecated for this model."
// See https://github.com/altic-dev/FluidVoice/issues/285 (Opus 4.7) — the same failure
// recurred for Sonnet 5 because the check only matched claude-opus-4-7.
// Sonnet 4.6 and older still accept `temperature` (verified against the live API)
// and must keep receiving the app's tuned values.

@MainActor
final class TemperatureSupportTests: XCTestCase {
    func testTemperatureUnsupported_newerAnthropicModels() {
        let unsupported = [
            "claude-opus-4-7",
            "claude-opus-4-8",
            "claude-sonnet-5",
            "claude-fable-5",
            "claude-mythos-5",
            // Provider-prefixed and dotted IDs (e.g. OpenRouter) must match too
            "anthropic/claude-sonnet-5",
            "anthropic/claude-opus-4.7",
            "anthropic/claude-opus-4.8",
            "anthropic/claude-opus-4.8-fast",
        ]
        for model in unsupported {
            XCTAssertTrue(
                SettingsStore.shared.isTemperatureUnsupported(model),
                "\(model) rejects `temperature` — sending it fails with HTTP 400"
            )
        }
    }

    func testTemperatureUnsupported_openAIReasoningModels() {
        for model in ["o1", "o3-mini", "gpt-5", "openai/gpt-oss-120b"] {
            XCTAssertTrue(
                SettingsStore.shared.isTemperatureUnsupported(model),
                "\(model) is a reasoning model and must not receive `temperature`"
            )
        }
    }

    func testIsReasoningModel_doesNotMatchEveryOpenAIModel() {
        // Regression: isReasoningModel matched the whole "openai/" prefix, so
        // every OpenAI model on a provider like OpenRouter was mis-classified
        // as a reasoning model and lost temperature control. Only actual
        // reasoning model families should match.
        let nonReasoning = [
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-4.1",
            "chatgpt-4o-latest",
            // Provider-prefixed (e.g. OpenRouter) non-reasoning IDs — the bug case
            "openai/gpt-4o",
            "openai/gpt-4.1",
            "openai/gpt-4o-mini",
            "openai/chatgpt-4o-latest",
        ]
        for model in nonReasoning {
            XCTAssertFalse(
                SettingsStore.shared.isReasoningModel(model),
                "\(model) is not a reasoning model and must keep temperature control"
            )
        }

        // Control: known reasoning models still classify as reasoning, both
        // bare and provider-prefixed.
        let reasoning = [
            "o1", "o3-mini", "o4-mini", "gpt-5", "gpt-5-mini",
            "openai/o3", "openai/o3-mini", "openai/gpt-5", "openai/gpt-oss-120b",
            "deepseek/deepseek-reasoner",
        ]
        for model in reasoning {
            XCTAssertTrue(
                SettingsStore.shared.isReasoningModel(model),
                "\(model) is a reasoning model"
            )
        }
    }

    func testTemperatureSupported_olderAndNonAnthropicModels() {
        let supported = [
            "gpt-4.1",
            "claude-sonnet-4-6",
            "claude-sonnet-4-20250514",
            "gemini-2.5-flash",
            "llama3",
            // OpenRouter-prefixed non-reasoning OpenAI models keep temperature
            "openai/gpt-4o",
            "openai/gpt-4.1",
            // Dotted OpenRouter IDs for models that still accept temperature
            "anthropic/claude-sonnet-4.6",
            "anthropic/claude-sonnet-4.5",
            "anthropic/claude-opus-4.5",
        ]
        for model in supported {
            XCTAssertFalse(
                SettingsStore.shared.isTemperatureUnsupported(model),
                "\(model) still supports `temperature` and should keep receiving it"
            )
        }
    }
}
