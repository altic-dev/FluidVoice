import CoreGraphics
import XCTest

@testable import FluidVoice_Debug

/// Regression coverage for the system-shortcut fast path in `GlobalHotkeyManager`.
///
/// The event tap fires for every key event system-wide, so Command-modified switching
/// shortcuts (Cmd+Tab, Cmd+Shift+Tab, Cmd+Space, Cmd+`) must be passed straight through
/// before any matching work, otherwise app switching / Spotlight pick up perceptible
/// latency (which compounds when VoiceOver is also intercepting the same events).
final class GlobalHotkeyManagerSystemShortcutTests: XCTestCase {
    // Virtual key codes (kVK_*).
    private let tab: UInt16 = 48
    private let space: UInt16 = 49
    private let grave: UInt16 = 50
    private let escape: UInt16 = 53

    func testCommandSystemShortcutsArePassedThrough() {
        for keyCode in [self.tab, self.space, self.grave] {
            XCTAssertTrue(
                GlobalHotkeyManager.isSystemShortcutPassthrough(
                    type: .keyDown, flags: .maskCommand, keyCode: keyCode
                ),
                "Cmd + keyCode \(keyCode) keyDown should be passed straight through"
            )
            XCTAssertTrue(
                GlobalHotkeyManager.isSystemShortcutPassthrough(
                    type: .keyUp, flags: .maskCommand, keyCode: keyCode
                ),
                "Cmd + keyCode \(keyCode) keyUp should be passed straight through"
            )
        }
    }

    func testCommandShiftTabIsPassedThrough() {
        // Cmd+Shift+Tab (reverse app switch): extra modifiers must not defeat the fast path.
        XCTAssertTrue(
            GlobalHotkeyManager.isSystemShortcutPassthrough(
                type: .keyDown, flags: [.maskCommand, .maskShift], keyCode: self.tab
            )
        )
    }

    func testNonCommandKeysAreNotPassedThrough() {
        // The same keys without Command must still reach the matching machinery.
        for keyCode in [self.tab, self.space, self.grave] {
            XCTAssertFalse(
                GlobalHotkeyManager.isSystemShortcutPassthrough(
                    type: .keyDown, flags: [], keyCode: keyCode
                )
            )
        }
    }

    func testUnrelatedCommandShortcutIsNotPassedThrough() {
        // e.g. Cmd+Escape is not one of the fast-pathed switching shortcuts.
        XCTAssertFalse(
            GlobalHotkeyManager.isSystemShortcutPassthrough(
                type: .keyDown, flags: .maskCommand, keyCode: self.escape
            )
        )
    }

    func testNonKeyEventsAreNotPassedThrough() {
        // flagsChanged carries the Command press itself and must flow through normal
        // handling so modifier tracking stays consistent.
        XCTAssertFalse(
            GlobalHotkeyManager.isSystemShortcutPassthrough(
                type: .flagsChanged, flags: .maskCommand, keyCode: self.tab
            )
        )
    }
}
