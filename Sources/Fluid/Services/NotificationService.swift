import Foundation
import UserNotifications

enum NotificationService {
    enum UserInfoKey {
        static let kind = "kind"
    }

    enum Kind {
        static let aiProcessingFallback = "aiProcessingFallback"
        static let commandModeFailure = "commandModeFailure"
        static let smartNotesFallback = "smartNotesFallback"
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

    static func showSmartNotesFallback(error: String) {
        guard SettingsStore.shared.notifyAIProcessingFailures else { return }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.deliverSmartNotesFallback(error: error, using: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, requestError in
                    if let requestError {
                        DebugLogger.shared.warning(
                            "Notification permission request failed: \(requestError.localizedDescription)",
                            source: "NotificationService"
                        )
                    }
                    guard granted else { return }
                    self.deliverSmartNotesFallback(error: error, using: center)
                }
            case .denied:
                break
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

    private static func deliverSmartNotesFallback(error: String, using center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Smart Note saved without AI"
        content.body = "The raw transcript is safe in your notes folder."
        content.subtitle = error
        content.sound = nil
        content.userInfo = [UserInfoKey.kind: Kind.smartNotesFallback]

        let request = UNNotificationRequest(
            identifier: "smart-notes-fallback-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { addError in
            if let addError {
                DebugLogger.shared.warning(
                    "Failed to show Smart Notes fallback notification: \(addError.localizedDescription)",
                    source: "NotificationService"
                )
            }
        }
    }
}
