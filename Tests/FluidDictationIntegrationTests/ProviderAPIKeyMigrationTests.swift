@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class ProviderAPIKeyMigrationTests: XCTestCase {
    private let savedProvidersKey = "SavedProviders"
    private let providerAPIKeysKey = "ProviderAPIKeys"
    private let providerAPIKeyMigrationCompletedKey = "ProviderAPIKeyMigrationCompleted"
    private static var retainedStores: [SettingsStore] = []

    func testScrubPreservesAPIKeyWhenKeychainStoreFailsForThatProvider() throws {
        try self.withIsolatedProviderState { store, defaults in
            let keychain = MockProviderKeychain()
            store.replaceKeychainForTesting(keychain)
            keychain.failingProviderIDs = ["custom:failing-provider"]

            let succeeding = SettingsStore.SavedProvider(
                id: "custom:ok-provider",
                name: "OK Provider",
                baseURL: "https://ok.example",
                apiKey: "sk-ok",
                models: []
            )
            let failing = SettingsStore.SavedProvider(
                id: "custom:failing-provider",
                name: "Failing Provider",
                baseURL: "https://fail.example",
                apiKey: "sk-keep-me",
                models: []
            )
            defaults.set(try JSONEncoder().encode([succeeding, failing]), forKey: self.savedProvidersKey)

            store.scrubSavedProviderAPIKeysForTesting()

            let data = try XCTUnwrap(defaults.data(forKey: self.savedProvidersKey))
            let result = try JSONDecoder().decode([SettingsStore.SavedProvider].self, from: data)
            let failingResult = try XCTUnwrap(result.first { $0.id == "custom:failing-provider" })
            let okResult = try XCTUnwrap(result.first { $0.id == "custom:ok-provider" })

            XCTAssertEqual(failingResult.apiKey, "sk-keep-me")
            XCTAssertEqual(okResult.apiKey, "")
            XCTAssertEqual(keychain.consolidatedKeys["custom:ok-provider"], "sk-ok")
        }
    }

    func testMigrateKeepsLegacySourcesWhenConsolidatedSaveFails() throws {
        try self.withIsolatedProviderState { store, defaults in
            let keychain = MockProviderKeychain()
            store.replaceKeychainForTesting(keychain)
            keychain.legacyEntries = ["anthropic": "legacy-keychain-secret"]
            keychain.shouldThrowOnWrite = true
            defaults.set(["openai": "legacy-defaults-secret"], forKey: self.providerAPIKeysKey)

            store.migrateProviderAPIKeysForTesting()

            let legacyDefaults = try XCTUnwrap(defaults.dictionary(forKey: self.providerAPIKeysKey) as? [String: String])
            XCTAssertEqual(legacyDefaults["openai"], "legacy-defaults-secret")
            XCTAssertEqual(keychain.legacyEntries["anthropic"], "legacy-keychain-secret")
            XCTAssertFalse(defaults.bool(forKey: self.providerAPIKeyMigrationCompletedKey))
            XCTAssertTrue(keychain.removedLegacyProviderIDs.isEmpty)
        }
    }

    func testMigratePersistsDefaultsWhenLegacyKeychainReadFails() throws {
        try self.withIsolatedProviderState { store, defaults in
            let keychain = MockProviderKeychain()
            store.replaceKeychainForTesting(keychain)
            keychain.shouldThrowOnLegacyRead = true
            defaults.set(["openai": "legacy-defaults-secret"], forKey: self.providerAPIKeysKey)

            store.migrateProviderAPIKeysForTesting()

            let legacyDefaults = try XCTUnwrap(defaults.dictionary(forKey: self.providerAPIKeysKey) as? [String: String])
            XCTAssertEqual(keychain.consolidatedKeys["openai"], "legacy-defaults-secret")
            XCTAssertEqual(legacyDefaults["openai"], "legacy-defaults-secret")
            XCTAssertFalse(defaults.bool(forKey: self.providerAPIKeyMigrationCompletedKey))
            XCTAssertTrue(keychain.removedLegacyProviderIDs.isEmpty)
        }
    }

    func testMigrateRecoveredLegacyKeychainOverridesFallbackDefaultsEcho() throws {
        try self.withIsolatedProviderState { store, defaults in
            let keychain = MockProviderKeychain()
            store.replaceKeychainForTesting(keychain)
            keychain.shouldThrowOnLegacyRead = true
            defaults.set(["anthropic": "stale-key"], forKey: self.providerAPIKeysKey)

            store.migrateProviderAPIKeysForTesting()

            XCTAssertEqual(keychain.consolidatedKeys["anthropic"], "stale-key")
            XCTAssertFalse(defaults.bool(forKey: self.providerAPIKeyMigrationCompletedKey))

            keychain.shouldThrowOnLegacyRead = false
            keychain.legacyEntries = ["anthropic": "fresh-key"]

            store.migrateProviderAPIKeysForTesting()

            XCTAssertEqual(keychain.consolidatedKeys["anthropic"], "fresh-key")
            XCTAssertNil(defaults.dictionary(forKey: self.providerAPIKeysKey))
            XCTAssertTrue(defaults.bool(forKey: self.providerAPIKeyMigrationCompletedKey))
            XCTAssertNil(keychain.legacyEntries["anthropic"])
            XCTAssertEqual(keychain.removedLegacyProviderIDs, [["anthropic"]])
        }
    }

    func testClearingKeyDuringFallbackWindowDoesNotResurrectItAfterRecovery() throws {
        try self.withIsolatedProviderState { store, defaults in
            let keychain = MockProviderKeychain()
            store.replaceKeychainForTesting(keychain)
            keychain.shouldThrowOnLegacyRead = true
            keychain.legacyEntries = ["anthropic": "stale-key"]
            defaults.set(["anthropic": "stale-key"], forKey: self.providerAPIKeysKey)

            store.migrateProviderAPIKeysForTesting()

            XCTAssertEqual(keychain.consolidatedKeys["anthropic"], "stale-key")
            XCTAssertFalse(defaults.bool(forKey: self.providerAPIKeyMigrationCompletedKey))

            keychain.shouldThrowOnLegacyRead = false
            _ = try store.saveProviderAPIKeys([:])

            XCTAssertNil(defaults.dictionary(forKey: self.providerAPIKeysKey))
            XCTAssertNil(keychain.legacyEntries["anthropic"])
            XCTAssertNil(keychain.consolidatedKeys["anthropic"])

            store.migrateProviderAPIKeysForTesting()

            XCTAssertNil(keychain.consolidatedKeys["anthropic"])
            XCTAssertNil(defaults.dictionary(forKey: self.providerAPIKeysKey))
        }
    }

    func testMigrateMarksCompleteAndRemovesDefaultsWhenLegacyCleanupFailsAfterSave() throws {
        try self.withIsolatedProviderState { store, defaults in
            let keychain = MockProviderKeychain()
            store.replaceKeychainForTesting(keychain)
            keychain.legacyEntries = ["anthropic": "legacy-keychain-secret"]
            keychain.shouldThrowOnLegacyRemoval = true
            defaults.set(["openai": "legacy-defaults-secret"], forKey: self.providerAPIKeysKey)

            store.migrateProviderAPIKeysForTesting()

            XCTAssertNil(defaults.dictionary(forKey: self.providerAPIKeysKey))
            XCTAssertEqual(keychain.consolidatedKeys["openai"], "legacy-defaults-secret")
            XCTAssertEqual(keychain.consolidatedKeys["anthropic"], "legacy-keychain-secret")
            XCTAssertTrue(defaults.bool(forKey: self.providerAPIKeyMigrationCompletedKey))
            XCTAssertEqual(keychain.legacyEntries["anthropic"], "legacy-keychain-secret")
            XCTAssertEqual(keychain.removedLegacyProviderIDs, [["anthropic"]])
        }
    }

    func testMigrateDoesNotLetStaleLegacyKeychainOverrideConsolidatedKey() throws {
        let keychain = MockProviderKeychain(
            consolidatedKeys: ["anthropic": "rotated-consolidated-secret"],
            legacyEntries: ["anthropic": "stale-legacy-secret"]
        )
        try self.withIsolatedProviderState { store, defaults in
            store.replaceKeychainForTesting(keychain)
            keychain.shouldThrowOnLegacyRemoval = true

            store.migrateProviderAPIKeysForTesting()

            XCTAssertEqual(keychain.consolidatedKeys["anthropic"], "rotated-consolidated-secret")
            XCTAssertEqual(keychain.legacyEntries["anthropic"], "stale-legacy-secret")
            XCTAssertTrue(defaults.bool(forKey: self.providerAPIKeyMigrationCompletedKey))
            XCTAssertEqual(keychain.removedLegacyProviderIDs, [["anthropic"]])
        }
    }

    func testMigratePrefersLegacyKeychainOverDefaultsWhenConsolidatedKeyIsMissing() throws {
        try self.withIsolatedProviderState { store, defaults in
            let keychain = MockProviderKeychain(legacyEntries: ["anthropic": "legacy-keychain-secret"])
            store.replaceKeychainForTesting(keychain)
            defaults.set(["anthropic": "stale-defaults-secret"], forKey: self.providerAPIKeysKey)

            store.migrateProviderAPIKeysForTesting()

            XCTAssertEqual(keychain.consolidatedKeys["anthropic"], "legacy-keychain-secret")
            XCTAssertNil(defaults.dictionary(forKey: self.providerAPIKeysKey))
            XCTAssertTrue(defaults.bool(forKey: self.providerAPIKeyMigrationCompletedKey))
            XCTAssertNil(keychain.legacyEntries["anthropic"])
            XCTAssertEqual(keychain.removedLegacyProviderIDs, [["anthropic"]])
        }
    }

    func testCompletedMigrationDoesNotResurrectDeletedKeyFromStaleLegacyKeychain() throws {
        let keychain = MockProviderKeychain(
            consolidatedKeys: ["anthropic": "legacy-keychain-secret"],
            legacyEntries: ["anthropic": "legacy-keychain-secret"]
        )
        try self.withIsolatedProviderState { store, defaults in
            store.replaceKeychainForTesting(keychain)
            keychain.shouldThrowOnLegacyRemoval = true

            store.migrateProviderAPIKeysForTesting()
            XCTAssertTrue(defaults.bool(forKey: self.providerAPIKeyMigrationCompletedKey))

            keychain.consolidatedKeys.removeValue(forKey: "anthropic")
            store.migrateProviderAPIKeysForTesting()

            XCTAssertNil(keychain.consolidatedKeys["anthropic"])
            XCTAssertEqual(keychain.legacyEntries["anthropic"], "legacy-keychain-secret")
            XCTAssertEqual(keychain.removedLegacyProviderIDs, [["anthropic"], ["anthropic"]])
        }
    }

    func testCompletedMigrationRemovesLegacyDefaultsWhenLegacyKeychainReadFails() throws {
        try self.withIsolatedProviderState { store, defaults in
            let keychain = MockProviderKeychain()
            store.replaceKeychainForTesting(keychain)
            keychain.shouldThrowOnLegacyRead = true
            defaults.set(true, forKey: self.providerAPIKeyMigrationCompletedKey)
            defaults.set(["openai": "legacy-defaults-secret"], forKey: self.providerAPIKeysKey)

            store.migrateProviderAPIKeysForTesting()

            XCTAssertNil(defaults.dictionary(forKey: self.providerAPIKeysKey))
            XCTAssertTrue(defaults.bool(forKey: self.providerAPIKeyMigrationCompletedKey))
            XCTAssertTrue(keychain.consolidatedKeys.isEmpty)
        }
    }

    private func withIsolatedProviderState(
        _ body: (SettingsStore, UserDefaults) throws -> Void
    ) throws {
        let defaults = InMemoryUserDefaults()

        let store = SettingsStore.makeForTesting(defaults: defaults, keychain: MockProviderKeychain())
        Self.retainedStores.append(store)
        try body(store, defaults)
    }
}

