import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Foundation
import ServiceManagement
import SwiftUI
#if canImport(FluidAudio)
import FluidAudio
#endif

// swiftlint:disable file_length type_body_length
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let transcriptionPreviewCharLimitRange: ClosedRange<Int> = 50...800
    static let transcriptionPreviewCharLimitStep = 50
    static let defaultTranscriptionPreviewCharLimit = 150
    private let defaults = UserDefaults.standard
    private let keychain = KeychainService.shared
    private(set) var launchAtStartupEnabled = false
    private(set) var launchAtStartupErrorMessage: String?
    private(set) var launchAtStartupStatusMessage =
        "FluidVoice reflects the actual macOS login item state. Unsigned or development builds may fail to enable this."

    private init() {
        self.migrateTranscriptionStartSoundIfNeeded()
        self.ensureDebugLoggingDefaults()
        self.migrateProviderAPIKeysIfNeeded()
        self.scrubSavedProviderAPIKeys()
        self.migrateDictationPromptProfilesIfNeeded()
        self.migrateLegacyDictationAIPreferenceIfNeeded()
        self.migrateSecondaryPromptShortcutIfNeeded()
        self.retireLegacySecondaryPromptShortcutIfNeeded()
        self.normalizePromptSelectionsIfNeeded()
        self.normalizeProviderSelectionForCurrentVerificationState()
        self.enforceOnboardingGenerationIfNeeded()
        self.migrateOverlayBottomOffsetTo50IfNeeded()
        self.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)
    }

    // MARK: - Prompt Profiles (Unified)

    enum PromptMode: String, Codable, CaseIterable, Identifiable {
        case dictate
        case edit
        case write // legacy persisted value (decoded as .edit)
        case rewrite // legacy persisted value (decoded as .edit)

        var id: String {
            self.rawValue
        }

        static var visiblePromptModes: [PromptMode] {
            [.dictate, .edit]
        }

        var normalized: PromptMode {
            switch self {
            case .dictate:
                return .dictate
            case .edit, .write, .rewrite:
                return .edit
            }
        }

        var displayName: String {
            switch self.normalized {
            case .dictate:
                return "Dictate"
            case .edit:
                return "Edit"
            case .write, .rewrite:
                return "Edit"
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = (try? container.decode(String.self).lowercased()) ?? Self.dictate.rawValue
            switch raw {
            case "dictate":
                self = .dictate
            case "edit", "write", "rewrite":
                self = .edit
            default:
                self = .dictate
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self.normalized.rawValue)
        }
    }

    enum DictationShortcutSlot: String, Codable, CaseIterable, Identifiable {
        case primary
        case secondary

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .primary:
                return "Primary Dictation Shortcut"
            case .secondary:
                return "Secondary Dictation Shortcut"
            }
        }
    }

    enum DictationPromptSelection: Equatable {
        case off, `default`, privateAI
        case profile(String)
    }

    struct DictationPromptProfile: Codable, Identifiable, Hashable {
        let id: String
        var name: String
        var prompt: String
        var mode: PromptMode
        var includeContext: Bool
        var createdAt: Date
        var updatedAt: Date

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case prompt
            case mode
            case includeContext
            case createdAt
            case updatedAt
        }

        init(
            id: String = UUID().uuidString,
            name: String,
            prompt: String,
            mode: PromptMode = .dictate,
            includeContext: Bool = false,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.name = name
            self.prompt = prompt
            self.mode = mode
            self.includeContext = includeContext
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.name = try container.decode(String.self, forKey: .name)
            self.prompt = try container.decode(String.self, forKey: .prompt)
            self.mode = try (container.decodeIfPresent(PromptMode.self, forKey: .mode) ?? .dictate).normalized
            self.includeContext = try container.decodeIfPresent(Bool.self, forKey: .includeContext) ?? false
            self.createdAt = try container.decode(Date.self, forKey: .createdAt)
            self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }
    }

    struct AppPromptBinding: Codable, Identifiable, Hashable {
        let id: String
        var mode: PromptMode
        var appBundleID: String
        var appName: String
        var promptID: String?
        var createdAt: Date
        var updatedAt: Date

        private enum CodingKeys: String, CodingKey {
            case id
            case mode
            case appBundleID
            case appName
            case promptID
            case createdAt
            case updatedAt
        }

        init(
            id: String = UUID().uuidString,
            mode: PromptMode,
            appBundleID: String,
            appName: String,
            promptID: String?,
            createdAt: Date = Date(),
            updatedAt: Date = Date()
        ) {
            self.id = id
            self.mode = mode.normalized
            self.appBundleID = Self.normalizeBundleID(appBundleID)
            let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.appName = trimmedName.isEmpty ? self.appBundleID : trimmedName
            let trimmedPromptID = promptID?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.promptID = (trimmedPromptID?.isEmpty == true) ? nil : trimmedPromptID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.mode = try (container.decodeIfPresent(PromptMode.self, forKey: .mode) ?? .dictate).normalized
            let rawBundleID = try container.decodeIfPresent(String.self, forKey: .appBundleID) ?? ""
            self.appBundleID = Self.normalizeBundleID(rawBundleID)
            let rawName = try container.decodeIfPresent(String.self, forKey: .appName) ?? ""
            let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.appName = trimmedName.isEmpty ? self.appBundleID : trimmedName
            let rawPromptID = try container.decodeIfPresent(String.self, forKey: .promptID)
            let trimmedPromptID = rawPromptID?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.promptID = (trimmedPromptID?.isEmpty == true) ? nil : trimmedPromptID
            self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        }

        private static func normalizeBundleID(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    struct DictationPromptConfiguration: Codable, Equatable {
        var shortcut: HotkeyShortcut?
        var providerID: String
        var modelName: String

        init(shortcut: HotkeyShortcut? = nil, providerID: String = "", modelName: String = "") {
            self.shortcut = shortcut
            self.providerID = providerID
            self.modelName = modelName
        }
    }

    enum PromptResolutionSource: String {
        case appBindingProfile
        case appBindingDefault
        case selectedProfile
        case defaultOverride
        case builtInDefault
    }

    struct PromptResolution {
        let source: PromptResolutionSource
        let profile: DictationPromptProfile?
        let appBinding: AppPromptBinding?
        let promptBody: String
        let systemPrompt: String
    }

    /// User-defined dictation prompt profiles (named system prompts for dictation enhancement).
    /// The built-in default prompt is not stored here.
    var dictationPromptProfiles: [DictationPromptProfile] {
        get {
            guard let data = self.defaults.data(forKey: Keys.dictationPromptProfiles),
                  let decoded = try? JSONDecoder().decode([DictationPromptProfile].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.dictationPromptProfiles)
            } else {
                // If encoding fails, avoid writing corrupt data.
                self.defaults.removeObject(forKey: Keys.dictationPromptProfiles)
            }
        }
    }

    /// Per-app prompt routing rules keyed by mode + app bundle identifier.
    /// `promptID == nil` means force Default prompt for that mode in the matched app.
    var appPromptBindings: [AppPromptBinding] {
        get {
            guard let data = self.defaults.data(forKey: Keys.appPromptBindings),
                  let decoded = try? JSONDecoder().decode([AppPromptBinding].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.appPromptBindings)
            } else {
                self.defaults.removeObject(forKey: Keys.appPromptBindings)
            }
        }
    }

    var dictationPromptConfigurations: [String: DictationPromptConfiguration] {
        get {
            guard let data = self.defaults.data(forKey: Keys.dictationPromptConfigurations),
                  let decoded = try? JSONDecoder().decode([String: DictationPromptConfiguration].self, from: data)
            else {
                return [:]
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.dictationPromptConfigurations)
            } else {
                self.defaults.removeObject(forKey: Keys.dictationPromptConfigurations)
            }
        }
    }

    /// Selected dictation prompt profile ID. `nil` means "Default".
    var selectedDictationPromptID: String? {
        get {
            let value = self.defaults.string(forKey: Keys.selectedDictationPromptID)
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : value
        }
        set {
            objectWillChange.send()
            if let id = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                self.defaults.set(id, forKey: Keys.selectedDictationPromptID)
            } else {
                self.defaults.removeObject(forKey: Keys.selectedDictationPromptID)
            }
        }
    }

    var isDictationPromptOff: Bool {
        get { self.defaults.bool(forKey: Keys.dictationPromptOff) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.dictationPromptOff)
        }
    }

    var isEditPromptOff: Bool {
        get { self.defaults.bool(forKey: Keys.editPromptOff) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.editPromptOff)
        }
    }

    var dictationPromptSelection: DictationPromptSelection {
        self.dictationPromptSelection(for: .primary)
    }

    func setDictationPromptSelection(_ selection: DictationPromptSelection) {
        self.setDictationPromptSelection(selection, for: .primary)
    }

    func dictationPromptSelection(for slot: DictationShortcutSlot) -> DictationPromptSelection {
        if self.isDictationPromptOff(for: slot) { return .off }
        if let promptID = self.selectedDictationPromptID(for: slot) {
            if promptID == PrivateAIProviderPromptFormat.promptSelectionID {
                return PrivateAIProviderPromptFormat.isAvailable(settings: self) ? .privateAI : .default
            }
            return .profile(promptID)
        }
        return .default
    }

    func setDictationPromptSelection(_ selection: DictationPromptSelection, for slot: DictationShortcutSlot) {
        let selectedID: String?
        switch selection {
        case .off, .default:
            selectedID = nil
        case .privateAI:
            selectedID = PrivateAIProviderPromptFormat.promptSelectionID
        case let .profile(promptID):
            selectedID = promptID
        }
        self.setDictationPromptOff(selection == .off, for: slot)
        self.setSelectedDictationPromptID(selectedID, for: slot)
    }

    func dictationPromptConfigurationKey(for selection: DictationPromptSelection) -> String? {
        switch selection {
        case .off:
            return nil
        case .privateAI:
            return "__privateAI__"
        case .default:
            return "__default__"
        case let .profile(promptID):
            let trimmed = promptID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "profile:\(trimmed)"
        }
    }

    func dictationPromptSelection(forConfigurationKey key: String) -> DictationPromptSelection? {
        if key == "__privateAI__" {
            return .privateAI
        }
        if key == "__default__" {
            return .default
        }
        if key.hasPrefix("profile:") {
            let id = String(key.dropFirst("profile:".count))
            guard self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode.normalized == .dictate }) else { return nil }
            return .profile(id)
        }
        return nil
    }

    func dictationPromptConfiguration(for selection: DictationPromptSelection) -> DictationPromptConfiguration {
        guard let key = self.dictationPromptConfigurationKey(for: selection) else {
            return DictationPromptConfiguration()
        }
        return self.dictationPromptConfigurations[key] ?? DictationPromptConfiguration()
    }

    func setDictationPromptConfiguration(_ configuration: DictationPromptConfiguration, for selection: DictationPromptSelection) {
        guard let key = self.dictationPromptConfigurationKey(for: selection) else { return }
        let providerID = configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        var configurations = self.dictationPromptConfigurations
        if configuration.shortcut == nil, providerID.isEmpty, modelName.isEmpty {
            configurations.removeValue(forKey: key)
        } else {
            configurations[key] = DictationPromptConfiguration(
                shortcut: configuration.shortcut,
                providerID: providerID,
                modelName: modelName
            )
        }
        self.dictationPromptConfigurations = configurations
    }

    func removeDictationPromptConfiguration(for selection: DictationPromptSelection) {
        guard let key = self.dictationPromptConfigurationKey(for: selection) else { return }
        var configurations = self.dictationPromptConfigurations
        configurations.removeValue(forKey: key)
        self.dictationPromptConfigurations = configurations
    }

    func dictationPromptShortcutAssignments() -> [(selection: DictationPromptSelection, shortcut: HotkeyShortcut)] {
        self.dictationPromptConfigurations.compactMap { key, configuration in
            guard let shortcut = configuration.shortcut else { return nil }
            if key == "__default__" {
                return (.default, shortcut)
            }
            if key == "__privateAI__" {
                return (.privateAI, shortcut)
            }
            if key.hasPrefix("profile:") {
                let id = String(key.dropFirst("profile:".count))
                guard self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode.normalized == .dictate }) else { return nil }
                return (.profile(id), shortcut)
            }
            return nil
        }
    }

    /// Convenience: currently selected profile, or nil if Default/invalid selection.
    var selectedDictationPromptProfile: DictationPromptProfile? {
        self.selectedPromptProfile(for: .dictate)
    }

    /// Selected edit prompt profile ID. `nil` means "Default Edit".
    var selectedEditPromptID: String? {
        get {
            if let value = self.defaults.string(forKey: Keys.selectedEditPromptID),
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            {
                return value
            }
            if let legacyRewrite = self.defaults.string(forKey: Keys.selectedRewritePromptID),
               legacyRewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            {
                return legacyRewrite
            }
            if let legacyWrite = self.defaults.string(forKey: Keys.selectedWritePromptID),
               legacyWrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            {
                return legacyWrite
            }
            return nil
        }
        set {
            objectWillChange.send()
            if let id = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                self.defaults.set(id, forKey: Keys.selectedEditPromptID)
            } else {
                self.defaults.removeObject(forKey: Keys.selectedEditPromptID)
            }
            // Normalize to the new key only.
            self.defaults.removeObject(forKey: Keys.selectedWritePromptID)
            self.defaults.removeObject(forKey: Keys.selectedRewritePromptID)
        }
    }

    /// Legacy alias retained for compatibility.
    var selectedWritePromptID: String? {
        get { self.selectedEditPromptID }
        set { self.selectedEditPromptID = newValue }
    }

    /// Legacy alias retained for compatibility.
    var selectedRewritePromptID: String? {
        get { self.selectedEditPromptID }
        set { self.selectedEditPromptID = newValue }
    }

    func selectedPromptID(for mode: PromptMode) -> String? {
        switch mode.normalized {
        case .dictate:
            if self.selectedDictationPromptID == PrivateAIProviderPromptFormat.promptSelectionID,
               !PrivateAIProviderPromptFormat.isAvailable(settings: self) { return nil }
            return self.selectedDictationPromptID
        case .edit:
            return self.selectedEditPromptID
        case .write, .rewrite:
            return self.selectedEditPromptID
        }
    }

    func selectedDictationPromptID(for slot: DictationShortcutSlot) -> String? {
        switch slot {
        case .primary:
            return self.selectedDictationPromptID
        case .secondary:
            return self.promptModeSelectedPromptID
        }
    }

    func setSelectedDictationPromptID(_ id: String?, for slot: DictationShortcutSlot) {
        switch slot {
        case .primary:
            self.selectedDictationPromptID = id
        case .secondary:
            self.promptModeSelectedPromptID = id
        }
    }

    func isDictationPromptOff(for slot: DictationShortcutSlot) -> Bool {
        switch slot {
        case .primary:
            return self.isDictationPromptOff
        case .secondary:
            return self.isSecondaryDictationPromptOff
        }
    }

    func setDictationPromptOff(_ isOff: Bool, for slot: DictationShortcutSlot) {
        switch slot {
        case .primary:
            self.isDictationPromptOff = isOff
        case .secondary:
            self.isSecondaryDictationPromptOff = isOff
        }
    }

    func isPromptOff(for mode: PromptMode) -> Bool {
        switch mode.normalized {
        case .dictate:
            return self.isDictationPromptOff
        case .edit, .write, .rewrite:
            return self.isEditPromptOff
        }
    }

    func setPromptOff(_ isOff: Bool, for mode: PromptMode) {
        switch mode.normalized {
        case .dictate:
            self.setDictationPromptSelection(isOff ? .off : .default)
        case .edit, .write, .rewrite:
            self.isEditPromptOff = isOff
        }
    }

    func selectedDictationPromptProfile(for slot: DictationShortcutSlot) -> DictationPromptProfile? {
        guard let id = self.selectedDictationPromptID(for: slot) else { return nil }
        return self.dictationPromptProfiles.first(where: { $0.id == id && $0.mode.normalized == .dictate })
    }

    func resolvedDictationPromptProfile(for slot: DictationShortcutSlot, appBundleID: String?) -> DictationPromptProfile? {
        switch self.dictationPromptSelection(for: slot) {
        case .off:
            return nil
        case .privateAI:
            return nil
        case let .profile(promptID):
            return self.dictationPromptProfiles.first(where: { $0.id == promptID && $0.mode.normalized == .dictate })
        case .default:
            guard let binding = self.appPromptBinding(for: .dictate, appBundleID: appBundleID) else { return nil }
            let promptID = binding.promptID
            return self.dictationPromptProfiles.first {
                $0.id == promptID && $0.mode.normalized == .dictate
            }
        }
    }

    func isAppDictationPromptBindingActive(for slot: DictationShortcutSlot, appBundleID: String?) -> Bool {
        guard !PrivateAIProviderPromptFormat.isAvailable(settings: self) else { return false }
        guard self.dictationPromptSelection(for: slot) == .default else { return false }
        return self.hasAppPromptBinding(for: .dictate, appBundleID: appBundleID)
    }

    func dictationPromptDisplayName(for slot: DictationShortcutSlot, appBundleID: String?) -> String {
        switch self.dictationPromptSelection(for: slot) {
        case .off:
            return "Off"
        case .default:
            if let profile = self.resolvedDictationPromptProfile(for: slot, appBundleID: appBundleID) {
                let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "Untitled" : name
            }
            return "Default"
        case .privateAI: return PrivateAIProviderFeature.displayName
        case let .profile(promptID):
            guard let profile = self.dictationPromptProfiles.first(where: { $0.id == promptID && $0.mode.normalized == .dictate }) else {
                return "Default"
            }
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled" : name
        }
    }

    func setSelectedPromptID(_ id: String?, for mode: PromptMode) {
        switch mode.normalized {
        case .dictate:
            if let id {
                self.setDictationPromptSelection(.profile(id))
            } else {
                self.setDictationPromptSelection(.default)
            }
        case .edit:
            self.isEditPromptOff = false
            self.selectedEditPromptID = id
        case .write, .rewrite:
            self.isEditPromptOff = false
            self.selectedEditPromptID = id
        }
    }

    func promptProfiles(for mode: PromptMode) -> [DictationPromptProfile] {
        let target = mode.normalized
        return self.dictationPromptProfiles.filter { $0.mode.normalized == target }
    }

    func selectedPromptProfile(for mode: PromptMode) -> DictationPromptProfile? {
        guard let id = self.selectedPromptID(for: mode) else { return nil }
        let target = mode.normalized
        return self.dictationPromptProfiles.first(where: { $0.id == id && $0.mode.normalized == target })
    }

    func appPromptBindings(for mode: PromptMode) -> [AppPromptBinding] {
        let target = mode.normalized
        return self.appPromptBindings.filter { $0.mode.normalized == target }
    }

    func appPromptBinding(for mode: PromptMode, appBundleID: String?) -> AppPromptBinding? {
        guard let normalizedBundleID = Self.normalizeAppBundleID(appBundleID) else { return nil }
        let target = mode.normalized
        return self.appPromptBindings.first {
            $0.mode.normalized == target &&
                $0.appBundleID == normalizedBundleID
        }
    }

    func hasAppPromptBinding(for mode: PromptMode, appBundleID: String?) -> Bool {
        self.appPromptBinding(for: mode, appBundleID: appBundleID) != nil
    }

    func upsertAppPromptBinding(
        for mode: PromptMode,
        appBundleID: String,
        appName: String,
        promptID: String?
    ) {
        guard let normalizedBundleID = Self.normalizeAppBundleID(appBundleID) else { return }

        let normalizedMode = mode.normalized
        let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? normalizedBundleID : trimmedName
        let cleanedPromptID = promptID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPromptID = (cleanedPromptID?.isEmpty == true) ? nil : cleanedPromptID
        let now = Date()

        var bindings = self.appPromptBindings
        if let idx = bindings.firstIndex(where: {
            $0.mode.normalized == normalizedMode &&
                $0.appBundleID == normalizedBundleID
        }) {
            bindings[idx].mode = normalizedMode
            bindings[idx].appName = resolvedName
            bindings[idx].promptID = resolvedPromptID
            bindings[idx].updatedAt = now
        } else {
            bindings.append(
                AppPromptBinding(
                    mode: normalizedMode,
                    appBundleID: normalizedBundleID,
                    appName: resolvedName,
                    promptID: resolvedPromptID,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        self.appPromptBindings = bindings
    }

    func removeAppPromptBinding(id: String) {
        var bindings = self.appPromptBindings
        bindings.removeAll { $0.id == id }
        self.appPromptBindings = bindings
    }

    func removeAppPromptBinding(for mode: PromptMode, appBundleID: String?) {
        guard let normalizedBundleID = Self.normalizeAppBundleID(appBundleID) else { return }
        let normalizedMode = mode.normalized
        var bindings = self.appPromptBindings
        bindings.removeAll {
            $0.mode.normalized == normalizedMode &&
                $0.appBundleID == normalizedBundleID
        }
        self.appPromptBindings = bindings
    }

    /// Re-run prompt/profile normalization after profile mutations.
    func reconcilePromptStateAfterProfileChanges() {
        self.normalizePromptSelectionsIfNeeded()
        self.normalizeDictationPromptConfigurationsIfNeeded()
    }

    private static func normalizeAppBundleID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// Optional override for the built-in default dictation system prompt.
    /// - nil: use the built-in default prompt
    /// - empty string: use an empty system prompt
    /// - otherwise: use the provided text as the default prompt
    var defaultDictationPromptOverride: String? {
        get {
            // Distinguish "not set" from "set to empty string"
            guard self.defaults.object(forKey: Keys.defaultDictationPromptOverride) != nil else {
                return nil
            }
            return self.defaults.string(forKey: Keys.defaultDictationPromptOverride) ?? ""
        }
        set {
            objectWillChange.send()
            if let value = newValue {
                self.defaults.set(value, forKey: Keys.defaultDictationPromptOverride) // allow empty
            } else {
                self.defaults.removeObject(forKey: Keys.defaultDictationPromptOverride)
            }
        }
    }

    /// Optional override for the built-in default edit system prompt.
    var defaultEditPromptOverride: String? {
        get {
            if self.defaults.object(forKey: Keys.defaultEditPromptOverride) != nil {
                return self.defaults.string(forKey: Keys.defaultEditPromptOverride) ?? ""
            }
            if self.defaults.object(forKey: Keys.defaultRewritePromptOverride) != nil {
                return self.defaults.string(forKey: Keys.defaultRewritePromptOverride) ?? ""
            }
            if self.defaults.object(forKey: Keys.defaultWritePromptOverride) != nil {
                return self.defaults.string(forKey: Keys.defaultWritePromptOverride) ?? ""
            }
            return nil
        }
        set {
            objectWillChange.send()
            if let value = newValue {
                self.defaults.set(value, forKey: Keys.defaultEditPromptOverride)
            } else {
                self.defaults.removeObject(forKey: Keys.defaultEditPromptOverride)
            }
            // Normalize to the new key only.
            self.defaults.removeObject(forKey: Keys.defaultWritePromptOverride)
            self.defaults.removeObject(forKey: Keys.defaultRewritePromptOverride)
        }
    }

    /// Legacy alias retained for compatibility.
    var defaultWritePromptOverride: String? {
        get { self.defaultEditPromptOverride }
        set { self.defaultEditPromptOverride = newValue }
    }

    /// Legacy alias retained for compatibility.
    var defaultRewritePromptOverride: String? {
        get { self.defaultEditPromptOverride }
        set { self.defaultEditPromptOverride = newValue }
    }

    func defaultPromptOverride(for mode: PromptMode) -> String? {
        switch mode.normalized {
        case .dictate:
            return self.defaultDictationPromptOverride
        case .edit:
            return self.defaultEditPromptOverride
        case .write, .rewrite:
            return self.defaultEditPromptOverride
        }
    }

    func setDefaultPromptOverride(_ value: String?, for mode: PromptMode) {
        switch mode.normalized {
        case .dictate:
            self.defaultDictationPromptOverride = value
        case .edit:
            self.defaultEditPromptOverride = value
        case .write, .rewrite:
            self.defaultEditPromptOverride = value
        }
    }

    /// Hidden base prompt: role/intent only (not exposed in UI).
    static func baseDictationPromptText() -> String {
        """
        You are a voice-to-text dictation cleaner. Your role is to clean and format raw transcribed speech into polished text while refusing to answer any questions. Never answer questions about yourself or anything else.

        ## Core Rules:
        1. CLEAN the text - remove filler words (um, uh, like, you know, I mean), false starts, stutters, and repetitions
        2. FORMAT properly - add correct punctuation, capitalization, and structure
        3. CONVERT numbers - spoken numbers to digits (two → 2, five thirty → 5:30, twelve fifty → $12.50)
        4. EXECUTE commands - handle "new line", "period", "comma", "bold X", "header X", "bullet point", etc.
        5. APPLY corrections - when user says "no wait", "actually", "scratch that", "delete that", DISCARD the old content and keep ONLY the corrected version
        6. PRESERVE intent - keep the user's meaning, just clean the delivery
        7. EXPAND abbreviations - thx → thanks, pls → please, u → you, ur → your/you're, gonna → going to

        ## Critical:
        - Output ONLY the cleaned text
        - Do NOT answer questions - just clean them
        - DO NOT EVER ANSWER TO QUESTIONS
        - Do NOT add explanations or commentary
        - Do NOT wrap in quotes unless the input had quotes
        - Do NOT add filler words (um, uh) to the output
        - PRESERVE ordinals in lists: "first call client, second review contract" → keep "First" and "Second"
        - PRESERVE politeness words: "please", "thank you" at end of sentences
        """
    }

    /// Hidden base prompt for edit mode (role/intent only).
    static func baseEditPromptText() -> String {
        """
        You are a helpful writing assistant. The user may ask you to write new text or edit selected text.

        Output ONLY what the user requested. Do not add explanations or preamble.
        """
    }

    /// Legacy wrappers retained for compatibility.
    static func baseWritePromptText() -> String {
        self.baseEditPromptText()
    }

    /// Legacy wrappers retained for compatibility.
    static func baseRewritePromptText() -> String {
        self.baseEditPromptText()
    }

    static func basePromptText(for mode: PromptMode) -> String {
        switch mode.normalized {
        case .dictate:
            return self.baseDictationPromptText()
        case .edit:
            return self.baseEditPromptText()
        case .write, .rewrite:
            return self.baseEditPromptText()
        }
    }

    /// Built-in default dictation prompt body that users may view/edit.
    static func defaultDictationPromptBodyText() -> String {
        """
        ## Self-Corrections:
        When user corrects themselves, DISCARD everything before the correction trigger:
        - Triggers: "no", "wait", "actually", "scratch that", "delete that", "no no", "cancel", "never mind", "sorry", "oops"
        - Example: "buy milk no wait buy water" → "Buy water." (NOT "Buy milk. Buy water.")
        - Example: "tell John no actually tell Sarah" → "Tell Sarah."
        - If correction cancels entirely: "send email no wait cancel that" → "" (empty)

        ## Multi-Command Chains:
        When multiple commands are chained, execute ALL of them in sequence:
        - "make X bold no wait make Y bold" → **Y** (correction + formatting)
        - "header shopping bullet milk no eggs" → # Shopping\n- Eggs (header + correction + bullet)
        - "the price is fifty no sixty dollars" → The price is $60. (correction + number)

        ## Emojis:
        - Convert spoken emoji names: "smiley face" → 😊 (NOT 😀), "thumbs up" → 👍, "heart emoji" → ❤️, "fire emoji" → 🔥
        - Keep emojis if user includes them
        - Do NOT add emojis unless user explicitly asks for them (e.g., "joke about cats" → NO 😺)
        """
    }

    /// Built-in default edit prompt body.
    static func defaultEditPromptBodyText() -> String {
        """
        Your job:
        - If the user asks for new content, write it directly.
        - If selected context is provided, apply the instruction to that context.
        - Preserve intent and requested tone/style/format.
        - Output only the final text, without explanations.

        Example requests:
        - "Write an email to my boss asking for time off"
        - "Draft a reply saying I'll be there at 5"
        - "Rewrite this to sound more professional"
        - "Make this shorter and clearer"
        """
    }

    /// Legacy wrappers retained for compatibility.
    static func defaultWritePromptBodyText() -> String {
        self.defaultEditPromptBodyText()
    }

    /// Legacy wrappers retained for compatibility.
    static func defaultRewritePromptBodyText() -> String {
        self.defaultEditPromptBodyText()
    }

    static func defaultPromptBodyText(for mode: PromptMode) -> String {
        switch mode.normalized {
        case .dictate:
            return self.defaultDictationPromptBodyText()
        case .edit:
            return self.defaultEditPromptBodyText()
        case .write, .rewrite:
            return self.defaultEditPromptBodyText()
        }
    }

    /// Join hidden base with a body, avoiding duplicate base text.
    static func combineBasePrompt(with body: String) -> String {
        self.combineBasePrompt(for: .dictate, with: body)
    }

    /// Join hidden base with a body for a given mode, avoiding duplicate base text.
    static func combineBasePrompt(for mode: PromptMode, with body: String) -> String {
        let base = self.basePromptText(for: mode).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // If body already starts with base, return as-is to avoid double-prepending.
        if trimmedBody.lowercased().hasPrefix(base.lowercased()) {
            return trimmedBody
        }

        // If body is empty, return just the base.
        guard !trimmedBody.isEmpty else { return base }

        return "\(base)\n\n\(trimmedBody)"
    }

    /// Remove the hidden base prompt prefix if it was persisted previously.
    static func stripBaseDictationPrompt(from text: String) -> String {
        self.stripBasePrompt(for: .dictate, from: text)
    }

    /// Remove a hidden base prompt prefix for a given mode if it was persisted previously.
    static func stripBasePrompt(for mode: PromptMode, from text: String) -> String {
        let base = self.basePromptText(for: mode).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try exact and case-insensitive prefix removal
        if trimmed.hasPrefix(base) {
            let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: base.count)
            return trimmed[bodyStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let range = trimmed.lowercased().range(of: base.lowercased()), range.lowerBound == trimmed.lowercased().startIndex {
            let idx = trimmed.index(trimmed.startIndex, offsetBy: base.count)
            return trimmed[idx...].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    /// Built-in default dictation system prompt shared across the app.
    static func defaultDictationPromptText() -> String {
        self.defaultSystemPromptText(for: .dictate)
    }

    static func defaultSystemPromptText(for mode: PromptMode) -> String {
        self.combineBasePrompt(for: mode, with: self.defaultPromptBodyText(for: mode))
    }

    static func contextTemplateText() -> String {
        """
        Use the following selected context to improve your response:
        {context}
        """
    }

    static func runtimeContextBlock(context: String, template: String) -> String {
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContext.isEmpty else { return "" }
        if template.contains("{context}") {
            return template.replacingOccurrences(of: "{context}", with: trimmedContext)
        }
        return "\(template)\n\(trimmedContext)"
    }

    func promptResolution(for mode: PromptMode, appBundleID: String? = nil) -> PromptResolution {
        let normalizedMode = mode.normalized

        if normalizedMode == .edit, self.isEditPromptOff {
            return self.defaultPromptResolution(
                for: normalizedMode,
                source: .builtInDefault,
                appBinding: nil,
                allowDefaultOverride: false
            )
        }

        if let binding = self.appPromptBinding(for: normalizedMode, appBundleID: appBundleID) {
            if let promptID = binding.promptID,
               let profile = self.dictationPromptProfiles.first(where: {
                   $0.id == promptID &&
                       $0.mode.normalized == normalizedMode
               })
            {
                let body = Self.stripBasePrompt(for: normalizedMode, from: profile.prompt)
                if !body.isEmpty {
                    return PromptResolution(
                        source: .appBindingProfile,
                        profile: profile,
                        appBinding: binding,
                        promptBody: body,
                        systemPrompt: Self.combineBasePrompt(for: normalizedMode, with: body)
                    )
                }
            }

            return self.defaultPromptResolution(
                for: normalizedMode,
                source: .appBindingDefault,
                appBinding: binding
            )
        }

        if self.promptRoutingScope(for: normalizedMode) == .selectedAppsOnly {
            return self.defaultPromptResolution(
                for: normalizedMode,
                source: .builtInDefault,
                appBinding: nil,
                allowDefaultOverride: false
            )
        }

        if let profile = self.selectedPromptProfile(for: normalizedMode) {
            let body = Self.stripBasePrompt(for: normalizedMode, from: profile.prompt)
            if !body.isEmpty {
                return PromptResolution(
                    source: .selectedProfile,
                    profile: profile,
                    appBinding: nil,
                    promptBody: body,
                    systemPrompt: Self.combineBasePrompt(for: normalizedMode, with: body)
                )
            }
        }

        return self.defaultPromptResolution(for: normalizedMode, source: .defaultOverride, appBinding: nil)
    }

    func resolvedPromptProfile(for mode: PromptMode, appBundleID: String? = nil) -> DictationPromptProfile? {
        self.promptResolution(for: mode, appBundleID: appBundleID).profile
    }

    func effectiveDictationPromptBody(for slot: DictationShortcutSlot, appBundleID: String? = nil) -> String {
        if self.promptRoutingScope(for: .dictate) == .selectedAppsOnly {
            guard self.dictationPromptSelection(for: slot) != .off else { return "" }
            return self.effectivePromptBody(for: .dictate, appBundleID: appBundleID)
        }

        switch self.dictationPromptSelection(for: slot) {
        case .off:
            return ""
        case .default, .privateAI:
            return self.effectivePromptBody(for: .dictate, appBundleID: appBundleID)
        case let .profile(promptID):
            guard let profile = self.dictationPromptProfiles.first(where: { $0.id == promptID && $0.mode.normalized == .dictate }) else {
                return self.effectivePromptBody(for: .dictate, appBundleID: appBundleID)
            }
            let body = Self.stripBasePrompt(for: .dictate, from: profile.prompt)
            if !body.isEmpty {
                return body
            }
            return self.effectivePromptBody(for: .dictate, appBundleID: appBundleID)
        }
    }

    func effectiveDictationSystemPrompt(for slot: DictationShortcutSlot, appBundleID: String? = nil) -> String {
        if self.promptRoutingScope(for: .dictate) == .selectedAppsOnly {
            guard self.dictationPromptSelection(for: slot) != .off else { return "" }
            return self.effectiveSystemPrompt(for: .dictate, appBundleID: appBundleID)
        }

        switch self.dictationPromptSelection(for: slot) {
        case .off, .default, .privateAI:
            return self.effectiveSystemPrompt(for: .dictate, appBundleID: appBundleID)
        case let .profile(promptID):
            guard let profile = self.dictationPromptProfiles.first(where: { $0.id == promptID && $0.mode.normalized == .dictate }) else {
                return self.effectiveSystemPrompt(for: .dictate, appBundleID: appBundleID)
            }
            let body = Self.stripBasePrompt(for: .dictate, from: profile.prompt)
            if !body.isEmpty {
                return Self.combineBasePrompt(for: .dictate, with: body)
            }
            return self.effectiveSystemPrompt(for: .dictate, appBundleID: appBundleID)
        }
    }

    func effectivePromptBody(for mode: PromptMode, appBundleID: String? = nil) -> String {
        self.promptResolution(for: mode, appBundleID: appBundleID).promptBody
    }

    func effectiveSystemPrompt(for mode: PromptMode, appBundleID: String? = nil) -> String {
        self.promptResolution(for: mode, appBundleID: appBundleID).systemPrompt
    }

    func effectivePromptSource(for mode: PromptMode, appBundleID: String? = nil) -> PromptResolutionSource {
        self.promptResolution(for: mode, appBundleID: appBundleID).source
    }

    /// Literal placeholder that gets substituted with the raw transcription
    /// when composing the user message for a dictation enhancement call.
    static let transcriptPlaceholder = "${transcript}"

    /// Compose the user-turn string for a dictation enhancement call by folding
    /// the transcript into the prompt template. If the template contains the
    /// `${transcript}` placeholder, the placeholder is replaced; otherwise
    /// the transcript is appended after a blank line, matching the pre-PR
    /// behaviour of sending the transcript as a separate user message.
    static func renderDictationUserMessage(promptText: String, transcript: String) -> String {
        if promptText.contains(self.transcriptPlaceholder) {
            return promptText.replacingOccurrences(of: self.transcriptPlaceholder, with: transcript)
        }
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty { return transcript }
        return promptText + "\n\n" + transcript
    }

    private func defaultPromptResolution(
        for mode: PromptMode,
        source: PromptResolutionSource,
        appBinding: AppPromptBinding?,
        allowDefaultOverride: Bool = true
    ) -> PromptResolution {
        if allowDefaultOverride, let override = self.defaultPromptOverride(for: mode) {
            let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOverride.isEmpty {
                return PromptResolution(
                    source: source,
                    profile: nil,
                    appBinding: appBinding,
                    promptBody: "",
                    systemPrompt: override
                )
            }

            let body = Self.stripBasePrompt(for: mode, from: trimmedOverride)
            return PromptResolution(
                source: source,
                profile: nil,
                appBinding: appBinding,
                promptBody: body,
                systemPrompt: Self.combineBasePrompt(for: mode, with: body)
            )
        }

        let defaultBody = Self.defaultPromptBodyText(for: mode)
        let fallbackSource: PromptResolutionSource = source == .defaultOverride ? .builtInDefault : source
        return PromptResolution(
            source: fallbackSource,
            profile: nil,
            appBinding: appBinding,
            promptBody: defaultBody,
            systemPrompt: Self.combineBasePrompt(for: mode, with: defaultBody)
        )
    }

    // MARK: - Model Reasoning Configuration

    /// Configuration for model-specific reasoning/thinking parameters
    struct ModelReasoningConfig: Codable, Equatable {
        /// The parameter name to use (e.g., "reasoning_effort", "enable_thinking", "thinking")
        var parameterName: String

        /// The value to use for the parameter (e.g., "low", "medium", "high", "none", "true")
        var parameterValue: String

        /// Whether this config is enabled (allows disabling without deleting)
        var isEnabled: Bool

        init(parameterName: String = "reasoning_effort", parameterValue: String = "low", isEnabled: Bool = true) {
            self.parameterName = parameterName
            self.parameterValue = parameterValue
            self.isEnabled = isEnabled
        }

        /// Common presets for different model types
        static let openAIGPT5 = ModelReasoningConfig(
            parameterName: "reasoning_effort",
            parameterValue: "low",
            isEnabled: true
        )
        static let openAIO1 = ModelReasoningConfig(
            parameterName: "reasoning_effort",
            parameterValue: "medium",
            isEnabled: true
        )
        static let groqGPTOSS = ModelReasoningConfig(
            parameterName: "reasoning_effort",
            parameterValue: "low",
            isEnabled: true
        )
        static let deepSeekReasoner = ModelReasoningConfig(
            parameterName: "enable_thinking",
            parameterValue: "true",
            isEnabled: true
        )
        static let disabled = ModelReasoningConfig(parameterName: "", parameterValue: "", isEnabled: false)
    }

    struct SavedProvider: Codable, Identifiable, Hashable {
        let id: String
        let name: String
        let baseURL: String
        let apiKey: String
        let models: [String]

        init(id: String = UUID().uuidString, name: String, baseURL: String, apiKey: String = "", models: [String] = []) {
            self.id = id
            self.name = name
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.models = models
        }
    }

    var enableAIProcessing: Bool {
        get { self.defaults.bool(forKey: Keys.enableAIProcessing) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableAIProcessing)
        }
    }

    /// Show the main window when macOS launches FluidVoice at login (default: ON, matching
    /// current behavior). When off, login launches boot silently in the menu bar. Manual
    /// launches always show the window. Default-true semantics so existing installs keep
    /// their current behavior.
    var showMainWindowAtLoginLaunch: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.showMainWindowAtLoginLaunch)
            if value == nil { return true }
            return self.defaults.bool(forKey: Keys.showMainWindowAtLoginLaunch)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.showMainWindowAtLoginLaunch)
        }
    }

    /// Anonymous analytics toggle (default: ON). Uses default-true semantics so existing installs
    /// upgrading to a version that includes analytics do not silently default to OFF.
    var shareAnonymousAnalytics: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.shareAnonymousAnalytics)
            if value == nil { return true }
            return self.defaults.bool(forKey: Keys.shareAnonymousAnalytics)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.shareAnonymousAnalytics)
        }
    }

    var privateAIInterestCaptured: Bool {
        get { self.defaults.bool(forKey: Keys.privateAIInterestCaptured) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.privateAIInterestCaptured)
        }
    }

    var availableModels: [String] {
        get { (self.defaults.array(forKey: Keys.availableAIModels) as? [String]) ?? [] }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.availableAIModels)
        }
    }

    var availableModelsByProvider: [String: [String]] {
        get { (self.defaults.dictionary(forKey: Keys.availableModelsByProvider) as? [String: [String]]) ?? [:] }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.availableModelsByProvider)
        }
    }

    var enableDebugLogs: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableDebugLogs)
            if value == nil { return true }
            return self.defaults.bool(forKey: Keys.enableDebugLogs)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableDebugLogs)
            DebugLogger.shared.refreshLoggingEnabled()
        }
    }

    private func ensureDebugLoggingDefaults() {
        if self.defaults.object(forKey: Keys.enableDebugLogs) == nil {
            self.defaults.set(true, forKey: Keys.enableDebugLogs)
        }
        DebugLogger.shared.refreshLoggingEnabled()
    }

    var selectedModel: String? {
        get { self.defaults.string(forKey: Keys.selectedAIModel) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.selectedAIModel)
        }
    }

    var selectedModelByProvider: [String: String] {
        get { (self.defaults.dictionary(forKey: Keys.selectedModelByProvider) as? [String: String]) ?? [:] }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.selectedModelByProvider)
        }
    }

    var providerAPIKeys: [String: String] {
        get { (try? self.keychain.fetchAllKeys()) ?? [:] }
        set {
            objectWillChange.send()
            do {
                _ = try self.saveProviderAPIKeys(newValue)
            } catch {
                self.logProviderAPIKeyPersistenceFailure(error)
            }
        }
    }

    @discardableResult
    func saveProviderAPIKeys(_ values: [String: String]) throws -> [String: String] {
        let trimmed = self.sanitizeAPIKeys(values)
        try self.keychain.storeAllKeys(trimmed)
        return try self.keychain.fetchAllKeys()
    }

    /// Securely retrieve API key for a provider, handling custom prefix logic
    func getAPIKey(for providerID: String) -> String? {
        let keys = self.providerAPIKeys
        // Try exact match first
        if let key = keys[providerID] { return key }

        // Try canonical key format (custom:ID)
        let canonical = self.canonicalProviderKey(for: providerID)
        return keys[canonical]
    }

    var selectedProviderID: String {
        get { self.availableSelectedProviderID(for: self.defaults.string(forKey: Keys.selectedProviderID)) }
        set {
            objectWillChange.send()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                self.defaults.removeObject(forKey: Keys.selectedProviderID)
            } else {
                self.defaults.set(trimmed, forKey: Keys.selectedProviderID)
            }
        }
    }

    /// No-op: never override the user's provider selection on launch.
    ///
    /// The per-prompt shortcut system means the global default provider is no longer the
    /// authoritative routing source — each shortcut can bind to its own provider/model, or be off.
    /// The only time we set a provider is during onboarding (Fluid Intelligence flow); after that
    /// the selection is sticky across restarts and updates. Default is off (empty).
    func normalizeProviderSelectionForCurrentVerificationState() {
        // Intentionally empty. Selection is sticky.
    }

    var privateAIPrefixKVCacheEnabled: Bool {
        get { self.defaults.object(forKey: PrivateAIProviderFeature.shared.prefixCacheDefaultsKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: PrivateAIProviderFeature.shared.prefixCacheDefaultsKey)
        }
    }

    var savedProviders: [SavedProvider] {
        get {
            guard let data = defaults.data(forKey: Keys.savedProviders),
                  let decoded = try? JSONDecoder().decode([SavedProvider].self, from: data) else { return [] }
            return decoded
        }
        set {
            objectWillChange.send()
            let sanitized = newValue.map { provider -> SavedProvider in
                if provider.apiKey.isEmpty { return provider }
                return SavedProvider(
                    id: provider.id,
                    name: provider.name,
                    baseURL: provider.baseURL,
                    apiKey: "",
                    models: provider.models
                )
            }
            if let encoded = try? JSONEncoder().encode(sanitized) {
                self.defaults.set(encoded, forKey: Keys.savedProviders)
            }
        }
    }

    /// Check if the current AI provider is fully configured (API key/baseURL + selected model)
    var isAIConfigured: Bool {
        let providerID = self.selectedProviderID

        // 1. Apple Intelligence is always considered configured
        if providerID == "apple-intelligence" { return true }

        // 2. Get base URL to check for local endpoints
        var baseURL = ""
        if let saved = self.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = saved.baseURL
        } else {
            baseURL = ModelRepository.shared.defaultBaseURL(for: providerID)
        }

        let isLocal = ModelRepository.shared.isLocalEndpoint(baseURL)

        // 3. Check for API key and selected model
        let key = self.canonicalProviderKey(for: providerID)
        let hasApiKey = !(self.providerAPIKeys[key]?.isEmpty ?? true)

        let selectedModel = self.selectedModelByProvider[key]
        let hasSelectedModel = !(selectedModel?.isEmpty ?? true)
        let hasDefaultModel = !ModelRepository.shared.defaultModels(for: providerID).isEmpty
        let hasModel = hasSelectedModel || hasDefaultModel

        return (isLocal || hasApiKey) && hasModel
    }

    /// The base URL for the currently selected AI provider
    var activeBaseURL: String {
        let providerID = self.selectedProviderID
        if let saved = self.savedProviders.first(where: { $0.id == providerID }) {
            return saved.baseURL
        }
        return ModelRepository.shared.defaultBaseURL(for: providerID)
    }

    var hotkeyShortcut: HotkeyShortcut {
        get {
            self.primaryDictationShortcuts.first ?? Self.defaultPrimaryDictationShortcut
        }
        set {
            objectWillChange.send()
            let shortcuts = Self.normalizedPrimaryDictationShortcuts([newValue], fallback: Self.defaultPrimaryDictationShortcut)
            self.storePrimaryDictationShortcuts(shortcuts)
            self.storeLegacyHotkeyShortcut(shortcuts[0])
        }
    }

    var primaryDictationShortcutDisplayString: String {
        let displays = self.primaryDictationShortcuts
            .map(\.displayString)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return displays.isEmpty ? Self.defaultPrimaryDictationShortcut.displayString : displays.joined(separator: " / ")
    }

    var primaryDictationShortcuts: [HotkeyShortcut] {
        get {
            let fallback = self.legacyHotkeyShortcut
            if let data = defaults.data(forKey: Keys.primaryDictationShortcutsKey),
               let shortcuts = try? JSONDecoder().decode([HotkeyShortcut].self, from: data)
            {
                return Self.normalizedPrimaryDictationShortcuts(shortcuts, fallback: fallback)
            }
            return [fallback]
        }
        set {
            objectWillChange.send()
            let shortcuts = Self.normalizedPrimaryDictationShortcuts(newValue, fallback: self.legacyHotkeyShortcut)
            self.storePrimaryDictationShortcuts(shortcuts)
            self.storeLegacyHotkeyShortcut(shortcuts[0])
        }
    }

    private static var defaultPrimaryDictationShortcut: HotkeyShortcut {
        HotkeyShortcut(keyCode: 61, modifierFlags: [])
    }

    private var legacyHotkeyShortcut: HotkeyShortcut {
        if let data = defaults.data(forKey: Keys.hotkeyShortcutKey),
           let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
        {
            return shortcut
        }
        return Self.defaultPrimaryDictationShortcut
    }

    private static func normalizedPrimaryDictationShortcuts(
        _ shortcuts: [HotkeyShortcut],
        fallback: HotkeyShortcut
    ) -> [HotkeyShortcut] {
        var unique: [HotkeyShortcut] = []
        for shortcut in shortcuts where !unique.contains(shortcut) {
            unique.append(shortcut)
        }
        if unique.isEmpty {
            unique.append(fallback)
        }
        return unique
    }

    private func storePrimaryDictationShortcuts(_ shortcuts: [HotkeyShortcut]) {
        if let data = try? JSONEncoder().encode(shortcuts) {
            self.defaults.set(data, forKey: Keys.primaryDictationShortcutsKey)
        }
    }

    private func storeLegacyHotkeyShortcut(_ shortcut: HotkeyShortcut) {
        if let data = try? JSONEncoder().encode(shortcut) {
            self.defaults.set(data, forKey: Keys.hotkeyShortcutKey)
        }
    }

    var pressAndHoldMode: Bool {
        get { self.defaults.object(forKey: Keys.hotkeyMode) != nil ? self.hotkeyMode == .hold : self.defaults.bool(forKey: Keys.pressAndHoldMode) } set { self.hotkeyMode = newValue ? .hold : .toggle }
    }

    var hotkeyMode: HotkeyActivationMode {
        get { self.defaults.string(forKey: Keys.hotkeyMode).flatMap(HotkeyActivationMode.init(rawValue:)) ?? (self.defaults.bool(forKey: Keys.pressAndHoldMode) ? .hold : .toggle) }
        set { objectWillChange.send(); self.defaults.set(newValue.rawValue, forKey: Keys.hotkeyMode); self.defaults.set(newValue == .hold, forKey: Keys.pressAndHoldMode) }
    }

    var enableStreamingPreview: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableStreamingPreview)
            return value as? Bool ?? true // Default to true (enabled)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableStreamingPreview)
        }
    }

    var enableAIStreaming: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableAIStreaming)
            return value as? Bool ?? true // Default to true (enabled)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableAIStreaming)
        }
    }

    var parakeetFinalizationMode: ParakeetFinalizationMode {
        get {
            self.defaults.string(forKey: Keys.parakeetFinalizationMode).flatMap(ParakeetFinalizationMode.init(rawValue:)) ?? .stableFullFinal
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.parakeetFinalizationMode)
        }
    }

    var copyTranscriptionToClipboard: Bool {
        get { self.defaults.bool(forKey: Keys.copyTranscriptionToClipboard) }
        set { self.defaults.set(newValue, forKey: Keys.copyTranscriptionToClipboard) }
    }

    var preferredInputDeviceUID: String? {
        get { self.defaults.string(forKey: Keys.preferredInputDeviceUID) }
        set { self.defaults.set(newValue, forKey: Keys.preferredInputDeviceUID) }
    }

    var preferredOutputDeviceUID: String? {
        get { self.defaults.string(forKey: Keys.preferredOutputDeviceUID) }
        set { self.defaults.set(newValue, forKey: Keys.preferredOutputDeviceUID) }
    }

    /// When enabled, changing audio devices in FluidVoice will also update macOS system audio settings.
    /// ALWAYS TRUE: Independent mode removed due to CoreAudio aggregate device limitations (OSStatus -10851)
    var syncAudioDevicesWithSystem: Bool {
        get {
            // Always return true - independent mode doesn't work for Bluetooth/aggregate devices
            return true
        }
        set {
            // No-op: sync mode is always enabled
            // Kept for backward compatibility but value is ignored
            _ = newValue
        }
    }

    var visualizerNoiseThreshold: Double {
        get {
            let value = self.defaults.double(forKey: Keys.visualizerNoiseThreshold)
            return value == 0.0 ? 0.4 : value // Default to 0.4 if not set
        }
        set {
            // Clamp between 0.0 and 0.95 to avoid division by zero issues in visualizers
            let clamped = max(min(newValue, 0.95), 0.0)
            self.defaults.set(clamped, forKey: Keys.visualizerNoiseThreshold)
        }
    }

    // MARK: - Overlay Position

    /// Size options for the recording overlay
    enum OverlaySize: String, CaseIterable, Codable {
        case pill
        case small
        case medium
        case large

        var displayName: String {
            switch self {
            case .pill: return "Pill"
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    /// Position options for the recording overlay
    enum OverlayPosition: String, CaseIterable, Codable {
        case top // Top of screen (notch area or floating)
        case bottom // Bottom of screen

        var displayName: String {
            switch self {
            case .top: return "Top of Screen"
            case .bottom: return "Bottom of Screen"
            }
        }
    }

    /// Internal presentation modes for the top notch overlay.
    /// This is intentionally separate from bottom overlay sizing.
    enum NotchPresentationMode: String, CaseIterable, Codable {
        case standard
        case minimal

        var displayName: String {
            switch self {
            case .standard:
                return "Standard Notch"
            case .minimal:
                return "Compact"
            }
        }
    }

    /// Where the recording overlay appears (default: bottom)
    var overlayPosition: OverlayPosition {
        get {
            guard let raw = self.defaults.string(forKey: Keys.overlayPosition),
                  let position = OverlayPosition(rawValue: raw)
            else {
                return .bottom // Default to bottom (menu overlay)
            }
            return position
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.overlayPosition)
        }
    }

    /// Internal-only top notch presentation mode. No public settings UI yet.
    var notchPresentationMode: NotchPresentationMode {
        get {
            guard let raw = self.defaults.string(forKey: Keys.notchPresentationMode),
                  let mode = NotchPresentationMode(rawValue: raw)
            else {
                return .standard
            }
            return mode
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.notchPresentationMode)
        }
    }

    /// Vertical offset for the bottom overlay (distance from bottom of screen/dock)
    var overlayBottomOffset: Double {
        get {
            let value = self.defaults.double(forKey: Keys.overlayBottomOffset)
            return value == 0.0 ? 50.0 : value // Default to 50.0
        }
        set {
            objectWillChange.send()
            // Clamp between a safe range (20px to 1000px)
            // Even though slider is 20-500, we clamp for safety
            let clamped = max(min(newValue, 1000.0), 10.0)
            self.defaults.set(clamped, forKey: Keys.overlayBottomOffset)

            // Post notification for live update if overlay is visible
            NotificationCenter.default.post(name: NSNotification.Name("OverlayOffsetChanged"), object: nil)
        }
    }

    /// The size of the recording overlay (default: medium)
    var overlaySize: OverlaySize {
        get {
            guard let raw = self.defaults.string(forKey: Keys.overlaySize),
                  let size = OverlaySize(rawValue: raw)
            else {
                return .medium // Default to medium
            }
            return size
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.overlaySize)

            // Post notification for live update if overlay is visible
            NotificationCenter.default.post(name: NSNotification.Name("OverlaySizeChanged"), object: nil)
        }
    }

    /// How many recent transcription characters show in overlays (default: 150)
    var transcriptionPreviewCharLimit: Int {
        get {
            let stored = self.defaults.object(forKey: Keys.transcriptionPreviewCharLimit) as? NSNumber
            let value = stored?.intValue ?? Self.defaultTranscriptionPreviewCharLimit
            return Self.normalizedTranscriptionPreviewCharLimit(value)
        }
        set {
            let clamped = Self.normalizedTranscriptionPreviewCharLimit(newValue)
            guard clamped != self.transcriptionPreviewCharLimit else { return }

            objectWillChange.send()
            self.defaults.set(clamped, forKey: Keys.transcriptionPreviewCharLimit)
            NotificationCenter.default.post(
                name: NSNotification.Name("TranscriptionPreviewCharLimitChanged"),
                object: nil
            )
        }
    }

    private static func normalizedTranscriptionPreviewCharLimit(_ value: Int) -> Int {
        let range = Self.transcriptionPreviewCharLimitRange
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        let offset = clamped - range.lowerBound
        let snappedOffset = Int((Double(offset) / Double(Self.transcriptionPreviewCharLimitStep)).rounded())
            * Self.transcriptionPreviewCharLimitStep
        return max(range.lowerBound, min(range.upperBound, range.lowerBound + snappedOffset))
    }

    // MARK: - Preferences Settings

    enum AccentColorOption: String, CaseIterable, Identifiable, Codable {
        case cyan = "Cyan"
        case green = "Green"
        case blue = "Blue"
        case purple = "Purple"
        case orange = "Orange"

        var id: String {
            self.rawValue
        }

        var hex: String {
            switch self {
            case .cyan: return "#3AC8C6"
            case .green: return "#22C55E"
            case .blue: return "#3B82F6"
            case .purple: return "#A855F7"
            case .orange: return "#F59E0B"
            }
        }
    }

    enum ThemePreference: String, CaseIterable, Identifiable, Codable {
        case system
        case light
        case dark

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var systemImageName: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }

        var preferredColorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    enum TranscriptionStartSound: String, CaseIterable, Identifiable, Codable {
        case none
        case fluidSfx0 = "fluid_sfx_0"
        case fluidSfx1 = "fluid_sfx_1"
        case fluidSfx2 = "fluid_sfx_2"
        case fluidSfx3 = "fluid_sfx_3"
        case fluidSfx4 = "fluid_sfx_4"

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .none: return "None"
            case .fluidSfx0: return "Fluid SFX 0"
            case .fluidSfx1: return "Fluid SFX 1"
            case .fluidSfx2: return "Fluid SFX 2"
            case .fluidSfx3: return "Fluid SFX 3"
            case .fluidSfx4: return "Fluid SFX 4"
            }
        }

        var startSoundFileName: String? {
            switch self {
            case .none: return nil
            case .fluidSfx0: return "FV_start_0"
            case .fluidSfx1: return "FV_start"
            case .fluidSfx2: return "FV_start_2"
            case .fluidSfx3: return "sfx_3"
            case .fluidSfx4: return "sfx_4"
            }
        }

        var stopSoundFileName: String? {
            switch self {
            case .fluidSfx0: return "FV_end_0"
            case .none, .fluidSfx1, .fluidSfx2, .fluidSfx3, .fluidSfx4: return nil
            }
        }
    }

    var accentColorOption: AccentColorOption {
        get {
            guard let raw = self.defaults.string(forKey: Keys.accentColorOption),
                  let option = AccentColorOption(rawValue: raw)
            else {
                return .cyan
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.accentColorOption)
        }
    }

    var accentColor: Color {
        Color(hex: self.accentColorOption.hex) ?? Color(red: 0.227, green: 0.784, blue: 0.776)
    }

    var themePreference: ThemePreference {
        get {
            guard let raw = self.defaults.string(forKey: Keys.themePreference),
                  let preference = ThemePreference(rawValue: raw)
            else {
                return .system
            }
            return preference
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.themePreference)
        }
    }

    var enableTranscriptionSounds: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.enableTranscriptionSounds)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.enableTranscriptionSounds)
        }
    }

    var transcriptionSoundVolume: Float {
        get {
            let value = self.defaults.object(forKey: Keys.transcriptionSoundVolume)
            return (value as? Float) ?? 1.0
        }
        set {
            objectWillChange.send()
            let clamped = max(0.0, min(1.0, newValue))
            self.defaults.set(clamped, forKey: Keys.transcriptionSoundVolume)
        }
    }

    var transcriptionSoundIndependentVolume: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.transcriptionSoundIndependentVolume)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.transcriptionSoundIndependentVolume)
        }
    }

    var transcriptionStartSound: TranscriptionStartSound {
        get {
            self.migrateTranscriptionStartSoundIfNeeded()
            guard let raw = self.defaults.string(forKey: Keys.transcriptionStartSound),
                  let option = TranscriptionStartSound(rawValue: raw)
            else {
                return .fluidSfx0
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.transcriptionStartSound)
        }
    }

    var launchAtStartup: Bool {
        get { self.launchAtStartupEnabled }
        set {
            self.setLaunchAtStartup(newValue)
        }
    }

    func applyLaunchAtStartupStatus(enabled: Bool, statusMessage: String, errorMessage: String?) {
        objectWillChange.send()
        self.launchAtStartupEnabled = enabled
        self.launchAtStartupStatusMessage = statusMessage
        self.launchAtStartupErrorMessage = errorMessage
    }

    func applyLaunchAtStartupErrorMessage(_ message: String?) {
        objectWillChange.send()
        self.launchAtStartupErrorMessage = message
    }

    // MARK: - Initialization Methods

    func initializeAppSettings() {
        #if os(macOS)
        self.refreshLaunchAtStartupStatus(clearError: true)

        // Apply dock visibility setting on app launch
        let dockVisible = self.showInDock
        DebugLogger.shared.info("Initializing app with dock visibility: \(dockVisible)", source: "SettingsStore")

        // Set activation policy based on saved preference
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(dockVisible ? .regular : .accessory)
        }
        #endif
    }

    var showInDock: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.showInDock)
            return value as? Bool ?? true // Default to true if not set
        }
        set {
            self.defaults.set(newValue, forKey: Keys.showInDock)
            // Update dock visibility
            self.updateDockVisibility(newValue)
        }
    }

    /// Issue #162 wording: hide app from Dock and Cmd+Tab when enabled.
    /// Backed by existing `showInDock` storage to keep this change minimal.
    var hideFromDockAndAppSwitcher: Bool {
        get { !self.showInDock }
        set { self.showInDock = !newValue }
    }

    var autoUpdateCheckEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.autoUpdateCheckEnabled)
            return value as? Bool ?? true // Default to enabled
        }
        set {
            self.defaults.set(newValue, forKey: Keys.autoUpdateCheckEnabled)
        }
    }

    var lastUpdateCheckDate: Date? {
        get {
            return self.defaults.object(forKey: Keys.lastUpdateCheckDate) as? Date
        }
        set {
            self.defaults.set(newValue, forKey: Keys.lastUpdateCheckDate)
        }
    }

    // MARK: - Update Check Helper

    func shouldCheckForUpdates() -> Bool {
        guard self.autoUpdateCheckEnabled else { return false }

        guard let lastCheck = lastUpdateCheckDate else {
            // Never checked before, should check
            return true
        }

        // Check if more than 1 hour has passed
        let hourInSeconds: TimeInterval = 60 * 60
        return Date().timeIntervalSince(lastCheck) >= hourInSeconds
    }

    func updateLastCheckDate() {
        self.lastUpdateCheckDate = Date()
    }

    // MARK: - Update Prompt Snooze

    /// Date until which update prompts are snoozed (user clicked "Later")
    var updatePromptSnoozedUntil: Date? {
        get { self.defaults.object(forKey: Keys.updatePromptSnoozedUntil) as? Date }
        set { self.defaults.set(newValue, forKey: Keys.updatePromptSnoozedUntil) }
    }

    /// The version that was snoozed (to allow prompting for newer versions)
    var snoozedUpdateVersion: String? {
        get { self.defaults.string(forKey: Keys.snoozedUpdateVersion) }
        set { self.defaults.set(newValue, forKey: Keys.snoozedUpdateVersion) }
    }

    /// Check if we should show the update prompt for a given version
    /// Returns false if user snoozed this version within the last 24 hours
    func shouldShowUpdatePrompt(forVersion version: String) -> Bool {
        // If a different (newer) version is available, always show
        if let snoozedVersion = snoozedUpdateVersion, snoozedVersion != version {
            return true
        }

        // Check if snooze period has expired
        guard let snoozedUntil = updatePromptSnoozedUntil else {
            return true // Never snoozed, show prompt
        }

        return Date() >= snoozedUntil
    }

    /// Snooze update prompts for 24 hours for the given version
    func snoozeUpdatePrompt(forVersion version: String) {
        let snoozeUntil = Date().addingTimeInterval(24 * 60 * 60) // 24 hours
        self.updatePromptSnoozedUntil = snoozeUntil
        self.snoozedUpdateVersion = version
        DebugLogger.shared.info("Update prompt snoozed for version \(version) until \(snoozeUntil)", source: "SettingsStore")
    }

    /// Clear the snooze (e.g., when update is installed)
    func clearUpdateSnooze() {
        self.updatePromptSnoozedUntil = nil
        self.snoozedUpdateVersion = nil
    }

    var playgroundUsed: Bool {
        get { self.defaults.bool(forKey: Keys.playgroundUsed) }
        set { self.defaults.set(newValue, forKey: Keys.playgroundUsed) }
    }

    /// Bump this when shipping a version that should force all users (new + existing) through
    /// onboarding again. The user's stored generation is compared on init; if it's below this
    /// value, onboarding is reset. Each forced ship increments this by 1.
    private static let currentOnboardingGeneration: Int = 2

    /// Force onboarding reset for users whose stored generation is below the current one.
    /// Called during init() so it takes effect before any UI decision.
    private func enforceOnboardingGenerationIfNeeded() {
        let storedGeneration = self.defaults.integer(forKey: Keys.onboardingGeneration)
        guard storedGeneration < Self.currentOnboardingGeneration else { return }

        // Reset onboarding state and bump the stored generation so this is a one-time reset.
        objectWillChange.send()
        self.defaults.set(false, forKey: Keys.onboardingCompleted)
        self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
        self.defaults.set(false, forKey: Keys.onboardingAISkipped)
        self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
        self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
        self.defaults.set(Self.currentOnboardingGeneration, forKey: Keys.onboardingGeneration)
    }

    var onboardingCompleted: Bool {
        get {
            if self.defaults.object(forKey: Keys.onboardingCompleted) == nil {
                return true
            }
            return self.defaults.bool(forKey: Keys.onboardingCompleted)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingCompleted)
            if newValue {
                self.defaults.set(Self.currentOnboardingGeneration, forKey: Keys.onboardingGeneration)
            }
        }
    }

    var onboardingCurrentStep: Int {
        get {
            let raw = self.defaults.integer(forKey: Keys.onboardingCurrentStep)
            return max(0, min(5, raw))
        }
        set {
            objectWillChange.send()
            let clamped = max(0, min(5, newValue))
            self.defaults.set(clamped, forKey: Keys.onboardingCurrentStep)
        }
    }

    var onboardingAISkipped: Bool {
        get { self.defaults.bool(forKey: Keys.onboardingAISkipped) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingAISkipped)
        }
    }

    var onboardingPlaygroundValidated: Bool {
        get { self.defaults.bool(forKey: Keys.onboardingPlaygroundValidated) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingPlaygroundValidated)
        }
    }

    var onboardingPlaygroundSkipped: Bool {
        get { self.defaults.bool(forKey: Keys.onboardingPlaygroundSkipped) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.onboardingPlaygroundSkipped)
        }
    }

    var onboardingSelectedLanguageID: String {
        get {
            let stored = self.defaults.string(forKey: Keys.onboardingSelectedLanguageID)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty {
                return stored
            }
            return "en"
        }
        set {
            objectWillChange.send()
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.defaults.set(normalized.isEmpty ? "en" : normalized, forKey: Keys.onboardingSelectedLanguageID)
        }
    }

    var selectedAppleSpeechLocaleIdentifier: String {
        get {
            let stored = self.defaults.string(forKey: Keys.selectedAppleSpeechLocaleIdentifier)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty {
                return stored
            }
            return Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        }
        set {
            objectWillChange.send()
            let normalized = newValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
            self.defaults.set(normalized.isEmpty ? "en-US" : normalized, forKey: Keys.selectedAppleSpeechLocaleIdentifier)
        }
    }

    var selectedAppleSpeechLocale: Locale {
        Locale(identifier: self.selectedAppleSpeechLocaleIdentifier)
    }

    var shouldShowOnboarding: Bool {
        !self.onboardingCompleted
    }

    var shouldPromptAccessibilityOnLaunch: Bool {
        !self.shouldShowOnboarding
    }

    func bootstrapOnboardingState(isTrueFirstOpen: Bool) {
        guard self.defaults.object(forKey: Keys.onboardingCompleted) == nil else { return }

        objectWillChange.send()

        let hasLegacyUsageSignals = self.hasLegacyUsageSignals()
        let shouldShowForThisInstall = isTrueFirstOpen && !hasLegacyUsageSignals

        if shouldShowForThisInstall {
            self.defaults.set(false, forKey: Keys.onboardingCompleted)
            self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
            self.defaults.set(false, forKey: Keys.onboardingAISkipped)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
            self.defaults.set("en", forKey: Keys.onboardingSelectedLanguageID)
        } else {
            self.defaults.set(true, forKey: Keys.onboardingCompleted)
            self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
            self.defaults.set(false, forKey: Keys.onboardingAISkipped)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
            self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
            self.defaults.set("en", forKey: Keys.onboardingSelectedLanguageID)
        }
    }

    func resetOnboardingProgress() {
        objectWillChange.send()
        self.defaults.set(false, forKey: Keys.onboardingCompleted)
        self.defaults.set(Self.currentOnboardingGeneration, forKey: Keys.onboardingGeneration)
        self.defaults.set(0, forKey: Keys.onboardingCurrentStep)
        self.defaults.set(false, forKey: Keys.onboardingAISkipped)
        self.defaults.set(false, forKey: Keys.onboardingPlaygroundValidated)
        self.defaults.set(false, forKey: Keys.onboardingPlaygroundSkipped)
        self.defaults.set("en", forKey: Keys.onboardingSelectedLanguageID)
        self.defaults.set(false, forKey: Keys.playgroundUsed)
    }

    private func hasLegacyUsageSignals() -> Bool {
        if self.defaults.object(forKey: Keys.playgroundUsed) != nil { return true }
        if self.defaults.object(forKey: Keys.hotkeyShortcutKey) != nil { return true }
        if self.defaults.object(forKey: Keys.primaryDictationShortcutsKey) != nil { return true }
        if let rawSpeechModel = self.defaults.string(forKey: Keys.selectedSpeechModel),
           rawSpeechModel != SpeechModel.defaultModel.rawValue
        {
            return true
        }
        if self.defaults.object(forKey: Keys.selectedProviderID) != nil { return true }
        if self.defaults.object(forKey: Keys.customDictionaryEntries) != nil { return true }
        if !self.savedProviders.isEmpty { return true }
        return false
    }

    // MARK: - Command Mode Settings

    var commandModeSelectedModel: String? {
        get { self.defaults.string(forKey: Keys.commandModeSelectedModel) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.commandModeSelectedModel)
        }
    }

    var commandModeSelectedProviderID: String {
        get { self.defaults.string(forKey: Keys.commandModeSelectedProviderID) ?? "" }
        set {
            objectWillChange.send()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                self.defaults.removeObject(forKey: Keys.commandModeSelectedProviderID)
            } else {
                self.defaults.set(trimmed, forKey: Keys.commandModeSelectedProviderID)
            }
        }
    }

    // MARK: - Prompt Mode Settings (Transcribe with Prompt)

    var promptModeShortcutEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.promptModeShortcutEnabled)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.promptModeShortcutEnabled)
        }
    }

    var promptModeHotkeyShortcut: HotkeyShortcut {
        get {
            if let data = defaults.data(forKey: Keys.promptModeHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            // Default to Right Shift key (keyCode: 60, no modifiers) — avoids conflict with Command Mode (Right Command, keyCode 54)
            return HotkeyShortcut(keyCode: 60, modifierFlags: [])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.promptModeHotkeyShortcut)
            }
        }
    }

    var promptModeSelectedPromptID: String? {
        get {
            let value = self.defaults.string(forKey: Keys.promptModeSelectedPromptID)
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : value
        }
        set {
            objectWillChange.send()
            if let id = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                self.defaults.set(id, forKey: Keys.promptModeSelectedPromptID)
            } else {
                self.defaults.removeObject(forKey: Keys.promptModeSelectedPromptID)
            }
        }
    }

    var isSecondaryDictationPromptOff: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.secondaryDictationPromptOff)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.secondaryDictationPromptOff)
        }
    }

    var commandModeShortcutEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.commandModeShortcutEnabled)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.commandModeShortcutEnabled)
        }
    }

    var commandModeHotkeyShortcut: HotkeyShortcut {
        get {
            if let data = defaults.data(forKey: Keys.commandModeHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            // Default to Right Command key (keyCode: 54, no modifiers for the key itself)
            return HotkeyShortcut(keyCode: 54, modifierFlags: [])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.commandModeHotkeyShortcut)
            }
        }
    }

    var cancelRecordingHotkeyShortcut: HotkeyShortcut {
        get {
            if let data = defaults.data(forKey: Keys.cancelRecordingHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            return HotkeyShortcut(keyCode: 53, modifierFlags: [])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.cancelRecordingHotkeyShortcut)
            }
        }
    }

    var commandModeConfirmBeforeExecute: Bool {
        get {
            // Default to true (safer - ask before running commands)
            let value = self.defaults.object(forKey: Keys.commandModeConfirmBeforeExecute)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.commandModeConfirmBeforeExecute)
        }
    }

    // MARK: - Rewrite Mode Settings

    var rewriteModeHotkeyShortcut: HotkeyShortcut {
        get {
            if let data = defaults.data(forKey: Keys.rewriteModeHotkeyShortcut),
               let shortcut = try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
            {
                return shortcut
            }
            // Default to Option+R (keyCode: 15 is R, with Option modifier)
            return HotkeyShortcut(keyCode: 15, modifierFlags: [.option])
        }
        set {
            objectWillChange.send()
            if let data = try? JSONEncoder().encode(newValue) {
                self.defaults.set(data, forKey: Keys.rewriteModeHotkeyShortcut)
            }
        }
    }

    var rewriteModeSelectedModel: String? {
        get { self.defaults.string(forKey: Keys.rewriteModeSelectedModel) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.rewriteModeSelectedModel)
        }
    }

    var rewriteModeSelectedProviderID: String {
        get { self.defaults.string(forKey: Keys.rewriteModeSelectedProviderID) ?? "" }
        set {
            objectWillChange.send()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                self.defaults.removeObject(forKey: Keys.rewriteModeSelectedProviderID)
            } else {
                self.defaults.set(trimmed, forKey: Keys.rewriteModeSelectedProviderID)
            }
        }
    }

    var rewriteModeLinkedToGlobal: Bool {
        get {
            // Default to true - sync with global settings by default
            let value = self.defaults.object(forKey: Keys.rewriteModeLinkedToGlobal)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.rewriteModeLinkedToGlobal)
        }
    }

    // MARK: - Model Reasoning Configuration

    /// Per-model reasoning configuration storage
    /// Key format: "provider:model" (e.g., "openai:gpt-5.1", "groq:gpt-oss-120b")
    var modelReasoningConfigs: [String: ModelReasoningConfig] {
        get {
            guard let data = defaults.data(forKey: Keys.modelReasoningConfigs),
                  let decoded = try? JSONDecoder().decode([String: ModelReasoningConfig].self, from: data)
            else {
                return [:]
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.modelReasoningConfigs)
            }
        }
    }

    /// Get reasoning config for a specific model, with smart defaults for known models
    func getReasoningConfig(forModel model: String, provider: String) -> ModelReasoningConfig? {
        let key = "\(provider):\(model)"

        // First check if user has a custom config
        if let customConfig = modelReasoningConfigs[key] {
            return customConfig.isEnabled ? customConfig : nil
        }

        // Apply smart defaults for known model patterns
        let modelLower = model.lowercased()

        // OpenAI gpt-5.x models
        if modelLower.hasPrefix("gpt-5") || modelLower.contains("gpt-5.") {
            return .openAIGPT5
        }

        // OpenAI o-series reasoning models
        if modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") || modelLower.hasPrefix("o4") {
            return .openAIO1
        }

        // Groq gpt-oss models
        if modelLower.contains("gpt-oss") || modelLower.hasPrefix("openai/") {
            return .groqGPTOSS
        }

        // DeepSeek reasoner models
        if modelLower.contains("deepseek"), modelLower.contains("reasoner") {
            return .deepSeekReasoner
        }

        // No reasoning config needed for standard models (gpt-4.x, claude, llama, etc.)
        return nil
    }

    /// Set reasoning config for a specific model
    func setReasoningConfig(_ config: ModelReasoningConfig?, forModel model: String, provider: String) {
        let key = "\(provider):\(model)"
        var configs = self.modelReasoningConfigs

        if let config = config {
            configs[key] = config
        } else {
            configs.removeValue(forKey: key)
        }

        self.modelReasoningConfigs = configs
    }

    /// Check if a model has a custom (user-defined) reasoning config
    func hasCustomReasoningConfig(forModel model: String, provider: String) -> Bool {
        let key = "\(provider):\(model)"
        return self.modelReasoningConfigs[key] != nil
    }

    var rewriteModeShortcutEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.rewriteModeShortcutEnabled)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.rewriteModeShortcutEnabled)
        }
    }

    /// Global check if a model is a reasoning model (requires special params/max_completion_tokens)
    func isReasoningModel(_ model: String) -> Bool {
        let modelLower = model.lowercased()
        return modelLower.hasPrefix("gpt-5") ||
            modelLower.contains("gpt-5.") ||
            modelLower.hasPrefix("o1") ||
            modelLower.hasPrefix("o3") ||
            modelLower.hasPrefix("o4") ||
            modelLower.contains("gpt-oss") ||
            modelLower.hasPrefix("openai/") ||
            (modelLower.contains("deepseek") && modelLower.contains("reasoner"))
    }

    /// Whether the model rejects the `temperature` parameter.
    /// Covers reasoning models plus Anthropic models that have deprecated temperature
    /// (Claude Opus 4.7+, which use extended thinking by default).
    func isTemperatureUnsupported(_ model: String) -> Bool {
        if self.isReasoningModel(model) { return true }
        let modelLower = model.lowercased()
        return modelLower.contains("claude-opus-4-7")
    }

    /// Whether to display thinking tokens in the UI (Command Mode, Rewrite Mode)
    /// If false, thinking tokens are extracted but not shown to user
    var showThinkingTokens: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.showThinkingTokens)
            return value as? Bool ?? true // Default to true (show thinking)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.showThinkingTokens)
        }
    }

    /// Stored verification fingerprints per provider key (hash of baseURL + apiKey).
    var verifiedProviderFingerprints: [String: String] {
        get {
            guard let data = self.defaults.data(forKey: Keys.verifiedProviderFingerprints),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            else {
                return [:]
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.verifiedProviderFingerprints)
            } else {
                self.defaults.removeObject(forKey: Keys.verifiedProviderFingerprints)
            }
        }
    }

    // MARK: - Stats Settings

    /// User's typing speed in words per minute (for time saved calculation)
    var userTypingWPM: Int {
        get {
            let value = self.defaults.integer(forKey: Keys.userTypingWPM)
            return value > 0 ? value : 40 // Default to 40 WPM
        }
        set {
            objectWillChange.send()
            self.defaults.set(max(1, min(200, newValue)), forKey: Keys.userTypingWPM) // Clamp 1-200
        }
    }

    /// When enabled, weekends (Saturday/Sunday) don't break the usage streak
    var weekendsDontBreakStreak: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.weekendsDontBreakStreak)
            return value as? Bool ?? true // Default to true (weekends don't break streak)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.weekendsDontBreakStreak)
        }
    }

    // MARK: - Custom Dictation Prompt

    /// Custom system prompt for dictation mode. When empty, uses the default built-in prompt.
    var customDictationPrompt: String {
        get { self.defaults.string(forKey: Keys.customDictationPrompt) ?? "" }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.customDictationPrompt)
        }
    }

    /// Whether to save transcription history for stats tracking
    /// When disabled, transcriptions are not stored and stats won't update
    var saveTranscriptionHistory: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.saveTranscriptionHistory)
            return value as? Bool ?? true // Default to true (save history)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.saveTranscriptionHistory)
        }
    }

    /// Stores actual microphone audio locally alongside dictation history.
    var saveAudioWithTranscriptionHistory: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.saveAudioWithTranscriptionHistory)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.saveAudioWithTranscriptionHistory)
        }
    }

    var audioHistoryBudgetGB: Double {
        get {
            let value = self.defaults.double(forKey: Keys.audioHistoryBudgetGB)
            return value > 0 ? max(0.1, value) : 4.0
        }
        set {
            objectWillChange.send()
            self.defaults.set(max(0.1, newValue), forKey: Keys.audioHistoryBudgetGB)
        }
    }

    var audioHistoryBudgetBytes: Int64 {
        DictationAudioHistoryStore.bytes(forGigabytes: self.audioHistoryBudgetGB)
    }

    /// Whether to show a native notification when AI post-processing fails and raw text is used
    var notifyAIProcessingFailures: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.notifyAIProcessingFailures)
            return value as? Bool ?? true
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.notifyAIProcessingFailures)
        }
    }

    func makeBackupPayload() -> SettingsBackupPayload {
        SettingsBackupPayload(
            selectedProviderID: self.selectedProviderID,
            selectedModelByProvider: self.selectedModelByProvider,
            savedProviders: self.savedProviders,
            modelReasoningConfigs: self.modelReasoningConfigs,
            privateAIPrefixKVCacheEnabled: self.privateAIPrefixKVCacheEnabled,
            selectedSpeechModel: self.selectedSpeechModel,
            selectedCohereLanguage: self.selectedCohereLanguage,
            selectedNemotronLanguage: self.selectedNemotronLanguage,
            selectedAppleSpeechLocaleIdentifier: self.selectedAppleSpeechLocaleIdentifier,
            hotkeyShortcut: self.hotkeyShortcut,
            primaryDictationShortcuts: self.primaryDictationShortcuts,
            promptModeHotkeyShortcut: self.promptModeHotkeyShortcut,
            promptModeShortcutEnabled: self.promptModeShortcutEnabled,
            promptModeSelectedPromptID: self.promptModeSelectedPromptID,
            secondaryDictationPromptOff: self.isSecondaryDictationPromptOff,
            commandModeHotkeyShortcut: self.commandModeHotkeyShortcut,
            commandModeShortcutEnabled: self.commandModeShortcutEnabled,
            commandModeSelectedModel: self.commandModeSelectedModel,
            commandModeSelectedProviderID: self.commandModeSelectedProviderID,
            commandModeConfirmBeforeExecute: self.commandModeConfirmBeforeExecute,
            commandModeLinkedToGlobal: self.commandModeLinkedToGlobal,
            rewriteModeHotkeyShortcut: self.rewriteModeHotkeyShortcut,
            rewriteModeShortcutEnabled: self.rewriteModeShortcutEnabled,
            rewriteModeSelectedModel: self.rewriteModeSelectedModel,
            rewriteModeSelectedProviderID: self.rewriteModeSelectedProviderID,
            rewriteModeLinkedToGlobal: self.rewriteModeLinkedToGlobal,
            cancelRecordingHotkeyShortcut: self.cancelRecordingHotkeyShortcut,
            showThinkingTokens: self.showThinkingTokens,
            hideFromDockAndAppSwitcher: self.hideFromDockAndAppSwitcher,
            showMainWindowAtLoginLaunch: self.showMainWindowAtLoginLaunch,
            accentColorOption: self.accentColorOption,
            transcriptionStartSound: self.transcriptionStartSound,
            transcriptionSoundVolume: self.transcriptionSoundVolume,
            transcriptionSoundIndependentVolume: self.transcriptionSoundIndependentVolume,
            autoUpdateCheckEnabled: self.autoUpdateCheckEnabled,
            betaReleasesEnabled: self.betaReleasesEnabled,
            enableDebugLogs: self.enableDebugLogs,
            shareAnonymousAnalytics: self.shareAnonymousAnalytics,
            pressAndHoldMode: self.pressAndHoldMode,
            hotkeyMode: self.hotkeyMode,
            enableStreamingPreview: self.enableStreamingPreview,
            enableAIStreaming: self.enableAIStreaming,
            copyTranscriptionToClipboard: self.copyTranscriptionToClipboard,
            textInsertionMode: self.textInsertionMode,
            preferredInputDeviceUID: self.preferredInputDeviceUID,
            preferredOutputDeviceUID: self.preferredOutputDeviceUID,
            visualizerNoiseThreshold: self.visualizerNoiseThreshold,
            overlayPosition: self.overlayPosition,
            overlayBottomOffset: self.overlayBottomOffset,
            overlaySize: self.overlaySize,
            transcriptionPreviewCharLimit: self.transcriptionPreviewCharLimit,
            userTypingWPM: self.userTypingWPM,
            saveTranscriptionHistory: self.saveTranscriptionHistory,
            saveAudioWithTranscriptionHistory: self.saveAudioWithTranscriptionHistory,
            audioHistoryBudgetGB: self.audioHistoryBudgetGB,
            notifyAIProcessingFailures: self.notifyAIProcessingFailures,
            weekendsDontBreakStreak: self.weekendsDontBreakStreak,
            fillerWords: self.fillerWords,
            removeFillerWordsEnabled: self.removeFillerWordsEnabled,
            gaavModeEnabled: self.gaavModeEnabled,
            gaavLowercaseFirstLetterEnabled: self.gaavLowercaseFirstLetterEnabled,
            gaavRemoveTrailingPeriodEnabled: self.gaavRemoveTrailingPeriodEnabled,
            continuousDictationModeEnabled: self.continuousDictationModeEnabled,
            continuousDictationSpacingEnabled: self.continuousDictationSpacingEnabled,
            contextAwareCapitalizationEnabled: self.contextAwareCapitalizationEnabled,
            pauseMediaDuringTranscription: self.pauseMediaDuringTranscription,
            vocabularyBoostingEnabled: self.vocabularyBoostingEnabled,
            customDictionaryEntries: self.customDictionaryEntries,
            selectedDictationPromptID: self.selectedDictationPromptID,
            dictationPromptOff: self.isDictationPromptOff,
            dictationPromptRoutingScope: self.dictationPromptRoutingScope,
            editPromptOff: self.isEditPromptOff,
            selectedEditPromptID: self.selectedEditPromptID,
            editPromptRoutingScope: self.editPromptRoutingScope,
            defaultDictationPromptOverride: self.defaultDictationPromptOverride,
            defaultEditPromptOverride: self.defaultEditPromptOverride
        )
    }

    func restore(from payload: SettingsBackupPayload) {
        self.restore(from: payload, promptProfiles: self.dictationPromptProfiles, appPromptBindings: self.appPromptBindings)
    }

    func restore(
        from payload: SettingsBackupPayload,
        promptProfiles: [DictationPromptProfile],
        appPromptBindings: [AppPromptBinding]
    ) {
        self.savedProviders = payload.savedProviders
        self.selectedProviderID = payload.selectedProviderID
        self.selectedModelByProvider = payload.selectedModelByProvider
        self.modelReasoningConfigs = payload.modelReasoningConfigs
        if let privateAIPrefixKVCacheEnabled = payload.privateAIPrefixKVCacheEnabled {
            self.privateAIPrefixKVCacheEnabled = privateAIPrefixKVCacheEnabled
        }
        self.selectedSpeechModel = payload.selectedSpeechModel
        self.selectedCohereLanguage = payload.selectedCohereLanguage
        if let selectedNemotronLanguage = payload.selectedNemotronLanguage {
            self.selectedNemotronLanguage = selectedNemotronLanguage
        }
        if let selectedAppleSpeechLocaleIdentifier = payload.selectedAppleSpeechLocaleIdentifier {
            self.selectedAppleSpeechLocaleIdentifier = selectedAppleSpeechLocaleIdentifier
        }
        self.primaryDictationShortcuts = payload.primaryDictationShortcuts ?? [payload.hotkeyShortcut]
        self.promptModeHotkeyShortcut = payload.promptModeHotkeyShortcut
        self.promptModeShortcutEnabled = payload.promptModeShortcutEnabled
        self.commandModeHotkeyShortcut = payload.commandModeHotkeyShortcut
        self.commandModeShortcutEnabled = payload.commandModeShortcutEnabled
        self.commandModeSelectedModel = payload.commandModeSelectedModel
        self.commandModeSelectedProviderID = payload.commandModeSelectedProviderID
        self.commandModeConfirmBeforeExecute = payload.commandModeConfirmBeforeExecute
        self.commandModeLinkedToGlobal = payload.commandModeLinkedToGlobal
        self.rewriteModeHotkeyShortcut = payload.rewriteModeHotkeyShortcut
        self.rewriteModeShortcutEnabled = payload.rewriteModeShortcutEnabled
        self.rewriteModeSelectedModel = payload.rewriteModeSelectedModel
        self.rewriteModeSelectedProviderID = payload.rewriteModeSelectedProviderID
        self.rewriteModeLinkedToGlobal = payload.rewriteModeLinkedToGlobal
        self.cancelRecordingHotkeyShortcut = payload.cancelRecordingHotkeyShortcut
        self.showThinkingTokens = payload.showThinkingTokens
        self.hideFromDockAndAppSwitcher = payload.hideFromDockAndAppSwitcher
        self.showMainWindowAtLoginLaunch = payload.showMainWindowAtLoginLaunch ?? true
        self.accentColorOption = payload.accentColorOption
        self.transcriptionStartSound = payload.transcriptionStartSound
        self.transcriptionSoundVolume = payload.transcriptionSoundVolume
        self.transcriptionSoundIndependentVolume = payload.transcriptionSoundIndependentVolume
        self.autoUpdateCheckEnabled = payload.autoUpdateCheckEnabled
        self.betaReleasesEnabled = payload.betaReleasesEnabled
        self.enableDebugLogs = payload.enableDebugLogs
        self.shareAnonymousAnalytics = payload.shareAnonymousAnalytics
        self.hotkeyMode = payload.hotkeyMode ?? (payload.pressAndHoldMode ? .hold : .toggle)
        self.enableStreamingPreview = payload.enableStreamingPreview
        self.enableAIStreaming = payload.enableAIStreaming
        self.copyTranscriptionToClipboard = payload.copyTranscriptionToClipboard
        self.textInsertionMode = payload.textInsertionMode
        self.preferredInputDeviceUID = payload.preferredInputDeviceUID
        self.preferredOutputDeviceUID = payload.preferredOutputDeviceUID
        self.visualizerNoiseThreshold = payload.visualizerNoiseThreshold
        self.overlayPosition = payload.overlayPosition
        self.overlayBottomOffset = payload.overlayBottomOffset
        self.overlaySize = payload.overlaySize
        self.transcriptionPreviewCharLimit = payload.transcriptionPreviewCharLimit
        self.userTypingWPM = payload.userTypingWPM
        self.saveTranscriptionHistory = payload.saveTranscriptionHistory
        if let saveAudioWithTranscriptionHistory = payload.saveAudioWithTranscriptionHistory {
            self.saveAudioWithTranscriptionHistory = saveAudioWithTranscriptionHistory
        }
        if let audioHistoryBudgetGB = payload.audioHistoryBudgetGB {
            self.audioHistoryBudgetGB = audioHistoryBudgetGB
        }
        if let notifyAIProcessingFailures = payload.notifyAIProcessingFailures {
            self.notifyAIProcessingFailures = notifyAIProcessingFailures
        }
        self.weekendsDontBreakStreak = payload.weekendsDontBreakStreak
        self.fillerWords = payload.fillerWords
        self.removeFillerWordsEnabled = payload.removeFillerWordsEnabled
        let restoredGaavModeEnabled = payload.gaavModeEnabled
        let restoredContinuousDictationModeEnabled = payload.continuousDictationModeEnabled ?? false
        self.gaavModeEnabled = restoredGaavModeEnabled
        self.gaavLowercaseFirstLetterEnabled = payload.gaavLowercaseFirstLetterEnabled ?? restoredGaavModeEnabled
        self.gaavRemoveTrailingPeriodEnabled = payload.gaavRemoveTrailingPeriodEnabled ?? restoredGaavModeEnabled
        self.continuousDictationModeEnabled = restoredContinuousDictationModeEnabled
        self.continuousDictationSpacingEnabled = payload.continuousDictationSpacingEnabled ?? restoredContinuousDictationModeEnabled
        self.contextAwareCapitalizationEnabled = payload.contextAwareCapitalizationEnabled ?? restoredContinuousDictationModeEnabled
        self.pauseMediaDuringTranscription = payload.pauseMediaDuringTranscription
        self.vocabularyBoostingEnabled = payload.vocabularyBoostingEnabled
        self.customDictionaryEntries = payload.customDictionaryEntries

        self.dictationPromptProfiles = promptProfiles
        self.appPromptBindings = appPromptBindings
        self.selectedDictationPromptID = payload.selectedDictationPromptID
        self.isDictationPromptOff = payload.dictationPromptOff ?? self.isDictationPromptOff
        self.dictationPromptRoutingScope = payload.dictationPromptRoutingScope ?? .allApps
        self.isEditPromptOff = payload.editPromptOff ?? self.isEditPromptOff
        self.editPromptRoutingScope = payload.editPromptRoutingScope ?? .allApps
        self.selectedEditPromptID = payload.selectedEditPromptID
        self.defaultDictationPromptOverride = payload.defaultDictationPromptOverride
        self.defaultEditPromptOverride = payload.defaultEditPromptOverride
        self.promptModeSelectedPromptID = payload.promptModeSelectedPromptID
        self.isSecondaryDictationPromptOff = payload.secondaryDictationPromptOff ?? false
        self.normalizePromptSelectionsIfNeeded()
    }

    // MARK: - Private Methods

    private func logProviderAPIKeyPersistenceFailure(_ error: Error) {
        DebugLogger.shared.error(
            "Failed to persist provider API keys: \(error.localizedDescription)",
            source: "SettingsStore"
        )
    }

    private func migrateTranscriptionStartSoundIfNeeded() {
        guard let legacyEnabled = self.defaults.object(forKey: Keys.enableTranscriptionSounds) as? Bool else { return }
        if legacyEnabled == false {
            self.defaults.set(TranscriptionStartSound.none.rawValue, forKey: Keys.transcriptionStartSound)
        }
        self.defaults.removeObject(forKey: Keys.enableTranscriptionSounds)
    }

    private func migrateProviderAPIKeysIfNeeded() {
        self.defaults.removeObject(forKey: Keys.providerAPIKeyIdentifiers)

        var merged = (try? self.keychain.fetchAllKeys()) ?? [:]
        var didMutate = false

        if let legacyDefaults = defaults.dictionary(forKey: Keys.providerAPIKeys) as? [String: String],
           legacyDefaults.isEmpty == false
        {
            merged.merge(self.sanitizeAPIKeys(legacyDefaults)) { _, new in new }
            didMutate = true
        }
        self.defaults.removeObject(forKey: Keys.providerAPIKeys)

        if let legacyKeychain = try? keychain.legacyProviderEntries(),
           legacyKeychain.isEmpty == false
        {
            merged.merge(self.sanitizeAPIKeys(legacyKeychain)) { _, new in new }
            didMutate = true
            try? self.keychain.removeLegacyEntries(providerIDs: Array(legacyKeychain.keys))
        }

        if didMutate {
            do {
                _ = try self.saveProviderAPIKeys(merged)
            } catch {
                self.logProviderAPIKeyPersistenceFailure(error)
            }
        }
    }

    private func migrateDictationPromptProfilesIfNeeded() {
        // Migration path from legacy single prompt to multi-prompt profiles.
        // If user had a legacy custom dictation prompt, convert it to a profile and select it.
        let legacyPrompt = self.customDictationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyPrompt.isEmpty else { return }

        // If profiles already exist, just clear the legacy prompt so we don't keep two sources of truth.
        if self.dictationPromptProfiles.isEmpty == false {
            self.customDictationPrompt = ""
            // If selection points to nowhere, reset to default to avoid confusion.
            if let id = self.selectedDictationPromptID,
               self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode == .dictate }) == false
            {
                self.selectedDictationPromptID = nil
            }
            return
        }

        let profile = DictationPromptProfile(
            name: "My Custom Prompt",
            prompt: legacyPrompt,
            createdAt: Date(),
            updatedAt: Date()
        )
        self.dictationPromptProfiles = [profile]
        self.selectedDictationPromptID = profile.id
        self.customDictationPrompt = ""
        DebugLogger.shared.info("Migrated legacy custom dictation prompt to a prompt profile", source: "SettingsStore")
    }

    private func migrateLegacyDictationAIPreferenceIfNeeded() {
        guard self.defaults.object(forKey: Keys.dictationPromptOff) == nil else { return }

        let hasSelectedCustomDictationPrompt = self.selectedDictationPromptID.flatMap { id in
            self.dictationPromptProfiles.first(where: { $0.id == id && $0.mode == .dictate })
        } != nil

        let shouldStartOff: Bool
        if hasSelectedCustomDictationPrompt {
            shouldStartOff = false
        } else if self.defaults.object(forKey: Keys.enableAIProcessing) != nil {
            shouldStartOff = !self.defaults.bool(forKey: Keys.enableAIProcessing)
        } else {
            shouldStartOff = true
        }

        self.defaults.set(shouldStartOff, forKey: Keys.dictationPromptOff)
    }

    private func migrateSecondaryPromptShortcutIfNeeded() {
        guard self.defaults.bool(forKey: Keys.secondaryPromptShortcutRemoved) == false else { return }
        self.defaults.set(false, forKey: Keys.promptModeShortcutEnabled)
        self.defaults.set(true, forKey: Keys.secondaryDictationPromptOff)
        self.defaults.removeObject(forKey: Keys.promptModeSelectedPromptID)
        self.defaults.set(true, forKey: Keys.secondaryPromptShortcutRemoved)
    }

    private func retireLegacySecondaryPromptShortcutIfNeeded() {
        guard self.defaults.bool(forKey: Keys.legacySecondaryPromptShortcutRetired) == false else { return }

        self.defaults.set(false, forKey: Keys.promptModeShortcutEnabled)
        self.defaults.set(true, forKey: Keys.secondaryDictationPromptOff)
        self.defaults.removeObject(forKey: Keys.promptModeHotkeyShortcut)
        self.defaults.removeObject(forKey: Keys.promptModeSelectedPromptID)
        self.defaults.set(true, forKey: Keys.legacySecondaryPromptShortcutRetired)
    }

    private func normalizePromptSelectionsIfNeeded() {
        if self.defaults.object(forKey: Keys.secondaryDictationPromptOff) == nil {
            self.defaults.set(false, forKey: Keys.secondaryDictationPromptOff)
        }

        // One-time migration to unified edit keys.
        if self.defaults.object(forKey: Keys.selectedEditPromptID) == nil,
           let migratedSelectedEditID = self.selectedEditPromptID
        {
            self.defaults.set(migratedSelectedEditID, forKey: Keys.selectedEditPromptID)
            self.defaults.removeObject(forKey: Keys.selectedWritePromptID)
            self.defaults.removeObject(forKey: Keys.selectedRewritePromptID)
        }

        if self.defaults.object(forKey: Keys.defaultEditPromptOverride) == nil,
           let migratedEditOverride = self.defaultEditPromptOverride
        {
            self.defaults.set(migratedEditOverride, forKey: Keys.defaultEditPromptOverride)
            self.defaults.removeObject(forKey: Keys.defaultWritePromptOverride)
            self.defaults.removeObject(forKey: Keys.defaultRewritePromptOverride)
        }

        // Persist profile mode normalization to the new user-facing modes.
        var normalizedProfiles = self.dictationPromptProfiles
        var didChangeProfiles = false
        for idx in normalizedProfiles.indices {
            let normalizedMode = normalizedProfiles[idx].mode.normalized
            if normalizedProfiles[idx].mode != normalizedMode {
                normalizedProfiles[idx].mode = normalizedMode
                didChangeProfiles = true
            }
        }
        normalizedProfiles.removeAll { profile in
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = Self.stripBasePrompt(for: profile.mode, from: profile.prompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isLegacyPlaceholder = profile.mode.normalized == .dictate &&
                name.caseInsensitiveCompare("Blocked") == .orderedSame &&
                prompt.caseInsensitiveCompare("Blocked prompt") == .orderedSame
            let isAccidentalPrivateAIProfile = profile.mode.normalized == .dictate &&
                name.caseInsensitiveCompare(PrivateAIProviderFeature.displayName) == .orderedSame &&
                prompt.isEmpty
            if isLegacyPlaceholder || isAccidentalPrivateAIProfile {
                didChangeProfiles = true
            }
            return isLegacyPlaceholder || isAccidentalPrivateAIProfile
        }
        if didChangeProfiles {
            self.dictationPromptProfiles = normalizedProfiles
        }

        let privateAIPromptID = PrivateAIProviderPromptFormat.promptSelectionID

        if let id = self.selectedDictationPromptID,
           !(PrivateFeatures.privateAIProvider && id == privateAIPromptID),
           self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode == .dictate }) == false
        {
            self.selectedDictationPromptID = nil
        }

        if let id = self.selectedEditPromptID,
           self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode.normalized == .edit }) == false
        {
            self.selectedEditPromptID = nil
        }

        if let id = self.promptModeSelectedPromptID,
           !(PrivateFeatures.privateAIProvider && id == privateAIPromptID),
           self.dictationPromptProfiles.contains(where: { $0.id == id && $0.mode.normalized == .dictate }) == false
        {
            self.promptModeSelectedPromptID = nil
        }

        let validPromptIDsByMode: [PromptMode: Set<String>] = [
            .dictate: Set(self.dictationPromptProfiles.filter { $0.mode.normalized == .dictate }.map(\.id)),
            .edit: Set(self.dictationPromptProfiles.filter { $0.mode.normalized == .edit }.map(\.id)),
        ]

        var normalizedBindings: [AppPromptBinding] = []
        var dedupe: [String: AppPromptBinding] = [:]
        var didMutateBindings = false

        for binding in self.appPromptBindings {
            let normalizedMode = binding.mode.normalized
            guard let normalizedBundleID = Self.normalizeAppBundleID(binding.appBundleID) else {
                didMutateBindings = true
                continue
            }

            var cleaned = binding
            if cleaned.mode != normalizedMode {
                cleaned.mode = normalizedMode
                didMutateBindings = true
            }
            if cleaned.appBundleID != normalizedBundleID {
                cleaned.appBundleID = normalizedBundleID
                didMutateBindings = true
            }

            let trimmedName = cleaned.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = trimmedName.isEmpty ? normalizedBundleID : trimmedName
            if cleaned.appName != resolvedName {
                cleaned.appName = resolvedName
                didMutateBindings = true
            }

            if let promptID = cleaned.promptID,
               validPromptIDsByMode[normalizedMode]?.contains(promptID) != true
            {
                cleaned.promptID = nil
                didMutateBindings = true
            }

            let dedupeKey = "\(normalizedMode.rawValue)|\(normalizedBundleID)"
            if let existing = dedupe[dedupeKey] {
                // Keep the most recently updated binding when duplicates exist.
                if cleaned.updatedAt >= existing.updatedAt {
                    dedupe[dedupeKey] = cleaned
                }
                didMutateBindings = true
            } else {
                dedupe[dedupeKey] = cleaned
            }
        }

        normalizedBindings = Array(dedupe.values).sorted { lhs, rhs in
            if lhs.mode.normalized != rhs.mode.normalized {
                return lhs.mode.normalized.rawValue < rhs.mode.normalized.rawValue
            }
            if lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) != .orderedSame {
                return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
            }
            return lhs.appBundleID < rhs.appBundleID
        }

        if didMutateBindings || normalizedBindings.count != self.appPromptBindings.count {
            self.appPromptBindings = normalizedBindings
        }
    }

    private func normalizeDictationPromptConfigurationsIfNeeded() {
        let validKeys = Set(
            ["__default__", "__privateAI__"] + self.dictationPromptProfiles
                .filter { $0.mode.normalized == .dictate }
                .map { "profile:\($0.id)" }
        )
        var configurations = self.dictationPromptConfigurations
        let originalCount = configurations.count
        configurations = configurations.filter { key, configuration in
            validKeys.contains(key) &&
                (
                    configuration.shortcut != nil ||
                        !configuration.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
        if configurations.count != originalCount {
            self.dictationPromptConfigurations = configurations
        }
    }

    private func migrateOverlayBottomOffsetTo50IfNeeded() {
        if self.defaults.bool(forKey: Keys.overlayBottomOffsetMigratedTo50) {
            return
        }

        self.defaults.set(50.0, forKey: Keys.overlayBottomOffset)
        self.defaults.set(true, forKey: Keys.overlayBottomOffsetMigratedTo50)
        NotificationCenter.default.post(name: NSNotification.Name("OverlayOffsetChanged"), object: nil)
    }

    private func scrubSavedProviderAPIKeys() {
        guard let data = defaults.data(forKey: Keys.savedProviders),
              var decoded = try? JSONDecoder().decode([SavedProvider].self, from: data) else { return }

        var didModify = false
        for index in decoded.indices {
            let provider = decoded[index]
            let trimmed = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }

            let keyID = self.canonicalProviderKey(for: provider.id)
            do {
                try self.keychain.storeKey(trimmed, for: keyID)
                didModify = true
            } catch {
                DebugLogger.shared
                    .error(
                        "Failed to migrate API key for \(provider.name): \(error.localizedDescription)",
                        source: "SettingsStore"
                    )
            }

            decoded[index] = SavedProvider(
                id: provider.id,
                name: provider.name,
                baseURL: provider.baseURL,
                apiKey: "",
                models: provider.models
            )
        }

        if didModify,
           let encoded = try? JSONEncoder().encode(decoded)
        {
            self.defaults.set(encoded, forKey: Keys.savedProviders)
        }

        // No need to track migrated IDs; consolidated storage keeps them together.
    }

    private func canonicalProviderKey(for providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Built-in providers use their ID directly
        if ModelRepository.shared.isBuiltIn(trimmed) {
            return trimmed
        }
        if trimmed.hasPrefix("custom:") {
            return trimmed
        }
        return "custom:\(trimmed)"
    }

    private func verifiedProviderIDsForCurrentConfiguration() -> [String] {
        var providerIDs = ModelRepository.builtInProviderIDs + self.savedProviders.map(\.id)
        if PrivateFeatures.privateAIProvider {
            providerIDs.append(PrivateAIProviderFeature.shared.providerID)
        }

        var seenProviderKeys = Set<String>()
        return providerIDs.filter { providerID in
            let key = self.canonicalProviderKey(for: providerID)
            guard !key.isEmpty, seenProviderKeys.insert(key).inserted else { return false }
            return self.isVerifiedProviderForCurrentConfiguration(providerID)
        }
    }

    private func isVerifiedProviderForCurrentConfiguration(_ providerID: String) -> Bool {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed == "apple-intelligence" {
            return AppleIntelligenceService.isAvailable &&
                self.verifiedProviderFingerprints[self.canonicalProviderKey(for: trimmed)] == "apple-intelligence"
        }

        if PrivateFeatures.privateAIProvider,
           trimmed == PrivateAIProviderFeature.shared.providerID
        {
            return PrivateAIProviderPromptFormat.verifiedModelID(settings: self) != nil
        }

        let key = self.canonicalProviderKey(for: trimmed)
        guard let stored = self.verifiedProviderFingerprints[key] else { return false }

        let baseURL = self.providerBaseURLForVerification(for: trimmed)
        let apiKey = (self.getAPIKey(for: trimmed) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModelRepository.shared.isLocalEndpoint(baseURL) || !apiKey.isEmpty else { return false }

        return self.providerFingerprint(baseURL: baseURL, apiKey: apiKey) == stored
    }

    private func providerBaseURLForVerification(for providerID: String) -> String {
        let savedProviderID = providerID.hasPrefix("custom:") ?
            String(providerID.dropFirst("custom:".count)) : providerID
        if let saved = self.savedProviders.first(where: { $0.id == savedProviderID }) {
            return saved.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ModelRepository.shared.isBuiltIn(providerID) {
            return ModelRepository.shared.defaultBaseURL(for: providerID).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func providerFingerprint(baseURL: String, apiKey: String) -> String? {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else { return nil }

        let input = "\(trimmedBaseURL)|\(trimmedAPIKey)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func syncLinkedProviderSelections(to providerID: String) {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkedProviderID = self.isPrivateAIProviderID(trimmed) ? "" : trimmed
        let model = self.modelSelection(for: linkedProviderID)

        if self.rewriteModeLinkedToGlobal {
            self.rewriteModeSelectedProviderID = linkedProviderID
            self.rewriteModeSelectedModel = model
        }

        if self.commandModeLinkedToGlobal {
            self.commandModeSelectedProviderID = linkedProviderID
            self.commandModeSelectedModel = model
        }
    }

    private func isPrivateAIProviderID(_ providerID: String) -> Bool {
        PrivateFeatures.privateAIProvider &&
            providerID.trimmingCharacters(in: .whitespacesAndNewlines) == PrivateAIProviderFeature.shared.providerID
    }

    private func modelSelection(for providerID: String) -> String? {
        guard !providerID.isEmpty else { return nil }

        if PrivateFeatures.privateAIProvider,
           providerID == PrivateAIProviderFeature.shared.providerID,
           let modelID = PrivateAIProviderPromptFormat.verifiedModelID(settings: self)
        {
            return modelID
        }

        let key = self.canonicalProviderKey(for: providerID)
        if let selected = self.selectedModelByProvider[key],
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return selected
        }

        let savedProviderID = providerID.hasPrefix("custom:") ?
            String(providerID.dropFirst("custom:".count)) : providerID
        if let savedModel = self.savedProviders.first(where: { $0.id == savedProviderID })?.models.first,
           !savedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return savedModel
        }

        return ModelRepository.shared.defaultModels(for: providerID).first
    }

    private func availableSelectedProviderID(for rawValue: String?) -> String {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        let providerID = trimmed
        if ModelRepository.shared.isBuiltIn(providerID) { return providerID }
        if PrivateFeatures.privateAIProvider,
           providerID == PrivateAIProviderFeature.shared.providerID
        {
            return providerID
        }

        let savedProviderID = providerID.hasPrefix("custom:") ?
            String(providerID.dropFirst("custom:".count)) : providerID
        if self.savedProviders.contains(where: { $0.id == savedProviderID }) {
            return savedProviderID
        }

        return ""
    }

    private func sanitizeAPIKeys(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [String: String]()) { partialResult, pair in
            let sanitizedValue = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sanitizedValue.isEmpty == false else { return }
            partialResult[pair.key] = sanitizedValue
        }
    }

    private func updateDockVisibility(_ visible: Bool) {
        #if os(macOS)
        // IMPORTANT: This is a simplified implementation for development
        // In production, consider these approaches:
        // 1. Use LSUIElement in Info.plist to control default dock visibility
        // 2. Implement a proper helper app or service for dock management
        // 3. Use NSApplication.shared.setActivationPolicy() for better control

        // For now, we'll try multiple approaches with fallbacks

        DebugLogger.shared.debug(
            "Attempting to update dock visibility to: \(visible ? "visible" : "hidden")",
            source: "SettingsStore"
        )

        // Method 1: Try the deprecated TransformProcessType (may not work on all systems)
        let transformState = visible ? ProcessApplicationTransformState(kProcessTransformToForegroundApplication)
            : ProcessApplicationTransformState(kProcessTransformToUIElementApplication)

        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        let result = TransformProcessType(&psn, transformState)

        if result == 0 {
            DebugLogger.shared.info("✓ Dock visibility updated using TransformProcessType", source: "SettingsStore")
        } else {
            DebugLogger.shared
                .warning(
                    "⚠️ TransformProcessType failed (error: \(result)). This is expected on some macOS versions.",
                    source: "SettingsStore"
                )
            DebugLogger.shared.debug(
                "   The setting is saved and will be applied when possible.",
                source: "SettingsStore"
            )
        }

        // Method 2: Try to notify the system of the change
        // This may help with some system caches
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
            DebugLogger.shared.info(
                "✓ Activation policy updated to: \(visible ? "regular" : "accessory")",
                source: "SettingsStore"
            )
        }

        // Store the intended state for reference
        UserDefaults.standard.set(visible, forKey: "IntendedDockVisibility")
        DebugLogger.shared.info("✓ Dock visibility preference saved: \(visible)", source: "SettingsStore")
        #endif
    }

    // MARK: - Filler Words

    static let defaultFillerWords = [
        "um",
        "uh",
        "er",
        "ah",
        "eh",
        "umm",
        "uhh",
        "err",
        "ahh",
        "ehh",
        "hmm",
        "hm",
        "mm",
        "mmm",
        "erm",
        "urm",
        "ugh",
    ]

    var fillerWords: [String] {
        get {
            if let stored = defaults.array(forKey: Keys.fillerWords) as? [String] {
                return stored
            }
            return Self.defaultFillerWords
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.fillerWords)
        }
    }

    var removeFillerWordsEnabled: Bool {
        get { self.defaults.object(forKey: Keys.removeFillerWordsEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.removeFillerWordsEnabled)
        }
    }

    // MARK: - GAAV Mode

    /// Legacy combined GAAV setting. New behavior uses the split formatting toggles below.
    var gaavModeEnabled: Bool {
        get { self.defaults.object(forKey: Keys.gaavModeEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.gaavModeEnabled)
        }
    }

    var gaavLowercaseFirstLetterEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.gaavLowercaseFirstLetterEnabled) as? Bool ?? self.gaavModeEnabled
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.gaavLowercaseFirstLetterEnabled)
        }
    }

    var gaavRemoveTrailingPeriodEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.gaavRemoveTrailingPeriodEnabled) as? Bool ?? self.gaavModeEnabled
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.gaavRemoveTrailingPeriodEnabled)
        }
    }

    // MARK: - Continuous Dictation Mode

    /// Legacy combined continuous-dictation setting. New behavior uses the split toggles below.
    var continuousDictationModeEnabled: Bool {
        get { self.defaults.object(forKey: Keys.continuousDictationModeEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.continuousDictationModeEnabled)
        }
    }

    var continuousDictationSpacingEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.continuousDictationSpacingEnabled) as? Bool ?? self.continuousDictationModeEnabled
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.continuousDictationSpacingEnabled)
        }
    }

    var contextAwareCapitalizationEnabled: Bool {
        get {
            self.defaults.object(forKey: Keys.contextAwareCapitalizationEnabled) as? Bool ?? self.continuousDictationModeEnabled
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.contextAwareCapitalizationEnabled)
        }
    }

    var needsDictationFormattingContext: Bool {
        self.continuousDictationSpacingEnabled || self.contextAwareCapitalizationEnabled
    }

    // MARK: - Media Playback Control

    /// When enabled, automatically pauses system media playback when transcription starts.
    /// Only resumes if FluidVoice was the one that paused it.
    var pauseMediaDuringTranscription: Bool {
        get { self.defaults.object(forKey: Keys.pauseMediaDuringTranscription) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.pauseMediaDuringTranscription)
        }
    }

    // MARK: - Custom Dictionary

    /// A custom dictionary entry that maps multiple misheard/alternate spellings to a correct replacement.
    /// For example: ["fluid voice", "fluid boys"] -> "FluidVoice"
    struct CustomDictionaryEntry: Codable, Identifiable, Hashable {
        let id: UUID
        /// Words/phrases to look for (case-insensitive matching)
        var triggers: [String]
        /// The correct replacement text
        var replacement: String

        init(triggers: [String], replacement: String) {
            self.id = UUID()
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }

        init(id: UUID, triggers: [String], replacement: String) {
            self.id = id
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }
    }

    var vocabularyBoostingEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.vocabularyBoostingEnabled)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.vocabularyBoostingEnabled)
            NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
        }
    }

    /// Custom dictionary entries for word replacement
    var customDictionaryEntries: [CustomDictionaryEntry] {
        get {
            guard let data = defaults.data(forKey: Keys.customDictionaryEntries),
                  let decoded = try? JSONDecoder().decode([CustomDictionaryEntry].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.customDictionaryEntries)
            }
        }
    }

    // MARK: - Speech Model (Unified ASR Model Selection)

    /// Unified speech recognition model selection.
    /// Replaces the old TranscriptionProviderOption + WhisperModelSize dual-setting.
    enum SpeechModel: String, CaseIterable, Identifiable, Codable {
        /// Temporarily disabled in UI/runtime while Parakeet word boosting work is prioritized.
        /// Flip to `true` in a future round to re-enable Qwen without deleting implementation.
        static let qwenPreviewEnabled = false

        // MARK: - FluidAudio Models (Apple Silicon Only)

        case parakeetTDT = "parakeet-tdt"
        case parakeetTDTv2 = "parakeet-tdt-v2"
        case parakeetRealtime = "parakeet-realtime"
        case qwen3Asr = "qwen3-asr"
        case cohereTranscribeSixBit = "cohere-transcribe-6bit"
        case nemotronOffline = "nemotron-3.5-offline"
        case nemotronStreaming = "nemotron-3.5-streaming"
        case nemotronStreaming320 = "nemotron-3.5-streaming-320"

        // MARK: - Apple Native

        case appleSpeech = "apple-speech"
        case appleSpeechAnalyzer = "apple-speech-analyzer"

        // MARK: - Whisper Models (Universal)

        case whisperTiny = "whisper-tiny"
        case whisperBase = "whisper-base"
        case whisperSmall = "whisper-small"
        case whisperMedium = "whisper-medium"
        case whisperLargeTurbo = "whisper-large-turbo" // temporarily disabled in UI
        case whisperLarge = "whisper-large"

        var id: String {
            rawValue
        }

        // MARK: - Display Properties

        var displayName: String {
            switch self {
            case .parakeetTDT: return "Parakeet TDT v3 (Multilingual)"
            case .parakeetTDTv2: return "Parakeet TDT v2 (English Only)"
            case .parakeetRealtime: return "Parakeet Flash (Beta)"
            case .qwen3Asr: return "Qwen3 ASR (Beta)"
            case .cohereTranscribeSixBit: return "Cohere Transcribe"
            case .nemotronOffline: return "Nemotron 3.5 Multilingual"
            case .nemotronStreaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .nemotronStreaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .appleSpeech: return "Apple ASR Legacy"
            case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
            case .whisperTiny: return "Whisper Tiny"
            case .whisperBase: return "Whisper Base"
            case .whisperSmall: return "Whisper Small"
            case .whisperMedium: return "Whisper Medium"
            case .whisperLargeTurbo: return "Whisper Large Turbo (Disabled)"
            case .whisperLarge: return "Whisper Large"
            }
        }

        var languageSupport: String {
            switch self {
            case .parakeetTDT:
                return "25 Languages"
            case .parakeetTDTv2: return "English Only (Higher Accuracy)"
            case .parakeetRealtime: return "English Only (Live Streaming)"
            case .qwen3Asr: return "30 Languages"
            case .cohereTranscribeSixBit: return "14 Languages (Select Manually)"
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return "Around 40 Languages"
            case .appleSpeech: return "System Languages"
            case .appleSpeechAnalyzer: return "EN, ES, FR, DE, IT, JA, KO, PT, ZH"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "99 Languages"
            }
        }

        var downloadSize: String {
            switch self {
            case .parakeetTDT: return "~500 MB"
            case .parakeetTDTv2: return "~500 MB"
            case .parakeetRealtime: return "~250 MB"
            case .qwen3Asr: return "~2.0 GB"
            case .cohereTranscribeSixBit: return "~1.4 GB"
            case .nemotronOffline: return "~530 MB"
            case .nemotronStreaming: return "~670 MB"
            case .nemotronStreaming320: return "~670 MB"
            case .appleSpeech: return "Built-in"
            case .appleSpeechAnalyzer: return "Built-in"
            case .whisperTiny: return "~75 MB"
            case .whisperBase: return "~142 MB"
            case .whisperSmall: return "~466 MB"
            case .whisperMedium: return "~1.5 GB"
            case .whisperLargeTurbo: return "~1.6 GB"
            case .whisperLarge: return "~2.9 GB"
            }
        }

        var requiresAppleSilicon: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return true
            default: return false
            }
        }

        var isWhisperModel: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320, .appleSpeech, .appleSpeechAnalyzer: return false
            default: return true
            }
        }

        /// The ggml filename for Whisper models
        var whisperModelFile: String? {
            switch self {
            case .whisperTiny: return "ggml-tiny.bin"
            case .whisperBase: return "ggml-base.bin"
            case .whisperSmall: return "ggml-small.bin"
            case .whisperMedium: return "ggml-medium.bin"
            case .whisperLargeTurbo: return "ggml-large-v3-turbo.bin"
            case .whisperLarge: return "ggml-large-v3.bin"
            default: return nil
            }
        }

        /// The short model name for whisper.cpp internal usage
        var whisperModelName: String? {
            switch self {
            case .whisperTiny: return "tiny"
            case .whisperBase: return "base"
            case .whisperSmall: return "small"
            case .whisperMedium: return "medium"
            case .whisperLargeTurbo: return "large-v3-turbo"
            case .whisperLarge: return "large-v3"
            default: return nil
            }
        }

        // MARK: - Architecture Filtering

        /// Requires macOS 26 (Tahoe) or later
        var requiresMacOS26: Bool {
            switch self {
            case .appleSpeechAnalyzer: return true
            default: return false
            }
        }

        /// Requires macOS 15 or later.
        var requiresMacOS15: Bool {
            switch self {
            case .qwen3Asr, .cohereTranscribeSixBit: return true
            default: return false
            }
        }

        /// Returns models available for the current Mac's architecture and OS
        static var availableModels: [SpeechModel] {
            allCases.filter { model in
                if model == .whisperLargeTurbo {
                    return false
                }
                if model == .qwen3Asr, !Self.qwenPreviewEnabled {
                    return false
                }
                if model == .nemotronStreaming320 {
                    return false
                }
                // Filter by Apple Silicon requirement
                if model.requiresAppleSilicon, !CPUArchitecture.isAppleSilicon {
                    return false
                }
                // Filter by macOS 15 requirement
                if model.requiresMacOS15, #unavailable(macOS 15.0) {
                    return false
                }
                // Filter by macOS 26 requirement
                if model.requiresMacOS26 {
                    if #available(macOS 26.0, *) {
                        return true
                    } else {
                        return false
                    }
                }
                return true
            }
        }

        /// Default model for the current architecture
        static var defaultModel: SpeechModel {
            CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase
        }

        // MARK: - UI Card Metadata

        /// Human-readable marketing name for the card UI
        var humanReadableName: String {
            switch self {
            case .parakeetTDT: return "Blazing Fast - Multilingual"
            case .parakeetTDTv2: return "Blazing Fast - English"
            case .parakeetRealtime: return "Flash Dictation"
            case .qwen3Asr: return "Qwen3 - Multilingual"
            case .cohereTranscribeSixBit: return "Cohere - High Accuracy"
            case .nemotronOffline: return "Nemotron 3.5 Multilingual"
            case .nemotronStreaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .nemotronStreaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .appleSpeech: return "Apple ASR Legacy"
            case .appleSpeechAnalyzer: return "Apple Speech - macOS 26+"
            case .whisperTiny: return "Fast & Light"
            case .whisperBase: return "Standard Choice"
            case .whisperSmall: return "Balanced Speed & Accuracy"
            case .whisperMedium: return "Medium Quality"
            case .whisperLargeTurbo: return "Higher Quality but Faster"
            case .whisperLarge: return "Maximum Accuracy"
            }
        }

        /// One-line description for the card UI
        var cardDescription: String {
            switch self {
            case .parakeetTDT:
                return "Fast multilingual transcription. Supports Bulgarian, Croatian, Czech, Danish, " +
                    "Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, " +
                    "Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, " +
                    "Slovenian, Spanish, Swedish, and Ukrainian."
            case .parakeetTDTv2:
                return "Optimized for English accuracy and fastest transcription."
            case .parakeetRealtime:
                return "English-only streaming local dictation with low-latency partial text and end-of-utterance detection."
            case .qwen3Asr:
                return "Qwen3 multilingual ASR via FluidAudio. Higher quality, heavier memory footprint."
            case .cohereTranscribeSixBit:
                return "High-accuracy multilingual transcription. Select the language manually before dictation for best results."
            case .nemotronOffline:
                return "Slower but more accurate NVIDIA Nemotron 3.5 transcription. Supports 40 language-locales with auto or manual language selection."
            case .nemotronStreaming:
                return "NVIDIA Nemotron 3.5 streaming-capable transcription. Supports 40 language-locales with auto or manual language selection."
            case .nemotronStreaming320:
                return "NVIDIA Nemotron 3.5 streaming-capable transcription. Supports 40 language-locales with auto or manual language selection."
            case .appleSpeech:
                return "Built-in macOS speech recognition. No model download required."
            case .appleSpeechAnalyzer:
                return "Advanced and modern on-device recognition for newer macOS devices."
            case .whisperTiny:
                return "Minimal resource usage. Best for older Macs or battery life."
            case .whisperBase:
                return "Good balance of speed and accuracy. Works on any Mac."
            case .whisperSmall:
                return "Better accuracy than Base. Moderate resource usage."
            case .whisperMedium:
                return "High accuracy for demanding tasks. Requires more memory."
            case .whisperLargeTurbo:
                return "Near-maximum accuracy with optimized speed."
            case .whisperLarge:
                return "Best possible accuracy. Large download and memory usage."
            }
        }

        /// Minimum recommended RAM in GB for this model to run safely
        var requiredMemoryGB: Double {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime:
                return 4.0
            case .qwen3Asr:
                return 8.0
            case .cohereTranscribeSixBit:
                return 8.0
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return 8.0
            case .appleSpeech, .appleSpeechAnalyzer:
                return 2.0 // Built-in, minimal overhead
            case .whisperTiny:
                return 2.0
            case .whisperBase:
                return 3.0
            case .whisperSmall:
                return 4.0
            case .whisperMedium:
                return 6.0
            case .whisperLargeTurbo:
                return 8.0
            case .whisperLarge:
                return 10.0 // Large model needs ~6-8GB working memory + model size
            }
        }

        /// Warning text for models with high memory requirements, nil if no warning needed
        var memoryWarning: String? {
            switch self {
            case .qwen3Asr:
                return "⚠️ Requires 8GB+ RAM. Best on newer Apple Silicon Macs."
            case .whisperLarge:
                return "⚠️ Requires 10GB+ RAM. May crash on systems with limited memory."
            case .whisperLargeTurbo:
                return "⚠️ Requires 8GB+ RAM. May be unstable on some systems."
            case .whisperMedium:
                return "Requires 6GB+ RAM for stable operation."
            default:
                return nil
            }
        }

        /// Speed rating (1-5, higher is faster)
        var speedRating: Int {
            switch self {
            case .parakeetTDT: return 5
            case .parakeetTDTv2: return 5
            case .parakeetRealtime: return 5
            case .qwen3Asr: return 3
            case .cohereTranscribeSixBit: return 3
            case .nemotronOffline: return 3
            case .nemotronStreaming, .nemotronStreaming320: return 4
            case .appleSpeech: return 4
            case .appleSpeechAnalyzer: return 4
            case .whisperTiny: return 4
            case .whisperBase: return 4
            case .whisperSmall: return 3
            case .whisperMedium: return 2
            case .whisperLargeTurbo: return 3
            case .whisperLarge: return 1
            }
        }

        /// Accuracy rating (1-5, higher is more accurate)
        var accuracyRating: Int {
            switch self {
            case .parakeetTDT: return 5
            case .parakeetTDTv2: return 5
            case .parakeetRealtime: return 4
            case .qwen3Asr: return 4
            case .cohereTranscribeSixBit: return 5
            case .nemotronOffline: return 5
            case .nemotronStreaming, .nemotronStreaming320: return 4
            case .appleSpeech: return 4
            case .appleSpeechAnalyzer: return 4
            case .whisperTiny: return 2
            case .whisperBase: return 3
            case .whisperSmall: return 4
            case .whisperMedium: return 4
            case .whisperLargeTurbo: return 5
            case .whisperLarge: return 5
            }
        }

        /// Exact speed percentage (0.0 - 1.0) for the liquid bars
        var speedPercent: Double {
            switch self {
            case .parakeetTDT: return 1.0
            case .parakeetTDTv2: return 1.0
            case .parakeetRealtime: return 1.0
            case .qwen3Asr: return 0.45
            case .cohereTranscribeSixBit: return 0.85
            case .nemotronOffline: return 0.85
            case .nemotronStreaming, .nemotronStreaming320: return 1.0
            case .appleSpeech: return 0.60
            case .appleSpeechAnalyzer: return 0.85
            case .whisperTiny: return 0.90
            case .whisperBase: return 0.80
            case .whisperSmall: return 0.60
            case .whisperMedium: return 0.40
            case .whisperLargeTurbo: return 0.65
            case .whisperLarge: return 0.20
            }
        }

        /// Exact accuracy percentage (0.0 - 1.0) for the liquid bars
        var accuracyPercent: Double {
            switch self {
            case .parakeetTDT: return 0.92
            case .parakeetTDTv2: return 0.96
            case .parakeetRealtime: return 0.75
            case .qwen3Asr: return 0.90
            case .cohereTranscribeSixBit: return 0.98
            case .nemotronOffline: return 0.90
            case .nemotronStreaming, .nemotronStreaming320: return 0.85
            case .appleSpeech: return 0.60
            case .appleSpeechAnalyzer: return 0.80
            case .whisperTiny: return 0.40
            case .whisperBase: return 0.60
            case .whisperSmall: return 0.70
            case .whisperMedium: return 0.80
            case .whisperLargeTurbo: return 0.95
            case .whisperLarge: return 1.00
            }
        }

        /// Optional badge text for the card (e.g., "FluidVoice Pick")
        var badgeText: String? {
            switch self {
            case .parakeetTDT: return "FluidVoice Pick"
            case .parakeetTDTv2: return "FluidVoice Pick"
            case .parakeetRealtime: return "Beta"
            case .qwen3Asr: return "Beta"
            case .cohereTranscribeSixBit: return "New"
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320: return "New + Beta"
            case .appleSpeechAnalyzer: return "New"
            default: return nil
            }
        }

        /// Optimization level for Apple Silicon (for display)
        var appleSiliconOptimized: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .qwen3Asr, .cohereTranscribeSixBit, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320, .appleSpeechAnalyzer:
                return true
            default:
                return false
            }
        }

        var supportsFastDictationProcessing: Bool {
            switch self {
            case .parakeetTDT, .parakeetTDTv2:
                return true
            default:
                return false
            }
        }

        /// Whether this model supports real-time streaming/chunk processing.
        /// Large Whisper models are too slow for streaming, so they only do final transcription on stop.
        var supportsStreaming: Bool {
            switch self {
            case .qwen3Asr, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return false // Too slow for real-time chunk processing
            default:
                return true // All other models support streaming
            }
        }

        /// Preview update cadence for real-time transcription.
        /// Models without native incremental decoding should use a slower interval.
        var streamingPreviewIntervalSeconds: Double {
            switch self {
            case .parakeetRealtime:
                return 0.2
            case .nemotronStreaming, .nemotronStreaming320:
                return 0.32
            case .cohereTranscribeSixBit:
                return 1.0
            default:
                return 0.6
            }
        }

        /// Minimum audio required before attempting a preview decode.
        /// Cohere performs better with a slightly larger prefix than the default 1 second.
        var minimumStreamingPreviewSeconds: Double {
            switch self {
            case .parakeetRealtime:
                return 0.2
            case .nemotronStreaming, .nemotronStreaming320:
                return 0.64
            case .cohereTranscribeSixBit:
                return 1.5
            default:
                return 1.0
            }
        }

        /// Provider category for tab grouping
        enum Provider: String, CaseIterable {
            case nvidia = "NVIDIA"
            case apple = "Apple"
            case openai = "OpenAI"
            case qwen = "Qwen"
            case cohere = "Cohere"
        }

        /// Which provider this model belongs to
        var provider: Provider {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return .nvidia
            case .appleSpeech, .appleSpeechAnalyzer:
                return .apple
            case .qwen3Asr:
                return .qwen
            case .cohereTranscribeSixBit:
                return .cohere
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return .openai
            }
        }

        /// Get models filtered by provider
        static func models(for provider: Provider) -> [SpeechModel] {
            self.availableModels.filter { $0.provider == provider }
        }

        /// Whether this model is built-in or already downloaded on disk
        var isInstalled: Bool {
            switch self {
            case .appleSpeech, .appleSpeechAnalyzer:
                return true
            case .parakeetTDT:
                // Hardcoded path check for NVIDIA v3
                return Self.parakeetCacheDirectory(version: "parakeet-tdt-0.6b-v3-coreml")
            case .parakeetTDTv2:
                // Hardcoded path check for NVIDIA v2
                return Self.parakeetCacheDirectory(version: "parakeet-tdt-0.6b-v2-coreml")
            case .parakeetRealtime:
                return Self.parakeetCacheDirectory(version: "parakeet-eou-streaming/parakeet-eou-streaming/160ms")
            case .qwen3Asr:
                #if canImport(FluidAudio) && ENABLE_QWEN
                if #available(macOS 15.0, *) {
                    return Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory())
                }
                return false
                #else
                return false
                #endif
            case .cohereTranscribeSixBit:
                guard
                    let spec = self.externalCoreMLSpec,
                    let directory = SettingsStore.shared.externalCoreMLArtifactsDirectory(for: self)
                else {
                    return false
                }
                return spec.validateArtifacts(at: directory)
            case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                let hint: String
                switch self {
                case .nemotronOffline:
                    hint = "nemotron-3.5-asr-offline-6bit-CoreML"
                default:
                    hint = "nemotron-3.5-asr-streaming320-int8-CoreML"
                }
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent(hint, isDirectory: true)
                let requiredEntries = [
                    "metadata.json",
                    "preprocessor.mlpackage",
                    "encoder.mlpackage",
                    "decoder.mlpackage",
                    "joint.mlpackage",
                    "joint_decision.mlpackage",
                    "tokenizer.model",
                ]
                return directory.map { url in
                    requiredEntries.allSatisfy {
                        FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
                    }
                } ?? false
            default:
                // Whisper models
                guard let whisperFile = self.whisperModelFile else { return false }
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("WhisperModels")
                let modelURL = directory?.appendingPathComponent(whisperFile)
                return modelURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            }
        }

        private static func parakeetCacheDirectory(version: String) -> Bool {
            #if canImport(FluidAudio)
            let baseCacheDir = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
            let modelDir = baseCacheDir.appendingPathComponent(version)
            return FileManager.default.fileExists(atPath: modelDir.path)
            #else
            let baseCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent(version)
            return baseCacheDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            #endif
        }

        /// Brand/provider name for the model (NVIDIA, Apple, OpenAI)
        var brandName: String {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return "NVIDIA"
            case .qwen3Asr:
                return "Qwen"
            case .cohereTranscribeSixBit:
                return "Cohere"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "Apple"
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "OpenAI"
            }
        }

        /// Whether this model uses Apple's SF Symbol for branding (apple.logo)
        var usesAppleLogo: Bool {
            switch self {
            case .appleSpeech, .appleSpeechAnalyzer: return true
            default: return false
            }
        }

        /// Brand color for the provider badge
        var brandColorHex: String {
            switch self {
            case .parakeetTDT, .parakeetTDTv2, .parakeetRealtime, .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
                return "#76B900"
            case .qwen3Asr:
                return "#E67E22"
            case .cohereTranscribeSixBit:
                return "#FA6B3C"
            case .appleSpeech, .appleSpeechAnalyzer:
                return "#A2AAAD" // Apple Gray
            case .whisperTiny, .whisperBase, .whisperSmall, .whisperMedium, .whisperLargeTurbo, .whisperLarge:
                return "#10A37F" // OpenAI Teal
            }
        }
    }

    // MARK: - Transcription Provider (ASR)

    /// Available transcription providers
    enum TranscriptionProviderOption: String, CaseIterable, Identifiable {
        case auto
        case fluidAudio
        case whisper

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .auto: return "Automatic (Recommended)"
            case .fluidAudio: return "FluidAudio (Apple Silicon)"
            case .whisper: return "Whisper (Intel/Universal)"
            }
        }

        var description: String {
            switch self {
            case .auto: return "Uses FluidAudio on Apple Silicon, Whisper on Intel"
            case .fluidAudio: return "Fast CoreML-based transcription optimized for M-series chips"
            case .whisper: return "whisper.cpp - CPU-based, works on any Mac"
            }
        }
    }

    /// Selected transcription provider - defaults to "auto" which picks based on architecture
    var selectedTranscriptionProvider: TranscriptionProviderOption {
        get {
            guard let rawValue = defaults.string(forKey: Keys.selectedTranscriptionProvider),
                  let option = TranscriptionProviderOption(rawValue: rawValue)
            else {
                return .auto
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedTranscriptionProvider)
        }
    }

    /// Selected Whisper model size - defaults to "base"
    var whisperModelSize: WhisperModelSize {
        get {
            guard let rawValue = defaults.string(forKey: Keys.whisperModelSize),
                  let size = WhisperModelSize(rawValue: rawValue)
            else {
                return .base
            }
            return size
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.whisperModelSize)
        }
    }
}

