import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SettingsNavigationStateTests: XCTestCase {
    func testPresentAndDismissRestoresPreviousAppDestination() {
        var state = SettingsNavigationState()

        state.present(.general, returningTo: .history)

        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(state.selectedSection, .general)
        XCTAssertEqual(state.returnDestination, .history)
        XCTAssertEqual(state.dismiss(), .history)
        XCTAssertFalse(state.isPresented)
    }

    func testSpecificDeepLinkChangesSectionWithoutReplacingReturnDestination() {
        var state = SettingsNavigationState()
        state.present(.general, returningTo: .stats)

        state.present(.audio, returningTo: .customDictionary)

        XCTAssertEqual(state.selectedSection, .audio)
        XCTAssertEqual(state.returnDestination, .stats)
    }

    func testMissingReturnDestinationFallsBackToGettingStarted() {
        var state = SettingsNavigationState()

        state.present(.general, returningTo: nil)

        XCTAssertEqual(state.dismiss(), .welcome)
    }

    func testLeavingForAppDismissesSettings() {
        var state = SettingsNavigationState()
        state.present(.overlay, returningTo: .voiceEngine)

        state.leaveForApp()

        XCTAssertFalse(state.isPresented)
        XCTAssertNil(state.selectedSection)
    }

    func testDetectsWhenNavigationLeavesDictationSettings() {
        var state = SettingsNavigationState()
        state.present(.dictation, returningTo: .welcome)

        XCTAssertTrue(state.isLeaving(.dictation, for: .audio))
        XCTAssertTrue(state.isLeaving(.dictation, for: nil))
        XCTAssertFalse(state.isLeaving(.dictation, for: .dictation))
    }

    func testAIProviderAndCleanupRoutesMapToSeparateSections() {
        XCTAssertEqual(SidebarItem.aiEnhancements.aiEnhancementConfigurationSection, .providers)
        XCTAssertEqual(SidebarItem.cleanupStyles.aiEnhancementConfigurationSection, .advancedPrompts)
    }

    func testUnrelatedRoutesDoNotSelectAIConfigurationSections() {
        XCTAssertNil(SidebarItem.voiceEngine.aiEnhancementConfigurationSection)
        XCTAssertNil(SidebarItem.customDictionary.aiEnhancementConfigurationSection)
    }

    func testInactiveSettingsSearchResignsFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let searchField = NSSearchField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        window.contentView?.addSubview(searchField)

        XCTAssertTrue(window.makeFirstResponder(searchField))
        XCTAssertNotNil(searchField.currentEditor())

        SettingsSearchField.resignFocusIfNeeded(from: searchField, isActive: false)

        XCTAssertNil(searchField.currentEditor())
    }

    func testCommandModeOnlyOwnsRecordingItStarted() {
        XCTAssertTrue(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .started, isRunning: true))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .started, isRunning: false))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .alreadyActive, isRunning: true))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.ownsRecording(after: .failed, isRunning: true))
    }

    func testCommandModeDeactivationNeverStopsUnownedRecording() {
        XCTAssertTrue(CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(
            ownsRecording: true,
            isRunning: true
        ))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(
            ownsRecording: false,
            isRunning: true
        ))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.shouldStopOnDeactivate(
            ownsRecording: true,
            isRunning: false
        ))
        XCTAssertTrue(CommandModeRecordingOwnershipPolicy.shouldStopAfterStart(
            ownsRecording: true,
            isPresentationActive: false
        ))
        XCTAssertFalse(CommandModeRecordingOwnershipPolicy.shouldStopAfterStart(
            ownsRecording: false,
            isPresentationActive: false
        ))
    }

    func testSettingsSectionsHaveStableTitlesAndIcons() {
        XCTAssertEqual(
            SettingsSection.allCases.map(\.title),
            ["General", "Dictation", "Notifications", "Audio", "Overlay", "Data & Diagnostics"]
        )
        XCTAssertTrue(SettingsSection.allCases.allSatisfy { !$0.systemImage.isEmpty })
        XCTAssertEqual(SettingsSection.overlay.systemImage, "rectangle.on.rectangle")
    }

    func testSettingsSearchRanksExactTitleAheadOfRelatedTerms() {
        let results = SettingsSearchIndex.results(for: "Copy to Clipboard")

        XCTAssertEqual(results.first?.target, .copyToClipboard)
        XCTAssertTrue(results.contains { $0.target == .textInsertionMode })
    }

    func testSettingsSearchNormalizesCaseAndDiacritics() {
        let results = SettingsSearchIndex.results(for: "ACCÉNT COLOR")

        XCTAssertEqual(results.first?.target, .accentColor)
    }

    func testSettingsSearchMatchesPrefixesAliasesAndMultipleWords() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "start").first?.target, .launchAtStartup)
        XCTAssertTrue(SettingsSearchIndex.results(for: "mic").contains { $0.target == .inputDevicePriority })
        XCTAssertEqual(SettingsSearchIndex.results(for: "audio device").first?.section, .audio)
    }

    func testSettingsSearchToleratesRepresentativeTypos() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "microfone").contains { $0.target == .microphonePermission })
        XCTAssertEqual(SettingsSearchIndex.results(for: "clipbord").first?.target, .copyToClipboard)
        XCTAssertEqual(SettingsSearchIndex.results(for: "hot ky").first?.target, .globalHotkey)
    }

    func testSettingsSearchRejectsUnrelatedShortQuery() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "zz").isEmpty)
    }

    func testSettingsSearchKeepsSectionsInNavigationOrder() {
        XCTAssertEqual(
            SettingsSearchIndex.matchingSections(for: "mic"),
            [.dictation, .notifications, .audio]
        )
    }

    func testSettingsSearchPreservesMatchingSectionAndFallsBackToBestResult() {
        let results = SettingsSearchIndex.results(for: "mic")

        XCTAssertEqual(
            SettingsSearchIndex.preferredSection(current: .audio, results: results),
            .audio
        )
        XCTAssertEqual(
            SettingsSearchIndex.preferredSection(current: .general, results: results),
            results.first?.section
        )
        XCTAssertEqual(SettingsSearchIndex.preferredSection(current: .audio, results: []), .audio)
    }
}
