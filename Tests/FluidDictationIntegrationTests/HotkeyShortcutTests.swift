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
    private let microphonePriorityKey = "MicrophonePriority"
    private let suppressedMicrophoneUIDsKey = "SuppressedMicrophoneUIDs"
    private let microphoneSelectionMigrationVersionKey = "AppOnlyMicrophoneSelectionMigrationVersion"
    private let showMicrophoneChangeAlertsKey = "ShowMicrophoneChangeAlerts"
    private let experimentalDirectAudioCaptureEnabledKey = "ExperimentalDirectAudioCaptureEnabled"
    private let incrementalParakeetEnabledKey = "ExperimentalParakeetUnifiedFinalEnabled"

    @MainActor
    func testActiveShortcutSummaryListsEverySourceWithKeyCodes() {
        let summary = GlobalHotkeyManager.activeShortcutSummary(.init(
            primary: [HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])],
            promptAssignments: [(key: "__default__", shortcut: HotkeyShortcut(keyCode: 55, modifierFlags: [], modifierKeyCodes: [55]))],
            secondaryPromptMode: HotkeyShortcut(keyCode: 60, modifierFlags: []),
            secondaryPromptModeEnabled: false,
            command: nil,
            commandEnabled: false,
            edit: HotkeyShortcut(keyCode: 15, modifierFlags: [.option]),
            editEnabled: true,
            cancel: HotkeyShortcut(keyCode: 53, modifierFlags: []),
            pasteLast: HotkeyShortcut(mouseButton: 0, modifierFlags: [.command]),
            pasteLastEnabled: true,
            mode: .automatic
        ))

        XCTAssertTrue(summary.hasPrefix("mode=automatic"))
        XCTAssertTrue(summary.contains("primary[0]=Right ⌥ [keyCode=61"), summary)
        XCTAssertTrue(summary.contains("prompt[__default__]=Left ⌘ [keyCode=55"), summary)
        XCTAssertTrue(summary.contains("secondaryPromptMode=Right ⇧ [keyCode=60 flags=0] enabled=false"), summary)
        XCTAssertTrue(summary.contains("command=none enabled=false"), summary)
        XCTAssertTrue(summary.contains("edit=⌥ + R [keyCode=15"), summary)
        XCTAssertTrue(summary.contains("cancel=Escape [keyCode=53"), summary)
        XCTAssertTrue(summary.contains("pasteLast=⌘ + Left Click [button=0"), summary)
    }

    func testKeyboardEventMaskExcludesMouseEvents() {
        let mask = GlobalHotkeyManager.keyboardEventMask()
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged] {
            XCTAssertNotEqual(mask & (CGEventMask(1) << type.rawValue), 0, "keyboard mask must include \(type)")
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp] {
            XCTAssertEqual(mask & (CGEventMask(1) << type.rawValue), 0, "keyboard mask must not include \(type)")
        }
    }

    func testMouseObserverMaskCoversOnlyMouseDowns() {
        let mask = GlobalHotkeyManager.mouseObserverEventMask()
        for type in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            XCTAssertNotEqual(mask & (CGEventMask(1) << type.rawValue), 0, "observer mask must include \(type)")
        }
        for type in [CGEventType.leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown, .keyUp, .flagsChanged] {
            XCTAssertEqual(mask & (CGEventMask(1) << type.rawValue), 0, "observer mask must not include \(type)")
        }
    }

    func testMouseShortcutMaskMatchesConfiguredButtons() {
        XCTAssertEqual(GlobalHotkeyManager.mouseShortcutEventMask(mouseButtons: []), 0)

        let leftOnly = GlobalHotkeyManager.mouseShortcutEventMask(mouseButtons: [0])
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            XCTAssertNotEqual(leftOnly & (CGEventMask(1) << type.rawValue), 0)
        }
        for type in [CGEventType.rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .keyDown, .flagsChanged] {
            XCTAssertEqual(leftOnly & (CGEventMask(1) << type.rawValue), 0, "left-only mask must not include \(type)")
        }

        let sideButton = GlobalHotkeyManager.mouseShortcutEventMask(mouseButtons: [3])
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            XCTAssertNotEqual(sideButton & (CGEventMask(1) << type.rawValue), 0)
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp] {
            XCTAssertEqual(sideButton & (CGEventMask(1) << type.rawValue), 0, "side-button mask must not include \(type)")
        }
    }

    func testModifierOnlyShortcutIgnoresTapAfterMouseClick() {
        let replay = ModifierOnlyFlagsReplay(
            shortcut: HotkeyShortcut(keyCode: 58, modifierFlags: .option, modifierKeyCodes: [58])
        )

        replay.flagsChanged(keyCode: 58, modifiers: .option, nextPressed: [58])
        XCTAssertEqual(replay.activeModifierOnlyType, .transcription)

        replay.mouseDown()
        replay.flagsChanged(keyCode: 58, modifiers: [], nextPressed: [])

        XCTAssertEqual(replay.cleanFinishCount, 0, "Option+click must not read as an Option tap")
        XCTAssertNil(replay.activeModifierOnlyType)
    }

    func testMicrophoneChangeAlertsSupportProductionAndDebugAppsOnly() {
        XCTAssertTrue(MicrophoneChangeOverlayController.supportsAlerts(bundleIdentifier: "com.FluidApp.app"))
        XCTAssertTrue(MicrophoneChangeOverlayController.supportsAlerts(bundleIdentifier: "com.FluidApp.app.debug"))
        XCTAssertFalse(MicrophoneChangeOverlayController.supportsAlerts(bundleIdentifier: "com.example.tests"))
        XCTAssertFalse(MicrophoneChangeOverlayController.supportsAlerts(bundleIdentifier: nil))
    }

    func testInterruptedMousePressForceStopsHoldAndAutomaticModes() {
        XCTAssertTrue(GlobalHotkeyManager.shouldForceStopInterruptedPrimaryPress(activationMode: .hold))
        XCTAssertTrue(GlobalHotkeyManager.shouldForceStopInterruptedPrimaryPress(activationMode: .automatic))
        XCTAssertFalse(GlobalHotkeyManager.shouldForceStopInterruptedPrimaryPress(activationMode: .toggle))
    }

    func testHotkeySessionLockDetection() {
        XCTAssertTrue(GlobalHotkeyManager.sessionIsLocked(sessionInfo: ["CGSSessionScreenIsLocked": true]))
        XCTAssertFalse(GlobalHotkeyManager.sessionIsLocked(sessionInfo: ["CGSSessionScreenIsLocked": false]))
        XCTAssertFalse(GlobalHotkeyManager.sessionIsLocked(sessionInfo: [:]))
    }

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
    func testIncrementalParakeetDefaultsOnAndRoundTripsWithoutBreakingLegacyBackups() async throws {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: self.incrementalParakeetEnabledKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: self.incrementalParakeetEnabledKey)
            } else {
                defaults.removeObject(forKey: self.incrementalParakeetEnabledKey)
            }
        }

        defaults.removeObject(forKey: self.incrementalParakeetEnabledKey)
        XCTAssertTrue(SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled)

        SettingsStore.shared.experimentalParakeetUnifiedFinalEnabled = false
        let document = await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.experimentalParakeetUnifiedFinalEnabled, false)

        let encoded = try BackupService.shared.encode(document)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var settings = try XCTUnwrap(root["settings"] as? [String: Any])
        settings.removeValue(forKey: "experimentalParakeetUnifiedFinalEnabled")
        root["settings"] = settings

        let legacyBackup = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(legacyBackup.settings.experimentalParakeetUnifiedFinalEnabled)
    }

    @MainActor
    func testHistoryPerformanceDefaultsOffAndRoundTripsWithoutBreakingLegacyBackups() async throws {
        let defaults = UserDefaults.standard
        let key = "ShowHistoryPerformanceMetrics"
        let originalValue = defaults.object(forKey: key)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        XCTAssertFalse(SettingsStore.shared.showHistoryPerformanceMetrics)

        SettingsStore.shared.showHistoryPerformanceMetrics = true
        let document = await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.showHistoryPerformanceMetrics, true)

        let encoded = try BackupService.shared.encode(document)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var settings = try XCTUnwrap(root["settings"] as? [String: Any])
        settings.removeValue(forKey: "showHistoryPerformanceMetrics")
        root["settings"] = settings

        let legacyBackup = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(legacyBackup.settings.showHistoryPerformanceMetrics)
    }

    @MainActor
    func testIncrementalParakeetCopiesOnlyTheUnacceptedTailAfterSessionStarts() {
        XCTAssertEqual(
            FluidAudioProvider.incrementalPreviewDeltaRange(
                enabled: true,
                hasSession: true,
                acceptedSampleCount: 320_000,
                totalSampleCount: 330_000
            ),
            320_000..<330_000
        )
        XCTAssertNil(
            FluidAudioProvider.incrementalPreviewDeltaRange(
                enabled: false,
                hasSession: true,
                acceptedSampleCount: 320_000,
                totalSampleCount: 330_000
            )
        )
        XCTAssertNil(
            FluidAudioProvider.incrementalPreviewDeltaRange(
                enabled: true,
                hasSession: false,
                acceptedSampleCount: 320_000,
                totalSampleCount: 330_000
            )
        )
        XCTAssertNil(
            FluidAudioProvider.incrementalPreviewDeltaRange(
                enabled: true,
                hasSession: true,
                acceptedSampleCount: 240_000,
                totalSampleCount: 250_000
            )
        )
    }

    @MainActor
    func testLegacySystemModeBackupQueuesMicrophonePriorityMigration() async throws {
        let document = await BackupService.shared.makeBackupDocument()

        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            SettingsStore.shared.microphoneSelectionMigrationVersion = 4
            let encoded = try BackupService.shared.encode(document)
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var settings = try XCTUnwrap(root["settings"] as? [String: Any])
            settings["microphoneSelectionMode"] = SettingsStore.MicrophoneSelectionMode.system.rawValue
            settings["preferredInputDeviceUID"] = "legacy-system-mic"
            settings.removeValue(forKey: "microphonePriority")
            root["settings"] = settings
            let backup = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))

            SettingsStore.shared.restore(from: backup.settings)

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "legacy-system-mic")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .system)
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 0)
        }
    }

    @MainActor
    func testPriorityBackupKeepsCompletedMicrophoneMigration() async {
        let document = await BackupService.shared.makeBackupDocument()

        self.withRestoredDefaults(keys: [self.microphoneSelectionMigrationVersionKey]) {
            SettingsStore.shared.microphoneSelectionMigrationVersion = 4

            SettingsStore.shared.restore(from: document.settings)

            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
        }
    }

    @MainActor
    func testPriorityBackupRoundTripsRemovedConnectedMicrophones() async {
        let originalPriority = SettingsStore.shared.microphonePriority
        let originalSuppressedUIDs = SettingsStore.shared.suppressedMicrophoneUIDs
        defer {
            SettingsStore.shared.microphonePriority = originalPriority
            SettingsStore.shared.suppressedMicrophoneUIDs = originalSuppressedUIDs
        }

        SettingsStore.shared.microphonePriority = [
            .init(uid: "kept-mic", name: "Kept Microphone"),
        ]
        SettingsStore.shared.suppressedMicrophoneUIDs = ["removed-connected-mic"]
        let document = await BackupService.shared.makeBackupDocument()

        XCTAssertEqual(document.settings.suppressedMicrophoneUIDs, ["removed-connected-mic"])
        SettingsStore.shared.suppressedMicrophoneUIDs = []
        SettingsStore.shared.restore(from: document.settings)
        XCTAssertEqual(SettingsStore.shared.suppressedMicrophoneUIDs, ["removed-connected-mic"])
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

    func testDirectRecoveryTracksPriorityInputAvailability() {
        let previousUIDs = Set(["preferred", "built-in"])

        XCTAssertFalse(AudioCaptureIdlePolicy.didResolvedPriorityInputChange(
            priorityInputUIDs: ["preferred"],
            previousInputUIDs: previousUIDs,
            currentInputUIDs: previousUIDs.union(["unrelated"])
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.didResolvedPriorityInputChange(
            priorityInputUIDs: ["preferred"],
            previousInputUIDs: previousUIDs,
            currentInputUIDs: ["built-in"]
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.didResolvedPriorityInputChange(
            priorityInputUIDs: ["preferred"],
            previousInputUIDs: ["built-in"],
            currentInputUIDs: previousUIDs
        ))
        XCTAssertFalse(AudioCaptureIdlePolicy.didResolvedPriorityInputChange(
            priorityInputUIDs: ["preferred", "built-in", "lower-priority"],
            previousInputUIDs: previousUIDs,
            currentInputUIDs: previousUIDs.union(["lower-priority"])
        ))
    }

    func testPendingMicrophoneMigrationRetriesWhenDevicesAppear() {
        XCTAssertFalse(AudioCaptureIdlePolicy.shouldReconcileInputSelection(
            priorityInputUIDs: ["disconnected-usb"],
            migrationPending: true,
            previousInputUIDs: [],
            currentInputUIDs: []
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldReconcileInputSelection(
            priorityInputUIDs: ["disconnected-usb"],
            migrationPending: true,
            previousInputUIDs: [],
            currentInputUIDs: ["built-in"]
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldReconcileInputSelection(
            priorityInputUIDs: [],
            migrationPending: false,
            previousInputUIDs: [],
            currentInputUIDs: ["built-in"]
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldReconcileInputSelection(
            priorityInputUIDs: ["preferred", "fallback"],
            migrationPending: false,
            previousInputUIDs: ["fallback"],
            currentInputUIDs: []
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldReconcileInputSelection(
            priorityInputUIDs: ["unavailable", "new", "fallback"],
            migrationPending: false,
            previousInputUIDs: ["fallback"],
            currentInputUIDs: ["new", "fallback"]
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

    /// Regression for #688: a single-modifier dictation hotkey (Left Option) must not falsely
    /// start recording when an unrelated Shift+key combo is typed while the configured modifier
    /// is held. The release of the extra Shift used to re-enter the modifier-only start block and
    /// erase the "another key was pressed" flag, so the subsequent Option release read as a clean
    /// tap and started recording.
    func testModifierOnlyShortcutDoesNotFireOnUnrelatedShiftKeyCombo() {
        let replay = ModifierOnlyFlagsReplay(
            shortcut: HotkeyShortcut(keyCode: 58, modifierFlags: .option, modifierKeyCodes: [58])
        )

        // Genuine Left-Option press arms the modifier-only press (toggle: no recording yet).
        replay.flagsChanged(keyCode: 58, modifiers: .option, nextPressed: [58])
        XCTAssertEqual(replay.activeModifierOnlyType, .transcription)
        XCTAssertEqual(replay.cleanFinishCount, 0)

        // Shift held during the Option press records an interruption.
        replay.flagsChanged(keyCode: 56, modifiers: [.option, .shift], nextPressed: [56, 58])
        XCTAssertTrue(replay.otherKeyPressedDuringModifier)

        // An unrelated key (Return) is typed while the Option press is active.
        replay.keyDown()
        XCTAssertTrue(replay.otherKeyPressedDuringModifier)

        // The unrelated Shift is released while Option is still held. This must NOT re-arm the
        // press or erase the recorded interruption.
        replay.flagsChanged(keyCode: 56, modifiers: .option, nextPressed: [58])

        // The configured Option is released; the press must be treated as interrupted (not a clean
        // tap), so recording is NOT started.
        replay.flagsChanged(keyCode: 58, modifiers: [], nextPressed: [])

        XCTAssertEqual(
            replay.cleanFinishCount,
            0,
            "An unrelated Shift+key combo must not falsely start recording for a Left-Option modifier-only hotkey"
        )
        XCTAssertNil(replay.activeModifierOnlyType)
    }

    /// Companion guard: a genuine clean Left-Option tap must still start recording after the fix.
    func testModifierOnlyShortcutFiresOnGenuineModifierTap() {
        let replay = ModifierOnlyFlagsReplay(
            shortcut: HotkeyShortcut(keyCode: 58, modifierFlags: .option, modifierKeyCodes: [58])
        )

        replay.flagsChanged(keyCode: 58, modifiers: .option, nextPressed: [58])
        XCTAssertEqual(replay.activeModifierOnlyType, .transcription)

        replay.flagsChanged(keyCode: 58, modifiers: [], nextPressed: [])

        XCTAssertEqual(replay.cleanFinishCount, 1, "A genuine clean Left-Option tap must still start recording")
        XCTAssertNil(replay.activeModifierOnlyType)
    }

    /// From idle (no configured modifier pressed), a bare Shift+Enter must never arm the
    /// modifier-only hotkey, so `activeModifierOnlyType` stays nil.
    func testModifierOnlyShortcutIgnoresShiftComboFromIdle() {
        let replay = ModifierOnlyFlagsReplay(
            shortcut: HotkeyShortcut(keyCode: 58, modifierFlags: .option, modifierKeyCodes: [58])
        )

        replay.flagsChanged(keyCode: 56, modifiers: .shift, nextPressed: [56])
        replay.keyDown()

        XCTAssertNil(replay.activeModifierOnlyType, "Shift+Enter from idle must not arm a Left-Option modifier-only hotkey")
        XCTAssertEqual(replay.cleanFinishCount, 0)
    }

    /// Branch-2 (flag-only) modifier-only shortcut coverage. The original start matched on modifier
    /// flags (side-agnostic), so a Left-Option-stored shortcut must still arm on the sibling Right
    /// Option, and the #688 re-arm on releasing an extra Shift must stay blocked.
    func testBranch2ModifierOnlyShortcutArmsOnSiblingAndIgnoresShiftCombo() {
        // Flag-only form: keyCode 58 with an .option flag and no modifierKeyCodes -> branch 2.
        let shortcut = HotkeyShortcut(keyCode: 58, modifierFlags: .option)
        XCTAssertTrue(shortcut.normalizedModifierKeyCodes.isEmpty, "precondition: flag-only shortcut takes branch 2")

        // Sibling side: Right Option (keyCode 61, same .option flag) arms the press.
        let siblingReplay = ModifierOnlyFlagsReplay(shortcut: shortcut)
        siblingReplay.flagsChanged(keyCode: 61, modifiers: .option, nextPressed: [61])
        XCTAssertEqual(
            siblingReplay.activeModifierOnlyType,
            .transcription,
            "Branch-2 Left-Option shortcut must arm on the sibling Right Option (side-agnostic flags)"
        )

        // #688 analog for branch 2: releasing an extra Shift while Option is held must not re-arm.
        let comboReplay = ModifierOnlyFlagsReplay(shortcut: shortcut)
        comboReplay.flagsChanged(keyCode: 58, modifiers: .option, nextPressed: [58])
        comboReplay.flagsChanged(keyCode: 56, modifiers: [.option, .shift], nextPressed: [56, 58])
        comboReplay.keyDown()
        comboReplay.flagsChanged(keyCode: 56, modifiers: .option, nextPressed: [58])
        comboReplay.flagsChanged(keyCode: 58, modifiers: [], nextPressed: [])

        XCTAssertEqual(comboReplay.cleanFinishCount, 0, "Branch-2 shortcut must not falsely start on an unrelated Shift+key combo")
    }

    /// Regression for the sibling-side re-arm: while a modifier-only press is active, pressing the
    /// sibling modifier of the same family (Right Option while Left Option is armed) must NOT
    /// re-enter `.start` and erase the "another key was pressed" flag. Without the active-press
    /// guard the sibling's flag is in the expected set so `.start` fires again, the interrupt flag
    /// is wiped, and the configured modifier's later release reads as a clean tap (#688 class).
    func testBranch2ModifierOnlyShortcutSiblingPressDoesNotEraseInterrupt() {
        // Branch-2 (flag-only) Left-Option shortcut.
        let replay = ModifierOnlyFlagsReplay(shortcut: HotkeyShortcut(keyCode: 58, modifierFlags: .option))
        XCTAssertTrue(replay.shortcut.normalizedModifierKeyCodes.isEmpty, "precondition: flag-only shortcut takes branch 2")

        // Arm with Left Option, type a key, then press the sibling Right Option mid-press.
        replay.flagsChanged(keyCode: 58, modifiers: .option, nextPressed: [58])
        XCTAssertEqual(replay.activeModifierOnlyType, .transcription)
        replay.keyDown()
        XCTAssertTrue(replay.otherKeyPressedDuringModifier)
        replay.flagsChanged(keyCode: 61, modifiers: .option, nextPressed: [58, 61])

        // The sibling press must not re-arm the press or erase the recorded interrupt.
        XCTAssertTrue(
            replay.otherKeyPressedDuringModifier,
            "Sibling-side modifier press must not erase the recorded interrupt flag"
        )
        XCTAssertEqual(replay.activeModifierOnlyType, .transcription)

        // Release the sibling, then release the configured Left Option last.
        replay.flagsChanged(keyCode: 61, modifiers: .option, nextPressed: [58])
        replay.flagsChanged(keyCode: 58, modifiers: [], nextPressed: [])

        XCTAssertEqual(
            replay.cleanFinishCount,
            0,
            "Sibling press during an active press must not lead to a false clean-tap start"
        )
    }

    func testReleasingSecondPrimaryModifierDoesNotFinishActiveShortcut() {
        let leftOption = HotkeyShortcut(keyCode: 58, modifierFlags: .option, modifierKeyCodes: [58])
        let rightOption = HotkeyShortcut(keyCode: 61, modifierFlags: .option, modifierKeyCodes: [61])

        let decision = ModifierOnlyShortcutFlagsDecision.evaluate(
            shortcut: rightOption,
            holdModeType: .transcription,
            isEnabled: true,
            keyCode: 61,
            modifiers: .option,
            state: ModifierOnlyShortcutTrackingState(
                pressedModifierKeyCodes: [58],
                activeModifierOnlyType: .transcription,
                activeModifierOnlyShortcut: leftOption,
                otherKeyPressedDuringModifier: true,
                isModeKeyPressed: true
            )
        )

        XCTAssertEqual(decision.outcome, .ignore)
        XCTAssertEqual(decision.activeModifierOnlyType, .transcription)
        XCTAssertEqual(decision.activeModifierOnlyShortcut, leftOption)
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

    func testLegacySystemModeRemainsReadableForPriorityMigration() throws {
        try self.withRestoredDefaults(keys: [self.microphoneSelectionModeKey]) {
            UserDefaults.standard.set(
                SettingsStore.MicrophoneSelectionMode.system.rawValue,
                forKey: self.microphoneSelectionModeKey
            )

            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .system)
        }
    }

    func testInputSelectionPersistsAppPreference() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
        ]) {
            SettingsStore.shared.recordInputDeviceSelection("studio-mic")

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "studio-mic")
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), ["studio-mic"])
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .manual)
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
        XCTAssertTrue(builtInDevice.isUnavailableWhenClamshellClosed)
        XCTAssertFalse(builtInDevice.isBluetooth)

        let analogHeadset = Self.device(
            uid: "analog-headset",
            name: "External Microphone",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            inputDataSourceID: AudioDevice.Device.externalMicrophoneDataSourceID
        )
        XCTAssertTrue(analogHeadset.isBuiltIn)
        XCTAssertFalse(analogHeadset.isUnavailableWhenClamshellClosed)
    }

    func testBluetoothStartupAdmitsSameInputRetriesWithinFiveSecondWindow() {
        var stabilization = AudioCaptureIdlePolicy.BluetoothInputStabilization()

        XCTAssertTrue(stabilization.shouldRetry(
            inputUID: "airpods",
            isBluetoothInput: true,
            now: 10
        ))
        XCTAssertTrue(stabilization.shouldRetry(
            inputUID: "airpods",
            isBluetoothInput: false,
            now: 14.999
        ))
        XCTAssertFalse(stabilization.shouldRetry(
            inputUID: "airpods",
            isBluetoothInput: false,
            now: 15
        ))
    }

    func testCaptureAttemptRetainsBluetoothIdentityWhenForcedDeviceDisappears() {
        let airPods = Self.device(
            uid: "airpods",
            name: "AirPods Microphone",
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        let selectedIdentity = AudioCaptureIdlePolicy.CaptureAttemptIdentity.resolve(
            selectedInput: airPods,
            forcingInputUID: nil,
            previous: nil
        )
        let retryIdentity = AudioCaptureIdlePolicy.CaptureAttemptIdentity.resolve(
            selectedInput: nil,
            forcingInputUID: "airpods",
            previous: selectedIdentity
        )

        XCTAssertEqual(retryIdentity, selectedIdentity)
        XCTAssertTrue(retryIdentity?.isBluetooth == true)
    }

    func testCaptureAttemptDoesNotTransferBluetoothIdentityToDifferentDevice() {
        let previous = AudioCaptureIdlePolicy.CaptureAttemptIdentity(
            uid: "airpods",
            name: "AirPods Microphone",
            isBluetooth: true,
            isInternalMicrophone: false
        )

        let replacement = AudioCaptureIdlePolicy.CaptureAttemptIdentity.resolve(
            selectedInput: nil,
            forcingInputUID: "usb-mic",
            previous: previous
        )

        XCTAssertEqual(replacement?.uid, "usb-mic")
        XCTAssertFalse(replacement?.isBluetooth == true)
    }

    func testCaptureAttemptSeedsPreferredBluetoothIdentityBeforeInputAppears() {
        let airPodsOutputProfile = AudioDevice.Device(
            id: 42,
            uid: "airpods",
            name: "AirPods",
            hasInput: false,
            hasOutput: true,
            transportType: kAudioDeviceTransportTypeBluetooth
        )

        let candidate = AudioCaptureIdlePolicy.bluetoothInputAwaitingAvailability(
            priorityInputUIDs: ["airpods", "built-in"],
            preferredInputUID: "airpods",
            resolvedInputUID: "built-in",
            allDevices: [airPodsOutputProfile],
            excluding: []
        )

        XCTAssertEqual(candidate?.uid, "airpods")
        XCTAssertTrue(candidate?.isBluetooth == true)
    }

    func testCaptureAttemptDoesNotWaitForLowerPriorityBluetoothInput() {
        let builtIn = Self.device(
            uid: "built-in",
            name: "MacBook Pro Microphone",
            transportType: kAudioDeviceTransportTypeBuiltIn
        )
        let airPodsOutputProfile = AudioDevice.Device(
            id: 42,
            uid: "airpods",
            name: "AirPods",
            hasInput: false,
            hasOutput: true,
            transportType: kAudioDeviceTransportTypeBluetooth
        )

        let candidate = AudioCaptureIdlePolicy.bluetoothInputAwaitingAvailability(
            priorityInputUIDs: ["built-in", "airpods"],
            preferredInputUID: "built-in",
            resolvedInputUID: "built-in",
            allDevices: [builtIn, airPodsOutputProfile],
            excluding: []
        )

        XCTAssertNil(candidate)
    }

    func testCaptureAttemptSkipsDisconnectedPriorityBeforeSettlingBluetoothInput() {
        let airPodsOutputProfile = AudioDevice.Device(
            id: 42,
            uid: "airpods",
            name: "AirPods",
            hasInput: false,
            hasOutput: true,
            transportType: kAudioDeviceTransportTypeBluetooth
        )

        let candidate = AudioCaptureIdlePolicy.bluetoothInputAwaitingAvailability(
            priorityInputUIDs: ["disconnected-usb", "airpods", "built-in"],
            preferredInputUID: "disconnected-usb",
            resolvedInputUID: "built-in",
            allDevices: [airPodsOutputProfile],
            excluding: []
        )

        XCTAssertEqual(candidate?.uid, "airpods")
    }

    func testBluetoothStartupPolicyDoesNotAffectOtherInputsOrActiveRecovery() {
        var stabilization = AudioCaptureIdlePolicy.BluetoothInputStabilization()

        XCTAssertFalse(stabilization.shouldRetry(
            inputUID: "usb",
            isBluetoothInput: false,
            now: 10
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldDeferRouteRecoveryToBluetoothStart(
            directCaptureEnabled: true,
            isStarting: true,
            isRunning: false,
            attemptedInputIsBluetooth: true
        ))
        XCTAssertFalse(AudioCaptureIdlePolicy.shouldDeferRouteRecoveryToBluetoothStart(
            directCaptureEnabled: true,
            isStarting: true,
            isRunning: true,
            attemptedInputIsBluetooth: true
        ))
        XCTAssertFalse(AudioCaptureIdlePolicy.shouldDeferRouteRecoveryToBluetoothStart(
            directCaptureEnabled: true,
            isStarting: true,
            isRunning: false,
            attemptedInputIsBluetooth: false
        ))

        XCTAssertEqual(
            AudioCaptureIdlePolicy.bluetoothStartupRouteChangeDisposition(
                invalidatesCurrentStart: true,
                requiresIdlePrewarm: true,
                reconcilesInputSelection: false
            ),
            .retryCurrentStart
        )
        XCTAssertEqual(
            AudioCaptureIdlePolicy.bluetoothStartupRouteChangeDisposition(
                invalidatesCurrentStart: false,
                requiresIdlePrewarm: true,
                reconcilesInputSelection: true
            ),
            .preserveDeferredWork
        )
        XCTAssertEqual(
            AudioCaptureIdlePolicy.bluetoothStartupRouteChangeDisposition(
                invalidatesCurrentStart: false,
                requiresIdlePrewarm: false,
                reconcilesInputSelection: false
            ),
            .ignore
        )
    }

    func testBluetoothStartupPreservesOnlyExplicitReconciliationWork() {
        var deferredRecovery = AudioCaptureIdlePolicy.DeferredBluetoothRouteRecovery()

        deferredRecovery.preserve(
            reason: "ordinary route churn",
            requiresIdlePrewarm: false,
            reconcilesInputSelection: false
        )
        XCTAssertNil(deferredRecovery.take())

        deferredRecovery.preserve(
            reason: "settings backup restored",
            requiresIdlePrewarm: true,
            reconcilesInputSelection: false
        )
        deferredRecovery.preserve(
            reason: "input topology changed",
            requiresIdlePrewarm: false,
            reconcilesInputSelection: true
        )
        let request = deferredRecovery.take()
        XCTAssertEqual(request?.reason, "settings backup restored")
        XCTAssertEqual(request?.requiresIdlePrewarm, true)
        XCTAssertEqual(request?.reconcilesInputSelection, true)
        XCTAssertNil(deferredRecovery.take())
    }

    func testDeferredBluetoothReconciliationLeavesMatchingActiveInputUntouched() {
        XCTAssertFalse(AudioCaptureIdlePolicy.shouldRecoverAfterDeferredBluetoothReconciliation(
            isRunning: true,
            confirmedInputUID: "airpods",
            activeDeviceID: 42,
            resolvedInputUID: "airpods",
            resolvedDeviceID: 42,
            hasPreparedCapture: true,
            requiresIdlePrewarm: true
        ))
    }

    func testDeferredBluetoothReconciliationRecoversChangedSelectionOrIdentity() {
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldRecoverAfterDeferredBluetoothReconciliation(
            isRunning: true,
            confirmedInputUID: "airpods",
            activeDeviceID: 42,
            resolvedInputUID: "usb",
            resolvedDeviceID: 88,
            hasPreparedCapture: true,
            requiresIdlePrewarm: true
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldRecoverAfterDeferredBluetoothReconciliation(
            isRunning: true,
            confirmedInputUID: "airpods",
            activeDeviceID: 42,
            resolvedInputUID: "airpods",
            resolvedDeviceID: 43,
            hasPreparedCapture: true,
            requiresIdlePrewarm: true
        ))
    }

    func testDeferredBluetoothReconciliationPreservesIdlePrewarmIntent() {
        XCTAssertFalse(AudioCaptureIdlePolicy.shouldRecoverAfterDeferredBluetoothReconciliation(
            isRunning: false,
            confirmedInputUID: nil,
            activeDeviceID: 42,
            resolvedInputUID: "airpods",
            resolvedDeviceID: 42,
            hasPreparedCapture: true,
            requiresIdlePrewarm: true
        ))
        XCTAssertTrue(AudioCaptureIdlePolicy.shouldRecoverAfterDeferredBluetoothReconciliation(
            isRunning: false,
            confirmedInputUID: nil,
            activeDeviceID: nil,
            resolvedInputUID: "airpods",
            resolvedDeviceID: 42,
            hasPreparedCapture: false,
            requiresIdlePrewarm: true
        ))
    }

    func testSilentPCMWatchdogRecoversInternalDirectCaptureOnceAfterRealSignal() {
        var watchdog = AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog()

        XCTAssertFalse(watchdog.shouldRecover(
            isInternalMicrophone: true, isDirectCapture: true, rms: 0, peak: 0
        ))
        XCTAssertFalse(watchdog.shouldRecover(
            isInternalMicrophone: true, isDirectCapture: true, rms: 0.02, peak: 0.08
        ))
        for _ in 0..<(AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog.requiredSilentWindows - 1) {
            XCTAssertFalse(watchdog.shouldRecover(
                isInternalMicrophone: true, isDirectCapture: true, rms: 0, peak: 0
            ))
        }
        XCTAssertTrue(watchdog.shouldRecover(
            isInternalMicrophone: true, isDirectCapture: true, rms: 0, peak: 0
        ))
        XCTAssertFalse(watchdog.shouldRecover(
            isInternalMicrophone: true, isDirectCapture: true, rms: 0, peak: 0
        ))
    }

    func testSilentPCMWatchdogIgnoresExternalAndLowAmbientInputs() {
        var externalWatchdog = AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog()
        XCTAssertFalse(externalWatchdog.shouldRecover(
            isInternalMicrophone: false, isDirectCapture: true, rms: 0.02, peak: 0.08
        ))
        for _ in 0...AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog.requiredSilentWindows {
            XCTAssertFalse(externalWatchdog.shouldRecover(
                isInternalMicrophone: false, isDirectCapture: true, rms: 0, peak: 0
            ))
        }

        var legacyCaptureWatchdog = AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog()
        XCTAssertFalse(legacyCaptureWatchdog.shouldRecover(
            isInternalMicrophone: true, isDirectCapture: false, rms: 0.02, peak: 0.08
        ))
        for _ in 0...AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog.requiredSilentWindows {
            XCTAssertFalse(legacyCaptureWatchdog.shouldRecover(
                isInternalMicrophone: true, isDirectCapture: false, rms: 0, peak: 0
            ))
        }

        var ambientWatchdog = AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog()
        XCTAssertFalse(ambientWatchdog.shouldRecover(
            isInternalMicrophone: true, isDirectCapture: true, rms: 0.02, peak: 0.08
        ))
        for _ in 0...AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog.requiredSilentWindows {
            XCTAssertFalse(ambientWatchdog.shouldRecover(
                isInternalMicrophone: true, isDirectCapture: true, rms: 0.0001, peak: 0.001
            ))
        }
    }

    @MainActor
    func testLegacySystemModeSeedsPriorityFromCurrentDefault() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            UserDefaults.standard.set(
                SettingsStore.MicrophoneSelectionMode.system.rawValue,
                forKey: self.microphoneSelectionModeKey
            )
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            SettingsStore.shared.microphoneSelectionMigrationVersion = 0
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

            coordinator.migrateMicrophonePriorityIfNeeded()

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "airpods")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .manual)
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
            XCTAssertEqual(
                UserDefaults.standard.string(forKey: self.microphoneSelectionModeKey),
                SettingsStore.MicrophoneSelectionMode.manual.rawValue
            )
            XCTAssertEqual(devices.defaultInputUID, "airpods")

            SettingsStore.shared.recordInputDeviceSelection("internal")
            coordinator.migrateMicrophonePriorityIfNeeded()
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "internal")
        }
    }

    @MainActor
    func testLegacyStoredMicrophoneWithoutModeKeyKeepsUserSelection() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            UserDefaults.standard.removeObject(forKey: self.microphoneSelectionModeKey)
            SettingsStore.shared.preferredInputDeviceUID = "studio-mic"
            SettingsStore.shared.microphoneSelectionMigrationVersion = 0
            let devices = FakeAudioDeviceManager(
                inputs: [
                    Self.device(uid: "internal", name: "MacBook Pro Microphone"),
                    Self.device(uid: "studio-mic", name: "Studio Mic"),
                ],
                defaultInputUID: "internal"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            coordinator.migrateMicrophonePriorityIfNeeded()

            XCTAssertEqual(SettingsStore.shared.microphonePriority.first?.uid, "studio-mic")
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "studio-mic")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .manual)
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
        }
    }

    @MainActor
    func testFreshInstallKeepsPriorityUsableWhileWaitingForMacOSDefault() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            UserDefaults.standard.removeObject(forKey: self.microphoneSelectionModeKey)
            SettingsStore.shared.preferredInputDeviceUID = nil
            SettingsStore.shared.microphoneSelectionMigrationVersion = 0
            let fallback = Self.device(uid: "fallback", name: "Available Fallback")
            let unsettledDevices = FakeAudioDeviceManager(
                inputs: [fallback],
                defaultInputUID: "system-default"
            )
            let unsettledCoordinator = MicrophonePreferenceCoordinator(
                settings: .shared,
                devices: unsettledDevices
            )

            let temporarySelection = unsettledCoordinator.reconcileMicrophoneSelection(
                availableInputs: unsettledDevices.inputs,
                defaultInputUID: unsettledDevices.defaultInputUID
            )

            XCTAssertEqual(temporarySelection, fallback)
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [fallback.uid])
            XCTAssertNil(SettingsStore.shared.preferredInputDeviceUID)
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 0)

            let systemDefault = Self.device(uid: "system-default", name: "macOS Default")
            let settledDevices = FakeAudioDeviceManager(
                inputs: [fallback, systemDefault],
                defaultInputUID: systemDefault.uid
            )
            let settledCoordinator = MicrophonePreferenceCoordinator(
                settings: .shared,
                devices: settledDevices
            )

            settledCoordinator.migrateMicrophonePriorityIfNeeded()

            XCTAssertEqual(SettingsStore.shared.microphonePriority.first?.uid, systemDefault.uid)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, systemDefault.uid)
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
        }
    }

    @MainActor
    func testFreshInstallPrioritizesMacOSDefaultWhileTemporarilyUnusable() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            UserDefaults.standard.set(
                SettingsStore.MicrophoneSelectionMode.system.rawValue,
                forKey: self.microphoneSelectionModeKey
            )
            SettingsStore.shared.preferredInputDeviceUID = nil
            SettingsStore.shared.microphoneSelectionMigrationVersion = 0
            let systemDefault = Self.device(uid: "system-default", name: "macOS Default")
            let fallback = Self.device(uid: "fallback", name: "Available Fallback")
            let devices = FakeAudioDeviceManager(
                inputs: [fallback, systemDefault],
                defaultInputUID: systemDefault.uid,
                unusableInputUIDs: [systemDefault.uid]
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let resolved = coordinator.reconcileMicrophoneSelection(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID
            )

            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [systemDefault.uid, fallback.uid])
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, systemDefault.uid)
            XCTAssertEqual(resolved, fallback)
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
        }
    }

    @MainActor
    func testMicrophoneMigrationWaitsForAUsableDeviceList() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            UserDefaults.standard.set(
                SettingsStore.MicrophoneSelectionMode.system.rawValue,
                forKey: self.microphoneSelectionModeKey
            )
            SettingsStore.shared.preferredInputDeviceUID = "airpods"
            SettingsStore.shared.microphoneSelectionMigrationVersion = 0
            let devices = FakeAudioDeviceManager(inputs: [], defaultInputUID: nil)
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            coordinator.migrateMicrophonePriorityIfNeeded()

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "airpods")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 0)
        }
    }

    @MainActor
    func testManualMicrophoneMigrationPreservesAvailableSelection() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            UserDefaults.standard.set(
                SettingsStore.MicrophoneSelectionMode.manual.rawValue,
                forKey: self.microphoneSelectionModeKey
            )
            SettingsStore.shared.preferredInputDeviceUID = "studio-mic"
            SettingsStore.shared.microphoneSelectionMigrationVersion = 0
            let devices = FakeAudioDeviceManager(
                inputs: [
                    Self.device(uid: "display-mic", name: "Display Mic"),
                    Self.device(uid: "studio-mic", name: "Studio Mic"),
                ],
                defaultInputUID: "display-mic"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            coordinator.migrateMicrophonePriorityIfNeeded()

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "studio-mic")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
            XCTAssertEqual(devices.defaultInputUID, "display-mic")
        }
    }

    @MainActor
    func testMicrophoneMigrationWithoutBuiltInReplacesMissingSelectionWithDefault() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            UserDefaults.standard.set(
                SettingsStore.MicrophoneSelectionMode.system.rawValue,
                forKey: self.microphoneSelectionModeKey
            )
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            SettingsStore.shared.microphoneSelectionMigrationVersion = 0
            let devices = FakeAudioDeviceManager(
                inputs: [
                    Self.device(uid: "display-mic", name: "Display Mic"),
                    Self.device(uid: "studio-mic", name: "Studio Mic"),
                ],
                defaultInputUID: "studio-mic"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            coordinator.migrateMicrophonePriorityIfNeeded()

            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "studio-mic")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
            XCTAssertEqual(devices.defaultInputUID, "studio-mic")
        }
    }

    @MainActor
    func testVersionOneMigrationRepairsForcedBuiltInSelection() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            SettingsStore.shared.microphoneSelectionMigrationVersion = 1
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

            let reconciled = coordinator.reconcileMicrophoneSelection(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID
            )

            XCTAssertEqual(reconciled?.uid, "usb")
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "usb")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
            XCTAssertEqual(devices.defaultInputUID, "usb")
        }
    }

    @MainActor
    func testVersionOneMigrationRepairsUnavailableBuiltInForClamshellUser() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "internal"
            SettingsStore.shared.microphoneSelectionMigrationVersion = 1
            let webcam = Self.device(uid: "webcam", name: "Webcam Microphone")
            let devices = FakeAudioDeviceManager(
                inputs: [webcam],
                defaultInputUID: webcam.uid
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let reconciled = coordinator.reconcileMicrophoneSelection(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID
            )

            XCTAssertEqual(reconciled, webcam)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "webcam")
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
        }
    }

    @MainActor
    func testVersionOneMigrationPreservesDisconnectedExternalSelection() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "disconnected-studio-mic"
            SettingsStore.shared.microphoneSelectionMigrationVersion = 1
            let fallback = Self.device(uid: "internal", name: "MacBook Pro Microphone")
            let devices = FakeAudioDeviceManager(
                inputs: [fallback],
                defaultInputUID: fallback.uid
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let reconciled = coordinator.reconcileMicrophoneSelection(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID
            )

            XCTAssertEqual(reconciled, fallback)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "disconnected-studio-mic")
            XCTAssertEqual(
                SettingsStore.shared.microphonePriority.map(\.uid),
                ["disconnected-studio-mic", fallback.uid]
            )
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
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
    func testMicrophoneCoordinatorUsesDefaultTemporarilyAndRestoresSelection() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "airpods"
            SettingsStore.shared.microphoneSelectionMigrationVersion = 2
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

            XCTAssertEqual(previewFallback?.uid, "usb")
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "airpods")
            XCTAssertEqual(devices.defaultInputUID, "usb")

            let settledFallback = coordinator.reconcileMicrophoneSelection(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID
            )
            XCTAssertEqual(settledFallback?.uid, "usb")
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "airpods")
            XCTAssertEqual(devices.defaultInputUID, "usb")

            let airPods = Self.device(uid: "airpods", name: "AirPods")
            let afterReconnect = coordinator.reconcileMicrophoneSelection(
                availableInputs: [builtIn, airPods],
                defaultInputUID: builtIn.uid
            )
            XCTAssertEqual(afterReconnect, airPods)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "airpods")
        }
    }

    @MainActor
    func testMicrophoneCoordinatorUsesCurrentInputWhenNoBuiltInExists() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            SettingsStore.shared.preferredInputDeviceUID = "disconnected"
            SettingsStore.shared.microphoneSelectionMigrationVersion = 2
            let currentInput = Self.device(uid: "usb", name: "USB Mic")
            let devices = FakeAudioDeviceManager(
                inputs: [Self.device(uid: "other", name: "Other Mic"), currentInput],
                defaultInputUID: "usb"
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let previewFallback = coordinator.inputDeviceForCapture()

            XCTAssertEqual(previewFallback, currentInput)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "disconnected")

            let settledFallback = coordinator.reconcileMicrophoneSelection(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID
            )
            XCTAssertEqual(settledFallback, currentInput)
            XCTAssertEqual(SettingsStore.shared.preferredInputDeviceUID, "disconnected")
        }
    }

    @MainActor
    func testMicrophonePriorityWinsOverDefaultAndBuiltIn() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphonePriorityKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            let usb = Self.device(uid: "usb", name: "USB Microphone")
            SettingsStore.shared.microphonePriority = [
                .init(uid: usb.uid, name: usb.name),
                .init(uid: builtIn.uid, name: builtIn.name),
            ]
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.microphoneSelectionMigrationVersion = 4
            let devices = FakeAudioDeviceManager(
                inputs: [builtIn, usb],
                defaultInputUID: builtIn.uid
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            XCTAssertEqual(coordinator.inputDeviceForCapture(), usb)
        }
    }

    @MainActor
    func testResolvedMicrophoneIsNotMarkedActiveUntilFirstPCMConfirmation() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphonePriorityKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            let preferred = Self.device(uid: "preferred", name: "Preferred")
            SettingsStore.shared.microphonePriority = [
                .init(uid: preferred.uid, name: preferred.name),
            ]
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.microphoneSelectionMigrationVersion = 4
            let coordinator = MicrophonePreferenceCoordinator(
                settings: SettingsStore.shared,
                devices: FakeAudioDeviceManager(
                    inputs: [preferred],
                    defaultInputUID: preferred.uid
                )
            )

            XCTAssertEqual(
                coordinator.reconcileMicrophoneSelection(
                    availableInputs: [preferred],
                    defaultInputUID: preferred.uid
                ),
                preferred
            )
            XCTAssertNil(coordinator.confirmedActiveInputUID)

            coordinator.confirmActiveSelection(uid: preferred.uid, name: preferred.name)
            XCTAssertEqual(coordinator.confirmedActiveInputUID, preferred.uid)
        }
    }

    @MainActor
    func testDisablingMicrophoneChangeAlertsPreservesMicrophonePriority() throws {
        try self.withRestoredDefaults(keys: [
            self.microphonePriorityKey,
            self.showMicrophoneChangeAlertsKey,
        ]) {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: self.showMicrophoneChangeAlertsKey)
            let microphone = Self.device(uid: "preferred", name: "Preferred")
            SettingsStore.shared.microphonePriority = [
                .init(uid: microphone.uid, name: microphone.name),
            ]

            XCTAssertTrue(SettingsStore.shared.showMicrophoneChangeAlerts)

            MicrophoneChangeOverlayController.shared.disableFutureAlerts()

            XCTAssertFalse(SettingsStore.shared.showMicrophoneChangeAlerts)
            XCTAssertEqual(SettingsStore.shared.makeBackupPayload().showMicrophoneChangeAlerts, false)
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [microphone.uid])
        }
    }

    @MainActor
    func testFailedPriorityDeviceAdvancesWithoutChangingSavedOrder() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphonePriorityKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            let studio = Self.device(uid: "studio", name: "Studio Microphone")
            let webcam = Self.device(uid: "webcam", name: "Webcam Microphone")
            SettingsStore.shared.microphonePriority = [
                .init(uid: studio.uid, name: studio.name),
                .init(uid: webcam.uid, name: webcam.name),
            ]
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.microphoneSelectionMigrationVersion = 4
            let devices = FakeAudioDeviceManager(
                inputs: [studio, webcam],
                defaultInputUID: studio.uid
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let fallback = coordinator.inputDeviceForCapture(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID,
                excluding: [studio.uid]
            )

            XCTAssertEqual(fallback, webcam)
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [studio.uid, webcam.uid])
        }
    }

    @MainActor
    func testLegacySystemModeIsNormalizedWithoutReorderingPriority() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphonePriorityKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            let studio = Self.device(uid: "studio", name: "Studio Microphone")
            let system = Self.device(uid: "system", name: "System Microphone")
            SettingsStore.shared.microphonePriority = [
                .init(uid: studio.uid, name: studio.name),
                .init(uid: system.uid, name: system.name),
            ]
            SettingsStore.shared.microphoneSelectionMode = .system
            SettingsStore.shared.microphoneSelectionMigrationVersion = 3
            let devices = FakeAudioDeviceManager(
                inputs: [studio, system],
                defaultInputUID: system.uid
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            let selected = coordinator.reconcileMicrophoneSelection(
                availableInputs: devices.inputs,
                defaultInputUID: devices.defaultInputUID
            )

            XCTAssertEqual(selected, studio)
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [studio.uid, system.uid])
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMode, .manual)
            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
        }
    }

    @MainActor
    func testPrioritySkipsUnusableEnumeratedDeviceAndRestoresItAfterReconnect() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphonePriorityKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            let external = Self.device(uid: "external", name: "External Microphone")
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            SettingsStore.shared.microphonePriority = [
                .init(uid: external.uid, name: external.name),
                .init(uid: builtIn.uid, name: builtIn.name),
            ]
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.microphoneSelectionMigrationVersion = 4
            let devices = FakeAudioDeviceManager(
                inputs: [external, builtIn],
                defaultInputUID: builtIn.uid,
                unusableInputUIDs: [external.uid]
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            XCTAssertEqual(coordinator.inputDeviceForCapture(), builtIn)

            devices.unusableInputUIDs.remove(external.uid)

            XCTAssertEqual(coordinator.inputDeviceForCapture(), external)
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [external.uid, builtIn.uid])
        }
    }

    func testInputDeviceLivenessUsesSnapshotWithoutQueryingHAL() {
        let unavailable = AudioDevice.Device(
            id: 42,
            uid: "unavailable",
            name: "Unavailable Microphone",
            hasInput: true,
            hasOutput: false,
            isAlive: false
        )

        XCTAssertFalse(AudioDevice.isInputDeviceAlive(unavailable))
    }

    @MainActor
    func testInputAvailabilitySignalDoesNotEmitGenericHardwareChange() {
        let observer = AudioHardwareObserver()

        observer.signalInputAvailabilityChanged()

        XCTAssertEqual(observer.inputAvailabilityTick, 1)
        XCTAssertEqual(observer.changeTick, 0)
    }

    @MainActor
    func testClamshellSkipsEnumeratedUnusableBuiltInMicrophone() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphonePriorityKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            let external = Self.device(uid: "external", name: "External Microphone")
            SettingsStore.shared.microphonePriority = [
                .init(uid: builtIn.uid, name: builtIn.name),
                .init(uid: external.uid, name: external.name),
            ]
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.microphoneSelectionMigrationVersion = 4
            let devices = FakeAudioDeviceManager(
                inputs: [builtIn, external],
                defaultInputUID: builtIn.uid,
                isClamshellClosed: true
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            XCTAssertEqual(coordinator.inputDeviceForCapture(), external)
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [builtIn.uid, external.uid])

            devices.isClamshellClosed = false

            XCTAssertEqual(coordinator.inputDeviceForCapture(), builtIn)
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [builtIn.uid, external.uid])
        }
    }

    @MainActor
    func testClamshellKeepsBuiltInTransportExternalMicrophoneAvailable() throws {
        try self.withRestoredDefaults(keys: [
            self.microphoneSelectionModeKey,
            self.preferredInputDeviceUIDKey,
            self.microphonePriorityKey,
            self.microphoneSelectionMigrationVersionKey,
        ]) {
            let wiredHeadset = Self.device(
                uid: "wired-headset",
                name: "External Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn,
                inputDataSourceID: AudioDevice.Device.externalMicrophoneDataSourceID
            )
            SettingsStore.shared.microphonePriority = [
                .init(uid: wiredHeadset.uid, name: wiredHeadset.name),
            ]
            SettingsStore.shared.microphoneSelectionMode = .manual
            SettingsStore.shared.microphoneSelectionMigrationVersion = 4
            let devices = FakeAudioDeviceManager(
                inputs: [wiredHeadset],
                defaultInputUID: wiredHeadset.uid,
                isClamshellClosed: true
            )
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)

            XCTAssertTrue(wiredHeadset.isBuiltIn)
            XCTAssertEqual(coordinator.inputDeviceForCapture(), wiredHeadset)
        }
    }

    func testNewMicrophoneEntersSecondAndStaysAfterDisconnecting() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.microphonePriorityKey,
        ]) {
            let airPods = Self.device(uid: "airpods", name: "AirPods Microphone")
            let builtIn = Self.device(
                uid: "internal",
                name: "MacBook Pro Microphone",
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
            let usb = Self.device(uid: "usb", name: "USB Microphone")
            SettingsStore.shared.microphonePriority = [
                .init(uid: airPods.uid, name: airPods.name),
            ]

            SettingsStore.shared.reconcileMicrophonePriority(with: [builtIn])
            XCTAssertEqual(
                SettingsStore.shared.microphonePriority.map(\.uid),
                [airPods.uid, builtIn.uid]
            )

            SettingsStore.shared.reconcileMicrophonePriority(with: [builtIn, usb])
            XCTAssertEqual(
                SettingsStore.shared.microphonePriority.map(\.uid),
                [airPods.uid, usb.uid, builtIn.uid]
            )

            SettingsStore.shared.reconcileMicrophonePriority(with: [builtIn])
            XCTAssertEqual(
                SettingsStore.shared.microphonePriority.map(\.uid),
                [airPods.uid, usb.uid, builtIn.uid]
            )
        }
    }

    @MainActor
    func testRemovedConnectedMicrophoneStaysRemovedAfterReconnect() throws {
        try self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.microphonePriorityKey,
            self.suppressedMicrophoneUIDsKey,
        ]) {
            let builtIn = Self.device(uid: "internal", name: "MacBook Pro Microphone")
            let usb = Self.device(uid: "usb", name: "USB Microphone")
            SettingsStore.shared.microphonePriority = [
                .init(uid: builtIn.uid, name: builtIn.name),
                .init(uid: usb.uid, name: usb.name),
            ]
            SettingsStore.shared.removeMicrophoneFromPriority(uid: builtIn.uid, isConnected: true)

            let devices = FakeAudioDeviceManager(inputs: [builtIn, usb], defaultInputUID: builtIn.uid)
            let coordinator = MicrophonePreferenceCoordinator(settings: .shared, devices: devices)
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [usb.uid])
            XCTAssertEqual(coordinator.inputDeviceForCapture(), usb)

            SettingsStore.shared.reconcileMicrophonePriority(with: [builtIn, usb])
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [usb.uid])

            SettingsStore.shared.reconcileMicrophonePriority(with: [usb])
            XCTAssertTrue(SettingsStore.shared.suppressedMicrophoneUIDs.contains(builtIn.uid))

            SettingsStore.shared.reconcileMicrophonePriority(with: [builtIn, usb])
            XCTAssertEqual(SettingsStore.shared.microphonePriority.map(\.uid), [usb.uid])
            XCTAssertEqual(coordinator.inputDeviceForCapture(), usb)
        }
    }

    @MainActor
    func testSelectingOrRestoringMicrophoneClearsRemovalSuppression() async {
        let originalSuppressedUIDs = SettingsStore.shared.suppressedMicrophoneUIDs
        SettingsStore.shared.suppressedMicrophoneUIDs = []
        let document = await BackupService.shared.makeBackupDocument()
        defer { SettingsStore.shared.suppressedMicrophoneUIDs = originalSuppressedUIDs }

        self.withRestoredDefaults(keys: [
            self.preferredInputDeviceUIDKey,
            self.microphonePriorityKey,
            self.suppressedMicrophoneUIDsKey,
        ]) {
            let microphone = Self.device(uid: "restored", name: "Restored Microphone")
            SettingsStore.shared.suppressedMicrophoneUIDs = [microphone.uid]
            SettingsStore.shared.recordInputDeviceSelection(microphone.uid, name: microphone.name)
            XCTAssertFalse(SettingsStore.shared.suppressedMicrophoneUIDs.contains(microphone.uid))

            SettingsStore.shared.suppressedMicrophoneUIDs = [microphone.uid]
            SettingsStore.shared.restore(from: document.settings)
            XCTAssertTrue(SettingsStore.shared.suppressedMicrophoneUIDs.isEmpty)
        }
    }

    private static func device(
        uid: String,
        name: String,
        transportType: UInt32 = kAudioDeviceTransportTypeUnknown,
        inputDataSourceID: UInt32? = nil
    ) -> AudioDevice.Device {
        AudioDevice.Device(
            id: AudioObjectID(abs(uid.hashValue % 100_000) + 1),
            uid: uid,
            name: name,
            hasInput: true,
            hasOutput: false,
            transportType: transportType,
            inputDataSourceID: inputDataSourceID
        )
    }

    private func withRestoredDefaults(keys: [String], run: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let touchesMicrophoneSettings = keys.contains { key in
            key == self.microphoneSelectionModeKey ||
                key == self.preferredInputDeviceUIDKey ||
                key == self.microphoneSelectionMigrationVersionKey ||
                key == self.microphonePriorityKey ||
                key == self.suppressedMicrophoneUIDsKey
        }
        let managedKeys = touchesMicrophoneSettings
            ? Array(Set(keys + [
                self.microphoneSelectionModeKey,
                self.preferredInputDeviceUIDKey,
                self.microphonePriorityKey,
                self.suppressedMicrophoneUIDsKey,
                self.microphoneSelectionMigrationVersionKey,
            ]))
            : keys
        var snapshot: [String: Any] = [:]
        for key in managedKeys {
            if let value = defaults.object(forKey: key) {
                snapshot[key] = value
            }
        }
        if touchesMicrophoneSettings {
            defaults.removeObject(forKey: self.microphonePriorityKey)
            defaults.removeObject(forKey: self.suppressedMicrophoneUIDsKey)
        }

        defer {
            for key in managedKeys {
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
    var unusableInputUIDs: Set<String>
    var isClamshellClosed: Bool

    init(
        inputs: [AudioDevice.Device],
        defaultInputUID: String?,
        unusableInputUIDs: Set<String> = [],
        isClamshellClosed: Bool = false
    ) {
        self.inputs = inputs
        self.defaultInputUID = defaultInputUID
        self.unusableInputUIDs = unusableInputUIDs
        self.isClamshellClosed = isClamshellClosed
    }

    func listInputDevices() -> [AudioDevice.Device] {
        self.inputs
    }

    func defaultInputDevice() -> AudioDevice.Device? {
        guard let defaultInputUID else { return nil }
        return self.inputs.first { $0.uid == defaultInputUID }
    }

    func isInputDeviceUsable(_ device: AudioDevice.Device) -> Bool {
        self.unusableInputUIDs.contains(device.uid) == false
    }
}

/// Minimal driver that replays a `flagsChanged` / `keyDown` sequence through the pure
/// `ModifierOnlyShortcutFlagsDecision` state machine. `nextPressed` is the
/// `synchronizedPressedModifierKeyCodes` output for each event (the sync function is provably
/// correct for these inputs, so it is driven directly to focus the test on the decision logic).
private final class ModifierOnlyFlagsReplay {
    let shortcut: HotkeyShortcut
    private(set) var pressedModifierKeyCodes: Set<UInt16> = []
    private(set) var activeModifierOnlyType: HotkeyHoldModeType?
    private(set) var activeModifierOnlyShortcut: HotkeyShortcut?
    private(set) var otherKeyPressedDuringModifier = false
    /// Number of `.finish(wasCleanPress: true)` outcomes — the toggle-mode "start recording" path.
    private(set) var cleanFinishCount = 0

    init(shortcut: HotkeyShortcut) {
        self.shortcut = shortcut
    }

    func flagsChanged(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, nextPressed: Set<UInt16>) {
        self.pressedModifierKeyCodes = nextPressed
        let decision = ModifierOnlyShortcutFlagsDecision.evaluate(
            shortcut: self.shortcut,
            holdModeType: .transcription,
            isEnabled: true,
            keyCode: keyCode,
            modifiers: modifiers,
            state: ModifierOnlyShortcutTrackingState(
                pressedModifierKeyCodes: self.pressedModifierKeyCodes,
                activeModifierOnlyType: self.activeModifierOnlyType,
                activeModifierOnlyShortcut: self.activeModifierOnlyShortcut,
                otherKeyPressedDuringModifier: self.otherKeyPressedDuringModifier,
                isModeKeyPressed: false
            )
        )
        self.activeModifierOnlyType = decision.activeModifierOnlyType
        self.activeModifierOnlyShortcut = decision.activeModifierOnlyShortcut
        self.otherKeyPressedDuringModifier = decision.otherKeyPressedDuringModifier
        if case let .finish(wasCleanPress) = decision.outcome, wasCleanPress {
            self.cleanFinishCount += 1
        }
    }

    /// Simulates a non-modifier keyDown during an active modifier-only press
    /// (GlobalHotkeyManager.markOtherInputDuringModifierOnly).
    func keyDown() {
        if self.activeModifierOnlyType != nil {
            self.otherKeyPressedDuringModifier = true
        }
    }

    /// Same mark as keyDown; the mouse observer tap calls markOtherInputDuringModifierOnly too.
    func mouseDown() {
        self.keyDown()
    }
}