// swiftlint:enable type_body_length

private extension SettingsStore {
    /// Keys
    enum Keys {
        static let enableAIProcessing = "EnableAIProcessing"
        static let showMainWindowAtLoginLaunch = "ShowMainWindowAtLoginLaunch"
        static let dictationPromptOff = "DictationPromptOff"
        static let enableDebugLogs = "EnableDebugLogs"
        static let availableAIModels = "AvailableAIModels"
        static let availableModelsByProvider = "AvailableModelsByProvider"
        static let selectedAIModel = "SelectedAIModel"
        static let selectedModelByProvider = "SelectedModelByProvider"
        static let selectedProviderID = "SelectedProviderID"
        static let privateAIPrefixKVCacheEnabled = "PrivateAIProviderPrefixKVCacheEnabled"
        static let providerAPIKeys = "ProviderAPIKeys"
        static let providerAPIKeyIdentifiers = "ProviderAPIKeyIdentifiers"
        static let savedProviders = "SavedProviders"
        static let verifiedProviderFingerprints = "VerifiedProviderFingerprints"
        static let shareAnonymousAnalytics = "ShareAnonymousAnalytics"
        static let privateAIInterestCaptured = "PrivateAIProviderInterestCaptured"
        static let hotkeyShortcutKey = "HotkeyShortcutKey"
        static let primaryDictationShortcutsKey = "PrimaryDictationShortcuts"
        static let preferredInputDeviceUID = "PreferredInputDeviceUID"
        static let preferredOutputDeviceUID = "PreferredOutputDeviceUID"
        static let syncAudioDevicesWithSystem = "SyncAudioDevicesWithSystem"
        static let visualizerNoiseThreshold = "VisualizerNoiseThreshold"
        static let launchAtStartup = "LaunchAtStartup"
        static let showInDock = "ShowInDock"
        static let accentColorOption = "AccentColorOption"
        static let themePreference = "ThemePreference"
        static let enableTranscriptionSounds = "EnableTranscriptionSounds"
        static let transcriptionStartSound = "TranscriptionStartSound"
        static let transcriptionSoundVolume = "TranscriptionSoundVolume"
        static let transcriptionSoundIndependentVolume = "TranscriptionSoundIndependentVolume"
        static let pressAndHoldMode = "PressAndHoldMode"
        static let hotkeyMode = "HotkeyMode"
        static let enableStreamingPreview = "EnableStreamingPreview"
        static let enableAIStreaming = "EnableAIStreaming"
        static let parakeetFinalizationMode = "ParakeetFinalizationMode"
        static let copyTranscriptionToClipboard = "CopyTranscriptionToClipboard"
        static let textInsertionMode = "TextInsertionMode"
        static let autoUpdateCheckEnabled = "AutoUpdateCheckEnabled"
        static let betaReleasesEnabled = "BetaReleasesEnabled"
        static let lastUpdateCheckDate = "LastUpdateCheckDate"
        static let updatePromptSnoozedUntil = "UpdatePromptSnoozedUntil"
        static let snoozedUpdateVersion = "SnoozedUpdateVersion"
        static let playgroundUsed = "PlaygroundUsed"
        static let onboardingCompleted = "OnboardingCompleted"
        static let onboardingGeneration = "OnboardingGeneration"
        static let onboardingCurrentStep = "OnboardingCurrentStep"
        static let onboardingAISkipped = "OnboardingAISkipped"
        static let onboardingPlaygroundValidated = "OnboardingPlaygroundValidated"
        static let onboardingPlaygroundSkipped = "OnboardingPlaygroundSkipped"
        static let onboardingSelectedLanguageID = "OnboardingSelectedLanguageID"

