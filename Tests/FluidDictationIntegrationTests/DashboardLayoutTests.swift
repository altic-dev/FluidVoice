@testable import FluidVoice_Debug
import XCTest

@MainActor
final class DashboardLayoutTests: XCTestCase {
    func testSetupCardsAlwaysFillTheirRows() {
        for width in stride(from: 320, through: 2000, by: 1) {
            let layout = DashboardLayout(width: CGFloat(width))
            for count in 1...4 {
                XCTAssertEqual(count % layout.setupColumns(count: count), 0)
                if layout.setupColumns(count: count) > 1 {
                    XCTAssertGreaterThanOrEqual((layout.contentWidth - CGFloat(count - 1) * 10) / CGFloat(count), 280)
                }
            }
            if layout.hasActionColumn {
                XCTAssertGreaterThanOrEqual(layout.mainWidth, 640)
            }
        }
    }

    func testBreakpointsAndCappedWidth() {
        XCTAssertFalse(DashboardLayout(width: 1007).hasActionColumn)
        XCTAssertTrue(DashboardLayout(width: 1008).hasActionColumn)
        XCTAssertEqual(DashboardLayout(width: 609).setupColumns(count: 2), 1)
        XCTAssertEqual(DashboardLayout(width: 610).setupColumns(count: 2), 2)
        XCTAssertEqual(DashboardLayout(width: 900).setupColumns(count: 3), 3)
        XCTAssertFalse(DashboardLayout(width: 659).hasHorizontalActions)
        XCTAssertTrue(DashboardLayout(width: 660).hasHorizontalActions)
        XCTAssertFalse(DashboardLayout(width: 1008).hasHorizontalActions)
        XCTAssertEqual(DashboardLayout(width: 2000).contentWidth, DashboardLayout(width: 1440).contentWidth)
    }

    func testStatisticsDoNotSqueezeFourColumnsBesideActions() {
        XCTAssertEqual(DashboardLayout(width: 1008).statisticColumns(count: 4), 2)
        XCTAssertEqual(DashboardLayout(width: 1440).statisticColumns(count: 4), 4)
        XCTAssertEqual(DashboardLayout(width: 320).statisticColumns(count: 4), 1)
    }

    func testOnlyMissingSetupOptionsAreShown() {
        for model in [false, true] {
            for microphone in [false, true] {
                for typing in [false, true] {
                    for screen in [false, true] {
                        let missing = DashboardSetupStatus(
                            voiceModelReady: model,
                            microphoneReady: microphone,
                            typingAccessReady: typing,
                            screenCaptureReady: screen
                        ).missing
                        XCTAssertEqual(missing.contains(.voiceModel), !model)
                        XCTAssertEqual(missing.contains(.microphone), !microphone)
                        XCTAssertEqual(missing.contains(.typingAccess), !typing)
                        XCTAssertEqual(missing.contains(.screenCapture), !screen)
                        XCTAssertEqual(missing.isEmpty, model && microphone && typing && screen)
                    }
                }
            }
        }
    }

    func testOptionalScreenAccessDoesNotAddOtherMissingRequirements() {
        XCTAssertEqual(DashboardSetupStatus(
            voiceModelReady: true, microphoneReady: true, typingAccessReady: true, screenCaptureReady: false
        ).missing, [.screenCapture])
        XCTAssertEqual(DashboardSetupStatus(
            voiceModelReady: true, microphoneReady: false, typingAccessReady: false, screenCaptureReady: true
        ).missing, [.microphone, .typingAccess])
    }

    func testIntelligenceInvitationOnlyAppearsForUntriedUndismissedUsers() {
        for available in [false, true] {
            for dismissed in [false, true] {
                for used in [false, true] {
                    XCTAssertEqual(FluidIntelligenceInvitation.shouldShow(available: available, dismissed: dismissed, hasUsed: used), available && !dismissed && !used)
                }
            }
        }
    }

