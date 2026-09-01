@testable import FluidVoice_Debug
import XCTest

@MainActor
final class PrivateAIProviderPromptFormatTests: XCTestCase {
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