        // Command Mode Keys
        static let commandModeSelectedModel = "CommandModeSelectedModel"
        static let commandModeSelectedProviderID = "CommandModeSelectedProviderID"
        static let commandModeHotkeyShortcut = "CommandModeHotkeyShortcut"
        static let commandModeConfirmBeforeExecute = "CommandModeConfirmBeforeExecute"
        static let cancelRecordingHotkeyShortcut = "CancelRecordingHotkeyShortcut"
        static let commandModeLinkedToGlobal = "CommandModeLinkedToGlobal"
        static let commandModeShortcutEnabled = "CommandModeShortcutEnabled"

        // Prompt Mode Keys (Transcribe with Prompt)
        static let promptModeHotkeyShortcut = "PromptModeHotkeyShortcut"
        static let promptModeShortcutEnabled = "PromptModeShortcutEnabled"
        static let promptModeSelectedPromptID = "PromptModeSelectedPromptID"
        static let secondaryDictationPromptOff = "SecondaryDictationPromptOff"
        static let secondaryPromptShortcutRemoved = "SecondaryPromptShortcutRemoved"
        static let legacySecondaryPromptShortcutRetired = "LegacySecondaryPromptShortcutRetired"
        static let dictationPromptConfigurations = "DictationPromptConfigurations"

