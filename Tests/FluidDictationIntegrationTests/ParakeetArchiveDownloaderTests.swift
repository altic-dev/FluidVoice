import CryptoKit
import Darwin
@testable import FluidVoice_Debug
import Foundation
import XCTest

final nonisolated class ParakeetArchiveDownloaderTests: XCTestCase {
    func testValidTarPublishesCompleteModelWithRealByteProgressAndPreservesSiblings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let recorder = ProgressRecorder()
        let result = try await fixture.install(progress: recorder.record)
        XCTAssertEqual(result, fixture.target)
        XCTAssertTrue(ParakeetArchiveDownloader.artifactsAreComplete(at: result, descriptor: fixture.descriptor))
        XCTAssertTrue(fixture.descriptor.artifactsAreComplete(at: result))
        XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName)), try Data(XCTUnwrap(fixture.descriptor.archiveSHA256).utf8))
        XCTAssertEqual(recorder.values.filter { $0.phase == .downloading }.compactMap(\.fractionCompleted), [0.5, 1])
        XCTAssertEqual(recorder.values.last?.phase, .loading)
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testInstalledCompleteCacheSkipsNetwork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.install()
        let result = try await ParakeetArchiveDownloader.ensurePresent(descriptor: fixture.descriptor, in: fixture.models, transport: { _, _ in
            XCTFail("An installed model must not use the network")
            throw ProbeFailure.injected
        })
        XCTAssertEqual(result, fixture.target)
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testNewRevisionRejectsOldCompleteCacheAndPublishesOnlyAfterOwnedRemoval() async throws {
        let old = try Fixture()
        let newer = try Fixture(artifactContents: "new trained checkpoint")
        defer { old.cleanup(); newer.cleanup() }
        _ = try await old.install()
        XCTAssertTrue(old.descriptor.artifactsAreComplete(at: old.target))
        XCTAssertFalse(newer.descriptor.artifactsAreComplete(at: old.target))
        XCTAssertFalse(ParakeetArchiveDownloader.artifactsAreComplete(at: old.target, descriptor: newer.descriptor))
        do {
            _ = try await ParakeetArchiveDownloader.ensurePresent(descriptor: newer.descriptor, in: old.models, transport: { _, _ in
                XCTFail("The downloader must preserve an existing target until its caller admits removal")
                throw ProbeFailure.injected
            })
            XCTFail("An old revision must never be accepted as the new installed model")
        } catch let error as ParakeetArchiveDownloader.DownloadError {
            guard case .targetExists = error else { return XCTFail("Expected actionable existing-cache failure") }
        }
        XCTAssertTrue(old.descriptor.artifactsAreComplete(at: old.target))
        // Mirror the provider's admitted removal of this exact stale model folder.
        // The archive helper itself never removes an existing installed target.
        try FileManager.default.removeItem(at: old.target)
        let result = try await ParakeetArchiveDownloader.ensurePresent(descriptor: newer.descriptor, in: old.models, transport: { _, progress in
            try newer.transport(progress)
        })
        XCTAssertEqual(result, old.target)
        XCTAssertTrue(newer.descriptor.artifactsAreComplete(at: result))
        XCTAssertFalse(old.descriptor.artifactsAreComplete(at: result))
        try old.assertPreservedSiblingsAndNoStage()
        try newer.assertPreservedSiblingsAndNoStage()
    }

    func testMissingWrongOversizedAndSymlinkRevisionMarkersCannotClaimInstalledCache() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.install()
        let marker = fixture.target.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName)
        for contents: Data? in [nil, Data(String(repeating: "0", count: 64).utf8), Data(repeating: 1, count: 65)] {
            try FileManager.default.removeItem(at: marker)
            if let contents { try contents.write(to: marker) }
            XCTAssertFalse(fixture.descriptor.artifactsAreComplete(at: fixture.target))
            XCTAssertFalse(ParakeetArchiveDownloader.artifactsAreComplete(at: fixture.target, descriptor: fixture.descriptor))
            if contents == nil { try fixture.descriptor.writeInstallationRevision(at: fixture.target) }
        }
        try FileManager.default.removeItem(at: marker)
        let external = fixture.base.appendingPathComponent("external-revision")
        try Data(XCTUnwrap(fixture.descriptor.archiveSHA256).utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: external)
        XCTAssertFalse(fixture.descriptor.artifactsAreComplete(at: fixture.target))
        XCTAssertFalse(ParakeetArchiveDownloader.artifactsAreComplete(at: fixture.target, descriptor: fixture.descriptor))
        XCTAssertTrue(ParakeetSpeechModelCatalog.v2.installationRevisionMatches(at: fixture.base))
        XCTAssertTrue(ParakeetSpeechModelCatalog.v3.installationRevisionMatches(at: fixture.base))
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testExplicitUpdateValidatesUnpublishedStageThenSwapsAndRemovesOldFiles() async throws {
        let old = try Fixture()
        let newer = try Fixture(artifactContents: "new trained checkpoint")
        defer { old.cleanup(); newer.cleanup() }
        _ = try await old.install()
        let result = try await ParakeetArchiveDownloader.ensurePresent(
            descriptor: newer.descriptor, in: old.models, replaceExisting: true,
            stageValidator: { stage in
                XCTAssertNotEqual(stage, old.target)
                XCTAssertTrue(newer.descriptor.artifactsAreComplete(at: stage))
                XCTAssertTrue(old.descriptor.artifactsAreComplete(at: old.target), "Old weights stay usable during validation")
            }, transport: { _, progress in try newer.transport(progress) }
        )
        XCTAssertEqual(result, old.target)
        XCTAssertTrue(newer.descriptor.artifactsAreComplete(at: result))
        XCTAssertFalse(old.descriptor.artifactsAreComplete(at: result))
        XCTAssertEqual(try String(contentsOf: result.appendingPathComponent("Encoder-1.mlmodelc/weights/weight.bin"), encoding: .utf8), "new trained checkpoint")
        try old.assertPreservedSiblingsAndNoStage()
        try newer.assertPreservedSiblingsAndNoStage()
    }

    func testUpdateValidatorFailureAndCancellationPreserveInstalledOldRevision() async throws {
        for cancel in [false, true] {
            let old = try Fixture()
            let newer = try Fixture(artifactContents: "new trained checkpoint")
            defer { old.cleanup(); newer.cleanup() }
            _ = try await old.install()
            do {
                _ = try await ParakeetArchiveDownloader.ensurePresent(
                    descriptor: newer.descriptor, in: old.models, replaceExisting: true,
                    stageValidator: { _ in
                        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                        else { throw ProbeFailure.injected }
                    }, transport: { _, progress in try newer.transport(progress) }
                )
                XCTFail("Failed or cancelled Core ML validation must not publish")
            } catch {}
            XCTAssertTrue(old.descriptor.artifactsAreComplete(at: old.target))
            XCTAssertEqual(try String(contentsOf: old.target.appendingPathComponent("Encoder-1.mlmodelc/weights/weight.bin"), encoding: .utf8), "fixture")
            try old.assertPreservedSiblingsAndNoStage()
            try newer.assertPreservedSiblingsAndNoStage()
        }
    }

    func testUpdateTransferFailureAndBadChecksumPreserveOldFiles() async throws {
        for badChecksum in [false, true] {
            let old = try Fixture()
            let newer = try Fixture(checksum: badChecksum ? String(repeating: "0", count: 64) : nil, artifactContents: "new trained checkpoint")
            defer { old.cleanup(); newer.cleanup() }
            _ = try await old.install()
            await self.expectFailure {
                _ = try await ParakeetArchiveDownloader.ensurePresent(descriptor: newer.descriptor, in: old.models, replaceExisting: true, transport: { _, progress in
                    if !badChecksum { throw ProbeFailure.injected }
                    return try newer.transport(progress)
                })
            }
            XCTAssertTrue(old.descriptor.artifactsAreComplete(at: old.target))
            try old.assertPreservedSiblingsAndNoStage()
            try newer.assertPreservedSiblingsAndNoStage()
        }
    }

    func testUpdateCancellationDuringTransferKeepsOldModel() async throws {
        let old = try Fixture()
        let newer = try Fixture(artifactContents: "new trained checkpoint")
        defer { old.cleanup(); newer.cleanup() }
        _ = try await old.install()
        let started = Started()
        let task = Task {
            try await ParakeetArchiveDownloader.ensurePresent(descriptor: newer.descriptor, in: old.models, replaceExisting: true, transport: { _, _ in
                await started.signal()
                try await Task.sleep(for: .seconds(30))
                throw ProbeFailure.injected
            })
        }
        await started.wait()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(old.descriptor.artifactsAreComplete(at: old.target))
        try old.assertPreservedSiblingsAndNoStage()
    }

    func testUpdateIncompleteArchivePreservesOldModel() async throws {
        let old = try Fixture()
        let newer = try Fixture(omitLastArtifact: true, artifactContents: "new trained checkpoint")
        defer { old.cleanup(); newer.cleanup() }
        _ = try await old.install()
        await self.expectFailure {
            _ = try await ParakeetArchiveDownloader.ensurePresent(descriptor: newer.descriptor, in: old.models, replaceExisting: true, transport: { _, progress in try newer.transport(progress) })
        }
        XCTAssertTrue(old.descriptor.artifactsAreComplete(at: old.target))
        try old.assertPreservedSiblingsAndNoStage()
        try newer.assertPreservedSiblingsAndNoStage()
    }

    func testCompetingUpdatesPublishOnceAndRejectStaleOriginalIdentity() async throws {
        let old = try Fixture()
        let newer = try Fixture(artifactContents: "new trained checkpoint")
        defer { old.cleanup(); newer.cleanup() }
        _ = try await old.install()
        let gate = UpdateValidationGate()
        let operation: @Sendable () async throws -> Bool = {
            do {
                _ = try await ParakeetArchiveDownloader.ensurePresent(
                    descriptor: newer.descriptor, in: old.models, replaceExisting: true,
                    stageValidator: { _ in await gate.enter() }, transport: { _, progress in try newer.transport(progress) }
                )
                return true
            } catch let error as ParakeetArchiveDownloader.DownloadError {
                guard case .targetChanged = error else { throw error }
                return false
            }
        }
        let first = Task { try await operation() }
        let second = Task { try await operation() }
        let deadline = ContinuousClock.now + .seconds(3)
        while await gate.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let arrived = await gate.count
        await gate.releaseAll()
        XCTAssertEqual(arrived, 2, "Both stages must validate before either publishes")
        let results = try await [first.value, second.value]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertTrue(newer.descriptor.artifactsAreComplete(at: old.target))
        try old.assertPreservedSiblingsAndNoStage()
        try newer.assertPreservedSiblingsAndNoStage()
    }

    func testPostCommitCleanupFailureReportsInstalledNewAndRetainedOldFiles() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Filesystem permission failure requires a non-root user") }
        let old = try Fixture()
        let newer = try Fixture(artifactContents: "new trained checkpoint")
        defer { old.cleanup(); newer.cleanup() }
        _ = try await old.install()
        do {
            _ = try await ParakeetArchiveDownloader.ensurePresent(
                descriptor: newer.descriptor, in: old.models, replaceExisting: true,
                stageValidator: { stage in
                    let ownedStage = stage.deletingLastPathComponent().deletingLastPathComponent()
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ownedStage.path)
                }, transport: { _, progress in try newer.transport(progress) }
            )
            XCTFail("Cleanup failure must not be returned as success")
        } catch let error as ParakeetArchiveDownloader.DownloadError {
            guard case let .replacementCleanupFailed(installed, retainedOld) = error else { return XCTFail("Expected post-commit cleanup failure, got \(error)") }
            XCTAssertEqual(installed, old.target)
            XCTAssertTrue(newer.descriptor.artifactsAreComplete(at: installed))
            XCTAssertTrue(FileManager.default.fileExists(atPath: retainedOld.path), "A post-commit cleanup error names the owned remainder, not a rollback")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: retainedOld.path)
            try FileManager.default.removeItem(at: retainedOld)
        }
        try old.assertPreservedSiblingsAndNoStage()
        try newer.assertPreservedSiblingsAndNoStage()
    }

    func testUpdateRejectsChangedTargetIdentityEvenWithTheSameRevision() async throws {
        let old = try Fixture()
        let newer = try Fixture(artifactContents: "new trained checkpoint")
        defer { old.cleanup(); newer.cleanup() }
        _ = try await old.install()
        do {
            _ = try await ParakeetArchiveDownloader.ensurePresent(
                descriptor: newer.descriptor, in: old.models, replaceExisting: true,
                stageValidator: { _ in
                    let replacement = old.models.appendingPathComponent("competing-target")
                    try FileManager.default.copyItem(at: old.target, to: replacement)
                    try FileManager.default.removeItem(at: old.target)
                    try FileManager.default.moveItem(at: replacement, to: old.target)
                }, transport: { _, progress in try newer.transport(progress) }
            )
            XCTFail("A replaced directory must not be overwritten")
        } catch let error as ParakeetArchiveDownloader.DownloadError {
            guard case .targetChanged = error else { return XCTFail("Expected targetChanged") }
        }
        XCTAssertTrue(old.descriptor.artifactsAreComplete(at: old.target))
        try old.assertPreservedSiblingsAndNoStage()
    }

    func testUpdateRejectsRevisionChangedDuringValidation() async throws {
        let old = try Fixture()
        let newer = try Fixture(artifactContents: "new trained checkpoint")
        defer { old.cleanup(); newer.cleanup() }
        _ = try await old.install()
        let competingHash = String(repeating: "a", count: 64)
        do {
            _ = try await ParakeetArchiveDownloader.ensurePresent(
                descriptor: newer.descriptor, in: old.models, replaceExisting: true,
                stageValidator: { _ in
                    try Data(competingHash.utf8).write(to: old.target.appendingPathComponent(ParakeetSpeechModelCatalog.installationRevisionFileName))
                }, transport: { _, progress in try newer.transport(progress) }
            )
            XCTFail("A changed checkpoint must be preserved")
        } catch let error as ParakeetArchiveDownloader.DownloadError {
            guard case .targetChanged = error else { return XCTFail("Expected targetChanged") }
        }
        XCTAssertEqual(old.descriptor.installedArchiveSHA256(at: old.target), competingHash)
        try old.assertPreservedSiblingsAndNoStage()
    }

    func testRevisionWriteFailureCleansStageAndNeverPublishes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        await self.expectFailure {
            _ = try await ParakeetArchiveDownloader.ensurePresent(
                descriptor: fixture.descriptor,
                in: fixture.models,
                transport: { _, progress in try fixture.transport(progress) },
                revisionWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testCancellationAfterRevisionWriteCleansStageWithoutPublishing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            _ = try await ParakeetArchiveDownloader.ensurePresent(
                descriptor: fixture.descriptor,
                in: fixture.models,
                transport: { _, progress in try fixture.transport(progress) },
                revisionWriter: { directory, descriptor in
                    try descriptor.writeInstallationRevision(at: directory)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
            XCTFail("Expected cancellation before publication")
        } catch is CancellationError {} catch { XCTFail("Expected CancellationError, got \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testArchiveCannotSupplyItsOwnRevisionMarker() async throws {
        let marker = "fluid-parakeet-mini-coreml/" + ParakeetSpeechModelCatalog.installationRevisionFileName
        let fixture = try Fixture(extraEntry: Entry(path: marker, data: Data(String(repeating: "0", count: 64).utf8)))
        defer { fixture.cleanup() }
        await self.expectFailure { _ = try await fixture.install() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testWrongHashDoesNotExtractOrPublish() async throws {
        let fixture = try Fixture(checksum: String(repeating: "0", count: 64))
        defer { fixture.cleanup() }
        await self.expectFailure { _ = try await fixture.install() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testMissingCompiledArtifactDoesNotPublish() async throws {
        let fixture = try Fixture(omitLastArtifact: true)
        defer { fixture.cleanup() }
        await self.expectFailure { _ = try await fixture.install() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testWrongArchiveRootCannotWriteASibling() async throws {
        let fixture = try Fixture(rootName: "parakeet-tdt-0.6b-v3-coreml")
        defer { fixture.cleanup() }
        await self.expectFailure { _ = try await fixture.install() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testTraversalAndSymlinkEntriesAreRejected() async throws {
        for entry in [Entry(path: "../escape", data: Data("bad".utf8)), Entry(path: "fluid-parakeet-mini-coreml/link", type: 50)] {
            let fixture = try Fixture(extraEntry: entry)
            defer { fixture.cleanup() }
            await self.expectFailure { _ = try await fixture.install() }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("escape").path))
            try fixture.assertPreservedSiblingsAndNoStage()
        }
    }

    func testCancellationDuringTransferCleansOwnedStageAndPreservesSiblings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let started = Started()
        let task = Task {
            try await ParakeetArchiveDownloader.ensurePresent(descriptor: fixture.descriptor, in: fixture.models, transport: { _, _ in
                await started.signal()
                try await Task.sleep(for: .seconds(30))
                throw ProbeFailure.injected
            })
        }
        await started.wait()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected transfer cancellation")
        } catch is CancellationError {} catch { XCTFail("Expected CancellationError, got \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testCancellationAfterHashBeforeExtractionNeverExposesPartialTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.install(progress: { progress in
                if progress.phase == .optimizing { withUnsafeCurrentTask { $0?.cancel() } }
            })
            XCTFail("Expected install cancellation")
        } catch is CancellationError {} catch { XCTFail("Expected CancellationError, got \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testExistingIncompleteTargetAndCompetingPublishedTargetAreNeverOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: false)
        let marker = fixture.target.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: marker)
        await self.expectFailure { _ = try await fixture.install() }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        try FileManager.default.removeItem(at: fixture.target)
        await self.expectFailure {
            _ = try await ParakeetArchiveDownloader.ensurePresent(descriptor: fixture.descriptor, in: fixture.models, transport: { _, progress in
                try FileManager.default.createDirectory(at: fixture.target, withIntermediateDirectories: false)
                try Data("keep".utf8).write(to: marker)
                return try fixture.transport(progress)
            })
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    func testBadHTTPResponseAndWrongLengthCleanDownloadedFile() async throws {
        for status in [404, 200] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            await self.expectFailure {
                _ = try await ParakeetArchiveDownloader.ensurePresent(descriptor: fixture.descriptor, in: fixture.models, transport: { url, _ in
                    let file = fixture.base.appendingPathComponent("returned-download")
                    try Data("short response".utf8).write(to: file)
                    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
                    return (file, response)
                })
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("returned-download").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
            try fixture.assertPreservedSiblingsAndNoStage()
        }
    }

    func testSymlinkCacheRootAndNestedInstalledLinksAreRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let alias = fixture.base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.models)
        await self.expectFailure { _ = try await ParakeetArchiveDownloader.ensurePresent(descriptor: fixture.descriptor, in: alias, transport: { _, _ in
            XCTFail("A symlink cache root must not download")
            throw ProbeFailure.injected
        }) }
        _ = try await fixture.install()
        let link = fixture.target.appendingPathComponent("unexpected-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.models.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml"))
        XCTAssertFalse(ParakeetArchiveDownloader.artifactsAreComplete(at: fixture.target, descriptor: fixture.descriptor))
        await self.expectFailure { _ = try await fixture.install() }
        try fixture.assertPreservedSiblingsAndNoStage()
    }

    private func expectFailure(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected archive installation to fail") } catch {}
    }

    private enum ProbeFailure: Error { case injected }

    private actor Started {
        private var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        func signal() { self.started = true; self.continuation?.resume(); self.continuation = nil }
        func wait() async {
            if self.started { return }
            await withCheckedContinuation { self.continuation = $0 }
        }
    }

    private actor UpdateValidationGate {
        private(set) var count = 0
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false
        func enter() async {
            self.count += 1
            guard !self.released else { return }
            await withCheckedContinuation { self.continuations.append($0) }
        }
        func releaseAll() {
            self.released = true
            let pending = self.continuations
            self.continuations = []
            for continuation in pending { continuation.resume() }
        }
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var progress: [ModelPreparationProgress] = []
        var values: [ModelPreparationProgress] { self.lock.withLock { self.progress } }
        func record(_ value: ModelPreparationProgress) { self.lock.withLock { self.progress.append(value) } }
    }

    private struct Entry {
        let path: String
        var data = Data()
        var type: UInt8 = 48
    }

    private struct Fixture: Sendable {
        let base: URL
        let models: URL
        let descriptor: ParakeetSpeechModelCatalog.Descriptor
        let archive: Data
        var target: URL { self.descriptor.cacheDirectory(in: self.models) }

        init(checksum: String? = nil, omitLastArtifact: Bool = false, rootName: String = "fluid-parakeet-mini-coreml", extraEntry: Entry? = nil, artifactContents: String = "fixture") throws {
            self.base = FileManager.default.temporaryDirectory.appendingPathComponent("ParakeetArchiveDownloaderTests-" + UUID().uuidString, isDirectory: true)
            self.models = self.base.appendingPathComponent("Models", isDirectory: true)
            try FileManager.default.createDirectory(at: self.models, withIntermediateDirectories: true)
            for name in ["parakeet-tdt-0.6b-v2-coreml", "parakeet-tdt-0.6b-v3-coreml", "fluid-parakeet-pico-coreml", "parakeet-eou-streaming"] {
                let sibling = self.models.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
                try Data(name.utf8).write(to: sibling.appendingPathComponent("keep"))
            }
            let source = ParakeetSpeechModelCatalog.mini
            var entries = source.requiredModelNames.flatMap { name in
                ["coremldata.bin", "metadata.json", "weights/weight.bin"].map {
                    Entry(path: "\(rootName)/\(name)/\($0)", data: Data(artifactContents.utf8))
                }
            }
            if omitLastArtifact { entries.removeLast() }
            entries.append(Entry(path: "\(rootName)/\(source.vocabularyFile)", data: Data("{}".utf8)))
            if let extraEntry { entries.append(extraEntry) }
            self.archive = Self.tar(entries)
            self.descriptor = .init(
                modelID: source.modelID,
                variant: source.variant,
                folderName: source.folderName,
                expectedDownloadBytes: Int64(self.archive.count),
                archiveURL: source.archiveURL,
                archiveSHA256: checksum ?? SHA256.hash(data: self.archive).map { String(format: "%02x", $0) }.joined(),
                requiredModelNames: source.requiredModelNames,
                vocabularyFile: source.vocabularyFile,
                displayName: source.displayName,
                humanReadableName: source.humanReadableName,
                languageSupport: source.languageSupport,
                supportedLanguageCodes: source.supportedLanguageCodes,
                downloadSize: source.downloadSize,
                cardDescription: source.cardDescription,
                performanceRatings: source.performanceRatings
            )
        }

        func install(progress: @escaping @Sendable (ModelPreparationProgress) -> Void = { _ in }) async throws -> URL {
            try await ParakeetArchiveDownloader.ensurePresent(descriptor: self.descriptor, in: self.models, progressHandler: progress, transport: { _, progress in
                try self.transport(progress)
            })
        }

        func transport(_ progress: @Sendable (Int64, Int64) -> Void) throws -> (URL, URLResponse) {
            let file = self.base.appendingPathComponent("download-" + UUID().uuidString)
            try self.archive.write(to: file)
            progress(Int64(self.archive.count / 2), -1)
            progress(Int64(self.archive.count), Int64(self.archive.count))
            let url = try XCTUnwrap(self.descriptor.archiveURL)
            return try (file, XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }

        func assertPreservedSiblingsAndNoStage(file: StaticString = #filePath, line: UInt = #line) throws {
            for name in ["parakeet-tdt-0.6b-v2-coreml", "parakeet-tdt-0.6b-v3-coreml", "fluid-parakeet-pico-coreml", "parakeet-eou-streaming"] {
                XCTAssertEqual(try String(contentsOf: self.models.appendingPathComponent("\(name)/keep"), encoding: .utf8), name, file: file, line: line)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: self.models.path).filter { $0.hasSuffix(".staging") }, [], file: file, line: line)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: self.base.path).filter { $0.hasPrefix("download-") }, [], file: file, line: line)
        }

        func cleanup() { try? FileManager.default.removeItem(at: self.base) }

        private static func tar(_ entries: [Entry]) -> Data {
            var archive = Data()
            for entry in entries {
                var header = [UInt8](repeating: 0, count: 512)
                for (offset, byte) in entry.path.utf8.prefix(100).enumerated() {
                    header[offset] = byte
                }
                let size = String(format: "%011o", entry.data.count)
                for (offset, byte) in size.utf8.enumerated() {
                    header[124 + offset] = byte
                }
                for offset in 148..<156 {
                    header[offset] = 32
                }
                header[156] = entry.type
                let checksum = String(format: "%06o", header.reduce(0) { $0 + Int($1) })
                for (offset, byte) in checksum.utf8.enumerated() {
                    header[148 + offset] = byte
                }
                header[154] = 0; header[155] = 32
                archive.append(contentsOf: header)
                archive.append(entry.data)
                archive.append(Data(repeating: 0, count: (512 - entry.data.count % 512) % 512))
            }
            archive.append(Data(repeating: 0, count: 1024))
            return archive
        }
    }
}
