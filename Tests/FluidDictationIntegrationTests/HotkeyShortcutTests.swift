// Event replay matrices share private helpers in this regression suite.
// swiftlint:disable file_length
import AppKit
import Combine
import CoreAudio
@testable import FluidVoice_Debug
import Foundation
import SwiftUI
import XCTest

// swiftlint:disable:next type_body_length
final class HotkeyShortcutTests: XCTestCase {
    @MainActor
    func testOverlayAppearanceRejectsNonfiniteTransparency() {
        let defaults = UserDefaults.standard
        let key = "OverlayGlassOpacity"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            SettingsStore.shared.overlayGlassOpacity = invalid
            XCTAssertEqual(SettingsStore.shared.overlayGlassOpacity, SettingsStore.defaultOverlayGlassOpacity)
        }
        SettingsStore.shared.overlayGlassOpacity = -1
        XCTAssertEqual(SettingsStore.shared.overlayGlassOpacity, 0.25)
        SettingsStore.shared.overlayGlassOpacity = 2
        XCTAssertEqual(SettingsStore.shared.overlayGlassOpacity, 1)
    }

    @MainActor
    func testOverlayAppearanceFitsNarrowSettingsColumn() {
        let defaults = UserDefaults.standard
        let keys = ["OverlaySize", "OverlayMaterial"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        // 800-point minimum window minus sidebar, settings insets, and card padding.
        for width: CGFloat in [420, 520, 900] {
            for scheme in [ColorScheme.light, .dark] {
                for overlaySize in SettingsStore.OverlaySize.allCases {
                    for material in SettingsStore.OverlayMaterial.allCases {
                        defaults.set(overlaySize.rawValue, forKey: keys[0])
                        defaults.set(material.rawValue, forKey: keys[1])
                        let host = NSHostingController(rootView: OverlayAppearanceEditor().environment(\.colorScheme, scheme))
                        let size = host.sizeThatFits(in: NSSize(width: width, height: 10_000))
                        XCTAssertLessThanOrEqual(size.width, width + 1, "\(overlaySize) / \(material) at \(width)")
                        XCTAssertTrue(size.height.isFinite)
                    }
                }
            }
        }
    }

    func testExplicitCustomPromptMigrationPreservesRulesAndIdentity() throws {
        var legacy = SettingsStore.DictationPromptProfile(name: "Brief", prompt: "Keep it short.")
        legacy.usesExplicitDictationPrompt = false
        let migrated = SettingsStore.migrateExplicitDictationPrompt(legacy, legacySendOnly: false)
        XCTAssertEqual(migrated.prompt, SettingsStore.combineBasePrompt(for: .dictate, with: legacy.prompt))
        XCTAssertEqual(migrated.id, legacy.id)
        XCTAssertEqual(migrated.updatedAt, legacy.updatedAt)
        XCTAssertTrue(migrated.usesExplicitDictationPrompt)
        XCTAssertEqual(SettingsStore.migrateExplicitDictationPrompt(migrated, legacySendOnly: false), migrated)
        let restored = try JSONDecoder().decode(SettingsStore.DictationPromptProfile.self, from: JSONEncoder().encode(migrated))
        XCTAssertEqual(SettingsStore.migrateExplicitDictationPrompt(restored, legacySendOnly: false), migrated)
        XCTAssertEqual(SettingsStore.shared.shortcutOverrideSystemPrompt(for: migrated), migrated.prompt)
    }

    func testExplicitCustomPromptMigrationHonorsLegacyToggleAndEditMode() {
        var legacy = SettingsStore.DictationPromptProfile(name: "Brief", prompt: "Keep it short.")
        legacy.usesExplicitDictationPrompt = false
        let standalone = SettingsStore.migrateExplicitDictationPrompt(legacy, legacySendOnly: true)
        XCTAssertEqual(standalone.prompt, legacy.prompt)
        legacy.mode = .edit
        XCTAssertEqual(SettingsStore.migrateExplicitDictationPrompt(legacy, legacySendOnly: false), legacy)
        legacy.mode = .dictate
        legacy.prompt = ""
        XCTAssertEqual(SettingsStore.migrateExplicitDictationPrompt(legacy, legacySendOnly: false).prompt, "")
    }

    func testLegacyEmptyCustomShortcutPreservesBothFallbacks() throws {
        var legacy = SettingsStore.DictationPromptProfile(name: "Legacy empty", prompt: "")
        legacy.usesExplicitDictationPrompt = false
        let withBase = SettingsStore.migrateExplicitDictationPrompt(legacy, legacySendOnly: false)
        let defaultFallback = SettingsStore.migrateExplicitDictationPrompt(legacy, legacySendOnly: true)
        XCTAssertEqual(SettingsStore.shared.shortcutOverrideSystemPrompt(for: withBase), SettingsStore.baseDictationPromptText())
        XCTAssertNil(SettingsStore.shared.shortcutOverrideSystemPrompt(for: defaultFallback))
        let restored = try JSONDecoder().decode(SettingsStore.DictationPromptProfile.self, from: JSONEncoder().encode(withBase))
        XCTAssertEqual(SettingsStore.shared.shortcutOverrideSystemPrompt(for: restored), SettingsStore.baseDictationPromptText())
        XCTAssertTrue(withBase.usesLegacyEmptyPromptFallback)
        XCTAssertTrue(defaultFallback.usesLegacyEmptyPromptFallback)
    }

    func testNewCustomPromptsUseWrittenTextWithoutStrippingOrAddingRules() {
        let written = SettingsStore.baseDictationPromptText() + "\n\nUse lowercase.  "
        let profile = SettingsStore.DictationPromptProfile(name: "Custom", prompt: written)
        XCTAssertEqual(SettingsStore.migrateExplicitDictationPrompt(profile, legacySendOnly: false), profile)
        XCTAssertEqual(SettingsStore.customPromptBody(written, mode: .dictate), written)
        XCTAssertEqual(SettingsStore.shared.shortcutOverrideSystemPrompt(for: profile), written)
        XCTAssertEqual(SettingsStore.shared.shortcutOverrideSystemPrompt(for: .init(name: "Blank", prompt: "")), "")
        XCTAssertTrue(SettingsStore.defaultDictationPromptText().contains(SettingsStore.baseDictationPromptText()))
    }

    func testInputDeliveryTimingKeepsClocksSeparate() {
        let input = HotkeyInputTiming(
            receivedAt: 100, eventTimestamp: 5_000_000_000, eventType: 12, receivedTimestamp: 5_050_000_000
        )
        XCTAssertEqual(input.deliveryAgeMs, 50)
        XCTAssertEqual(input.receivedAt, 100)
        XCTAssertEqual(input.eventTimestamp, 5_000_000_000)
        XCTAssertEqual(input.eventType, 12)
    }

    func testRemovingAllPrimaryShortcutsPreservesExplicitEmptyState() throws {
        try self.withRestoredDefaults(keys: [self.legacyHotkeyShortcutKey, self.primaryDictationShortcutsKey]) {
            let existing = SettingsStore.shared.hotkeyShortcut
            SettingsStore.shared.primaryDictationShortcuts = []
            XCTAssertEqual(SettingsStore.shared.primaryDictationShortcuts, [])
            XCTAssertEqual(SettingsStore.shared.primaryDictationShortcutDisplayString, "Off")
            SettingsStore.shared.primaryDictationShortcuts = [existing]
            XCTAssertEqual(SettingsStore.shared.primaryDictationShortcuts, [existing])
        }
    }

    func testCancelShortcutRemovalDoesNotRestoreEscape() throws {
        try self.withRestoredDefaults(keys: ["CancelRecordingHotkeyShortcut"]) {
            UserDefaults.standard.removeObject(forKey: "CancelRecordingHotkeyShortcut")
            XCTAssertEqual(SettingsStore.shared.cancelRecordingHotkeyShortcut, HotkeyShortcut(keyCode: 53, modifierFlags: []))
            SettingsStore.shared.cancelRecordingHotkeyShortcut = nil
            XCTAssertNil(SettingsStore.shared.cancelRecordingHotkeyShortcut)
            let shortcut = HotkeyShortcut(keyCode: 53, modifierFlags: [.command])
            SettingsStore.shared.cancelRecordingHotkeyShortcut = shortcut
            XCTAssertEqual(SettingsStore.shared.cancelRecordingHotkeyShortcut, shortcut)
        }
    }

    func testInputDeliveryTimingRejectsMissingAndFutureEventTimestamps() {
        let missing = HotkeyInputTiming(receivedAt: 100, eventTimestamp: 0, eventType: 12, receivedTimestamp: 5_000_000_000)
        XCTAssertNil(missing.deliveryAgeMs)
        let future = HotkeyInputTiming(receivedAt: 100, eventTimestamp: 6_000_000_000, eventType: 12, receivedTimestamp: 5_000_000_000)
        XCTAssertNil(future.deliveryAgeMs)
        let immediate = HotkeyInputTiming(receivedAt: 100, eventTimestamp: 5_000_000_000, eventType: 12, receivedTimestamp: 5_000_000_000)
        XCTAssertEqual(immediate.deliveryAgeMs, 0)
    }

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

    @MainActor
    func testShortcutCaptureConsumesControlCommandDBeforeAppDispatch() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 2, keyDown: true))
        event.flags = [.maskControl, .maskCommand]
        var captured: HotkeyShortcut?
        let consumed = GlobalHotkeyManager.captureKeyboardEvent(type: .keyDown, event: event, isAppActive: true) { appEvent in
            captured = HotkeyShortcut(keyCode: appEvent.keyCode, modifierFlags: appEvent.modifierFlags)
            return nil
        }

        XCTAssertTrue(consumed, "A captured chord must not also reach macOS dictionary lookup or the local monitor")
        XCTAssertEqual(captured, HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command]))
        XCTAssertTrue(try XCTUnwrap(captured).matches(keyCode: 2, modifiers: [.control, .command]))
        XCTAssertFalse(try XCTUnwrap(captured).matches(keyCode: 2, modifiers: [.control]))
    }

    @MainActor
    func testShortcutCapturePreservesPassThroughAndInactiveAppInput() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 2, keyDown: true))
        var deliveries = 0
        let handler: (NSEvent) -> NSEvent? = { appEvent in
            deliveries += 1
            return appEvent
        }

        XCTAssertFalse(GlobalHotkeyManager.captureKeyboardEvent(type: .keyDown, event: event, isAppActive: true, handler: handler))
        XCTAssertEqual(deliveries, 1)
        XCTAssertFalse(GlobalHotkeyManager.captureKeyboardEvent(type: .keyDown, event: event, isAppActive: false, handler: handler))
        XCTAssertFalse(GlobalHotkeyManager.captureKeyboardEvent(type: .keyUp, event: event, isAppActive: true, handler: handler))
        XCTAssertFalse(GlobalHotkeyManager.captureKeyboardEvent(type: .leftMouseDown, event: event, isAppActive: true, handler: handler))
        XCTAssertFalse(GlobalHotkeyManager.captureKeyboardEvent(type: .keyDown, event: event, isAppActive: true, handler: nil))
        XCTAssertEqual(deliveries, 1, "Only foreground keyboard capture should reach the recorder")

        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: 59)
        event.flags = .maskControl
        XCTAssertTrue(GlobalHotkeyManager.captureKeyboardEvent(type: .flagsChanged, event: event, isAppActive: true) { appEvent in
            XCTAssertEqual(appEvent.type, .flagsChanged)
            XCTAssertEqual(appEvent.keyCode, 59)
            return nil
        })
    }

    @MainActor
    func testPrimaryToggleKeyboardStartsAndStopsOnlyOnOwnedRelease() async throws {
        let asr = ASRService()
        defer { asr.isRunning = false }
        var starts = 0
        var stops = 0
        let manager = self.makePrimaryReleaseTestManager(
            asr: asr,
            onStart: {
                starts += 1
                asr.isRunning = true
            },
            onStop: {
                stops += 1
                asr.isRunning = false
            }
        )
        let down = try self.primaryReleaseTestEvent(type: .keyDown)
        let up = try self.primaryReleaseTestEvent(type: .keyUp, modifiers: [])

        XCTAssertNil(manager.handleKeyEvent(type: .keyDown, event: down))
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNil(manager.handleKeyEvent(type: .keyDown, event: down))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0, "Holding D and auto-repeat must not start recording")

        let modifierUp = try self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 59, modifiers: .maskCommand)
        _ = manager.handleKeyEvent(type: .flagsChanged, event: modifierUp)
        let unrelatedUp = try self.primaryReleaseTestEvent(type: .keyUp, keyCode: 3)
        XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: unrelatedUp) != nil)
        XCTAssertEqual(starts, 0)
        XCTAssertNil(manager.handleKeyEvent(type: .keyUp, event: up))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1, "Releasing modifiers before D must still activate the owned D press")
        XCTAssertEqual(stops, 0)

        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        XCTAssertNil(manager.handleKeyEvent(type: .keyDown, event: down))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(stops, 0, "The stop toggle must also wait for release")
        XCTAssertNil(manager.handleKeyEvent(type: .keyUp, event: up))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: up) != nil)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(stops, 1, "Duplicate releases must not toggle again")
    }

    @MainActor
    func testPrimaryToggleDiscardsPressAfterShortcutEditCaptureOrModeChange() async throws {
        let asr = ASRService()
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: { starts += 1 })
        let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command])
        let down = try self.primaryReleaseTestEvent(type: .keyDown)
        let up = try self.primaryReleaseTestEvent(type: .keyUp)

        _ = manager.handleKeyEvent(type: .keyDown, event: down)
        manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: 3, modifierFlags: [.control, .command])])
        XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: up) != nil)

        manager.updatePrimaryShortcuts([shortcut])
        _ = manager.handleKeyEvent(type: .keyDown, event: down)
        manager.resetModifierOnlyShortcutTracking(reason: .shortcutCapture)
        down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertNil(manager.handleKeyEvent(type: .keyDown, event: down))
        XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: up) != nil)

        down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        _ = manager.handleKeyEvent(type: .keyDown, event: down)
        manager.setHotkeyMode(.hold)
        XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: up) != nil)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0, "A stale press must not start recording after an edit, capture, or mode change")
    }

    @MainActor
    func testPrimaryHoldAndAutomaticStillStartOnKeyDown() async throws {
        for mode in [HotkeyActivationMode.hold, .automatic] {
            let asr = ASRService()
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: { starts += 1 })
            manager.setHotkeyMode(mode)

            let down = try self.primaryReleaseTestEvent(type: .keyDown)
            XCTAssertNil(manager.handleKeyEvent(type: .keyDown, event: down))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1, "\(mode) must start immediately to preserve first-word capture")
            manager.resetModifierOnlyShortcutTracking()
        }
    }

    @MainActor
    func testPrimaryToggleMouseAlsoWaitsForMatchingRelease() async throws {
        let asr = ASRService()
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: { starts += 1 })
        manager.updatePrimaryShortcuts([HotkeyShortcut(mouseButton: 2, modifierFlags: [])])
        let down = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        let up = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))

        XCTAssertNil(manager.handleMouseShortcutEvent(type: .otherMouseDown, event: down))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0)
        XCTAssertNil(manager.handleMouseShortcutEvent(type: .otherMouseUp, event: up))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(manager.handleMouseShortcutEvent(type: .otherMouseUp, event: up) != nil)
    }

    @MainActor
    func testPrimaryShortcutEditPreservesPendingPasteMouseRelease() throws {
        let settings = SettingsStore.shared
        let previousShortcut = settings.pasteLastTranscriptionHotkeyShortcut
        let previousEnabled = settings.pasteLastTranscriptionShortcutEnabled
        defer {
            settings.pasteLastTranscriptionHotkeyShortcut = previousShortcut
            settings.pasteLastTranscriptionShortcutEnabled = previousEnabled
        }
        settings.pasteLastTranscriptionHotkeyShortcut = HotkeyShortcut(mouseButton: 2, modifierFlags: [])
        settings.pasteLastTranscriptionShortcutEnabled = true
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: {})
        manager.setPasteLastTranscriptionCallback {}
        let down = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        let up = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))

        XCTAssertNil(manager.handleMouseShortcutEvent(type: .otherMouseDown, event: down))
        manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: 3, modifierFlags: [.control, .command])])
        XCTAssertNil(manager.handleMouseShortcutEvent(type: .otherMouseUp, event: up), "Editing primary dictation must preserve the consumed paste click's release")
    }

    @MainActor
    func testPrimaryToggleMissingReleaseCannotTurnPlainDIntoShortcut() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        // Simulate a dropped shortcut key-up, then ordinary typing of the same letter.
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, modifiers: []))
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp, modifiers: []))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0, "A missed release must not make plain D activate Ctrl+Cmd+D")
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1, "The next genuine chord must recover without restarting the app")
    }

    @MainActor
    func testPrimaryToggleCancelDiscardsPendingRelease() async throws {
        let settings = SettingsStore.shared
        let previous = settings.cancelRecordingHotkeyShortcut
        defer { settings.cancelRecordingHotkeyShortcut = previous }
        settings.cancelRecordingHotkeyShortcut = HotkeyShortcut(keyCode: 53, modifierFlags: [])
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        manager.setCancelCallback { .cancelled }
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: 53, modifiers: []))
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0, "Cancel must not be followed by a pending release starting dictation")
    }

    @MainActor
    func testPrimaryToggleUnchangedBindingsPreservePendingRelease() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command])])
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1, "Refreshing identical bindings must not drop a valid press")
    }

    func testExplicitModifierShortcutRejectsUntrackedExtraFlags() {
        // Command was already held when monitoring started; only Option's physical press is known.
        let replay = ModifierOnlyFlagsReplay(shortcut: HotkeyShortcut(keyCode: 58, modifierFlags: [], modifierKeyCodes: [58]))
        replay.flagsChanged(keyCode: 58, modifiers: [.command, .option], nextPressed: [58])
        XCTAssertNil(replay.activeModifierOnlyType, "Command+Option must not arm Option-only even if Command's press was missed")
        replay.flagsChanged(keyCode: 58, modifiers: .command, nextPressed: [])
        XCTAssertEqual(replay.cleanFinishCount, 0)
    }

    func testLegacyModifierShortcutCompletesOnEitherSide() {
        for keyCode: UInt16 in [58, 61] {
            let replay = ModifierOnlyFlagsReplay(shortcut: HotkeyShortcut(keyCode: 58, modifierFlags: .option))
            replay.flagsChanged(keyCode: keyCode, modifiers: .option, nextPressed: [keyCode])
            replay.flagsChanged(keyCode: keyCode, modifiers: [], nextPressed: [])
            XCTAssertEqual(replay.cleanFinishCount, 1, "Legacy flag-only shortcuts must finish on the side that armed them")
            XCTAssertNil(replay.activeModifierOnlyType)
        }
    }

    func testKeyboardShortcutExactMatchAndPersistenceMatrix() throws {
        let modifierFlags: [NSEvent.ModifierFlags] = [.function, .command, .option, .control, .shift]
        let combinations = (0..<32).map { bits in
            modifierFlags.enumerated().reduce(into: NSEvent.ModifierFlags()) { flags, entry in
                if bits & (1 << entry.offset) != 0 { flags.insert(entry.element) }
            }
        }
        for storedFlags in combinations {
            let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: storedFlags)
            XCTAssertEqual(try JSONDecoder().decode(HotkeyShortcut.self, from: JSONEncoder().encode(shortcut)), shortcut)
            for incomingFlags in combinations {
                for keyCode in UInt16(0)...127 {
                    let shouldMatch = keyCode == 2 && incomingFlags == storedFlags
                    XCTAssertEqual(shortcut.matches(keyCode: keyCode, modifiers: incomingFlags), shouldMatch)
                    XCTAssertEqual(shortcut.matches(keyCode: keyCode, modifiers: incomingFlags.union([.capsLock, .numericPad])), shouldMatch)
                }
            }
        }
    }

    @MainActor
    func testPrimaryToggleRejectsEveryOtherKeyAndModifierCombination() async throws {
        let settings = SettingsStore.shared
        let previousPasteEnabled = settings.pasteLastTranscriptionShortcutEnabled
        defer { settings.pasteLastTranscriptionShortcutEnabled = previousPasteEnabled }
        settings.pasteLastTranscriptionShortcutEnabled = false
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        let flags: [CGEventFlags] = [.maskSecondaryFn, .maskCommand, .maskAlternate, .maskControl, .maskShift]
        for bits in 0..<32 {
            let modifiers = flags.enumerated().reduce(into: CGEventFlags()) { result, entry in
                if bits & (1 << entry.offset) != 0 { result.insert(entry.element) }
            }
            for keyCode in UInt16(0)...127 where HotkeyShortcut.modifierFlag(forKeyCode: keyCode) == nil {
                let down = try self.primaryReleaseTestEvent(type: .keyDown, keyCode: keyCode, modifiers: modifiers)
                let up = try self.primaryReleaseTestEvent(type: .keyUp, keyCode: keyCode, modifiers: [])
                let shouldConsume = keyCode == 2 && modifiers == [.maskControl, .maskCommand]
                XCTAssertEqual(manager.handleKeyEvent(type: .keyDown, event: down) == nil, shouldConsume)
                XCTAssertEqual(manager.handleKeyEvent(type: .keyUp, event: up) == nil, shouldConsume)
            }
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1, "Only Ctrl+Cmd+D may activate among all 3,808 event pairs")
    }

    @MainActor
    func testPrimaryToggleSynthesizedTypingAndOrphanRepeatsNeverArm() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged] {
            let event = try self.primaryReleaseTestEvent(type: type)
            event.setIntegerValueField(.eventSourceUserData, value: TypingService.synthesizedEventUserData)
            XCTAssertTrue(manager.handleKeyEvent(type: type, event: event) != nil)
        }
        let repeatedDown = try self.primaryReleaseTestEvent(type: .keyDown)
        repeatedDown.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        for _ in 0..<100 {
            _ = manager.handleKeyEvent(type: .keyDown, event: repeatedDown)
        }
        let orphanUp = try self.primaryReleaseTestEvent(type: .keyUp)
        XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: orphanUp) != nil)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0)
    }

    @MainActor
    func testPrimaryToggleResetsDiscardStaleReleasesAndPermitNextPress() async throws {
        for reason in [GlobalHotkeyManager.ModifierTrackingResetReason.shortcutCapture, .tapDisabled, .reinitialize] {
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
            let down = try self.primaryReleaseTestEvent(type: .keyDown)
            let up = try self.primaryReleaseTestEvent(type: .keyUp)
            _ = manager.handleKeyEvent(type: .keyDown, event: down)
            manager.resetModifierOnlyShortcutTracking(reason: reason)
            XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: up) != nil)
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 0)
            _ = manager.handleKeyEvent(type: .keyDown, event: down)
            _ = manager.handleKeyEvent(type: .keyUp, event: up)
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1)
        }
    }

    @MainActor
    func testPrimaryToggleMouseMissingReleaseCannotActivateUnmodifiedClick() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        manager.updatePrimaryShortcuts([HotkeyShortcut(mouseButton: 2, modifierFlags: .control)])
        let down = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        let up = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
        down.flags = .maskControl
        _ = manager.handleMouseShortcutEvent(type: .otherMouseDown, event: down)
        down.flags = []
        XCTAssertTrue(manager.handleMouseShortcutEvent(type: .otherMouseDown, event: down) != nil)
        XCTAssertTrue(manager.handleMouseShortcutEvent(type: .otherMouseUp, event: up) != nil)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0)
        down.flags = .maskControl
        _ = manager.handleMouseShortcutEvent(type: .otherMouseDown, event: down)
        _ = manager.handleMouseShortcutEvent(type: .otherMouseUp, event: up)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
    }

    func testModifierOnlyInterruptionsAcrossFamiliesSidesAndReleaseOrders() {
        let modifierKeys: [(UInt16, NSEvent.ModifierFlags)] = [
            (63, .function), (55, .command), (54, .command), (58, .option), (61, .option),
            (59, .control), (62, .control), (56, .shift), (60, .shift),
        ]
        for (owner, ownerFlag) in modifierKeys {
            for explicitSide in [false, true] {
                let shortcut = HotkeyShortcut(keyCode: owner, modifierFlags: ownerFlag, modifierKeyCodes: explicitSide ? [owner] : [])
                for (extra, extraFlag) in modifierKeys where extra != owner {
                    for releaseOwnerFirst in [false, true] {
                        let replay = ModifierOnlyFlagsReplay(shortcut: shortcut)
                        replay.flagsChanged(keyCode: owner, modifiers: ownerFlag, nextPressed: [owner])
                        replay.flagsChanged(keyCode: extra, modifiers: ownerFlag.union(extraFlag), nextPressed: [owner, extra])
                        replay.keyDown()
                        if releaseOwnerFirst {
                            replay.flagsChanged(keyCode: owner, modifiers: extraFlag, nextPressed: [extra])
                            replay.flagsChanged(keyCode: extra, modifiers: [], nextPressed: [])
                        } else {
                            replay.flagsChanged(keyCode: extra, modifiers: ownerFlag, nextPressed: [owner])
                            replay.flagsChanged(keyCode: owner, modifiers: [], nextPressed: [])
                        }
                        XCTAssertEqual(replay.cleanFinishCount, 0, "Typing during a modifier hold must never become a clean tap")
                        XCTAssertNil(replay.activeModifierOnlyType)
                        replay.flagsChanged(keyCode: owner, modifiers: ownerFlag, nextPressed: [owner])
                        replay.flagsChanged(keyCode: owner, modifiers: [], nextPressed: [])
                        XCTAssertEqual(replay.cleanFinishCount, 1, "The next clean tap must still work")
                    }
                }
            }
        }
    }

    @MainActor
    func testRealManagerModifierTypingDoesNotStartAndNextCleanTapWorks() async throws {
        for owner: UInt16 in [58, 61] {
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
            manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: owner, modifierFlags: [], modifierKeyCodes: [owner])])
            let optionDown = try self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: owner, modifiers: .maskAlternate)
            let optionUp = try self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: owner, modifiers: [])
            _ = manager.handleKeyEvent(type: .flagsChanged, event: optionDown)
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 56, modifiers: [.maskAlternate, .maskShift]))
            for keyCode: UInt16 in [36, 15] {
                _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: keyCode, modifiers: [.maskAlternate, .maskShift]))
                _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp, keyCode: keyCode, modifiers: [.maskAlternate, .maskShift]))
            }
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 56, modifiers: .maskAlternate))
            _ = manager.handleKeyEvent(type: .flagsChanged, event: optionUp)
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 0)
            _ = manager.handleKeyEvent(type: .flagsChanged, event: optionDown)
            _ = manager.handleKeyEvent(type: .flagsChanged, event: optionUp)
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1)
        }
    }

    @MainActor
    func testOtherRecordingModesIgnoreAutorepeat() async throws {
        for activationMode in [HotkeyActivationMode.toggle, .hold, .automatic] {
            let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command])
            for mode in [HotkeyHoldModeType.promptMode, .commandMode, .rewriteMode, .promptAssignment] {
                var starts = 0
                let manager = GlobalHotkeyManager(
                    asrService: ASRService(),
                    primaryShortcuts: [],
                    promptModeShortcut: shortcut,
                    commandModeShortcut: shortcut,
                    rewriteModeShortcut: shortcut,
                    promptShortcutAssignments: mode == .promptAssignment ? [(selection: SettingsStore.DictationPromptSelection.default, shortcut: shortcut)] : [],
                    promptModeShortcutEnabled: mode == .promptMode,
                    commandModeShortcutEnabled: mode == .commandMode,
                    rewriteModeShortcutEnabled: mode == .rewriteMode,
                    promptModeCallback: { starts += 1 },
                    promptSelectionCallback: { _ in starts += 1 },
                    commandModeCallback: { starts += 1 },
                    rewriteModeCallback: { starts += 1 },
                    isSessionLockedProvider: { false }
                )
                manager.setHotkeyMode(activationMode)
                let down = try self.primaryReleaseTestEvent(type: .keyDown)
                down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
                XCTAssertNil(manager.handleKeyEvent(type: .keyDown, event: down))
                for _ in 0..<10 {
                    await Task.yield()
                }
                XCTAssertEqual(starts, 0, "A repeat without a fresh press must not start \(mode)")
                down.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
                XCTAssertNil(manager.handleKeyEvent(type: .keyDown, event: down))
                down.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
                for _ in 0..<100 {
                    XCTAssertNil(manager.handleKeyEvent(type: .keyDown, event: down))
                }
                for _ in 0..<10 {
                    await Task.yield()
                }
                XCTAssertEqual(starts, 1, "Holding a shortcut must not repeatedly start or stop \(mode) in \(activationMode)")
            }
        }
    }

    @MainActor
    func testPrimaryToggleRapidDoubleTapStartsThenStopsOnce() async throws {
        let asr = ASRService()
        defer { asr.isRunning = false }
        var starts = 0
        var stops = 0
        let manager = self.makePrimaryReleaseTestManager(
            asr: asr,
            onStart: {
                starts += 1
                asr.isRunning = true
            },
            onStop: {
                stops += 1
                asr.isRunning = false
            }
        )
        let down = try self.primaryReleaseTestEvent(type: .keyDown)
        let up = try self.primaryReleaseTestEvent(type: .keyUp)
        for _ in 0..<2 {
            _ = manager.handleKeyEvent(type: .keyDown, event: down)
            _ = manager.handleKeyEvent(type: .keyUp, event: up)
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1, "Queued start callbacks must not start twice for a rapid double tap")
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(asr.isRunning)
    }

    // Reported sequences stay linked to their issue, including reports closed for inactivity.
    @MainActor
    func testIssues1031And909UnconfiguredOAndReturnPassThrough() async throws {
        for mode in [HotkeyActivationMode.toggle, .hold, .automatic] {
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
            manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])])
            manager.setHotkeyMode(mode)
            for keyCode: UInt16 in [31, 36, 76] {
                for modifiers: CGEventFlags in [[], .maskSecondaryFn, .maskAlternate, .maskShift, .maskControl, .maskCommand] {
                    let down = try self.primaryReleaseTestEvent(type: .keyDown, keyCode: keyCode, modifiers: modifiers)
                    let up = try self.primaryReleaseTestEvent(type: .keyUp, keyCode: keyCode, modifiers: modifiers)
                    XCTAssertTrue(manager.handleKeyEvent(type: .keyDown, event: down) != nil)
                    XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: up) != nil)
                }
            }
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 63, modifiers: .maskSecondaryFn))
            _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: 51, modifiers: .maskSecondaryFn))
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 63, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 0, "Plain O/Return and Fn+Delete must not activate Right Option")
        }
    }

    @MainActor
    func testIssues675And609OrdinaryCommandChordsDoNotTriggerOtherModifiers() async throws {
        for owner: UInt16 in [58, 61, 62] {
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
            manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: owner, modifierFlags: [], modifierKeyCodes: [owner])])
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 55, modifiers: .maskCommand))
            for keyCode: UInt16 in [8, 9, 6, 48, 13, 21] {
                _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: keyCode, modifiers: .maskCommand))
                _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp, keyCode: keyCode, modifiers: .maskCommand))
            }
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 55, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 0)
            let modifier = owner == 62 ? CGEventFlags.maskControl : .maskAlternate
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: owner, modifiers: modifier))
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: owner, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1, "The configured shortcut must still work after normal Command shortcuts")
        }
    }

    @MainActor
    func testIssues688And858ShiftTypingDoesNotTriggerModifierChords() async throws {
        for shortcut in [
            HotkeyShortcut(keyCode: 58, modifierFlags: [], modifierKeyCodes: [58]),
            HotkeyShortcut(keyCode: 63, modifierFlags: [], modifierKeyCodes: [63, 59]),
            HotkeyShortcut(keyCode: 54, modifierFlags: [], modifierKeyCodes: [54, 61]),
        ] {
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
            manager.updatePrimaryShortcuts([shortcut])
            // Literal reported sequence: no configured modifiers held at all.
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 56, modifiers: .maskShift))
            for keyCode: UInt16 in [36, 15, 9] {
                _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: keyCode, modifiers: .maskShift))
                _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp, keyCode: keyCode, modifiers: .maskShift))
            }
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 56, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 0, "Shift+Enter/R/V must not start a different modifier shortcut")
        }
    }

    @MainActor
    func testIssues221And327MultiModifierChordsWorkInEveryPressAndReleaseOrder() async throws {
        for keys: [UInt16] in [[63, 59], [61, 60], [54, 61]] {
            for pressOrder in [keys, keys.reversed().map { $0 }] {
                for releaseOrder in [keys, keys.reversed().map { $0 }] {
                    var starts = 0
                    let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
                    manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: keys[0], modifierFlags: [], modifierKeyCodes: keys)])
                    var held: Set<UInt16> = []
                    for key in pressOrder {
                        held.insert(key)
                        let flags = held.reduce(into: CGEventFlags()) { result, key in
                            result.formUnion(key == 63 ? .maskSecondaryFn : key == 59 ? .maskControl : key == 60 ? .maskShift : key == 54 ? .maskCommand : .maskAlternate)
                        }
                        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: key, modifiers: flags))
                    }
                    for _ in 0..<10 {
                        await Task.yield()
                    }
                    XCTAssertEqual(starts, 0, "Toggle chords must wait for release")
                    for key in releaseOrder {
                        held.remove(key)
                        let flags = held.reduce(into: CGEventFlags()) { result, key in
                            result.formUnion(key == 63 ? .maskSecondaryFn : key == 59 ? .maskControl : key == 60 ? .maskShift : key == 54 ? .maskCommand : .maskAlternate)
                        }
                        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: key, modifiers: flags))
                    }
                    for _ in 0..<10 {
                        await Task.yield()
                    }
                    XCTAssertEqual(starts, 1, "A full chord must toggle once, whichever modifier is released first")
                }
            }
        }
    }

    @MainActor
    func testIssue498DeletingHeldPrimaryModifierDoesNotBlockRemainingShortcut() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        let command = HotkeyShortcut(keyCode: 55, modifierFlags: [], modifierKeyCodes: [55])
        let option = HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])
        manager.updatePrimaryShortcuts([command, option])
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 55, modifiers: .maskCommand))
        manager.updatePrimaryShortcuts([option])
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 55, modifiers: []))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0)
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: .maskAlternate))
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: []))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1, "Deleting a held modifier must not wedge the remaining binding until restart")
    }

    @MainActor
    func testIssue422DisablingHeldModeModifierDoesNotBlockPrimary() async throws {
        for mode in [HotkeyHoldModeType.promptMode, .commandMode, .rewriteMode, .promptAssignment] {
            var starts = 0
            var otherStarts = 0
            let command = HotkeyShortcut(keyCode: 54, modifierFlags: [], modifierKeyCodes: [54])
            let option = HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])
            let manager = GlobalHotkeyManager(
                asrService: ASRService(),
                primaryShortcuts: [option],
                promptModeShortcut: command,
                commandModeShortcut: command,
                rewriteModeShortcut: command,
                promptShortcutAssignments: mode == .promptAssignment ? [(selection: SettingsStore.DictationPromptSelection.default, shortcut: command)] : [],
                promptModeShortcutEnabled: mode == .promptMode,
                commandModeShortcutEnabled: mode == .commandMode,
                rewriteModeShortcutEnabled: mode == .rewriteMode,
                dictationModeCallback: { starts += 1 },
                promptModeCallback: { otherStarts += 1 },
                promptSelectionCallback: { _ in otherStarts += 1 },
                commandModeCallback: { otherStarts += 1 },
                rewriteModeCallback: { otherStarts += 1 },
                isSessionLockedProvider: { false }
            )
            manager.setHotkeyMode(.toggle)
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 54, modifiers: .maskCommand))
            switch mode {
            case .promptMode: manager.updatePromptModeShortcutEnabled(false)
            case .commandMode: manager.updateCommandModeShortcutEnabled(false)
            case .rewriteMode: manager.updateRewriteModeShortcutEnabled(false)
            case .promptAssignment: manager.updatePromptShortcutAssignments([])
            case .transcription: XCTFail("unexpected test mode")
            }
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 54, modifiers: []))
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: .maskAlternate))
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(otherStarts, 0, "Disabled modes must never activate on a pending release")
            XCTAssertEqual(starts, 1, "Disabling a held mode must not wedge primary dictation")
        }
    }

    @MainActor
    func testIssues94And211HoldStopsWhenModifiersReleaseBeforeTheLetter() async throws {
        for shortcut in [HotkeyShortcut(keyCode: 2, modifierFlags: .option), HotkeyShortcut(keyCode: 49, modifierFlags: [.option, .shift])] {
            let asr = ASRService()
            defer { asr.isRunning = false }
            var starts = 0
            var stops = 0
            let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: { starts += 1; asr.isRunning = true }, onStop: { stops += 1; asr.isRunning = false })
            manager.updatePrimaryShortcuts([shortcut])
            manager.setHotkeyMode(.hold)
            let modifiers: CGEventFlags = shortcut.keyCode == 2 ? .maskAlternate : [.maskAlternate, .maskShift]
            let down = try self.primaryReleaseTestEvent(type: .keyDown, keyCode: shortcut.keyCode, modifiers: modifiers)
            XCTAssertTrue(manager.handleKeyEvent(type: .keyDown, event: down) == nil)
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1)
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 58, modifiers: []))
            let up = try self.primaryReleaseTestEvent(type: .keyUp, keyCode: shortcut.keyCode, modifiers: [])
            XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: up) == nil, "The shortcut letter's release must not leak into normal typing")
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(stops, 1)
            XCTAssertFalse(asr.isRunning)
        }
    }

    @MainActor
    func testIssues470And968LiveKeyboardRebindingRemovesOldChordImmediately() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        let old = HotkeyShortcut(keyCode: 50, modifierFlags: .shift)
        let new = HotkeyShortcut(keyCode: 50, modifierFlags: [.shift, .control, .option, .command])
        manager.updatePrimaryShortcuts([old])
        manager.updatePrimaryShortcuts([new])
        for flags: CGEventFlags in [.maskShift, [.maskShift, .maskControl, .maskAlternate, .maskCommand], .maskShift] {
            _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: 50, modifiers: flags))
            _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp, keyCode: 50, modifiers: flags))
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testIssue849OptionKeyboardChordsContinueWorkingAfterRepeatedUses() async throws {
        for keyCode: UInt16 in [50, 12, 49] {
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
            manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: keyCode, modifierFlags: .option)])
            for _ in 0..<20 {
                _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: keyCode, modifiers: .maskAlternate))
                _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp, keyCode: keyCode, modifiers: []))
            }
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 20)
        }
    }

    @MainActor
    func testIssue675ExplicitStyleShortcutsRemainIndependentOfSecondaryToggle() throws {
        try self.withRestoredDefaults(keys: ["DictationPromptConfigurations", "PromptModeShortcutEnabled", "SecondaryPromptShortcutRemoved", "LegacySecondaryPromptShortcutRetired"]) {
            let settings = SettingsStore.shared
            let shortcut = HotkeyShortcut(keyCode: 55, modifierFlags: [], modifierKeyCodes: [55])
            settings.promptModeShortcutEnabled = false
            UserDefaults.standard.set(true, forKey: "SecondaryPromptShortcutRemoved")
            UserDefaults.standard.set(true, forKey: "LegacySecondaryPromptShortcutRetired")
            let configuration = SettingsStore.DictationPromptConfiguration(shortcut: shortcut, providerID: "provider-keep", modelName: "model-keep")
            settings.setDictationPromptConfiguration(configuration, for: .default)
            let assignments = settings.dictationPromptShortcutAssignments()
            XCTAssertTrue(assignments.contains { $0.selection == .default && $0.shortcut == shortcut }, "Explicit style shortcuts are separate from Secondary; disabling Secondary must not erase them")
            XCTAssertEqual(settings.dictationPromptConfiguration(for: .default), configuration)
        }
    }

    @MainActor
    func testHeldPrimaryRemovalStopsHoldAndAutomaticWithoutWaitingForOldRelease() async throws {
        for mode in [HotkeyActivationMode.hold, .automatic] {
            let asr = ASRService()
            defer { asr.isRunning = false }
            var starts = 0
            var stops = 0
            let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: { starts += 1; asr.isRunning = true }, onStop: { stops += 1; asr.isRunning = false })
            let old = HotkeyShortcut(keyCode: 55, modifierFlags: [], modifierKeyCodes: [55])
            let new = HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])
            manager.updatePrimaryShortcuts([old])
            manager.setHotkeyMode(mode)
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 55, modifiers: .maskCommand))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1)
            manager.updatePrimaryShortcuts([new])
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(stops, 1)
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 55, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(stops, 1, "The removed modifier release must not stop twice or start anything")
            XCTAssertEqual(starts, 1)
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: .maskAlternate))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 2)
        }
    }

    @MainActor
    func testShortcutUpdatesPreserveUnrelatedAndStillConfiguredModifierPresses() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        let option = HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])
        manager.updatePrimaryShortcuts([option])
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: .maskAlternate))
        manager.updatePrimaryShortcuts([option, HotkeyShortcut(keyCode: 2, modifierFlags: .control)])
        manager.updatePromptModeShortcutEnabled(false)
        manager.updateCommandModeShortcut(nil)
        manager.updateRewriteModeShortcut(HotkeyShortcut(keyCode: 15, modifierFlags: .control))
        manager.updatePromptShortcutAssignments([])
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: []))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1, "Other settings edits and adding a binding must preserve the current valid press")
    }

    @MainActor
    func testHeldModeRebindingDiscardsOldReleaseAndAllowsNewModifier() async throws {
        for mode in [HotkeyHoldModeType.promptMode, .commandMode, .rewriteMode, .promptAssignment] {
            var starts = 0
            let old = HotkeyShortcut(keyCode: 54, modifierFlags: [], modifierKeyCodes: [54])
            let new = HotkeyShortcut(keyCode: 60, modifierFlags: [], modifierKeyCodes: [60])
            let manager = GlobalHotkeyManager(
                asrService: ASRService(),
                primaryShortcuts: [],
                promptModeShortcut: old,
                commandModeShortcut: old,
                rewriteModeShortcut: old,
                promptShortcutAssignments: mode == .promptAssignment ? [(selection: .default, shortcut: old)] : [],
                promptModeShortcutEnabled: mode == .promptMode,
                commandModeShortcutEnabled: mode == .commandMode,
                rewriteModeShortcutEnabled: mode == .rewriteMode,
                promptModeCallback: { starts += 1 },
                promptSelectionCallback: { _ in starts += 1 },
                commandModeCallback: { starts += 1 },
                rewriteModeCallback: { starts += 1 },
                isSessionLockedProvider: { false }
            )
            manager.setHotkeyMode(.toggle)
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 54, modifiers: .maskCommand))
            switch mode {
            case .promptMode: manager.updatePromptModeShortcut(new)
            case .commandMode: manager.updateCommandModeShortcut(new)
            case .rewriteMode: manager.updateRewriteModeShortcut(new)
            case .promptAssignment: manager.updatePromptShortcutAssignments([(selection: .privateAI, shortcut: new)])
            case .transcription: XCTFail("unexpected test mode")
            }
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 54, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 0)
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 60, modifiers: .maskShift))
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 60, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1)
        }
    }

    @MainActor
    func testIssue622ThirdPartyShortcutEventsAreNotMistakenForFluidVoiceTyping() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        for sourceTag: Int64 in [0, 42, 0x5354454552] {
            let down = try self.primaryReleaseTestEvent(type: .keyDown)
            let up = try self.primaryReleaseTestEvent(type: .keyUp)
            down.setIntegerValueField(.eventSourceUserData, value: sourceTag)
            up.setIntegerValueField(.eventSourceUserData, value: sourceTag)
            XCTAssertTrue(manager.handleKeyEvent(type: .keyDown, event: down) == nil)
            XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: up) == nil)
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 3)
    }

    @MainActor
    func testIssue556BareTypingBindingsDoNotStartAnyRecordingMode() async throws {
        for activation in [HotkeyActivationMode.toggle, .hold, .automatic] {
            for mode in [HotkeyHoldModeType.transcription, .promptMode, .commandMode, .rewriteMode, .promptAssignment] {
                var starts = 0
                let bare = HotkeyShortcut(keyCode: 31, modifierFlags: [])
                let manager = GlobalHotkeyManager(
                    asrService: ASRService(),
                    primaryShortcuts: mode == .transcription ? [bare] : [],
                    promptModeShortcut: bare,
                    commandModeShortcut: bare,
                    rewriteModeShortcut: bare,
                    promptShortcutAssignments: mode == .promptAssignment ? [(selection: .default, shortcut: bare)] : [],
                    promptModeShortcutEnabled: mode == .promptMode,
                    commandModeShortcutEnabled: mode == .commandMode,
                    rewriteModeShortcutEnabled: mode == .rewriteMode,
                    startRecordingCallback: { starts += 1 },
                    dictationModeCallback: { starts += 1 },
                    promptModeCallback: { starts += 1 },
                    promptSelectionCallback: { _ in starts += 1 },
                    commandModeCallback: { starts += 1 },
                    rewriteModeCallback: { starts += 1 },
                    isSessionLockedProvider: { false }
                )
                manager.setHotkeyMode(activation)
                let down = try self.primaryReleaseTestEvent(type: .keyDown, keyCode: 31, modifiers: [])
                let up = try self.primaryReleaseTestEvent(type: .keyUp, keyCode: 31, modifiers: [])
                XCTAssertTrue(manager.handleKeyEvent(type: .keyDown, event: down) != nil, "Bare letters must pass through to the user's app")
                _ = manager.handleKeyEvent(type: .keyUp, event: up)
                for _ in 0..<10 {
                    await Task.yield()
                }
                XCTAssertEqual(starts, 0, "Bare O must not start \(mode) in \(activation)")
            }
        }
    }

    @MainActor
    func testIssue556SavedBareTypingBindingsAreOffWithoutChangingModelsOrCancel() throws {
        try self.withRestoredDefaults(keys: [
            self.primaryDictationShortcutsKey,
            self.legacyHotkeyShortcutKey,
            "DictationPromptConfigurations",
            "PromptModeHotkeyShortcut",
            "PromptModeShortcutEnabled",
            "CommandModeHotkeyShortcut",
            "CommandModeShortcutEnabled",
            "RewriteModeHotkeyShortcut",
            "RewriteModeShortcutEnabled",
            "CancelRecordingHotkeyShortcut",
        ]) {
            let settings = SettingsStore.shared
            let bare = HotkeyShortcut(keyCode: 31, modifierFlags: [])
            let data = try JSONEncoder().encode(bare)
            UserDefaults.standard.removeObject(forKey: self.primaryDictationShortcutsKey)
            UserDefaults.standard.set(data, forKey: self.legacyHotkeyShortcutKey)
            XCTAssertTrue(settings.primaryDictationShortcuts.isEmpty, "Legacy bare bindings must show Off")
            try UserDefaults.standard.set(JSONEncoder().encode([bare]), forKey: self.primaryDictationShortcutsKey)
            XCTAssertEqual(settings.primaryDictationShortcutDisplayString, "Off")
            settings.promptModeHotkeyShortcut = bare
            settings.promptModeShortcutEnabled = true
            settings.commandModeHotkeyShortcut = bare
            settings.commandModeShortcutEnabled = true
            settings.rewriteModeHotkeyShortcut = bare
            settings.rewriteModeShortcutEnabled = true
            XCTAssertFalse(settings.promptModeShortcutEnabled)
            XCTAssertFalse(settings.commandModeShortcutEnabled)
            XCTAssertFalse(settings.rewriteModeShortcutEnabled)
            settings.setDictationPromptConfiguration(.init(shortcut: bare, providerID: "provider-keep", modelName: "model-keep"), for: .default)
            XCTAssertFalse(settings.dictationPromptShortcutAssignments().contains { $0.selection == .default })
            let configuration = settings.dictationPromptConfiguration(for: .default)
            XCTAssertNil(configuration.shortcut)
            XCTAssertEqual(configuration.providerID, "provider-keep")
            XCTAssertEqual(configuration.modelName, "model-keep")
            settings.cancelRecordingHotkeyShortcut = HotkeyShortcut(keyCode: 53, modifierFlags: [])
            XCTAssertTrue(try XCTUnwrap(settings.cancelRecordingHotkeyShortcut).matches(keyCode: 53, modifiers: []))
            XCTAssertEqual(UserDefaults.standard.data(forKey: self.legacyHotkeyShortcutKey), data, "Reading invalid bindings must not rewrite preferences")
        }
    }

    func testSavedCommandShortcutRemainsReservedWhileDisabled() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Fluid/ContentView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func shortcutConflictMessage("))
        let end = try XCTUnwrap(source.range(of: "private func applyPrimaryDictationShortcut", range: start.upperBound..<source.endIndex))
        let conflicts = String(source[start.lowerBound..<end.lowerBound])
        let optional = try XCTUnwrap(conflicts.components(separatedBy: "let optionalConfiguredShortcuts:").last?.components(separatedBy: "for (otherTarget").first)
        XCTAssertTrue(optional.contains("(.command, self.commandModeHotkeyShortcut)"), "The saved binding must remain reserved when Command Mode is toggled off")
        XCTAssertFalse(conflicts.contains("if self.isCommandModeShortcutEnabled"))
        XCTAssertTrue(conflicts.contains("configuredShortcut == shortcut"))
        XCTAssertTrue(conflicts.contains("shortcut.conflictsWith(configuredShortcut)"))
        XCTAssertTrue(conflicts.contains("otherTarget != target"), "Editing the Command binding must not conflict with itself")
    }

    func testBareKeyPolicyCoversLettersNumbersAndEditingKeysButAllowsPunctuation() {
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        let editing: [UInt16] = [48, 49, 36, 76, 51, 117, 53]
        for keyCode in letters + digits + editing {
            let bare = HotkeyShortcut(keyCode: keyCode, modifierFlags: [])
            XCTAssertTrue(bare.requiresModifierForRecording, "keyCode=\(keyCode)")
            XCTAssertFalse(bare.matchesRecordingShortcut(keyCode: keyCode, modifiers: []))
            XCTAssertFalse(bare.matchesRecordingShortcut(keyCode: keyCode, modifiers: [.capsLock, .numericPad]))
            XCTAssertTrue(bare.matches(keyCode: keyCode, modifiers: []), "Cancel and generic matching must remain available")
            for modifier: NSEvent.ModifierFlags in [.control, .command, .option, .shift, .function, [.control, .command]] {
                XCTAssertTrue(HotkeyShortcut(keyCode: keyCode, modifierFlags: modifier).matchesRecordingShortcut(keyCode: keyCode, modifiers: modifier))
            }
        }
        // ANSI/ISO punctuation, keypad operators, and JIS punctuation.
        for keyCode: UInt16 in [10, 24, 27, 30, 33, 39, 41, 42, 43, 44, 47, 50, 65, 67, 69, 75, 78, 81, 93, 94, 95] {
            XCTAssertTrue(HotkeyShortcut(keyCode: keyCode, modifierFlags: []).matchesRecordingShortcut(keyCode: keyCode, modifiers: []), "Punctuation must remain available: \(keyCode)")
        }
        for keyCode: UInt16 in [54, 55, 56, 58, 59, 60, 61, 62, 63, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 123, 124, 125, 126] {
            XCTAssertFalse(HotkeyShortcut(keyCode: keyCode, modifierFlags: []).requiresModifierForRecording)
        }
        XCTAssertFalse(HotkeyShortcut(mouseButton: 2, modifierFlags: []).requiresModifierForRecording)
    }

    @MainActor
    func testBarePunctuationAndModifiedEditingKeysRemainUsableAfterInvalidKeys() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        for keyCode: UInt16 in [3, 31, 18, 49, 48, 36, 76, 51, 117, 53] {
            manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: keyCode, modifierFlags: [])])
            let down = try self.primaryReleaseTestEvent(type: .keyDown, keyCode: keyCode, modifiers: [])
            let up = try self.primaryReleaseTestEvent(type: .keyUp, keyCode: keyCode, modifiers: [])
            XCTAssertTrue(manager.handleKeyEvent(type: .keyDown, event: down) != nil)
            XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: up) != nil)
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0)
        let allowed = [
            HotkeyShortcut(keyCode: 50, modifierFlags: []),
            HotkeyShortcut(keyCode: 43, modifierFlags: []),
            HotkeyShortcut(keyCode: 47, modifierFlags: []),
            HotkeyShortcut(keyCode: 36, modifierFlags: .control),
            HotkeyShortcut(keyCode: 53, modifierFlags: .control),
        ]
        for shortcut in allowed {
            manager.updatePrimaryShortcuts([shortcut])
            let flags: CGEventFlags = shortcut.modifierFlags.isEmpty ? [] : .maskControl
            let down = try self.primaryReleaseTestEvent(type: .keyDown, keyCode: shortcut.keyCode, modifiers: flags)
            let up = try self.primaryReleaseTestEvent(type: .keyUp, keyCode: shortcut.keyCode, modifiers: [])
            XCTAssertTrue(manager.handleKeyEvent(type: .keyDown, event: down) == nil)
            XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: up) == nil)
            for _ in 0..<10 {
                await Task.yield()
            }
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, allowed.count)
    }

    @MainActor
    func testSavedPunctuationAndModifiedBindingsStayEnabled() throws {
        try self.withRestoredDefaults(keys: [
            self.primaryDictationShortcutsKey,
            self.legacyHotkeyShortcutKey,
            "DictationPromptConfigurations",
            "PromptModeHotkeyShortcut",
            "PromptModeShortcutEnabled",
            "CommandModeHotkeyShortcut",
            "CommandModeShortcutEnabled",
            "RewriteModeHotkeyShortcut",
            "RewriteModeShortcutEnabled",
        ]) {
            let settings = SettingsStore.shared
            for shortcut in [HotkeyShortcut(keyCode: 50, modifierFlags: []), HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command]), HotkeyShortcut(keyCode: 61, modifierFlags: [])] {
                settings.primaryDictationShortcuts = [HotkeyShortcut(keyCode: 3, modifierFlags: []), shortcut]
                XCTAssertEqual(settings.primaryDictationShortcuts, [shortcut])
                settings.promptModeHotkeyShortcut = shortcut
                settings.promptModeShortcutEnabled = true
                settings.commandModeHotkeyShortcut = shortcut
                settings.commandModeShortcutEnabled = true
                settings.rewriteModeHotkeyShortcut = shortcut
                settings.rewriteModeShortcutEnabled = true
                XCTAssertTrue(settings.promptModeShortcutEnabled)
                XCTAssertTrue(settings.commandModeShortcutEnabled)
                XCTAssertTrue(settings.rewriteModeShortcutEnabled)
                settings.setDictationPromptConfiguration(.init(shortcut: shortcut, providerID: "provider-keep", modelName: "model-keep"), for: .default)
                XCTAssertTrue(settings.dictationPromptShortcutAssignments().contains { $0.selection == .default && $0.shortcut == shortcut })
                XCTAssertEqual(settings.dictationPromptConfiguration(for: .default).shortcut, shortcut)
            }
        }
    }

    @MainActor
    func testPromptAssignmentEditsPreserveAnUnchangedHeldStyle() async throws {
        var selections: [SettingsStore.DictationPromptSelection] = []
        let command = HotkeyShortcut(keyCode: 54, modifierFlags: [], modifierKeyCodes: [54])
        let shift = HotkeyShortcut(keyCode: 60, modifierFlags: [], modifierKeyCodes: [60])
        let manager = GlobalHotkeyManager(
            asrService: ASRService(),
            primaryShortcuts: [],
            promptModeShortcut: shift,
            commandModeShortcut: nil,
            rewriteModeShortcut: shift,
            promptShortcutAssignments: [(selection: .default, shortcut: command), (selection: .privateAI, shortcut: shift)],
            promptModeShortcutEnabled: false,
            commandModeShortcutEnabled: false,
            rewriteModeShortcutEnabled: false,
            promptSelectionCallback: { selections.append($0) },
            isSessionLockedProvider: { false }
        )
        manager.setHotkeyMode(.toggle)
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 54, modifiers: .maskCommand))
        manager.updatePromptShortcutAssignments([(selection: .privateAI, shortcut: shift), (selection: .default, shortcut: command)])
        manager.updatePromptShortcutAssignments([(selection: .default, shortcut: command)])
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 54, modifiers: []))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(selections, [.default], "Reordering styles or deleting another style must preserve the unchanged active shortcut")
    }

    @MainActor
    func testIssue498RemovedIdleModifierNoLongerTriggersWithoutRestart() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        let command = HotkeyShortcut(keyCode: 55, modifierFlags: [], modifierKeyCodes: [55])
        let option = HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])
        manager.updatePrimaryShortcuts([command, option])
        manager.updatePrimaryShortcuts([option])
        for keyCode: UInt16 in [55, 61, 55] {
            let flags: CGEventFlags = keyCode == 55 ? .maskCommand : .maskAlternate
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: keyCode, modifiers: flags))
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: keyCode, modifiers: []))
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1, "Only the remaining Option binding may trigger")
    }

    @MainActor
    func testRemovingHeldBindingDoesNotStopADifferentRecordingMode() async throws {
        let asr = ASRService()
        defer { asr.isRunning = false }
        var isDictate = true
        var starts = 0
        var stops = 0
        let shortcut = HotkeyShortcut(keyCode: 55, modifierFlags: [], modifierKeyCodes: [55])
        let manager = GlobalHotkeyManager(
            asrService: asr,
            primaryShortcuts: [shortcut],
            promptModeShortcut: shortcut,
            commandModeShortcut: nil,
            rewriteModeShortcut: shortcut,
            promptModeShortcutEnabled: false,
            commandModeShortcutEnabled: false,
            rewriteModeShortcutEnabled: false,
            startRecordingCallback: { starts += 1; asr.isRunning = true },
            dictationModeCallback: { starts += 1; asr.isRunning = true },
            stopAndProcessCallback: { _ in stops += 1 },
            isDictateRecordingProvider: { isDictate },
            isSessionLockedProvider: { false }
        )
        manager.setHotkeyMode(.hold)
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 55, modifiers: .maskCommand))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
        // Another recording mode took over while the original shortcut was held.
        isDictate = false
        manager.updatePrimaryShortcuts([])
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 55, modifiers: []))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(asr.isRunning, "Editing a Dictate binding must not stop a different active mode")
    }

    @MainActor
    func testActivationModeChangeDiscardsHeldModifierRelease() async throws {
        for previousMode in [HotkeyActivationMode.toggle, .hold, .automatic] {
            let asr = ASRService()
            defer { asr.isRunning = false }
            var starts = 0
            var stops = 0
            let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: { starts += 1; asr.isRunning = true }, onStop: { stops += 1; asr.isRunning = false })
            let option = HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])
            manager.updatePrimaryShortcuts([option])
            manager.setHotkeyMode(previousMode)
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: .maskAlternate))
            for _ in 0..<10 {
                await Task.yield()
            }
            let startsBeforeChange = starts
            manager.setHotkeyMode(previousMode == .toggle ? .automatic : .toggle)
            for _ in 0..<10 {
                await Task.yield()
            }
            let stopsBeforeRelease = stops
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, startsBeforeChange, "Changing \(previousMode) must not let the old press activate a new mode")
            XCTAssertEqual(stops, stopsBeforeRelease, "The old release must not stop twice")
            manager.setHotkeyMode(.toggle)
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: .maskAlternate))
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, startsBeforeChange + 1, "The next clean tap must work")
        }
    }

    @MainActor
    func testUnchangedActivationModePreservesHeldKeyboardAndModifierPresses() async throws {
        for shortcut in [HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command]), HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])] {
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
            manager.updatePrimaryShortcuts([shortcut])
            let downType: CGEventType = shortcut.isModifierOnlyShortcut ? .flagsChanged : .keyDown
            let upType: CGEventType = shortcut.isModifierOnlyShortcut ? .flagsChanged : .keyUp
            let flags: CGEventFlags = shortcut.isModifierOnlyShortcut ? .maskAlternate : [.maskControl, .maskCommand]
            _ = try manager.handleKeyEvent(type: downType, event: self.primaryReleaseTestEvent(type: downType, keyCode: shortcut.keyCode, modifiers: flags))
            manager.setHotkeyMode(.toggle)
            _ = try manager.handleKeyEvent(type: upType, event: self.primaryReleaseTestEvent(type: upType, keyCode: shortcut.keyCode, modifiers: []))
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1, "Refreshing an unchanged mode must preserve a valid press")
        }
    }

    @MainActor
    func testActivationModeChangeCancelsAStartQueuedByOldHoldPress() async throws {
        let asr = ASRService()
        defer { asr.isRunning = false }
        var starts = 0
        var stops = 0
        let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: { starts += 1; asr.isRunning = true }, onStop: { stops += 1; asr.isRunning = false })
        manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])])
        manager.setHotkeyMode(.hold)
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: .maskAlternate))
        // Change mode before the queued recording callback gets a turn.
        manager.setHotkeyMode(.toggle)
        _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: []))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(stops, 0)
        XCTAssertFalse(asr.isRunning)
    }

    @MainActor
    func testAddingUnrelatedPrimaryBindingPreservesHeldKeyboardAndMouse() async throws {
        for mouse in [false, true] {
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
            let shortcut = mouse ? HotkeyShortcut(mouseButton: 2, modifierFlags: []) : HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command])
            manager.updatePrimaryShortcuts([shortcut])
            if mouse {
                let down = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
                _ = manager.handleMouseShortcutEvent(type: .otherMouseDown, event: down)
            } else {
                _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
            }
            manager.updatePrimaryShortcuts([shortcut, HotkeyShortcut(keyCode: 3, modifierFlags: .control)])
            if mouse {
                let up = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
                _ = manager.handleMouseShortcutEvent(type: .otherMouseUp, event: up)
            } else {
                _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
            }
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1, "Adding another binding must preserve the held \(mouse ? "mouse" : "keyboard") shortcut")
        }
    }

    @MainActor
    func testRemovingHeldBindingRechecksActiveModeWhenQueuedStopRuns() async throws {
        let asr = ASRService()
        defer { asr.isRunning = false }
        var isDictate = true
        var stops = 0
        let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command])
        let manager = GlobalHotkeyManager(
            asrService: asr,
            primaryShortcuts: [shortcut],
            promptModeShortcut: shortcut,
            commandModeShortcut: nil,
            rewriteModeShortcut: shortcut,
            promptModeShortcutEnabled: false,
            commandModeShortcutEnabled: false,
            rewriteModeShortcutEnabled: false,
            startRecordingCallback: { asr.isRunning = true },
            dictationModeCallback: { asr.isRunning = true },
            stopAndProcessCallback: { _ in stops += 1; asr.isRunning = false },
            isDictateRecordingProvider: { isDictate },
            isSessionLockedProvider: { false }
        )
        manager.setHotkeyMode(.hold)
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        for _ in 0..<10 {
            await Task.yield()
        }
        manager.updatePrimaryShortcuts([])
        isDictate = false // Another mode takes over before the scheduled stop executes.
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(asr.isRunning)
    }

    @MainActor
    func testPrimaryRapidToggleUsesNestedAudioStartBoundary() async throws {
        let asr = ASRService()
        defer { asr.isRunning = false }
        var starts = 0
        var stops = 0
        let manager = self.makePrimaryReleaseTestManager(
            asr: asr,
            onStart: {
                starts += 1
                await Task { @MainActor in asr.isRunning = true }.value
            },
            onStop: { stops += 1; asr.isRunning = false }
        )
        for _ in 0..<2 {
            _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
            _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(asr.isRunning, "Two quick taps must leave recording stopped even when start is nested")
    }

    @MainActor
    func testPrimaryRapidHoldRepressCancelsPreviousQueuedReleaseStop() async throws {
        let asr = ASRService()
        defer { asr.isRunning = false }
        var starts = 0
        var stops = 0
        let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: { starts += 1; asr.isRunning = true }, onStop: { stops += 1; asr.isRunning = false })
        manager.setHotkeyMode(.hold)
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        for _ in 0..<10 {
            await Task.yield()
        }
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(asr.isRunning, "A fresh held press must retain recording while invalidating the prior release")
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(stops, 1)
    }

    @MainActor
    func testCancelAfterToggleReleaseInvalidatesQueuedStart() async throws {
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        manager.setCancelCallback { .cancelled }
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: 53, modifiers: []))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0, "Handled cancel must invalidate the already-queued recording start")
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testRemovingBindingChangingModeOrCaptureInvalidatesQueuedToggleStart() async throws {
        for interruption in 0..<3 {
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
            _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
            _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
            switch interruption {
            case 0: manager.updatePrimaryShortcuts([])
            case 1: manager.setHotkeyMode(.hold)
            default: manager.resetModifierOnlyShortcutTracking()
            }
            for _ in 0..<10 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 0, "Queued start must not survive interruption \(interruption)")
        }
    }

    @MainActor
    func testForeignStyleKeyReleaseCannotStopOwnedStylePress() async throws {
        let asr = ASRService()
        defer { asr.isRunning = false }
        var starts = 0
        var stops = 0
        let first = HotkeyShortcut(keyCode: 2, modifierFlags: .control)
        let second = HotkeyShortcut(keyCode: 3, modifierFlags: .control)
        let manager = GlobalHotkeyManager(
            asrService: asr,
            primaryShortcuts: [],
            promptModeShortcut: first,
            commandModeShortcut: nil,
            rewriteModeShortcut: first,
            promptShortcutAssignments: [(selection: .default, shortcut: first), (selection: .privateAI, shortcut: second)],
            promptModeShortcutEnabled: false,
            commandModeShortcutEnabled: false,
            rewriteModeShortcutEnabled: false,
            stopAndProcessCallback: { _ in stops += 1; asr.isRunning = false },
            promptSelectionCallback: { _ in starts += 1; asr.isRunning = true },
            isPromptModeRecordingProvider: { true },
            isSessionLockedProvider: { false }
        )
        manager.setHotkeyMode(.hold)
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: 2, modifiers: .maskControl))
        for _ in 0..<10 {
            await Task.yield()
        }
        let foreignDown = try self.primaryReleaseTestEvent(type: .keyDown, keyCode: 3, modifiers: [])
        let foreignUp = try self.primaryReleaseTestEvent(type: .keyUp, keyCode: 3, modifiers: [])
        XCTAssertTrue(manager.handleKeyEvent(type: .keyDown, event: foreignDown) != nil)
        XCTAssertTrue(manager.handleKeyEvent(type: .keyUp, event: foreignUp) != nil)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0)
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp, keyCode: 2, modifiers: []))
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(stops, 1)
    }

    @MainActor
    func testRapidToggleTapParityAcrossNestedStartsAndStops() async throws {
        for initiallyRunning in [false, true] {
            for taps in 1...4 {
                let asr = ASRService()
                asr.isRunning = initiallyRunning
                var starts = 0
                var stops = 0
                let manager = self.makePrimaryReleaseTestManager(
                    asr: asr,
                    onStart: {
                        starts += 1
                        await Task { @MainActor in
                            await Task.yield()
                            asr.isRunning = true
                        }.value
                    },
                    onStop: {
                        stops += 1
                        await Task { @MainActor in
                            await Task.yield()
                            asr.isRunning = false
                        }.value
                    }
                )
                for _ in 0..<taps {
                    _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
                    _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
                }
                for _ in 0..<100 {
                    await Task.yield()
                }
                XCTAssertEqual(asr.isRunning, initiallyRunning != (taps % 2 == 1), "Initial recording=\(initiallyRunning), taps=\(taps)")
                XCTAssertEqual(starts, initiallyRunning ? taps / 2 : (taps + 1) / 2)
                XCTAssertEqual(stops, initiallyRunning ? (taps + 1) / 2 : taps / 2)
                asr.isRunning = false
            }
        }
    }

    @MainActor
    func testCancelOrResetAfterCallbackEntryCancelsNestedCaptureTask() async throws {
        for reset in [false, true] {
            let asr = ASRService()
            var gate: CheckedContinuation<Void, Never>?
            var captureStarts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: {
                let captureTask = Task { @MainActor in
                    await withCheckedContinuation { gate = $0 }
                    guard !Task.isCancelled else { return }
                    captureStarts += 1
                    asr.isRunning = true
                }
                await withTaskCancellationHandler {
                    await captureTask.value
                } onCancel: {
                    captureTask.cancel()
                }
            })
            if reset { manager.setHotkeyMode(.hold) }
            _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
            if !reset { _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp)) }
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertNotNil(gate, "Callback must reach the nested capture boundary")
            if reset {
                manager.resetModifierOnlyShortcutTracking(reason: .tapDisabled)
            } else {
                let result = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: 53, modifiers: []))
                XCTAssertNil(result, "Escape must cancel a pending start even while ASR is still idle")
            }
            gate?.resume()
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertEqual(captureStarts, 0)
            XCTAssertFalse(asr.isRunning)
            asr.isRunning = false
        }
    }

    @MainActor
    func testQueuedPrimarySurvivesRemovingUnrelatedBinding() async throws {
        let first = HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command])
        let second = HotkeyShortcut(keyCode: 3, modifierFlags: .control)
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        manager.updatePrimaryShortcuts([first, second])
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        manager.updatePrimaryShortcuts([first])
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testReassigningQueuedStyleCannotInvokeItsPreviousSelection() async throws {
        let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: .control)
        var selections: [SettingsStore.DictationPromptSelection] = []
        let manager = GlobalHotkeyManager(
            asrService: ASRService(),
            primaryShortcuts: [],
            promptModeShortcut: shortcut,
            commandModeShortcut: nil,
            rewriteModeShortcut: shortcut,
            promptShortcutAssignments: [(selection: .default, shortcut: shortcut)],
            promptModeShortcutEnabled: false,
            commandModeShortcutEnabled: false,
            rewriteModeShortcutEnabled: false,
            promptSelectionCallback: { selections.append($0) },
            isSessionLockedProvider: { false }
        )
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, modifiers: .maskControl))
        manager.updatePromptShortcutAssignments([(selection: .privateAI, shortcut: shortcut)])
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertTrue(selections.isEmpty)
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, modifiers: .maskControl))
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(selections, [.privateAI])
    }

    @MainActor
    func testModifierShortcutCannotTakeOverHeldKeyboardOwner() async throws {
        for style in [false, true] {
            let asr = ASRService()
            let keyboard = HotkeyShortcut(keyCode: 2, modifierFlags: .control)
            let modifier = HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])
            var starts = 0
            var stops = 0
            let manager = GlobalHotkeyManager(
                asrService: asr,
                primaryShortcuts: style ? [] : [keyboard, modifier],
                promptModeShortcut: keyboard,
                commandModeShortcut: nil,
                rewriteModeShortcut: keyboard,
                promptShortcutAssignments: style ? [(selection: .default, shortcut: keyboard), (selection: .privateAI, shortcut: modifier)] : [],
                promptModeShortcutEnabled: false,
                commandModeShortcutEnabled: false,
                rewriteModeShortcutEnabled: false,
                startRecordingCallback: { starts += 1; asr.isRunning = true },
                stopAndProcessCallback: { _ in stops += 1; asr.isRunning = false },
                promptSelectionCallback: { _ in starts += 1; asr.isRunning = true },
                isDictateRecordingProvider: { !style },
                isPromptModeRecordingProvider: { style },
                isSessionLockedProvider: { false }
            )
            manager.setHotkeyMode(.hold)
            _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, modifiers: .maskControl))
            for _ in 0..<20 {
                await Task.yield()
            }
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 59, modifiers: []))
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: .maskAlternate))
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: []))
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(stops, 0, "The keyboard is still held; a second modifier shortcut must not release it")
            XCTAssertTrue(asr.isRunning)
            _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp, modifiers: []))
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertEqual(stops, 1)
            asr.isRunning = false
        }
    }

    @MainActor
    func testBindingRemovalDoesNotCancelOutputAlreadyProcessing() async throws {
        let asr = ASRService()
        asr.isRunning = true
        var finishStop: CheckedContinuation<Void, Never>?
        var outputWasCancelled = false
        var stops = 0
        let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: {}, onStop: {
            await withCheckedContinuation { finishStop = $0 }
            outputWasCancelled = Task.isCancelled
            stops += 1
            asr.isRunning = false
        })
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertNotNil(finishStop)
        manager.updatePrimaryShortcuts([])
        finishStop?.resume()
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertFalse(outputWasCancelled)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(asr.isRunning)
        asr.isRunning = false
    }

    @MainActor
    func testToggleModifierCannotTakeOverHeldKeyboardOrMouseOwner() async throws {
        for mouse in [false, true] {
            let first = mouse ? HotkeyShortcut(mouseButton: 2, modifierFlags: []) : HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command])
            let modifier = HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
            manager.updatePrimaryShortcuts([first, modifier])
            if mouse {
                let down = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
                _ = manager.handleMouseShortcutEvent(type: .otherMouseDown, event: down)
            } else {
                _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
                _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 59, modifiers: []))
            }
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: .maskAlternate))
            _ = try manager.handleKeyEvent(type: .flagsChanged, event: self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: []))
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 0, "A second modifier shortcut must not activate before the owning key/button releases")
            if mouse {
                let up = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center))
                _ = manager.handleMouseShortcutEvent(type: .otherMouseUp, event: up)
            } else {
                _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp, modifiers: []))
            }
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1)
        }
    }

    @MainActor
    func testCancelledOutputPolicySavesHistoryWithoutEditorOrDelivery() {
        let route = ContentView.DictationOutputRoute.historyOnly
        XCTAssertTrue(route.savesHistory)
        XCTAssertFalse(route.deliversText)
        XCTAssertFalse(route.publishesEditorResult)
    }

    @MainActor
    func testNormalAndPracticeOutputPoliciesStayUnchanged() {
        let normal = ContentView.DictationOutputRoute.normal
        XCTAssertTrue(normal.savesHistory)
        XCTAssertTrue(normal.deliversText)
        XCTAssertTrue(normal.publishesEditorResult)
        let practice = ContentView.DictationOutputRoute.onboardingSandbox
        XCTAssertFalse(practice.savesHistory)
        XCTAssertFalse(practice.deliversText)
        XCTAssertTrue(practice.publishesEditorResult)
    }

    @MainActor
    func testCancelCallbackOwnsAudioBeforeDiscardFallback() async throws {
        let asr = ASRService()
        asr.isRunning = true
        defer { asr.isRunning = false }
        var cancellations = 0
        let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: {}, isSessionLocked: { true })
        manager.setCancelCallback { cancellations += 1; return .cancelled }
        let result = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: 53, modifiers: []))
        XCTAssertNil(result)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(asr.isRunning, "The application must own stop/transcription; fallback must not discard its audio")
    }

    @MainActor
    func testCancelClearsHeldOwnerWithoutStoppingApplicationRecovery() async throws {
        let asr = ASRService()
        defer { asr.isRunning = false }
        var starts = 0
        var stops = 0
        let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: { starts += 1; asr.isRunning = true }, onStop: { stops += 1; asr.isRunning = false })
        manager.setHotkeyMode(.hold)
        manager.setCancelCallback { .cancelled }
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertTrue(asr.isRunning)
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: 53, modifiers: []))
        let releaseEvent = try self.primaryReleaseTestEvent(type: .keyUp, modifiers: [])
        let released = manager.handleKeyEvent(type: .keyUp, event: releaseEvent)
        withExtendedLifetime(releaseEvent) {
            XCTAssertNotNil(released, "Escape invalidates the old held owner")
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(asr.isRunning, "The application-owned recovery must retain audio until transcription takes it")
        asr.isRunning = false // Recovery finishes; the next real shortcut must still work.
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 2)
    }

    @MainActor
    func testRepeatedCancelDoesNotInvokeDiscardWhileRecoveryIsPending() async throws {
        let asr = ASRService()
        asr.isRunning = true
        defer { asr.isRunning = false }
        var recoveryQueued = false
        var saves = 0
        let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: {})
        manager.setCancelCallback {
            if !recoveryQueued { recoveryQueued = true; saves += 1 }
            return .cancelled
        }
        for _ in 0..<5 {
            XCTAssertNil(try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: 53, modifiers: [])))
        }
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(asr.isRunning)
    }

    @MainActor
    func testSuggestionDismissalPreservesHoldRecordingAndOwnedRelease() async throws {
        let settings = SettingsStore.shared
        let previous = settings.cancelRecordingHotkeyShortcut
        defer { settings.cancelRecordingHotkeyShortcut = previous }
        for modifierOnly in [false, true] {
            let asr = ASRService()
            defer { asr.isRunning = false }
            var starts = 0
            var stops = 0
            let manager = self.makePrimaryReleaseTestManager(asr: asr, onStart: { starts += 1; asr.isRunning = true }, onStop: { stops += 1; asr.isRunning = false })
            manager.setHotkeyMode(.hold)
            if modifierOnly { manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])]) }
            let heldModifiers: CGEventFlags = modifierOnly ? .maskAlternate : [.maskControl, .maskCommand]
            settings.cancelRecordingHotkeyShortcut = HotkeyShortcut(keyCode: 53, modifierFlags: modifierOnly ? .option : [.control, .command])
            manager.setCancelCallback { .dismissedOverlay }
            let down = try self.primaryReleaseTestEvent(
                type: modifierOnly ? .flagsChanged : .keyDown,
                keyCode: modifierOnly ? 61 : 2,
                modifiers: heldModifiers
            )
            _ = manager.handleKeyEvent(type: down.type, event: down)
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertTrue(asr.isRunning)
            let escape = try self.primaryReleaseTestEvent(type: .keyDown, keyCode: 53, modifiers: heldModifiers)
            XCTAssertNil(manager.handleKeyEvent(type: .keyDown, event: escape))
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertTrue(asr.isRunning, "Only dismiss the suggestion; keep the current recording")
            XCTAssertEqual(stops, 0)
            let up = try self.primaryReleaseTestEvent(type: modifierOnly ? .flagsChanged : .keyUp, keyCode: modifierOnly ? 61 : 2, modifiers: modifierOnly ? [] : heldModifiers)
            _ = manager.handleKeyEvent(type: up.type, event: up)
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(stops, 1, "Dismissal must not orphan the held recording's release")
            XCTAssertFalse(asr.isRunning)
        }
    }

    @MainActor
    func testSuggestionDismissalInterruptsModifierOnlyToggleWithoutStartingRecording() async throws {
        let settings = SettingsStore.shared
        let previous = settings.cancelRecordingHotkeyShortcut
        defer { settings.cancelRecordingHotkeyShortcut = previous }
        settings.cancelRecordingHotkeyShortcut = HotkeyShortcut(keyCode: 53, modifierFlags: .option)
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        manager.updatePrimaryShortcuts([HotkeyShortcut(keyCode: 61, modifierFlags: [], modifierKeyCodes: [61])])
        manager.setCancelCallback { .dismissedOverlay }
        let down = try self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: .maskAlternate)
        _ = manager.handleKeyEvent(type: .flagsChanged, event: down)
        let escape = try self.primaryReleaseTestEvent(type: .keyDown, keyCode: 53, modifiers: .maskAlternate)
        XCTAssertNil(manager.handleKeyEvent(type: .keyDown, event: escape))
        let up = try self.primaryReleaseTestEvent(type: .flagsChanged, keyCode: 61, modifiers: [])
        _ = manager.handleKeyEvent(type: .flagsChanged, event: up)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0, "Closing the suggestion must not count as a clean modifier tap")
        _ = manager.handleKeyEvent(type: .flagsChanged, event: down)
        _ = manager.handleKeyEvent(type: .flagsChanged, event: up)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1, "The next genuine modifier tap must still work")
    }

    @MainActor
    func testCancelBeforeToggleReleaseDoesNotNeedApplicationUIToHandleIt() async throws {
        let settings = SettingsStore.shared
        let previous = settings.cancelRecordingHotkeyShortcut
        defer { settings.cancelRecordingHotkeyShortcut = previous }
        settings.cancelRecordingHotkeyShortcut = HotkeyShortcut(keyCode: 53, modifierFlags: [.control, .command])
        var starts = 0
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 })
        manager.setCancelCallback { .unhandled }
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown, keyCode: 53, modifiers: [.maskControl, .maskCommand]))
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 0)
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
    }

    @MainActor
    func testIdleCancelPassesThroughWhenApplicationHasNothingToHandle() throws {
        let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: {})
        manager.setCancelCallback { .unhandled }
        let event = try self.primaryReleaseTestEvent(type: .keyDown, keyCode: 53, modifiers: [])
        let result = manager.handleKeyEvent(type: .keyDown, event: event)
        withExtendedLifetime(event) { XCTAssertNotNil(result) }
    }

    @MainActor
    func testLockedSessionBlocksPrimaryRecordingStarts() async throws {
        for activationMode in [HotkeyActivationMode.toggle, .hold, .automatic] {
            var starts = 0
            let manager = self.makePrimaryReleaseTestManager(asr: ASRService(), onStart: { starts += 1 }, isSessionLocked: { true })
            manager.setHotkeyMode(activationMode)
            _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
            _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 0, "A locked session must not start primary recording in \(activationMode)")
        }
    }

    @MainActor
    func testLockedSessionBlocksOtherRecordingStarts() async throws {
        let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command])
        for mode in [HotkeyHoldModeType.promptMode, .commandMode, .rewriteMode, .promptAssignment] {
            var starts = 0
            let manager = GlobalHotkeyManager(
                asrService: ASRService(),
                primaryShortcuts: [],
                promptModeShortcut: shortcut,
                commandModeShortcut: shortcut,
                rewriteModeShortcut: shortcut,
                promptShortcutAssignments: mode == .promptAssignment ? [(selection: SettingsStore.DictationPromptSelection.default, shortcut: shortcut)] : [],
                promptModeShortcutEnabled: mode == .promptMode,
                commandModeShortcutEnabled: mode == .commandMode,
                rewriteModeShortcutEnabled: mode == .rewriteMode,
                promptModeCallback: { starts += 1 },
                promptSelectionCallback: { _ in starts += 1 },
                commandModeCallback: { starts += 1 },
                rewriteModeCallback: { starts += 1 },
                isSessionLockedProvider: { true }
            )
            manager.setHotkeyMode(.toggle)
            _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
            _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp))
            for _ in 0..<20 {
                await Task.yield()
            }
            XCTAssertEqual(starts, 0, "A locked session must not start \(mode)")
        }
    }

    @MainActor
    func testLockingSessionStillAllowsOwnedHoldRelease() async throws {
        let asr = ASRService()
        defer { asr.isRunning = false }
        var isLocked = false
        var starts = 0
        var stops = 0
        let manager = self.makePrimaryReleaseTestManager(
            asr: asr,
            onStart: { starts += 1; asr.isRunning = true },
            onStop: { stops += 1; asr.isRunning = false },
            isSessionLocked: { isLocked }
        )
        manager.setHotkeyMode(.hold)
        _ = try manager.handleKeyEvent(type: .keyDown, event: self.primaryReleaseTestEvent(type: .keyDown))
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(asr.isRunning)
        isLocked = true
        _ = try manager.handleKeyEvent(type: .keyUp, event: self.primaryReleaseTestEvent(type: .keyUp, modifiers: []))
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(stops, 1, "Locking must not strand a recording owned by the held shortcut")
        XCTAssertFalse(asr.isRunning)
    }

    @MainActor
    private func makePrimaryReleaseTestManager(
        asr: ASRService,
        onStart: @escaping () async -> Void,
        onStop: @escaping () async -> Void = {},
        isSessionLocked: @escaping () -> Bool = { false }
    ) -> GlobalHotkeyManager {
        let manager = GlobalHotkeyManager(
            asrService: asr,
            primaryShortcuts: [HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .command])],
            promptModeShortcut: HotkeyShortcut(keyCode: 60, modifierFlags: []),
            commandModeShortcut: nil,
            rewriteModeShortcut: HotkeyShortcut(keyCode: 58, modifierFlags: []),
            promptModeShortcutEnabled: false,
            commandModeShortcutEnabled: false,
            rewriteModeShortcutEnabled: false,
            startRecordingCallback: onStart,
            dictationModeCallback: onStart,
            stopAndProcessCallback: { _ in await onStop() },
            isDictateRecordingProvider: { true },
            isSessionLockedProvider: isSessionLocked
        )
        manager.setHotkeyMode(.toggle)
        return manager
    }

    private func primaryReleaseTestEvent(
        type: CGEventType,
        keyCode: CGKeyCode = 2,
        modifiers: CGEventFlags = [.maskControl, .maskCommand]
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: type == .keyDown))
        event.type = type
        event.flags = modifiers
        return event
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

    @MainActor
    func testMicrophoneNoticeFallbackReleasesHostedViewWithoutFadeCompletion() {
        let previous = SettingsStore.shared.showMicrophoneChangeAlerts
        SettingsStore.shared.showMicrophoneChangeAlerts = true
        defer { SettingsStore.shared.showMicrophoneChangeAlerts = previous }

        var fallbacks: [(delay: Duration, run: @MainActor () -> Void)] = []
        let controller = MicrophoneChangeOverlayController(
            animationOverride: { _, changes, _ in changes() },
            scheduleHideFallback: { delay, run in fallbacks.append((delay, run)) }
        )
        controller.show(.init(previousName: nil, currentName: "Test microphone", presentation: .startupSelection))
        weak var hostedView = controller.hostedContentView
        XCTAssertNotNil(hostedView)

        controller.hide()
        XCTAssertNotNil(controller.hostedContentView, "The fade completion was deliberately withheld")
        XCTAssertEqual(fallbacks.count, 1)
        XCTAssertEqual(fallbacks[0].delay, .milliseconds(200))

        fallbacks[0].run()
        XCTAssertNil(controller.hostedContentView)
        XCTAssertNil(hostedView, "The countdown's NSHostingView must be released")
    }

    @MainActor
    func testMicrophoneNoticeStaleFallbackKeepsNewNotice() {
        let previous = SettingsStore.shared.showMicrophoneChangeAlerts
        SettingsStore.shared.showMicrophoneChangeAlerts = true
        defer { SettingsStore.shared.showMicrophoneChangeAlerts = previous }

        var fallbacks: [(Duration, @MainActor () -> Void)] = []
        let controller = MicrophoneChangeOverlayController(
            animationOverride: { _, changes, _ in changes() },
            scheduleHideFallback: { delay, run in fallbacks.append((delay, run)) }
        )
        controller.show(.init(previousName: nil, currentName: "First microphone", presentation: .startupSelection))
        controller.hide()
        controller.show(.init(previousName: "First microphone", currentName: "Second microphone", presentation: .selectionChange))
        weak var secondHostedView = controller.hostedContentView
        XCTAssertNotNil(secondHostedView)

        fallbacks[0].1()
        XCTAssertTrue(controller.hostedContentView === secondHostedView)

        controller.hide()
        XCTAssertEqual(fallbacks.count, 2)
        fallbacks[1].1()
        XCTAssertNil(secondHostedView)
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
        let previous = SettingsStore.shared.overlayClosingAnimationEnabled
        SettingsStore.shared.overlayClosingAnimationEnabled = true
        defer { SettingsStore.shared.overlayClosingAnimationEnabled = previous }
        let audioPublisher = Just(CGFloat.zero).eraseToAnyPublisher()
        let controller = BottomOverlayWindowController.shared

        controller.prepare()
        await Task.yield()
        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        controller.hide()
        XCTAssertTrue(
            NotchContentState.shared.isBottomOverlayDismissing,
            "A nonblocking hide must start the visual transition before returning"
        )
        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        XCTAssertFalse(NotchContentState.shared.isBottomOverlayDismissing)
        let outcome = await controller.hideAndWait()

        XCTAssertEqual(outcome, .hidden)
        XCTAssertFalse(NotchContentState.shared.isBottomOverlayPresented)
    }

    @MainActor
    func testPreparedBottomOverlayStaysInvisibleAcrossScreenChanges() async {
        let controller = BottomOverlayWindowController.shared
        let audioPublisher = Just(CGFloat.zero).eraseToAnyPublisher()
        controller.hideImmediately()
        controller.destroyWindowForTests()
        controller.prepare()
        await Task.yield()
        XCTAssertTrue(controller.isVisuallyHiddenForTests, "A prepared panel must never be visible before the first show")
        XCTAssertTrue(controller.isParkedOffscreenForTests)

        // Login, wake and monitor plug post this after the panel was parked.
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(controller.isVisuallyHiddenForTests, "A display change must not reveal the parked panel")
        XCTAssertTrue(controller.isParkedOffscreenForTests, "The panel must be re-parked after a display change")

        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        XCTAssertFalse(controller.isVisuallyHiddenForTests, "Parking at alpha 0 must not break the next show")
        controller.hideImmediately()
    }

    func testBottomOverlayGrowthUsesASpring() {
        // A spring retargets smoothly when the text keeps growing.
        XCTAssertEqual(BottomOverlayWindowController.growthAnimation, .spring(response: 0.32, dampingFraction: 0.86))
    }

    func testBottomOverlayExitUsesMinimalFadeDuration() {
        XCTAssertEqual(BottomOverlayWindowController.exitDuration, 0.08, accuracy: 0.001)
    }

    @MainActor
    func testBottomOverlayReportsWhenRapidRestartSupersedesHide() async {
        let previous = SettingsStore.shared.overlayClosingAnimationEnabled
        SettingsStore.shared.overlayClosingAnimationEnabled = true
        defer { SettingsStore.shared.overlayClosingAnimationEnabled = previous }
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

    @MainActor
    func testDisabledClosingAnimationHidesWithoutDismissalAndAllowsImmediateRestart() async {
        let previous = SettingsStore.shared.overlayClosingAnimationEnabled
        SettingsStore.shared.overlayClosingAnimationEnabled = false
        defer { SettingsStore.shared.overlayClosingAnimationEnabled = previous }
        let controller = BottomOverlayWindowController.shared
        let audioPublisher = Just(CGFloat.zero).eraseToAnyPublisher()
        controller.show(audioPublisher: audioPublisher, mode: .dictation)

        let outcome = await controller.hideAndWait()
        XCTAssertEqual(outcome, .hidden)
        XCTAssertTrue(controller.isVisuallyHiddenForTests)
        XCTAssertFalse(NotchContentState.shared.isBottomOverlayDismissing)
        XCTAssertFalse(NotchContentState.shared.isBottomOverlayReleaseTransitioning)

        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        await Task.yield()
        XCTAssertFalse(controller.isVisuallyHiddenForTests, "Old deferred cleanup must not hide the new recording")
        controller.hide()
        XCTAssertTrue(controller.isVisuallyHiddenForTests)
        XCTAssertFalse(NotchContentState.shared.isBottomOverlayDismissing)
    }

    @MainActor
    func testBottomOverlayImmediateHideCompletesBeforeReturningAndAllowsRestart() async {
        let audioPublisher = Just(CGFloat.zero).eraseToAnyPublisher()
        let controller = BottomOverlayWindowController.shared

        controller.prepare()
        await Task.yield()
        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        controller.hideImmediately()

        XCTAssertTrue(controller.isVisuallyHiddenForTests)

        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        XCTAssertTrue(NotchContentState.shared.isBottomOverlayPresented)
        XCTAssertFalse(controller.isVisuallyHiddenForTests)
        XCTAssertFalse(NotchContentState.shared.isBottomOverlayDismissing)
        _ = await controller.hideAndWait()
    }

    @MainActor
    func testBottomOverlayReopenStartsAtEmptyHeightBeforeQueuedResize() async throws {
        let defaults = UserDefaults.standard
        let overlaySizeKey = "OverlaySize"
        let streamingPreviewKey = "EnableStreamingPreview"
        let previousOverlaySize = defaults.object(forKey: overlaySizeKey)
        let previousStreamingPreview = defaults.object(forKey: streamingPreviewKey)
        defer {
            if let previousOverlaySize {
                defaults.set(previousOverlaySize, forKey: overlaySizeKey)
            } else {
                defaults.removeObject(forKey: overlaySizeKey)
            }
            if let previousStreamingPreview {
                defaults.set(previousStreamingPreview, forKey: streamingPreviewKey)
            } else {
                defaults.removeObject(forKey: streamingPreviewKey)
            }
            NotchContentState.shared.updateTranscription("")
        }

        SettingsStore.shared.overlaySize = .medium
        SettingsStore.shared.enableStreamingPreview = true
        let audioPublisher = Just(CGFloat.zero).eraseToAnyPublisher()
        let controller = BottomOverlayWindowController.shared

        controller.prepare()
        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        let emptySize = try XCTUnwrap(controller.windowSizeForTests)

        NotchContentState.shared.updateTranscription(String(repeating: "multiline preview text ", count: 30))
        controller.refreshSizeForContent()
        // SwiftUI layout can finish after 120 ms on a busy host; await the actual resize.
        let resizeDeadline = Date().addingTimeInterval(2)
        while let size = controller.windowSizeForTests, size.height <= emptySize.height, Date() < resizeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let expandedSize = try XCTUnwrap(controller.windowSizeForTests)
        XCTAssertGreaterThan(expandedSize.height, emptySize.height)

        _ = await controller.hideAndWait()
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        let reopenedSize = try XCTUnwrap(controller.windowSizeForTests)
        XCTAssertEqual(reopenedSize.height, emptySize.height, accuracy: 0.5)

        // A resize queued by the previous presentation must not restore its frame.
        controller.refreshSizeForContent()
        controller.hide()
        controller.show(audioPublisher: audioPublisher, mode: .dictation)
        try await Task.sleep(nanoseconds: 120_000_000)
        let rapidReopenSize = try XCTUnwrap(controller.windowSizeForTests)
        XCTAssertEqual(rapidReopenSize.height, emptySize.height, accuracy: 0.5)
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
        let document = try await BackupService.shared.makeBackupDocument()
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
        let document = try await BackupService.shared.makeBackupDocument()
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
    func testHistoryPerformanceDefaultsOnAndRoundTripsWithoutBreakingLegacyBackups() async throws {
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
        XCTAssertTrue(SettingsStore.shared.showHistoryPerformanceMetrics)

        SettingsStore.shared.showHistoryPerformanceMetrics = false
        XCTAssertFalse(SettingsStore.shared.showHistoryPerformanceMetrics, "An explicit opt-out must remain respected")
        let optedOutDocument = try await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(optedOutDocument.settings.showHistoryPerformanceMetrics, false)

        SettingsStore.shared.showHistoryPerformanceMetrics = true
        let document = try await BackupService.shared.makeBackupDocument()
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
        let document = try await BackupService.shared.makeBackupDocument()

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
    func testPriorityBackupKeepsCompletedMicrophoneMigration() async throws {
        let document = try await BackupService.shared.makeBackupDocument()

        self.withRestoredDefaults(keys: [self.microphoneSelectionMigrationVersionKey]) {
            SettingsStore.shared.microphoneSelectionMigrationVersion = 4

            SettingsStore.shared.restore(from: document.settings)

            XCTAssertEqual(SettingsStore.shared.microphoneSelectionMigrationVersion, 4)
        }
    }

    @MainActor
    func testPriorityBackupRoundTripsRemovedConnectedMicrophones() async throws {
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
        let document = try await BackupService.shared.makeBackupDocument()

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
    func testSelectingOrRestoringMicrophoneClearsRemovalSuppression() async throws {
        let originalSuppressedUIDs = SettingsStore.shared.suppressedMicrophoneUIDs
        SettingsStore.shared.suppressedMicrophoneUIDs = []
        let document = try await BackupService.shared.makeBackupDocument()
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