        // Rewrite Mode Keys
        static let rewriteModeHotkeyShortcut = "RewriteModeHotkeyShortcut"
        static let rewriteModeSelectedModel = "RewriteModeSelectedModel"
        static let rewriteModeSelectedProviderID = "RewriteModeSelectedProviderID"
        static let rewriteModeLinkedToGlobal = "RewriteModeLinkedToGlobal"

        // Model Reasoning Config Keys
        static let modelReasoningConfigs = "ModelReasoningConfigs"
        static let rewriteModeShortcutEnabled = "RewriteModeShortcutEnabled"
        static let showThinkingTokens = "ShowThinkingTokens"

        // Stats Keys
        static let userTypingWPM = "UserTypingWPM"
        static let saveTranscriptionHistory = "SaveTranscriptionHistory"
        static let saveAudioWithTranscriptionHistory = "SaveAudioWithTranscriptionHistory"
        static let audioHistoryBudgetGB = "AudioHistoryBudgetGB"
        static let notifyAIProcessingFailures = "NotifyAIProcessingFailures"

        // Filler Words
        static let fillerWords = "FillerWords"
        static let removeFillerWordsEnabled = "RemoveFillerWordsEnabled"

        /// GAAV Mode (removes capitalization and trailing punctuation)
        static let gaavModeEnabled = "GAAVModeEnabled"
        static let gaavLowercaseFirstLetterEnabled = "GAAVLowercaseFirstLetterEnabled"
        static let gaavRemoveTrailingPeriodEnabled = "GAAVRemoveTrailingPeriodEnabled"

