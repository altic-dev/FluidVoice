import Foundation

/// Persists the anonymous analytics ID across app updates.
final class AnalyticsIdentityStore {
    nonisolated static let shared = AnalyticsIdentityStore()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let anonymousInstallID = "AnalyticsAnonymousInstallID"
        static let firstOpenAt = "AnalyticsFirstOpenAt"
    }

    private init() {}

    nonisolated var anonymousInstallID: String {
        if let existing = defaults.string(forKey: Keys.anonymousInstallID), !existing.isEmpty {
            return existing
        }
        let newID = UUID().uuidString
        self.defaults.set(newID, forKey: Keys.anonymousInstallID)
        return newID
    }

    /// Returns whether this is the first recorded launch.
    @discardableResult
    nonisolated func ensureFirstOpenRecorded() -> Bool {
        if self.defaults.object(forKey: Keys.firstOpenAt) == nil {
            self.defaults.set(Date().timeIntervalSince1970, forKey: Keys.firstOpenAt)
            return true
        }
        return false
    }

    nonisolated var firstOpenAt: Date? {
        let timestamp = self.defaults.double(forKey: Keys.firstOpenAt)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }
}
