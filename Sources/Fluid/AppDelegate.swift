//
//  AppDelegate.swift
//  Fluid
//
//  Created by Barathwaj Anandan on 9/22/25.
//

import AppKit
import Carbon
import PromiseKit
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var updateCheckTimer: Timer?
    private var didRevealMainWindowOnLaunch = false
    private var didRequestMainWindowReopen = false
    private var shouldSuppressNextReopenActivation = false
    private var wasLaunchedAsLoginItem = false
    private var analyticsActivationSuppressionDeadline: Date?
    private var hasDeferredMLXUpgradeOffer = false
    private var floatingPromptWindow: NSWindow?
    private var floatingPromptTitle: String?

    var shouldPresentStartupMicrophoneNotice: Bool {
        !self.wasLaunchedAsLoginItem || SettingsStore.shared.showMainWindowAtLoginLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring up file logging + crash handlers immediately during launch.
        _ = FileLogger.shared
        // Must be read during the launch callback - the current Apple Event identifies
        // login-item launches (used to optionally start silently, see issue #369).
        self.wasLaunchedAsLoginItem = Self.detectLoginItemLaunch()
        if self.wasLaunchedAsLoginItem {
            self.analyticsActivationSuppressionDeadline = Date().addingTimeInterval(3)
        }
        DebugLogger.shared.info(
            "Application launched [loginItemLaunch=\(self.wasLaunchedAsLoginItem)]",
            source: "AppDelegate"
        )
        UNUserNotificationCenter.current().delegate = self

        // Initialize app settings (dock visibility, etc.)
        SettingsStore.shared.initializeAppSettings()
        let shouldOfferMLXUpgrade = PrivateAIMLXUpgradeCoordinator.prepareOfferIfNeeded()
        LocalAPIServer.shared.start()

        // Record first-open synchronously before async analytics bootstrap so
        // onboarding initialization is deterministic on brand-new installs.
        let isTrueFirstOpen = AnalyticsIdentityStore.shared.ensureFirstOpenRecorded()
        SettingsStore.shared.bootstrapOnboardingState(isTrueFirstOpen: isTrueFirstOpen)

        AnalyticsService.shared.bootstrap()

        // Check for updates automatically if enabled (initial check on launch)
        self.checkForUpdatesAutomatically()

        // Schedule periodic update checks every hour while app is running
        self.schedulePeriodicUpdateChecks()

        // Login Items can launch hidden; reveal the real SwiftUI window so ContentView startup runs.
        self.openMainWindowOnLaunch()

        if shouldOfferMLXUpgrade {
            if self.wasLaunchedAsLoginItem, !SettingsStore.shared.showMainWindowAtLoginLaunch {
                self.hasDeferredMLXUpgradeOffer = true
            } else {
                self.scheduleMLXUpgradeOffer()
            }
        }

        // Note: App UI is designed with dark color scheme in mind
        // All gradients and effects are optimized for dark mode
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLogger.shared.info("Application will terminate", source: "AppDelegate")
        self.shutdownPrivateAIRuntimeForTermination()
        self.shutdownASRRuntimeForTermination()
        LocalAPIServer.shared.stop()
        // Clean up the update check timer
        self.updateCheckTimer?.invalidate()
        self.updateCheckTimer = nil
    }

    private func shutdownASRRuntimeForTermination() {
        var didFinishShutdown = false
        Task { @MainActor in
            await AppServices.shared.shutdownForTermination()
            didFinishShutdown = true
        }

        let deadline = Date().addingTimeInterval(8)
        while !didFinishShutdown, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        if !didFinishShutdown {
            DebugLogger.shared.warning(
                "Timed out waiting for ASR runtime shutdown during termination",
                source: "AppDelegate"
            )
        }
    }

    private func shutdownPrivateAIRuntimeForTermination() {
        var didFinishShutdown = false
        Task { @MainActor in
            await PrivateAIIntegrationService.shared.shutdownForTermination()
            didFinishShutdown = true
        }

        let deadline = Date().addingTimeInterval(8)
        while !didFinishShutdown, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        if !didFinishShutdown {
            DebugLogger.shared.warning(
                "Timed out waiting for private AI runtime shutdown during termination",
                source: "AppDelegate"
            )
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if self.shouldSuppressNextReopenActivation {
            self.shouldSuppressNextReopenActivation = false
            return true
        }

        // Ensure dock-icon reopen always foregrounds FluidVoice.
        sender.activate(ignoringOtherApps: true)

        return !self.bringMainWindowToFrontIfPresent()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let deadline = self.analyticsActivationSuppressionDeadline, Date() <= deadline {
            self.analyticsActivationSuppressionDeadline = nil
        } else {
            self.analyticsActivationSuppressionDeadline = nil
            AnalyticsService.shared.recordAppActivity()
        }
        if self.hasDeferredMLXUpgradeOffer {
            self.hasDeferredMLXUpgradeOffer = false
            self.scheduleMLXUpgradeOffer()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if userInfo[NotificationService.UserInfoKey.kind] as? String == NotificationService.Kind.aiProcessingFallback {
            DispatchQueue.main.async {
                AppNavigationRouter.shared.request(.history)
                self.bringMainWindowToFront()
            }
        }

        completionHandler()
    }

    /// Whether this launch came from macOS Login Items. Reads the launch Apple Event,
    /// which is only valid during applicationDidFinishLaunching.
    /// FLUID_SIMULATE_LOGIN_LAUNCH=1 forces this on for testing, since real login-item
    /// launches can only be produced by logging in.
    private static func detectLoginItemLaunch() -> Bool {
        if ProcessInfo.processInfo.environment["FLUID_SIMULATE_LOGIN_LAUNCH"] == "1" {
            return true
        }
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    /// Apply the user's dock-visibility preference ("Hide from dock", issue #162).
    /// Re-applied after operations that can reset the process activation policy - notably the
    /// LaunchServices reopen below, which restores the bundle default (.regular) even when the
    /// app is reopened without activation, so hide-from-dock is honored on login launches (#396).
    private func applyDockVisibilityPolicy() {
        NSApp.setActivationPolicy(SettingsStore.shared.showInDock ? .regular : .accessory)
    }

    private func openMainWindowOnLaunch() {
        self.applyDockVisibilityPolicy()

        // Users can opt out of showing the window for login-item launches (#369).
        // The window must still be CREATED either way - ContentView's appearance
        // bootstraps the menu bar and services - so the silent path realizes it
        // invisibly instead of skipping it.
        let revealWindow = !self.wasLaunchedAsLoginItem || SettingsStore.shared.showMainWindowAtLoginLaunch

        for delay in [0.1, 0.6, 1.2, 2.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                guard self.didRevealMainWindowOnLaunch == false else { return }

                if revealWindow {
                    NSApp.unhide(nil)
                    NSApp.activate(ignoringOtherApps: true)

                    if self.bringMainWindowToFrontIfPresent() {
                        self.didRevealMainWindowOnLaunch = true
                        return
                    }
                } else if self.bootMainWindowHiddenIfPresent() {
                    self.didRevealMainWindowOnLaunch = true
                    return
                }

                DebugLogger.shared.debug("Main window not ready during launch reveal retry", source: "AppDelegate")
                if delay >= 0.6 {
                    self.requestMainWindowReopenIfNeeded(activate: revealWindow)
                }
            }
        }
    }

    private func scheduleMLXUpgradeOffer() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.showMLXUpgradeOffer()
        }
    }

    @MainActor
    private func showMLXUpgradeOffer() {
        // Offered unattended after launch, so it must never block the main actor - see
        // presentFloatingPrompt(title:message:actions:).
        self.presentFloatingPrompt(
            title: "Fluid-1 is now 2.2x faster",
            message: "A new 3.77 GB MLX model is available for Apple silicon. Continue to AI Enhancement to download and verify it. Your current slower model will keep working unless you choose to upgrade.",
            actions: [
                FloatingPromptAction(title: "Continue to Download") { [weak self] in
                    PrivateAIMLXUpgradeCoordinator.beginUpgrade()
                    AppNavigationRouter.shared.request(.aiEnhancements)
                    self?.bringMainWindowToFront()
                },
                FloatingPromptAction(title: "Keep Current Model") {
                    PrivateAIMLXUpgradeCoordinator.keepCurrentModel()
                },
            ]
        )
    }

    /// Realize the main window invisibly so ContentView's startup runs, then order it out.
    /// Used for login-item launches when "Show window when launched at login" is off.
    @discardableResult
    private func bootMainWindowHiddenIfPresent() -> Bool {
        guard let mainWindow = NSApp.windows.first(where: self.isMainWindow) else { return false }

        let originalAlpha = mainWindow.alphaValue
        mainWindow.alphaValue = 0
        mainWindow.orderFrontRegardless()

        // Give ContentView.onAppear time to finish its startup work (menu bar setup plus
        // the delayed service initialization), then put the window away. Alpha is restored
        // so opening it later from the menu bar shows it normally.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak mainWindow] in
            guard let mainWindow, mainWindow.alphaValue <= 0.01 else { return }
            mainWindow.orderOut(nil)
            mainWindow.alphaValue = originalAlpha
            DebugLogger.shared.info(
                "Main window booted hidden (show-at-login-launch disabled)",
                source: "AppDelegate"
            )
        }
        return true
    }

    private func requestMainWindowReopenIfNeeded(activate: Bool = true) {
        guard !self.didRequestMainWindowReopen else { return }
        self.didRequestMainWindowReopen = true

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        if !activate {
            self.shouldSuppressNextReopenActivation = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.shouldSuppressNextReopenActivation = false
            }
        }

        DebugLogger.shared.info("Requesting LaunchServices reopen to create SwiftUI main window", source: "AppDelegate")
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
            if let error {
                DebugLogger.shared.error("LaunchServices reopen failed: \(error.localizedDescription)", source: "AppDelegate")
            }
            // The reopen restores the app's bundle default activation policy (.regular), which
            // would surface the Dock icon even when the user enabled "Hide from dock". Re-apply
            // the configured policy so login launches honor the setting (#396). The completion
            // runs off the main thread, so hop back before touching NSApp.
            DispatchQueue.main.async {
                self?.applyDockVisibilityPolicy()
            }
        }
    }

    private func bringMainWindowToFront() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !self.bringMainWindowToFrontIfPresent() {
            DebugLogger.shared.debug("Main window not ready", source: "AppDelegate")
        }
    }

    @discardableResult
    private func bringMainWindowToFrontIfPresent() -> Bool {
        if let mainWindow = NSApp.windows.first(where: self.isMainWindow) {
            if mainWindow.alphaValue <= 0.01 {
                mainWindow.alphaValue = 1
            }
            mainWindow.orderFrontRegardless()
            mainWindow.makeKeyAndOrderFront(nil)
            DebugLogger.shared.debug("Brought main window to front", source: "AppDelegate")
            return true
        }

        return false
    }

    private func isMainWindow(_ window: NSWindow) -> Bool {
        guard window.level == .normal else { return false }
        guard window.styleMask.contains(.titled) else { return false }
        return window.title == "FluidVoice" || window.title.contains("FluidVoice")
    }

    // MARK: - Periodic Update Checks

    private func schedulePeriodicUpdateChecks() {
        // Schedule a timer to check for updates every hour (3600 seconds)
        // The actual check logic inside checkForUpdatesAutomatically() handles:
        // - Whether auto-updates are enabled
        // - Whether enough time has passed since last check
        // - Whether the user snoozed the prompt
        self.updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            DebugLogger.shared.debug("Periodic update check timer fired", source: "AppDelegate")
            self?.checkForUpdatesAutomatically()
        }
    }

    // MARK: - Manual Update Check

    @objc func checkForUpdatesManually() {
        // Confirm invocation
        DebugLogger.shared.info("🔎 Manual update check triggered", source: "AppDelegate")

        // Get current app version for debugging
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        DebugLogger.shared.info(
            "Manual update check requested. Current version: \(currentVersion)",
            source: "AppDelegate"
        )
        DebugLogger.shared.info("Checking repository: altic-dev/Fluid-oss", source: "AppDelegate")
        DebugLogger.shared.debug("🔍 DEBUG: Manual update check started - Current version: \(currentVersion)", source: "AppDelegate")
        DebugLogger.shared.debug("🔍 DEBUG: Repository: altic-dev/Fluid-oss", source: "AppDelegate")
        let includePrerelease = SettingsStore.shared.betaReleasesEnabled
        DebugLogger.shared.info(
            "Beta releases opt-in: \(SettingsStore.shared.betaReleasesEnabled)",
            source: "AppDelegate"
        )

        Task { @MainActor in
            do {
                // Use our tolerant updater to handle v-prefixed tags and 2-part versions
                try await SimpleUpdater.shared.checkAndUpdate(
                    owner: "altic-dev",
                    repo: "Fluid-oss",
                    includePrerelease: includePrerelease
                )
            } catch SimpleUpdateError.updateAlreadyInProgress {
                DebugLogger.shared.info("Update installation already in progress", source: "AppDelegate")
            } catch {
                if let pmkError = error as? PMKError, pmkError.isCancelled {
                    DebugLogger.shared.info("App is already up-to-date", source: "AppDelegate")
                    let isBeta = SettingsStore.shared.betaReleasesEnabled
                    self.showUpdateAlert(
                        title: isBeta ? "No Beta Updates" : "No Updates",
                        message: isBeta
                            ? "You're already running the latest build available in the beta channel."
                            : "You're already running the latest version of Fluid!"
                    )
                } else {
                    DebugLogger.shared.error("Update check failed: \(error)", source: "AppDelegate")
                    self.showUpdateAlert(
                        title: "Update Check Failed",
                        message: "Unable to check for updates. Please try again later.\n\nError: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    // MARK: - Automatic Update Check

    private func checkForUpdatesAutomatically() {
        // Check if we should perform an automatic update check
        guard SettingsStore.shared.shouldCheckForUpdates() else {
            let reason = !SettingsStore.shared.autoUpdateCheckEnabled ? "disabled by user" : "checked recently"
            DebugLogger.shared.debug("Automatic update check skipped (\(reason))", source: "AppDelegate")
            return
        }

        DebugLogger.shared.info("Scheduling automatic update check...", source: "AppDelegate")

        // Delay check slightly to avoid slowing down app launch
        Task {
            // Wait 3 seconds after launch before checking
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            DebugLogger.shared.info("Performing automatic update check for altic-dev/Fluid-oss", source: "AppDelegate")

            do {
                let includePrerelease = SettingsStore.shared.betaReleasesEnabled
                let result = try await SimpleUpdater.shared.checkForUpdate(
                    owner: "altic-dev",
                    repo: "Fluid-oss",
                    includePrerelease: includePrerelease
                )

                // Update the last check date regardless of result
                await MainActor.run {
                    SettingsStore.shared.updateLastCheckDate()
                }

                if result.hasUpdate {
                    DebugLogger.shared.info("✅ Update available: \(result.latestVersion)", source: "AppDelegate")

                    guard !SimpleUpdater.shared.isUpdateInProgress else {
                        DebugLogger.shared.debug(
                            "Update prompt skipped because installation is already in progress",
                            source: "AppDelegate"
                        )
                        return
                    }

                    // Check if user snoozed this version (clicked "Later")
                    if SettingsStore.shared.shouldShowUpdatePrompt(forVersion: result.latestVersion) {
                        // Show update notification on main thread
                        await MainActor.run {
                            self.showUpdateNotification(version: result.latestVersion)
                        }
                    } else {
                        DebugLogger.shared.debug("Update prompt snoozed for \(result.latestVersion), skipping notification", source: "AppDelegate")
                    }
                } else {
                    DebugLogger.shared.info("✅ App is up to date", source: "AppDelegate")
                }
            } catch {
                // Silently log the error, don't bother the user with failed automatic checks
                DebugLogger.shared.debug("Automatic update check failed: \(error.localizedDescription)", source: "AppDelegate")

                // Still update last check date to avoid hammering the API on failure
                await MainActor.run {
                    SettingsStore.shared.updateLastCheckDate()
                }
            }
        }
    }

    @MainActor
    private func showUpdateNotification(version: String) {
        DebugLogger.shared.info("Showing update notification for version \(version)", source: "AppDelegate")
        self.presentFloatingPrompt(
            title: "Update Available",
            message: "FluidVoice \(version) is now available. The app will restart automatically after installation.",
            actions: [
                FloatingPromptAction(title: "Install Now") { [weak self] in
                    self?.installOfferedUpdate()
                },
                FloatingPromptAction(title: "Later") { [weak self] in
                    self?.postponeOfferedUpdate(version: version)
                },
            ]
        )
    }

    @MainActor
    private func installOfferedUpdate() {
        DebugLogger.shared.info("User chose to install update now", source: "AppDelegate")
        SettingsStore.shared.clearUpdateSnooze() // Clear snooze since they're installing
        // Installing restarts the app, so taking focus here costs nothing and keeps the updater's
        // own install status window in front of the user.
        NSApp.activate(ignoringOtherApps: true)
        self.checkForUpdatesManually()
    }

    @MainActor
    private func postponeOfferedUpdate(version: String) {
        DebugLogger.shared.info("User postponed update for 24 hours", source: "AppDelegate")
        SettingsStore.shared.snoozeUpdatePrompt(forVersion: version)
    }

    @MainActor
    private func showUpdateAlert(title: String, message: String) {
        self.presentFloatingPrompt(
            title: title,
            message: message,
            actions: [FloatingPromptAction(title: "OK") {}]
        )
    }

    // MARK: - Floating Prompts

    /// Presents a prompt from a floating panel instead of a modal alert.
    ///
    /// These prompts used to be `NSAlert.runModal()`. That call never returns until the alert is
    /// dismissed, and it runs inside a main actor job, so every other `@MainActor` job queues up
    /// behind it - including the dictation callbacks `GlobalHotkeyManager` posts from its event
    /// tap. FluidVoice is a menu bar app that is rarely frontmost, so the alert also came up
    /// unactivated behind other windows: dictation stayed dead until the user found the hidden
    /// dialog (#564, #745). The panel keeps the main actor free and floats above other apps
    /// without stealing focus, and matches the install status panel in SimpleUpdater.
    ///
    /// `actions` is ordered like `NSAlert.addButton(withTitle:)`: the first action is laid out
    /// where the alert's default button used to sit. Choosing one dismisses the panel before its
    /// handler runs, so a handler is free to present the next prompt.
    ///
    /// Only one prompt is on screen at a time. The title identifies the prompt: a repeat of the one
    /// already showing is dropped (checks that used to be blocked by the modal now really do run
    /// while a prompt is up), and a different prompt replaces it rather than stacking on top.
    @MainActor
    private func presentFloatingPrompt(title: String, message: String, actions: [FloatingPromptAction]) {
        DebugLogger.shared.info("🔔 Showing prompt: \(title)", source: "AppDelegate")

        guard self.floatingPromptTitle != title else {
            DebugLogger.shared.debug("Prompt \"\(title)\" already on screen, skipping duplicate", source: "AppDelegate")
            return
        }
        self.dismissFloatingPrompt()

        let margin: CGFloat = 22
        let textLeading: CGFloat = 92
        let buttonHeight: CGFloat = 30
        let buttonSpacing: CGFloat = 10

        let buttons = actions.map { action in
            FloatingPromptButton(title: action.title) { [weak self] in
                self?.dismissFloatingPrompt()
                action.handler()
            }
        }
        // The leading action is the default one, so give it the wider minimum an alert would use.
        let buttonWidths = buttons.enumerated().map { index, button in
            max(ceil(button.fittingSize.width), index == 0 ? 96 : 80)
        }
        let buttonsWidth = buttonWidths.reduce(0, +) + buttonSpacing * CGFloat(max(buttons.count - 1, 0))
        let panelWidth = max(420, margin * 2 + buttonsWidth)
        let textWidth = panelWidth - textLeading - margin

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        let titleHeight = ceil(titleLabel.fittingSize.height)

        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = textWidth
        let detailHeight = ceil(detail.fittingSize.height)

        let buttonsY = margin - 2
        let detailY = buttonsY + buttonHeight + 16
        let titleY = detailY + detailHeight + 8
        let panelHeight = titleY + titleHeight + margin

        titleLabel.frame = NSRect(x: textLeading, y: titleY, width: textWidth, height: titleHeight)
        detail.frame = NSRect(x: textLeading, y: detailY, width: textWidth, height: detailHeight)

        var buttonTrailing = panelWidth - margin
        for (button, width) in zip(buttons, buttonWidths) {
            button.frame = NSRect(x: buttonTrailing - width, y: buttonsY, width: width, height: buttonHeight)
            buttonTrailing -= width + buttonSpacing
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        // The panel is owned by floatingPromptWindow, so let ARC release it after close().
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.autoresizingMask = [.width, .height]

        let icon = NSImageView(frame: NSRect(x: margin, y: panelHeight - margin - 52, width: 52, height: 52))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)
        content.addSubview(titleLabel)
        content.addSubview(detail)
        for button in buttons {
            content.addSubview(button)
        }

        panel.contentView = content
        panel.center()
        // Floating level plus orderFrontRegardless puts the prompt above the frontmost app without
        // activating FluidVoice, so an in-flight dictation is never interrupted to show it.
        panel.orderFrontRegardless()
        self.floatingPromptWindow = panel
        self.floatingPromptTitle = title
    }

    @MainActor
    private func dismissFloatingPrompt() {
        self.floatingPromptWindow?.close()
        self.floatingPromptWindow = nil
        self.floatingPromptTitle = nil
    }
}

/// One button on a floating prompt panel.
private struct FloatingPromptAction {
    let title: String
    let handler: @MainActor () -> Void
}

/// Push button for a floating prompt panel.
///
/// The panel is a non-activating panel of a menu bar app, so it never becomes key; accepting the
/// first mouse keeps a single click on the button working while another app stays frontmost.
private final class FloatingPromptButton: NSButton {
    private let onClick: @MainActor () -> Void

    init(title: String, onClick: @escaping @MainActor () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .rounded
        self.target = self
        self.action = #selector(self.handleClick)
        self.sizeToFit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FloatingPromptButton is created in code only")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    @objc private func handleClick() {
        // The handler closes the panel that owns this button, so hold the closure for the call.
        let onClick = self.onClick
        onClick()
    }
}
