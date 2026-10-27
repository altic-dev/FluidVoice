@testable import FluidVoice_Debug
import Foundation
import XCTest

final nonisolated class UpdateRollbackBackupTests: XCTestCase {
    func testCopiesVerifiedBundleAndPreservesInstalledSource() throws {
        try self.withFixture { fixture in
            try fixture.create()
            XCTAssertEqual(try fixture.contents(fixture.installed), "old")
            XCTAssertEqual(try fixture.contents(fixture.backup), "old")
            XCTAssertFalse(fixture.stageExists)
        }
    }

    func testExistingBackupIsNeverOverwritten() throws {
        try self.withFixture { fixture in
            try fixture.makeBundle(at: fixture.backup, contents: "unrelated")
            XCTAssertThrowsError(try fixture.create())
            XCTAssertEqual(try fixture.contents(fixture.backup), "unrelated")
            XCTAssertEqual(try fixture.contents(fixture.installed), "old")
            XCTAssertFalse(fixture.stageExists)
        }
    }

    func testPartialCopyFailureCleansStagingWithoutPublishing() throws {
        try self.withFixture { fixture in
            var operations = UpdateRollbackBackup.Operations.live
            operations.copyBundle = { _, destination in
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                try Data("partial".utf8).write(to: destination.appendingPathComponent("payload"))
                throw ProbeFailure.injected
            }
            XCTAssertThrowsError(try fixture.create(operations: operations))
            XCTAssertFalse(fixture.stageExists)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
            XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        }
    }

    func testStagedValidationFailureCleansPartialAndDoesNotPublish() throws {
        try self.withFixture { fixture in
            XCTAssertThrowsError(try UpdateRollbackBackup.create(installedAppURL: fixture.installed, backupURL: fixture.backup, validate: { url in
                if url != fixture.installed { throw ProbeFailure.injected }
            }))
            XCTAssertFalse(fixture.stageExists)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
            XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        }
    }

    func testCleanupFailureReportsOneStablePathAndNextAttemptRetriesIt() throws {
        try self.withFixture { fixture in
            var operations = UpdateRollbackBackup.Operations.live
            operations.copyBundle = { _, _ in throw ProbeFailure.injected }
            operations.removeDirectory = { _ in throw ProbeFailure.injected }
            for _ in 0..<2 {
                XCTAssertThrowsError(try fixture.create(operations: operations)) {
                    XCTAssertEqual(($0 as? UpdateRollbackBackup.Failure)?.retainedDirectoryURL, fixture.stage)
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.hasSuffix(".staging") }, [fixture.stage.lastPathComponent])
            }
            try fixture.create()
            XCTAssertFalse(fixture.stageExists)
            XCTAssertEqual(try fixture.contents(fixture.backup), "old")
        }
    }

    func testOwnedCrashStageIsDiscardedOnlyAfterInstalledValidation() throws {
        try self.withFixture { fixture in
            try fixture.makeOwnedStage()
            try fixture.makeBundle(at: fixture.stage.appendingPathComponent("partial.app"), contents: "partial")
            XCTAssertThrowsError(try UpdateRollbackBackup.create(installedAppURL: fixture.installed, backupURL: fixture.backup, validate: { _ in throw ProbeFailure.injected }))
            XCTAssertTrue(fixture.stageExists)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
            try fixture.create()
            XCTAssertFalse(fixture.stageExists)
            XCTAssertEqual(try fixture.contents(fixture.backup), "old")
        }
    }

    func testUnknownStageAndForeignOwnershipArePreserved() throws {
        try self.withFixture { fixture in
            try FileManager.default.createDirectory(at: fixture.stage, withIntermediateDirectories: false)
            let marker = fixture.stage.appendingPathComponent("ownership")
            XCTAssertThrowsError(try fixture.create())
            XCTAssertTrue(fixture.stageExists)
            try Data("belongs to another app".utf8).write(to: marker)
            XCTAssertThrowsError(try fixture.create())
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "belongs to another app")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        }
    }

    func testSymlinkStageAndSymlinkMarkerCannotDeleteUnrelatedPaths() throws {
        try self.withFixture { fixture in
            let unrelated = fixture.root.appendingPathComponent("unrelated", isDirectory: true)
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
            try Data("preserve".utf8).write(to: unrelated.appendingPathComponent("payload"))
            let unrelatedMarker = unrelated.appendingPathComponent("ownership")
            try Data("FluidVoiceRollbackBackup-v1\n\(fixture.installed.standardizedFileURL.path)\n".utf8).write(to: unrelatedMarker)
            try FileManager.default.createSymbolicLink(at: fixture.stage, withDestinationURL: unrelated)
            XCTAssertThrowsError(try fixture.create())
            XCTAssertEqual(try fixture.contents(unrelated), "preserve")
            try FileManager.default.removeItem(at: fixture.stage)
            try FileManager.default.createDirectory(at: fixture.stage, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: fixture.stage.appendingPathComponent("ownership"), withDestinationURL: unrelatedMarker)
            XCTAssertThrowsError(try fixture.create())
            XCTAssertEqual(try fixture.contents(unrelated), "preserve")
        }
    }

    func testPublicationFailureCleansStagingAndPreservesSource() throws {
        try self.withFixture { fixture in
            var operations = UpdateRollbackBackup.Operations.live
            operations.publishBundle = { _, _ in throw ProbeFailure.injected }
            XCTAssertThrowsError(try fixture.create(operations: operations))
            XCTAssertFalse(fixture.stageExists)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
            XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        }
    }

    func testCleanupFailureAfterPublicationRetainsVerifiedBackupAndRetries() throws {
        try self.withFixture { fixture in
            var operations = UpdateRollbackBackup.Operations.live
            operations.removeDirectory = { _ in throw ProbeFailure.injected }
            XCTAssertThrowsError(try fixture.create(operations: operations)) {
                XCTAssertEqual(($0 as? UpdateRollbackBackup.Failure)?.retainedDirectoryURL, fixture.stage)
            }
            XCTAssertEqual(try fixture.contents(fixture.backup), "old")
            XCTAssertEqual(try fixture.contents(fixture.installed), "old")
            let nextBackup = fixture.root.appendingPathComponent("next.app")
            try UpdateRollbackBackup.create(installedAppURL: fixture.installed, backupURL: nextBackup, validate: { try fixture.validate($0) })
            XCTAssertFalse(fixture.stageExists)
            XCTAssertEqual(try fixture.contents(nextBackup), "old")
            XCTAssertEqual(try fixture.contents(fixture.backup), "old")
        }
    }

    func testCreateFailureCannotDeleteAnUnknownPath() throws {
        try self.withFixture { fixture in
            var operations = UpdateRollbackBackup.Operations.live
            operations.createDirectory = { _ in throw ProbeFailure.injected }
            operations.removeDirectory = { _ in XCTFail("No owned directory was created") }
            XCTAssertThrowsError(try fixture.create(operations: operations))
            XCTAssertFalse(fixture.stageExists)
            XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try body(fixture)
    }

    private enum ProbeFailure: Error { case injected }

    private struct Fixture: Sendable {
        let base: URL
        let root: URL
        let installed: URL
        let backup: URL
        var stage: URL { self.root.appendingPathComponent(".fluidvoice-backup-FluidVoice.app.staging", isDirectory: true) }
        var stageExists: Bool { FileManager.default.fileExists(atPath: self.stage.path) }

        init() throws {
            self.base = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateRollbackBackupTests-" + UUID().uuidString, isDirectory: true)
            self.root = self.base.appendingPathComponent("backups", isDirectory: true)
            self.installed = self.base.appendingPathComponent("FluidVoice.app", isDirectory: true)
            self.backup = self.root.appendingPathComponent("saved.app", isDirectory: true)
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            try self.makeBundle(at: self.installed, contents: "old")
        }

        func makeBundle(at url: URL, contents: String) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data(contents.utf8).write(to: url.appendingPathComponent("payload"))
        }

        func contents(_ url: URL) throws -> String {
            try String(contentsOf: url.appendingPathComponent("payload"), encoding: .utf8)
        }

        func validate(_ url: URL) throws {
            guard try self.contents(url) == "old" else { throw ProbeFailure.injected }
        }

        func create(operations: UpdateRollbackBackup.Operations = .live) throws {
            try UpdateRollbackBackup.create(installedAppURL: self.installed, backupURL: self.backup, validate: { try self.validate($0) }, operations: operations)
        }

        func makeOwnedStage() throws {
            try FileManager.default.createDirectory(at: self.stage, withIntermediateDirectories: false)
            try Data("FluidVoiceRollbackBackup-v1\n\(self.installed.standardizedFileURL.path)\n".utf8).write(to: self.stage.appendingPathComponent("ownership"))
        }
    }
}
