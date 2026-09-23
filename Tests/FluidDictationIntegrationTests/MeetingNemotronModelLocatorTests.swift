@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§5): local Nemotron model
/// readiness. Injected URLs for tests, the development environment override, the versioned cache
/// location, and fail-closed structure validation. No network and no bundled 190 MB weights.
@MainActor
final class MeetingNemotronModelLocatorTests: XCTestCase {
    func testInvalidImportPreservesInstalledPackage() throws {
        let root = try self.makeTempDirectory()
        let source = try self.makeFakePackage(at: root.appendingPathComponent("source"))
        let destination = try self.makeFakePackage(at: root.appendingPathComponent("installed"))
        let manifest = destination.appendingPathComponent("Manifest.json")
        let original = try Data(contentsOf: manifest)
        XCTAssertThrowsError(try MeetingModelInstaller.install(from: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), [destination.lastPathComponent])
    }

    func testPublishedPackageInstallPersistsForFreshLocatorAndReplacement() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scratch/nemotron-diar/hf-upload/nemotron_3_diarization.mlpackage")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Published model fixture is not available")
        }
        let root = try self.makeTempDirectory()
        let destination = root.appendingPathComponent("installed/model.mlpackage")
        _ = try MeetingModelInstaller.install(from: source, to: destination)
        // A fresh locator has no reference to the install task or original download.
        XCTAssertEqual(try MeetingNemotronModelLocator(injectedURL: destination).locate().totalByteCount, 199_258_287)
        _ = try MeetingModelInstaller.install(from: source, to: destination)
        XCTAssertEqual(try MeetingModelInstaller.validate(destination).totalByteCount, 199_258_287)
        XCTAssertEqual(try MeetingModelInstaller.validate(source).totalByteCount, 199_258_287)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemotron-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func makeFakePackage(at url: URL) throws -> URL {
        let package = url.appendingPathComponent("nemotron_diar_fp16.mlpackage", isDirectory: true)
        let coreML = package.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
        try FileManager.default.createDirectory(at: coreML, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        try Data("model".utf8).write(to: coreML.appendingPathComponent("model.mlmodel"))
        let weights = coreML.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: weights.appendingPathComponent("weight.bin"))
        return package
    }

    func testInjectedURLValidatesStructureAndRechecks() throws {
        let root = try self.makeTempDirectory()
        let package = try self.makeFakePackage(at: root)
        let locator = MeetingNemotronModelLocator(injectedURL: package)

        let artifact = try locator.locate()
        XCTAssertEqual(artifact.packageURL, package.standardizedFileURL)
        XCTAssertEqual(artifact.fileCount, 3)
        XCTAssertGreaterThan(artifact.totalByteCount, 0)
        XCTAssertFalse(artifact.manifestSHA256.isEmpty)
        XCTAssertFalse(artifact.entryMetadataSHA256.isEmpty)

        XCTAssertEqual(try locator.recheck(artifact), artifact)

        // A changed artifact is refused at open time.
        try Data("{\"changed\":true}".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        XCTAssertThrowsError(try locator.recheck(artifact)) {
            XCTAssertEqual(
                $0 as? MeetingNemotronModelReadinessError,
                .artifactChanged(path: package.standardizedFileURL.path)
            )
        }

        // Restore the manifest, locate again, then replace weights with the same byte count.
        // Entry metadata still changes, so recheck cannot be bypassed by preserving file size.
        try Data("{}".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        let sameSizeBaseline = try locator.locate()
        try Data("changed".utf8).write(
            to: package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        )
        XCTAssertThrowsError(try locator.recheck(sameSizeBaseline)) {
            XCTAssertEqual(
                $0 as? MeetingNemotronModelReadinessError,
                .artifactChanged(path: package.standardizedFileURL.path)
            )
        }
    }

    func testStructureValidationRefusesMissingPiecesAndSymlinks() throws {
        let root = try self.makeTempDirectory()

        // Missing entirely.
        let missing = root.appendingPathComponent("nope.mlpackage")
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: missing).locate()) {
            guard case .modelNotInstalled = $0 as? MeetingNemotronModelReadinessError else {
                return XCTFail("expected modelNotInstalled, got \($0)")
            }
        }

        // No Manifest.json.
        let noManifest = root.appendingPathComponent("bad1.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: noManifest, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: noManifest.appendingPathComponent("model.mlmodel"))
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: noManifest).locate()) {
            XCTAssertEqual($0 as? MeetingNemotronModelReadinessError, .invalidModelPackage(reason: "manifestMissing"))
        }

        // No model.mlmodel.
        let noModel = root.appendingPathComponent("bad2.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: noModel, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: noModel.appendingPathComponent("Manifest.json"))
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: noModel).locate()) {
            XCTAssertEqual($0 as? MeetingNemotronModelReadinessError, .invalidModelPackage(reason: "modelMissing"))
        }

        // A symlink anywhere inside the package is rejected.
        let linked = try self.makeFakePackage(at: root)
        let symlinkedWeights = linked.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        try FileManager.default.removeItem(at: symlinkedWeights)
        try FileManager.default.createSymbolicLink(atPath: symlinkedWeights.path, withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: linked).locate()) {
            XCTAssertEqual(
                $0 as? MeetingNemotronModelReadinessError,
                .invalidModelPackage(reason: "packageContainsSymlink")
            )
        }

        // The package itself may not be a symlink either.
        let real = try self.makeFakePackage(at: root.appendingPathComponent("real", isDirectory: true))
        let link = root.appendingPathComponent("linked.mlpackage")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: link).locate()) {
            XCTAssertEqual(
                $0 as? MeetingNemotronModelReadinessError,
                .invalidModelPackage(reason: "packageIsSymlink")
            )
        }
    }

    func testEnvironmentOverrideAndDefaultLocation() throws {
        let root = try self.makeTempDirectory()
        let package = try self.makeFakePackage(at: root)

        let key = MeetingNemotronModelLocator.environmentOverrideKey
        let overridden = MeetingNemotronModelLocator(environment: [key: package.path])
        XCTAssertEqual(try overridden.locate().packageURL, package.standardizedFileURL)

        // Blank override falls through to the versioned cache location. Whether a model is
        // installed there is developer-machine state and is covered separately through injected
        // present/missing paths; this routing test must not depend on that state.
        let blank = MeetingNemotronModelLocator(environment: [key: "  "])
        XCTAssertEqual(
            blank.resolvedPackageURL(),
            MeetingNemotronModelLocator.defaultPackageURL()
        )
    }

    /// The supplied development package must pass structural validation — this catches a broken
    /// or moved checkout before any CoreML load is attempted.
    func testSuppliedDevelopmentPackageIsStructurallyValid() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FluidDictationIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let supplied = repoRoot
            .appendingPathComponent("nemotron-3-diarization/models/nemotron_diar_fp16.mlpackage")
        guard FileManager.default.fileExists(atPath: supplied.path) else {
            throw XCTSkip("the supplied Nemotron package is not present in this checkout")
        }
        let artifact = try MeetingNemotronModelLocator(injectedURL: supplied).locate()
        XCTAssertGreaterThan(artifact.fileCount, 0)
        XCTAssertGreaterThan(artifact.totalByteCount, 100_000_000, "the real package carries its weights")
    }
}

