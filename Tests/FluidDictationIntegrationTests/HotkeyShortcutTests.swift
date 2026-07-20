import AppKit
import CoreAudio
@testable import FluidVoice_Debug
import Foundation
import XCTest

final class HotkeyShortcutTests: XCTestCase {
    private let legacyHotkeyShortcutKey = "HotkeyShortcutKey"
    private let primaryDictationShortcutsKey = "PrimaryDictationShortcuts"
    private let pasteLastTranscriptionShortcutKey = "PasteLastTranscriptionHotkeyShortcut"
    private let pasteLastTranscriptionEnabledKey = "PasteLastTranscriptionShortcutEnabled"
    private let microphoneSelectionModeKey = "MicrophoneSelectionMode"
    private let preferredInputDeviceUIDKey = "PreferredInputDeviceUID"
    private let systemInputDeviceUIDBeforeManualKey = "SystemInputDeviceUIDBeforeManual"

    func testCoreAudioFrameCountUsesActualBufferChannelLayout() {
        XCTAssertEqual(fv_core_audio_buffer_frame_count(512 * 4, 4, 1), 512)
        XCTAssertEqual(fv_core_audio_buffer_frame_count(512 * 8, 4, 2), 512)
        XCTAssertEqual(fv_core_audio_buffer_frame_count(512 * 12, 4, 3), 512)

        // Three non-interleaved buffers each contain one channel and must each
        // report 512 frames, never the 170-frame failure observed in the field.
        for _ in 0..<3 {
            XCTAssertEqual(fv_core_audio_buffer_frame_count(512 * 4, 4, 1), 512)
        }
    }

    func testDirectCaptureDurationMismatchFilter() {
        XCTAssertFalse(ASRService.directCaptureDurationIsMismatched(
            capturedMilliseconds: 100,
            elapsedMilliseconds: 499
        ))
        XCTAssertFalse(ASRService.directCaptureDurationIsMismatched(
            capturedMilliseconds: 460,
            elapsedMilliseconds: 500
        ))
        XCTAssertFalse(ASRService.directCaptureDurationIsMismatched(
            capturedMilliseconds: 700,
            elapsedMilliseconds: 1000
        ))
        XCTAssertFalse(ASRService.directCaptureDurationIsMismatched(
            capturedMilliseconds: 1300,
            elapsedMilliseconds: 1000
        ))
        XCTAssertTrue(ASRService.directCaptureDurationIsMismatched(
            capturedMilliseconds: 333,
            elapsedMilliseconds: 1000
        ))
        XCTAssertTrue(ASRService.directCaptureDurationIsMismatched(
            capturedMilliseconds: 1500,
            elapsedMilliseconds: 1000
        ))
        XCTAssertFalse(ASRService.directCaptureShouldDisable(afterFailureCount: 1))
        XCTAssertFalse(ASRService.directCaptureShouldDisable(afterFailureCount: 2))
        XCTAssertTrue(ASRService.directCaptureShouldDisable(afterFailureCount: 3))
        XCTAssertTrue(ASRService.directCaptureShouldDisable(afterFailureCount: 4))
    }

    func testLegacyKeyboardShortcutPayloadDefaultsToKeyboardKind() throws {
        let json = #"{"keyCode":61,"modifierFlagsRawValue":0}"#
        let data = try XCTUnwrap(json.data(using: .utf8))

        let shortcut = try JSONDecoder().decode(HotkeyShortcut.self, from: data)

        XCTAssertEqual(shortcut.kind, .keyboard)
        XCTAssertFalse(shortcut.isMouseShortcut)
        XCTAssertEqual(shortcut.keyCode, 61)
        XCTAssertTrue(shortcut.matches(keyCode: 61, modifiers: NSEvent.ModifierFlags()))
    }

