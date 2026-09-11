import AppKit
import Carbon
#if !HOTKEY_STANDALONE_TESTS
@testable import FluidVoice_Debug
#endif
import XCTest

@MainActor
private final class FakeHotkeyDriver: RegisteredHotkeyDriver {
    var onEvent: ((UInt32, Bool) -> Void)?
    var status: OSStatus = noErr
    var registered: [UInt32: RegisteredHotkeyChord] = [:]
    var removed: [UInt32] = []

    func register(_ chord: RegisteredHotkeyChord, id: UInt32) -> OSStatus {
        if self.status == noErr {
            self.registered[id] = chord
        }
        return self.status
    }

    func unregister(id: UInt32) {
        self.registered.removeValue(forKey: id)
        self.removed.append(id)
    }
}

final class RegisteredHotkeysTests: XCTestCase {
    @MainActor
    func testNativeRegistrationIsReleasedWhenDriverIsDestroyed() throws {
        // Use an uncommon chord so this test never takes over a normal app action.
        let chord = try XCTUnwrap(RegisteredHotkeyChord(HotkeyShortcut(keyCode: 79, modifierFlags: [.control, .option])))
        var first: CarbonHotkeyDriver? = CarbonHotkeyDriver()
        let status = try XCTUnwrap(first).register(chord, id: 1)
        guard status == noErr else {
            throw XCTSkip("Native hotkey registration unavailable in this session: \(status)")
        }
        first = nil
        let second = CarbonHotkeyDriver()
        XCTAssertEqual(second.register(chord, id: 1), noErr)
        second.unregister(id: 1)
        XCTAssertEqual(second.register(chord, id: 2), noErr)
        second.unregister(id: 2)
    }

    @MainActor
    func testRequestsExclusiveOwnershipAndFallsBackWhenDenied() {
        var attempted = false
        let driver = CarbonHotkeyDriver { _, _, _, _, options, _ in
            attempted = true
            XCTAssertEqual(options, OptionBits(kEventHotKeyExclusive))
            return OSStatus(eventHotKeyExistsErr)
        }
        let hotkeys = RegisteredHotkeys(driver: driver)
        hotkeys.update(shortcuts: [HotkeyShortcut(keyCode: 49, modifierFlags: .option)])
        XCTAssertTrue(attempted)
        XCTAssertFalse(hotkeys.shouldBypassEventTap(keyCode: 49, modifiers: .option, down: true))
    }

    @MainActor
    func testNativeConflictRetainsEventTapFallbackUntilOwnerReleases() throws {
        let shortcut = HotkeyShortcut(keyCode: 80, modifierFlags: [.control, .option])
        let chord = try XCTUnwrap(RegisteredHotkeyChord(shortcut))
        let owner = CarbonHotkeyDriver()
        let status = owner.register(chord, id: 1)
        guard status == noErr else { throw XCTSkip("Native registration unavailable: \(status)") }
        defer { owner.unregister(id: 1) }
        let hotkeys = RegisteredHotkeys(driver: CarbonHotkeyDriver())
        var failures: [OSStatus] = []
        hotkeys.onFailure = { _, status in failures.append(status) }
        hotkeys.update(shortcuts: [shortcut])
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(hotkeys.shouldBypassEventTap(keyCode: 80, modifiers: [.control, .option], down: true))
        owner.unregister(id: 1)
        hotkeys.update(shortcuts: [shortcut])
        XCTAssertTrue(hotkeys.shouldBypassEventTap(keyCode: 80, modifiers: [.control, .option], down: true))
    }