@MainActor
final class MeetingDiarizationModelStoreTests: XCTestCase {
    private static let artifact = MeetingNemotronModelArtifact(
        packageURL: URL(fileURLWithPath: "/tmp/stub-nemotron.mlpackage"),
        totalByteCount: 199_258_287,
        fileCount: 3,
        manifestSHA256: "stub",
        entryMetadataSHA256: "stub"
    )

    private struct Missing: Error {}

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.value += 1
            return self.value
        }

        var count: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    override func setUpWithError() throws {
        guard CPUArchitecture.isAppleSilicon else { throw XCTSkip("Speaker labels require Apple silicon") }
    }

    func testInstalledModelIsReadyWithoutDownloading() async throws {
        let installs = Counter()
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { Self.artifact },
            install: { _ in
                _ = installs.increment()
                return Self.artifact
            }
        )

        let installed = try await store.ensureInstalled()

        XCTAssertEqual(installed, Self.artifact)
        XCTAssertEqual(store.state, .ready(Self.artifact))
        XCTAssertEqual(installs.count, 0, "an installed model must never be downloaded again")
    }

    func testConcurrentCallersShareOneDownload() async throws {
        let installs = Counter()
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { throw Missing() },
            install: { progress in
                _ = installs.increment()
                progress(0.5)
                try await Task.sleep(nanoseconds: 50_000_000)
                return Self.artifact
            }
        )

        async let first = store.ensureInstalled()
        async let second = store.ensureInstalled()
        let results = try await [first, second]

        XCTAssertEqual(results, [Self.artifact, Self.artifact])
        XCTAssertEqual(installs.count, 1, "opening FluidMeet and finishing a meeting must not download twice")
        XCTAssertEqual(store.state, .ready(Self.artifact))
    }

    func testFailedDownloadShowsPlainMessageAndRetryStartsFresh() async throws {
        let installs = Counter()
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { throw Missing() },
            install: { _ in
                if installs.increment() == 1 {
                    throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
                }
                return Self.artifact
            }
        )

        do {
            try await store.ensureInstalled()
            XCTFail("the first download must fail")
        } catch let error as MeetingDiarizationModelStore.DownloadError {
            XCTAssertEqual(
                error.localizedDescription,
                "Couldn't download the speaker model. Check your internet connection and try again."
            )
        }
        guard case .failed = store.state else { return XCTFail("expected failed state, got \(store.state)") }

        let installed = try await store.ensureInstalled()

        XCTAssertEqual(installed, Self.artifact)
        XCTAssertEqual(installs.count, 2)
        XCTAssertEqual(store.state, .ready(Self.artifact))
    }

    func testDevelopmentOverrideNeverDownloads() async throws {
        let installs = Counter()
        let store = MeetingDiarizationModelStore(
            canDownload: { false },
            validate: { throw Missing() },
            install: { _ in
                _ = installs.increment()
                return Self.artifact
            }
        )

        do {
            try await store.ensureInstalled()
            XCTFail("an invalid development path must fail")
        } catch {}

        XCTAssertEqual(installs.count, 0, "a development override must never be replaced by a download")
        guard case .failed = store.state else { return XCTFail("expected failed state, got \(store.state)") }
    }

    func testUnavailableRepositoryMessage() {
        XCTAssertEqual(
            MeetingDiarizationModelStore.userMessage(for: NSError(domain: "HF", code: 401)),
            "The speaker model isn't available for download right now. Try again later."
        )
    }
}
