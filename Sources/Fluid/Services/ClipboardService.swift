import AppKit
import Foundation

/// A simple service for clipboard operations
enum ClipboardService {
    /// Copies the provided text to the system clipboard
    /// - Parameter text: The text to copy to clipboard
    /// - Returns: Boolean indicating success or failure
    @discardableResult
    static func copyToClipboard(_ text: String) -> Bool {
        guard !text.isEmpty else {
            DebugLogger.shared.debug("Attempted to copy empty text to clipboard, skipping", source: "ClipboardService")
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)

        if success {
            DebugLogger.shared.info("Copied \(text.count) characters to clipboard", source: "ClipboardService")
        } else {
            DebugLogger.shared.error("Failed to copy text to clipboard", source: "ClipboardService")
        }

        return success
    }

    /// Retrieves the current text content from the clipboard
    /// - Returns: The clipboard text, or nil if no text is available
    static func getFromClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        return pasteboard.string(forType: .string)
    }
}