        /// Continuous Dictation Mode (append trailing space + smart caps for chaining)
        static let continuousDictationModeEnabled = "ContinuousDictationModeEnabled"
        static let continuousDictationSpacingEnabled = "ContinuousDictationSpacingEnabled"
        static let contextAwareCapitalizationEnabled = "ContextAwareCapitalizationEnabled"

        // Custom Dictionary
        static let customDictionaryEntries = "CustomDictionaryEntries"
        static let vocabularyBoostingEnabled = "VocabularyBoostingEnabled"

        // Transcription Provider (ASR)
        static let selectedTranscriptionProvider = "SelectedTranscriptionProvider"
        static let whisperModelSize = "WhisperModelSize"

        /// Unified Speech Model (replaces above two)
        static let selectedSpeechModel = "SelectedSpeechModel"
        static let selectedCohereLanguage = "SelectedCohereLanguage"
        static let selectedNemotronLanguage = "SelectedNemotronLanguage"
        static let selectedAppleSpeechLocaleIdentifier = "SelectedAppleSpeechLocaleIdentifier"
        static let externalCoreMLArtifactsDirectories = "ExternalCoreMLArtifactsDirectories"

        // Overlay Position
        static let overlayPosition = "OverlayPosition"
        static let notchPresentationMode = "NotchPresentationMode"
        static let overlayBottomOffset = "OverlayBottomOffset"
        static let overlayBottomOffsetMigratedTo50 = "OverlayBottomOffsetMigratedTo50"
        static let overlaySize = "OverlaySize"
        static let transcriptionPreviewCharLimit = "TranscriptionPreviewCharLimit"

