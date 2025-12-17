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
                return message
            }
            return "Unhandled Keychain status: \(status)"
        }
    }
}

/// Lightweight helper for storing provider API keys in the system Keychain.
/// Keys are stored as generic passwords scoped to the FluidVoice service.
final class KeychainService {
    static let shared = KeychainService()

    private let service = "com.fluidvoice.provider-api-keys"
    private let account = "fluidApiKeys"

    private init() {}

    // MARK: - Public API

    func storeKey(_ key: String, for providerID: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var keys = try loadStoredKeys()
        keys[providerID] = trimmed
        try self.saveStoredKeys(keys)
    }

    func fetchKey(for providerID: String) throws -> String? {
        let keys = try loadStoredKeys()
        return keys[providerID]
    }

    func deleteKey(for providerID: String) throws {
        var keys = try loadStoredKeys()
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

    func storeAllKeys(_ values: [String: String]) throws {
        try self.saveStoredKeys(values)
    }

    func legacyProviderEntries() throws -> [String: String] {
        var result: [String: String] = [:]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        switch status {
        case errSecSuccess:
            guard let attributesArray = items as? [[String: Any]] else { return [:] }
            for attributes in attributesArray {
                guard let providerID = attributes[kSecAttrAccount as String] as? String,
                      providerID != account,
                      let data = attributes[kSecValueData as String] as? Data,
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
        let targets: [String]
        if providerIDs.isEmpty {
            targets = try Array(self.legacyProviderEntries().keys)
        } else {
            targets = providerIDs
        }

        for providerID in targets {
            let status = SecItemDelete(legacyQuery(for: providerID) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainServiceError.unhandled(status)
            }
        }
    }

    // MARK: - Private helpers

    private func loadStoredKeys() throws -> [String: String] {
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
            if data.isEmpty {
                return [:]
            }
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
        let data = try JSONEncoder().encode(keys)

        var attributes = self.aggregatedQuery()
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            try self.removeLegacyEntries()
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                aggregatedQuery() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainServiceError.unhandled(updateStatus)
            }
            try self.removeLegacyEntries()
        default:
            throw KeychainServiceError.unhandled(status)
        }
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
