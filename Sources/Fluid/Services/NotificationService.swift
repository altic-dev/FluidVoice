import Foundation
import UserNotifications

enum NotificationService {
    enum UserInfoKey {
        static let kind = "kind"
    }

    enum Kind {
        static let aiProcessingFallback = "aiProcessingFallback"
        static let commandModeFailure = "commandModeFailure"
        static let preferredMicrophoneFallback = "preferredMicrophoneFallback"
    }

    enum Identifier {
        static let preferredMicrophoneFallback = "preferred-microphone-fallback"
    }

    /// Retracts the fallback notification once the preferred microphone is in use again, so the
    /// banner does not keep claiming the device is unavailable after it has reconnected.
    static func withdrawPreferredMicrophoneFallback() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Identifier.preferredMicrophoneFallback])
        center.removePendingNotificationRequests(withIdentifiers: [Identifier.preferredMicrophoneFallback])
    }

    /// Announces that FluidVoice-only mode could not use the pinned microphone and is recording
    /// through the macOS default instead. The fallback itself is intended behaviour — this only
    /// makes it visible so the substitution is never silent.
    static func showPreferredMicrophoneFallback(fallbackDeviceName: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.deliverPreferredMicrophoneFallback(fallbackDeviceName: fallbackDeviceName, using: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, requestError in
                    if let requestError {
                        DebugLogger.shared.warning(
                            "Notification permission request failed: \(requestError.localizedDescription)",
                            source: "NotificationService"
                        )
                    }
                    guard granted else { return }
                    self.deliverPreferredMicrophoneFallback(fallbackDeviceName: fallbackDeviceName, using: center)
                }
            case .denied:
                DebugLogger.shared.debug(
                    "Skipping preferred microphone fallback notification because notification permission is denied",
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

    private static func deliverPreferredMicrophoneFallback(
        fallbackDeviceName: String,
        using center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Preferred microphone unavailable"
        content.body = "Recording through \(fallbackDeviceName) until your selected microphone is reconnected."
        content.sound = nil
        content.userInfo = [UserInfoKey.kind: Kind.preferredMicrophoneFallback]

        // Stable, not per-UUID: this notification promises "until your selected microphone is
        // reconnected", so it has to be retractable. A fresh UUID each time would also stack up one
        // banner per recording. Re-posting with the same identifier replaces the existing one.
        let request = UNNotificationRequest(
            identifier: Identifier.preferredMicrophoneFallback,
            content: content,
            trigger: nil
        )

        center.add(request) { addError in
            if let addError {
                DebugLogger.shared.warning(
                    "Failed to show preferred microphone fallback notification: \(addError.localizedDescription)",
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
}
