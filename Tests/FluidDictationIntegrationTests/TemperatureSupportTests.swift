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

    func testTemperatureSupported_olderAndNonAnthropicModels() {
        let supported = [
            "gpt-4.1",
            "claude-sonnet-4-6",
            "claude-sonnet-4-20250514",
            "gemini-2.5-flash",
            "llama3",
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
