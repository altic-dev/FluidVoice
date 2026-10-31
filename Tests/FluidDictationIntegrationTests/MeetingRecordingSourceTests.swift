import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class MeetingRecordingSourceTests: XCTestCase {
    private let zoom = MeetingApplicationIdentity(bundleIdentifier: "zoom", processID: 42, displayName: "Zoom")
    private let browser = MeetingApplicationIdentity(bundleIdentifier: "browser", processID: 43, displayName: "Browser")
    private let mic = MeetingMicrophoneIdentity(captureDeviceID: "mic", coreAudioUID: "mic", displayName: "Microphone")
    private var originalFeature: Any?
    private var originalRecentApplication: Any?

    override func setUp() {
        super.setUp()
        self.originalFeature = UserDefaults.standard.object(forKey: "FluidMeetEnabled")
        self.originalRecentApplication = UserDefaults.standard.object(forKey: "MeetingRecentApplication")
        SettingsStore.shared.meetingRecentApplication = nil
        SettingsStore.shared.fluidMeetEnabled = true
    }

    override func tearDown() {
        UserDefaults.standard.set(self.originalFeature, forKey: "FluidMeetEnabled")
        UserDefaults.standard.set(self.originalRecentApplication, forKey: "MeetingRecentApplication")
        super.tearDown()
    }

    private func snapshot() -> MeetingRecordingSourceSnapshot {
        MeetingRecordingSourceSnapshot(
            defaults: .unconfigured,
            applications: [self.zoom, self.browser],
            microphones: MeetingMicrophoneCatalogSnapshot(identities: [self.mic], defaultCoreAudioUID: "mic"),
            selectedApplication: self.zoom,
            selectedMicrophoneID: "mic"
        )
    }

    func testMicrophoneLabelWhenNoDevicesAreAvailable() {
        var snapshot = self.snapshot()
        snapshot.microphones = MeetingMicrophoneCatalogSnapshot(identities: [], defaultCoreAudioUID: nil)
        snapshot.selectedMicrophoneID = nil
        XCTAssertEqual(snapshot.microphoneSelectionLabel, "No microphone available")
    }

    func testDraftRestoresManualSourceWithoutPersistingAutomaticSuggestions() {
        var defaults = MeetingRecordingDefaults.unconfigured
        defaults.isConfigured = true
        defaults.applicationBundleIdentifier = "browser"
        let saved = MeetingTranscriptionSetupDraft(defaults: defaults, autoDetectEnabled: true, browserDetectionEnabled: true)
        XCTAssertFalse(saved.usesAutomaticApplication)
        XCTAssertEqual(saved.preferredApplicationBundleIdentifier, "browser")
        XCTAssertNil(saved.selectedApplicationID, "A saved bundle must resolve against current processes")
        var editing = saved
        editing.usesAutomaticApplication = true
        editing.preferredApplicationBundleIdentifier = nil
        XCTAssertFalse(saved.usesAutomaticApplication, "Cancelling can restore the untouched draft")
        XCTAssertEqual(defaults.applicationBundleIdentifier, "browser")
        defaults.isConfigured = false
        XCTAssertTrue(MeetingTranscriptionSetupDraft(defaults: defaults, autoDetectEnabled: true, browserDetectionEnabled: true).usesAutomaticApplication)
    }

    func testAutomaticPrefersDetectedCallThenExactForegroundApp() {
        let defaults = MeetingRecordingDefaults.unconfigured
        let target = MeetingAutoDetector.ResolvedTarget(bundleIdentifier: "zoom", pid: 42, windowID: 7)
        let detected = MeetingRecordingSourceSnapshot.suggestedApplication(defaults: defaults, target: target, foreground: self.browser, applications: [self.zoom, self.browser])
        XCTAssertEqual(detected?.processID, 42)
        XCTAssertEqual(detected?.windowID, 7)
        let fallback = MeetingRecordingSourceSnapshot.suggestedApplication(defaults: defaults, target: nil, foreground: self.browser, applications: [self.zoom, self.browser])
        XCTAssertEqual(fallback, self.browser)
        XCTAssertNil(MeetingRecordingSourceSnapshot.suggestedApplication(defaults: defaults, target: nil, foreground: nil, applications: [self.zoom]))
        var restarted = self.browser
        restarted.processID = 99
        XCTAssertNil(MeetingRecordingSourceSnapshot.suggestedApplication(defaults: defaults, target: nil, foreground: self.browser, applications: [restarted]))
    }

    func testInPersonSettingsKeepTheRememberedAppWithoutRunningApplications() {
        var defaults = MeetingRecordingDefaults.unconfigured
        defaults.isConfigured = true
        defaults.applicationBundleIdentifier = self.browser.bundleIdentifier
        defaults.applicationDisplayName = self.browser.displayName
        defaults.microphoneCaptureDeviceID = "chosen-mic"
        defaults.languageCode = "fr"
        var draft = MeetingTranscriptionSetupDraft(defaults: defaults, autoDetectEnabled: true, browserDetectionEnabled: true)
        draft.mode = .inRoom
        let inPerson = draft.applyingSource(to: defaults, application: nil)
        XCTAssertEqual(inPerson.mode, .inRoom)
        XCTAssertEqual(inPerson.applicationBundleIdentifier, self.browser.bundleIdentifier)
        XCTAssertEqual(inPerson.applicationDisplayName, self.browser.displayName)
        XCTAssertEqual(inPerson.microphoneCaptureDeviceID, "chosen-mic")
        XCTAssertEqual(inPerson.languageCode, "fr")

        var reopened = MeetingTranscriptionSetupDraft(defaults: inPerson, autoDetectEnabled: true, browserDetectionEnabled: true)
        let saved = reopened.applyingSource(to: inPerson, application: nil)
        XCTAssertEqual(saved.applicationBundleIdentifier, self.browser.bundleIdentifier)
        XCTAssertEqual(saved.applicationDisplayName, self.browser.displayName)
        reopened.mode = .onlineCall
        XCTAssertEqual(MeetingRecordingSourceSnapshot.suggestedApplication(defaults: reopened.applyingSource(to: saved, application: nil), target: nil, foreground: nil, applications: [self.browser]), self.browser)

        let changed = reopened.applyingSource(to: saved, application: self.zoom)
        XCTAssertEqual(changed.applicationBundleIdentifier, self.zoom.bundleIdentifier)
        XCTAssertEqual(changed.applicationDisplayName, self.zoom.displayName)
        reopened.usesAutomaticApplication = true
        let automatic = reopened.applyingSource(to: changed, application: self.zoom)
        XCTAssertNil(automatic.applicationBundleIdentifier, "An explicit Automatic choice must still clear the saved app")
        XCTAssertNil(automatic.applicationDisplayName)
    }

    func testSavedChoiceWinsAndMissingSavedAppCannotBecomeAnotherSource() {
        var defaults = MeetingRecordingDefaults.unconfigured
        defaults.isConfigured = true
        defaults.applicationBundleIdentifier = "browser"
        let target = MeetingAutoDetector.ResolvedTarget(bundleIdentifier: "zoom", pid: 42, windowID: nil)
        XCTAssertEqual(MeetingRecordingSourceSnapshot.suggestedApplication(defaults: defaults, target: target, foreground: self.zoom, applications: [self.zoom, self.browser]), self.browser)
        XCTAssertNil(MeetingRecordingSourceSnapshot.suggestedApplication(defaults: defaults, target: target, foreground: self.zoom, applications: [self.zoom]))
        var duplicate = self.browser
        duplicate.processID = 99
        XCTAssertNil(MeetingRecordingSourceSnapshot.suggestedApplication(defaults: defaults, target: nil, foreground: self.zoom, applications: [self.browser, duplicate]))
    }

    func testConfirmationCannotChangeAppProcessOrMicrophone() throws {
        var snapshot = self.snapshot()
        snapshot.selectedApplication?.windowID = 7
        let configuration = try snapshot.configuration(applications: [self.zoom, self.browser], microphones: [self.mic])
        XCTAssertEqual(configuration.application?.processID, 42)
        XCTAssertEqual(configuration.application?.windowID, 7)
        XCTAssertEqual(configuration.mode, .onlineCall)
        XCTAssertThrowsError(try snapshot.configuration(applications: [self.browser], microphones: [self.mic]))
        var restarted = self.zoom
        restarted.processID = 100
        XCTAssertThrowsError(try snapshot.configuration(applications: [restarted], microphones: [self.mic]))
        XCTAssertThrowsError(try snapshot.configuration(applications: [self.zoom], microphones: []))
        snapshot.selectedApplication = nil
        XCTAssertThrowsError(try snapshot.configuration(applications: [self.zoom], microphones: [self.mic]))
        snapshot.defaults.mode = .inRoom
        XCTAssertNil(try snapshot.configuration(applications: [], microphones: [self.mic]).application)
    }

    func testFirstPressOnlyShowsSourcesAndSecondPressRecordsOnce() async {
        let defaultsBefore = SettingsStore.shared.meetingRecordingDefaults
        var calls = 0
        var receivedForeground: MeetingApplicationIdentity?
        let controller = MeetingRecordingSourcePromptController(
            showsPanel: false,
            load: { foreground in
                receivedForeground = foreground
                return self.snapshot()
            },
            start: { snapshot in
                calls += 1
                XCTAssertEqual(snapshot.selectedApplication, self.zoom)
            }
        )
        controller.handleShortcut(foreground: self.browser)
        await self.waitUntil { !controller.isLoading }
        XCTAssertEqual(receivedForeground, self.browser)
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(calls, 0)
        controller.handleShortcut()
        controller.handleShortcut()
        await self.waitUntil { !controller.isPresented }
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(controller.isStarting)
        XCTAssertEqual(SettingsStore.shared.meetingRecordingDefaults, defaultsBefore, "A temporary suggestion cannot overwrite saved sources")
    }

    func testCancelDuringDiscoveryIgnoresLateResultAndRapidPresses() async {
        var resume: CheckedContinuation<MeetingRecordingSourceSnapshot, Never>?
        var starts = 0
        let controller = MeetingRecordingSourcePromptController(
            showsPanel: false,
            load: { _ in
                await withCheckedContinuation { resume = $0 }
            },
            start: { _ in starts += 1 }
        )
        controller.handleShortcut(foreground: self.browser)
        await self.waitUntil { resume != nil }
        controller.handleShortcut()
        XCTAssertEqual(starts, 0)
        controller.cancel()
        resume?.resume(returning: self.snapshot())
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.isLoading)
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(starts, 0)
    }

    func testFailureAllowsRetryAndFeatureDisableClearsPendingStart() async {
        var starts = 0
        let controller = MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in self.snapshot() }, start: { _ in
            starts += 1
            throw MeetingCaptureError.applicationUnavailable("Zoom")
        })
        controller.handleShortcut()
        await self.waitUntil { !controller.isLoading }
        controller.confirm()
        await self.waitUntil { !controller.isStarting }
        XCTAssertTrue(controller.isPresented)
        XCTAssertNotNil(controller.errorMessage)
        controller.confirm()
        await self.waitUntil { !controller.isStarting }
        XCTAssertEqual(starts, 2)
        SettingsStore.shared.fluidMeetEnabled = false
        controller.confirm()
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.isStarting)
        XCTAssertEqual(starts, 2)
    }

    func testRefreshKeepsAnExplicitInPersonChoice() async {
        let controller = MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in self.snapshot() }, start: { _ in XCTFail("Refreshing must not record") })
        controller.handleShortcut()
        await self.waitUntil { !controller.isLoading }
        controller.selectApplication(nil)
        controller.refresh()
        await self.waitUntil { !controller.isLoading }
        XCTAssertEqual(controller.snapshot?.defaults.mode, .inRoom)
        XCTAssertNil(controller.snapshot?.selectedApplication)
        controller.cancel()
    }

    func testCancelledStartCannotDismissANewerSourcePrompt() async {
        var resume: CheckedContinuation<Void, Never>?
        var starts = 0
        var firstStartWasCancelled = false
        let controller = MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in self.snapshot() }, start: { _ in
            starts += 1
            if starts == 1 {
                await withCheckedContinuation { resume = $0 }
                firstStartWasCancelled = Task.isCancelled
            }
        })
        controller.handleShortcut()
        await self.waitUntil { !controller.isLoading }
        controller.confirm()
        await self.waitUntil { resume != nil }
        controller.cancel()
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(controller.isStarting)
        controller.handleShortcut()
        await self.waitUntil { !controller.isLoading }
        resume?.resume()
        await self.waitUntil { firstStartWasCancelled }
        XCTAssertTrue(controller.isPresented, "A cancelled start must not dismiss a later source picker")
        XCTAssertTrue(controller.canConfirm)
        XCTAssertEqual(starts, 1)
        controller.confirm()
        await self.waitUntil { !controller.isPresented }
        XCTAssertEqual(starts, 2)
    }

    func testRefreshKeepsExplicitAppAndMicrophoneChoices() async {
        var initial = self.snapshot()
        let secondMic = MeetingMicrophoneIdentity(captureDeviceID: "second", coreAudioUID: "second", displayName: "Second microphone")
        initial.microphones = MeetingMicrophoneCatalogSnapshot(identities: [self.mic, secondMic], defaultCoreAudioUID: "mic")
        let controller = MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in initial }, start: { _ in XCTFail("Refreshing must not record") })
        controller.handleShortcut()
        await self.waitUntil { !controller.isLoading }
        controller.selectApplication(self.browser)
        controller.selectMicrophone(secondMic.captureDeviceID)
        controller.refresh()
        await self.waitUntil { !controller.isLoading }
        XCTAssertEqual(controller.snapshot?.selectedApplication, self.browser)
        XCTAssertEqual(controller.snapshot?.selectedMicrophoneID, secondMic.captureDeviceID)
        XCTAssertEqual(controller.snapshot?.defaults.mode, .onlineCall)
        XCTAssertTrue(controller.canConfirm)
        controller.cancel()
    }

    func testRefreshRequiresAReplacementForADisconnectedMicrophone() async {
        let chosen = MeetingMicrophoneIdentity(captureDeviceID: "chosen", coreAudioUID: "chosen", displayName: "Chosen microphone")
        var loaded = self.snapshot()
        loaded.microphones = MeetingMicrophoneCatalogSnapshot(identities: [self.mic, chosen], defaultCoreAudioUID: "mic")
        var recordedMicrophone: String?
        let controller = MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in loaded }, start: { snapshot in
            recordedMicrophone = try snapshot.configuration(applications: loaded.applications, microphones: loaded.microphones.identities).microphone.captureDeviceID
        })
        controller.handleShortcut()
        await self.waitUntil { !controller.isLoading }
        controller.selectMicrophone(chosen.captureDeviceID)

        loaded.microphones = MeetingMicrophoneCatalogSnapshot(identities: [self.mic], defaultCoreAudioUID: "mic")
        controller.refresh()
        await self.waitUntil { !controller.isLoading }
        XCTAssertNil(controller.snapshot?.selectedMicrophoneID)
        XCTAssertEqual(controller.snapshot?.microphoneSelectionLabel, "Choose a microphone…")
        XCTAssertFalse(controller.canConfirm)
        controller.confirm()
        XCTAssertNil(recordedMicrophone)

        controller.refresh()
        await self.waitUntil { !controller.isLoading }
        XCTAssertNil(controller.snapshot?.selectedMicrophoneID, "Refreshing without a selection must not choose the default")
        XCTAssertFalse(controller.canConfirm)
        controller.selectMicrophone(self.mic.captureDeviceID)
        XCTAssertEqual(controller.snapshot?.microphoneSelectionLabel, self.mic.displayName)
        XCTAssertTrue(controller.canConfirm)
        controller.confirm()
        await self.waitUntil { !controller.isPresented }
        XCTAssertEqual(recordedMicrophone, self.mic.captureDeviceID)
    }

    func testFailedRefreshDoesNotForgetThePreviousMicrophone() async {
        let chosen = MeetingMicrophoneIdentity(captureDeviceID: "chosen", coreAudioUID: "chosen", displayName: "Chosen microphone")
        var loaded = self.snapshot()
        loaded.microphones = MeetingMicrophoneCatalogSnapshot(identities: [self.mic, chosen], defaultCoreAudioUID: "mic")
        var shouldFail = false
        var starts = 0
        let controller = MeetingRecordingSourcePromptController(
            showsPanel: false,
            load: { _ in
                if shouldFail { throw MeetingCaptureError.microphoneUnavailable }
                return loaded
            },
            start: { _ in starts += 1 }
        )
        controller.handleShortcut()
        await self.waitUntil { !controller.isLoading }
        controller.selectMicrophone(chosen.captureDeviceID)

        shouldFail = true
        controller.refresh()
        await self.waitUntil { !controller.isLoading }
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.canConfirm)
        controller.confirm()
        XCTAssertEqual(starts, 0)

        shouldFail = false
        loaded.microphones = MeetingMicrophoneCatalogSnapshot(identities: [self.mic], defaultCoreAudioUID: "mic")
        controller.refresh()
        await self.waitUntil { !controller.isLoading }
        XCTAssertNil(controller.snapshot?.selectedMicrophoneID)
        XCTAssertFalse(controller.canConfirm)
        controller.cancel()
    }

    func testFailedInitialDiscoveryKeepsThePageMicrophoneChoiceOnRetry() async {
        var shouldFail = true
        let controller = MeetingRecordingSourcePromptController(
            showsPanel: false,
            load: { _ in
                if shouldFail { throw MeetingCaptureError.microphoneUnavailable }
                return self.snapshot()
            },
            start: { _ in XCTFail("An unavailable microphone must not start recording") }
        )
        controller.handleShortcut(microphoneID: "disconnected")
        await self.waitUntil { !controller.isLoading }
        XCTAssertNotNil(controller.errorMessage)
        shouldFail = false
        controller.refresh()
        await self.waitUntil { !controller.isLoading }
        XCTAssertNil(controller.snapshot?.selectedMicrophoneID)
        XCTAssertFalse(controller.canConfirm)
        controller.cancel()
    }

    func testPageMicrophoneChoiceSurvivesPickerDiscoveryAndConfirmation() async {
        let defaultsBefore = SettingsStore.shared.meetingRecordingDefaults
        let chosen = MeetingMicrophoneIdentity(captureDeviceID: "chosen", coreAudioUID: "chosen", displayName: "Chosen microphone")
        var loaded = self.snapshot()
        loaded.microphones = MeetingMicrophoneCatalogSnapshot(identities: [self.mic, chosen], defaultCoreAudioUID: "mic")
        var recordedMicrophone: String?
        let controller = MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in loaded }, start: { snapshot in
            let configuration = try snapshot.configuration(applications: loaded.applications, microphones: loaded.microphones.identities)
            recordedMicrophone = configuration.microphone.captureDeviceID
        })
        controller.handleShortcut(microphoneID: chosen.captureDeviceID)
        await self.waitUntil { !controller.isLoading }
        XCTAssertEqual(controller.snapshot?.selectedMicrophoneID, chosen.captureDeviceID)
        XCTAssertNil(recordedMicrophone, "Opening the picker must not start capture")
        controller.refresh()
        await self.waitUntil { !controller.isLoading }
        XCTAssertEqual(controller.snapshot?.selectedMicrophoneID, chosen.captureDeviceID)
        controller.confirm()
        await self.waitUntil { !controller.isPresented }
        XCTAssertEqual(recordedMicrophone, chosen.captureDeviceID)
        XCTAssertEqual(SettingsStore.shared.meetingRecordingDefaults, defaultsBefore)
    }

    func testMissingPageMicrophoneRequiresAChoiceInsteadOfUsingDefaultInput() async {
        var starts = 0
        let controller = MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in self.snapshot() }, start: { _ in starts += 1 })
        controller.handleShortcut(microphoneID: "disconnected")
        await self.waitUntil { !controller.isLoading }
        XCTAssertNil(controller.snapshot?.selectedMicrophoneID)
        XCTAssertFalse(controller.canConfirm)
        controller.confirm()
        XCTAssertEqual(starts, 0)
        controller.selectMicrophone(self.mic.captureDeviceID)
        XCTAssertTrue(controller.canConfirm)
        controller.confirm()
        await self.waitUntil { !controller.isPresented }
        XCTAssertEqual(starts, 1)
    }

    func testRecentTagMovesWithExplicitChoicesAndSurvivesReopening() async {
        let defaultsBefore = SettingsStore.shared.meetingRecordingDefaults
        var starts = 0
        let controller = MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in self.snapshot() }, start: { _ in starts += 1 })
        controller.handleShortcut()
        await self.waitUntil { !controller.isLoading }
        XCTAssertNil(controller.snapshot?.availableRecentApplication, "An automatic suggestion is not a recent explicit choice")
        controller.selectApplication(self.browser)
        XCTAssertEqual(controller.snapshot?.applicationLabel(self.browser), "Browser (Recent)")
        XCTAssertEqual(controller.snapshot?.applicationLabel(self.zoom), "Zoom")
        XCTAssertEqual(SettingsStore.shared.meetingRecentApplication, self.browser)
        controller.selectApplication(self.zoom)
        XCTAssertEqual(controller.snapshot?.applicationLabel(self.zoom), "Zoom (Recent)")
        XCTAssertEqual(controller.snapshot?.applicationLabel(self.browser), "Browser")
        controller.selectApplication(nil)
        XCTAssertEqual(SettingsStore.shared.meetingRecentApplication, self.zoom, "In person does not replace the most recent app")
        controller.selectApplication(self.browser)
        controller.cancel()

        let reopened = MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in self.snapshot() }, start: { _ in starts += 1 })
        reopened.handleShortcut()
        await self.waitUntil { !reopened.isLoading }
        XCTAssertEqual(reopened.snapshot?.availableRecentApplication, self.browser)
        XCTAssertEqual(reopened.snapshot?.selectedApplication, self.zoom, "Recency must not replace the detected or foreground suggestion")
        XCTAssertEqual(reopened.snapshot?.applicationLabel(self.browser), "Browser (Recent)")
        XCTAssertEqual(SettingsStore.shared.meetingRecordingDefaults, defaultsBefore)
        XCTAssertEqual(starts, 0)
        reopened.cancel()
    }

    func testRecentTagFollowsARelaunchedAppWithoutChoosingAmongDuplicateCopies() {
        var snapshot = self.snapshot()
        snapshot.recentApplication = self.browser
        var restarted = self.browser
        restarted.processID = 99
        snapshot.applications = [self.zoom, restarted]
        XCTAssertEqual(snapshot.availableRecentApplication, restarted)
        XCTAssertEqual(snapshot.applicationLabel(restarted), "Browser (Recent)")
        var duplicate = restarted
        duplicate.processID = 100
        snapshot.applications.append(duplicate)
        XCTAssertNil(snapshot.availableRecentApplication)
        XCTAssertEqual(snapshot.applicationLabel(restarted), "Browser")
        snapshot.recentApplication = duplicate
        XCTAssertEqual(snapshot.availableRecentApplication, duplicate)
        XCTAssertEqual(snapshot.applicationLabel(restarted), "Browser")
        XCTAssertEqual(snapshot.applicationLabel(duplicate), "Browser (Recent)")
        snapshot.applications = [self.zoom]
        XCTAssertNil(snapshot.availableRecentApplication)
        XCTAssertEqual(snapshot.selectedApplication, self.zoom)
    }

    func testRecentAppPersistenceDoesNotKeepWindowOrDisplayTargets() {
        var choice = self.browser
        choice.windowID = 7
        choice.displayID = 8
        SettingsStore.shared.meetingRecentApplication = choice
        let restored = SettingsStore.shared.meetingRecentApplication
        XCTAssertEqual(restored?.bundleIdentifier, choice.bundleIdentifier)
        XCTAssertEqual(restored?.processID, choice.processID)
        XCTAssertNil(restored?.windowID)
        XCTAssertNil(restored?.displayID)
    }

    func testOnlySourcePickerPanelsCanTakeKeyboardFocus() {
        let captions = MeetingFloatingCaptionsPanel()
        XCTAssertFalse(captions.canBecomeKey)
        captions.allowsKeyboardFocus = true
        XCTAssertTrue(captions.canBecomeKey)
    }

    func testPromptRendersAllChoicesWithoutRecordingOrChangingPreferences() async throws {
        let defaultsBefore = SettingsStore.shared.meetingRecordingDefaults
        var starts = 0
        var empty = self.snapshot()
        empty.selectedApplication = nil
        var inRoom = self.snapshot()
        inRoom.defaults.mode = .inRoom
        inRoom.selectedApplication = nil
        var unavailable = self.snapshot()
        unavailable.sourceMessage = "The selected app is no longer available. Refresh sources to choose it again."
        var recent = self.snapshot()
        recent.recentApplication = self.zoom
        let scenarios = [("selected", self.snapshot()), ("empty", empty), ("in-person", inRoom), ("unavailable", unavailable), ("recent", recent)]
        for (name, snapshot) in scenarios {
            SettingsStore.shared.meetingRecentApplication = snapshot.recentApplication
            let controller = MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in snapshot }, start: { _ in starts += 1 })
            controller.handleShortcut()
            await self.waitUntil { !controller.isLoading }
            for scheme in [ColorScheme.dark, .light] {
                let content = MeetingRecordingSourcePromptContent(controller: controller)
                    .appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme))
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 392, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let directory = URL(fileURLWithPath: "/tmp/meeting-source-prompt-review", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("\(name)-\(scheme).png"))
                window.close()
            }
            controller.cancel()
        }
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(SettingsStore.shared.meetingRecordingDefaults, defaultsBefore)
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the source prompt", file: file, line: line)
    }
}
