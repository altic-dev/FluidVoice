@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Byte-identical publisher/iPhone archives; Mac must return the same verdict for every case.
final nonisolated class ParakeetArchiveInstallerTests: XCTestCase {
    private struct TarCase: Decodable {
        let file: String
        let folderName: String
        let manifestSHA256: String
        let verdict: String
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ModelRelease/tars", isDirectory: true)
    }

    private func cases() throws -> [TarCase] {
        try JSONDecoder().decode([TarCase].self, from: Data(contentsOf: fixtures.appendingPathComponent("expected.json")))
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func unpack(_ tar: TarCase, staging: URL) throws -> URL {
        try ParakeetArchiveInstaller.unpack(archive: fixtures.appendingPathComponent(tar.file), folderName: tar.folderName,
                                           staging: staging, manifestSHA256: tar.manifestSHA256)
    }

    private func verdict(_ error: Error) -> String {
        String(String(describing: error).prefix { $0 != "(" })
    }

    func testEveryCanonicalTarGetsThePublisherAndIPhoneVerdict() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let entries = try cases()
        XCTAssertEqual(entries.count, 17)
        for entry in entries {
            let result: String
            do {
                _ = try unpack(entry, staging: base.appendingPathComponent(entry.file, isDirectory: true))
                result = "ok"
            } catch { result = verdict(error) }
            XCTAssertEqual(result, entry.verdict, entry.file)
        }
    }

    func testVarAndPrivateVarAliasesVerifySameArchiveWithoutChangingFilesOrLinkRules() throws {
        let base = try self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let publicPath = base.path.hasPrefix("/private/var/") ? String(base.path.dropFirst("/private".count)) : base.path
        guard publicPath.hasPrefix("/var/") else { return XCTFail("Expected macOS temporary folder under /var, got \(base.path)") }
        // Build both spellings literally; URL standardization can collapse /private/var.
        let varBase = URL(fileURLWithPath: publicPath, isDirectory: true)
        let privateBase = URL(fileURLWithPath: "/private" + publicPath, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: varBase.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateBase.path))
        let good = try XCTUnwrap(self.cases().first { $0.file == "good.tar" })
        let sibling = privateBase.appendingPathComponent("other-model", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let siblingWeights = sibling.appendingPathComponent("weights")
        try Data("keep".utf8).write(to: siblingWeights)
        let privateFolder = try self.unpack(good, staging: privateBase.appendingPathComponent("staging", isDirectory: true))
        let varFolder = varBase.appendingPathComponent("staging/\(good.folderName)", isDirectory: true)
        let manifest = privateFolder.appendingPathComponent("manifest.json")
        let originalManifest = try Data(contentsOf: manifest)
        let originalNames = try FileManager.default.subpathsOfDirectory(atPath: privateFolder.path).sorted()
        let originalFileIdentity = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: privateFolder.path)[.systemFileNumber] as? NSNumber)
        for alias in [varFolder, privateFolder] {
            XCTAssertNoThrow(try ParakeetArchiveInstaller.verify(folder: alias, folderName: good.folderName, manifestSHA256: good.manifestSHA256))
            XCTAssertEqual(try ParakeetArchiveInstaller.sha256(of: alias.appendingPathComponent("manifest.json")), good.manifestSHA256)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: alias.path)[.systemFileNumber] as? NSNumber, originalFileIdentity)
            XCTAssertEqual(try Data(contentsOf: alias.appendingPathComponent("manifest.json")), originalManifest)
            XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: alias.path).sorted(), originalNames)
            XCTAssertEqual(try Data(contentsOf: siblingWeights), Data("keep".utf8))
        }
        // Canonicalizing an ancestor alias must never permit a symlink as the model root.
        let rootLink = privateBase.appendingPathComponent("linked-model")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: privateFolder)
        XCTAssertThrowsError(try ParakeetArchiveInstaller.verify(folder: rootLink, folderName: good.folderName, manifestSHA256: good.manifestSHA256)) {
            XCTAssertEqual($0 as? ParakeetArchiveInstaller.InstallError, .manifestMismatch)
        }
        try FileManager.default.createSymbolicLink(at: privateFolder.appendingPathComponent("linked-weights"), withDestinationURL: siblingWeights)
        for alias in [varFolder, privateFolder] {
            XCTAssertThrowsError(try ParakeetArchiveInstaller.verify(folder: alias, folderName: good.folderName, manifestSHA256: good.manifestSHA256)) {
                XCTAssertEqual($0 as? ParakeetArchiveInstaller.InstallError, .fileMismatch("linked-weights"))
            }
            XCTAssertEqual(try Data(contentsOf: alias.appendingPathComponent("manifest.json")), originalManifest)
            XCTAssertEqual(try Data(contentsOf: siblingWeights), Data("keep".utf8))
        }
    }

    func testEveryRejectedTarLeavesExistingWeightsAndSiblingUntouched() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let installed = base.appendingPathComponent("installed", isDirectory: true)
        let sibling = base.appendingPathComponent("other-model", isDirectory: true)
        for folder in [installed, sibling] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: folder.appendingPathComponent("weights"))
        }
        for entry in try cases() where entry.verdict != "ok" {
            XCTAssertThrowsError(try unpack(entry, staging: base.appendingPathComponent(entry.file)))
            for folder in [installed, sibling] {
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("weights")), Data("keep".utf8), entry.file)
            }
        }
    }

    func testPreexistingStagingDirectoryAndSymlinkAreNeverRemoved() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let good = try XCTUnwrap(cases().first { $0.file == "good.tar" })
        let protected = base.appendingPathComponent("protected", isDirectory: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: protected.appendingPathComponent("weights"))
        let link = base.appendingPathComponent("linked-staging")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: protected)
        for staging in [protected, link] {
            XCTAssertThrowsError(try unpack(good, staging: staging)) {
                XCTAssertEqual($0 as? ParakeetArchiveInstaller.InstallError, .invalidStaging)
            }
            XCTAssertEqual(try Data(contentsOf: protected.appendingPathComponent("weights")), Data("keep".utf8))
            XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: staging.path))
        }
    }

    func testStandaloneVerificationRejectsLinksWithoutReadingTheirPayload() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let good = try XCTUnwrap(cases().first { $0.file == "good.tar" })
        let folder = try unpack(good, staging: base.appendingPathComponent("staging"))
        let external = base.appendingPathComponent("external")
        try Data("keep".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked"), withDestinationURL: external)
        XCTAssertThrowsError(try ParakeetArchiveInstaller.verify(folder: folder, folderName: good.folderName, manifestSHA256: good.manifestSHA256)) {
            XCTAssertEqual($0 as? ParakeetArchiveInstaller.InstallError, .fileMismatch("linked"))
        }
        XCTAssertEqual(try Data(contentsOf: external), Data("keep".utf8))
    }

    func testInvalidManifestSizesExitWithoutIntegerOverflow() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        for size in [-1, Int64.max] as [Int64] {
            let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let manifest: [String: Any] = [
                "folderName": "tiny-model", "totalSize": 0,
                "files": [["path": "payload", "size": size, "sha256": String(repeating: "0", count: 64)]]
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest)
            let url = folder.appendingPathComponent("manifest.json")
            try data.write(to: url)
            XCTAssertThrowsError(try ParakeetArchiveInstaller.verify(folder: folder, folderName: "tiny-model", manifestSHA256: ParakeetArchiveInstaller.sha256(of: url))) {
                XCTAssertEqual($0 as? ParakeetArchiveInstaller.InstallError, .manifestMismatch)
            }
        }
    }

    func testOversizedManifestIsRejectedBeforeDecode() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let manifest = base.appendingPathComponent("manifest.json")
        try Data(repeating: 32, count: 1_048_577).write(to: manifest)
        XCTAssertThrowsError(try ParakeetArchiveInstaller.verify(folder: base, folderName: "tiny-model", manifestSHA256: ParakeetArchiveInstaller.sha256(of: manifest))) {
            XCTAssertEqual($0 as? ParakeetArchiveInstaller.InstallError, .manifestMismatch)
        }
    }

    func testCancelledUnpackDoesNotCreateStaging() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let good = try XCTUnwrap(cases().first { $0.file == "good.tar" })
        let archive = fixtures.appendingPathComponent(good.file)
        let stage = base.appendingPathComponent("staging")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ParakeetArchiveInstaller.unpack(archive: archive, folderName: good.folderName, staging: stage, manifestSHA256: good.manifestSHA256)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }
}