    @MainActor
    func testInterruptionIsVisibleDuringReleaseAndDoesNotLeakToNextPress() throws {
        let driver = FakeHotkeyDriver()
        let hotkeys = RegisteredHotkeys(driver: driver)
        hotkeys.update(shortcuts: [HotkeyShortcut(keyCode: 49, modifierFlags: .option)])
        let id = try XCTUnwrap(driver.registered.keys.first)
        var interruptions: [Bool] = []
        hotkeys.onEvent = { _, down in
            if !down {
                interruptions.append(hotkeys.isInterruptingPress)
            }
        }
        defer { hotkeys.onEvent = nil }
        driver.onEvent?(id, true)
        hotkeys.releaseAll(interrupted: true)
        driver.onEvent?(id, false) // stale physical release must not finish twice
        XCTAssertFalse(hotkeys.isInterruptingPress)
        driver.onEvent?(id, true)
        driver.onEvent?(id, false)
        XCTAssertEqual(interruptions, [true, false])
    }

    @MainActor
    func testChordEligibilityPreservesPlainKeysAndModifierOnlyShortcuts() {
        let optionSpace = HotkeyShortcut(keyCode: 49, modifierFlags: .option)
        XCTAssertEqual(RegisteredHotkeyChord(optionSpace)?.shortcut, optionSpace)
        XCTAssertNil(RegisteredHotkeyChord(HotkeyShortcut(keyCode: 49, modifierFlags: [])))
        XCTAssertNil(RegisteredHotkeyChord(HotkeyShortcut(keyCode: 61, modifierFlags: [])))
        XCTAssertNil(RegisteredHotkeyChord(HotkeyShortcut(keyCode: 49, modifierFlags: [.function, .option])))
        XCTAssertNil(RegisteredHotkeyChord(HotkeyShortcut(mouseButton: 2, modifierFlags: .option)))
    }

    @MainActor
    func testCarbonDeliveryWorksWithoutAnyEventTapEventsAndIgnoresRepeats() throws {
        let driver = FakeHotkeyDriver()
        let hotkeys = RegisteredHotkeys(driver: driver)
        let shortcut = HotkeyShortcut(keyCode: 49, modifierFlags: .option)
        var edges: [Bool] = []
        hotkeys.onEvent = { actual, down in
            XCTAssertEqual(actual, shortcut)
            edges.append(down)
        }
        hotkeys.update(shortcuts: [shortcut])
        let id = try XCTUnwrap(driver.registered.keys.first)
        driver.onEvent?(id, true)
        driver.onEvent?(id, true)
        driver.onEvent?(id, false)
        driver.onEvent?(id, false)
        XCTAssertEqual(edges, [true, false])
    }

    @MainActor
    func testEventTapPassesRegisteredChordAndReleaseAfterModifierReleased() {
        let driver = FakeHotkeyDriver()
        let hotkeys = RegisteredHotkeys(driver: driver)
        hotkeys.update(shortcuts: [HotkeyShortcut(keyCode: 49, modifierFlags: .option)])
        XCTAssertTrue(hotkeys.shouldBypassEventTap(keyCode: 49, modifiers: .option, down: true))
        XCTAssertTrue(hotkeys.shouldBypassEventTap(keyCode: 49, modifiers: [], down: false))
        XCTAssertFalse(hotkeys.shouldBypassEventTap(keyCode: 49, modifiers: [], down: true))
        XCTAssertFalse(hotkeys.shouldBypassEventTap(keyCode: 49, modifiers: [], down: false))
    }

    @MainActor
    func testFailedRegistrationFallsBackAndReportsError() {
        let driver = FakeHotkeyDriver()
        driver.status = OSStatus(eventHotKeyExistsErr)
        let hotkeys = RegisteredHotkeys(driver: driver)
        var failures: [OSStatus] = []
        hotkeys.onFailure = { _, status in failures.append(status) }
        hotkeys.update(shortcuts: [HotkeyShortcut(keyCode: 49, modifierFlags: .option)])
        XCTAssertEqual(failures, [OSStatus(eventHotKeyExistsErr)])
        XCTAssertFalse(hotkeys.shouldBypassEventTap(keyCode: 49, modifiers: .option, down: true))
        driver.status = noErr
        hotkeys.update(shortcuts: [HotkeyShortcut(keyCode: 49, modifierFlags: .option)])
        XCTAssertTrue(hotkeys.shouldBypassEventTap(keyCode: 49, modifiers: .option, down: true))
    }