// swiftlint:disable discouraged_optional_collection
private final class InMemoryUserDefaults: UserDefaults {
    private var storage: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? {
        self.storage[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        self.storage[defaultName] = value
    }

    override func set(_ value: Int, forKey defaultName: String) {
        self.storage[defaultName] = value
    }

    override func set(_ value: Float, forKey defaultName: String) {
        self.storage[defaultName] = value
    }

    override func set(_ value: Double, forKey defaultName: String) {
        self.storage[defaultName] = value
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        self.storage[defaultName] = value
    }

    override func set(_ url: URL?, forKey defaultName: String) {
        self.storage[defaultName] = url
    }

    override func removeObject(forKey defaultName: String) {
        self.storage.removeValue(forKey: defaultName)
    }

    override func string(forKey defaultName: String) -> String? {
        self.storage[defaultName] as? String
    }

    override func array(forKey defaultName: String) -> [Any]? {
        self.storage[defaultName] as? [Any]
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        if let dictionary = self.storage[defaultName] as? [String: Any] {
            return dictionary
        }
        if let dictionary = self.storage[defaultName] as? [String: String] {
            return dictionary.mapValues { $0 as Any }
        }
        return nil
    }

    override func data(forKey defaultName: String) -> Data? {
        self.storage[defaultName] as? Data
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        self.storage[defaultName] as? [String]
    }

    override func integer(forKey defaultName: String) -> Int {
        self.storage[defaultName] as? Int ?? 0
    }

    override func float(forKey defaultName: String) -> Float {
        self.storage[defaultName] as? Float ?? 0
    }

    override func double(forKey defaultName: String) -> Double {
        self.storage[defaultName] as? Double ?? 0
    }

    override func bool(forKey defaultName: String) -> Bool {
        self.storage[defaultName] as? Bool ?? false
    }

    override func url(forKey defaultName: String) -> URL? {
        self.storage[defaultName] as? URL
    }

    override func dictionaryRepresentation() -> [String: Any] {
        self.storage
    }

    override func synchronize() -> Bool {
        true
    }
}
// swiftlint:enable discouraged_optional_collection

private final class MockProviderKeychain: ProviderKeychain {
    enum Failure: Error {
        case readLegacy
        case removeLegacy
        case write
    }

