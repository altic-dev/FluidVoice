@testable import FluidVoice_Debug
import XCTest

final class WhisperLanguageSelectionTests: XCTestCase {
    func testHungarianLanguageCodeIsAvailable() {
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "hu"), "hu")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "hu")?.displayName, "Hungarian")
    }

    func testWhisperRunOptionsUseSelectedLanguage() {
        XCTAssertEqual(WhisperProvider.runOptions(languageCode: "hu").language, "hu")
    }

    func testWhisperRunOptionsAllowAutomaticDetection() {
        XCTAssertNil(WhisperProvider.runOptions(languageCode: nil).language)
    }

    func testWhisperLanguageCodesAreUnique() {
        let languageCodes = VoiceEngineLanguageCatalog.whisperLanguages.compactMap {
            VoiceEngineLanguageCatalog.whisperLanguageCode(for: $0.id)
        }
        XCTAssertEqual(languageCodes.count, Set(languageCodes).count)
    }
}
