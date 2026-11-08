#!/usr/bin/env python3
"""Exercise the production meeting picker with in-memory settings and no capture."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def main():
    developer = os.environ.get('DEVELOPER_DIR') or subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    if not (Path(developer) / 'Platforms/MacOSX.platform').is_dir():
        raise SystemExit('A full Xcode is required.')
    ui = (ROOT / 'Sources/Fluid/UI/MeetingRecordingSourcePrompt.swift').read_text()
    snapshot = declaration(ui, 'nonisolated struct MeetingRecordingSourceSnapshot:')
    snapshot = snapshot.replace(declaration(snapshot, 'func configuration('), '')
    controller = declaration(ui, 'final class MeetingRecordingSourcePromptController:')
    for marker, replacement in [
        ('private static func loadSnapshot(', 'private static func loadSnapshot(foreground: MeetingApplicationIdentity?) async throws -> MeetingRecordingSourceSnapshot { fatalError("Inject a loader") }'),
        ('private static func startSnapshot(', 'private static func startSnapshot(_ snapshot: MeetingRecordingSourceSnapshot) async throws { fatalError("Inject a starter") }'),
        ('private func showPanel()', 'private func showPanel() -> Bool { false }'),
    ]:
        controller = controller.replace(declaration(controller, marker), replacement)
    models = (ROOT / 'Sources/Fluid/Services/Meeting/MeetingModels.swift').read_text()
    source = (ROOT / 'Sources/Fluid/Services/Meeting/MeetingRecordingSource.swift').read_text()
    swift = '''import AppKit
import Combine
import SwiftUI
struct Microphone: Sendable { var captureDeviceID = "mic" }
struct MeetingMicrophoneCatalogSnapshot: Sendable { var identities: [Microphone] = [.init()] }
struct MeetingInstalledCallApplication: Sendable {}
struct MeetingRecordingDefaults: Equatable, Sendable, Codable {
    static var unconfigured: Self { .init() }
    var mode: MeetingCaptureMode = .onlineCall
    var isConfigured = false
    var languageCode: String? = "en"
    var microphoneCaptureDeviceID = "mic"
    var applicationBundleIdentifier: String?
    var applicationDisplayName: String?
}
enum MeetingCaptureError: Error { case applicationNotSelected, applicationUnavailable(String) }
enum MeetingAutoDetector { struct ResolvedTarget { var bundleIdentifier: String; var pid: Int32; var windowID: UInt32? } }
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var meetingRecordingDefaults = MeetingRecordingDefaults()
    var fluidMeetEnabled = true
    var meetingRecentApplication: MeetingApplicationIdentity?
    var meetingAutoDetectEnabled = true
    var meetingAutoDetectBrowserEnabled = true
}
class MeetingFloatingCaptionsPanel: NSPanel {}
'''
    # The microphone label is unrelated to source choice; its model is replaced above.
    snapshot = snapshot.replace(declaration(snapshot, 'var microphoneSelectionLabel:'), '')
    swift += declaration((ROOT / 'Sources/Fluid/Services/Meeting/MeetingInstalledCallApplications.swift').read_text(), 'nonisolated struct MeetingApplicationIcon:') + '\n'
    swift += declaration(models, 'nonisolated enum MeetingCaptureMode:') + '\n'
    swift += declaration(models, 'nonisolated struct MeetingApplicationIdentity:') + '\n'
    swift += (ROOT / 'Sources/Fluid/Services/Meeting/MeetingAppRegistry.swift').read_text() + '\n'
    swift += source + '\n' + snapshot + '\n@MainActor\n' + controller
    page = (ROOT / 'Sources/Fluid/UI/MeetingTranscriptionView.swift').read_text()
    swift += '\n@MainActor\n' + declaration(page, 'struct MeetingTranscriptionSetupDraft:')
    swift += '\n' + declaration(page, 'nonisolated struct MeetingApplicationOption:')
    swift += '\n@MainActor final class PageHarness {\n'
    swift += '''
    var pendingSourceChoiceRefresh = false
    var canRefreshSetupAfterBackupRestore = true
    var setupDraft = MeetingTranscriptionSetupDraft()
    var applications: [MeetingApplicationOption] = []
    var titles = 0
    let appServices = TargetServices()
    func regenerateDefaultTitleIfNeeded() { titles += 1 }
    func changed() { pendingSourceChoiceRefresh = true; applyPendingSourceChoiceRefresh() }
    func safe() { canRefreshSetupAfterBackupRestore = true; applyPendingSourceChoiceRefresh() }
'''
    swift += declaration(page, 'private func selectPreferredApplication(') + '\n'
    swift += declaration(page, 'private func applyPendingSourceChoiceRefresh()') + '\n}\n'
    preferences = (ROOT / 'Sources/Fluid/Persistence/SettingsStore.swift').read_text()
    swift += '\n@MainActor final class ChoicePreferences {\nlet defaults: UserDefaults\ninit(_ defaults: UserDefaults) { self.defaults = defaults }\nenum Keys { static let meetingRecentApplication = "MeetingRecentApplication"; static let meetingRecordingDefaults = "MeetingRecordingDefaults" }\n'
    swift += declaration(preferences, 'var meetingRecentApplication:') + '\n' + declaration(preferences, 'var meetingRecordingDefaults:') + '\n}\n'
    swift += '\nfinal class EventCounter: @unchecked Sendable { var value = 0 }\n'
    swift += r'''
final class TargetServices { var meetingAutomaticTarget: MeetingAutoDetector.ResolvedTarget? }
@main struct Tests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        let zoom = MeetingApplicationIdentity(bundleIdentifier: "zoom", processID: 1, displayName: "Zoom")
        let browser = MeetingApplicationIdentity(bundleIdentifier: "browser", processID: 2, displayName: "Browser")
        var available = [zoom, browser]
        var starts = 0
        var loadFails = false
        var delay = false
        func snapshot() -> MeetingRecordingSourceSnapshot {
            MeetingRecordingSourceSnapshot(defaults: .init(), applications: available,
                microphones: .init(), selectedApplication: zoom, selectedMicrophoneID: "mic")
        }
        func picker() -> MeetingRecordingSourcePromptController {
            MeetingRecordingSourcePromptController(showsPanel: false, load: { _ in
                if delay { try? await Task.sleep(nanoseconds: 30_000_000) }
                if loadFails { throw MeetingCaptureError.applicationNotSelected }
                return snapshot()
            }, start: { _ in starts += 1 })
        }
        func settle(_ controller: MeetingRecordingSourcePromptController) async throws {
            for _ in 0..<200 where controller.isLoading { try await Task.sleep(nanoseconds: 1_000_000) }
            check(!controller.isLoading, "bounded load completion")
        }
        let suite = "FluidVoiceMeetingPickerTests." + UUID().uuidString
        let isolatedDefaults = UserDefaults(suiteName: suite)!
        defer { isolatedDefaults.removePersistentDomain(forName: suite) }
        let preferences = ChoicePreferences(isolatedDefaults)
        let events = EventCounter()
        let observer = NotificationCenter.default.addObserver(forName: .meetingRecordingSourceChoiceDidChange, object: nil, queue: nil) { _ in events.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        var choice = browser; choice.windowID = 7; choice.displayID = 9
        preferences.meetingRecentApplication = choice
        check(events.value == 1, "explicit preference change posts the narrow source event")
        check(preferences.meetingRecentApplication?.windowID == nil && preferences.meetingRecentApplication?.displayID == nil, "remembered app excludes stale window and display targets")
        preferences.meetingRecentApplication = choice
        check(events.value == 1, "identical pick does not broadcast or write again")
        check(isolatedDefaults.dictionaryRepresentation()["MeetingRecordingDefaults"] == nil, "last pick persistence cannot rewrite unrelated saved setup")
        preferences.meetingRecentApplication = nil
        check(events.value == 2 && preferences.meetingRecentApplication == nil, "Automatic clears remembered app and publishes source change")
        preferences.meetingRecentApplication = nil
        check(events.value == 2, "repeated clear is a no-op")
        var sourceDefaults = preferences.meetingRecordingDefaults
        sourceDefaults.mode = .systemAudio
        preferences.meetingRecordingDefaults = sourceDefaults
        check(events.value == 3, "Choosing Automatic notifies even when no recent app was stored")
        sourceDefaults.languageCode = "de"
        sourceDefaults.microphoneCaptureDeviceID = "other-mic"
        preferences.meetingRecordingDefaults = sourceDefaults
        check(events.value == 3, "Microphone and language changes do not broadcast a source choice")
        preferences.meetingRecordingDefaults = sourceDefaults
        check(events.value == 3, "Repeated source defaults do not broadcast")
        let settings = SettingsStore.shared
        var oldDefaults = MeetingRecordingDefaults()
        oldDefaults.isConfigured = true
        oldDefaults.applicationBundleIdentifier = "com.openai.codex"
        oldDefaults.applicationDisplayName = "ChatGPT"
        oldDefaults.languageCode = "fr"
        settings.meetingRecordingDefaults = oldDefaults
        let safari = MeetingApplicationIdentity(bundleIdentifier: "com.apple.Safari", processID: 30, displayName: "Safari")
        settings.meetingRecentApplication = safari
        let initialDraft = MeetingTranscriptionSetupDraft(settings: settings)
        check(initialDraft.preferredApplicationBundleIdentifier == safari.bundleIdentifier && !initialDraft.usesAutomaticApplication, "page restores Safari last pick instead of stale ChatGPT default")
        check(initialDraft.languageCode == "fr" && settings.meetingRecordingDefaults == oldDefaults, "resolving last pick preserves language and does not write defaults")
        let page = PageHarness()
        page.applications = [.init(identity: safari), .init(identity: zoom)]
        page.setupDraft.selectedMicrophoneID = "custom-mic"
        page.setupDraft.title = "My custom title"; page.setupDraft.titleWasEdited = true
        page.changed()
        check(page.setupDraft.selectedApplicationID == MeetingApplicationOption(identity: safari).id, "choice event updates cached page app")
        check(page.setupDraft.selectedMicrophoneID == "custom-mic" && page.setupDraft.title == "My custom title", "choice event preserves microphone and edited title")
        page.canRefreshSetupAfterBackupRestore = false
        settings.meetingRecentApplication = zoom; page.changed()
        check(page.pendingSourceChoiceRefresh && page.setupDraft.selectedApplicationID == MeetingApplicationOption(identity: safari).id, "active capture or editing sheet defers app change")
        settings.meetingRecentApplication = browser; page.changed()
        page.safe()
        check(!page.pendingSourceChoiceRefresh && page.setupDraft.selectedApplicationID == nil, "safe point uses latest pick and cannot substitute missing app")
        check(page.setupDraft.preferredApplicationBundleIdentifier == browser.bundleIdentifier, "missing app retains its identity")
        let duplicate = MeetingApplicationIdentity(bundleIdentifier: browser.bundleIdentifier, processID: 22, displayName: "Browser")
        page.applications = [.init(identity: browser), .init(identity: duplicate)]
        settings.meetingRecentApplication = duplicate; page.changed()
        check(page.setupDraft.selectedApplicationID == MeetingApplicationOption(identity: duplicate).id, "same-app processes restore the exact explicit process choice")
        let titles = page.titles; page.safe()
        check(page.titles == titles, "completed source refresh cannot replay")
        settings.meetingRecordingDefaults = .init(); settings.meetingRecentApplication = nil
        page.changed()
        check(page.setupDraft.usesAutomaticApplication && page.setupDraft.preferredApplicationBundleIdentifier == nil, "explicit Automatic choice clears old app")
        let arbitrary = MeetingApplicationIdentity(bundleIdentifier: "com.openai.codex", processID: 44, displayName: "ChatGPT")
        check(MeetingRecordingSourceSnapshot.suggestedApplication(defaults: .init(), target: nil, foreground: arbitrary, applications: [arbitrary]) == nil, "foreground ChatGPT is never an automatic suggestion")
        check(MeetingRecordingSourceSnapshot.suggestedApplication(defaults: .init(), target: nil, foreground: safari, applications: [safari]) == safari, "known meeting sources remain eligible as first-use suggestions")
        let manual = oldDefaults.preferringLastPickedApplication(arbitrary)
        check(MeetingRecordingSourceSnapshot.suggestedApplication(defaults: manual, target: nil, foreground: safari, applications: [arbitrary, safari])?.bundleIdentifier == arbitrary.bundleIdentifier, "explicit other-app choices still work")
        settings.meetingRecentApplication = nil
        let first = picker(); first.handleShortcut(foreground: browser); try await settle(first)
        check(first.snapshot?.selectedApplication == zoom, "first opening retains normal suggestion")
        check(settings.meetingRecentApplication == nil && starts == 0, "opening never writes recency or captures")
        first.selectApplication(browser); first.cancel()
        check(settings.meetingRecentApplication == browser, "explicit choice survives cancel")
        let second = picker(); second.handleShortcut(foreground: zoom); try await settle(second)
        check(second.snapshot?.selectedApplication == browser, "last pick wins over detected and foreground app")
        check(second.snapshot?.applicationLabel(browser) == "Browser (Last picked)", "clear last-picked label")
        second.refresh(); try await settle(second)
        check(second.snapshot?.selectedApplication == browser, "refresh retains explicit pick")
        second.selectApplication(nil); second.refresh(); try await settle(second)
        check(second.snapshot?.defaults.mode == .systemAudio && second.snapshot?.selectedApplication == nil, "refresh preserves all-computer choice")
        check(settings.meetingRecentApplication == nil, "Automatic clears remembered app")
        settings.meetingRecentApplication = browser
        second.cancel()
        var restarted = browser; restarted.processID = 20
        available = [zoom, restarted]
        let relaunched = picker(); relaunched.handleShortcut(); try await settle(relaunched)
        check(relaunched.snapshot?.selectedApplication?.bundleIdentifier == restarted.bundleIdentifier, "relaunch resolves current PID")
        relaunched.confirm()
        for _ in 0..<200 where relaunched.isPresented { try await Task.sleep(nanoseconds: 1_000_000) }
        check(starts == 1 && settings.meetingRecentApplication == browser, "recording does not rewrite explicit preference")
        available = [zoom]
        let missing = picker(); missing.handleShortcut(foreground: zoom); try await settle(missing)
        check(missing.snapshot?.selectedApplication == nil && !missing.canConfirm, "missing app cannot switch silently")
        check(missing.errorMessage?.contains("Browser") == true, "unavailable choice is named")
        missing.refresh(); try await settle(missing)
        check(missing.snapshot?.selectedApplication == nil, "refresh does not replace missing selection")
        missing.confirm(); check(starts == 1, "unavailable app cannot start capture"); missing.cancel()
        available = [zoom, restarted, .init(bundleIdentifier: "browser", processID: 21, displayName: "Browser")]
        let ambiguous = picker(); ambiguous.handleShortcut(); try await settle(ambiguous)
        check(ambiguous.canConfirm && ambiguous.snapshot?.selectedApplication?.capturesAllInstances == true, "duplicate copies resolve to an explicit all-instances app choice")
        ambiguous.cancel()
        loadFails = true
        let failed = picker(); failed.handleShortcut(); try await settle(failed)
        check(failed.snapshot == nil && failed.errorMessage != nil, "discovery failure has retryable visible state")
        failed.cancel(); loadFails = false
        delay = true
        let stale = picker(); stale.handleShortcut(); stale.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        check(!stale.isPresented && stale.snapshot == nil && !stale.isLoading, "late loader cannot reopen cancelled picker")
        check(settings.meetingRecentApplication == browser && starts == 1, "failures and stale loads never write preferences or capture")
        let icons = await MeetingApplicationIcon.snapshot(bundleIdentifiers: ["com.apple.finder", "com.apple.finder", "invalid.fluidvoice.missing-app"])
        check(icons.count == 1 && icons["com.apple.finder"] != nil, "icons are deduplicated and missing apps use fallback")
        check(icons["com.apple.finder"]?.image.size == NSSize(width: 16, height: 16), "icons use native menu size")
        check(await MeetingApplicationIcon.snapshot(bundleIdentifiers: []).isEmpty, "empty catalog has no icon work")
        print("PASS: \(checks) production meeting picker checks")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix='fluidvoice-picker-') as directory:
        directory = Path(directory)
        file = directory / 'Tests.swift'
        file.write_text(swift)
        binary = directory / 'tests'
        env = dict(os.environ, DEVELOPER_DIR=developer)
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(file), '-o', str(binary)], check=True, env=env, timeout=90)
        subprocess.run([str(binary)], check=True, env=env, timeout=15)


if __name__ == '__main__':
    main()
