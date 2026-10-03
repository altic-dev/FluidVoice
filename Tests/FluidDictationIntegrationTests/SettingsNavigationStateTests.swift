import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SettingsNavigationStateTests: XCTestCase {
    func testManualLaunchPreferenceDefaultsOnAndIsIndependentOfLogin() {
        self.withLaunchPreferences {
            let settings = SettingsStore.shared
            UserDefaults.standard.removeObject(forKey: "ShowMainWindowAtLaunch")
            UserDefaults.standard.set(true, forKey: "OnboardingCompleted")
            settings.showMainWindowAtLoginLaunch = false

            XCTAssertTrue(settings.shouldShowMainWindowOnLaunch(isLoginItem: false))
            XCTAssertFalse(settings.shouldShowMainWindowOnLaunch(isLoginItem: true))

            settings.showMainWindowAtLaunch = false
            settings.showMainWindowAtLoginLaunch = true

            XCTAssertFalse(settings.shouldShowMainWindowOnLaunch(isLoginItem: false))
            XCTAssertTrue(settings.shouldShowMainWindowOnLaunch(isLoginItem: true))
            XCTAssertEqual(UserDefaults.standard.object(forKey: "ShowMainWindowAtLaunch") as? Bool, false)
        }
    }

    func testIncompleteOnboardingRemainsVisibleWithBothLaunchPreferencesOff() {
        self.withLaunchPreferences {
            let settings = SettingsStore.shared
            settings.showMainWindowAtLaunch = false
            settings.showMainWindowAtLoginLaunch = false
            UserDefaults.standard.set(false, forKey: "OnboardingCompleted")

            XCTAssertTrue(settings.shouldShowMainWindowOnLaunch(isLoginItem: false))
            XCTAssertTrue(settings.shouldShowMainWindowOnLaunch(isLoginItem: true))
        }
    }

    func testManualLaunchPreferenceBackupPreservesFalseAndDecodesLegacyFiles() throws {
        try self.withLaunchPreferences {
            SettingsStore.shared.showMainWindowAtLaunch = false
            let payload = SettingsStore.shared.makeBackupPayload()
            let encoded = try JSONEncoder().encode(payload)
            XCTAssertEqual(try JSONDecoder().decode(SettingsBackupPayload.self, from: encoded).showMainWindowAtLaunch, false)

            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            legacy.removeValue(forKey: "showMainWindowAtLaunch")
            let legacyData = try JSONSerialization.data(withJSONObject: legacy)
            XCTAssertNil(try JSONDecoder().decode(SettingsBackupPayload.self, from: legacyData).showMainWindowAtLaunch)
        }
    }

    func testInvisibleLaunchSearchFindsManualLaunchPreference() {
        let result = SettingsSearchIndex.results(for: "invisible launch").first
        XCTAssertEqual(result?.target, .showWindowAtLaunch)
        XCTAssertEqual(result?.section, .general)
    }

    private func withLaunchPreferences(_ body: () throws -> Void) rethrows {
        // Initialize migrations before taking the snapshot; restore absent keys as absent.
        _ = SettingsStore.shared
        let defaults = UserDefaults.standard
        let keys = ["ShowMainWindowAtLaunch", "ShowMainWindowAtLoginLaunch", "OnboardingCompleted"]
        let originalValues = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, originalValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }

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

        SidebarSearchField.resignFocusIfNeeded(from: searchField, isActive: false)

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
            ["General", "Dictation", "Dictation Formatting", "Shortcuts", "Notifications", "Audio", "Overlay", "Data & Diagnostics", "Experimental"]
        )
        XCTAssertTrue(SettingsSection.allCases.allSatisfy { !$0.systemImage.isEmpty })
        XCTAssertEqual(SettingsSection.overlay.systemImage, "rectangle.on.rectangle")
    }

    func testShortcutSearchRoutesToDedicatedPageWithoutMovingDictationOptions() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "Primary Dictation Shortcuts").first?.section, .shortcuts)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Copy to Clipboard").first?.section, .dictation)
        XCTAssertEqual(SettingsSearchTarget.commandModeShortcut.section, .shortcuts)
        var state = SettingsNavigationState()
        state.present(.shortcuts, returningTo: .cleanupStyles)
        XCTAssertTrue(state.isLeaving(.shortcuts, for: .dictation))
        XCTAssertEqual(state.dismiss(), .cleanupStyles)
    }

    func testFormattingSearchRoutesToDedicatedSection() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "Dictation Formatting").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Text Formatting").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Spoken Formatting").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchIndex.results(for: "Remove Filler Words").first?.section, .dictationFormatting)
        XCTAssertEqual(SettingsSearchTarget.copyToClipboard.section, .dictation)
        XCTAssertEqual(SettingsSearchTarget.inputDevicePriority.section, .audio)
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

    func testSettingsSearchOmitsTargetsUnavailableInTheCurrentState() {
        let availability = SettingsSearchAvailability(
            microphoneAuthorized: true,
            accessibilityEnabled: true,
            savesTranscriptionHistory: false,
            savesAudioWithTranscriptionHistory: false,
            overlayAtBottom: false
        )

        let permissionTargets = SettingsSearchIndex.results(
            for: "permission",
            availability: availability
        ).map(\.target)

        XCTAssertFalse(permissionTargets.contains(.microphonePermission))
        XCTAssertFalse(permissionTargets.contains(.accessibilityPermission))
        XCTAssertFalse(SettingsSearchIndex.results(
            for: "audio storage",
            availability: availability
        ).contains { $0.target == .audioStorage })
        XCTAssertFalse(SettingsSearchIndex.results(
            for: "bottom offset",
            availability: availability
        ).contains { $0.target == .bottomOffset })
    }

    func testSettingsSearchOmitsControlsHiddenWithoutAccessibility() {
        let availability = SettingsSearchAvailability(
            microphoneAuthorized: true,
            accessibilityEnabled: false,
            savesTranscriptionHistory: true,
            savesAudioWithTranscriptionHistory: true,
            overlayAtBottom: true
        )
        let gatedTargets: [(SettingsSearchTarget, String)] = [
            (.primaryDictationShortcuts, "primary dictation shortcuts"),
            (.commandModeShortcut, "command mode shortcut"),
            (.editModeShortcut, "edit mode shortcut"),
            (.cancelRecordingShortcut, "cancel recording shortcut"),
            (.pasteLastTranscriptionShortcut, "paste last transcription shortcut"),
            (.activationMode, "activation mode"),
            (.copyToClipboard, "copy to clipboard"),
            (.textInsertionMode, "text insertion mode"),
            (.spokenSend, "spoken send"),
            (.transcriptionHistory, "save transcription history"),
            (.audioHistory, "save audio with history"),
            (.audioStorage, "audio storage"),
            (.usageStreak, "usage streak"),
            (.skipSilentRecordings, "skip silent recordings"),
            (.pauseMedia, "pause media during transcription"),
            (.dictionarySuggestions, "dictionary suggestions"),
            (.analyticsPrivacy, "detailed anonymous analytics"),
        ]

        for (target, query) in gatedTargets {
            XCTAssertFalse(
                SettingsSearchIndex.results(for: query, availability: availability)
                    .contains { $0.target == target },
                "\(target) is not rendered without Accessibility permission"
            )
        }
    }
}
