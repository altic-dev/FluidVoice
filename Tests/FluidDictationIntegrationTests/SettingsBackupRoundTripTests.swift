import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class SettingsBackupRoundTripTests: XCTestCase {
    func testModernBackupExportsAndRestoresMeetingIdleAndPromptConfiguration() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let profile = self.profile(id: "backup-dictation")
            let meeting = self.meetingDefaults()
            let configurations = self.configurations(profileID: profile.id)
            settings.dictationPromptProfiles = [profile]
            settings.meetingRecordingDefaults = meeting
            settings.privateAIIdleUnload = .oneHour
            settings.dictationPromptConfigurations = configurations
            let payload = settings.makeBackupPayload()
            let encoded = try JSONEncoder().encode(payload)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNotNil(json["meetingRecordingDefaults"])
            XCTAssertEqual(json["privateAIIdleUnload"] as? Int, 60)
            XCTAssertNotNil(json["dictationPromptConfigurations"])

            settings.meetingRecordingDefaults = .unconfigured
            settings.privateAIIdleUnload = .never
            settings.dictationPromptConfigurations = [:]
            settings.dictationPromptProfiles = []
            try settings.restore(
                from: JSONDecoder().decode(SettingsBackupPayload.self, from: encoded),
                promptProfiles: [profile],
                appPromptBindings: []
            )
            XCTAssertEqual(settings.meetingRecordingDefaults, meeting)
            XCTAssertEqual(settings.privateAIIdleUnload, .oneHour)
            XCTAssertEqual(settings.dictationPromptConfigurations, configurations)
            XCTAssertEqual(settings.dictationPromptShortcutAssignments().count, 3)
            XCTAssertEqual(settings.selectedProviderID, payload.selectedProviderID)
            XCTAssertEqual(settings.primaryDictationShortcuts, payload.primaryDictationShortcuts)
        }
    }

    func testLegacyAbsentFieldsPreserveCurrentPreferences() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let profile = self.profile(id: "legacy-survivor")
            settings.dictationPromptProfiles = [profile]
            let payload = try self.payload(removing: [
                "meetingRecordingDefaults", "privateAIIdleUnload", "dictationPromptConfigurations",
            ])
            let meeting = self.meetingDefaults()
            let configurations = self.configurations(profileID: profile.id)
            settings.meetingRecordingDefaults = meeting
            settings.privateAIIdleUnload = .thirtyMinutes
            settings.dictationPromptConfigurations = configurations
            settings.restore(from: payload, promptProfiles: [profile], appPromptBindings: [])
            XCTAssertEqual(settings.meetingRecordingDefaults, meeting)
            XCTAssertEqual(settings.privateAIIdleUnload, .thirtyMinutes)
            XCTAssertEqual(settings.dictationPromptConfigurations, configurations)
        }
    }

    func testCustomAccentColorRoundTripsAndPresetClearsIt() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            XCTAssertEqual(Color(hex: "#3AC8C6")?.hexString, "#3AC8C6")

            settings.accentColorOption = .purple
            settings.customAccentColorHex = "#FF2D55"
            XCTAssertEqual(settings.accentColor.hexString, "#FF2D55")
            let encoded = try JSONEncoder().encode(settings.makeBackupPayload())

            settings.accentColorOption = .green
            XCTAssertNil(settings.customAccentColorHex)
            try settings.restore(
                from: JSONDecoder().decode(SettingsBackupPayload.self, from: encoded),
                promptProfiles: settings.dictationPromptProfiles,
                appPromptBindings: []
            )
            XCTAssertEqual(settings.accentColorOption, .purple)
            XCTAssertEqual(settings.customAccentColorHex, "#FF2D55")

            settings.restore(
                from: try self.payload(removing: ["customAccentColorHex"]),
                promptProfiles: settings.dictationPromptProfiles,
                appPromptBindings: []
            )
            XCTAssertNil(settings.customAccentColorHex)
        }
    }

    func testExplicitEmptyPromptConfigurationsClearPreviousMappings() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            settings.dictationPromptConfigurations = [:]
            let payload = settings.makeBackupPayload()
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
            XCTAssertEqual((json["dictationPromptConfigurations"] as? [String: Any])?.count, 0)
            settings.dictationPromptConfigurations = self.configurations(profileID: "previous")
            settings.restore(from: payload, promptProfiles: [], appPromptBindings: [])
            XCTAssertTrue(settings.dictationPromptConfigurations.isEmpty)
            XCTAssertTrue(settings.dictationPromptShortcutAssignments().isEmpty)
        }
    }

    func testImportedPromptConfigurationsUseRestoredProfilesAndCannotActivateInvalidReferences() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let valid = self.profile(id: "imported")
            let edit = self.profile(id: "edit-only", mode: .edit)
            let shortcut = HotkeyShortcut(keyCode: 2, modifierFlags: [.control, .option])
            let imported: [String: SettingsStore.DictationPromptConfiguration] = [
                "profile:imported": .init(shortcut: shortcut, providerID: "openai", modelName: "imported-model"),
                "profile:missing": .init(shortcut: shortcut, providerID: "openai", modelName: "missing-model"),
                "profile:edit-only": .init(shortcut: shortcut, providerID: "openai", modelName: "edit-model"),
                "unknown": .init(shortcut: shortcut),
                "__default__": .init(shortcut: HotkeyShortcut(keyCode: 2, modifierFlags: []), providerID: "openai", modelName: "default-model"),
                "__privateAI__": .init(shortcut: shortcut, providerID: "apple-intelligence", modelName: "retired-model"),
            ]
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.makeBackupPayload())) as? [String: Any])
            json["dictationPromptConfigurations"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(imported))
            let payload = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
            settings.dictationPromptProfiles = [self.profile(id: "previous")]
            settings.dictationPromptConfigurations = ["profile:previous": .init(shortcut: shortcut)]
            settings.restore(from: payload, promptProfiles: [valid, edit], appPromptBindings: [])

            XCTAssertEqual(settings.dictationPromptConfigurations["profile:imported"], imported["profile:imported"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:missing"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:edit-only"])
            XCTAssertNil(settings.dictationPromptConfigurations["profile:previous"])
            XCTAssertNil(settings.dictationPromptConfigurations["unknown"])
            XCTAssertNil(settings.dictationPromptConfiguration(for: .default).shortcut)
            XCTAssertEqual(settings.dictationPromptConfiguration(for: .default).modelName, "default-model")
            XCTAssertEqual(settings.dictationPromptConfigurations["__privateAI__"], .init(shortcut: shortcut))
            XCTAssertEqual(settings.dictationPromptShortcutAssignments().count, 2)
            XCTAssertEqual(settings.selectedProviderID, payload.selectedProviderID)
            XCTAssertEqual(settings.primaryDictationShortcuts, payload.primaryDictationShortcuts)
        }
    }

    func testLegacyLinkedEditUsesRestoredPromptProvider() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            settings.selectedProviderID = "openai"
            settings.rewriteModeLinkedToGlobal = true
            settings.setDictationPromptSelection(.default, for: .primary)
            settings.dictationPromptConfigurations = ["__default__": .init(providerID: "openai", modelName: "gpt-4o-mini")]
            let payload = settings.makeBackupPayload()
            settings.dictationPromptConfigurations = ["__default__": .init(providerID: "anthropic", modelName: "claude-haiku")]

            settings.restore(from: payload, promptProfiles: [], appPromptBindings: [])

            XCTAssertEqual(settings.rewriteModeSelectedProviderID, "openai")
            XCTAssertFalse(settings.rewriteModeLinkedToGlobal)
            XCTAssertEqual(settings.dictationPromptSelection(for: .primary), .default)
            XCTAssertEqual(settings.selectedProviderID, payload.selectedProviderID)
            XCTAssertEqual(settings.primaryDictationShortcuts, payload.primaryDictationShortcuts)
        }
    }

    func testIndependentEditBackupKeepsItsOwnProvider() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            settings.rewriteModeLinkedToGlobal = false
            settings.rewriteModeSelectedProviderID = "anthropic"
            settings.rewriteModeSelectedModel = "saved-edit-model"
            let payload = settings.makeBackupPayload()
            settings.rewriteModeSelectedProviderID = "openai"
            settings.restore(from: payload, promptProfiles: [], appPromptBindings: [])
            XCTAssertEqual(settings.rewriteModeSelectedProviderID, "anthropic")
            XCTAssertEqual(settings.rewriteModeSelectedModel, "saved-edit-model")
            XCTAssertFalse(settings.rewriteModeLinkedToGlobal)
        }
    }

    func testDictionaryPromptDelayDefaultsAndRejectsUnknownStoredValues() throws {
        try self.withSavedDefaults {
            let defaults = UserDefaults.standard
            let settings = SettingsStore.shared
            defaults.removeObject(forKey: "AutomaticDictionaryPromptDelay")
            XCTAssertEqual(settings.automaticDictionaryPromptDelay, .three)
            for invalid in [-1, 0, 999, 4000] {
                defaults.set(invalid, forKey: "AutomaticDictionaryPromptDelay")
                XCTAssertEqual(settings.automaticDictionaryPromptDelay, .three)
            }
        }
    }

    func testDictionaryPromptDelayBackupRoundTripAndLegacyPreservation() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let enabled = settings.automaticDictionaryLearningEnabled
            let frequency = settings.automaticDictionarySuggestionFrequency
            for delay in SettingsStore.AutomaticDictionaryPromptDelay.allCases {
                settings.automaticDictionaryPromptDelay = delay
                let data = try JSONEncoder().encode(settings.makeBackupPayload())
                let payload = try JSONDecoder().decode(SettingsBackupPayload.self, from: data)
                settings.automaticDictionaryPromptDelay = .three
                settings.restore(from: payload, promptProfiles: [], appPromptBindings: [])
                XCTAssertEqual(settings.automaticDictionaryPromptDelay, delay)
                XCTAssertEqual(settings.automaticDictionaryLearningEnabled, enabled)
                XCTAssertEqual(settings.automaticDictionarySuggestionFrequency, frequency)
            }
            let legacy = try self.payload(removing: ["automaticDictionaryPromptDelay"])
            settings.automaticDictionaryPromptDelay = .threeQuarters
            settings.restore(from: legacy, promptProfiles: [], appPromptBindings: [])
            XCTAssertEqual(settings.automaticDictionaryPromptDelay, .threeQuarters)
        }
    }

    private func payload(removing keys: [String]) throws -> SettingsBackupPayload {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SettingsStore.shared.makeBackupPayload())) as? [String: Any])
        for key in keys {
            json.removeValue(forKey: key)
        }
        return try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func profile(id: String, mode: SettingsStore.PromptMode = .dictate) -> SettingsStore.DictationPromptProfile {
        .init(id: id, name: "Backup fixture", prompt: "Keep these words", mode: mode)
    }

    private func configurations(profileID: String) -> [String: SettingsStore.DictationPromptConfiguration] {
        [
            "__default__": .init(shortcut: HotkeyShortcut(keyCode: 2, modifierFlags: .control), providerID: "openai", modelName: "default-model"),
            "__privateAI__": .init(shortcut: HotkeyShortcut(keyCode: 3, modifierFlags: .control), providerID: "fluid-fixture", modelName: "private-model"),
            "profile:\(profileID)": .init(shortcut: HotkeyShortcut(keyCode: 5, modifierFlags: .control), providerID: "custom:fixture", modelName: "profile-model"),
        ]
    }

    private func meetingDefaults() -> MeetingRecordingDefaults {
        .init(
            isConfigured: true,
            mode: .inRoom,
            applicationBundleIdentifier: "fixture.meeting",
            applicationDisplayName: "Fixture Meeting",
            microphoneCaptureDeviceID: "fixture-capture",
            microphoneCoreAudioUID: "fixture-core-audio",
            microphoneRole: .shared,
            languageCode: "fr"
        )
    }

    private func withSavedDefaults(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let original = defaults.persistentDomain(forName: domain)
        defer {
            if let original {
                defaults.setPersistentDomain(original, forName: domain)
            } else {
                defaults.removePersistentDomain(forName: domain)
            }
        }
        try body()
    }
}