        /// Media Playback Control
        static let pauseMediaDuringTranscription = "PauseMediaDuringTranscription"

        /// Custom Dictation Prompt
        static let customDictationPrompt = "CustomDictationPrompt"

        // Dictation Prompt Profiles (multi-prompt system)
        static let dictationPromptProfiles = "DictationPromptProfiles"
        static let appPromptBindings = "AppPromptBindings"
        static let selectedDictationPromptID = "SelectedDictationPromptID"
        static let editPromptOff = "EditPromptOff"
        static let selectedEditPromptID = "SelectedEditPromptID"
        static let selectedWritePromptID = "SelectedWritePromptID" // legacy fallback key
        static let selectedRewritePromptID = "SelectedRewritePromptID" // legacy fallback key

        // Default Dictation Prompt Override (optional)
        // nil   => use built-in default prompt
        // ""    => use empty system prompt
        // other => use custom default prompt text
        static let defaultDictationPromptOverride = "DefaultDictationPromptOverride"
        static let defaultEditPromptOverride = "DefaultEditPromptOverride"
        static let defaultWritePromptOverride = "DefaultWritePromptOverride" // legacy fallback key
        static let defaultRewritePromptOverride = "DefaultRewritePromptOverride" // legacy fallback key

        /// Streak Settings
        static let weekendsDontBreakStreak = "WeekendsDontBreakStreak"
    }
}

