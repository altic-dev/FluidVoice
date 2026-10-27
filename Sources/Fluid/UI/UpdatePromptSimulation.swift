#if DEBUG
import AppKit

/// Explicit launch-only diagnostics. Release builds have no observer or simulated installer.
@MainActor
enum UpdatePromptSimulation {
    static let isEnabled = ProcessInfo.processInfo.environment["FLUIDVOICE_UPDATE_UI_SIMULATION"] == "1"

    static func register(_ delegate: AppDelegate) -> NSObjectProtocol? {
        guard self.isEnabled else { return nil }
        return DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.FluidApp.debug.updateUI"),
            object: String(ProcessInfo.processInfo.processIdentifier),
            queue: .main
        ) { [weak delegate] notification in
            guard let scenario = notification.userInfo?["scenario"] as? String else { return }
            Task { @MainActor [weak delegate] in
                delegate?.simulateUpdateUI(scenario)
            }
        }
    }
}
#endif
