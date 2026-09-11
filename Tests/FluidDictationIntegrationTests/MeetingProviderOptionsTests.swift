@testable import FluidVoice_Debug
import XCTest

final class MeetingProviderOptionsTests: XCTestCase {
    func testDefaultMeetingConfigurationResolvesToPinnedParakeetTDTv2EnglishPolicy() throws {
        let options = try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration())
        XCTAssertEqual(options.model, .parakeetTDTv2)
        XCTAssertFalse(options.vocabularyBoostingEnabled)
        XCTAssertFalse(options.pronunciationMatchingEnabled)
        XCTAssertFalse(options.customDictionaryRewritingEnabled)
        XCTAssertFalse(options.experimentalUnifiedFinalEnabled)
    }

    func testP1DefaultASRModelMatchesSpeechModelRawValue() {
        XCTAssertEqual(
            MeetingFinalProcessingConfiguration.defaultASRModel,
            SettingsStore.SpeechModel.parakeetTDTv2.rawValue
        )
    }

    func testResolveRejectsUnsupportedModelsWithoutRelabeling() {
        let unsupportedModels = [
            "parakeet-tdt",     // raw value of the v3 multilingual model
            "parakeet-tdt-v3",
            "parakeet-tdt-v99",
            "whisper-tiny",
            "",
        ]
        for asrModel in unsupportedModels {
            let configuration = MeetingFinalProcessingConfiguration(asrModel: asrModel)
            XCTAssertThrowsError(try MeetingProviderOptions.resolve(configuration)) { error in
                XCTAssertEqual(
                    error as? MeetingProviderOptionsError,
                    .unsupportedASRModel(asrModel)
                )
            }
        }
    }

    func testResolveRejectsNonEnglishLanguageCode() {
        let configuration = MeetingFinalProcessingConfiguration(languageCode: "de")
        XCTAssertThrowsError(try MeetingProviderOptions.resolve(configuration)) { error in
            XCTAssertEqual(
                error as? MeetingProviderOptionsError,
                .unsupportedLanguageCode("de")
            )
        }
    }

    func testResolveRejectsEveryEnhancementFlag() {
        let cases: [(MeetingFinalProcessingConfiguration, String)] = [
            (MeetingFinalProcessingConfiguration(vocabularyBoostingEnabled: true), "vocabularyBoosting"),
            (MeetingFinalProcessingConfiguration(pronunciationMatchingEnabled: true), "pronunciationMatching"),
            (MeetingFinalProcessingConfiguration(customDictionaryRewritingEnabled: true), "customDictionaryRewriting"),
            (MeetingFinalProcessingConfiguration(experimentalUnifiedFinalEnabled: true), "experimentalUnifiedFinal"),
        ]
        for (configuration, feature) in cases {
            XCTAssertThrowsError(try MeetingProviderOptions.resolve(configuration)) { error in
                XCTAssertEqual(
                    error as? MeetingProviderOptionsError,
                    .unsupportedFeature(feature)
                )
            }
        }
    }

    func testMeetingConstructorPinsModelOverrideImmutably() throws {
        let provider = try FluidAudioProvider(meetingConfiguration: MeetingFinalProcessingConfiguration())
        // The Intel stub stores no modelOverride; the pinning assertion is arm64-only.
        #if arch(arm64)
        XCTAssertEqual(provider.modelOverride, .parakeetTDTv2)
        #endif
        XCTAssertFalse(provider.isWordBoostingActive)
        XCTAssertEqual(provider.boostedVocabularyTermsCount, 0)
    }

    func testMeetingConstructorRejectsUnsupportedConfiguration() {
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "parakeet-tdt-v3")
        XCTAssertThrowsError(try FluidAudioProvider(meetingConfiguration: configuration)) { error in
            XCTAssertEqual(
                error as? MeetingProviderOptionsError,
                .unsupportedASRModel("parakeet-tdt-v3")
            )
        }
    }

    #if arch(arm64)
    func testLegacyConstructorsKeepDynamicModelResolution() {
        XCTAssertNil(FluidAudioProvider().modelOverride)
        XCTAssertNil(FluidAudioProvider(configureWordBoosting: false).modelOverride)
        XCTAssertEqual(
            FluidAudioProvider(modelOverride: .parakeetTDT, configureWordBoosting: false).modelOverride,
            .parakeetTDT
        )
    }
    #endif
}
