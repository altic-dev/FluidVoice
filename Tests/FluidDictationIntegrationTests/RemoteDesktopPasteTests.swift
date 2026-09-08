import Carbon.HIToolbox
import CoreGraphics
@testable import FluidVoice_Debug
import XCTest

/// Covers the remote-desktop (Windows App / Microsoft Remote Desktop) insertion path.
///
/// The assertions deliberately avoid absolute flag patterns and cross-call reference events:
/// `CGEvent(keyboardEventSource: nil, ...)` derives part of its flags from ambient session
/// modifier state and from event coalescing, so anything pinned to a literal bit pattern fails
/// for reasons unrelated to the code under test. Everything here is either a bit this code sets
/// itself or a comparison within a single chord.
final class RemoteDesktopPasteTests: XCTestCase {
    private let pasteKeyCode: CGKeyCode = 9

    private func makeControlChord() throws -> TypingService.SyntheticChord {
        try XCTUnwrap(
            TypingService.makeRemoteDesktopChord(
                modifierKeyCode: CGKeyCode(kVK_Control),
                keyCode: self.pasteKeyCode
            ),
            "Chord construction must succeed in a plain unit-test process"
        )
    }

    private func keyCode(_ event: CGEvent) -> Int64 {
        event.getIntegerValueField(.keyboardEventKeycode)
    }

    // MARK: - Shape

    func testControlChordIsModifierDownKeyDownKeyUpModifierUp() throws {
        let chord = try self.makeControlChord()

        XCTAssertEqual(chord.ordered.count, 4)
        XCTAssertEqual(
            chord.ordered.map(\.type),
            [.flagsChanged, .keyDown, .keyUp, .flagsChanged],
            "The modifier must arrive as flagsChanged either side of the key events"
        )
        XCTAssertEqual(
            chord.ordered.map(self.keyCode),
            [Int64(kVK_Control), Int64(self.pasteKeyCode), Int64(self.pasteKeyCode), Int64(kVK_Control)],
            "A client translating scan codes needs the modifier key code preserved, not discarded"
        )
    }

