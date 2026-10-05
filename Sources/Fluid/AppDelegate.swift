//
//  AppDelegate.swift
//  Fluid
//
//  Created by Barathwaj Anandan on 9/22/25.
//

import AppKit
import Carbon
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static var restartPrepared = false
    private static var restartInProgress = false

    @MainActor
    static func restartAfterSaving() {
        guard !self.restartInProgress else { return }
        self.restartInProgress = true
        Task { @MainActor in
            await TranscriptionHistoryStore.shared.finishPendingWrites()
            guard TranscriptionHistoryStore.shared.persistenceError == nil else {
                self.restartInProgress = false
                DebugLogger.shared.error("Restart cancelled: history could not be saved", source: "AppDelegate")
                return
            }
            UserDefaults.standard.synchronize()
            await PrivateAIIntegrationService.shared.shutdownForTermination()
            await AppServices.shared.shutdownForTermination()
            self.restartPrepared = true
            NSApp.terminate(nil)
        }
    }

    private let updatePromptPresenter = UpdatePromptPresenter.shared
    #if DEBUG
    private var updateUISimulationObserver: NSObjectProtocol?
    #endif
    private var updateCheckTimer: Timer?
    private var didRevealMainWindowOnLaunch = false
    private var didRequestMainWindowReopen = false
    private var shouldSuppressNextReopenActivation = false
    private var wasLaunchedAsLoginItem = false
    private var analyticsActivationSuppressionDeadline: Date?

    var shouldPresentStartupMicrophoneNotice: Bool {
        !self.wasLaunchedAsLoginItem || SettingsStore.shared.showMainWindowAtLoginLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AccessibilityMessagingTimeout.configure()
        #if DEBUG
        self.updateUISimulationObserver = UpdatePromptSimulation.register(self)
        #endif
        #if DEBUG
        // Stage 0.5, Trial A, and C2 autoruns must return before Core Audio observers,
        // logging, AppServices, and UI startup. Each owns one bounded diagnostic stream.
        if MeetingStage05EvidenceAutorun.startIfRequested() {
            return
        }
        if MeetingExternalReferenceTrialAAutorun.startIfRequested() {
            return
        }
        if MeetingSCKPairedAutorun.startIfRequested() {
            return
        }
        // Must precede every Core Audio observer. Disabled unless explicitly
        // requested through the Phase 0 diagnostics environment.
        AudioTopologyDiagnostics.shared.startIfRequested()
        // App-hosted XCTest otherwise starts the normal UI/audio services alongside the
        // exclusive VPIO hardware probe. Keep that opt-in diagnostic launch isolated.
        if ProcessInfo.processInfo.environment["FLUIDVOICE_MIC_PHASE1"] != nil
            || ProcessInfo.processInfo.environment["FLUIDVOICE_VPIO_ACOUSTIC"] == "1"
        {
            return
        }
        #endif
        // Bring up file logging + crash handlers immediately during launch.
        _ = FileLogger.shared
        TypingService.startKeyboardLayoutTracking()
        _ = TranscriptionHistoryStore.shared
        #if arch(arm64)
        Task {
            await CompactSpeechModelReleaseCatalog.shared.refreshIfNeeded()
            SpeechModelInstallationSnapshot.shared.refresh()
        }
        #endif
        #if DEBUG
        MeetingDetectorFeasibilityProbe.startIfRequested()
        #endif
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
        DictationAppSession.shared.start()
        OnboardingAISetupController.live.resumePendingDownload()
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
        self.scheduleMeetingAutoDetectorStart()

        // Note: App UI is designed with dark color scheme in mind
        // All gradients and effects are optimized for dark mode
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.restartPrepared { return .terminateNow }
        Task { @MainActor in
            await TranscriptionHistoryStore.shared.finishPendingWrites()
            if let error = TranscriptionHistoryStore.shared.persistenceError {
                let alert = NSAlert()
                alert.messageText = "History could not be saved"
                alert.informativeText = error
                alert.addButton(withTitle: "Keep Open")
                alert.addButton(withTitle: "Quit Anyway")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
                return
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        if let observer = self.updateUISimulationObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            self.updateUISimulationObserver = nil
        }
        #endif
        if Self.restartPrepared {
            // Launch only after this process exits: never overlap two app instances.
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/sh")
            let waitForExit = "i=0; while kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); [ \"$i\" -lt 120 ] || exit 1; sleep 1; done; exec /usr/bin/open \"$2\""
            helper.arguments = ["-c", waitForExit, "fluidvoice-restart", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
            do { try helper.run() } catch {
                DebugLogger.shared.error("Could not schedule relaunch: \(error)", source: "AppDelegate")
            }
        }
        DebugLogger.shared.info("Application will terminate", source: "AppDelegate")
        if !Self.restartPrepared {
            self.shutdownPrivateAIRuntimeForTermination()
            self.shutdownASRRuntimeForTermination()
        }
        self.closeZeppelinForTermination()
        LocalAPIServer.shared.stop()
        // Clean up the update check timer
        self.updateCheckTimer?.invalidate()
        self.updateCheckTimer = nil
        #if DEBUG
        AudioTopologyDiagnostics.shared.stop()
        #endif
    }

    /// Short deadline: the index is rebuilt from its source stores, so a timeout
    /// costs a log replay at startup and nothing else.
    private func closeZeppelinForTermination() {
        var didClose = false
        Task {
            AppSearchService.shared.stop()
            await SearchIndexCoordinator.shared.stop()
            await FluidZeppelinRoot.shared.shutdown()
            didClose = true
        }

        let deadline = Date().addingTimeInterval(2)
        while !didClose, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        if !didClose {
            DebugLogger.shared.warning(
                "Timed out closing Zeppelin namespaces during termination",
                source: "AppDelegate"
            )
        }
    }

    private func shutdownASRRuntimeForTermination() {
        var didFinishShutdown = false
        Task { @MainActor in
            await AppServices.shared.shutdownForTermination()
            didFinishShutdown = true
        }

        // Meeting capture can spend up to three seconds stopping its runtime and
        // four seconds finalizing audio before the durable session save.
        let deadline = Date().addingTimeInterval(12)
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

        // LaunchServices can restore the bundle's regular activation policy when
        // reopening a running app, so reapply the user's Dock preference first.
        self.applyDockVisibilityPolicy()
        sender.activate(ignoringOtherApps: true)

        return !self.bringMainWindowToFrontIfPresent()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.global(qos: .utility).async {
            try? KeychainService.shared.refreshCachedKeys()
        }
        if let deadline = self.analyticsActivationSuppressionDeadline, Date() <= deadline {
            self.analyticsActivationSuppressionDeadline = nil
        } else {
            self.analyticsActivationSuppressionDeadline = nil
            AnalyticsService.shared.recordAppActivity()
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

    private func scheduleMeetingAutoDetectorStart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task { @MainActor in
                _ = AppServices.shared.meetingAutoDetector
            }
        }
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
        SimpleUpdater.shared.checkForUpdatesManually()
    }

    // MARK: - Automatic Update Check

    private func checkForUpdatesAutomatically() {
        #if DEBUG
        guard !UpdatePromptSimulation.isEnabled else { return }
        #endif
        guard SettingsStore.shared.shouldCheckForUpdates() else { return }
        Task {
            // Keep the existing launch delay; the updater rechecks current preferences.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, SettingsStore.shared.shouldCheckForUpdates() else { return }
            SimpleUpdater.shared.checkForUpdatesAutomatically()
        }
    }

    @MainActor
    private func showUpdateAlert(title: String, message: String) {
        DebugLogger.shared.info("🔔 Showing alert: \(title)", source: "AppDelegate")
        self.updatePromptPresenter.presentFloatingPrompt(
            title: title,
            message: message,
            actions: [FloatingPromptAction(title: "OK") {}]
        )
    }

    #if DEBUG
    @MainActor
    func simulateUpdateUI(_ scenario: String) {
        guard UpdatePromptSimulation.isEnabled else { return }
        switch scenario {
        case "offer":
            guard !SimpleUpdater.shared.isUpdateInProgress else { return }
            SimpleUpdater.shared.simulationHasUpdate = true
            SimpleUpdater.shared.checkForUpdatesAutomatically()
        case "manual":
            SimpleUpdater.shared.simulationHasUpdate = true
            self.checkForUpdatesManually()
        case "no-update":
            SimpleUpdater.shared.simulationHasUpdate = false
            self.checkForUpdatesManually()
        case "progress":
            Task { try? await SimpleUpdater.shared.checkAndUpdate(owner: "altic-dev", repo: "Fluid-oss") }
        case "failure":
            SimpleUpdater.shared.finishSimulatedUpdate()
            self.showUpdateAlert(title: "Update Check Failed", message: "Simulated download failure. No update was downloaded or installed.")
        case "dismiss":
            SimpleUpdater.shared.finishSimulatedUpdate()
            self.updatePromptPresenter.dismissAll()
        default:
            return
        }
        DebugLogger.shared.info("Update UI simulation: \(scenario)", source: "AppDelegate")
    }
    #endif
}
