import Foundation

/// Stores anonymous analytics identifiers. This is intentionally NOT tied to any user identity.
final class AnalyticsIdentityStore {
    static let shared = AnalyticsIdentityStore()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let anonymousInstallID = "AnalyticsAnonymousInstallID"
        static let firstOpenAt = "AnalyticsFirstOpenAt"
    }

    private init() {}

    var anonymousInstallID: String {
        if let existing = defaults.string(forKey: Keys.anonymousInstallID), existing.isEmpty == false {
            return existing
        }
        let newID = UUID().uuidString
        self.defaults.set(newID, forKey: Keys.anonymousInstallID)
        return newID
    }

    /// Returns true if this is the first time we've ever recorded an app open on this install.
    @discardableResult
    func ensureFirstOpenRecorded() -> Bool {
        if self.defaults.object(forKey: Keys.firstOpenAt) == nil {
            self.defaults.set(Date().timeIntervalSince1970, forKey: Keys.firstOpenAt)
            return true
        }
        return false
    }

    var firstOpenAt: Date? {
        let ts = self.defaults.double(forKey: Keys.firstOpenAt)
        if ts <= 0 { return nil }
        return Date(timeIntervalSince1970: ts)
    }
}
