@testable import FluidVoice_Debug
import CryptoKit
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

    private func catalogModels(version: String = "1.2.0") -> [[String: Any]] {
        [ParakeetSpeechModelCatalog.mini, ParakeetSpeechModelCatalog.pico].map {
            [
                "variant": $0.variant.rawValue, "version": version,
                "url": "https://models.fluidvoice.app/parakeet/fluid-\($0.variant.rawValue)/\(version)/\($0.folderName).tar",
                "sha256": String(repeating: $0.variant == .mini ? "a" : "b", count: 64),
                "byteCount": $0.expectedDownloadBytes,
            ]
        }
    }

    private func signedCatalog(
        key: Curve25519.Signing.PrivateKey,
        models: [[String: Any]],
        payloadSchema: Int = 1,
        envelopeSchema: Int = 1
    ) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["schemaVersion": payloadSchema, "models": models])
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": envelopeSchema, "payload": payload.base64EncodedString(),
            "signature": key.signature(for: payload).base64EncodedString(),
        ])
    }

    func testSignedCatalogChangesOnlyTrustedReleaseMetadata() throws {
        let key = Curve25519.Signing.PrivateKey()
        let descriptors = try CompactSpeechModelReleaseCatalog.validate(
            self.signedCatalog(key: key, models: self.catalogModels()), publicKey: key.publicKey.rawRepresentation
        )
        XCTAssertEqual(descriptors.count, 2)
        for original in [ParakeetSpeechModelCatalog.mini, ParakeetSpeechModelCatalog.pico] {
            let release = try XCTUnwrap(descriptors[original.variant])
            XCTAssertNotEqual(release.archiveSHA256, original.archiveSHA256)
            XCTAssertEqual(release.expectedDownloadBytes, original.expectedDownloadBytes)
            XCTAssertEqual(release.folderName, original.folderName)
            XCTAssertEqual(release.requiredModelNames, original.requiredModelNames)
            XCTAssertEqual(release.vocabularyFile, original.vocabularyFile)
            XCTAssertEqual(release.displayName, original.displayName)
            XCTAssertEqual(release.cardDescription, original.cardDescription)
            XCTAssertEqual(release.languageSupport, original.languageSupport)
            XCTAssertEqual(release.supportedLanguageCodes, ["en"])
        }
        XCTAssertEqual(Data(base64Encoded: CompactSpeechModelReleaseCatalog.publicKeyBase64)?.count, 32)
    }

    func testCatalogRejectsUnsignedTamperedUnknownAndUnsafeReleases() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = try self.signedCatalog(key: key, models: self.catalogModels())
        XCTAssertThrowsError(try CompactSpeechModelReleaseCatalog.validate(data, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        XCTAssertThrowsError(try CompactSpeechModelReleaseCatalog.validate(Data(repeating: 0, count: 16_385), publicKey: key.publicKey.rawRepresentation))
        for schema in [0, 2] {
            XCTAssertThrowsError(try CompactSpeechModelReleaseCatalog.validate(
                self.signedCatalog(key: key, models: self.catalogModels(), payloadSchema: schema), publicKey: key.publicKey.rawRepresentation
            ))
            XCTAssertThrowsError(try CompactSpeechModelReleaseCatalog.validate(
                self.signedCatalog(key: key, models: self.catalogModels(), envelopeSchema: schema), publicKey: key.publicKey.rawRepresentation
            ))
        }
        var cases: [[[String: Any]]] = []
        let normal = self.catalogModels()
        cases.append([normal[0]])
        cases.append([normal[0], normal[0]])
        cases.append(self.catalogModels(version: "1.0.0"))
        let invalidFields: [(String, Any)] = [
            ("variant", "v3"), ("version", "../1.2.0"), ("version", "01.2.0"),
            ("url", "http://models.fluidvoice.app/parakeet/fluid-mini/1.2.0/fluid-parakeet-mini-coreml.tar"),
            ("url", "https://elsewhere.invalid/parakeet/fluid-mini/1.2.0/fluid-parakeet-mini-coreml.tar"),
            ("url", "https://models.fluidvoice.app/parakeet/fluid-mini/1.2.0/arbitrary.tar"),
            ("sha256", String(repeating: "A", count: 64)), ("sha256", "short"),
            ("byteCount", 0), ("byteCount", 600_000_001),
        ]
        for (field, value) in invalidFields {
            var changed = normal
            changed[0][field] = value
            cases.append(changed)
        }
        for models in cases {
            XCTAssertThrowsError(try CompactSpeechModelReleaseCatalog.validate(
                self.signedCatalog(key: key, models: models), publicKey: key.publicKey.rawRepresentation
            ))
        }
        var tampered = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        tampered["payload"] = Data("{}".utf8).base64EncodedString()
        XCTAssertThrowsError(try CompactSpeechModelReleaseCatalog.validate(
            JSONSerialization.data(withJSONObject: tampered), publicKey: key.publicKey.rawRepresentation
        ))
    }

    func testCatalogCoalescesChecksAndPreservesCachedReleaseAfterFailure() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("catalog.json")
        try self.signedCatalog(key: key, models: self.catalogModels()).write(to: cache)
        let gate = CompactCatalogFetchGate()
        let catalog = CompactSpeechModelReleaseCatalog(publicKey: key.publicKey.rawRepresentation, cacheURL: cache, fetch: { try await gate.fetch() })
        let first = Task { await catalog.refreshIfNeeded() }
        try await self.waitUntil { await gate.calls == 1 }
        let second = Task { await catalog.refreshIfNeeded() }
        XCTAssertEqual(catalog.descriptor(for: .mini).archiveSHA256, String(repeating: "a", count: 64))
        let cached = catalog.snapshot
        await gate.complete(.success(try self.signedCatalog(key: key, models: self.catalogModels(version: "1.1.1"))))
        await first.value
        await second.value
        XCTAssertEqual(catalog.snapshot, cached)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        await catalog.refreshIfNeeded()
        let stillOne = await gate.calls
        XCTAssertEqual(stillOne, 1, "Appearance bursts must not repeat a failed check")
        let retry = Task { await catalog.refreshIfNeeded(force: true) }
        try await self.waitUntil { await gate.calls == 2 }
        await gate.complete(.success(try self.signedCatalog(key: key, models: self.catalogModels(version: "1.3.0"))))
        await retry.value
        XCTAssertTrue(catalog.descriptor(for: .pico).archiveURL?.path.contains("/1.3.0/") == true)
        XCTAssertGreaterThan(catalog.revision, cached.revision)
        let latest = catalog.snapshot
        let older = Task { await catalog.refreshIfNeeded(force: true) }
        try await self.waitUntil { await gate.calls == 3 }
        var replay = self.catalogModels(version: "1.3.0")
        replay[1] = self.catalogModels(version: "1.2.0")[1]
        await gate.complete(.success(try self.signedCatalog(key: key, models: replay)))
        await older.value
        XCTAssertEqual(catalog.snapshot, latest, "One older variant must reject the whole signed release atomically")
        let retained = try CompactSpeechModelReleaseCatalog.validate(Data(contentsOf: cache), publicKey: key.publicKey.rawRepresentation)
        XCTAssertTrue(retained[.pico]?.archiveURL?.path.contains("/1.3.0/") == true, "A replay cannot overwrite the higher signed cache")
        XCTAssertEqual(catalog.descriptor(for: .v3), ParakeetSpeechModelCatalog.v3)
        XCTAssertNil(catalog.descriptor(for: SettingsStore.SpeechModel.appleSpeech))
    }

    func testOptionalPublishedCatalogFixtureUsesEmbeddedProductionKey() throws {
        guard let path = ProcessInfo.processInfo.environment["FLUID_COMPACT_MODEL_CATALOG_FIXTURE"] else {
            throw XCTSkip("Set FLUID_COMPACT_MODEL_CATALOG_FIXTURE to the externally generated signed envelope")
        }
        let releases = try CompactSpeechModelReleaseCatalog.validate(
            Data(contentsOf: URL(fileURLWithPath: path)),
            publicKey: try XCTUnwrap(Data(base64Encoded: CompactSpeechModelReleaseCatalog.publicKeyBase64))
        )
        XCTAssertEqual(Set(releases.keys), [.mini, .pico])
        XCTAssertEqual(releases[.mini]?.modelID, ParakeetSpeechModelCatalog.mini.modelID)
        XCTAssertEqual(releases[.pico]?.modelID, ParakeetSpeechModelCatalog.pico.modelID)
    }

    func testOfflineInvalidCatalogKeepsBuiltInModelsUsable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("catalog.json")
        try Data("{\"schemaVersion\":1,\"models\":[]}".utf8).write(to: cache)
        let catalog = CompactSpeechModelReleaseCatalog(cacheURL: cache, fetch: { throw URLError(.timedOut) })
        await catalog.refreshIfNeeded()
        XCTAssertEqual(catalog.descriptor(for: .mini), ParakeetSpeechModelCatalog.mini)
        XCTAssertEqual(catalog.descriptor(for: .pico), ParakeetSpeechModelCatalog.pico)
        XCTAssertEqual(catalog.revision, 0)
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
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName)), Data(oldHash.utf8), "Checking cannot replace the installed checkpoint")
        try Data((descriptor.archiveSHA256 ?? "").utf8).write(to: directory.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName))
        snapshot.refresh()
        try await self.waitUntil { snapshot.state == .ready }
        XCTAssertEqual(snapshot.installedIDs, [descriptor.modelID])
        XCTAssertTrue(snapshot.updateAvailableIDs.isEmpty)
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
