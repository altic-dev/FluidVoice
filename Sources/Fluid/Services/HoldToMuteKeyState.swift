import AppKit

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

/// Defers an ordinary Space until a short tap is known, without delaying audio mute.
/// Events go downstream of our tap, before the current event, preserving typing order
/// without re-entering the hotkey handler or changing the clipboard.
@MainActor
final class HoldToMuteSpaceTap {
    static let maximumDuration: UInt64 = 250_000_000

    struct Context: Equatable {
        let pid: pid_t
        let leftClicks: UInt32
        let rightClicks: UInt32
        let otherClicks: UInt32
    }

    var contextProvider: () -> Context? = {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return Context(
            pid: pid,
            leftClicks: CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown),
            rightClicks: CGEventSource.counterForEventType(.combinedSessionState, eventType: .rightMouseDown),
            otherClicks: CGEventSource.counterForEventType(.combinedSessionState, eventType: .otherMouseDown)
        )
    }

    var postEvent: (CGEventTapProxy?, CGEvent) -> Void = { proxy, event in
        guard let proxy else { return }
        event.tapPostEvent(proxy)
    }

    private var keyDown: CGEvent?
    private var context: Context?

    func begin(_ event: CGEvent) {
        self.keyDown = event.copy()
        self.context = self.contextProvider()
    }

    func cancel() {
        self.keyDown = nil
        self.context = nil
    }

    func finish(at timestamp: CGEventTimestamp, proxy: CGEventTapProxy?, allowed: Bool) {
        defer { self.cancel() }
        guard allowed, let down = self.keyDown, let context = self.context,
              timestamp >= down.timestamp, timestamp - down.timestamp <= Self.maximumDuration,
              context == self.contextProvider(), let up = down.copy()
        else { return }
        // A completed tap, even when flushed before the next letter while Space is
        // still physically down. Later repeats and the physical release stay owned.
        down.timestamp = timestamp
        up.timestamp = timestamp
        up.type = .keyUp
        self.postEvent(proxy, down)
        self.postEvent(proxy, up)
    }

    static func isPlainTextKey(_ event: CGEvent) -> Bool {
        guard event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]) else { return false }
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
        guard length > 0 else { return false }
        return characters.prefix(length).allSatisfy { $0 >= 0x20 && $0 != 0x7f && !(0xf700...0xf8ff).contains($0) }
    }
}
