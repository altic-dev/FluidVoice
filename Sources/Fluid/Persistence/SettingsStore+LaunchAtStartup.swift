import Foundation
#if os(macOS)
import ServiceManagement
#endif

extension SettingsStore {
    private static var launchAtStartupDefaults: UserDefaults {
        UserDefaults.standard
    }

    func refreshLaunchAtStartupStatus(clearError: Bool = false, logMismatch: Bool = true) {
        #if os(macOS)
        let storedValue = Self.launchAtStartupDefaults.bool(forKey: LaunchAtStartupKeys.preference)
        let systemState = self.currentLaunchAtStartupSystemState()
        let systemEnabled = systemState.isEnabled

        if logMismatch, storedValue != systemEnabled {
            DebugLogger.shared.warning(
                "Launch at startup preference mismatch. Stored: \(storedValue), actual: \(systemEnabled). Preferring macOS state.",
                source: "SettingsStore"
            )
        }

        Self.launchAtStartupDefaults.set(systemEnabled, forKey: LaunchAtStartupKeys.preference)

        let nextErrorMessage = clearError ? nil : self.launchAtStartupErrorMessage
        let nextStatusMessage = systemState.message
        if self.launchAtStartupEnabled != systemEnabled ||
            self.launchAtStartupStatusMessage != nextStatusMessage ||
            self.launchAtStartupErrorMessage != nextErrorMessage
        {
            self.applyLaunchAtStartupStatus(
                enabled: systemEnabled,
                statusMessage: nextStatusMessage,
                errorMessage: nextErrorMessage
            )
        }
        #else
        let unavailableMessage = "Launch at startup is only available on macOS."
        let nextErrorMessage = clearError ? nil : self.launchAtStartupErrorMessage
        if self.launchAtStartupEnabled ||
            self.launchAtStartupStatusMessage != unavailableMessage ||
            self.launchAtStartupErrorMessage != nextErrorMessage
        {
            self.applyLaunchAtStartupStatus(
                enabled: false,
                statusMessage: unavailableMessage,
                errorMessage: nextErrorMessage
            )
        }
        #endif
    }

    func setLaunchAtStartup(_ enabled: Bool) {
        #if os(macOS)
        let service = SMAppService.mainApp
        let statusBeforeChange = self.currentLaunchAtStartupSystemState()

        if statusBeforeChange.isEnabled == enabled {
            if enabled == false {
                self.cleanupLegacyCompatibilityLoginItemAfterDisable()
            }
            self.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)
            return
        }

        do {
            if enabled {
                try service.register()
                DebugLogger.shared.info("Requested registration for launch at startup", source: "SettingsStore")
            } else {
                try service.unregister()
                self.cleanupLegacyCompatibilityLoginItemAfterDisable()
                DebugLogger.shared.info("Requested unregistration from launch at startup", source: "SettingsStore")
            }

            self.refreshLaunchAtStartupStatus(clearError: true, logMismatch: false)

            if self.launchAtStartupEnabled != enabled {
                let mismatchMessage = enabled
                    ? "macOS did not enable FluidVoice in Login Items. Check System Settings > General > Login Items."
                    : "macOS still shows FluidVoice in Login Items. Check System Settings > General > Login Items."
                self.applyLaunchAtStartupErrorMessage(mismatchMessage)
                DebugLogger.shared.warning(mismatchMessage, source: "SettingsStore")
            }
        } catch {
            DebugLogger.shared.error("Failed to update launch at startup: \(error)", source: "SettingsStore")
            self.refreshLaunchAtStartupStatus(clearError: false, logMismatch: false)

            let message = self.launchAtStartupFailureMessage(for: error, enabling: enabled)
            if self.launchAtStartupErrorMessage != message {
                self.applyLaunchAtStartupErrorMessage(message)
            }
        }
        #else
        let message = "Launch at startup is only available on macOS."
        if self.launchAtStartupErrorMessage != message {
            self.applyLaunchAtStartupErrorMessage(message)
        }
        #endif
    }

    #if os(macOS)
    private func currentLaunchAtStartupSystemState() -> LaunchAtStartupSystemState {
        let service = SMAppService.mainApp
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .disabled
        case .notRegistered:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    private func launchAtStartupFailureMessage(for error: Error, enabling: Bool) -> String {
        let nsError = error as NSError
        let action = enabling ? "enable" : "disable"
        let lowercasedDescription = nsError.localizedDescription.lowercased()

        if lowercasedDescription.contains("developer") ||
            lowercasedDescription.contains("sign") ||
            lowercasedDescription.contains("entitlement")
        {
            return "FluidVoice could not \(action) launch at startup. This build may not be signed correctly for macOS Login Items."
        }

        if lowercasedDescription.contains("approval") ||
            lowercasedDescription.contains("authorize")
        {
            return "macOS needs approval before FluidVoice can \(action) launch at startup. Check System Settings > General > Login Items."
        }

        return "FluidVoice could not \(action) launch at startup. macOS reported: \(nsError.localizedDescription)"
    }

    private func cleanupLegacyCompatibilityLoginItemAfterDisable() {
        do {
            try self.unregisterCompatibilityLoginItemIfNeeded()
        } catch {
            DebugLogger.shared.warning(
                "Failed to remove legacy compatibility login item after disabling launch at startup: \(error)",
                source: "SettingsStore"
            )
        }
    }

    private func unregisterCompatibilityLoginItemIfNeeded() throws {
        guard Self.launchAtStartupDefaults.bool(forKey: LaunchAtStartupKeys.legacyCompatibilityItem) else { return }

        let appName = self.compatibilityLoginItemName
        let script = """
        tell application "System Events"
            if exists login item "\(self.appleScriptEscaped(appName))" then
                delete login item "\(self.appleScriptEscaped(appName))"
            end if
        end tell
        """

        try self.runLaunchAtStartupAppleScript(script)
        Self.launchAtStartupDefaults.set(false, forKey: LaunchAtStartupKeys.legacyCompatibilityItem)
    }

    private var compatibilityLoginItemName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "FluidVoice"
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runLaunchAtStartupAppleScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NSError(
                domain: "FluidVoiceLaunchAtStartup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create launch at startup cleanup script."]
            )
        }

        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 2
            throw NSError(
                domain: "FluidVoiceLaunchAtStartup",
                code: number,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
    #endif
}

#if os(macOS)
private enum LaunchAtStartupSystemState {
    case enabled
    case disabled
    case requiresApproval

    var isEnabled: Bool {
        switch self {
        case .enabled:
            return true
        case .disabled, .requiresApproval:
            return false
        }
    }

    var message: String {
        switch self {
        case .enabled:
            return "FluidVoice reflects the actual macOS login item state."
        case .disabled:
            return "FluidVoice reflects the actual macOS login item state. Unsigned or development builds may fail to enable this."
        case .requiresApproval:
            return "macOS requires approval for FluidVoice in Login Items before launch at startup becomes active."
        }
    }
}
#endif

private enum LaunchAtStartupKeys {
    static let preference = "LaunchAtStartup"
    static let legacyCompatibilityItem = "LaunchAtStartupCompatibilityFallback"
}