    func testKeyboardPayloadIgnoresStrayMouseButtonField() throws {
        let json = #"{"kind":"keyboard","keyCode":0,"modifierFlagsRawValue":0,"mouseButton":3}"#
        let data = try XCTUnwrap(json.data(using: .utf8))

        let shortcut = try JSONDecoder().decode(HotkeyShortcut.self, from: data)

        XCTAssertFalse(shortcut.isMouseShortcut)
        XCTAssertEqual(shortcut.displayString, "A")
        XCTAssertFalse(shortcut.matchesMouse(button: 3, modifiers: NSEvent.ModifierFlags()))
    }

    func testMouseShortcutRoundTripsAndMatchesOnlyMouseEvents() throws {
        let shortcut = HotkeyShortcut(mouseButton: 3, modifierFlags: [.option])

        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(HotkeyShortcut.self, from: data)

        XCTAssertEqual(decoded.kind, .mouse)
        XCTAssertTrue(decoded.isMouseShortcut)
        XCTAssertEqual(decoded.mouseButton, 3)
        XCTAssertTrue(decoded.matchesMouse(button: 3, modifiers: [.option]))
        XCTAssertFalse(decoded.matchesMouse(button: 3, modifiers: NSEvent.ModifierFlags()))
        XCTAssertFalse(decoded.matches(keyCode: 0, modifiers: [.option]))
    }

    func testUnmodifiedLeftAndRightClicksDoNotMatchMouseEvents() {
        let leftClick = HotkeyShortcut(mouseButton: 0, modifierFlags: NSEvent.ModifierFlags())
        let rightClick = HotkeyShortcut(mouseButton: 1, modifierFlags: NSEvent.ModifierFlags())
        let sideButton = HotkeyShortcut(mouseButton: 3, modifierFlags: NSEvent.ModifierFlags())
        let modifiedLeftClick = HotkeyShortcut(mouseButton: 0, modifierFlags: [.control])

        XCTAssertTrue(leftClick.isUnmodifiedLeftOrRightClick)
        XCTAssertTrue(rightClick.isUnmodifiedLeftOrRightClick)
        XCTAssertFalse(leftClick.matchesMouse(button: 0, modifiers: NSEvent.ModifierFlags()))
        XCTAssertFalse(rightClick.matchesMouse(button: 1, modifiers: NSEvent.ModifierFlags()))
        XCTAssertTrue(sideButton.matchesMouse(button: 3, modifiers: NSEvent.ModifierFlags()))
        XCTAssertTrue(modifiedLeftClick.matchesMouse(button: 0, modifiers: [.control]))
    }

    func testMouseShortcutDisplayIncludesModifiers() {
        let shortcut = HotkeyShortcut(mouseButton: 0, modifierFlags: [.control, .shift])

        XCTAssertEqual(shortcut.displayString, "⌃ + ⇧ + Left Click")
    }

    func testMouseShortcutDoesNotEqualKeyboardShortcutWithPlaceholderKeyCode() {
        let mouseShortcut = HotkeyShortcut(mouseButton: 3, modifierFlags: NSEvent.ModifierFlags())
        let keyboardShortcut = HotkeyShortcut(keyCode: 0, modifierFlags: NSEvent.ModifierFlags())

        XCTAssertEqual(mouseShortcut.displayString, "Mouse 4")
        XCTAssertNotEqual(mouseShortcut, keyboardShortcut)
    }

    func testModifiedMouseShortcutConflictsWithModifierOnlyShortcut() {
        let optionOnly = HotkeyShortcut(keyCode: 61, modifierFlags: [])
        let modifiedClick = HotkeyShortcut(mouseButton: 0, modifierFlags: [.option])
        let unmodifiedSideButton = HotkeyShortcut(mouseButton: 3, modifierFlags: [])

        XCTAssertTrue(modifiedClick.conflictsWith(optionOnly))
        XCTAssertTrue(optionOnly.conflictsWith(modifiedClick))
        XCTAssertFalse(unmodifiedSideButton.conflictsWith(optionOnly))
    }

