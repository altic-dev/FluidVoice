import CryptoKit
import Darwin
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
private final class InstallationCapture {
    var modelID = "first"
}

private actor InstallationScanGate {
    private(set) var calls = 0
    private(set) var observedIDs: [[String]] = []
    private var continuations: [CheckedContinuation<Set<String>, Error>] = []

    func scan(_ probes: [SpeechModelInstallationSnapshot.Probe]) async throws -> Set<String> {
        self.calls += 1
        self.observedIDs.append(probes.map(\.modelID))
        return try await withCheckedThrowingContinuation { self.continuations.append($0) }
    }

    func complete(_ result: Result<Set<String>, Error>) {
        self.continuations.removeFirst().resume(with: result)
    }
}

private actor CompactCatalogFetchGate {
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<Data, Error>] = []

    func fetch() async throws -> Data {
        self.calls += 1
        return try await withCheckedThrowingContinuation { self.waiting.append($0) }
    }

    func complete(_ result: Result<Data, Error>) {
        self.waiting.removeFirst().resume(with: result)
    }
}

private final nonisolated class CatalogTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)

    func now() -> Date { self.lock.withLock { self.date } }
    func advance(_ seconds: TimeInterval) { self.lock.withLock { self.date.addTimeInterval(seconds) } }
}

