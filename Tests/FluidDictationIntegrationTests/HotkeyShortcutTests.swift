import AppKit
import Combine
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
    private let appOnlyMicMigrationVersionKey = "AppOnlyMicrophoneSelectionMigrationVersion"
    private let experimentalDirectAudioCaptureEnabledKey = "ExperimentalDirectAudioCaptureEnabled"

    @MainActor
    func testBottomOverlayRapidStopStartStopDoesNotDropFinalHide() async {
        let audioPublisher = Just(CGFloat.zero).eraseToAnyPublisher()
        let controller = BottomOverlayWindowController.shared

        controller.prepare()
        await Task.yield()
        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        controller.hide()
        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        let outcome = await controller.hideAndWait()

        XCTAssertEqual(outcome, .hidden)
        XCTAssertFalse(NotchContentState.shared.isBottomOverlayPresented)
    }

    @MainActor
    func testBottomOverlayReportsWhenRapidRestartSupersedesHide() async {
        let audioPublisher = Just(CGFloat.zero).eraseToAnyPublisher()
        let controller = BottomOverlayWindowController.shared

        controller.prepare()
        await Task.yield()
        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        let hideTask = Task { @MainActor in
            await controller.hideAndWait()
        }
        await Task.yield()
        controller.show(audioPublisher: audioPublisher, mode: .dictation)

        let hideOutcome = await hideTask.value
        XCTAssertEqual(hideOutcome, .superseded)
        XCTAssertTrue(NotchContentState.shared.isBottomOverlayPresented)
        _ = await controller.hideAndWait()
    }

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

    func testShortAudioSilenceGateRejectsOnlyClearShortSilence() {
        let silence = [Float](repeating: 0.0005, count: 16_000)
        let silenceAssessment = ASRService.assessShortAudioSilence(silence)
        XCTAssertTrue(silenceAssessment.isEligible)
        XCTAssertTrue(silenceAssessment.shouldSkipTranscription)

        var quietSpeech = [Float](repeating: 0.0005, count: 16_000)
        for index in 4000..<4320 {
            quietSpeech[index] = index.isMultiple(of: 2) ? 0.012 : -0.012
        }
        let quietSpeechAssessment = ASRService.assessShortAudioSilence(quietSpeech)
        XCTAssertTrue(quietSpeechAssessment.isEligible)
        XCTAssertFalse(quietSpeechAssessment.shouldSkipTranscription)

        let longSilence = [Float](repeating: 0, count: 64_001)
        let longAssessment = ASRService.assessShortAudioSilence(longSilence)
        XCTAssertFalse(longAssessment.isEligible)
        XCTAssertFalse(longAssessment.shouldSkipTranscription)
    }

    func testShortAudioSilenceGateFailsOpenForInvalidSamples() {
        var samples = [Float](repeating: 0, count: 8000)
        samples[100] = .nan

        let assessment = ASRService.assessShortAudioSilence(samples)

        XCTAssertTrue(assessment.isEligible)
        XCTAssertFalse(assessment.shouldSkipTranscription)
    }

    func testShortAudioSilenceGateRunsOnlyWhenEnabledForUnrecognizedDictation() {
        XCTAssertFalse(ASRService.shouldAssessShortAudioSilence(
            isEnabled: false,
            useDictionaryTrainingPath: false,
            hasRecognizedStreamingPreview: false
        ))
        XCTAssertFalse(ASRService.shouldAssessShortAudioSilence(
            isEnabled: true,
            useDictionaryTrainingPath: true,
            hasRecognizedStreamingPreview: false
        ))
        XCTAssertFalse(ASRService.shouldAssessShortAudioSilence(
            isEnabled: true,
            useDictionaryTrainingPath: false,
            hasRecognizedStreamingPreview: true
        ))
        XCTAssertTrue(ASRService.shouldAssessShortAudioSilence(
            isEnabled: true,
            useDictionaryTrainingPath: false,
            hasRecognizedStreamingPreview: false
        ))
    }

    @MainActor
    func testSilentRecordingSettingRoundTripsAndOlderBackupsStillDecode() async throws {
        let settingsStore = SettingsStore.shared
        let originalValue = settingsStore.skipSilentRecordingsEnabled
        defer { settingsStore.skipSilentRecordingsEnabled = originalValue }

        settingsStore.skipSilentRecordingsEnabled = true
        let document = await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.skipSilentRecordingsEnabled, true)

        let encoded = try BackupService.shared.encode(document)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var settings = try XCTUnwrap(root["settings"] as? [String: Any])
        settings.removeValue(forKey: "skipSilentRecordingsEnabled")
        root["settings"] = settings

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let decoded = try BackupService.shared.decode(legacyData)
        XCTAssertNil(decoded.settings.skipSilentRecordingsEnabled)
    }

    @MainActor
    func testSystemModeBackupRestartsAppOnlyMicrophoneMigration() async throws {
        let document = await BackupService.shared.makeBackupDocument()

        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.appOnlyMicMigrationVersionKey,
        ]) {
            SettingsStore.shared.appMicSelectionMigrationVersion = 1
            let encoded = try BackupService.shared.encode(document)
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var settings = try XCTUnwrap(root["settings"] as? [String: Any])
            settings["microphoneSelectionMode"] = SettingsStore.MicrophoneSelectionMode.system.rawValue
            settings["preferredInputDeviceUID"] = "legacy-system-mic"
            root["settings"] = settings
            let backup = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))

            SettingsStore.shared.restore(from: backup.settings)

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "legacy-system-mic")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .manual)
            XCTAssertEqual(SettingsStore.shared.appMicSelectionMigrationVersion, 0)
        }
    }

    @MainActor
    func testAppOnlyBackupKeepsCompletedMicrophoneMigration() async {
        let document = await BackupService.shared.makeBackupDocument()

        self.withRestoredDefaults(keys: [self.appOnlyMicMigrationVersionKey]) {
            SettingsStore.shared.appMicSelectionMigrationVersion = 1

            SettingsStore.shared.restore(from: document.settings)

            XCTAssertEqual(SettingsStore.shared.appMicSelectionMigrationVersion, 1)
        }
    }

    func testDirectAudioCaptureIsEnabledWhenLegacyPreferenceIsUnset() {
        self.withRestoredDefaults(keys: [self.experimentalDirectAudioCaptureEnabledKey]) {
            UserDefaults.standard.removeObject(forKey: self.experimentalDirectAudioCaptureEnabledKey)

            XCTAssertTrue(SettingsStore.shared.experimentalDirectAudioCaptureEnabled)
        }
    }

    func testDirectAudioCaptureIgnoresStoredDisabledPreference() {
        self.withRestoredDefaults(keys: [self.experimentalDirectAudioCaptureEnabledKey]) {
            UserDefaults.standard.set(false, forKey: self.experimentalDirectAudioCaptureEnabledKey)

            XCTAssertTrue(SettingsStore.shared.experimentalDirectAudioCaptureEnabled)
        }
    }

    func testLegacyAVAudioEngineDoesNotPrewarmWhileIdle() {
        XCTAssertFalse(AudioCaptureIdlePolicy.shouldPrewarmCapture(
            experimentalDirectAudioCaptureEnabled: false
        ))
    }

    func testPreparedDirectCaptureMayRemainWarmWhileIdle() {
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldPrewarmCapture(
            experimentalDirectAudioCaptureEnabled: true
        ))
    }

    func testDirectRecoveryTracksOnlyPreferredInputAvailability() {
        let previousUIDs = Set(["preferred", "built-in"])

        XCTAssertFalse(AudioCaptureIdlePolicy.didPreferredInputAvailabilityChange(
            preferredInputUID: "preferred",
            previousInputUIDs: previousUIDs,
            currentInputUIDs: previousUIDs.union(["unrelated"])
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.didPreferredInputAvailabilityChange(
            preferredInputUID: "preferred",
            previousInputUIDs: previousUIDs,
            currentInputUIDs: ["built-in"]
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.didPreferredInputAvailabilityChange(
            preferredInputUID: "preferred",
            previousInputUIDs: ["built-in"],
            currentInputUIDs: previousUIDs
        ))
    }

    func testPendingMicrophoneMigrationRetriesWhenDevicesAppear() {
        XCTAssertFalse(AudioCaptureIdlePolicy.shouldReconcileInputSelection(
            preferredInputUID: "disconnected-usb",
            migrationPending: true,
            previousInputUIDs: [],
            currentInputUIDs: []
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldReconcileInputSelection(
            preferredInputUID: "disconnected-usb",
            migrationPending: true,
            previousInputUIDs: [],
            currentInputUIDs: ["built-in"]
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldReconcileInputSelection(
            preferredInputUID: nil,
            migrationPending: false,
            previousInputUIDs: [],
            currentInputUIDs: ["built-in"]
        ))
    }

    func testEngineConfigurationChangesRecoverOnlyDuringCaptureTransitions() {
        XCTAssertFalse(AudioCaptureIdlePolicy.shouldRecoverEngineConfigurationChange(
            isRunning: false,
            isStarting: false
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldRecoverEngineConfigurationChange(
            isRunning: true,
            isStarting: false
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldRecoverEngineConfigurationChange(
            isRunning: false,
            isStarting: true
        ))
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

    func testMicrophoneSelectionModeIsAlwaysAppOnly() throws {
        try self.withRestoredDefaults(keys: [self.microphoneSelectionModeKey]) {
            UserDefaults.standard.set(
                SettingsStore.MicrophoneSelectionMode.system.rawValue,
                forKey: self.microphoneSelectionModeKey
            )

            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .manual)
        }
    }

    func testInputSelectionPersistsAppPreference() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.recordInputDeviceSelection("studio-mic")

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "studio-mic")
        }
    }

    func testAudioDeviceClassifiesBluetoothTransports() {
        let bluetoothDevice = Self.device(
            uid: "bluetooth",
            name: "Bluetooth Microphone",
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        let bluetoothLEDevice = Self.device(
            uid: "bluetooth-le",
            name: "Bluetooth LE Microphone",
            transportType: kAudioDeviceTransportTypeBluetoothLE
        )

        XCTAssertTrue(bluetoothDevice.isBluetooth)
        XCTAssertTrue(bluetoothLEDevice.isBluetooth)
        XCTAssertFalse(bluetoothDevice.isBuiltIn)
        XCTAssertFalse(bluetoothLEDevice.isBuiltIn)
    }

    func testAudioDeviceClassifiesBuiltInTransport() {
        let builtInDevice = Self.device(
            uid: "built-in",
            name: "MacBook Pro Microphone",
            transportType: kAudioDeviceTransportTypeBuiltIn
        )

        XCTAssertTrue(builtInDevice.isBuiltIn)
        XCTAssertFalse(builtInDevice.isBluetooth)
    }

    @MainActor
    func testClamshellCaptureKeepsSelectedExternalMicrophone() {
        self.withRestoredDefaults(keys: [self.preferredInputDeviceUIDKey]) {
            SettingsStore.shared.preferredInputDeviceUID = "usb"
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            let usb = Self.device(uid: "usb", name: "USB Microphone")
            let devices = FakeAudioDeviceManager(
                inputs: [builtIn, usb],
                defaultInputUID: "internal"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let resolution = coordinator.captureResolution(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID,
                isLidClosed: true
            )

            XCTAssertEqual(resolution, .clamshellSelectedExternal(usb))
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "usb")
        }
    }

    @MainActor
    func testClamshellCaptureTemporarilyUsesDefaultExternalMicrophone() {
        self.withRestoredDefaults(keys: [self.preferredInputDeviceUIDKey]) {
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            let display = Self.device(uid: "display", name: "Display Microphone")
            let usb = Self.device(uid: "usb", name: "USB Microphone")
            let devices = FakeAudioDeviceManager(
                inputs: [builtIn, display, usb],
                defaultInputUID: "usb"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let resolution = coordinator.captureResolution(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID,
                isLidClosed: true
            )

            XCTAssertEqual(resolution, .clamshellFallback(usb))
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "internal")
        }
    }

    @MainActor
    func testClamshellCaptureUsesAvailableExternalWhenDefaultIsBuiltIn() {
        self.withRestoredDefaults(keys: [self.preferredInputDeviceUIDKey]) {
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            let usb = Self.device(uid: "usb", name: "USB Microphone")
            let devices = FakeAudioDeviceManager(
                inputs: [builtIn, usb],
                defaultInputUID: "internal"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let resolution = coordinator.captureResolution(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID,
                isLidClosed: true
            )

            XCTAssertEqual(resolution, .clamshellFallback(usb))
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "internal")
        }
    }

    @MainActor
    func testClamshellCaptureRejectsBuiltInMicrophoneWithoutExternalInput() {
        self.withRestoredDefaults(keys: [self.preferredInputDeviceUIDKey]) {
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            let devices = FakeAudioDeviceManager(
                inputs: [builtIn],
                defaultInputUID: "internal"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let resolution = coordinator.captureResolution(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID,
                isLidClosed: true
            )

            XCTAssertEqual(resolution, .clamshellRequiresExternalMicrophone)
        }
    }

    @MainActor
    func testOpenLidCaptureKeepsStandardRouting() {
        self.withRestoredDefaults(keys: [self.preferredInputDeviceUIDKey]) {
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            let usb = Self.device(uid: "usb", name: "USB Microphone")
            let devices = FakeAudioDeviceManager(
                inputs: [builtIn, usb],
                defaultInputUID: "usb"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let resolution = coordinator.captureResolution(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID,
                isLidClosed: false
            )

            XCTAssertEqual(resolution, .standard)
        }
    }

    @MainActor
    func testMicrophoneMigrationChoosesBuiltInOnce() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.appOnlyMicMigrationVersionKey,
        ]) {
            UserDefaults.standard.set(
                SettingsStore.MicrophoneSelectionMode.system.rawValue,
                forKey: self.microphoneSelectionModeKey
            )
            SettingsStore.shared.preferredInputDeviceUID = "airpods"
            SettingsStore.shared.appMicSelectionMigrationVersion = 0
            let devices = FakeAudioDeviceManager(
                inputs: [
                    Self.device(
                        uid: "internal",
                        name: "MacBook Pro Microphone",
                        transportType: kAudioDeviceTransportTypeBuiltIn
                    ),
                    Self.device(uid: "airpods", name: "AirPods"),
                ],
                defaultInputUID: "airpods"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            coordinator.migrateToAppOnlySelectionIfNeeded()

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "internal")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .manual)
            XCTAssertEqual(SettingsStore.shared.appMicSelectionMigrationVersion, 1)
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: self.microphoneSelectionModeKey),
                SettingsStore.MicrophoneSelectionMode.manual.rawValue
            )
            XCTAssertEqual(devices.defaultInputUID, "airpods")

            SettingsStore.shared.recordInputDeviceSelection("airpods")
            coordinator.migrateToAppOnlySelectionIfNeeded()
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "airpods")
        }
    }

    @MainActor
    func testMicrophoneMigrationWaitsForAUsableDeviceList() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.appOnlyMicMigrationVersionKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "airpods"
            SettingsStore.shared.appMicSelectionMigrationVersion = 0
            let devices = FakeAudioDeviceManager(inputs: [], defaultInputUID: nil)
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            coordinator.migrateToAppOnlySelectionIfNeeded()

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "airpods")
            XCTAssertEqual(SettingsStore.shared.appMicSelectionMigrationVersion, 0)
        }
    }

    @MainActor
    func testMicrophoneMigrationWithoutBuiltInPreservesAvailableSelection() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.appOnlyMicMigrationVersionKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "studio-mic"
            SettingsStore.shared.appMicSelectionMigrationVersion = 0
            let devices = FakeAudioDeviceManager(
                inputs: [
                    Self.device(uid: "display-mic", name: "Display Mic"),
                    Self.device(uid: "studio-mic", name: "Studio Mic"),
                ],
                defaultInputUID: "display-mic"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            coordinator.migrateToAppOnlySelectionIfNeeded()

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "studio-mic")
            XCTAssertEqual(SettingsStore.shared.appMicSelectionMigrationVersion, 1)
            XCTAssertEqual(devices.defaultInputUID, "display-mic")
        }
    }

    @MainActor
    func testMicrophoneMigrationWithoutBuiltInReplacesMissingSelectionWithDefault() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.appOnlyMicMigrationVersionKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "disconnected-usb"
            SettingsStore.shared.appMicSelectionMigrationVersion = 0
            let devices = FakeAudioDeviceManager(
                inputs: [
                    Self.device(uid: "display-mic", name: "Display Mic"),
                    Self.device(uid: "studio-mic", name: "Studio Mic"),
                ],
                defaultInputUID: "studio-mic"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            coordinator.migrateToAppOnlySelectionIfNeeded()

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "studio-mic")
            XCTAssertEqual(SettingsStore.shared.appMicSelectionMigrationVersion, 1)
            XCTAssertEqual(devices.defaultInputUID, "studio-mic")
        }
    }

    @MainActor
    func testCompletedMigrationReconcilesMissingSavedInputAtLaunch() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.appOnlyMicMigrationVersionKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "disconnected-usb"
            SettingsStore.shared.appMicSelectionMigrationVersion = 1
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            let devices = FakeAudioDeviceManager(
                inputs: [builtIn, Self.device(uid: "usb", name: "USB Mic")],
                defaultInputUID: "usb"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let reconciled = coordinator.reconcileAppOnlySelection(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID
            )

            XCTAssertEqual(reconciled, builtIn)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "internal")
            XCTAssertEqual(devices.defaultInputUID, "usb")
        }
    }

    @MainActor
    func testMicrophoneCoordinatorKeepsAvailableUserSelection() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "studio-mic"
            let studioMic = Self.device(uid: "studio-mic", name: "Studio Mic")
            let devices = FakeAudioDeviceManager(
                inputs: [
                    Self.device(
                        uid: "internal",
                        name: "MacBook Pro Microphone",
                        transportType: kAudioDeviceTransportTypeBuiltIn
                    ),
                    studioMic,
                ],
                defaultInputUID: "internal"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let resolved = coordinator.inputDeviceForCapture()

            XCTAssertEqual(resolved, studioMic)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "studio-mic")
        }
    }

    @MainActor
    func testMicrophoneCoordinatorFallsBackToBuiltInWhenSelectionDisappears() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "airpods"
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            let devices = FakeAudioDeviceManager(
                inputs: [builtIn, Self.device(uid: "usb", name: "USB Mic")],
                defaultInputUID: "usb"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let previewFallback = coordinator.inputDeviceForCapture()

            XCTAssertEqual(previewFallback, builtIn)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "airpods")
            XCTAssertEqual(devices.defaultInputUID, "usb")

            let settledFallback = coordinator.inputDeviceForCapture(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID,
                persistFallback: true
            )
            XCTAssertEqual(settledFallback, builtIn)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "internal")
            XCTAssertEqual(devices.defaultInputUID, "usb")

            let afterReconnect = coordinator.inputDeviceForCapture(availableInputs: [
                builtIn,
                Self.device(uid: "airpods", name: "AirPods"),
            ])
            XCTAssertEqual(afterReconnect, builtIn)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "internal")
        }
    }

    @MainActor
    func testMicrophoneCoordinatorUsesCurrentInputWhenNoBuiltInExists() throws {
        try self.withRestoredDefaults(keys: [self.preferredInputDeviceUIDKey]) {
            SettingsStore.shared.preferredInputDeviceUID = "disconnected"
            let currentInput = Self.device(uid: "usb", name: "USB Mic")
            let devices = FakeAudioDeviceManager(
                inputs: [Self.device(uid: "other", name: "Other Mic"), currentInput],
                defaultInputUID: "usb"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let previewFallback = coordinator.inputDeviceForCapture()

            XCTAssertEqual(previewFallback, currentInput)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "disconnected")

            let settledFallback = coordinator.inputDeviceForCapture(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID,
                persistFallback: true
            )
            XCTAssertEqual(settledFallback, currentInput)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "usb")
        }
    }

    private static func device(
        uid: String,
        name: String,
        transportType: UInt32 = kAudioDeviceTransportTypeUnknown
    ) -> AudioDevice.Device {
        AudioDevice.Device(
            id: AudioObjectID(abs(uid.hashValue % 100_000) + 1),
            uid: uid,
            name: name,
            hasInput: true,
            hasOutput: false,
            transportType: transportType
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
}
