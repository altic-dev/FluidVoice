@testable import FluidVoice_Debug
import XCTest

final class MeetingProcessingConfigurationTests: XCTestCase {
    func testFinalConfigurationDefaultsAreParakeetTDTv2EnglishWithoutPostProcessing() {
        let config = MeetingFinalProcessingConfiguration()
        XCTAssertEqual(config.asrModel, "parakeet-tdt-v2")
        XCTAssertEqual(config.languageCode, "en")
        XCTAssertFalse(config.vocabularyBoostingEnabled)
        XCTAssertFalse(config.pronunciationMatchingEnabled)
        XCTAssertFalse(config.customDictionaryRewritingEnabled)
        XCTAssertFalse(config.experimentalUnifiedFinalEnabled)
        XCTAssertEqual(config.pipelineVersion, MeetingFinalProcessingConfiguration.defaultPipelineVersion)
        XCTAssertEqual(config.diarizationFingerprint, MeetingProcessingCheckpoint.currentDiarizationFingerprint)
    }

    @MainActor
    func testFinalConfigurationDefaultPipelineVersionMatchesPipelineConstant() {
        XCTAssertEqual(
            MeetingFinalProcessingConfiguration.defaultPipelineVersion,
            MeetingProcessingPipeline.pipelineVersion
        )
    }

    func testFinalIdentityFingerprintIsStableAndCoversEveryEffectiveField() {
        let base = MeetingFinalProcessingConfiguration()
        XCTAssertEqual(base.identityFingerprint, MeetingFinalProcessingConfiguration().identityFingerprint)
        XCTAssertTrue(base.identityFingerprint.hasPrefix("v\(MeetingConfigFingerprintEncoding.version);"))

        let variants: [MeetingFinalProcessingConfiguration] = [
            MeetingFinalProcessingConfiguration(asrModel: "parakeet-tdt-v3"),
            MeetingFinalProcessingConfiguration(languageCode: "de"),
            MeetingFinalProcessingConfiguration(vocabularyBoostingEnabled: true),
            MeetingFinalProcessingConfiguration(pronunciationMatchingEnabled: true),
            MeetingFinalProcessingConfiguration(customDictionaryRewritingEnabled: true),
            MeetingFinalProcessingConfiguration(experimentalUnifiedFinalEnabled: true),
            MeetingFinalProcessingConfiguration(diarizationFingerprint: "other"),
            MeetingFinalProcessingConfiguration(pipelineVersion: base.pipelineVersion + 1),
        ]
        for variant in variants {
            XCTAssertNotEqual(variant.identityFingerprint, base.identityFingerprint)
        }
        XCTAssertTrue(base.identityFingerprint.contains(MeetingProcessingCheckpoint.currentDiarizationFingerprint))
        XCTAssertTrue(base.identityFingerprint.contains("pipeline"))
        XCTAssertTrue(base.identityFingerprint.contains(String(base.pipelineVersion)))
    }

    func testFinalIdentityFingerprintHasNoDelimiterCollisions() {
        let splitAt = MeetingFinalProcessingConfiguration(asrModel: "a@b", languageCode: "c")
        let splitAtLanguage = MeetingFinalProcessingConfiguration(asrModel: "a", languageCode: "b@c")
        XCTAssertNotEqual(splitAt.identityFingerprint, splitAtLanguage.identityFingerprint)

        let semicolonKey = MeetingFinalProcessingConfiguration(asrModel: "x;lang=de")
        let plain = MeetingFinalProcessingConfiguration(languageCode: "de", vocabularyBoostingEnabled: false)
        XCTAssertNotEqual(semicolonKey.identityFingerprint, plain.identityFingerprint)
    }

    func testLiveCaptionsDefaultsMatchStreamingEouIdentity() {
        let config = MeetingLiveCaptionsConfiguration()
        XCTAssertEqual(config.modelRepositoryID, "FluidInference/parakeet-realtime-eou-120m-coreml")
        XCTAssertEqual(config.modelVariant, "160ms")
        XCTAssertEqual(config.chunkSizeMilliseconds, 160)
        XCTAssertEqual(config.languageCode, "en")
        XCTAssertEqual(config.modelRevision, "main")
    }

