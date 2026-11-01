import AppKit

/// Constructs the production events only. Never calls postGlobalPasteCommand.
@main
@MainActor
enum PasteCommandEventTests {
    static func main() {
        precondition(SystemPasteCommandPoster.pasteEventTapLocation == .cgSessionEventTap)
        let events = SystemPasteCommandPoster.makePasteEvents()
        precondition(events.count == 2)
        precondition(events.map(\.type) == [.keyDown, .keyUp])
        for event in events {
            precondition(event.getIntegerValueField(.keyboardEventKeycode) == 9)
            precondition(event.flags == [.maskCommand, CGEventFlags(rawValue: UInt64(NX_DEVICELCMDKEYMASK))], "No Control, Option, Shift or Fn may leak into Cmd+V")
            // Flutter's synchronizeModifiers reads this device-dependent bit.
            precondition(event.flags.rawValue & 0x8 != 0, "Flutter must recognize the left Command key")
            precondition(event.flags.isDisjoint(with: [.maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]))
            precondition(event.getIntegerValueField(.eventSourceUserData) == TypingService.synthesizedEventUserData)
            precondition(event.getIntegerValueField(.eventSourceStateID) == CGEventSourceStateID.combinedSessionState.rawValue)
        }
        print("PASS: production paste uses session-level V down/up, Command-only flags, correct source and hotkey bypass tag")
        print("No events were posted. Physical modifier-state behavior requires the installed-app test.")
    }
}
