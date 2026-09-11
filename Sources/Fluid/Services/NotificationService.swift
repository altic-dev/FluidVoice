import Foundation
import UserNotifications

enum NotificationService {
    enum UserInfoKey {
        static let kind = "kind"
    }

    enum Kind {
        static let aiProcessingFallback = "aiProcessingFallback"
        static let commandModeFailure = "commandModeFailure"
        static let callTranscriptionInProgress = "callTranscriptionInProgress"
    }

    static func showAIProcessingFallback(error: String) {
        guard SettingsStore.shared.notifyAIProcessingFailures else { return }
        self.show(
            identifier: "ai-cleanup-fallback-\(UUID().uuidString)",
            kind: Kind.aiProcessingFallback,
            title: "AI Enhancement failed",
            body: "Typed raw transcription instead.",
            subtitle: error,
            authorizationOptions: [.alert, .sound]
        )
    }

    static func showCommandModeFailure(error: String) {
        guard SettingsStore.shared.notifyAIProcessingFailures else { return }
        self.show(
            identifier: "command-mode-failure-\(UUID().uuidString)",
            kind: Kind.commandModeFailure,
            title: "Command Mode needs setup",
            body: error,
            authorizationOptions: [.alert, .sound]
        )
    }

    static func showCallTranscriptionInProgress() {
        self.show(
            identifier: "call-transcription-in-progress",
            kind: Kind.callTranscriptionInProgress,
            title: "Call transcription in progress",
            body: "Dictation will be available when it finishes.",
            authorizationOptions: [.alert]
        )
    }

    private static func show(
        identifier: String,
        kind: String,
        title: String,
        body: String,
        subtitle: String? = nil,
        authorizationOptions: UNAuthorizationOptions
    ) {
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.subtitle = subtitle ?? ""
            content.sound = nil
            content.userInfo = [UserInfoKey.kind: kind]
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                if let error {
                    DebugLogger.shared.warning(
                        "Failed to show notification: \(error.localizedDescription)",
                        source: "NotificationService"
                    )
                }
            }
        }

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                deliver()
            case .notDetermined:
                center.requestAuthorization(options: authorizationOptions) { granted, error in
                    if let error {
                        DebugLogger.shared.warning(
                            "Notification permission request failed: \(error.localizedDescription)",
                            source: "NotificationService"
                        )
                    }
                    guard granted else { return }
                    deliver()
                }
            case .denied:
                DebugLogger.shared.debug(
                    "Skipping notification because permission is denied",
                    source: "NotificationService"
                )
            @unknown default:
                break
            }
        }
    }
}