@testable import FluidVoice_Debug
import XCTest

@MainActor
final class DashboardLayoutTests: XCTestCase {
    func testSetupCardsAlwaysFillTheirRows() {
        for width in stride(from: 320, through: 2000, by: 1) {
            let layout = DashboardLayout(width: CGFloat(width))
            for count in 1...3 {
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

    func testOnlyMissingEssentialsAreShown() {
        for model in [false, true] {
            for microphone in [false, true] {
                for typing in [false, true] {
                    let missing = DashboardSetupStatus(voiceModelReady: model, microphoneReady: microphone, typingAccessReady: typing).missing
                    XCTAssertEqual(missing.contains(.voiceModel), !model)
                    XCTAssertEqual(missing.contains(.microphone), !microphone)
                    XCTAssertEqual(missing.contains(.typingAccess), !typing)
                    XCTAssertEqual(missing.isEmpty, model && microphone && typing)
                }
            }
        }
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
