import AppKit

// Compile-only adapters for app-wide logging and the unused real command poster.
// The production delivery coordinator and pasteboard implementation are compiled unchanged.
// Fatal keyboard getters prevent this isolated harness from ever posting real keys.
enum TypingService {
    #if PASTE_EVENT_CONSTRUCTION_TESTS
    static let pasteVirtualKeyCode: CGKeyCode = 9
    static let synthesizedEventUserData: Int64 = 0x46565353
    #else
    static var pasteVirtualKeyCode: CGKeyCode { fatalError("Real keyboard posting is forbidden in this harness") }
    static var synthesizedEventUserData: Int64 { fatalError("Real keyboard posting is forbidden in this harness") }
    #endif
}

enum ClipboardAudit {
    static func record(_ event: String, pasteboard: NSPasteboard, detail: String = "") {}
}

final class DebugLogger {
    @TaskLocal static var pipelineID: String?
    static let shared = DebugLogger()
    private let lock = NSLock()
    private var events: [(message: String, pipelineID: String?)] = []
    var infoEvents: [(message: String, pipelineID: String?)] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.events
    }

    func benchmark(_ category: String, message: String, source: String) {}
    func info(_ message: String, source: String) {
        self.lock.lock()
        self.events.append((message, Self.pipelineID))
        self.lock.unlock()
    }
}
