import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

final class TextSelectionService {
    static let shared = TextSelectionService()

    private init() {}

    /// Attempts to get the currently selected text using Accessibility APIs
    func getSelectedText() -> String? {
        self.diag("Selection capture start")

        // Check accessibility permissions
        guard AXIsProcessTrusted() else {
            DebugLogger.shared.error("Accessibility permissions not granted", source: "TextSelectionService")
            self.diag("Selection capture failed: Accessibility permissions not granted")
            return nil
        }

        // 1. Try to get the system-wide focused element
        if let focusedElement = getFocusedElement() {
            if let text = getSelectedText(from: focusedElement) {
                self.diag("Selection capture success via system focused element (chars=\(text.count))")
                return text
            }
            self.diag("System focused element returned no selected text")
        }

        // 2. Fallback: Try to find focused element in frontmost app
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            self.diag("Trying frontmost app fallback: \(frontmostApp.bundleIdentifier ?? frontmostApp.localizedName ?? "unknown") pid=\(frontmostApp.processIdentifier)")
            let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
            if let focusedElement = getFocusedElement(from: appElement) {
                if let text = getSelectedText(from: focusedElement) {
                    self.diag("Selection capture success via frontmost app focused element (chars=\(text.count))")
                    return text
                }
                self.diag("Frontmost app focused element returned no selected text")
            } else {
                self.diag("Frontmost app fallback could not resolve focused element")
            }
        }

        // 3. Final fallback: synthetic Cmd+C, read the pasteboard, restore it.
        // Electron / GPU-rendered editors (Zed, VS Code, Obsidian, web editors in Chrome)
        // frequently don't expose the focused element or selection through the AX tree, so
        // both AX strategies above return nothing. Copying the live selection is the only
        // reliable way to read it from those apps (issue #259).
        if let text = getSelectedTextViaClipboard() {
            return text
        }

