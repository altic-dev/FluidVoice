// ABOUTME: Tests for the ivrit.ai Hebrew Whisper model wiring (metadata + catalog routing).
// ABOUTME: Verifies Hebrew routes to the ivrit model first and forces Hebrew decoding.
import Foundation
import XCTest

@testable import FluidVoice_Debug

final class IvritHebrewModelTests: XCTestCase {
    private typealias Model = SettingsStore.SpeechModel

    // MARK: - Model metadata

    func testIvritModelLocalFilenameIsDistinctFromGenericWhisper() {
        XCTAssertEqual(Model.whisperIvritV3Turbo.whisperModelFile, "ggml-ivrit-v3-turbo.bin")
    }

    func testIvritModelIsTreatedAsWhisper() {
        XCTAssertTrue(Model.whisperIvritV3Turbo.isWhisperModel)
    }

    func testIvritModelForcesHebrewDecodeLanguage() {
        // "iw" is SwiftWhisper's WhisperLanguage.hebrew raw value (legacy ISO 639 code).
        XCTAssertEqual(Model.whisperIvritV3Turbo.forcedWhisperLanguageCode, "iw")
    }

    func testIvritModelDownloadsFromIvritAIRepoNotGgerganov() {
        let url = Model.whisperIvritV3Turbo.whisperDownloadURL
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "huggingface.co")
        XCTAssertTrue(url?.path.contains("ivrit-ai") ?? false, "Expected ivrit.ai HF repo, got \(String(describing: url))")
    }

    func testGenericWhisperStillDownloadsFromGgerganov() {
        let url = Model.whisperSmall.whisperDownloadURL
        XCTAssertTrue(url?.path.contains("ggerganov/whisper.cpp") ?? false)
    }

    // MARK: - Catalog routing

    func testHebrewRoutesToIvritModelWhenAvailable() {
        let routes = VoiceEngineLanguageCatalog.routes(
            forLanguageID: "he",
            availableModels: [.whisperIvritV3Turbo]
        )
        XCTAssertTrue(
            routes.contains { $0.model == .whisperIvritV3Turbo },
            "Hebrew should produce an ivrit.ai route when the model is available"
        )
    }

    func testIvritModelIsTheRecommendedHebrewEngine() {
        // When several Hebrew-capable engines are available, the ivrit model should rank first.
        let routes = VoiceEngineLanguageCatalog.routes(
            forLanguageID: "he",
            availableModels: [.whisperSmall, .nemotronOffline, .whisperIvritV3Turbo, .appleSpeech]
        )
        XCTAssertEqual(routes.first?.model, .whisperIvritV3Turbo)
    }

    func testEnglishDoesNotRouteToIvritModel() {
        let routes = VoiceEngineLanguageCatalog.routes(
            forLanguageID: "en",
            availableModels: Model.allCases
        )
        XCTAssertFalse(routes.contains { $0.model == .whisperIvritV3Turbo })
    }

    func testHebrewLanguageIsListedWhenIvritModelAvailable() {
        let languages = VoiceEngineLanguageCatalog.allLanguages(availableModels: [.whisperIvritV3Turbo])
        XCTAssertTrue(languages.contains { $0.id == "he" })
    }
}
