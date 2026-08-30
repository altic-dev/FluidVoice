import AppKit
import ApplicationServices
import Foundation

final class TextSelectionService {
    static let shared = TextSelectionService()
    private static let pasteboardSessionSemaphore = DispatchSemaphore(value: 1)

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

        if let copiedSelection = self.getSelectedTextByCopyFallback() {
            self.diag("Selection capture success via clipboard fallback (chars=\(copiedSelection.count))")
            return copiedSelection
        }

        self.diag("Selection capture failed: no selected text found")
        return nil
    }

    // MARK: - Private Helpers

    private struct PasteboardItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
        let changeCount: Int
    }

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

    private func getSelectedTextByCopyFallback() -> String? {
        Self.pasteboardSessionSemaphore.wait()
        defer { Self.pasteboardSessionSemaphore.signal() }

        let pasteboard = NSPasteboard.general
        let snapshot = self.capturePasteboardSnapshot(pasteboard)

        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount

        guard self.sendCopyShortcut() else {
            self.restorePasteboardSnapshot(snapshot, to: pasteboard)
            self.diag("Clipboard fallback failed: could not dispatch Cmd+C")
            return nil
        }

        // Google Docs and other browser editors can update the system pasteboard
        // noticeably later than native text fields after Cmd+C.
        let deadline = Date().addingTimeInterval(1.0)
        var copiedText: String?
        repeat {
            if pasteboard.changeCount != clearedChangeCount,
               let text = pasteboard.string(forType: .string),
               !text.isEmpty
            {
                copiedText = text
                break
            }
            usleep(15_000)
        } while Date() < deadline

        self.restorePasteboardSnapshot(snapshot, to: pasteboard)

        guard let copiedText else {
            self.diag("Clipboard fallback failed: clipboard did not receive selected text")
            return nil
        }

        return copiedText
    }

    private func sendCopyShortcut() -> Bool {
        guard let copyDown = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let copyUp = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false)
        else {
            return false
        }

        copyDown.flags = .maskCommand
        copyUp.flags = .maskCommand
        copyDown.post(tap: .cghidEventTap)
        usleep(10_000)
        copyUp.post(tap: .cghidEventTap)
        return true
    }

    private func capturePasteboardSnapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [PasteboardItemSnapshot] = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return PasteboardItemSnapshot(dataByType: dataByType)
        } ?? []
        return PasteboardSnapshot(items: items, changeCount: pasteboard.changeCount)
    }

    private func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        guard pasteboard.changeCount != snapshot.changeCount else { return }

        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }

        let restoredItems = snapshot.items.map { snap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snap.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        _ = pasteboard.writeObjects(restoredItems)
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