    func testPrimaryDictationShortcutsFallbackToLegacyShortcut() throws {
        try self.withRestoredDefaults(keys: [self.legacyHotkeyShortcutKey, self.primaryDictationShortcutsKey]) {
            let legacyShortcut = HotkeyShortcut(keyCode: 12, modifierFlags: [.option])
            let data = try JSONEncoder().encode(legacyShortcut)
            UserDefaults.standard.set(data, forKey: self.legacyHotkeyShortcutKey)
            UserDefaults.standard.removeObject(forKey: self.primaryDictationShortcutsKey)

            XCTAssertEqual(SettingsStore.shared.primaryDictationShortcuts, [legacyShortcut])
            XCTAssertEqual(SettingsStore.shared.hotkeyShortcut, legacyShortcut)
        }
    }

    func testPrimaryDictationShortcutsPersistMultipleAndUpdateLegacyFirst() throws {
        try self.withRestoredDefaults(keys: [self.legacyHotkeyShortcutKey, self.primaryDictationShortcutsKey]) {
            let mouseShortcut = HotkeyShortcut(mouseButton: 3, modifierFlags: NSEvent.ModifierFlags())
            let keyboardShortcut = HotkeyShortcut(keyCode: 12, modifierFlags: [.option])

            SettingsStore.shared.primaryDictationShortcuts = [mouseShortcut, keyboardShortcut, mouseShortcut]

            XCTAssertEqual(SettingsStore.shared.primaryDictationShortcuts, [mouseShortcut, keyboardShortcut])
            XCTAssertEqual(SettingsStore.shared.hotkeyShortcut, mouseShortcut)
            XCTAssertEqual(
                SettingsStore.shared.primaryDictationShortcutDisplayString,
                "\(mouseShortcut.displayString) / \(keyboardShortcut.displayString)"
            )
        }
    }

    func testPasteLastTranscriptionShortcutDefaultsToUnboundAndDisabled() throws {
        try self.withRestoredDefaults(keys: [
            self.pasteLastTranscriptionShortcutKey,
            self.pasteLastTranscriptionEnabledKey,
        ]) {
            UserDefaults.standard.removeObject(forKey: self.pasteLastTranscriptionShortcutKey)
            UserDefaults.standard.removeObject(forKey: self.pasteLastTranscriptionEnabledKey)

            XCTAssertNil(SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut)
            XCTAssertFalse(SettingsStore.shared.pasteLastTranscriptionShortcutEnabled)
        }
    }

    func testPasteLastTranscriptionShortcutPersistsAndClears() throws {
        try self.withRestoredDefaults(keys: [
            self.pasteLastTranscriptionShortcutKey,
            self.pasteLastTranscriptionEnabledKey,
        ]) {
            let shortcut = HotkeyShortcut(keyCode: 9, modifierFlags: [.command, .shift])
            SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut = shortcut
            SettingsStore.shared.pasteLastTranscriptionShortcutEnabled = true

            XCTAssertEqual(SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut, shortcut)
            XCTAssertTrue(SettingsStore.shared.pasteLastTranscriptionShortcutEnabled)

            // Removing the shortcut returns to the unbound state.
            SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut = nil
            XCTAssertNil(SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut)
        }
    }

    func testPasteLastTranscriptionShortcutSupportsMouseButton() throws {
        try self.withRestoredDefaults(keys: [self.pasteLastTranscriptionShortcutKey]) {
            let mouseShortcut = HotkeyShortcut(mouseButton: 3, modifierFlags: [.option])
            SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut = mouseShortcut

            let stored = SettingsStore.shared.pasteLastTranscriptionHotkeyShortcut
            XCTAssertEqual(stored, mouseShortcut)
            XCTAssertTrue(stored?.isMouseShortcut ?? false)
            XCTAssertTrue(stored?.matchesMouse(button: 3, modifiers: [.option]) ?? false)
        }
    }

