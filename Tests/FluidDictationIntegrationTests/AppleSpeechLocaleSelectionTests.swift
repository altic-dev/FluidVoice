@testable import FluidVoice_Debug
import XCTest

final class AppleSpeechLocaleSelectionTests: XCTestCase {
    func testLocaleOptionsAreNormalizedDeduplicatedAndSortedByName() {
        let english = Locale(identifier: "en")
        let options = VoiceEngineLanguageCatalog.appleSpeechLocaleOptions(
            identifiers: ["en-US", "zh_TW", "zh-TW"],
            displayLocale: english
        )

        XCTAssertEqual(options.map(\.id), ["zh-TW", "en-US"])
        XCTAssertEqual(options.map(\.displayName), [
            english.localizedString(forIdentifier: "zh-TW"),
            english.localizedString(forIdentifier: "en-US"),
        ])
    }

    func testLocaleOptionNamesFollowDisplayLocale() {
        let english = VoiceEngineLanguageCatalog.appleSpeechLocaleOptions(
            identifiers: ["zh-TW"],
            displayLocale: Locale(identifier: "en")
        )
        let traditionalChinese = VoiceEngineLanguageCatalog.appleSpeechLocaleOptions(
            identifiers: ["zh-TW"],
            displayLocale: Locale(identifier: "zh-Hant-TW")
        )

        XCTAssertNotEqual(english.first?.displayName, "zh-TW")
        XCTAssertNotEqual(english.first?.displayName, traditionalChinese.first?.displayName)
    }
}
