@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Exercises the real delegate without starting a network task.
final nonisolated class ProgressiveFileDownloaderTests: XCTestCase {
    func testOversizedChunkedTransferStopsBeforeReportingMisleadingProgress() throws {
        try self.assertRejected(written: 11, expected: -1, maximum: 10)
    }

    func testOversizedDeclaredResponseStopsAtFirstByteCallback() throws {
        try self.assertRejected(written: 1, expected: 11, maximum: 10)
    }

    func testExactLimitAndDefaultUnlimitedDownloadsStillReturnTheirFile() throws {
        for maximum: Int64? in [3, nil] {
            let fixture = try Fixture(maximumBytes: maximum)
            defer { fixture.cleanup() }
            fixture.delegate.urlSession(fixture.session, downloadTask: fixture.task, didWriteData: 3, totalBytesWritten: 3, totalBytesExpectedToWrite: 3)
            fixture.delegate.retainDownload(at: fixture.source, response: fixture.response)
            fixture.delegate.urlSession(fixture.session, task: fixture.task, didCompleteWithError: nil)
            let result = try XCTUnwrap(fixture.recorder.result).get()
            defer { try? FileManager.default.removeItem(at: result.0) }
            XCTAssertEqual(try Data(contentsOf: result.0), Data([1, 2, 3]))
            XCTAssertEqual(fixture.recorder.progress, [3])
        }
    }

    func testFinishedOversizedFileIsNeverRetainedEvenWithoutProgressCallback() throws {
        let fixture = try Fixture(maximumBytes: 2)
        defer { fixture.cleanup() }
        fixture.delegate.retainDownload(at: fixture.source, response: fixture.response)
        fixture.delegate.urlSession(fixture.session, task: fixture.task, didCompleteWithError: nil)
        self.assertLengthFailure(fixture.recorder.result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testCancellationAfterFileCompletionRemovesRetainedDownload() throws {
        let fixture = try Fixture(maximumBytes: nil)
        defer { fixture.cleanup() }
        let retained = try XCTUnwrap(fixture.delegate.retainDownload(at: fixture.source, response: fixture.response))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        fixture.delegate.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.cancelled))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
        guard case let .failure(error)? = fixture.recorder.result else { return XCTFail("Expected cancellation") }
        XCTAssertEqual((error as? URLError)?.code, .cancelled)
    }

    private func assertRejected(written: Int64, expected: Int64, maximum: Int64) throws {
        let fixture = try Fixture(maximumBytes: maximum)
        defer { fixture.cleanup() }
        fixture.delegate.urlSession(fixture.session, downloadTask: fixture.task, didWriteData: written, totalBytesWritten: written, totalBytesExpectedToWrite: expected)
        fixture.delegate.urlSession(fixture.session, task: fixture.task, didCompleteWithError: URLError(.cancelled))
        self.assertLengthFailure(fixture.recorder.result)
        XCTAssertTrue(fixture.recorder.progress.isEmpty)
    }

    private func assertLengthFailure(_ result: Result<(URL, URLResponse), Error>?, file: StaticString = #filePath, line: UInt = #line) {
        guard case let .failure(error)? = result else { return XCTFail("Expected oversized transfer rejection", file: file, line: line) }
        XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum, file: file, line: line)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedResult: Result<(URL, URLResponse), Error>?
        private var storedProgress: [Int64] = []
        var result: Result<(URL, URLResponse), Error>? { self.lock.withLock { self.storedResult } }
        var progress: [Int64] { self.lock.withLock { self.storedProgress } }
        func complete(_ result: Result<(URL, URLResponse), Error>) { self.lock.withLock { self.storedResult = result } }
        func report(_ bytes: Int64, _: Int64) { self.lock.withLock { self.storedProgress.append(bytes) } }
    }

    private struct Fixture {
        let directory: URL
        let source: URL
        let session: URLSession
        let task: URLSessionDownloadTask
        let response: URLResponse
        let delegate: ProgressiveFileDownloader.Delegate
        let recorder: Recorder

        init(maximumBytes: Int64?) throws {
            self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProgressiveFileDownloaderTests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false)
            self.source = self.directory.appendingPathComponent("transfer")
            try Data([1, 2, 3]).write(to: self.source)
            self.recorder = Recorder()
            self.delegate = ProgressiveFileDownloader.Delegate(maximumBytes: maximumBytes, onProgress: self.recorder.report, completion: self.recorder.complete)
            self.session = URLSession(configuration: .ephemeral)
            self.task = try self.session.downloadTask(with: XCTUnwrap(URL(string: "https://fixture.invalid/unused")))
            self.response = URLResponse(url: self.source, mimeType: nil, expectedContentLength: 3, textEncodingName: nil)
        }

        func cleanup() {
            self.session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: self.directory)
        }
    }
}
