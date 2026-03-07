import Foundation

/// Manages the macOS system Globe/fn key behavior to prevent the Emoji Picker
/// from appearing when the Globe key is used as a FluidVoice hotkey.
///
/// Uses `CFPreferencesSetValue` to set `AppleFnUsageType` in the
/// `com.apple.HIToolbox` domain:
///   0 = Do Nothing, 1 = Change Input Source, 2 = Show Emoji & Symbols, 3 = Start Dictation
@MainActor
final class GlobeKeyManager {
    static let shared = GlobeKeyManager()
    static let globeKeyCode: UInt16 = 63
    /// Synthetic "Globe function" key that macOS generates alongside the fn flagsChanged event.
    /// This keyDown/keyUp is what actually triggers the Emoji Picker.
    static let globeSyntheticKeyCode: UInt16 = 179

    private let domain = "com.apple.HIToolbox" as CFString
    private let key = "AppleFnUsageType" as CFString

    private let savedOriginalKey = "GlobeKeyOriginalFnUsageType"
    private let overrideActiveKey = "GlobeKeyOverrideActive"

    private init() {
        // Crash recovery: if the app was killed while the override was active,
        // restore the original setting before anything else runs.
        if UserDefaults.standard.bool(forKey: self.overrideActiveKey) {
            DebugLogger.shared.warning(
                "Globe key override was still active from previous session - restoring",
                source: "GlobeKeyManager"
            )
            self.restoreSystemGlobeAction()
        }
    }

    /// Suppress the system Globe key action by setting `AppleFnUsageType` to 0 ("Do Nothing").
    /// Saves the original value so it can be restored later.
    func suppressSystemGlobeAction() {
        let isAlreadyActive = UserDefaults.standard.bool(forKey: self.overrideActiveKey)

        if !isAlreadyActive {
            // Only save original value on first activation (not on re-suppress)
            let currentValue = CFPreferencesCopyValue(
                self.key, self.domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
            )
            let originalValue = (currentValue as? Int) ?? 2 // Default is 2 (Emoji & Symbols)
            UserDefaults.standard.set(originalValue, forKey: self.savedOriginalKey)
        }

        UserDefaults.standard.set(true, forKey: self.overrideActiveKey)

        // Set to 0 = "Do Nothing"
        CFPreferencesSetValue(
            self.key, 0 as CFNumber, self.domain,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(self.domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)

        // Notify the system to re-read the preference (otherwise the cached value is used)
        self.postFnUsageTypeChanged()

        DebugLogger.shared.info(
            "Suppressed system Globe key action (wasAlreadyActive: \(isAlreadyActive))",
            source: "GlobeKeyManager"
        )
    }

    /// Restore the original system Globe key action.
    func restoreSystemGlobeAction() {
        guard UserDefaults.standard.bool(forKey: self.overrideActiveKey) else {
            return
        }

        let originalValue = UserDefaults.standard.integer(forKey: self.savedOriginalKey)

        CFPreferencesSetValue(
            self.key, originalValue as CFNumber, self.domain,
            kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        )
        CFPreferencesSynchronize(self.domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)

        UserDefaults.standard.removeObject(forKey: self.savedOriginalKey)
        UserDefaults.standard.removeObject(forKey: self.overrideActiveKey)

        self.postFnUsageTypeChanged()

        DebugLogger.shared.info(
            "Restored system Globe key action (value: \(originalValue))",
            source: "GlobeKeyManager"
        )
    }

    /// Notify the system that `AppleFnUsageType` changed so running processes pick up the new value.
    private func postFnUsageTypeChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.HIToolbox.AppleFnUsageTypeChangedNotification"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Check whether the given shortcut is the Globe/fn key (keyCode 63 with no modifiers).
    nonisolated static func isGlobeKey(_ shortcut: HotkeyShortcut) -> Bool {
        return shortcut.keyCode == Self.globeKeyCode && shortcut.modifierFlags.isEmpty
    }
}