extension SettingsStore {
    enum TextInsertionMode: String, CaseIterable, Identifiable, Codable {
        case standard
        case reliablePaste

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .standard:
                return "Clipboard Free Insert"
            case .reliablePaste:
                return "Clipboard Paste"
            }
        }

        var description: String {
            switch self {
            case .standard:
                return "Fastest path. Inserts text without changing the clipboard, with paste fallback if direct insertion is unavailable."
            case .reliablePaste:
                return "Compatibility path. Uses a temporary clipboard paste, so clipboard history apps may briefly record dictated text."
            }
        }
    }

    var textInsertionMode: TextInsertionMode {
        get {
            guard let raw = self.defaults.string(forKey: Keys.textInsertionMode),
                  let mode = TextInsertionMode(rawValue: raw)
            else {
                return .standard
            }
            return mode
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.textInsertionMode)
        }
    }

    var betaReleasesEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.betaReleasesEnabled)
            return value as? Bool ?? false // Default to stable-only updates
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.betaReleasesEnabled)
            self.lastUpdateCheckDate = nil
            self.clearUpdateSnooze()
        }
    }

    /// Available Whisper model sizes
    enum WhisperModelSize: String, CaseIterable, Identifiable {
        case tiny = "ggml-tiny.bin"
        case base = "ggml-base.bin"
        case small = "ggml-small.bin"
        case medium = "ggml-medium.bin"
        case large = "ggml-large-v3.bin"

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .tiny: return "Tiny (~75 MB)"
            case .base: return "Base (~142 MB)"
            case .small: return "Small (~466 MB)"
            case .medium: return "Medium (~1.5 GB)"
            case .large: return "Large (~2.9 GB)"
            }
        }

        var description: String {
            switch self {
            case .tiny: return "Fastest, lower accuracy"
            case .base: return "Good balance of speed and accuracy"
            case .small: return "Better accuracy, slower"
            case .medium: return "High accuracy, requires more memory"
            case .large: return "Best accuracy, large download"
            }
        }
    }
}

