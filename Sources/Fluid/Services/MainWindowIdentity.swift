import AppKit

/// Shared by startup and menu actions, since the title follows the selected page.
enum MainWindowIdentity {
    @MainActor
    static func matches(_ window: NSWindow) -> Bool {
        guard window.level == .normal, window.styleMask.contains(.titled) else { return false }
        return window.identifier?.rawValue.hasPrefix("main-AppWindow") == true
            || window.title.contains("FluidVoice")
    }
}
