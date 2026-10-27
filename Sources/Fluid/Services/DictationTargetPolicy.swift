import Foundation

/// Ordinary dictation may follow the current cursor. Rewrite and retry callers
/// retain their captured destination unless they explicitly opt into this policy.
enum DictationTargetPolicy {
    static func resolve(
        returnToStartingField: Bool,
        focusedPID: Int32?,
        ownPID: Int32,
        originalPID: Int32?,
        originalFieldIsFocused: Bool
    ) -> (pid: Int32?, shouldRestoreOriginalFocus: Bool) {
        if !returnToStartingField, let focusedPID, focusedPID > 0, focusedPID != ownPID {
            return (focusedPID, false)
        }
        // An app-owned overlay may temporarily hold focus. Recover the saved
        // field in that case, rather than treating the overlay as a destination.
        return (originalPID, !originalFieldIsFocused)
    }
}