    func testLiveCaptionsFingerprintIsStableAndDoesNotClaimResolvedRevision() {
        let base = MeetingLiveCaptionsConfiguration()
        XCTAssertEqual(base.identityFingerprint, MeetingLiveCaptionsConfiguration().identityFingerprint)
        XCTAssertTrue(base.identityFingerprint.hasPrefix("v\(MeetingConfigFingerprintEncoding.version);"))
        XCTAssertTrue(base.identityFingerprint.contains("FluidInference/parakeet-realtime-eou-120m-coreml"))
        XCTAssertTrue(base.identityFingerprint.contains("160ms"))
        XCTAssertTrue(base.identityFingerprint.contains("unresolved"))
        // A resolved HF pin would be a full commit SHA; the loader only selects the branch.
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertFalse(
            base.modelRevision.count == 40
                && base.modelRevision.unicodeScalars.allSatisfy(hex.contains)
        )
    }

    func testLiveCaptionsFingerprintChangesForEveryField() {
        let base = MeetingLiveCaptionsConfiguration()
        let variants: [MeetingLiveCaptionsConfiguration] = [
            MeetingLiveCaptionsConfiguration(modelRepositoryID: "FluidInference/parakeet-realtime-eou-200m-coreml"),
            MeetingLiveCaptionsConfiguration(modelVariant: "320ms"),
            MeetingLiveCaptionsConfiguration(modelRevision: "release"),
            MeetingLiveCaptionsConfiguration(chunkSizeMilliseconds: 320),
            MeetingLiveCaptionsConfiguration(languageCode: "de"),
        ]
        for variant in variants {
            XCTAssertNotEqual(variant.identityFingerprint, base.identityFingerprint)
        }
    }

    func testLiveCaptionsFingerprintHasNoDelimiterCollisions() {
        let splitRepo = MeetingLiveCaptionsConfiguration(modelRepositoryID: "x/y", modelVariant: "z")
        let splitVariant = MeetingLiveCaptionsConfiguration(modelRepositoryID: "x", modelVariant: "y/z")
        XCTAssertNotEqual(splitRepo.identityFingerprint, splitVariant.identityFingerprint)
    }

    func testConfigurationsBehaveAsEquatableValueSnapshots() {
        let final = MeetingFinalProcessingConfiguration()
        let finalCopy = final
        XCTAssertEqual(final, finalCopy)
        XCTAssertEqual(final, MeetingFinalProcessingConfiguration())
        XCTAssertNotEqual(final, MeetingFinalProcessingConfiguration(vocabularyBoostingEnabled: true))
        XCTAssertNotEqual(final, MeetingFinalProcessingConfiguration(pipelineVersion: final.pipelineVersion + 1))

        let captions = MeetingLiveCaptionsConfiguration()
        XCTAssertEqual(captions, MeetingLiveCaptionsConfiguration())
        XCTAssertNotEqual(captions, MeetingLiveCaptionsConfiguration(modelRevision: "abc123"))
    }

    func testFingerprintsMatchForCanonicallyEquivalentUnicode() {
        let composedFinal = MeetingFinalProcessingConfiguration(languageCode: "\u{E9}")
        let decomposedFinal = MeetingFinalProcessingConfiguration(languageCode: "e\u{301}")
        XCTAssertEqual(composedFinal, decomposedFinal)
        XCTAssertEqual(composedFinal.identityFingerprint, decomposedFinal.identityFingerprint)

        let composedCaptions = MeetingLiveCaptionsConfiguration(modelRepositoryID: "Caf\u{E9}")
        let decomposedCaptions = MeetingLiveCaptionsConfiguration(modelRepositoryID: "Cafe\u{301}")
        XCTAssertEqual(composedCaptions, decomposedCaptions)
        XCTAssertEqual(composedCaptions.identityFingerprint, decomposedCaptions.identityFingerprint)
    }

    func testFingerprintGoldenEncodingLocksFramingStability() {
        let encoded = MeetingConfigFingerprintEncoding.encode([
            ("asr", "a@b"),
            ("lang", "e\u{301}"),
        ])
        XCTAssertEqual(encoded, "v1;3:asr=3:a@b;4:lang=2:\u{E9}")
    }
}