    @MainActor
    func testRefreshKeepsExistingRegistrationAndDeduplicatesIdenticalChords() {
        let driver = FakeHotkeyDriver()
        let hotkeys = RegisteredHotkeys(driver: driver)
        let shortcut = HotkeyShortcut(keyCode: 49, modifierFlags: .option)
        hotkeys.update(shortcuts: [shortcut, shortcut])
        let original = driver.registered
        hotkeys.update(shortcuts: [shortcut])
        XCTAssertEqual(driver.registered, original)
        XCTAssertEqual(driver.registered.count, 1)
        XCTAssertTrue(driver.removed.isEmpty)
    }

    @MainActor
    func testShortcutCaptureUnregistersAndFinishesHeldShortcutBeforeRemoval() throws {
        let driver = FakeHotkeyDriver()
        let hotkeys = RegisteredHotkeys(driver: driver)
        let shortcut = HotkeyShortcut(keyCode: 49, modifierFlags: .option)
        var edges: [Bool] = []
        hotkeys.onEvent = { _, down in edges.append(down) }
        hotkeys.update(shortcuts: [shortcut])
        let id = try XCTUnwrap(driver.registered.keys.first)
        driver.onEvent?(id, true)
        hotkeys.update(shortcuts: [])
        XCTAssertEqual(edges, [true, false])
        XCTAssertTrue(driver.registered.isEmpty)
        driver.onEvent?(id, true) // queued stale event after removal
        XCTAssertEqual(edges, [true, false])
        hotkeys.update(shortcuts: [shortcut])
        XCTAssertNotEqual(driver.registered.keys.first, id)
    }

    @MainActor
    func testRefreshDuringPressPreservesReleaseOwnership() throws {
        let driver = FakeHotkeyDriver()
        let hotkeys = RegisteredHotkeys(driver: driver)
        let shortcut = HotkeyShortcut(keyCode: 49, modifierFlags: .option)
        var edges: [Bool] = []
        hotkeys.onEvent = { _, down in edges.append(down) }
        hotkeys.update(shortcuts: [shortcut])
        let id = try XCTUnwrap(driver.registered.keys.first)
        driver.onEvent?(id, true)
        hotkeys.update(shortcuts: [shortcut]) // event-tap recovery must not rebuild Carbon
        XCTAssertTrue(hotkeys.hasPressedShortcut)
        XCTAssertEqual(edges, [true])
        driver.onEvent?(id, false)
        XCTAssertFalse(hotkeys.hasPressedShortcut)
        XCTAssertEqual(edges, [true, false])
    }

    @MainActor
    func testReleaseAllBalancesEveryPressAndRejectsLateRelease() {
        let driver = FakeHotkeyDriver()
        let hotkeys = RegisteredHotkeys(driver: driver)
        hotkeys.update(shortcuts: [
            HotkeyShortcut(keyCode: 49, modifierFlags: .option),
            HotkeyShortcut(keyCode: 15, modifierFlags: [.control, .option]),
        ])
        var edges: [Bool] = []
        hotkeys.onEvent = { _, down in edges.append(down) }
        for id in driver.registered.keys {
            driver.onEvent?(id, true)
        }
        hotkeys.releaseAll()
        for id in driver.registered.keys {
            driver.onEvent?(id, false)
        }
        XCTAssertEqual(edges, [true, true, false, false])
    }
}

#if HOTKEY_STANDALONE_TESTS
@main
struct RegisteredHotkeysTestRunner {
    static func main() {
        let suite = RegisteredHotkeysTests.defaultTestSuite
        suite.run()
        exit(suite.testRun?.hasSucceeded == true ? 0 : 1)
    }
}
#endif
