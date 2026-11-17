@testable import FluidVoice_Debug
import XCTest

@MainActor
final class ModelPickerTests: XCTestCase {
    private let gib: UInt64 = 1024 * 1024 * 1024

    // MARK: - Size contract

    func testModelPopupsFitTheSharedPopupSize() {
        // The model pop-ups fill the shared pop-up size; at its smallest the detail panel keeps room beside the list.
        XCTAssertGreaterThanOrEqual(FluidPopupLayout.minimumSize.width - ModelPickerLayout.listWidth, 520)
    }

    func testPopupPresenceKeepsTheWindowRuleUntilEveryPopupCloses() {
        let presence = FluidPopupPresence()
        XCTAssertFalse(presence.isAnyOpen)
        presence.opened()
        presence.opened()
        presence.closed()
        XCTAssertTrue(presence.isAnyOpen, "One pop-up is still open")
        presence.closed()
        XCTAssertFalse(presence.isAnyOpen)
        presence.closed()
        XCTAssertEqual(presence.openCount, 0, "An extra close never goes below zero")
        presence.opened()
        XCTAssertTrue(presence.isAnyOpen, "A pop-up opened after an extra close still counts")
    }

    // MARK: - Sorting

    private func row(_ id: String, _ name: String, _ first: Int?, _ second: Int?) -> ModelPickerRow {
        ModelPickerRow(id: id, name: name, logo: .cleanup, firstValue: first, secondValue: second, isInUse: false, tag: nil)
    }

    func testSortingPutsTheBestFirstAndKeepsTiesAndUnratedRowsInPlace() {
        let rows = [self.row("a", "Beta", 85, 98), self.row("b", "alpha", nil, 90), self.row("c", "Gamma", 99, 98), self.row("d", "Delta", 85, nil)]
        XCTAssertEqual(ModelPickerSort.suggested.apply(rows).map(\.id), ["a", "b", "c", "d"], "The suggested order is left alone")
        XCTAssertEqual(ModelPickerSort.first.apply(rows).map(\.id), ["c", "a", "d", "b"], "Fastest first, ties keep their order, unrated last")
        XCTAssertEqual(ModelPickerSort.second.apply(rows).map(\.id), ["a", "c", "b", "d"], "Most accurate first, ties keep their order, unrated last")
        XCTAssertEqual(ModelPickerSort.name.apply(rows).map(\.id), ["b", "a", "d", "c"], "Names A to Z, ignoring case")
    }

    func testSortMenuOffersRecommendedThenTheColumnsThenName() {
        let speech = ModelPickerColumns(first: "Speed", second: "Accuracy")
        let cleanup = ModelPickerColumns(first: "Speed", second: "Quality", scale: 5)
        XCTAssertEqual(ModelPickerSort.menuOrder.map { $0.title(speech) }, ["Recommended", "Accuracy", "Speed", "Name"])
        XCTAssertEqual(ModelPickerSort.menuOrder.map { $0.title(cleanup) }, ["Recommended", "Quality", "Speed", "Name"])
    }

    // MARK: - Starting language

