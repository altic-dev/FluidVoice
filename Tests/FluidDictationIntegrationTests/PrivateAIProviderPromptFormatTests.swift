@testable import FluidVoice_Debug
import XCTest

@MainActor
final class PrivateAIProviderPromptFormatTests: XCTestCase {
    func testProviderTaskDefaultKeepsDictationAndHidesOtherModes() {
        let provider = TaskDefaultPrivateAIProvider()

        XCTAssertEqual(provider.modelIDs(for: .dictation), ["dictation-model"])
        XCTAssertEqual(provider.modelIDs(for: .edit), [])
        XCTAssertEqual(provider.modelIDs(for: .command), [])
    }

    func testTaskFilteringDoesNotChangeRemoteProviderDefaults() {
        let repository = ModelRepository.shared

        XCTAssertEqual(
            repository.defaultModels(for: "openai", task: .edit),
            repository.defaultModels(for: "openai")
        )
        XCTAssertEqual(
            repository.defaultModels(for: "anthropic", task: .command),
            repository.defaultModels(for: "anthropic")
        )
    }

    func testEligibleTaskModelPreservesAValidNonFirstSelection() {
        let models = ["edit-model-a", "edit-model-b"]

        XCTAssertEqual(
            ModelRepository.eligibleModel(preferred: "edit-model-b", from: models),
            "edit-model-b"
        )
        XCTAssertEqual(
            ModelRepository.eligibleModel(preferred: "dictation-only", from: models),
            "edit-model-a"
        )
    }

    func testModelScopedVerificationIsIndependentFromProviderSelection() {
        self.withRestoredFingerprints { settings in
            settings.verifiedProviderFingerprints = ["private": "model-a-fingerprint"]
            settings.verifiedPrivateAIModelFingerprints = [:]

            XCTAssertFalse(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-b",
                    providerKey: "private",
                    expectedFingerprint: "model-b-fingerprint",
                    settings: settings
                )
            )

            settings.verifiedPrivateAIModelFingerprints = ["model-b": "model-b-fingerprint"]

            XCTAssertTrue(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-b",
                    providerKey: "private",
                    expectedFingerprint: "model-b-fingerprint",
                    settings: settings
                )
            )
            XCTAssertFalse(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-b",
                    providerKey: "private",
                    expectedFingerprint: "stale-fingerprint",
                    settings: settings
                )
            )
        }
    }

    func testLegacyProviderFingerprintRemainsValid() {
        self.withRestoredFingerprints { settings in
            settings.verifiedPrivateAIModelFingerprints = [:]
            settings.verifiedProviderFingerprints = ["private": "legacy-fingerprint"]

            XCTAssertTrue(
                PrivateAIProviderPromptFormat.hasStoredVerification(
                    for: "model-a",
                    providerKey: "private",
                    expectedFingerprint: "legacy-fingerprint",
                    settings: settings
                )
            )
        }
    }

    private func withRestoredFingerprints(_ body: (SettingsStore) -> Void) {
        let settings = SettingsStore.shared
        let providerFingerprints = settings.verifiedProviderFingerprints
        let modelFingerprints = settings.verifiedPrivateAIModelFingerprints
        defer {
            settings.verifiedProviderFingerprints = providerFingerprints
            settings.verifiedPrivateAIModelFingerprints = modelFingerprints
        }
        body(settings)
    }
}

private struct TaskDefaultPrivateAIProvider: PrivateAIProviderFeatureProviding {
    let isAvailable = true
    let providerID = "private-test"
    let providerName = "Private Test"
    let promptSelectionID = "private-test"
    let defaultModelID = "dictation-model"
    let selectedModelDefaultsKey = "private-test-model"
    let localModelPathDefaultsKey = "private-test-path"
    let prefixCacheDefaultsKey = "private-test-cache"
    let boostDefaultsKey = "private-test-boost"
    let modelDirectoryName = "PrivateTest"

    func modelIDs() -> [String] { ["dictation-model"] }
    func model(id _: String) -> PrivateAIRegisteredModel? { nil }
    func canonicalModelID(for _: String) -> String? { nil }
    func isKnownModelID(_: String) -> Bool { false }
}
