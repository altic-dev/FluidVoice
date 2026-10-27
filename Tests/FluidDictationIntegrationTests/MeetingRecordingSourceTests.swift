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

    override func setUp() {
        super.setUp()
        self.originalFeature = UserDefaults.standard.object(forKey: "FluidMeetEnabled")
        SettingsStore.shared.fluidMeetEnabled = true
    }

    override func tearDown() {
        UserDefaults.standard.set(self.originalFeature, forKey: "FluidMeetEnabled")
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
        let scenarios = [("selected", self.snapshot()), ("empty", empty), ("in-person", inRoom), ("unavailable", unavailable)]
        for (name, snapshot) in scenarios {
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