    func testPickerStartsFromTheModelsOwnLanguageSettingThenTheChosenLanguage() {
        let settings = SettingsStore.shared
        let saved = (settings.selectedSpeechModel, settings.selectedWhisperLanguageCode, settings.onboardingSelectedLanguageID)
        defer {
            settings.selectedSpeechModel = saved.0
            settings.selectedWhisperLanguageCode = saved.1
            settings.onboardingSelectedLanguageID = saved.2
        }
        settings.onboardingSelectedLanguageID = "fr"
        settings.selectedWhisperLanguageCode = "ta"
        settings.selectedSpeechModel = .whisperSmall
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredLanguageID(settings: settings), "ta")
        settings.selectedSpeechModel = .qwen3Asr17B
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredLanguageID(settings: settings), "fr", "Qwen detects the language, so the stale Whisper setting is ignored")
        settings.selectedSpeechModel = .fluidParakeetPro
        XCTAssertEqual(VoiceEngineLanguageCatalog.preferredLanguageID(settings: settings), "fr")
    }

    // MARK: - Speech list

    func testSpeechListPutsTheRecommendationFirstAndListsEachModelOnce() {
        let all = SettingsStore.SpeechModel.allCases
        let japanese = SpeechModelPickerContent(languageID: "ja", memoryBytes: 16 * self.gib, availableModels: all)
        XCTAssertEqual(japanese.recommended, .qwen3Asr17B)
        XCTAssertEqual(japanese.routes.first?.model, .qwen3Asr17B)
        XCTAssertEqual(Set(japanese.unsupportedFluidModels), [.fluidParakeetPro, .fluidParakeetMini, .fluidParakeetPico])
        XCTAssertEqual(japanese.routes.count, Set(japanese.routes.map(\.model)).count)

        let english = SpeechModelPickerContent(languageID: "en", memoryBytes: 16 * self.gib, availableModels: all)
        XCTAssertEqual(english.routes.first?.model, .fluidParakeetPro)
        XCTAssertTrue(english.unsupportedFluidModels.isEmpty)
        XCTAssertEqual(SpeechModelPickerContent(languageID: "en", memoryBytes: 8 * self.gib, availableModels: all).recommended, .fluidParakeetMini)
    }

    func testOnlyFluidSpeechProIsMarkedNew() {
        XCTAssertEqual(SettingsStore.SpeechModel.allCases.filter(\.isNew), [.fluidParakeetPro])
        XCTAssertEqual(SettingsStore.SpeechModel.fluidParakeetPro.badgeText, "New")
        XCTAssertNil(SettingsStore.SpeechModel.fluidParakeetMini.badgeText)
        XCTAssertEqual(SettingsStore.SpeechModel.parakeetTDTv2.badgeText, "FluidVoice Pick")
        XCTAssertEqual(SettingsStore.SpeechModel.nemotronStreaming.badgeText, "Beta")
    }

    func testSpeechListHasNoRecommendationUntilMemoryIsKnownOrBelowEightGigabytes() {
        let all = SettingsStore.SpeechModel.allCases
        XCTAssertNil(SpeechModelPickerContent(languageID: "en", memoryBytes: nil, availableModels: all).recommended)
        XCTAssertNil(SpeechModelPickerContent(languageID: "ja", memoryBytes: 4 * self.gib, availableModels: all).recommended)
        XCTAssertEqual(SpeechModelPickerContent(languageID: "unknown", memoryBytes: 16 * self.gib, availableModels: all).language.id, "en")
    }

    func testRouteIsInUseOnlyForTheLanguageAModelIsSetTo() {
        let settings = SettingsStore.shared
        let saved = (settings.selectedSpeechModel, settings.selectedWhisperLanguageCode)
        defer {
            settings.selectedSpeechModel = saved.0
            settings.selectedWhisperLanguageCode = saved.1
        }
        settings.selectedWhisperLanguageCode = "de"
        settings.selectedSpeechModel = .whisperLargeTurbo
        let models: [SettingsStore.SpeechModel] = [.whisperLargeTurbo]
        let german = VoiceEngineLanguageCatalog.routes(forLanguageID: "de", availableModels: models)[0]
        let english = VoiceEngineLanguageCatalog.routes(forLanguageID: "en", availableModels: models)[0]
        XCTAssertTrue(SpeechModelPickerContent.isInUse(german, settings: settings))
        XCTAssertFalse(SpeechModelPickerContent.isInUse(english, settings: settings))
    }

    func testProFallsBackToMiniWhenProIsNotAvailable() {
        XCTAssertEqual(
            DashboardModelRecommendationPolicy.speechModel(memoryBytes: 32 * self.gib, language: "en", available: [.fluidParakeetMini]),
            .fluidParakeetMini
        )
        XCTAssertEqual(DashboardModelRecommendationPolicy.minimumMemoryGB(for: .fluidParakeetPro), 16)
        XCTAssertNil(DashboardModelRecommendationPolicy.minimumMemoryGB(for: .fluidParakeetPico))
    }

    // MARK: - Cleanup list

    private func cleanupModel(_ id: String, _ languages: [String]) -> PrivateAIRegisteredModel {
        PrivateAIRegisteredModel(
            displayName: id,
            detail: "",
            isEnabled: true,
            parameterCount: "",
            recommendedMemoryGB: 8,
            artifact: PrivateAIModelArtifact(identifier: id, filename: id, downloadURL: nil, sha256: nil, byteCount: nil, version: nil),
            supportedLanguageIDs: languages
        )
    }

    private var cleanupModels: [PrivateAIRegisteredModel] {
        let five = ["en", "de", "es", "fr", "pt"]
        return [self.cleanupModel("pico", []), self.cleanupModel("splash", five), self.cleanupModel("ripple", five), self.cleanupModel("english", ["en"])]
    }

    func testNewCleanupModelsGoByTheirOwnNameAndCarryTheNewLabel() throws {
        guard PrivateAIProviderFeature.shared.isAvailable else { throw XCTSkip("Needs Fluid Intelligence") }
        for (id, name) in [("fluid-1.1-ripple", "Ripple"), ("fluid-1.1-splash", "Splash")] {
            let model = try XCTUnwrap(PrivateAIModelRegistry.model(id: id), id)
            XCTAssertEqual(model.displayName, name)
            XCTAssertEqual(model.presentation?.badge, "New", id)
        }
        for (id, name) in [("fluid-1-pico-96k-dflash", "Fluid 1 Pico"), ("fluid-1-mini-96k-dflash", "Fluid 1 Mini")] {
            let model = try XCTUnwrap(PrivateAIModelRegistry.model(id: id), id)
            XCTAssertEqual(model.displayName, name)
            XCTAssertNil(model.presentation?.badge, id)
        }
    }

    func testCleanupListShowsSupportingAndUnlistedModelsAndHidesTheRest() {
        let german = CleanupModelPickerContent(languageID: "de", languageName: "German", models: self.cleanupModels, recommendedModelID: "splash")
        XCTAssertFalse(german.isUntrained)
        XCTAssertEqual(german.listed.map(\.id), ["splash", "pico", "ripple"])
        XCTAssertEqual(german.hidden.map(\.id), ["english"])
        XCTAssertEqual(german.suggestedModelID, "splash")
        XCTAssertEqual(german.tag, .recommended)
        XCTAssertEqual(german.support(self.cleanupModels[0]), .notListed)
    }

    func testCleanupRecommendationIsDroppedWhenItDoesNotSupportTheLanguage() {
        let german = CleanupModelPickerContent(languageID: "de", languageName: "German", models: self.cleanupModels, recommendedModelID: "pico")
        XCTAssertNil(german.suggestedModelID)
        XCTAssertEqual(german.listed.map(\.id), ["pico", "splash", "ripple"])
    }

    func testUntrainedLanguageListsEveryModelAndSuggestsOneToTryFirst() {
        let japanese = CleanupModelPickerContent(languageID: "ja", languageName: "Japanese", models: self.cleanupModels, recommendedModelID: "splash")
        XCTAssertTrue(japanese.isUntrained)
        XCTAssertEqual(japanese.listed.count, self.cleanupModels.count)
        XCTAssertTrue(japanese.hidden.isEmpty)
        XCTAssertEqual(japanese.suggestedModelID, "splash")
        XCTAssertEqual(japanese.tag, .tryFirst)
        XCTAssertNil(CleanupModelPickerContent(languageID: "ja", languageName: "Japanese", models: self.cleanupModels, recommendedModelID: nil).suggestedModelID)
    }

    func testBestValuesHighlightEveryTie() {
        let rows = [
            ModelPickerRow(id: "a", name: "A", logo: .cleanup, firstValue: 85, secondValue: 98, isInUse: false, tag: nil),
            ModelPickerRow(id: "b", name: "B", logo: .cleanup, firstValue: 85, secondValue: nil, isInUse: false, tag: nil),
        ]
        let best = ModelPickerColumns.bestValues(rows)
        XCTAssertEqual(best.first, 85)
        XCTAssertEqual(best.second, 98)
    }
}
