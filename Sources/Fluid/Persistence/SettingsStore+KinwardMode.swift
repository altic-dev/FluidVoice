import Combine
import Foundation

/// Settings for Kinward Mode: push-to-talk / wake-word voice turns routed directly to the
/// Kinward household backend's `/api/v1/integration/conversation` endpoint, bypassing Home
/// Assistant's Assist pipeline entirely (no Area/location context, just memory + personality +
/// tools). The bearer token itself lives in the Keychain (KinwardClient.keychainProviderID),
/// never here — everything in this file is non-secret configuration.
extension SettingsStore {
    private var kinwardBaseURLKey: String { "KinwardBaseURL" }
    private var kinwardHAUserIDKey: String { "KinwardHAUserID" }
    private var kinwardAssistantIDKey: String { "KinwardAssistantID" }
    private var kinwardConversationIDKey: String { "KinwardConversationID" }
    private var kinwardTTSVoiceIdentifierKey: String { "KinwardTTSVoiceIdentifier" }
    private var kinwardWakeWordEnabledKey: String { "KinwardWakeWordEnabled" }
    private var kinwardWakeWordSensitivityKey: String { "KinwardWakeWordSensitivity" }
    private var kinwardWakeWordKeywordPathKey: String { "KinwardWakeWordKeywordPath" }
    private var kinwardHotkeyEnabledKey: String { "KinwardHotkeyEnabled" }

    /// e.g. "https://kinward.example-household.internal" - no trailing path.
    var kinwardBaseURL: String {
        get { UserDefaults.standard.string(forKey: self.kinwardBaseURLKey) ?? "" }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.kinwardBaseURLKey)
        }
    }

    /// The stable identity string already stored on Marc's PersonRecord.ha_user_id in Kinward -
    /// reused as-is, not a live Home Assistant session. See docs/adr on cross-principal access.
    var kinwardHAUserID: String {
        get { UserDefaults.standard.string(forKey: self.kinwardHAUserIDKey) ?? "" }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.kinwardHAUserIDKey)
        }
    }

    /// Optional: address a specific (non-default) assistant. Empty means "my primary assistant".
    var kinwardAssistantID: String {
        get { UserDefaults.standard.string(forKey: self.kinwardAssistantIDKey) ?? "" }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.kinwardAssistantIDKey)
        }
    }

    /// Persisted Kinward topic id for turn-to-turn continuity. Cleared by
    /// KinwardClient.startNewConversation() to explicitly start a new topic.
    var kinwardConversationID: String {
        get { UserDefaults.standard.string(forKey: self.kinwardConversationIDKey) ?? "" }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.kinwardConversationIDKey)
        }
    }

    /// AVSpeechSynthesisVoice.identifier for spoken replies. Empty means "system default".
    var kinwardTTSVoiceIdentifier: String {
        get { UserDefaults.standard.string(forKey: self.kinwardTTSVoiceIdentifierKey) ?? "" }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.kinwardTTSVoiceIdentifierKey)
        }
    }

    var kinwardWakeWordEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: self.kinwardWakeWordEnabledKey) }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.kinwardWakeWordEnabledKey)
        }
    }

    /// Absolute path to a Porcupine `.ppn` keyword file (a custom-trained "Hey Kinward" from
    /// https://console.picovoice.ai, or one of Porcupine's bundled mac keywords). Not a secret,
    /// just a local file path - safe in UserDefaults.
    var kinwardWakeWordKeywordPath: String {
        get { UserDefaults.standard.string(forKey: self.kinwardWakeWordKeywordPathKey) ?? "" }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.kinwardWakeWordKeywordPathKey)
        }
    }

    private static let wakeWordAccessKeyProviderID = "kinward-wakeword-picovoice-accesskey"

    /// Picovoice Console AccessKey (console.picovoice.ai) - a real secret, stored in the
    /// Keychain via the same generic helper KinwardClient's token uses, not UserDefaults.
    var kinwardWakeWordAccessKey: String {
        get {
            (try? KeychainService.shared.fetchKey(for: Self.wakeWordAccessKeyProviderID)).flatMap { $0 } ?? ""
        }
        set {
            self.objectWillChange.send()
            try? KeychainService.shared.storeKey(newValue, for: Self.wakeWordAccessKeyProviderID)
        }
    }

    /// 0...1, higher = fewer misses but more false triggers. Picovoice default is 0.5.
    var kinwardWakeWordSensitivity: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: self.kinwardWakeWordSensitivityKey) as? Double
            return stored ?? 0.5
        }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.kinwardWakeWordSensitivityKey)
        }
    }

    var kinwardHotkeyEnabled: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: self.kinwardHotkeyEnabledKey) as? Bool {
                return value
            }
            return true
        }
        set {
            self.objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: self.kinwardHotkeyEnabledKey)
        }
    }

    /// True once enough is configured to actually place a call (token presence checked separately
    /// via Keychain at call time, since it's not readable synchronously here without a throw).
    var kinwardModeReadinessIssue: String? {
        guard !self.kinwardBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Kinward Mode needs a backend URL."
        }
        guard !self.kinwardHAUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Kinward Mode needs your household user id."
        }
        guard KeychainService.shared.containsKey(for: KinwardClient.keychainProviderID) else {
            return "Kinward Mode needs an integration token (Settings > Kinward)."
        }
        return nil
    }
}
