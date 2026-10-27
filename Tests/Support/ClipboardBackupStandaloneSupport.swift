import AppKit

// Compile-only adapters for app-wide logging and the unused real command poster.
// The production delivery coordinator and pasteboard implementation are compiled unchanged.
// Fatal keyboard getters prevent this isolated harness from ever posting real keys.
enum TypingService {
    static var pasteVirtualKeyCode: CGKeyCode { fatalError("Real keyboard posting is forbidden in this harness") }
    static var synthesizedEventUserData: Int64 { fatalError("Real keyboard posting is forbidden in this harness") }
}

enum ClipboardAudit {
    static func record(_ event: String, pasteboard: NSPasteboard, detail: String = "") {}
}

final class DebugLogger {
    static let shared = DebugLogger()
    func benchmark(_ category: String, message: String, source: String) {}
}
