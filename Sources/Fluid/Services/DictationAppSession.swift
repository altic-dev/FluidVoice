import AppKit
import Combine
import Foundation

/// Event-driven and memory-only. Watching while the overlay is hidden catches A → B → A.
final class DictationAppSession: @unchecked Sendable {
    static let shared = DictationAppSession()
    private let lock = NSLock()
    private var state = ForegroundAppOverride<SettingsStore.DictationPromptSelection>()
    private var observer: NSObjectProtocol?
    private var mainWindowObserver: NSObjectProtocol?
    var appID: String? { self.lock.withLock { self.state.appID } }

    @MainActor
    func start() {
        guard self.observer == nil else { return }
        self.activate(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let appID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.activate(appID) }
        }
        self.mainWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow, !(window is NSPanel) else { return }
            MainActor.assumeIsolated { self?.activate(Bundle.main.bundleIdentifier, isMainWindow: true) }
        }
    }

    @MainActor
    func activate(_ appID: String?, isMainWindow: Bool? = nil) {
        // Our nonactivating overlay/popover must not end the target app's visit.
        let mainWindowFocused = isMainWindow ?? (NSApp.keyWindow != nil && !(NSApp.keyWindow is NSPanel))
        if appID == Bundle.main.bundleIdentifier, !mainWindowFocused { return }
        let changed = self.lock.withLock { self.state.activate(appID) }
        if changed { SettingsStore.shared.objectWillChange.send() }
    }

    @MainActor
    func select(_ selection: SettingsStore.DictationPromptSelection, slot: SettingsStore.DictationShortcutSlot, appID: String?) {
        guard let appID else { return }
        self.lock.withLock { self.state.select(selection, slot: slot.rawValue, appID: appID) }
        SettingsStore.shared.objectWillChange.send()
    }

    func choice(for slot: SettingsStore.DictationShortcutSlot, appID: String?) -> SettingsStore.DictationPromptSelection? {
        self.lock.withLock { self.state.choice(slot: slot.rawValue, appID: appID) }
    }
}
