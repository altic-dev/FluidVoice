import Foundation
import Security

enum KeychainServiceError: Error, LocalizedError {
    case invalidData
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Failed to convert key data."
        case let .unhandled(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "\(message) (OSStatus: \(status))"
            }
            return "Unhandled Keychain error (OSStatus: \(status))"
        }
    }
}

/// Lightweight helper for storing provider API keys in the system Keychain.
/// Keys are stored as generic passwords scoped to the FluidVoice service.
final class KeychainService {
    static let shared = KeychainService()

    private struct TestingBackend {
        let load: () throws -> [String: String]
        let save: ([String: String]) throws -> Void
    }

    private enum KeyCache {
        case unloaded
        case loaded([String: String])
    }

    private let service = "com.fluidvoice.provider-api-keys"
    private let account = "fluidApiKeys"
    private let cacheLock = NSLock()
    private let ioLock = NSRecursiveLock()
    private var keyCache = KeyCache.unloaded
    private let testingBackend: TestingBackend?

    private init() {
        // The ASR baseline host must never touch credentials; any transitive
        // `SettingsStore.shared` initialization reaches this stored-property singleton.
        #if FLUID_ASR_BASELINE
        fatalError("KeychainService is unavailable in the ASR baseline host")
        #endif
        self.testingBackend = nil
    }

    init(
        testingLoad: @escaping () throws -> [String: String],
        testingSave: @escaping ([String: String]) throws -> Void
    ) {
        self.testingBackend = TestingBackend(load: testingLoad, save: testingSave)
    }

    // MARK: - Public API

    func storeKey(_ key: String, for providerID: String) throws {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mutations are rare and must merge against the latest aggregate in
        // case another app instance or Keychain Access changed it.
        var keys = try self.loadStoredKeys(forceRefresh: true)
        keys[providerID] = trimmed
        try self.saveStoredKeys(keys)
    }

    func fetchKey(for providerID: String) throws -> String? {
        let keys = try loadStoredKeys()
        return keys[providerID]
    }

    func deleteKey(for providerID: String) throws {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        var keys = try self.loadStoredKeys(forceRefresh: true)
        guard keys.removeValue(forKey: providerID) != nil else { return }
        try self.saveStoredKeys(keys)
    }

    func containsKey(for providerID: String) -> Bool {
        guard let keys = try? loadStoredKeys() else { return false }
        return keys[providerID] != nil
    }

    func allProviderIDs() throws -> [String] {
        return try self.loadStoredKeys().keys.sorted()
    }

    func fetchAllKeys() throws -> [String: String] {
        try self.loadStoredKeys()
    }

    /// Refreshes the process cache after the user returns to FluidVoice, so
    /// Keychain Access or another app instance cannot leave credentials stale.
    /// Callers should run this away from the main thread because Keychain I/O
    /// may wait for the login keychain to become available.
    func refreshCachedKeys() throws {
        _ = try self.loadStoredKeys(forceRefresh: true)
    }

    func storeAllKeys(_ values: [String: String]) throws {
        try self.saveStoredKeys(values)
    }

    func legacyProviderEntries() throws -> [String: String] {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        var result: [String: String] = [:]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        switch status {
        case errSecSuccess:
            guard let attributesArray = items as? [[String: Any]] else { return [:] }
            for attributes in attributesArray {
                guard let providerID = attributes[kSecAttrAccount as String] as? String,
                      providerID != account
                else {
                    continue
                }

                var dataQuery = self.legacyQuery(for: providerID)
                dataQuery[kSecReturnData as String] = true
                dataQuery[kSecMatchLimit as String] = kSecMatchLimitOne

                var dataItem: CFTypeRef?
                let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataItem)
                guard dataStatus == errSecSuccess else {
                    if dataStatus == errSecItemNotFound { continue }
                    throw KeychainServiceError.unhandled(dataStatus)
                }
                guard let data = dataItem as? Data,
                      let key = String(data: data, encoding: .utf8)
                else {
                    continue
                }
                result[providerID] = key
            }
            return result
        case errSecItemNotFound:
            return [:]
        default:
            throw KeychainServiceError.unhandled(status)
        }
    }

    func removeLegacyEntries(providerIDs: [String] = []) throws {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        let targets: [String]
        if !providerIDs.isEmpty {
            targets = providerIDs
        } else {
            targets = try Array((self.legacyProviderEntries()).keys)
        }

        for providerID in targets {
            let status = SecItemDelete(legacyQuery(for: providerID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainServiceError.unhandled(status)
            }
        }
    }

    // MARK: - Private helpers

    private func loadStoredKeys(forceRefresh: Bool = false) throws -> [String: String] {
        if !forceRefresh, case let .loaded(keys) = self.cachedState() { return keys }

        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        // A concurrent cold read may have populated the cache while this caller
        // waited for I/O ownership. Forced refreshes intentionally bypass it.
        if !forceRefresh, case let .loaded(keys) = self.cachedState() { return keys }

        let keys = try self.readStoredKeys()
        self.setCachedKeys(keys)
        return keys
    }

    private func readStoredKeys() throws -> [String: String] {
        if let testingBackend {
            return try testingBackend.load()
        }

        var query = self.aggregatedQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainServiceError.invalidData
            }
            if data.isEmpty { return [:] }
            do {
                return try JSONDecoder().decode([String: String].self, from: data)
            } catch {
                throw KeychainServiceError.invalidData
            }
        case errSecItemNotFound:
            return [:]
        default:
            throw KeychainServiceError.unhandled(status)
        }
    }

    private func saveStoredKeys(_ keys: [String: String]) throws {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        if let testingBackend {
            try testingBackend.save(keys)
            self.setCachedKeys(keys)
            return
        }

        let data = try JSONEncoder().encode(keys)

        var attributes = self.aggregatedQuery()
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            self.setCachedKeys(keys)
            try self.removeLegacyEntries()
            return
        case errSecDuplicateItem:
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(
                aggregatedQuery() as CFDictionary,
                updateAttributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainServiceError.unhandled(updateStatus)
            }
            self.setCachedKeys(keys)
            try self.removeLegacyEntries()
        default:
            throw KeychainServiceError.unhandled(status)
        }
    }

    private func cachedState() -> KeyCache {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        return self.keyCache
    }

    private func setCachedKeys(_ keys: [String: String]) {
        self.cacheLock.lock()
        self.keyCache = .loaded(keys)
        self.cacheLock.unlock()
    }

    private func aggregatedQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
    }

    private func legacyQuery(for providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: providerID,
        ]
    }
}
