@testable import FluidVoice_Debug
import Foundation
import XCTest

#if arch(arm64)
final class OrukeetModelStoreTests: XCTestCase {
    func testRejectsIncompleteInstallation() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(OrukeetModelStore.installed(at: missing))
        XCTAssertThrowsError(try OrukeetModelStore.load(from: missing))
    }

    func testRejectsCorruptArchiveBeforeCreatingInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("corrupt.zip")
        try Data("not a model archive".utf8).write(to: archive)
        let destination = root.appendingPathComponent("installed")
        XCTAssertThrowsError(try OrukeetModelStore.installArchive(at: archive, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Use a throttled local HTTP fixture to exercise real download delegate callbacks.
    func testReportsProgressBeforeDownloadCompletes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["ORUKEET_DOWNLOAD_FIXTURE_URL"],
              let url = URL(string: address),
              let size = environment["ORUKEET_DOWNLOAD_FIXTURE_BYTES"].flatMap(Int.init), size > 0
        else {
            throw XCTSkip("Set ORUKEET_DOWNLOAD_FIXTURE_URL and ORUKEET_DOWNLOAD_FIXTURE_BYTES")
        }
        let intermediate = expectation(description: "Receives progress between zero and completion")
        intermediate.assertForOverFulfill = false
        let progress = ModelPreparationProgressRelay { update in
            if update.phase == .downloading, let fraction = update.fractionCompleted,
               fraction > 0, fraction < 1
            {
                intermediate.fulfill()
            }
        }
        let downloaded = try await OrukeetModelStore.downloadArchive(
            from: url, expectedBytes: size, progress: progress)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        XCTAssertEqual(try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize, size)
        await fulfillment(of: [intermediate], timeout: 1)
    }

    /// Opt-in integration check using the actual pinned Hugging Face archive.
    func testCompilesPortableBundleAndDetectsMissingComponent() async throws {
        guard let path = ProcessInfo.processInfo.environment["ORUKEET_COREML_ARCHIVE"] else {
            throw XCTSkip("Set ORUKEET_COREML_ARCHIVE to the pinned baseline ZIP")
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try OrukeetModelStore.installArchive(at: URL(fileURLWithPath: path), to: destination)
        XCTAssertTrue(OrukeetModelStore.installed(at: destination))
        XCTAssertEqual(try OrukeetModelStore.load(from: destination).vocabulary.count, 8192)
        let missingSource = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try OrukeetModelStore.commitInstallation(from: missingSource, to: destination))
        XCTAssertTrue(OrukeetModelStore.installed(at: destination), "A failed final move must restore the old cache")
        let cancelled = Task {
            try OrukeetModelStore.installArchive(at: URL(fileURLWithPath: path), to: destination)
        }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Cancelled installation succeeded")
        } catch is CancellationError {
            XCTAssertTrue(OrukeetModelStore.installed(at: destination))
        }
        try FileManager.default.removeItem(at: destination.appendingPathComponent("Encoder.mlmodelc"))
        XCTAssertFalse(OrukeetModelStore.installed(at: destination))
        XCTAssertThrowsError(try OrukeetModelStore.load(from: destination))
    }
}
#endif