    var consolidatedKeys: [String: String]
    var legacyEntries: [String: String]
    var failingProviderIDs: Set<String> = []
    var shouldThrowOnWrite = false
    var shouldThrowOnLegacyRead = false
    var shouldThrowOnLegacyRemoval = false
    private(set) var removedLegacyProviderIDs: [[String]] = []

    init(consolidatedKeys: [String: String] = [:], legacyEntries: [String: String] = [:]) {
        self.consolidatedKeys = consolidatedKeys
        self.legacyEntries = legacyEntries
    }

    func storeKey(_ key: String, for providerID: String) throws {
        if self.shouldThrowOnWrite || self.failingProviderIDs.contains(providerID) {
            throw Failure.write
        }
        self.consolidatedKeys[providerID] = key
    }

    func storeAllKeys(_ values: [String: String]) throws {
        if self.shouldThrowOnWrite {
            throw Failure.write
        }
        self.consolidatedKeys = values
    }

    func fetchAllKeys() throws -> [String: String] {
        self.consolidatedKeys
    }

    func legacyProviderEntries() throws -> [String: String] {
        if self.shouldThrowOnLegacyRead {
            throw Failure.readLegacy
        }
        return self.legacyEntries
    }

    func removeLegacyEntries(providerIDs: [String]) throws {
        self.removedLegacyProviderIDs.append(providerIDs)
        if self.shouldThrowOnLegacyRemoval {
            throw Failure.removeLegacy
        }
        for providerID in providerIDs {
            self.legacyEntries.removeValue(forKey: providerID)
        }
    }
}
