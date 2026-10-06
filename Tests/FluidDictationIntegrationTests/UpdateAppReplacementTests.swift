@testable import FluidVoice_Debug
import Foundation
import XCTest

final class UpdateAppReplacementTests: XCTestCase {
    func testCommitKeepsInstalledNameSourceAndUnrelatedDestination() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let unrelated = try fixture.bundle("DownloadedName.app", parent: fixture.applications, contents: "unrelated")
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        XCTAssertEqual(try fixture.contents(replacement.stagedAppURL), "new")
        try replacement.commit()
        XCTAssertEqual(try fixture.contents(fixture.installed), "new")
        XCTAssertEqual(replacement.installedAppURL, fixture.installed)
        XCTAssertEqual(try fixture.contents(replacement.recoveryAppURL), "old")
        XCTAssertEqual(try fixture.contents(fixture.source), "new")
        XCTAssertEqual(try fixture.contents(unrelated), "unrelated")
        try replacement.finalize()
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.stagingDirectoryURL.path))
        XCTAssertEqual(try fixture.contents(fixture.backup), "old")
        XCTAssertEqual(try fixture.contents(fixture.installed), "new")
    }

    func testFailedRelaunchRecoveryRestoresOldBundleWithoutConsumingRollbackSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.backup)
        try replacement.commit()
        try replacement.recover()
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        XCTAssertEqual(try fixture.contents(fixture.backup), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.stagingDirectoryURL.path))
    }

    func testPreparationFailureDoesNotChangeInstalledBundle() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var operations = UpdateAppReplacement.Operations.live
        operations.copyBundle = { _, destination in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            throw ProbeFailure.injected
        }
        XCTAssertThrowsError(try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source, operations: operations))
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        XCTAssertEqual(try fixture.contents(fixture.source), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.applications.path).filter { $0.hasSuffix(".staging") }, [])
    }

    func testCreateFailureCannotDeleteAnUnownedDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let removals = Counter()
        var operations = UpdateAppReplacement.Operations.live
        operations.createDirectory = { _ in throw ProbeFailure.injected }
        operations.removeDirectory = { _ in _ = removals.next() }
        XCTAssertThrowsError(try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source, operations: operations))
        XCTAssertEqual(removals.value, 0)
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
    }

    func testExchangeFailurePreservesOldBundleAndPreparedCopyCanBeDiscarded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var operations = UpdateAppReplacement.Operations.live
        operations.exchangeBundles = { _, _ in throw ProbeFailure.injected }
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source, operations: operations)
        XCTAssertThrowsError(try replacement.commit())
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        XCTAssertEqual(try fixture.contents(replacement.stagedAppURL), "new")
        try replacement.discardPrepared()
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.stagingDirectoryURL.path))
    }

    func testRecoveryFailureRetainsBothBundlesAndAllowsRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let exchanges = Counter()
        var operations = UpdateAppReplacement.Operations.live
        operations.exchangeBundles = { installed, staged in
            if exchanges.next() == 2 { throw ProbeFailure.injected }
            try UpdateAppReplacement.Operations.live.exchangeBundles(installed, staged)
        }
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source, operations: operations)
        try replacement.commit()
        XCTAssertThrowsError(try replacement.recover()) { error in
            XCTAssertEqual((error as? UpdateAppReplacement.Failure)?.operation, .recovery)
            XCTAssertEqual((error as? UpdateAppReplacement.Failure)?.recoveryDirectoryURL, replacement.stagingDirectoryURL)
        }
        XCTAssertEqual(try fixture.contents(fixture.installed), "new")
        XCTAssertEqual(try fixture.contents(replacement.recoveryAppURL), "old")
        try replacement.recover()
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.stagingDirectoryURL.path))
    }

    func testCleanupFailureAfterRecoveryKeepsOldInstalledAndRetriesOnlyCleanup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let exchanges = Counter()
        let removals = Counter()
        var operations = UpdateAppReplacement.Operations.live
        operations.exchangeBundles = { installed, staged in
            _ = exchanges.next()
            try UpdateAppReplacement.Operations.live.exchangeBundles(installed, staged)
        }
        operations.removeDirectory = { directory in
            if removals.next() == 1 { throw ProbeFailure.injected }
            try UpdateAppReplacement.Operations.live.removeDirectory(directory)
        }
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source, operations: operations)
        try replacement.commit()
        XCTAssertThrowsError(try replacement.recover())
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        try replacement.recover()
        XCTAssertEqual(exchanges.value, 2)
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.stagingDirectoryURL.path))
    }

    func testPartialFinalizationFailureKeepsInstalledNewAndDurableOldBackup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let removals = Counter()
        var operations = UpdateAppReplacement.Operations.live
        operations.removeDirectory = { directory in
            if removals.next() == 1 {
                try FileManager.default.removeItem(at: directory.appendingPathComponent("FluidVoice.app/marker"))
                throw ProbeFailure.injected
            }
            try UpdateAppReplacement.Operations.live.removeDirectory(directory)
        }
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source, operations: operations)
        try replacement.commit()
        XCTAssertThrowsError(try replacement.finalize())
        XCTAssertEqual(try fixture.contents(fixture.installed), "new")
        XCTAssertEqual(try fixture.contents(fixture.backup), "old")
        XCTAssertThrowsError(try replacement.recover(), "Partially cleaned old files must never replace the running new app")
        try replacement.finalize()
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.stagingDirectoryURL.path))
    }

    func testValidationOrBackupFailureCanDiscardPreparedWithoutChangingEitherBundle() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)
        try replacement.discardPrepared()
        try replacement.discardPrepared()
        XCTAssertThrowsError(try replacement.commit())
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        XCTAssertEqual(try fixture.contents(fixture.source), "new")
        XCTAssertEqual(try fixture.contents(fixture.backup), "old")
    }

    func testCopyAndCleanupFailureReportsOwnedRecoveryDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var operations = UpdateAppReplacement.Operations.live
        operations.copyBundle = { _, _ in throw ProbeFailure.injected }
        operations.removeDirectory = { _ in throw ProbeFailure.injected }
        XCTAssertThrowsError(try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source, operations: operations)) { error in
            let failure = error as? UpdateAppReplacement.Failure
            XCTAssertEqual(failure?.operation, .cleanup)
            XCTAssertEqual(failure?.recoveryDirectoryURL?.deletingLastPathComponent(), fixture.applications)
            XCTAssertTrue(failure?.recoveryDirectoryURL?.lastPathComponent.hasPrefix(".fluidvoice-update-") == true)
        }
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
    }

    func testRepeatedCommitIsRejectedAndSymlinkInputsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)
        try replacement.commit()
        XCTAssertThrowsError(try replacement.commit())
        XCTAssertEqual(try fixture.contents(fixture.installed), "new")
        try replacement.recover()
        let link = fixture.root.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
        XCTAssertThrowsError(try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: link))
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
    }

    func testLiveTransactionLockBlocksConcurrentAttemptWithoutDeletingRecoveryOrAccumulatingCopies() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)
        for _ in 0..<3 {
            XCTAssertThrowsError(try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)) { error in
                XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
                XCTAssertEqual((error as NSError).code, Int(EWOULDBLOCK))
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.applications.path).count, 3)
        XCTAssertEqual(try fixture.contents(first.stagedAppURL), "new")
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
        try first.discardPrepared()
        let retry = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)
        try retry.discardPrepared()
    }

    func testCallerValidationRunsUnderLockEvenWithoutStaleStage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let validations = Counter()
        let replacement = try UpdateAppReplacement.prepare(
            installedAppURL: fixture.installed,
            replacementAppURL: fixture.source,
            validateInstalledApp: { _ in
                _ = validations.next()
                XCTAssertThrowsError(try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source))
            }
        )
        XCTAssertEqual(validations.value, 1)
        try replacement.discardPrepared()
    }

    func testOtherProcessCannotAcquireLockUntilTransactionCompletes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)
        let lock = fixture.applications.appendingPathComponent(".fluidvoice-update-FluidVoice.app.lock")
        func childLockAttempt() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
            import fcntl, os, sys
            target = os.stat(sys.argv[1])
            for name in os.listdir('/dev/fd'):
                try:
                    inherited = os.fstat(int(name))
                except OSError:
                    continue
                if (inherited.st_dev, inherited.st_ino) == (target.st_dev, target.st_ino):
                    sys.exit(43)
            with open(sys.argv[1], 'r+') as lock:
                try:
                    fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    sys.exit(42)
            """, lock.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try childLockAttempt(), 42)
        try replacement.discardPrepared()
        XCTAssertEqual(try childLockAttempt(), 0)
    }

    func testChangedInstalledDirectoryCannotBeOverwrittenAtCommit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)
        let moved = fixture.root.appendingPathComponent("MovedOriginal.app")
        try FileManager.default.moveItem(at: fixture.installed, to: moved)
        _ = try fixture.bundle("FluidVoice.app", parent: fixture.applications, contents: "external")
        XCTAssertThrowsError(try replacement.commit())
        XCTAssertEqual(try fixture.contents(fixture.installed), "external")
        XCTAssertEqual(try fixture.contents(moved), "old")
        try replacement.discardPrepared()
    }

    func testChangedInstalledDirectoryCannotBeOverwrittenOrDeletedDuringRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let replacement = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)
        try replacement.commit()
        let moved = fixture.root.appendingPathComponent("MovedNew.app")
        try FileManager.default.moveItem(at: fixture.installed, to: moved)
        _ = try fixture.bundle("FluidVoice.app", parent: fixture.applications, contents: "external")
        XCTAssertThrowsError(try replacement.recover())
        XCTAssertEqual(try fixture.contents(fixture.installed), "external")
        XCTAssertEqual(try fixture.contents(replacement.recoveryAppURL), "old")
        XCTAssertEqual(try fixture.contents(moved), "new")
    }

    func testVerifiedInstalledBundleAllowsOwnedCrashStageCleanupAndRetry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = try {
            let abandoned = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)
            try abandoned.commit()
            return abandoned.stagingDirectoryURL
        }()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertThrowsError(try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source))
        XCTAssertEqual(try fixture.contents(directory.appendingPathComponent("FluidVoice.app")), "old")
        let replacement = try UpdateAppReplacement.prepare(
            installedAppURL: fixture.installed,
            replacementAppURL: fixture.source,
            validateInstalledApp: { url in XCTAssertEqual(try fixture.contents(url), "new") }
        )
        XCTAssertEqual(try fixture.contents(fixture.backup), "old")
        XCTAssertEqual(try fixture.contents(fixture.installed), "new")
        XCTAssertEqual(try fixture.contents(replacement.stagedAppURL), "new")
        try replacement.discardPrepared()
    }

    func testRejectedInstalledValidationPreservesOwnedStaleRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = try {
            let abandoned = try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source)
            try abandoned.commit()
            return abandoned.stagingDirectoryURL
        }()
        XCTAssertThrowsError(try UpdateAppReplacement.prepare(
            installedAppURL: fixture.installed,
            replacementAppURL: fixture.source,
            validateInstalledApp: { _ in throw ProbeFailure.injected }
        ))
        XCTAssertEqual(try fixture.contents(directory.appendingPathComponent("FluidVoice.app")), "old")
        XCTAssertEqual(try fixture.contents(fixture.installed), "new")
    }

    func testUnknownStagingDirectoryIsNeverRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = fixture.applications.appendingPathComponent(".fluidvoice-update-FluidVoice.app.staging")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: directory.appendingPathComponent("valuable"))
        XCTAssertThrowsError(try UpdateAppReplacement.prepare(
            installedAppURL: fixture.installed,
            replacementAppURL: fixture.source,
            validateInstalledApp: { _ in }
        ))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("valuable"), encoding: .utf8), "unrelated")
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
    }

    func testStagingSymlinkAndLockSymlinkAreNeverFollowedOrRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let directory = fixture.applications.appendingPathComponent(".fluidvoice-update-FluidVoice.app.staging")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: fixture.source)
        XCTAssertThrowsError(try UpdateAppReplacement.prepare(
            installedAppURL: fixture.installed,
            replacementAppURL: fixture.source,
            validateInstalledApp: { _ in }
        ))
        XCTAssertEqual(try fixture.contents(fixture.source), "new")
        try FileManager.default.removeItem(at: directory)
        let lock = fixture.applications.appendingPathComponent(".fluidvoice-update-FluidVoice.app.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: fixture.source.appendingPathComponent("marker"))
        XCTAssertThrowsError(try UpdateAppReplacement.prepare(installedAppURL: fixture.installed, replacementAppURL: fixture.source))
        XCTAssertEqual(try fixture.contents(fixture.source), "new")
        XCTAssertEqual(try fixture.contents(fixture.installed), "old")
    }

    private enum ProbeFailure: Error { case injected }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.count
        }

        func next() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.count += 1
            return self.count
        }
    }

    private struct Fixture: Sendable {
        let root: URL
        let applications: URL
        let installed: URL
        let source: URL
        let backup: URL

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("fluidvoice-replacement-tests-\(UUID().uuidString)", isDirectory: true)
            self.root = root
            self.applications = root.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(at: self.applications, withIntermediateDirectories: true)
            let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: false)
            self.installed = self.applications.appendingPathComponent("FluidVoice.app", isDirectory: true)
            self.source = downloads.appendingPathComponent("DownloadedName.app", isDirectory: true)
            self.backup = root.appendingPathComponent("Rollback.app", isDirectory: true)
            for (url, value) in [(self.installed, "old"), (self.source, "new"), (self.backup, "old")] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                try Data(value.utf8).write(to: url.appendingPathComponent("marker"))
            }
        }

        func bundle(_ name: String, parent: URL, contents: String) throws -> URL {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data(contents.utf8).write(to: url.appendingPathComponent("marker"))
            return url
        }

        func contents(_ url: URL) throws -> String {
            try String(contentsOf: url.appendingPathComponent("marker"), encoding: .utf8)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