        self.diag("Selection capture failed: no selected text found")
        return nil
    }

    // MARK: - Private Helpers

    /// Reads the current selection by synthesizing Cmd+C, polling the pasteboard for the
    /// resulting write, then restoring the user's previous pasteboard contents. This is a
    /// last resort used only when the Accessibility tree yields no selection.
    ///
    /// Runs synchronously on the caller's thread (the main thread for Write/Rewrite mode);
    /// the poll is bounded by `Self.clipboardCopyTimeoutMicros` so a missing selection (no
    /// pasteboard write) degrades to `nil` quickly rather than hanging.
    private func getSelectedTextViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let changeCountBeforeCopy = pasteboard.changeCount

        self.diag("Trying clipboard fallback (synthetic Cmd+C)")
        guard self.postSyntheticCopy() else {
            self.diag("Clipboard fallback: failed to post Cmd+C events")
            return nil
        }

        // Cmd+C is delivered asynchronously; wait for the target app to write the selection
        // to the pasteboard. The change-count increments on any write, even if the copied
        // text equals the prior contents, so this reliably detects a successful copy.
        let didChange = self.waitForPasteboardChange(
            pasteboard,
            since: changeCountBeforeCopy,
            timeoutMicros: Self.clipboardCopyTimeoutMicros
        )

        // Read the copied selection only if the pasteboard actually changed.
        let copiedText = didChange ? pasteboard.string(forType: .string) : nil

        // Always restore the user's previous pasteboard, then defend that restore against a
        // late synthetic-copy write (a slow/busy target app processing our Cmd+C after the
        // read timeout would otherwise clobber the restored clipboard — see the method doc).
        self.restoreClipboardDefensively(snapshot, to: pasteboard)

        guard didChange else {
            self.diag("Clipboard fallback: pasteboard unchanged within timeout (no selection?)")
            return nil
        }
        guard let copiedText, !copiedText.isEmpty else {
            self.diag("Clipboard fallback: pasteboard changed but yielded no string")
            return nil
        }

        self.diag("Clipboard fallback succeeded (chars=\(copiedText.count))")
        return copiedText
    }

    /// Posts a synthetic Cmd+C to the currently focused app via the HID event tap.
    /// Returns false only if the CGEvents could not be created.
    ///
    /// The key code for "c" is resolved against the active keyboard layout (via the same
    /// mechanism `TypingService` uses for Cmd+V), so the copy lands on the correct physical
    /// key on non-QWERTY layouts (Dvorak/AZERTY/...). Falls back to the ANSI "c" key code
    /// only when the layout data is unavailable.
    private func postSyntheticCopy() -> Bool {
        let cKeyCode = LayoutAwareKeyCode.virtualKeyCode(for: "c", qwertyFallback: CGKeyCode(kVK_ANSI_C))
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: cKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: cKeyCode, keyDown: false)
        else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(10_000)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// Polls `pasteboard.changeCount` until it differs from `previousChangeCount` or the
    /// timeout elapses. Returns whether a change was observed.
    private func waitForPasteboardChange(
        _ pasteboard: NSPasteboard,
        since previousChangeCount: Int,
        timeoutMicros: useconds_t
    ) -> Bool {
        let pollMicros: useconds_t = 10_000
        var waited: useconds_t = 0
        while waited < timeoutMicros {
            if pasteboard.changeCount != previousChangeCount {
                return true
            }
            usleep(pollMicros)
            waited += pollMicros
        }
        return pasteboard.changeCount != previousChangeCount
    }

    /// Upper bound on how long to wait for a synthetic Cmd+C to land on the pasteboard.
    /// Kept tight because this runs on the main thread; the copy normally completes in tens
    /// of milliseconds, and exceeding this just means "treat as no selection."
    private static let clipboardCopyTimeoutMicros: useconds_t = 300_000

    /// Restores `snapshot` onto `pasteboard`, then briefly watches for a *late* pasteboard
    /// write and re-restores if one lands.
    ///
    /// The hazard: our synthetic Cmd+C is delivered asynchronously. If the target app is
    /// slow/busy it may process the copy *after* `clipboardCopyTimeoutMicros` has elapsed and
    /// we've already restored — its delayed write would then clobber the user's clipboard,
    /// leaving the copied selection (or stale data) where the user's content should be. That
    /// breaks the "always restore the user's clipboard" guarantee.
    ///
    /// Defense: after restoring, record the change count our own restore produced and poll
    /// for a short, bounded settle window. Any further change is an external write — almost
    /// certainly the app's delayed copy — so we restore again (capped at `maxLateCopyRestores`
    /// re-restores within `lateCopySettleMicros` total). The loop is doubly bounded (time and
    /// retry count) so it cannot hang; because each pass ends by re-restoring the user's
    /// snapshot, it cannot leave the selection text on the clipboard.
    ///
    /// Runs synchronously on the caller's thread (the main thread for Write/Rewrite mode),
    /// consistent with the copy-wait above; the added latency is bounded by
    /// `lateCopySettleMicros` and only paid on this last-resort fallback path.
    private func restoreClipboardDefensively(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        snapshot.restore(to: pasteboard)
        var lastRestoreChangeCount = pasteboard.changeCount

        var restoresRemaining = Self.maxLateCopyRestores
        let pollMicros: useconds_t = 10_000
        var waited: useconds_t = 0

        while waited < Self.lateCopySettleMicros {
            usleep(pollMicros)
            waited += pollMicros

            guard pasteboard.changeCount != lastRestoreChangeCount else { continue }

            // A write landed after our restore — the target app's delayed synthetic copy
            // clobbering the user's clipboard. Restore the user's snapshot again.
            guard restoresRemaining > 0 else {
                self.diag("Clipboard fallback: late write persisted past \(Self.maxLateCopyRestores) restores; leaving user clipboard restored as of last attempt")
                return
            }
            restoresRemaining -= 1
            snapshot.restore(to: pasteboard)
            lastRestoreChangeCount = pasteboard.changeCount
            self.diag("Clipboard fallback: re-restored user clipboard after a late synthetic-copy write")
        }

        // Reconcile a write that landed in the final poll interval (just past the loop edge).
        if pasteboard.changeCount != lastRestoreChangeCount, restoresRemaining > 0 {
            snapshot.restore(to: pasteboard)
            self.diag("Clipboard fallback: final re-restore after a late write at the settle-window edge")
        }
    }

    /// Total time the defensive restore watches for a late synthetic-copy write before giving
    /// up. Bounds the extra main-thread latency added on top of `clipboardCopyTimeoutMicros`.
    private static let lateCopySettleMicros: useconds_t = 200_000

    /// Maximum number of re-restores during the settle window. A real app emits one delayed
    /// write per Cmd+C, so 1 suffices in practice; the small headroom covers pathological
    /// repeated writers without ever looping unbounded.
    private static let maxLateCopyRestores = 3

    private func getFocusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result == .success, let focusedElement {
            guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(focusedElement, to: AXUIElement.self)
        }

        return nil
    }

    private func getFocusedElement(from appElement: AXUIElement) -> AXUIElement? {
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if result == .success, let focusedElement {
            guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(focusedElement, to: AXUIElement.self)
        }

        return nil
    }

    private func getSelectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)

        if result == .success, let text = value as? String {
            self.diag("kAXSelectedTextAttribute succeeded (chars=\(text.count))")
            return text
        }

        self.diag("kAXSelectedTextAttribute unavailable (\(self.describe(result))) - trying selected range fallback")

        // Fallback: reconstruct selected text from selected range + full value for apps
        // that don't expose kAXSelectedTextAttribute directly.
        var selectedRangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef)
        guard rangeResult == .success, let axRange = selectedRangeRef else {
            self.diag("kAXSelectedTextRangeAttribute unavailable (\(self.describe(rangeResult)))")
            return nil
        }

        guard CFGetTypeID(axRange) == AXValueGetTypeID() else {
            self.diag("kAXSelectedTextRangeAttribute returned non-AXValue")
            return nil
        }

        let axValue = unsafeBitCast(axRange, to: AXValue.self)

        var range = CFRange()
        let gotRange = AXValueGetValue(axValue, .cfRange, &range)
        guard gotRange else {
            self.diag("AXValueGetValue(.cfRange) failed")
            return nil
        }

        guard range.location != kCFNotFound, range.length > 0 else {
            self.diag("Selected range empty (location=\(range.location), length=\(range.length))")
            return nil
        }

        var fullValueRef: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fullValueRef)
        guard valueResult == .success, let fullText = fullValueRef as? String else {
            self.diag("kAXValueAttribute unavailable for range extraction (\(self.describe(valueResult)))")
            return nil
        }

        let nsText = fullText as NSString
        guard range.location >= 0,
              range.length > 0,
              range.location + range.length <= nsText.length
        else {
            self.diag("Selected range out of bounds (textLen=\(nsText.length), location=\(range.location), length=\(range.length))")
            return nil
        }

        let extracted = nsText.substring(with: NSRange(location: range.location, length: range.length))
        self.diag("Selected range extraction succeeded (chars=\(extracted.count))")
        return extracted
    }

    private func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(error.rawValue))"
        }
    }

    private func diag(_ message: String) {
        let line = "[TextSelectionService] \(message)"
        FileLogger.shared.append(line: line)
        DebugLogger.shared.debug(line, source: "TextSelectionService")
    }
}
