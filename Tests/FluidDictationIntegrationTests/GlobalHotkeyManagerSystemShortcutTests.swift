import AppKit
import CoreGraphics
import XCTest

@testable import FluidVoice_Debug

/// Regression coverage for the system-shortcut fast path in `GlobalHotkeyManager`.
///
/// The event tap fires for every key event system-wide, so Command-modified switching
/// shortcuts (Cmd+Tab, Cmd+Shift+Tab, Cmd+Space, Cmd+`) must be passed straight through
/// before any matching work, otherwise app switching / Spotlight pick up perceptible
/// latency (which compounds when VoiceOver is also intercepting the same events).
///
/// The fast path must NOT shadow a user's saved shortcut: the recorder accepts arbitrary
/// keyDown combos, so a user can bind e.g. Cmd+Space as a FluidVoice shortcut. The
/// `shouldFastPathSystemShortcut` tests cover that a configured combo falls through to
/// normal matching while the latency win is preserved for the non-conflicting case.
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

    // MARK: - Conflict-aware fast path (shouldFastPathSystemShortcut)

    func testConfiguredCommandSpaceIsNotFastPathed() {
        // A user who bound Cmd+Space as a FluidVoice shortcut must keep their shortcut: the
        // fast path is suppressed for BOTH keyDown and keyUp so the event reaches normal
        // matching (and keyUp release handling) instead of being passed straight through.
        let configured: [(shortcut: HotkeyShortcut, isEnabled: Bool)] = [
            (HotkeyShortcut(keyCode: self.space, modifierFlags: [.command]), true),
        ]

        XCTAssertFalse(
            GlobalHotkeyManager.shouldFastPathSystemShortcut(
                type: .keyDown, flags: .maskCommand, keyCode: self.space, configuredShortcuts: configured
            ),
            "A configured Cmd+Space must not be fast-pathed on keyDown"
        )
        XCTAssertFalse(
            GlobalHotkeyManager.shouldFastPathSystemShortcut(
                type: .keyUp, flags: .maskCommand, keyCode: self.space, configuredShortcuts: configured
            ),
            "A configured Cmd+Space must not be fast-pathed on keyUp"
        )
    }

    func testDisabledConfiguredCommandSpaceStillFastPaths() {
        // A disabled mode shortcut bound to Cmd+Space must not block the fast path.
        let configured: [(shortcut: HotkeyShortcut, isEnabled: Bool)] = [
            (HotkeyShortcut(keyCode: self.space, modifierFlags: [.command]), false),
        ]

        XCTAssertTrue(
            GlobalHotkeyManager.shouldFastPathSystemShortcut(
                type: .keyDown, flags: .maskCommand, keyCode: self.space, configuredShortcuts: configured
            )
        )
    }

    func testNonConflictingSystemShortcutStillFastPaths() {
        // The latency win is preserved for the common case: a configured shortcut on a
        // different combo (Cmd+`) must not stop Cmd+Space / Cmd+Tab from fast-pathing.
        let configured: [(shortcut: HotkeyShortcut, isEnabled: Bool)] = [
            (HotkeyShortcut(keyCode: self.grave, modifierFlags: [.command]), true),
        ]

        for keyCode in [self.tab, self.space] {
            XCTAssertTrue(
                GlobalHotkeyManager.shouldFastPathSystemShortcut(
                    type: .keyDown, flags: .maskCommand, keyCode: keyCode, configuredShortcuts: configured
                ),
                "Cmd + keyCode \(keyCode) should still fast-path when only Cmd+` is configured"
            )
        }

        // With no configured shortcuts at all, every candidate fast-paths.
        XCTAssertTrue(
            GlobalHotkeyManager.shouldFastPathSystemShortcut(
                type: .keyDown, flags: .maskCommand, keyCode: self.space, configuredShortcuts: []
            )
        )
    }

    func testConfiguredNonSystemShortcutIsNeverFastPathed() {
        // Even if a configured shortcut matches the incoming combo, a non-candidate combo
        // (Cmd+Escape) is never fast-pathed — the fast path is only for switching shortcuts.
        let configured: [(shortcut: HotkeyShortcut, isEnabled: Bool)] = [
            (HotkeyShortcut(keyCode: self.escape, modifierFlags: [.command]), true),
        ]

        XCTAssertFalse(
            GlobalHotkeyManager.shouldFastPathSystemShortcut(
                type: .keyDown, flags: .maskCommand, keyCode: self.escape, configuredShortcuts: configured
            )
        )
    }

    func testEventModifierFlagsMapping() {
        let modifiers = GlobalHotkeyManager.eventModifierFlags(from: [.maskCommand, .maskShift])
        XCTAssertTrue(modifiers.contains(.command))
        XCTAssertTrue(modifiers.contains(.shift))
        XCTAssertFalse(modifiers.contains(.option))
        XCTAssertFalse(modifiers.contains(.control))
    }
}
