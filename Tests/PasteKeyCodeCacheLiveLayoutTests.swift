import AppKit
import Carbon.HIToolbox

// Opt-in live test. Temporarily selects Dvorak and restores the original layout.
@main
enum PasteKeyCodeCacheLiveLayoutTests {
    static func value(_ source: TISInputSource, _ property: CFString) -> String {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    static func resolveV() -> CGKeyCode {
        PasteKeyCodeResolver.current()
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as? [TISInputSource] else {
            throw NSError(domain: "Input source list unavailable", code: 9)
        }
        guard let dvorak = sources.first(where: { value($0, kTISPropertyInputSourceID) == "com.apple.keylayout.Dvorak" }) else {
            throw NSError(domain: "Dvorak unavailable", code: 1)
        }
        guard let enabledPointer = TISGetInputSourceProperty(dvorak, kTISPropertyInputSourceIsEnabled) else {
            throw NSError(domain: "Dvorak enabled state unavailable", code: 10)
        }
        let wasEnabled = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabledPointer).takeUnretainedValue())
        defer {
            let restored = TISSelectInputSource(original)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let disabled = wasEnabled ? noErr : TISDisableInputSource(dvorak)
            print("RESTORE selection=\(restored) removeTemporaryDvorak=\(disabled) current=\(value(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID))")
        }
        guard TISEnableInputSource(dvorak) == noErr else { throw NSError(domain: "Enable failed", code: 2) }
        var refreshes = 0
        let cache = KeyboardLayoutSnapshotCache(initialValue: CGKeyCode(9)) {
            refreshes += 1
            return self.resolveV()
        }
        cache.start()
        print("START key=\(cache.snapshot())")
        for source in [dvorak, original, dvorak, original] {
            let start = ProcessInfo.processInfo.systemUptime
            guard TISSelectInputSource(source) == noErr else { throw NSError(domain: "Select failed", code: 3) }
            let expected = self.resolveV()
            let immediate = cache.snapshot()
            let deadline = Date().addingTimeInterval(2)
            while cache.snapshot() != expected, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            guard cache.snapshot() == expected else { throw NSError(domain: "Stale cache", code: 4) }
            print("SWITCH \(self.value(source, kTISPropertyInputSourceID)) expected=\(expected) immediate=\(immediate) refreshed=\(cache.snapshot()) elapsedMs=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
        }
        // Several changes without yielding the main run loop: the request must use
        // the final layout, even if notifications are still queued or coalesced.
        for source in [dvorak, original, dvorak] {
            guard TISSelectInputSource(source) == noErr else { throw NSError(domain: "Rapid select failed", code: 6) }
        }
        let expectedAfterRapidChanges = self.resolveV()
        let deadline = Date().addingTimeInterval(2)
        while cache.snapshot() != expectedAfterRapidChanges, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        guard cache.snapshot() == expectedAfterRapidChanges else { throw NSError(domain: "Rapid refresh failed", code: 7) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard cache.snapshot() == expectedAfterRapidChanges else { throw NSError(domain: "Late notification regressed cache", code: 8) }
        print("PASS live notifications; refreshes=\(refreshes)")
    }
}