    func testIntelligenceUsePersistsWithoutChangingProviderOrOnboarding() throws {
        let suite = "FluidIntelligenceInvitationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("external-provider", forKey: "SelectedProviderID")
        defaults.set(true, forKey: "OnboardingCompleted")
        FluidIntelligenceInvitation.recordSuccess(output: " \n", defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: FluidIntelligenceInvitation.usedKey))
        FluidIntelligenceInvitation.recordSuccess(output: "Unchanged but successful text", defaults: defaults)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(reloaded.bool(forKey: FluidIntelligenceInvitation.usedKey))
        FluidIntelligenceInvitation.recordSuccess(output: "", defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: FluidIntelligenceInvitation.usedKey))
        defaults.set(true, forKey: FluidIntelligenceInvitation.dismissedKey)
        XCTAssertTrue(reloaded.bool(forKey: FluidIntelligenceInvitation.dismissedKey))
        XCTAssertEqual(defaults.string(forKey: "SelectedProviderID"), "external-provider")
        XCTAssertTrue(defaults.bool(forKey: "OnboardingCompleted"))
    }

    func testPracticeRejectsResultsAfterCloseAndReopen() {
        let sandbox = DictationPromptTestCoordinator()
        sandbox.activate(draftPromptText: "", providerID: "fluid-1", model: "example", usesBuiltInPrompt: true)
        XCTAssertTrue(sandbox.usesBuiltInPrompt)
        let oldSession = sandbox.sessionID
        XCTAssertTrue(sandbox.acceptsResult(for: oldSession))
        sandbox.deactivate()
        XCTAssertFalse(sandbox.acceptsResult(for: oldSession))
        sandbox.activate(draftPromptText: "different", providerID: "other", model: "new")
        XCTAssertFalse(sandbox.usesBuiltInPrompt)
        XCTAssertFalse(sandbox.acceptsResult(for: oldSession))
        XCTAssertTrue(sandbox.acceptsResult(for: sandbox.sessionID))
        XCTAssertEqual(sandbox.draftProviderID, "other")
        XCTAssertEqual(sandbox.draftPromptText, "different")
    }

    func testExistingSuccessfulUseCountsEvenWhenNoWordsChanged() throws {
        let entry = TranscriptionHistoryEntry(
            timestamp: Date(),
            rawText: "Already correct.",
            processedText: "Already correct.",
            appName: "Notes",
            windowTitle: "",
            wasAIProcessed: true,
            processingModel: "fluid-1-mini"
        )
        let snapshot = try StatsSnapshot.build(entries: [entry], now: Date(), calendar: .current)
        XCTAssertTrue(snapshot.hasFluidIntelligenceUse)
        XCTAssertEqual(snapshot.fluidFixedWords, 0)
        let failed = TranscriptionHistoryEntry(
            timestamp: Date(),
            rawText: "Raw",
            processedText: "Raw",
            appName: "Notes",
            windowTitle: "",
            wasAIProcessed: false,
            processingModel: "fluid-1-mini"
        )
        XCTAssertFalse(try StatsSnapshot.build(entries: [failed], now: Date(), calendar: .current).hasFluidIntelligenceUse)
    }
}

@MainActor
final class DashboardRecommendationTests: XCTestCase {
    func testSpeechRecommendationRespectsMemoryAvailabilityAndLanguage() {
        let gib: UInt64 = 1024 * 1024 * 1024
        let available: [SettingsStore.SpeechModel] = [.fluidParakeetPro, .fluidParakeetMini]
        XCTAssertFalse(DashboardModelRecommendationPolicy.shouldSuggestSpeech(
            targetID: SettingsStore.SpeechModel.fluidParakeetMini.id, selectedID: SettingsStore.SpeechModel.fluidParakeetPro.id, dismissedID: nil
        ))
        XCTAssertEqual(DashboardModelRecommendationPolicy.speechModel(memoryBytes: 16 * gib, language: "en", available: available), .fluidParakeetPro)
        XCTAssertEqual(DashboardModelRecommendationPolicy.speechModel(memoryBytes: 8 * gib, language: "de", available: available), .fluidParakeetMini)
        XCTAssertNil(DashboardModelRecommendationPolicy.speechModel(memoryBytes: 4 * gib, language: "en", available: available))
        XCTAssertNil(DashboardModelRecommendationPolicy.speechModel(memoryBytes: 32 * gib, language: "en", available: [.whisperSmall]))
        for language: String? in [nil, "auto", "ta", "zh", "unknown"] {
            XCTAssertNil(DashboardModelRecommendationPolicy.speechModel(memoryBytes: 32 * gib, language: language, available: available))
        }
    }

