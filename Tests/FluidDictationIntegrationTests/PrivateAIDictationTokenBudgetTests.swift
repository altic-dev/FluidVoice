@testable import FluidVoice_Debug
import XCTest

@MainActor
final class PrivateAIDictationTokenBudgetTests: XCTestCase {
    func testPrivateAIDictationTokenBudgetFallsBackBeforeLongInputCanTruncate() {
        let shortTranscript = Array(repeating: "word", count: 600).joined(separator: " ")
        let longTranscript = Array(repeating: "word", count: 3385).joined(separator: " ")
        let tokenDenseIdentifier = String(repeating: "a", count: 6000)
        let unspacedCJKTranscript = String(repeating: "漢", count: 2500)

        XCTAssertTrue(SettingsStore.privateAIDictationTokenBudget(
            forInputText: shortTranscript,
            contextTokenLimit: 4096
        ).hasSufficientHeadroom)
        XCTAssertFalse(SettingsStore.privateAIDictationTokenBudget(
            forInputText: longTranscript,
            contextTokenLimit: 4096
        ).hasSufficientHeadroom)
        XCTAssertFalse(SettingsStore.privateAIDictationTokenBudget(
            forInputText: tokenDenseIdentifier,
            contextTokenLimit: 4096
        ).hasSufficientHeadroom)
        XCTAssertFalse(SettingsStore.privateAIDictationTokenBudget(
            forInputText: unspacedCJKTranscript,
            contextTokenLimit: 4096
        ).hasSufficientHeadroom)
    }

    func testPrivateAIDictationRejectsLongInputBeforeCallingProvider() async {
        await self.assertRejectedBeforeProvider(
            Array(repeating: "word", count: 3385).joined(separator: " "),
            failureMessage: "Expected long dictation to fall back before provider generation"
        )
    }

    func testPrivateAIDictationRejectsTokenDenseInputBeforeCallingProvider() async {
        await self.assertRejectedBeforeProvider(
            String(repeating: "a", count: 6000),
            failureMessage: "Expected token-dense dictation to fall back before provider generation"
        )
    }

    private func assertRejectedBeforeProvider(_ transcript: String, failureMessage: String) async {
        let runtime = PrivateAIIntegrationService.RuntimeConfiguration(
            selectedProviderID: "private",
            providerKey: "private",
            baseURL: "",
            model: "fluid-1",
            apiKey: "",
            localModelPath: nil,
            usesStablePromptPrefixKVCache: true,
            usesFluid1Boost: true,
            contextTokenLimit: 4096
        )
        let context = PrivateAIIntegrationService.AppContext(
            appName: "Notes",
            bundleID: "com.apple.Notes",
            windowTitle: "",
            appVersion: nil
        )

        do {
            _ = try await PrivateAIIntegrationService.shared.enhanceDictation(
                transcript,
                runtime: runtime,
                context: context
            )
            XCTFail(failureMessage)
        } catch AIProcessingError.dictationExceedsAIContextWindow {
            // Expected: ContentView catches this and types the complete raw transcript.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
