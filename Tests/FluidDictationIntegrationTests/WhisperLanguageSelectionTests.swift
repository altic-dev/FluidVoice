@testable import FluidVoice_Debug
import XCTest

final class WhisperLanguageSelectionTests: XCTestCase {
    func testHungarianLanguageCodeIsAvailable() {
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "hu"), "hu")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "hu")?.displayName, "Hungarian")
    }

    func testHebrewUsesWhisperLanguageCode() {
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "he"), "he")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "he")?.displayName, "Hebrew")
    }

    func testWhisperRunOptionsUseSelectedLanguage() {
        XCTAssertEqual(WhisperProvider.runOptions(languageCode: "hu").language, "hu")
    }

    func testWhisperRunOptionsAllowAutomaticDetection() {
        XCTAssertNil(WhisperProvider.runOptions(languageCode: nil).language)
    }

    func testWhisperRunOptionsKeepLanguageFallbackAndTimestamps() {
        let options = WhisperProvider.runOptions(languageCode: nil, whisperLanguageCode: "hu")
        XCTAssertEqual(options.language, "hu")
        XCTAssertEqual(options.timestamps, .segment)
        XCTAssertEqual(WhisperProvider.runOptions(languageCode: "en", whisperLanguageCode: "hu").language, "en")
    }

    func testQwenDetectsLanguageWithoutInheritingWhisperSelection() {
        let options = WhisperProvider.runOptions(languageCode: nil, model: .qwen3Asr17B, whisperLanguageCode: "he")
        XCTAssertNil(options.language)
        XCTAssertEqual(options.timestamps, .none)
    }

    func testQwenHonorsExplicitLanguageWithoutRequestingTimestamps() {
        let options = WhisperProvider.runOptions(languageCode: "en", model: .qwen3Asr17B, whisperLanguageCode: "hu")
        XCTAssertEqual(options.language, "en")
        XCTAssertEqual(options.timestamps, .none)
    }

    func testQwenUsesItsOwnGGUFAndDoesNotExposeWhisperControls() {
        let model = SettingsStore.SpeechModel.qwen3Asr17B
        XCTAssertEqual(model.whisperModelFile, "Qwen3-ASR-1.7B-Q8_0.gguf")
        XCTAssertNil(model.legacyWhisperModelFile)
        XCTAssertEqual(model.provider, .qwen)
        XCTAssertFalse(model.isWhisperModel)
        XCTAssertFalse(model.supportsStreaming)
        XCTAssertFalse(model.hasPerformanceRatings)
        XCTAssertEqual(SettingsStore.SpeechModel.availableModels.contains(model), CPUArchitecture.isAppleSilicon)
        XCTAssertFalse(SettingsStore.SpeechModel.availableModels.contains(.qwen3Asr))
    }

    func testQwenTranscribesFixtureFromExistingModelAndPreservesWhisperCache() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["FLUIDVOICE_QWEN_MODEL_PATH"] else {
            throw XCTSkip("Set FLUIDVOICE_QWEN_MODEL_PATH to an existing Qwen GGUF for the local inference check.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelFile = try XCTUnwrap(SettingsStore.SpeechModel.qwen3Asr17B.whisperModelFile)
        try FileManager.default.linkItem(at: URL(fileURLWithPath: modelPath), to: directory.appendingPathComponent(modelFile))
        let legacyFile = directory.appendingPathComponent("ggml-tiny.bin")
        try Data("unrelated Whisper cache".utf8).write(to: legacyFile)
        let provider = WhisperProvider(modelDirectory: directory, modelOverride: .qwen3Asr17B)
        guard provider.modelsExistOnDisk() else {
            return XCTFail("This check must reuse the existing model without downloading.")
        }

        try await provider.prepare()
        let samples = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
        let result = try await provider.transcribe(samples)

        XCTAssertTrue(result.text.lowercased().contains("hello"), "Unexpected fixture transcription: \(result.text)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelPath))
        print("Qwen fixture transcription: \(result.text)")
    }

    func testStoredWhisperLanguageSelectionResolution() {
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromStoredValue: nil))
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromStoredValue: "auto"))
        XCTAssertEqual(SettingsStore.whisperLanguageCode(fromStoredValue: "hu"), "hu")
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromStoredValue: "unsupported"))
    }

    func testAutomaticWhisperLanguageRoundTripsThroughBackupValue() {
        let backupValue = SettingsStore.whisperLanguageBackupValue(for: nil)

        XCTAssertEqual(backupValue, "auto")
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromBackupValue: backupValue))
    }

    func testForcedWhisperLanguageRoundTripsThroughBackupValue() {
        let backupValue = SettingsStore.whisperLanguageBackupValue(for: "hu")

        XCTAssertEqual(backupValue, "hu")
        XCTAssertEqual(SettingsStore.whisperLanguageCode(fromBackupValue: backupValue), "hu")
    }

    func testWhisperLanguageCodesAreUnique() {
        let languageCodes = VoiceEngineLanguageCatalog.whisperLanguages.compactMap {
            VoiceEngineLanguageCatalog.whisperLanguageCode(for: $0.id)
        }
        XCTAssertEqual(languageCodes.count, Set(languageCodes).count)
    }
}
