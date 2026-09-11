@testable import FluidASRBaselineHost
import XCTest

/// Pins the explicit `enhancementOptions` path of `FluidAudioProvider`. These tests never
/// touch `SettingsStore.shared` and never prepare models; under the baseline host any
/// transitive settings/credentials access would trip the `KeychainService` fatalError guard.
@MainActor
final class ProviderEnhancementOptionsTests: XCTestCase {
    private func makeEntry() -> SettingsStore.CustomDictionaryEntry {
        SettingsStore.CustomDictionaryEntry(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            triggers: ["fluid voice", "fluid boys"],
            replacement: "FluidVoice"
        )
    }

    func testExplicitEnhancementOptionsDriveEffectiveGetters() {
        let entry = self.makeEntry()
        let options = FluidAudioProviderEnhancementOptions(
            experimentalUnifiedFinalEnabled: true,
            pronunciationMatchingEnabled: true,
            customDictionaryEntries: [entry]
        )
        let provider = FluidAudioProvider(configureWordBoosting: false, enhancementOptions: options)
        #if arch(arm64) && DEBUG
        let snapshot = provider.effectiveEnhancementOptionsForTesting
        XCTAssertTrue(snapshot.experimentalUnifiedFinalEnabled)
        XCTAssertTrue(snapshot.pronunciationMatchingEnabled)
        XCTAssertEqual(snapshot.customDictionaryEntries, [entry])
        #endif
    }

    func testExplicitlyDisabledOptionsAreNotTreatedAsNil() {
        let options = FluidAudioProviderEnhancementOptions(
            experimentalUnifiedFinalEnabled: false,
            pronunciationMatchingEnabled: false,
            customDictionaryEntries: []
        )
        let provider = FluidAudioProvider(enhancementOptions: options)
        #if arch(arm64) && DEBUG
        let snapshot = provider.effectiveEnhancementOptionsForTesting
        XCTAssertFalse(snapshot.experimentalUnifiedFinalEnabled)
        XCTAssertFalse(snapshot.pronunciationMatchingEnabled)
        XCTAssertTrue(snapshot.customDictionaryEntries.isEmpty)
        #endif
    }

    func testMeetingProviderKeepsFixedAllDisabledPolicy() throws {
        let provider = try FluidAudioProvider(meetingConfiguration: MeetingFinalProcessingConfiguration())
        #if arch(arm64) && DEBUG
        let snapshot = provider.effectiveEnhancementOptionsForTesting
        XCTAssertFalse(snapshot.experimentalUnifiedFinalEnabled)
        XCTAssertFalse(snapshot.pronunciationMatchingEnabled)
        XCTAssertTrue(snapshot.customDictionaryEntries.isEmpty)
        #endif
    }
}
