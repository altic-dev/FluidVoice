import AppKit
import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import SwiftUI
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
            "parakeet-tdt-v3",
            "parakeet-tdt-v99",
            "whisper-tiny",
            "fluid-parakeet-mini",
            "fluid-parakeet-pico",
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

    func testResolveRejectsNonEnglishLanguageCodeForV2() {
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "parakeet-tdt-v2", languageCode: "de")
        XCTAssertThrowsError(try MeetingProviderOptions.resolve(configuration)) { error in
            XCTAssertEqual(
                error as? MeetingProviderOptionsError,
                .unsupportedLanguageCode("de")
            )
        }
    }

    func testSupportedLanguagesResolveToPinnedModelsWithoutEnhancements() throws {
        for language in VoiceEngineLanguageCatalog.parakeetV3LanguageIDs {
            let configuration = MeetingFinalProcessingConfiguration(languageCode: language)
            let options = try MeetingProviderOptions.resolve(configuration)
            XCTAssertEqual(options.model, language == "en" ? .parakeetTDTv2 : .parakeetTDT)
            XCTAssertFalse(options.vocabularyBoostingEnabled)
            XCTAssertFalse(options.pronunciationMatchingEnabled)
            XCTAssertFalse(options.customDictionaryRewritingEnabled)
            XCTAssertFalse(options.experimentalUnifiedFinalEnabled)
            let capture = MeetingCaptureConfiguration(
                mode: .inRoom,
                title: "Multilingual meeting",
                languageCode: language,
                microphone: .init(captureDeviceID: "fixture", displayName: "Fixture")
            )
            try capture.validate()
            let session = MeetingSession(configuration: capture, timebase: .init(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
            try session.validateForPersistence()
            let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session))
            XCTAssertEqual(restored.languageCode, language)
        }
        XCTAssertThrowsError(try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(languageCode: "zh")))
    }

    func testV3PinsProviderAndChangesResumeFingerprint() throws {
        let configuration = MeetingFinalProcessingConfiguration(languageCode: "de")
        let provider = try FluidAudioProvider(meetingConfiguration: configuration)
        #if arch(arm64)
        XCTAssertEqual(provider.modelOverride, .parakeetTDT)
        #endif
        XCTAssertNotEqual(configuration.identityFingerprint, MeetingFinalProcessingConfiguration().identityFingerprint)
    }

    func testLegacyDefaultsDecodeWithoutLanguageAndNewDefaultsPersistIt() throws {
        let encoder = JSONEncoder()
        let original = MeetingRecordingDefaults.unconfigured
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        json.removeValue(forKey: "languageCode")
        let legacy = try JSONDecoder().decode(MeetingRecordingDefaults.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.languageCode)
        XCTAssertEqual(legacy.mode, original.mode)
        var configured = original
        configured.languageCode = "de"
        XCTAssertEqual(try JSONDecoder().decode(MeetingRecordingDefaults.self, from: encoder.encode(configured)).languageCode, "de")
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

    @MainActor
    func testOptInMeetingLanguageSettingsSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["FLUIDVOICE_MEETING_SETTINGS_SNAPSHOT"] else {
            throw XCTSkip("Set FLUIDVOICE_MEETING_SETTINGS_SNAPSHOT for a settings visual check")
        }
        var draft = MeetingTranscriptionSetupDraft()
        draft.languageCode = "de"
        let view = MeetingRecordingSettingsSheet(
            draft: .constant(draft),
            retentionPolicy: .constant(SettingsStore.shared.meetingAudioRetentionPolicy),
            applications: [],
            microphones: [],
            readiness: .checking,
            isFirstSetup: false,
            onRefreshSources: {},
            onOpenMicrophoneSettings: {},
            onOpenScreenRecordingSettings: {},
            onOpenVoiceEngine: {},
            onCancel: {},
            onSave: {}
        )
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let host = NSHostingView(rootView: view.appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme)).environment(\.colorScheme, scheme))
            host.frame = NSRect(x: 0, y: 0, width: 820, height: 720)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("meeting-language-\(name).png"))
        }
    }

    #if arch(arm64)
    @MainActor
    func testOptInGermanV3AudioProducesOriginalLanguageAndWordTimings() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLUIDVOICE_MEETING_GERMAN_FIXTURE"] else {
            throw XCTSkip("Set FLUIDVOICE_MEETING_GERMAN_FIXTURE to a 16 kHz mono German WAV for model verification")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let selected = SettingsStore.shared.selectedSpeechModel
        let provider = try FluidAudioProvider(meetingConfiguration: .init(languageCode: "de"))
        try await provider.prepare(progressHandler: nil)
        let output = try await provider.transcribeWithWordTimings(samples)
        print("Meeting v3 German smoke: \(output.result.text); words=\(output.words.count)")
        XCTAssertTrue(output.result.text.lowercased().contains("morgen"))
        XCTAssertTrue(output.result.text.lowercased().contains("freitag"))
        XCTAssertFalse(output.words.isEmpty)
        XCTAssertTrue(output.words.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= Double(samples.count) / 16_000 + 0.1 })
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selected)
    }
    #endif

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
