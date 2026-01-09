import AppKit
import Combine

/// Tracks the last non-FluidVoice frontmost application.
///
/// Purpose: overlays (notch/bottom) can temporarily make FluidVoice frontmost, which would
/// otherwise cause text insertion to target the wrong process. This tracker allows us to
/// continue targeting the user's real app (e.g. Terminal).
@MainActor
final class LastActiveNonFluidAppTracker: ObservableObject {
    static let shared = LastActiveNonFluidAppTracker()

    @Published private(set) var lastNonFluidApp: NSRunningApplication?

    var lastNonFluidPID: pid_t? { self.lastNonFluidApp?.processIdentifier }
    var lastNonFluidBundleID: String? { self.lastNonFluidApp?.bundleIdentifier }
    var lastNonFluidName: String? { self.lastNonFluidApp?.localizedName }

    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard self.observer == nil else { return }

        self.captureCurrentIfNonFluid()

        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self.captureIfNonFluid(app)
                } else {
                    self.captureCurrentIfNonFluid()
                }
            }
        }
    }

    func stop() {
        if let observer = self.observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    private func captureCurrentIfNonFluid() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        self.captureIfNonFluid(frontApp)
    }

    private func captureIfNonFluid(_ app: NSRunningApplication) {
        // Don't track ourselves
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        self.lastNonFluidApp = app
    }
}