extension SettingsBackupRoundTripTests {
    func testMeetingShortcutRestoreAssignedUnassignedAndLegacyBackups() throws {
        try self.withSavedDefaults {
            let settings = SettingsStore.shared
            let assigned = HotkeyShortcut(keyCode: 46, modifierFlags: [.control, .option, .command])
            let replacement = HotkeyShortcut(keyCode: 46, modifierFlags: [.command, .shift])
            let primary = settings.primaryDictationShortcuts
            let meetingDefaults = settings.meetingRecordingDefaults
            settings.meetingRecordingHotkeyShortcut = assigned
            let assignedPayload = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONEncoder().encode(settings.makeBackupPayload()))
            settings.meetingRecordingHotkeyShortcut = nil
            let unassignedPayload = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONEncoder().encode(settings.makeBackupPayload()))
            let legacyPayload = try self.payload(removing: ["meetingRecordingHotkeyShortcut", "meetingRecordingShortcutEnabled"])

            settings.meetingRecordingHotkeyShortcut = replacement
            settings.restore(from: assignedPayload)
            XCTAssertEqual(settings.meetingRecordingHotkeyShortcut, assigned)
            settings.restore(from: unassignedPayload)
            XCTAssertNil(settings.meetingRecordingHotkeyShortcut)
            settings.meetingRecordingHotkeyShortcut = replacement
            settings.restore(from: legacyPayload)
            XCTAssertEqual(settings.meetingRecordingHotkeyShortcut, replacement)
            XCTAssertEqual(settings.primaryDictationShortcuts, primary)
            XCTAssertEqual(settings.meetingRecordingDefaults, meetingDefaults)
        }
    }
}