extension SettingsStore.SpeechModel {
    var supportedLanguageCodes: String? {
        switch self {
        case .parakeetTDT:
            return "BG, HR, CS, DA, NL, EN, ET, FI, FR, DE, EL, HU, IT, LV, LT, MT, PL, PT, RO, SK, SL, ES, SV, RU, UK"
        case .parakeetRealtime:
            return "EN"
        case .cohereTranscribeSixBit:
            return "AR, DE, EL, EN, ES, FR, IT, JA, KO, NL, PL, PT, VI, ZH"
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return "40 language-locales"
        case .appleSpeechAnalyzer:
            return "EN, ES, FR, DE, IT, JA, KO, PT, ZH"
        default:
            return nil
        }
    }

    var supportedLanguageNames: String? {
        switch self {
        case .parakeetTDT:
            return """
            Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Slovak, Slovenian, Spanish, Swedish, Russian, and Ukrainian
            """
        case .cohereTranscribeSixBit:
            return "Arabic, German, Greek, English, Spanish, French, Italian, Japanese, Korean, Dutch, Polish, Portuguese, Vietnamese, and Mandarin Chinese"
        case .nemotronOffline, .nemotronStreaming, .nemotronStreaming320:
            return "Spanish, Italian, Portuguese, Hindi, Korean, English, German, French, Russian, Turkish, Vietnamese, Dutch, Japanese, Arabic, " +
                "Ukrainian; Polish, Norwegian Bokmal, Finnish, Mandarin, Czech, Bulgarian, Slovak, Swedish, Croatian, Romanian, Estonian, " +
                "Danish, and Hungarian are Alpha; Greek, Hebrew, Lithuanian, Slovenian, Latvian, Maltese, Thai, and Norwegian Nynorsk are Experimental."
        default:
            return nil
        }
    }
}

extension SettingsStore {
    enum CohereLanguage: String, CaseIterable, Identifiable, Codable {
        case arabic = "ar"
        case german = "de"
        case greek = "el"
        case english = "en"
        case spanish = "es"
        case french = "fr"
        case italian = "it"
        case japanese = "ja"
        case korean = "ko"
        case dutch = "nl"
        case polish = "pl"
        case portuguese = "pt"
        case vietnamese = "vi"
        case mandarinChinese = "zh"

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .arabic: return "Arabic"
            case .german: return "German"
            case .greek: return "Greek"
            case .english: return "English"
            case .spanish: return "Spanish"
            case .french: return "French"
            case .italian: return "Italian"
            case .japanese: return "Japanese"
            case .korean: return "Korean"
            case .dutch: return "Dutch"
            case .polish: return "Polish"
            case .portuguese: return "Portuguese"
            case .vietnamese: return "Vietnamese"
            case .mandarinChinese: return "Mandarin Chinese"
            }
        }

        var tokenString: String {
            "<|\(self.rawValue)|>"
        }
    }

    // MARK: - Unified Speech Model Selection

    /// The selected speech recognition model.
    /// This unified setting replaces the old TranscriptionProviderOption + WhisperModelSize combination.
    var selectedSpeechModel: SpeechModel {
        get {
            // Check if already using new system
            if let rawValue = defaults.string(forKey: Keys.selectedSpeechModel),
               let model = SpeechModel(rawValue: rawValue)
            {
                // If Qwen was previously selected, transparently fall back while preview is disabled.
                if model == .qwen3Asr, !SpeechModel.qwenPreviewEnabled {
                    return SpeechModel.defaultModel
                }
                if model == .nemotronStreaming320 {
                    return .nemotronStreaming
                }
                // Validate model is available on this architecture
                if model.requiresAppleSilicon && !CPUArchitecture.isAppleSilicon {
                    return .whisperBase
                }
                if model.requiresMacOS15, #unavailable(macOS 15.0) {
                    return .whisperBase
                }
                if model.requiresMacOS26, #unavailable(macOS 26.0) {
                    return .whisperBase
                }
                return model
            }

            // Migration: Convert old settings to new SpeechModel
            return self.migrateToSpeechModel()
        }
        set {
            objectWillChange.send()
            let model = newValue == .nemotronStreaming320 ? SpeechModel.nemotronStreaming : newValue
            self.defaults.set(model.rawValue, forKey: Keys.selectedSpeechModel)
        }
    }

    var selectedCohereLanguage: CohereLanguage {
        get {
            if let rawValue = self.defaults.string(forKey: Keys.selectedCohereLanguage),
               let language = CohereLanguage(rawValue: rawValue)
            {
                return language
            }
            return .english
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedCohereLanguage)
        }
    }

    var selectedNemotronLanguage: NemotronLanguage {
        get {
            if let rawValue = self.defaults.string(forKey: Keys.selectedNemotronLanguage),
               let language = NemotronLanguage.supportedLanguage(rawValue: rawValue)
            {
                return language
            }
            return .english
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.selectedNemotronLanguage)
        }
    }

    func externalCoreMLArtifactsDirectory(for model: SpeechModel) -> URL? {
        guard let spec = model.externalCoreMLSpec else { return nil }
        let paths = self.defaults.dictionary(forKey: Keys.externalCoreMLArtifactsDirectories) as? [String: String] ?? [:]
        if let storedPath = paths[model.rawValue], storedPath.isEmpty == false {
            return URL(fileURLWithPath: storedPath, isDirectory: true)
        }

        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let fallback = cachesDirectory?.appendingPathComponent(spec.artifactFolderHint, isDirectory: true)
        guard let fallback else { return nil }
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    func setExternalCoreMLArtifactsDirectory(_ directory: URL?, for model: SpeechModel) {
        guard model.requiresExternalArtifacts else { return }
        objectWillChange.send()
        var paths = self.defaults.dictionary(forKey: Keys.externalCoreMLArtifactsDirectories) as? [String: String] ?? [:]
        if let directory {
            paths[model.rawValue] = directory.standardizedFileURL.path
        } else {
            paths.removeValue(forKey: model.rawValue)
        }
        self.defaults.set(paths, forKey: Keys.externalCoreMLArtifactsDirectories)
    }

    /// Migrates old TranscriptionProviderOption + WhisperModelSize settings to new SpeechModel
    private func migrateToSpeechModel() -> SpeechModel {
        let oldProvider = self.defaults.string(forKey: Keys.selectedTranscriptionProvider) ?? "auto"
        let oldWhisperSize = self.defaults.string(forKey: Keys.whisperModelSize) ?? "ggml-base.bin"

        let newModel: SpeechModel

        switch oldProvider {
        case "whisper":
            // Map old whisper size to new model
            switch oldWhisperSize {
            case "ggml-tiny.bin": newModel = .whisperTiny
            case "ggml-base.bin": newModel = .whisperBase
            case "ggml-small.bin": newModel = .whisperSmall
            case "ggml-medium.bin": newModel = .whisperMedium
            case "ggml-large-v3.bin": newModel = .whisperLarge
            default: newModel = .whisperBase
            }
        case "fluidAudio":
            newModel = CPUArchitecture.isAppleSilicon ? .parakeetTDT : .whisperBase
        default: // "auto"
            newModel = SpeechModel.defaultModel
        }

        // Persist the migrated value
        self.defaults.set(newModel.rawValue, forKey: Keys.selectedSpeechModel)
        DebugLogger.shared.info("Migrated speech model settings: \(oldProvider)/\(oldWhisperSize) -> \(newModel.rawValue)", source: "SettingsStore")

        return newModel
    }
}
