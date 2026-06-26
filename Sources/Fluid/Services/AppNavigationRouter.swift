import Foundation

enum AppNavigationDestination {
    case aiEnhancements
    case history
}

final class AppNavigationRouter {
    static let shared = AppNavigationRouter()

    private var pendingDestination: AppNavigationDestination?

    private init() {}

    func request(_ destination: AppNavigationDestination) {
        self.pendingDestination = destination
        NotificationCenter.default.post(name: .appNavigationRequested, object: nil)
    }

    func consumePendingDestination() -> AppNavigationDestination? {
        let destination = self.pendingDestination
        self.pendingDestination = nil
        return destination
    }
}

extension Notification.Name {
    static let appNavigationRequested = Notification.Name("AppNavigationRequested")
    static let dictationPromptShortcutsChanged = Notification.Name("DictationPromptShortcutsChanged")
    static let newPromptShortcutRecorded = Notification.Name("NewPromptShortcutRecorded")
}