    func testChordWithoutModifierIsJustTheKeyPress() throws {
        let chord = try XCTUnwrap(
            TypingService.makeRemoteDesktopChord(modifierKeyCode: nil, keyCode: CGKeyCode(kVK_Return))
        )

        XCTAssertNil(chord.modifierDown)
        XCTAssertNil(chord.modifierUp)
        XCTAssertEqual(chord.ordered.count, 2)
        XCTAssertEqual(chord.ordered.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(chord.ordered.map(self.keyCode), [Int64(kVK_Return), Int64(kVK_Return)])
    }

    func testModifierEventsAreCreatedAsFlagsChangedWithoutMutatingType() throws {
        // Documents why the implementation never assigns `type`: CGEvent already does it.
        let asCreated = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Control), keyDown: true)
        )
        XCTAssertEqual(asCreated.type, .flagsChanged)
        XCTAssertEqual(self.keyCode(asCreated), Int64(kVK_Control))
    }

    func testChordUsesTheSuppliedKeyCode() throws {
        // Dvorak-QWERTY and non-Latin layouts resolve "v" to a different key code, so the chord
        // must carry whatever PasteKeyCodeResolver produced rather than a hard-coded 9.
        let dvorakStyleKeyCode: CGKeyCode = 47
        let chord = try XCTUnwrap(
            TypingService.makeRemoteDesktopChord(
                modifierKeyCode: CGKeyCode(kVK_Control),
                keyCode: dvorakStyleKeyCode
            )
        )

        XCTAssertEqual(self.keyCode(chord.keyDown), Int64(dvorakStyleKeyCode))
        XCTAssertEqual(self.keyCode(chord.keyUp), Int64(dvorakStyleKeyCode))
    }

    // MARK: - Flag fidelity (guards assigning `flags` instead of inserting)

    func testModifierIsHeldAcrossTheKeyEventsAndReleasedAfter() throws {
        let chord = try self.makeControlChord()

        for (label, event) in [("key down", chord.keyDown), ("key up", chord.keyUp)] {
            XCTAssertTrue(event.flags.contains(.maskControl), "\(label) must report control held")
        }
        XCTAssertTrue(try XCTUnwrap(chord.modifierDown).flags.contains(.maskControl))

        // Skipped rather than asserted when a physical control key is down: a nil-source
        // CGEvent inherits the ambient combined-session modifier state, so the release event
        // would legitimately still report control held and the assertion would say nothing
        // about this code.
        try XCTSkipIf(
            CGEventSource.flagsState(.combinedSessionState).contains(.maskControl),
            "A physical control key is held, so ambient state leaks into synthetic event flags"
        )
        XCTAssertFalse(
            try XCTUnwrap(chord.modifierUp).flags.contains(.maskControl),
            "The trailing flagsChanged must report control released"
        )
    }

    func testKeyEventsCarryEveryHeldModifierBitIncludingTheDeviceSideBit() throws {
        // Compared within one chord, so ambient state cannot skew it. The device-side bit
        // (NX_DEVICELCTLKEYMASK) says which physical modifier is down and is what a
        // remote-desktop client uses to pick a modifier scan code; assigning `flags` would
        // drop it, which is what this guards.
        //
        // Do not "strengthen" this by asserting an absolute flag value such as
        // `.maskNonCoalesced`: CoreGraphics sets that on a freshly created nil-source event in
        // a standalone process but *not* inside the XCTest host, so such an assertion fails
        // permanently in CI while telling you nothing about this code.
        let chord = try self.makeControlChord()
        let heldFlags = try XCTUnwrap(chord.modifierDown).flags

        for (label, event) in [("key down", chord.keyDown), ("key up", chord.keyUp)] {
            XCTAssertTrue(
                event.flags.isSuperset(of: heldFlags),
                """
                \(label) is missing bits the modifier event carried \
                (0x\(String(event.flags.rawValue, radix: 16)) does not contain \
                0x\(String(heldFlags.rawValue, radix: 16))). Insert into `flags`, never assign it.
                """
            )
        }
    }

    func testRightHandModifierContributesItsOwnDeviceBit() throws {
        // Proves the held flags are copied off the modifier event rather than hard-coded:
        // right control carries NX_DEVICERCTLKEYMASK, a different bit from left control.
        let left = try self.makeControlChord()
        let right = try XCTUnwrap(
            TypingService.makeRemoteDesktopChord(
                modifierKeyCode: CGKeyCode(kVK_RightControl),
                keyCode: self.pasteKeyCode
            )
        )

        let leftHeld = try XCTUnwrap(left.modifierDown).flags.rawValue
        let rightHeld = try XCTUnwrap(right.modifierDown).flags.rawValue
        XCTAssertNotEqual(leftHeld, rightHeld, "Left and right control differ in their device-side bit")
        XCTAssertTrue(right.keyDown.flags.isSuperset(of: CGEventFlags(rawValue: rightHeld)))
    }

    // MARK: - Hotkey isolation (prevents a phantom recording on every dictation)

    func testEveryChordEventIsExcludedFromFluidVoiceHotkeyMatching() throws {
        let chords = [
            try self.makeControlChord(),
            try XCTUnwrap(TypingService.makeRemoteDesktopChord(modifierKeyCode: nil, keyCode: CGKeyCode(kVK_Return))),
        ]

        for chord in chords {
            for (index, event) in chord.ordered.enumerated() {
                XCTAssertTrue(
                    GlobalHotkeyManager.isSynthesizedTypingEvent(event),
                    """
                    Event \(index) is untagged. GlobalHotkeyManager taps flagsChanged, so an \
                    untagged synthetic modifier press is matched as a modifier-only dictation \
                    shortcut and starts a phantom recording on every dictation.
                    """
                )
            }
        }
    }

    func testUntaggedControlEventWouldNotBeExcluded() throws {
        // Proves the assertion above is load-bearing rather than vacuously true.
        let untagged = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Control), keyDown: true)
        )
        XCTAssertFalse(GlobalHotkeyManager.isSynthesizedTypingEvent(untagged))
    }

    // MARK: - Spoken Send

    func testSpokenSendModifiersMapToRealModifierKeyCodes() {
        XCTAssertNil(TypingService.spokenSendModifierKeyCode(for: .enter))
        XCTAssertEqual(TypingService.spokenSendModifierKeyCode(for: .shiftEnter), CGKeyCode(kVK_Shift))
        // Command is translated to Control, not forwarded literally: the client forwards the
        // Command position as the Windows key, so Command+Enter would arrive as Win+Enter - an
        // operating-system shortcut that never submits. Control carries the same meaning in the
        // guest and is the mapping the client itself applies for copy, cut and paste.
        XCTAssertEqual(TypingService.spokenSendModifierKeyCode(for: .commandEnter), CGKeyCode(kVK_Control))
        XCTAssertNotEqual(TypingService.spokenSendModifierKeyCode(for: .commandEnter), CGKeyCode(kVK_Command))
    }

    func testShiftEnterProducesAShiftChordRatherThanABareReturn() throws {
        // A Shift+Enter that reaches the guest as a bare Enter sends a message the user meant
        // to add a newline to, so the modifier must be a real key event.
        let chord = try XCTUnwrap(
            TypingService.makeRemoteDesktopChord(
                modifierKeyCode: TypingService.spokenSendModifierKeyCode(for: .shiftEnter),
                keyCode: CGKeyCode(kVK_Return)
            )
        )

        XCTAssertEqual(chord.ordered.count, 4)
        XCTAssertEqual(self.keyCode(try XCTUnwrap(chord.modifierDown)), Int64(kVK_Shift))
        XCTAssertTrue(chord.keyDown.flags.contains(.maskShift))
    }

    // MARK: - Settle delay parsing

    func testSettleDelayDefaultsWhenNoOverrideIsSet() {
        XCTAssertEqual(
            TypingService.remoteDesktopSettleMicros(override: nil),
            useconds_t(TypingService.remoteDesktopClipboardSettleDefaultMs * 1000)
        )
    }

    func testSettleDelayHonoursAValidOverride() {
        XCTAssertEqual(TypingService.remoteDesktopSettleMicros(override: NSNumber(value: 250)), 250_000)
        XCTAssertEqual(TypingService.remoteDesktopSettleMicros(override: NSNumber(value: 0)), 0)
    }

    func testSettleDelayClampsInsteadOfTrapping() {
        // `useconds_t` is UInt32; an unclamped override would trap on conversion or overflow
        // the multiplication.
        let maximum = useconds_t(TypingService.remoteDesktopClipboardSettleMaximumMs * 1000)

        XCTAssertEqual(TypingService.remoteDesktopSettleMicros(override: NSNumber(value: Int32.max)), maximum)
        XCTAssertEqual(TypingService.remoteDesktopSettleMicros(override: NSNumber(value: 5_000_000)), maximum)
        XCTAssertEqual(TypingService.remoteDesktopSettleMicros(override: NSNumber(value: -1)), 0)
        XCTAssertEqual(TypingService.remoteDesktopSettleMicros(override: NSNumber(value: Int32.min)), 0)
    }

    // MARK: - Target resolution

    private func resolve(
        preferred: pid_t?,
        focused: pid_t?,
        frontmost: pid_t?,
        remoteDesktopPIDs: Set<pid_t>
    ) -> pid_t? {
        TypingService.resolveRemoteDesktopPID(
            preferredTargetPID: preferred,
            focusedPID: focused,
            frontmostPID: frontmost,
            isRemoteDesktop: { remoteDesktopPIDs.contains($0) }
        )
    }

    func testPreferredTargetWinsWhenItIsARemoteDesktop() {
        XCTAssertEqual(
            self.resolve(preferred: 10, focused: 20, frontmost: 30, remoteDesktopPIDs: [10, 30]),
            10
        )
    }

    func testPreferredTargetThatIsNotARemoteDesktopDoesNotFallThrough() {
        // The caller already knows which app it is inserting into; falling back to the
        // frontmost window would paste into a different app entirely.
        XCTAssertNil(
            self.resolve(preferred: 10, focused: 30, frontmost: 30, remoteDesktopPIDs: [30])
        )
    }

    func testNonPositivePreferredTargetIsTreatedAsAbsent() {
        XCTAssertEqual(self.resolve(preferred: 0, focused: 30, frontmost: 40, remoteDesktopPIDs: [30]), 30)
        XCTAssertEqual(self.resolve(preferred: -1, focused: 30, frontmost: 40, remoteDesktopPIDs: [30]), 30)
    }

    func testFocusedElementDecidesWhenThereIsNoPreferredTarget() {
        XCTAssertEqual(self.resolve(preferred: nil, focused: 30, frontmost: 40, remoteDesktopPIDs: [30]), 30)
    }

    func testFocusedNonRemoteDesktopDoesNotFallThroughToFrontmost() {
        // A floating launcher can own the focused element while a remote-desktop window is
        // frontmost. Pasting into the frontmost window would lose the text.
        XCTAssertNil(
            self.resolve(preferred: nil, focused: 20, frontmost: 40, remoteDesktopPIDs: [40])
        )
    }

    func testFrontmostIsUsedOnlyWhenNothingElseIsKnown() {
        XCTAssertEqual(self.resolve(preferred: nil, focused: nil, frontmost: 40, remoteDesktopPIDs: [40]), 40)
        XCTAssertNil(self.resolve(preferred: nil, focused: nil, frontmost: 40, remoteDesktopPIDs: [99]))
        XCTAssertNil(self.resolve(preferred: nil, focused: nil, frontmost: nil, remoteDesktopPIDs: [40]))
    }
}
