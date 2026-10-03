import Foundation

/// Keeps ownership until key-up, even if the recording stops or the setting changes.
/// This prevents a held Space from typing repeats into the destination application.
nonisolated struct HoldToMuteKeyState {
    private(set) var ownsSpace = false

    mutating func keyDown(isRepeat: Bool, canBegin: Bool) -> Bool {
        if self.ownsSpace, isRepeat {
            return true
        }
        // A fresh key-down proves a prior key-up was missed.
        self.ownsSpace = !isRepeat && canBegin
        return self.ownsSpace
    }

    mutating func keyUp() -> Bool {
        let consumed = self.ownsSpace
        self.ownsSpace = false
        return consumed
    }

    mutating func reconcile(isPhysicallyDown: Bool) {
        if !isPhysicallyDown {
            self.ownsSpace = false
        }
    }
}
