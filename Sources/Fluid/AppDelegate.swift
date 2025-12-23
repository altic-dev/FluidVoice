//
//  AppDelegate.swift
//  Fluid
//
//  Created by Barathwaj Anandan on 9/22/25.
//

import AppKit
import AppUpdater
import PromiseKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var updater: AppUpdater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize AppUpdater for automatic updates
        // Repository: https://github.com/altic-dev/Fluid-oss
        self.updater = AppUpdater(owner: "altic-dev", repo: "Fluid-oss")

        // Request accessibility permissions for global hotkey monitoring
        self.requestAccessibilityPermissions()

        // Initialize app settings (dock visibility, etc.)
        SettingsStore.shared.initializeAppSettings()

        AnalyticsService.shared.bootstrap()

        let isFirstOpen = AnalyticsIdentityStore.shared.ensureFirstOpenRecorded()
        if isFirstOpen {
            AnalyticsService.shared.capture(.appFirstOpen)
        }
        AnalyticsService.shared.capture(
            .appOpen,
            properties: ["accessibility_trusted": AXIsProcessTrusted()]
        )

        // Check for updates automatically if enabled
        self.checkForUpdatesAutomatically()

        // Note: App UI is designed with dark color scheme in mind
        // All gradients and effects are optimized for dark mode
    }

    // MARK: - Manual Update Check

    @objc func checkForUpdatesManually() {
        // Confirm invocation
        DebugLogger.shared.info("🔎 Manual update check triggered", source: "AppDelegate")

        // We use SimpleUpdater for manual checks; AppUpdater instance is optional

        // Get current app version for debugging
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        DebugLogger.shared.info(
            "Manual update check requested. Current version: \(currentVersion)",
            source: "AppDelegate"
        )
        DebugLogger.shared.info("Checking repository: altic-dev/Fluid-oss", source: "AppDelegate")
        DebugLogger.shared.debug("🔍 DEBUG: Manual update check started - Current version: \(currentVersion)", source: "AppDelegate")
        DebugLogger.shared.debug("🔍 DEBUG: Repository: altic-dev/Fluid-oss", source: "AppDelegate")

        Task { @MainActor in
            do {
                // Use our tolerant updater to handle v-prefixed tags and 2-part versions
                try await SimpleUpdater.shared.checkAndUpdate(owner: "altic-dev", repo: "Fluid-oss")
                // If we get here, an update was found; SimpleUpdater will relaunch on success
                // Show a quick heads-up before app restarts
                self.showUpdateAlert(
                    title: "Update Found!",
                    message: "A new version is available and will be installed now."
                )
            } catch {
                if let pmkError = error as? PMKError, pmkError.isCancelled {
                    DebugLogger.shared.info("App is already up-to-date", source: "AppDelegate")
                    self.showUpdateAlert(
                        title: "No Updates",
                        message: "You're already running the latest version of Fluid!"
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
                let result = try await SimpleUpdater.shared.checkForUpdate(owner: "altic-dev", repo: "Fluid-oss")

                // Update the last check date regardless of result
                await MainActor.run {
                    SettingsStore.shared.updateLastCheckDate()
                }

                if result.hasUpdate {
                    DebugLogger.shared.info("✅ Update available: \(result.latestVersion)", source: "AppDelegate")
                    // Show update notification on main thread
                    await MainActor.run {
                        self.showUpdateNotification(version: result.latestVersion)
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
        alert.informativeText = "Fluid \(version) is now available. Would you like to install it now?\n\nThe app will restart automatically after installation."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            DebugLogger.shared.info("User chose to install update now", source: "AppDelegate")
            self.checkForUpdatesManually()
        } else {
            DebugLogger.shared.info("User postponed update", source: "AppDelegate")
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