    func testCleanupSuggestionRequiresEnabledAndVerifiedCurrentModel() {
        let current = ["fluid-1.1-ripple", "fluid-1.1-splash"]
        for target in current {
            for selected in current + ["fluid-1-pico-96k-dflash", "unknown"] {
                for enabled in [false, true] {
                    for ready in [false, true] {
                        let expected = !enabled || !ready || !current.contains(selected)
                        XCTAssertEqual(DashboardModelRecommendationPolicy.shouldSuggestCleanup(
                            targetID: target,
                            selectedID: selected,
                            enabled: enabled,
                            ready: ready,
                            dismissedID: nil
                        ), expected)
                        XCTAssertFalse(DashboardModelRecommendationPolicy.shouldSuggestCleanup(
                            targetID: target,
                            selectedID: selected,
                            enabled: enabled,
                            ready: ready,
                            dismissedID: target
                        ))
                    }
                }
            }
        }
        XCTAssertTrue(DashboardModelRecommendationPolicy.shouldSuggestCleanup(
            targetID: "future-model", selectedID: current[0], enabled: true, ready: true, dismissedID: current[0]
        ))
    }

    func testCleanupActivationPreservesScreenContextAndOtherRoutes() {
        let settings = SettingsStore.shared
        let defaults = UserDefaults.standard
        let keys = [PrivateAIIntegrationService.selectedModelDefaultsKey, PrivateAIIntegrationService.localModelPathDefaultsKey]
        let savedDefaults = keys.map { defaults.object(forKey: $0) }
        let models = settings.selectedModelByProvider
        let verifiedModels = settings.verifiedPrivateAIModelFingerprints
        let verifiedProviders = settings.verifiedProviderFingerprints
        let primary = settings.dictationPromptSelection(for: .primary, privateAIAvailable: true)
        let secondary = settings.dictationPromptSelection(for: .secondary, privateAIAvailable: true)
        let context = settings.dictationScreenContextEnabled
        let edit = settings.selectedEditPromptID
        let bindings = settings.appPromptBindings
        let provider = settings.selectedProviderID
        defer {
            for (key, value) in zip(keys, savedDefaults) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            settings.selectedModelByProvider = models
            settings.verifiedPrivateAIModelFingerprints = verifiedModels
            settings.verifiedProviderFingerprints = verifiedProviders
            settings.setDictationPromptSelection(primary)
            settings.dictationScreenContextEnabled = context
        }
        for contextEnabled in [false, true] {
            settings.dictationScreenContextEnabled = contextEnabled
            DashboardCleanupActivation.commit(modelID: "test-recommended", settings: settings, defaults: defaults)
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary, privateAIAvailable: true), .privateAI)
            XCTAssertEqual(defaults.string(forKey: keys[0]), "test-recommended")
            XCTAssertEqual(settings.dictationScreenContextEnabled, contextEnabled)
            XCTAssertEqual(settings.dictationPromptSelection(for: .secondary, privateAIAvailable: true), secondary)
            XCTAssertEqual(settings.selectedEditPromptID, edit)
            XCTAssertEqual(settings.appPromptBindings, bindings)
            XCTAssertEqual(settings.selectedProviderID, provider)
        }
    }

    func testDismissalPersistsWithoutChangingModelsAndNewModelCanAppear() throws {
        let suite = "DashboardRecommendations.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old-speech", forKey: "SelectedSpeechModel")
        defaults.set("old-cleanup", forKey: "FluidIntelligenceSelectedModelID")
        let card = DashboardModelRecommendation(kind: .cleanup, modelID: "ripple", name: "Ripple", detail: "", downloadSize: "", installed: false)
        DashboardRecommendationDismissals(defaults: defaults).dismiss(card)
        let reloaded = try DashboardRecommendationDismissals(defaults: XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reloaded.modelID(for: .cleanup), "ripple")
        XCTAssertNil(reloaded.modelID(for: .speech))
        XCTAssertFalse(DashboardModelRecommendationPolicy.shouldShow(targetID: "ripple", selectedID: "old", dismissedID: reloaded.modelID(for: .cleanup)))
        XCTAssertTrue(DashboardModelRecommendationPolicy.shouldShow(targetID: "next", selectedID: "old", dismissedID: reloaded.modelID(for: .cleanup)))
        XCTAssertFalse(DashboardModelRecommendationPolicy.shouldShow(targetID: "next", selectedID: "next", dismissedID: nil))
        XCTAssertEqual(defaults.string(forKey: "SelectedSpeechModel"), "old-speech")
        XCTAssertEqual(defaults.string(forKey: "FluidIntelligenceSelectedModelID"), "old-cleanup")
    }

    func testActivationWaitsForPreparationAndRejectsRepeatedClicks() async {
        let operation = DashboardRecommendationOperation()
        let preparing = expectation(description: "preparing")
        let completed = expectation(description: "completed")
        var resume: CheckedContinuation<Void, Never>?
        var activations = 0
        operation.start(
            id: "one",
            prepare: {
                await withCheckedContinuation { resume = $0; preparing.fulfill() }
            },
            isCurrent: { true },
            activate: { activations += 1 },
            finished: { completed.fulfill() }
        )
        await fulfillment(of: [preparing], timeout: 2)
        XCTAssertEqual(activations, 0)
        operation.start(
            id: "two",
            prepare: { XCTFail("Duplicate click started work") },
            isCurrent: { true },
            activate: { XCTFail("Duplicate activation") },
            finished: {}
        )
        XCTAssertEqual(operation.activeID, "one")
        resume?.resume()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(activations, 1)
        XCTAssertFalse(operation.isBusy)
    }

    func testFailurePreservesSelectionAndAllowsRetry() async {
        let operation = DashboardRecommendationOperation()
        let completed = expectation(description: "failed")
        var selected = "original"
        operation.start(
            id: "next",
            prepare: { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download interrupted"]) },
            isCurrent: { true },
            activate: { selected = "next" },
            finished: { completed.fulfill() }
        )
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(selected, "original")
        XCTAssertEqual(operation.error, "Download interrupted")
        XCTAssertEqual(operation.failedID, "next")
        XCTAssertFalse(operation.isBusy)
        let retried = expectation(description: "retried")
        operation.start(
            id: "next",
            prepare: {},
            isCurrent: { true },
            activate: { selected = "next" },
            finished: { retried.fulfill() }
        )
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertEqual(selected, "next")
        XCTAssertNil(operation.error)
    }

    func testCancelledAndStaleDownloadsNeverActivate() async {
        for cancel in [false, true] {
            let operation = DashboardRecommendationOperation()
            let preparing = expectation(description: "preparing")
            let completed = expectation(description: "completed")
            var resume: CheckedContinuation<Void, Never>?
            var current = true
            operation.start(
                id: "next",
                prepare: {
                    await withCheckedContinuation { resume = $0; preparing.fulfill() }
                },
                isCurrent: { current },
                activate: { XCTFail("Old intent must not select a model") },
                finished: { completed.fulfill() }
            )
            await fulfillment(of: [preparing], timeout: 2)
            if cancel { operation.cancel() } else { current = false }
            resume?.resume()
            await fulfillment(of: [completed], timeout: 2)
            XCTAssertFalse(operation.isBusy)
            XCTAssertNil(operation.error)
        }
    }
}