    func testMicrophoneSelectionModeDefaultsToSystem() throws {
        try self.withRestoredDefaults(keys: [self.microphoneSelectionModeKey]) {
            UserDefaults.standard.removeObject(forKey: self.microphoneSelectionModeKey)

            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .system)
        }
    }

    func testMicrophoneSelectionModePersistsManual() throws {
        try self.withRestoredDefaults(keys: [self.microphoneSelectionModeKey]) {
            SettingsStore.shared.microphoneSelectionMode = .manual

            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .manual)
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: self.microphoneSelectionModeKey),
                SettingsStore.MicrophoneSelectionMode.manual.rawValue
            )
        }
    }

    func testLegacySyncFalseDoesNotEnableManualMode() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            "SyncAudioDevicesWithSystem",
        ]) {
            UserDefaults.standard.removeObject(forKey: self.microphoneSelectionModeKey)
            UserDefaults.standard.set(false, forKey: "SyncAudioDevicesWithSystem")

            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .system)
        }
    }

    func testSystemModeInputSelectionDoesNotOverwriteManualPreference() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            SettingsStore.shared.microphoneSelectionMode = .system

            SettingsStore.shared.recordInputDeviceSelection("airpods")

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "internal")
        }
    }

    func testManualModeInputSelectionPersistsManualPreference() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.microphoneSelectionMode = .manual

            SettingsStore.shared.recordInputDeviceSelection("studio-mic")

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "studio-mic")
        }
    }

    func testSystemModeInputSelectionSyncsToSystemDefault() throws {
        try self.withRestoredDefaults(keys: [self.microphoneSelectionModeKey]) {
            SettingsStore.shared.microphoneSelectionMode = .system

            XCTAssertTrue(SettingsStore.shared.shouldSyncInputSelectionToSystemDefault())
        }
    }

    func testManualModeInputSelectionDoesNotImmediatelySyncToSystemDefault() throws {
        try self.withRestoredDefaults(keys: [self.microphoneSelectionModeKey]) {
            SettingsStore.shared.microphoneSelectionMode = .manual

            XCTAssertFalse(SettingsStore.shared.shouldSyncInputSelectionToSystemDefault())
        }
    }

    func testSwitchingBackToSystemModeRestoresPreviousSystemInput() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.systemInputDeviceUIDBeforeManualKey,
        ]) {
            SettingsStore.shared.microphoneSelectionMode = .system
            _ = SettingsStore.shared.setMicrophoneSelectionMode(
                .manual,
                currentSystemInputUID: "internal",
                availableInputUIDs: ["internal", "airpods"]
            )
            SettingsStore.shared.recordInputDeviceSelection("airpods")

            let restoreUID = SettingsStore.shared.setMicrophoneSelectionMode(
                .system,
                currentSystemInputUID: "airpods",
                availableInputUIDs: ["internal", "airpods"]
            )

            XCTAssertEqual(restoreUID, "internal")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .system)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "airpods")
        }
    }

    func testSwitchingBackToSystemModeFallsBackWhenPreviousSystemInputUnavailable() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.systemInputDeviceUIDBeforeManualKey,
        ]) {
            SettingsStore.shared.microphoneSelectionMode = .system
            _ = SettingsStore.shared.setMicrophoneSelectionMode(
                .manual,
                currentSystemInputUID: "internal",
                availableInputUIDs: ["internal", "airpods"]
            )
            SettingsStore.shared.recordInputDeviceSelection("airpods")

            let restoreUID = SettingsStore.shared.setMicrophoneSelectionMode(
                .system,
                currentSystemInputUID: "airpods",
                availableInputUIDs: ["airpods"]
            )

            XCTAssertEqual(restoreUID, "airpods")
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "airpods")
        }
    }

    @MainActor
    func testMicrophoneCoordinatorSkipsSystemMode() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.microphoneSelectionMode = .system
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            let devices = FakeAudioDeviceManager(
                inputs: [Self.device(uid: "internal", name: "MacBook Pro Microphone")],
                defaultInputUID: "airpods"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let result = coordinator.enforcePreferredInput(reason: "unit test")

            XCTAssertEqual(result, .skippedSystemMode)
            XCTAssertEqual(devices.setInputCalls, [])
        }
    }

    @MainActor
    func testMicrophoneCoordinatorAppliesManualPreferredInput() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            let devices = FakeAudioDeviceManager(
                inputs: [
                    Self.device(uid: "internal", name: "MacBook Pro Microphone"),
                    Self.device(uid: "airpods", name: "AirPods"),
                ],
                defaultInputUID: "airpods"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let result = coordinator.enforcePreferredInput(reason: "unit test")

            XCTAssertEqual(result, .applied("internal"))
            XCTAssertEqual(devices.setInputCalls, ["internal"])
            XCTAssertEqual(devices.defaultInputUID, "internal")
        }
    }

    @MainActor
    func testMicrophoneCoordinatorKeepsUnavailableManualPreference() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.preferredInputDeviceUID = "external"
            let devices = FakeAudioDeviceManager(
                inputs: [Self.device(uid: "internal", name: "MacBook Pro Microphone")],
                defaultInputUID: "internal"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let result = coordinator.enforcePreferredInput(reason: "unit test")

            XCTAssertEqual(result, .skippedPreferredUnavailable("external"))
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "external")
            XCTAssertEqual(devices.setInputCalls, [])
        }
    }

    @MainActor
    func testMicrophoneCoordinatorNoOpsWhenPreferredAlreadyDefault() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            let devices = FakeAudioDeviceManager(
                inputs: [Self.device(uid: "internal", name: "MacBook Pro Microphone")],
                defaultInputUID: "internal"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let result = coordinator.enforcePreferredInput(reason: "unit test")

            XCTAssertEqual(result, .alreadyUsingPreferred("internal"))
            XCTAssertEqual(devices.setInputCalls, [])
        }
    }

    @MainActor
    func testMicrophoneCoordinatorResolvesManualPreferredInputForCapture() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.preferredInputDeviceUID = "studio-mic"
            let studioMic = Self.device(uid: "studio-mic", name: "Studio Mic")
            let devices = FakeAudioDeviceManager(
                inputs: [
                    Self.device(uid: "internal", name: "MacBook Pro Microphone"),
                    studioMic,
                ],
                defaultInputUID: "internal"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let resolved = coordinator.inputDeviceForCapture()

            XCTAssertEqual(resolved, studioMic)
            XCTAssertEqual(devices.setInputCalls, [])
        }
    }

    private static func device(uid: String, name: String) -> AudioDevice.Device {
        AudioDevice.Device(
            id: AudioObjectID(abs(uid.hashValue % 100_000) + 1),
            uid: uid,
            name: name,
            hasInput: true,
            hasOutput: false
        )
    }

    private func withRestoredDefaults(keys: [String], run: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }

        defer {
            for key in keys {
                if let previous = snapshot[key] {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        try run()
    }
}

@MainActor
private final class FakeAudioDeviceManager: AudioDeviceManaging {
    let inputs: [AudioDevice.Device]
    var defaultInputUID: String?
    private(set) var setInputCalls: [String] = []

    init(inputs: [AudioDevice.Device], defaultInputUID: String?) {
        self.inputs = inputs
        self.defaultInputUID = defaultInputUID
    }

    func listInputDevices() -> [AudioDevice.Device] {
        self.inputs
    }

    func defaultInputDevice() -> AudioDevice.Device? {
        guard let defaultInputUID else { return nil }
        return self.inputs.first { $0.uid == defaultInputUID }
    }

    func setDefaultInputDevice(uid: String) -> Bool {
        self.setInputCalls.append(uid)
        self.defaultInputUID = uid
        return true
    }
}
