import CryptoKit
import Foundation

/// Optional successful model checks, separate from legacy provider connection status.
/// Stores only hashes and timestamps, never API keys, URLs, or request contents.
@MainActor
final class ProviderModelVerificationStore {
    static let defaultsKey = "ProviderModelVerificationsV1"
    static let maximumEntries = 256
    private let defaults: UserDefaults
    private var successes: [String: Double]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        self.successes = Dictionary(uniqueKeysWithValues: stored
            .filter { $0.key.count == 64 && $0.value.isFinite }
            .sorted { $0.value > $1.value }
            .prefix(Self.maximumEntries)
            .map { ($0.key, $0.value) })
    }

    static func identity(providerID: String, baseURL: String, apiKey: String, model: String) -> String {
        let fields = [providerID, baseURL, apiKey, model].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func contains(_ identity: String) -> Bool { self.successes[identity] != nil }

    func recordSuccess(_ identity: String, now: Date = Date()) {
        self.successes[identity] = now.timeIntervalSince1970
        while self.successes.count > Self.maximumEntries,
              let oldest = self.successes.min(by: { $0.value < $1.value })?.key
        {
            self.successes.removeValue(forKey: oldest)
        }
        self.defaults.set(self.successes, forKey: Self.defaultsKey)
    }

    func remove(_ identity: String) {
        guard self.successes.removeValue(forKey: identity) != nil else { return }
        self.defaults.set(self.successes, forKey: Self.defaultsKey)
    }
}
