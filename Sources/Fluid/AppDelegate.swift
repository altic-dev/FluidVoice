//
//  AppDelegate.swift
//  Fluid
//
//  Created by Barathwaj Anandan on 9/22/25.
//

import AppKit
import PromiseKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var updateCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring up file logging + crash handlers immediately during launch.
        _ = FileLogger.shared
        DebugLogger.shared.info("Application launched", source: "AppDelegate")

        // Initialize app settings (dock visibility, etc.)
        SettingsStore.shared.initializeAppSettings()

        // Record first-open synchronously before async analytics bootstrap so
        // onboarding initialization is deterministic on brand-new installs.
        let isTrueFirstOpen = AnalyticsIdentityStore.shared.ensureFirstOpenRecorded()
        SettingsStore.shared.bootstrapOnboardingState(isTrueFirstOpen: isTrueFirstOpen)

        AnalyticsService.shared.bootstrap()

        if SettingsStore.shared.shouldPromptAccessibilityOnLaunch {
            self.requestAccessibilityPermissions()
        }

        if isTrueFirstOpen {
            AnalyticsService.shared.capture(.appFirstOpen)
        }
        AnalyticsService.shared.capture(
            .appOpen,
            properties: ["accessibility_trusted": AXIsProcessTrusted()]
        )

        // Check for updates automatically if enabled (initial check on launch)
        self.checkForUpdatesAutomatically()

        // Schedule periodic update checks every hour while app is running
        self.schedulePeriodicUpdateChecks()

        // Bring the app to front on initial launch.
        // Use a few delayed retries because SwiftUI window creation can lag app launch callbacks.
        self.forceFrontOnLaunch()

        // Note: App UI is designed with dark color scheme in mind
        // All gradients and effects are optimized for dark mode
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLogger.shared.info("Application will terminate", source: "AppDelegate")
        // Clean up the update check timer
        self.updateCheckTimer?.invalidate()
        self.updateCheckTimer = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Ensure dock-icon reopen always foregrounds MedVoice.
        sender.activate(ignoringOtherApps: true)

        if let mainWindow = sender.windows.first(where: { win in
            guard win.level == .normal else { return false }
            guard win.styleMask.contains(.titled) else { return false }
            return win.title == "MedVoice" || win.title.contains("MedVoice")
        }) {
            mainWindow.orderFrontRegardless()
            mainWindow.makeKeyAndOrderFront(nil)
        }

        return true
    }

    private func forceFrontOnLaunch() {
        // Login-item launches can take longer before SwiftUI's main window exists.
        // Keep retrying for a few seconds so the existing ContentView startup path runs.
        for delay in [0.0, 0.12, 0.35, 1.0, 2.0, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.bringMainWindowToFront()
            }
        }
    }

    private func bringMainWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)

        if let mainWindow = NSApp.windows.first(where: { win in
            guard win.level == .normal else { return false }
            guard win.styleMask.contains(.titled) else { return false }
            return win.title == "MedVoice" || win.title.contains("MedVoice")
        }) {
            mainWindow.orderFrontRegardless()
            mainWindow.makeKeyAndOrderFront(nil)
            DebugLogger.shared.debug("Brought main window to front", source: "AppDelegate")
        } else {
            DebugLogger.shared.debug("Main window not ready yet during launch-front retry", source: "AppDelegate")
        }
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
                // If we get here, an update was found; SimpleUpdater will relaunch on success
                // Show a quick heads-up before app restarts
                self.showUpdateAlert(
                    title: "Update Found!",
                    message: "A new version is available and will be installed now."
                )
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

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "MedVoice \(version) is now available. Would you like to install it now?\n\nThe app will restart automatically after installation."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            DebugLogger.shared.info("User chose to install update now", source: "AppDelegate")
            SettingsStore.shared.clearUpdateSnooze() // Clear snooze since they're installing
            self.checkForUpdatesManually()
        } else {
            DebugLogger.shared.info("User postponed update for 24 hours", source: "AppDelegate")
            SettingsStore.shared.snoozeUpdatePrompt(forVersion: version)
        }
    }

    @MainActor
    private func showUpdateAlert(title: String, message: String) {
        DebugLogger.shared.info("🔔 Showing alert: \(title)", source: "AppDelegate")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func requestAccessibilityPermissions() {
        // Never show if already trusted
        guard !AXIsProcessTrusted() else { return }

        // Per-session debounce
        if AXPromptState.hasPromptedThisSession { return }

        // Cooldown: avoid re-prompting too often across launches
        let cooldownKey = "AXLastPromptAt"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: cooldownKey)
        let oneDay: Double = 24 * 60 * 60
        if last > 0, (now - last) < oneDay {
            return
        }

        DebugLogger.shared.warning("Accessibility permissions required for global hotkeys.", source: "AppDelegate")
        DebugLogger.shared.info("Prompting for Accessibility permission…", source: "AppDelegate")

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        AXPromptState.hasPromptedThisSession = true
        UserDefaults.standard.set(now, forKey: cooldownKey)

        // If still not trusted shortly after, deep-link to the Accessibility pane for convenience
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard !AXIsProcessTrusted(),
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Session Debounce State

private enum AXPromptState {
    static var hasPromptedThisSession: Bool = false
}