@MainActor
final class SpeechModelInstallationSnapshotTests: XCTestCase {
    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()), Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let completed = await condition()
        XCTAssertTrue(completed, "Snapshot operation must finish within the test deadline")
    }

    private struct FeedCase: Decodable {
        let file: String
        let lastSequence: Int
        let verdict: String
    }

    private struct PickCase: Decodable {
        let file: String
        let model: String
        let platform: String
        let build: Int
        let format: Int
        let release: String?
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ModelRelease")
    }

    private func fixture<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: self.fixtures.appendingPathComponent(path)))
    }

    private func fixtureKey() throws -> String {
        try XCTUnwrap(self.fixture([String: String].self, "test_key.json")["publicKey"])
    }

    private func releaseModels(release: String = "1.2.0", format: Int = 1, minBuild: Int = 27) -> [String: [String: [[String: Any]]]] {
        var result: [String: [String: [[String: Any]]]] = [:]
        for descriptor in [ParakeetSpeechModelCatalog.mini, ParakeetSpeechModelCatalog.pico] {
            result[descriptor.variant.rawValue] = ["macos": [[
                "release": release,
                "url": "https://models.fluidvoice.app/parakeet/fluid-\(descriptor.variant.rawValue)/\(release)/\(descriptor.folderName).tar",
                "sha256": String(repeating: descriptor.variant == .mini ? "a" : "b", count: 64),
                "manifestSHA256": String(repeating: descriptor.variant == .mini ? "c" : "d", count: 64),
                "bytes": descriptor.expectedDownloadBytes,
                "format": format,
                "minBuild": minBuild,
            ]]]
        }
        return result
    }

    private func signedFeed(
        key: Curve25519.Signing.PrivateKey,
        sequence: Int,
        models: [String: [String: [[String: Any]]]]
    ) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["schema": 1, "sequence": sequence, "models": models])
        return try JSONSerialization.data(withJSONObject: [
            "payload": payload.base64EncodedString(), "signature": key.signature(for: payload).base64EncodedString(),
        ])
    }

    func testEveryCanonicalFeedFixtureGetsTheSameVerdict() throws {
        let key = try self.fixtureKey()
        let cases = try self.fixture([FeedCase].self, "feeds/expected.json")
        XCTAssertEqual(cases.count, 40)
        for feed in cases {
            let data = try Data(contentsOf: self.fixtures.appendingPathComponent("feeds/\(feed.file)"))
            let verdict: String
            do {
                _ = try SpeechModelFeed.verified(envelope: data, publicKeys: [key], lastSequence: feed.lastSequence)
                verdict = "ok"
            } catch {
                verdict = (error as? SpeechModelFeed.Rejection)?.rawValue ?? String(describing: error)
            }
            XCTAssertEqual(verdict, feed.verdict, feed.file)
        }
    }

    func testCanonicalReleasePicksAndProductionKeysMatchIPhone() throws {
        let key = try self.fixtureKey()
        let picks = try self.fixture([PickCase].self, "feeds/picks.json")
        XCTAssertEqual(picks.count, 7)
        for pick in picks {
            let data = try Data(contentsOf: self.fixtures.appendingPathComponent("feeds/\(pick.file)"))
            let payload = try SpeechModelFeed.verified(envelope: data, publicKeys: [key], lastSequence: 0)
            XCTAssertEqual(SpeechModelFeed.entry(in: payload, model: pick.model, platform: pick.platform, build: pick.build, supportedFormat: pick.format)?.release, pick.release)
        }
        let keys = try self.fixture([String: String].self, "public_keys.json")
        XCTAssertEqual(CompactSpeechModelReleaseCatalog.publicKeys, try [XCTUnwrap(keys["main"]), XCTUnwrap(keys["spare"])])
        let data = try Data(contentsOf: self.fixtures.appendingPathComponent("feeds/good.json"))
        XCTAssertThrowsError(try SpeechModelFeed.verified(envelope: data, publicKeys: CompactSpeechModelReleaseCatalog.publicKeys, lastSequence: 0)) {
            XCTAssertEqual($0 as? SpeechModelFeed.Rejection, .badSignature)
        }
        XCTAssertEqual(CompactSpeechModelReleaseCatalog.manifestURL.absoluteString, "https://models.fluidvoice.app/feed/v1/speech-models.json")
        XCTAssertEqual(CompactSpeechModelReleaseCatalog.maximumManifestBytes, 64 * 1024)
    }

    func testMacReleaseChangesOnlyTrustedMetadataAndNeverPicksIOS() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = try SpeechModelFeed.verified(
            envelope: self.signedFeed(key: key, sequence: 5, models: self.releaseModels()),
            publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()],
            lastSequence: 0
        )
        let descriptors = CompactSpeechModelReleaseCatalog.descriptors(in: payload, build: 27)
        for original in [ParakeetSpeechModelCatalog.mini, ParakeetSpeechModelCatalog.pico] {
            let release = try XCTUnwrap(descriptors[original.variant])
            XCTAssertNotEqual(release.archiveSHA256, original.archiveSHA256)
            XCTAssertNotEqual(release.manifestSHA256, original.manifestSHA256)
            XCTAssertEqual(release.expectedDownloadBytes, original.expectedDownloadBytes)
            XCTAssertEqual(release.folderName, original.folderName)
            XCTAssertEqual(release.requiredModelNames, original.requiredModelNames)
            XCTAssertEqual(release.vocabularyFile, original.vocabularyFile)
            XCTAssertEqual(release.displayName, original.displayName)
            XCTAssertEqual(release.cardDescription, original.cardDescription)
            XCTAssertEqual(release.supportedLanguageCodes, ["en"])
        }
        let builtins: [ParakeetSpeechModelCatalog.Variant: ParakeetSpeechModelCatalog.Descriptor] = [.mini: ParakeetSpeechModelCatalog.mini, .pico: ParakeetSpeechModelCatalog.pico]
        XCTAssertEqual(CompactSpeechModelReleaseCatalog.descriptors(in: payload, build: 26), builtins)
        let iosOnly: [String: [String: [[String: Any]]]] = [
            "mini": ["ios": self.releaseModels()["mini"]?["macos"] ?? [], "macos": []],
            "pico": ["ios": [], "macos": []],
        ]
        let incompatible = [self.releaseModels(format: 2), self.releaseModels(minBuild: 28), iosOnly]
        for models in incompatible {
            let fallback = try SpeechModelFeed.verified(
                envelope: self.signedFeed(key: key, sequence: 6, models: models),
                publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()],
                lastSequence: 5
            )
            XCTAssertEqual(CompactSpeechModelReleaseCatalog.descriptors(in: fallback, build: 27), builtins)
        }
    }

    func testCatalogCoalescesAndAcceptsRollbackOnlyUnderNewSequence() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("feed.json")
        try self.signedFeed(key: key, sequence: 5, models: self.releaseModels()).write(to: cache)
        let gate = CompactCatalogFetchGate()
        let catalog = CompactSpeechModelReleaseCatalog(publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()], cacheURL: cache, build: 27, fetch: { try await gate.fetch() })
        let first = Task { await catalog.refreshIfNeeded() }
        try await self.waitUntil { await gate.calls == 1 }
        let second = Task { await catalog.refreshIfNeeded() }
        XCTAssertEqual(catalog.snapshot.sequence, 5)
        let cached = catalog.snapshot
        try await gate.complete(.success(self.signedFeed(key: key, sequence: 4, models: self.releaseModels(release: "1.3.0"))))
        await first.value
        await second.value
        XCTAssertEqual(catalog.snapshot, cached)
        await catalog.refreshIfNeeded()
        let calls = await gate.calls
        XCTAssertEqual(calls, 1, "Failed checks retry hourly, not on every appearance")
        let retry = Task { await catalog.refreshIfNeeded(force: true) }
        try await self.waitUntil { await gate.calls == 2 }
        try await gate.complete(.success(self.signedFeed(key: key, sequence: 6, models: self.releaseModels(release: "1.0.0"))))
        await retry.value
        XCTAssertEqual(catalog.snapshot.sequence, 6)
        XCTAssertTrue(catalog.descriptor(for: .pico).archiveURL?.path.contains("/1.0.0/") == true, "Intentional rollback is allowed under a higher signed sequence")
        let retained = try SpeechModelFeed.verified(envelope: Data(contentsOf: cache), publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()], lastSequence: 6)
        XCTAssertEqual(retained.sequence, 6)
        XCTAssertEqual(catalog.descriptor(for: .v3), ParakeetSpeechModelCatalog.v3)
        XCTAssertNil(catalog.descriptor(for: SettingsStore.SpeechModel.appleSpeech))
        let reopened = CompactSpeechModelReleaseCatalog(
            publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()],
            cacheURL: cache,
            build: 27,
            fetch: { XCTFail("Persisted successful checks must not refetch before one day"); throw URLError(.timedOut) }
        )
        await reopened.refreshIfNeeded()
        XCTAssertEqual(reopened.snapshot.sequence, 6)
        XCTAssertEqual(reopened.descriptor(for: .mini), catalog.descriptor(for: .mini))
    }

    func testRejectionsPersistAreBoundedAndCannotChangeModelSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("feed.json")
        let catalog = CompactSpeechModelReleaseCatalog(cacheURL: cache, fetch: { throw URLError(.timedOut) })
        let selection = SettingsStore.shared.selectedSpeechModel
        let hash = try XCTUnwrap(ParakeetSpeechModelCatalog.mini.manifestSHA256)
        await catalog.reject(manifestSHA256: hash)
        let revision = catalog.revision
        await catalog.reject(manifestSHA256: hash)
        await catalog.reject(manifestSHA256: "invalid")
        XCTAssertEqual(catalog.revision, revision)
        XCTAssertEqual(catalog.snapshot.rejectedManifestHashes, [hash])
        XCTAssertEqual(catalog.descriptor(for: .mini), ParakeetSpeechModelCatalog.mini)
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selection)
        let reopened = CompactSpeechModelReleaseCatalog(cacheURL: cache, fetch: { throw URLError(.timedOut) })
        await reopened.refreshIfNeeded()
        XCTAssertTrue(reopened.snapshot.rejectedManifestHashes.contains(hash))
        let bounded = CompactSpeechModelReleaseCatalog(cacheURL: nil, fetch: { throw URLError(.timedOut) })
        for number in 0..<70 {
            await bounded.reject(manifestSHA256: String(format: "%064x", number))
        }
        XCTAssertEqual(bounded.snapshot.rejectedManifestHashes.count, 64)
        XCTAssertFalse(bounded.snapshot.rejectedManifestHashes.contains(String(format: "%064x", 0)))
        XCTAssertTrue(bounded.snapshot.rejectedManifestHashes.contains(String(format: "%064x", 69)))
    }

    func testCompetingCatalogsPreserveHighestSignedSequenceAndMergeRejections() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let keys = [key.publicKey.rawRepresentation.base64EncodedString()]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("feed.json")
        try self.signedFeed(key: key, sequence: 1, models: self.releaseModels()).write(to: cache)
        let earlierGate = CompactCatalogFetchGate()
        let laterGate = CompactCatalogFetchGate()
        let earlier = CompactSpeechModelReleaseCatalog(publicKeys: keys, cacheURL: cache, build: 27, fetch: { try await earlierGate.fetch() })
        let later = CompactSpeechModelReleaseCatalog(publicKeys: keys, cacheURL: cache, build: 27, fetch: { try await laterGate.fetch() })
        let earlierCheck = Task { await earlier.refreshIfNeeded(force: true) }
        try await self.waitUntil { await earlierGate.calls == 1 }
        let laterCheck = Task { await later.refreshIfNeeded(force: true) }
        try await self.waitUntil { await laterGate.calls == 1 }
        try await laterGate.complete(.success(self.signedFeed(key: key, sequence: 3, models: self.releaseModels(release: "1.3.0"))))
        await laterCheck.value
        try await earlierGate.complete(.success(self.signedFeed(key: key, sequence: 2, models: self.releaseModels(release: "1.2.0"))))
        await earlierCheck.value
        XCTAssertEqual(earlier.snapshot.sequence, 3, "The stale writer must adopt the higher on-disk signed feed")
        XCTAssertEqual(earlier.descriptor(for: .mini), later.descriptor(for: .mini))
        XCTAssertEqual(try SpeechModelFeed.verified(envelope: Data(contentsOf: cache), publicKeys: keys, lastSequence: 3).sequence, 3)
        let lock = open(cache.appendingPathExtension("lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(lock, 0)
        guard lock >= 0 else { return }
        defer { Darwin.close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        let firstHash = String(repeating: "e", count: 64)
        let secondHash = String(repeating: "f", count: 64)
        let firstReject = Task { await earlier.reject(manifestSHA256: firstHash) }
        let secondReject = Task { await later.reject(manifestSHA256: secondHash) }
        try await self.waitUntil {
            earlier.snapshot.rejectedManifestHashes.contains(firstHash) && later.snapshot.rejectedManifestHashes.contains(secondHash)
        }
        await firstReject.value
        await secondReject.value
        XCTAssertEqual(flock(lock, LOCK_UN), 0)
        // Both bounded busy retries exhausted while the lock was held. The next
        // duplicate rejection event must flush the one retained pending state.
        await earlier.reject(manifestSHA256: firstHash)
        await later.reject(manifestSHA256: secondHash)
        let reopened = CompactSpeechModelReleaseCatalog(publicKeys: keys, cacheURL: cache, build: 27, fetch: { throw URLError(.timedOut) })
        await reopened.refreshIfNeeded()
        XCTAssertEqual(reopened.snapshot.sequence, 3)
        XCTAssertEqual(reopened.snapshot.rejectedManifestHashes, [firstHash, secondHash], "Overlapping processes must retain both failures after restart")
        XCTAssertEqual(CompactSpeechModelReleaseCatalog.cacheFolderName(bundleIdentifier: "com.FluidApp.app", isDebug: false), "FluidVoice")
        XCTAssertEqual(CompactSpeechModelReleaseCatalog.cacheFolderName(bundleIdentifier: "com.FluidApp.app.debug", isDebug: true), "FluidVoice/com.FluidApp.app.debug")
    }

    func testSuccessfulChecksWaitOneDayAndFailedChecksRetryHourly() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let clock = CatalogTestClock()
        let gate = CompactCatalogFetchGate()
        let catalog = CompactSpeechModelReleaseCatalog(
            publicKeys: [key.publicKey.rawRepresentation.base64EncodedString()],
            cacheURL: nil,
            build: 27,
            now: { clock.now() },
            fetch: { try await gate.fetch() }
        )
        let first = Task { await catalog.refreshIfNeeded() }
        try await self.waitUntil { await gate.calls == 1 }
        try await gate.complete(.success(self.signedFeed(key: key, sequence: 1, models: self.releaseModels())))
        await first.value
        clock.advance(86_399)
        await catalog.refreshIfNeeded()
        let beforeDay = await gate.calls
        XCTAssertEqual(beforeDay, 1)
        clock.advance(1)
        let failure = Task { await catalog.refreshIfNeeded() }
        try await self.waitUntil { await gate.calls == 2 }
        await gate.complete(.failure(URLError(.timedOut)))
        await failure.value
        let lastGood = catalog.snapshot
        clock.advance(3599)
        await catalog.refreshIfNeeded()
        let beforeHour = await gate.calls
        XCTAssertEqual(beforeHour, 2)
        clock.advance(1)
        let retry = Task { await catalog.refreshIfNeeded() }
        try await self.waitUntil { await gate.calls == 3 }
        await gate.complete(.failure(URLError(.timedOut)))
        await retry.value
        XCTAssertEqual(catalog.snapshot, lastGood)
    }

    func testOfflineInvalidFeedKeepsBuiltInModelsUsable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("feed.json")
        try Data("{\"schema\":1,\"models\":[]}".utf8).write(to: cache)
        let catalog = CompactSpeechModelReleaseCatalog(cacheURL: cache, fetch: { throw URLError(.timedOut) })
        await catalog.refreshIfNeeded()
        XCTAssertEqual(catalog.descriptor(for: .mini), ParakeetSpeechModelCatalog.mini)
        XCTAssertEqual(catalog.descriptor(for: .pico), ParakeetSpeechModelCatalog.pico)
        XCTAssertEqual(catalog.snapshot.sequence, 0)
    }

    func testOldCompleteCompactInstallIsUsableAndHasUpdateWithActualProfileHash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = ParakeetSpeechModelCatalog.mini
        let directory = descriptor.cacheDirectory(in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in descriptor.requiredModelNames {
            let artifact = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: artifact.appendingPathComponent("weights", isDirectory: true), withIntermediateDirectories: true)
            for file in ["coremldata.bin", "metadata.json", "weights/weight.bin"] {
                try Data([1]).write(to: artifact.appendingPathComponent(file))
            }
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent(descriptor.vocabularyFile))
        let oldHash = String(repeating: "c", count: 64)
        try Data(oldHash.utf8).write(to: directory.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName))
        let probes = [SpeechModelInstallationSnapshot.Probe(modelID: descriptor.modelID, kind: .parakeet(descriptor))]
        let snapshot = SpeechModelInstallationSnapshot(capture: { probes }, resultScanner: {
            try await SpeechModelInstallationSnapshot.scanResult($0, cachesDirectory: root, modelsDirectory: root)
        })
        snapshot.refresh()
        try await self.waitUntil { snapshot.state == .ready }
        XCTAssertEqual(snapshot.installedIDs, [descriptor.modelID])
        XCTAssertEqual(snapshot.updateAvailableIDs, [descriptor.modelID])
        XCTAssertEqual(snapshot.installedArchiveHashes, [descriptor.modelID: oldHash])
        XCTAssertEqual(snapshot.installedDescriptor(for: .fluidParakeetMini)?.pronunciationModelKey, "\(descriptor.modelID):sha256:\(oldHash)")
        XCTAssertNil(snapshot.installedDescriptor(for: .appleSpeech))
        XCTAssertEqual(snapshot.latestDescriptors[descriptor.modelID], descriptor)
        XCTAssertFalse(descriptor.artifactsAreComplete(at: directory), "Old complete weights cannot count as latest")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName)),
            Data(oldHash.utf8),
            "Checking cannot replace the installed checkpoint"
        )
        try Data((descriptor.archiveSHA256 ?? "").utf8).write(to: directory.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName))
        snapshot.refresh()
        try await self.waitUntil { snapshot.state == .ready }
        XCTAssertEqual(snapshot.installedIDs, [descriptor.modelID])
        XCTAssertTrue(snapshot.updateAvailableIDs.isEmpty)

        let manifestBytes = Data("{\"schema\":1}".utf8)
        let manifestHash = SHA256.hash(data: manifestBytes).map { String(format: "%02x", $0) }.joined()
        let manifestFile = directory.appendingPathComponent("manifest.json")
        try manifestBytes.write(to: manifestFile)
        let sameManifest = descriptor.replacingArchive(url: descriptor.archiveURL, sha256: oldHash, manifestSHA256: manifestHash)
        let matching = try await SpeechModelInstallationSnapshot.scanResult(
            [.init(modelID: descriptor.modelID, kind: .parakeet(sameManifest))], cachesDirectory: root, modelsDirectory: root
        )
        XCTAssertEqual(matching.installedManifestHashes, [descriptor.modelID: manifestHash])
        XCTAssertTrue(matching.updateAvailableIDs.isEmpty, "Manifest identity wins even when archive packaging differs")
        let newManifest = String(repeating: "d", count: 64)
        let update = sameManifest.replacingArchive(url: descriptor.archiveURL, sha256: oldHash, manifestSHA256: newManifest)
        let differing = try await SpeechModelInstallationSnapshot.scanResult(
            [.init(modelID: descriptor.modelID, kind: .parakeet(update))], cachesDirectory: root, modelsDirectory: root
        )
        XCTAssertEqual(differing.updateAvailableIDs, [descriptor.modelID])
        let rejected = try await SpeechModelInstallationSnapshot.scanResult(
            [.init(modelID: descriptor.modelID, kind: .parakeet(update), rejectedManifestHashes: [newManifest])], cachesDirectory: root, modelsDirectory: root
        )
        XCTAssertEqual(rejected.installedIDs, [descriptor.modelID])
        XCTAssertTrue(rejected.updateAvailableIDs.isEmpty, "A failed runtime release must not nag the user again")
        XCTAssertEqual(rejected.installedArchiveHashes, matching.installedArchiveHashes, "Feed identity must not change pronunciation checkpoint identity")
        XCTAssertEqual(try Data(contentsOf: manifestFile), manifestBytes, "Checking and rejecting cannot change installed files")
    }

    func testRapidRefreshScansOnlyInitialAndLatestSnapshotAndRejectsOldResult() async throws {
        let gate = InstallationScanGate()
        let capture = InstallationCapture()
        let snapshot = SpeechModelInstallationSnapshot(capture: {
            [.init(modelID: capture.modelID, kind: .builtIn)]
        }, scanner: { try await gate.scan($0) })
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 1 }
        capture.modelID = "middle"
        snapshot.refresh()
        capture.modelID = "latest"
        snapshot.refresh()
        await gate.complete(.success(["first"]))
        try await self.waitUntil { await gate.calls == 2 }
        XCTAssertEqual(snapshot.state, .checking)
        XCTAssertTrue(snapshot.installedIDs.isEmpty, "An outdated scan must not publish")
        XCTAssertFalse(snapshot.canUseModelActions)
        await gate.complete(.success(["latest"]))
        try await self.waitUntil { snapshot.state == .ready }
        XCTAssertEqual(snapshot.installedIDs, ["latest"])
        let observed = await gate.observedIDs
        XCTAssertEqual(observed, [["first"], ["latest"]])
        XCTAssertTrue(snapshot.canUseModelActions)
    }

    func testCancelDrainsOldWorkerBeforeRetryAndNeverPublishesCanceledResult() async throws {
        let gate = InstallationScanGate()
        let snapshot = SpeechModelInstallationSnapshot(capture: { [] }, scanner: { try await gate.scan($0) })
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 1 }
        snapshot.cancel()
        XCTAssertEqual(snapshot.state, .failed)
        snapshot.refresh()
        let beforeDrain = await gate.calls
        XCTAssertEqual(beforeDrain, 1, "A retry must not start overlapping filesystem work")
        await gate.complete(.success(["canceled"]))
        try await self.waitUntil { await gate.calls == 2 }
        XCTAssertFalse(snapshot.isInstalled(modelID: "canceled"))
        await gate.complete(.success(["retry"]))
        try await self.waitUntil { snapshot.state == .ready }
        XCTAssertEqual(snapshot.installedIDs, ["retry"])
    }

    func testFailureClearsOldIDsAndAllowsSuccessfulRetry() async throws {
        let gate = InstallationScanGate()
        let snapshot = SpeechModelInstallationSnapshot(capture: { [] }, scanner: { try await gate.scan($0) })
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 1 }
        await gate.complete(.success(["old"]))
        try await self.waitUntil { snapshot.state == .ready }
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 2 }
        await gate.complete(.failure(CocoaError(.fileReadNoSuchFile)))
        try await self.waitUntil { snapshot.state == .failed }
        XCTAssertTrue(snapshot.installedIDs.isEmpty)
        XCTAssertFalse(snapshot.canUseModelActions)
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 3 }
        await gate.complete(.success(["new"]))
        try await self.waitUntil { snapshot.state == .ready }
        XCTAssertEqual(snapshot.installedIDs, ["new"])
    }

    func testStalledIOHasBoundedFailureAndRejectsLateSuccess() async throws {
        let gate = InstallationScanGate()
        let snapshot = SpeechModelInstallationSnapshot(timeoutNanoseconds: 20_000_000, capture: { [] }, scanner: { try await gate.scan($0) })
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 1 }
        try await self.waitUntil { snapshot.state == .failed }
        XCTAssertTrue(snapshot.installedIDs.isEmpty)
        XCTAssertFalse(snapshot.canUseModelActions)
        await gate.complete(.success(["late"]))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertFalse(snapshot.isInstalled(modelID: "late"))
    }

    func testCompletedDeadlineCannotCancelLaterRefresh() async throws {
        let gate = InstallationScanGate()
        let snapshot = SpeechModelInstallationSnapshot(timeoutNanoseconds: 100_000_000, capture: { [] }, scanner: { try await gate.scan($0) })
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 1 }
        await gate.complete(.success(["one"]))
        try await self.waitUntil { snapshot.state == .ready }
        try await Task.sleep(for: .milliseconds(70))
        snapshot.refresh()
        try await self.waitUntil { await gate.calls == 2 }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(snapshot.state, .checking, "The first canceled deadline must not cancel the new request")
        await gate.complete(.success(["two"]))
        try await self.waitUntil { snapshot.state == .ready }
    }

    func testOffMainScannerChecksExactWhisperSizeAndHasNoStatefulSideEffects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = root.appendingPathComponent("WhisperModels", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let file = models.appendingPathComponent("fixture.bin")
        try Data([1, 2, 3]).write(to: file)
        let selection = SettingsStore.shared.selectedSpeechModel
        let ids = try await SpeechModelInstallationSnapshot.scan(
            [
                .init(modelID: "bundled", kind: .builtIn),
                .init(modelID: "exact", kind: .whisper(file: "fixture.bin", expectedBytes: 3)),
                .init(modelID: "wrong-size", kind: .whisper(file: "fixture.bin", expectedBytes: 4)),
                .init(modelID: "missing", kind: .whisper(file: "missing.bin", expectedBytes: 3)),
                .init(modelID: "unsupported", kind: .unavailable),
            ],
            cachesDirectory: root,
            modelsDirectory: root
        )
        XCTAssertEqual(ids, ["bundled", "exact"])
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selection)
    }
}
