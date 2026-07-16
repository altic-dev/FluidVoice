import Foundation
import UserNotifications

enum NotificationService {
    enum UserInfoKey {
        static let kind = "kind"
    }

    enum Kind {
        static let aiProcessingFallback = "aiProcessingFallback"
        static let audioCaptureFallback = "audioCaptureFallback"
        static let commandModeFailure = "commandModeFailure"
        static let clipboardOnlyOutput = "clipboardOnlyOutput"
    }

    static func showAudioCaptureFallback(
        failureCount: Int,
        experimentalSettingDisabled: Bool
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.deliverAudioCaptureFallback(
                    failureCount: failureCount,
                    experimentalSettingDisabled: experimentalSettingDisabled,
                    using: center
                )
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, requestError in
                    if let requestError {
                        DebugLogger.shared.warning(
                            "Notification permission request failed: \(requestError.localizedDescription)",
                            source: "NotificationService"
                        )
                    }
                    guard granted else { return }
                    self.deliverAudioCaptureFallback(
                        failureCount: failureCount,
                        experimentalSettingDisabled: experimentalSettingDisabled,
                        using: center
                    )
                }
            case .denied:
                DebugLogger.shared.debug(
                    "Skipping audio capture fallback notification because notification permission is denied",
                    source: "NotificationService"
                )
            @unknown default:
                break
            }
        }
    }

    static func showAIProcessingFallback(error: String) {
        guard SettingsStore.shared.notifyAIProcessingFailures else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.deliverAIProcessingFallback(error: error, using: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, requestError in
                    if let requestError {
                        DebugLogger.shared.warning(
                            "Notification permission request failed: \(requestError.localizedDescription)",
                            source: "NotificationService"
                        )
                    }
                    guard granted else { return }
                    self.deliverAIProcessingFallback(error: error, using: center)
                }
            case .denied:
                DebugLogger.shared.debug(
                    "Skipping AI fallback notification because notification permission is denied",
                    source: "NotificationService"
                )
            @unknown default:
                break
            }
        }
    }

    static func showCommandModeFailure(error: String) {
        guard SettingsStore.shared.notifyAIProcessingFailures else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.deliverCommandModeFailure(error: error, using: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, requestError in
                    if let requestError {
                        DebugLogger.shared.warning(
                            "Notification permission request failed: \(requestError.localizedDescription)",
                            source: "NotificationService"
                        )
                    }
                    guard granted else { return }
                    self.deliverCommandModeFailure(error: error, using: center)
                }
            case .denied:
                DebugLogger.shared.debug(
                    "Skipping Command Mode notification because notification permission is denied",
                    source: "NotificationService"
                )
            @unknown default:
                break
            }
        }
    }

    static func showClipboardOnlyOutput() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.deliverClipboardOnlyOutput(using: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, requestError in
                    if let requestError {
                        DebugLogger.shared.warning(
                            "Notification permission request failed: \(requestError.localizedDescription)",
                            source: "NotificationService"
                        )
                    }
                    guard granted else { return }
                    self.deliverClipboardOnlyOutput(using: center)
                }
            case .denied:
                DebugLogger.shared.debug(
                    "Skipping clipboard-only notification because notification permission is denied",
                    source: "NotificationService"
                )
            @unknown default:
                break
            }
        }
    }

    private static func deliverAIProcessingFallback(error: String, using center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "AI Enhancement failed"
        content.body = "Typed raw transcription instead."
        content.subtitle = error
        content.sound = nil
        content.userInfo = [UserInfoKey.kind: Kind.aiProcessingFallback]

        let request = UNNotificationRequest(
            identifier: "ai-cleanup-fallback-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { addError in
            if let addError {
                DebugLogger.shared.warning(
                    "Failed to show AI fallback notification: \(addError.localizedDescription)",
                    source: "NotificationService"
                )
            }
        }
    }

    private static func deliverAudioCaptureFallback(
        failureCount: Int,
        experimentalSettingDisabled: Bool,
        using center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        if experimentalSettingDisabled {
            content.title = "Faster Recording Start turned off"
            content.body = "FluidVoice detected malformed microphone audio three times and switched to the compatibility audio path. You can turn it back on in Settings."
        } else {
            content.title = "Microphone audio recovered"
            content.body = "FluidVoice detected malformed audio and switched this session to the compatibility audio path. Faster Recording Start will retry next recording. (\(failureCount)/3)"
        }
        content.sound = nil
        content.userInfo = [UserInfoKey.kind: Kind.audioCaptureFallback]

        let request = UNNotificationRequest(
            identifier: "audio-capture-fallback-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { addError in
            if let addError {
                DebugLogger.shared.warning(
                    "Failed to show audio capture fallback notification: \(addError.localizedDescription)",
                    source: "NotificationService"
                )
            }
        }
    }

    private static func deliverCommandModeFailure(error: String, using center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Command Mode needs setup"
        content.body = error
        content.sound = nil
        content.userInfo = [UserInfoKey.kind: Kind.commandModeFailure]

        let request = UNNotificationRequest(
            identifier: "command-mode-failure-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { addError in
            if let addError {
                DebugLogger.shared.warning(
                    "Failed to show Command Mode notification: \(addError.localizedDescription)",
                    source: "NotificationService"
                )
            }
        }
    }

    private static func deliverClipboardOnlyOutput(using center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Copied to clipboard"
        content.body = "Enable Accessibility for auto-paste and global hotkeys."
        content.sound = nil
        content.userInfo = [UserInfoKey.kind: Kind.clipboardOnlyOutput]

        let request = UNNotificationRequest(
            identifier: "clipboard-only-output-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { addError in
            if let addError {
                DebugLogger.shared.warning(
                    "Failed to show clipboard-only notification: \(addError.localizedDescription)",
                    source: "NotificationService"
                )
            }
        }
    }
}
