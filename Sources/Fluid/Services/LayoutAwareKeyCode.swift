import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Resolves the virtual key code that produces a given character under the *current*
/// keyboard layout.
///
/// Synthetic keyboard shortcuts (Cmd+C, Cmd+V) are posted by virtual key code, not by
/// character. A hard-coded ANSI key code (e.g. `kVK_ANSI_V` = 9) only lands on the right
/// physical key for QWERTY layouts; on Dvorak/AZERTY/QWERTZ the same key code produces a
/// different character, so the shortcut silently misfires. This looks up the key code for
/// the desired character in the active layout instead.
///
/// Shared by `TypingService` (Cmd+V paste insertion) and `TextSelectionService` (Cmd+C
/// selection-read fallback) so both paths use one implementation rather than duplicating
/// the TIS / `UCKeyTranslate` scan.
enum LayoutAwareKeyCode {
    /// Returns the virtual key code that produces `character` under the current keyboard
    /// layout, falling back to `qwertyFallback` when the layout data is unavailable.
    ///
    /// Re-evaluated on every call so a runtime keyboard-layout switch is picked up
    /// immediately. The underlying TIS API must run on the main thread, so the lookup is
    /// dispatched there when called from a background thread.
    /// - Parameter carbonModifierState: the modifier state the emitted shortcut will actually carry,
    ///   in the format `UCKeyTranslate` expects (Carbon modifier bits shifted right by 8). This
    ///   matters on modifier-dependent layouts: under macOS's built-in "Dvorak - QWERTY ⌘" the key
    ///   that produces `c` unmodified is not the key that produces `c` with Command held, so
    ///   resolving with no modifier yields a key code that invokes a different shortcut entirely.
    static func virtualKeyCode(
        for character: Character,
        qwertyFallback: CGKeyCode,
        carbonModifierState: UInt32 = 0
    ) -> CGKeyCode {
        if Thread.isMainThread {
            return self.tisLookup(
                for: character,
                qwertyFallback: qwertyFallback,
                carbonModifierState: carbonModifierState
            )
        }
        var result = qwertyFallback
        DispatchQueue.main.sync {
            result = self.tisLookup(
                for: character,
                qwertyFallback: qwertyFallback,
                carbonModifierState: carbonModifierState
            )
        }
        return result
    }

    /// The `UCKeyTranslate` modifier state for a Command-held shortcut.
    static let commandModifierState = UInt32(cmdKey >> 8)

    /// Performs the actual TIS + `UCKeyTranslate` scan. Must be called on the main thread.
    private static func tisLookup(
        for character: Character,
        qwertyFallback: CGKeyCode,
        carbonModifierState: UInt32
    ) -> CGKeyCode {
        guard let targetScalar = character.unicodeScalars.first else { return qwertyFallback }

        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData)
        else {
            return qwertyFallback
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawPtr).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layoutPtr = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return qwertyFallback
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let kbType = UInt32(LMGetKbdType())

            for keyCode: UInt16 in 0..<128 {
                deadKeyState = 0
                length = 0
                let status = UCKeyTranslate(
                    layoutPtr,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    carbonModifierState,
                    kbType,
                    UInt32(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
                guard status == noErr, length > 0 else { continue }
                if Unicode.Scalar(chars[0]) == targetScalar {
                    return CGKeyCode(keyCode)
                }
            }
            return qwertyFallback
        }
    }
}
