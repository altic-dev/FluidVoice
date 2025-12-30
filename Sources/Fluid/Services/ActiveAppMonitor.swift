import AppKit
import Combine

/// A centralized service that monitors the currently active (frontmost) application.
/// This can be used by overlays, AI prompts, custom commands, etc.
@MainActor
final class ActiveAppMonitor: ObservableObject {
    static let shared = ActiveAppMonitor()

    /// The currently active application (excluding FluidVoice itself)
    @Published private(set) var activeApp: NSRunningApplication?

    /// The icon of the currently active application
    @Published private(set) var activeAppIcon: NSImage?

    /// The bundle identifier of the currently active application
    var activeAppBundleID: String? {
        self.activeApp?.bundleIdentifier
    }

    /// The localized name of the currently active application
    var activeAppName: String? {
        self.activeApp?.localizedName
    }

    private var observer: NSObjectProtocol?
    private var isMonitoring = false

    private init() {}

    /// Start monitoring active app changes.
    /// Call this when showing overlays or when you need real-time app tracking.
    func startMonitoring() {
        guard !self.isMonitoring else { return }
        self.isMonitoring = true

        // Capture the current app immediately
        self.updateActiveApp()

        // Subscribe to app activation notifications
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateActiveApp()
            }
        }
    }

    /// Stop monitoring active app changes.
    /// Call this when hiding overlays to conserve resources.
    func stopMonitoring() {
        guard self.isMonitoring else { return }
        self.isMonitoring = false

        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }

        // Clear state to ensure fresh capture on next start
        self.activeApp = nil
        self.activeAppIcon = nil
    }

    /// Manually refresh the active app (useful for one-shot captures)
    func refreshActiveApp() {
        self.updateActiveApp()
    }

    private func updateActiveApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            // No frontmost app (rare edge case during fast app switches)
            return
        }

        // Don't track ourselves
        guard frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        // Only update if the app actually changed
        if self.activeApp?.bundleIdentifier != frontApp.bundleIdentifier {
            self.activeApp = frontApp
            self.activeAppIcon = frontApp.icon

            // Also update NotchContentState for overlay compatibility
            NotchContentState.shared.targetAppIcon = frontApp.icon
        }
    }
}
