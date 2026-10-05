import CryptoKit
import Darwin
@testable import FluidVoice_Debug
import Foundation
import XCTest

final nonisolated class CompactSpeechModelArchiveTransportTests: XCTestCase {
    func testRangesAssembleOwnedArchiveAndPreserveSiblings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let recorder = Recorder()
        let (ready, response) = try await fixture.download { request, maximum, progress in
            recorder.add(request.value(forHTTPHeaderField: "Range") ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            XCTAssertLessThanOrEqual(maximum, 4)
            return try fixture.chunk(request, progress: progress)
        }
        defer { try? FileManager.default.removeItem(at: ready) }
        XCTAssertEqual(recorder.values, ["bytes=0-3", "bytes=4-7", "bytes=8-9"])
        XCTAssertEqual(try Data(contentsOf: ready), fixture.payload)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(response.expectedContentLength, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partial.path))
        XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8), fixture.descriptor.archiveSHA256)
        try fixture.assertSiblings()
    }

    func testFailureResumesOnlyCompleteRanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.download { request, _, progress in
                if request.value(forHTTPHeaderField: "Range") == "bytes=4-7" { throw ProbeFailure.injected }
                return try fixture.chunk(request, progress: progress)
            }
            XCTFail("Expected interrupted transfer")
        } catch { XCTAssertTrue(error is ProbeFailure) }
        XCTAssertEqual(try Data(contentsOf: fixture.partial), fixture.payload.prefix(4))
        let recorder = Recorder()
        let (ready, _) = try await fixture.download { request, _, progress in
            recorder.add(request.value(forHTTPHeaderField: "Range") ?? "")
            return try fixture.chunk(request, progress: progress)
        }
        defer { try? FileManager.default.removeItem(at: ready) }
        XCTAssertEqual(recorder.values, ["bytes=4-7", "bytes=8-9"])
        XCTAssertEqual(try Data(contentsOf: ready), fixture.payload)
        try fixture.assertSiblings()
    }

    func testCancellationJoinsTransportAndPreservesCompletedRange() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let cleanup = Recorder()
        let task = Task {
            try await fixture.download { request, _, progress in
                if request.value(forHTTPHeaderField: "Range") == "bytes=4-7" {
                    let (chunk, _) = try fixture.chunk(request, progress: progress)
                    continuation.yield(())
                    continuation.finish()
                    do { try await Task.sleep(for: .seconds(60)) } catch {
                        try FileManager.default.removeItem(at: chunk)
                        cleanup.add("joined")
                        throw error
                    }
                    throw ProbeFailure.injected
                }
                return try fixture.chunk(request, progress: progress)
            }
        }
        for await _ in started {
            break
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cleanup.values, ["joined"])
        XCTAssertEqual(try Data(contentsOf: fixture.partial), fixture.payload.prefix(4))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).contains { $0.hasPrefix("chunk-") })
        try fixture.assertSiblings()
    }

    func testCanceledReturnedChunkIsDeletedWithoutAppendingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.download { request, _, progress in
                let result = try fixture.chunk(request, progress: progress)
                withUnsafeCurrentTask { $0?.cancel() }
                return result
            }
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: fixture.partial).count, 0)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).contains { $0.hasPrefix("chunk-") })
        try fixture.assertSiblings()
    }

    func testBadStatusRangeSizeEncodingAndRedirectCannotAdvancePartial() async throws {
        for defect in Defect.allCases {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            do {
                _ = try await fixture.download { request, _, progress in try fixture.chunk(request, progress: progress, defect: defect) }
                XCTFail("Invalid \(defect) must fail")
            } catch { XCTAssertEqual(error as? CompactSpeechModelArchiveTransport.Failure, .invalidRange) }
            XCTAssertEqual(try Data(contentsOf: fixture.partial).count, 0)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.base.path).contains { $0.hasPrefix("chunk-") })
            try fixture.assertSiblings()
        }
    }

    func testNewReleaseDiscardsOnlyItsOwnOldPartial() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedPartial(fixture.payload.prefix(4), marker: XCTUnwrap(fixture.descriptor.archiveSHA256))
        let replacement = Data("ABCDEFGHIJ".utf8)
        let descriptor = fixture.descriptor.replacingArchive(url: fixture.descriptor.archiveURL, sha256: Fixture.sha256(replacement), byteCount: Int64(replacement.count))
        let recorder = Recorder()
        let (ready, _) = try await CompactSpeechModelArchiveTransport.download(
            descriptor: descriptor,
            in: fixture.models,
            progress: { _, _ in },
            transport: { request, _, progress in
                recorder.add(request.value(forHTTPHeaderField: "Range") ?? "")
                return try fixture.chunk(request, progress: progress, payload: replacement)
            },
            chunkBytes: 4
        )
        defer { try? FileManager.default.removeItem(at: ready) }
        XCTAssertEqual(recorder.values.first, "bytes=0-3")
        XCTAssertEqual(try Data(contentsOf: ready), replacement)
        XCTAssertEqual(try String(contentsOf: fixture.marker, encoding: .utf8), descriptor.archiveSHA256)
        try fixture.assertSiblings()
    }

    func testMalformedMarkerOversizedAndCrashPartialRecoverOnRetry() async throws {
        for corruption in 0..<4 {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let hash = try XCTUnwrap(fixture.descriptor.archiveSHA256)
            let marker = corruption == 0 ? "broken" : corruption == 1 ? String(repeating: "z", count: 64) : hash
            let bytes = corruption == 2 ? Data(repeating: 0, count: 11) : fixture.payload.prefix(corruption == 3 ? 6 : 4)
            try fixture.seedPartial(bytes, marker: marker)
            let recorder = Recorder()
            let (ready, _) = try await fixture.download { request, _, progress in
                recorder.add(request.value(forHTTPHeaderField: "Range") ?? "")
                return try fixture.chunk(request, progress: progress)
            }
            defer { try? FileManager.default.removeItem(at: ready) }
            XCTAssertEqual(recorder.values.first, corruption == 3 ? "bytes=4-7" : "bytes=0-3")
            XCTAssertEqual(try Data(contentsOf: ready), fixture.payload)
            try fixture.assertSiblings()
        }
    }

    func testSamePartialClaimRejectsConcurrentDownloadWithoutNetwork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await fixture.download { _, _, _ in
                continuation.yield(())
                continuation.finish()
                try await Task.sleep(for: .seconds(60))
                throw ProbeFailure.injected
            }
        }
        for await _ in started {
            break
        }
        do {
            _ = try await fixture.download { _, _, _ in XCTFail("A competing claim must fail before network"); throw ProbeFailure.injected }
            XCTFail("Expected another-process claim failure")
        } catch { XCTAssertEqual(error as? CompactSpeechModelArchiveTransport.Failure, .alreadyDownloading) }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let (ready, _) = try await fixture.download { request, _, progress in try fixture.chunk(request, progress: progress) }
        defer { try? FileManager.default.removeItem(at: ready) }
        XCTAssertEqual(try Data(contentsOf: ready), fixture.payload)
        try fixture.assertSiblings()
    }

    func testPartialMarkerAndClaimLinksCannotMutateExternalFiles() async throws {
        for name in ["archive.partial", "release.sha256", "claim.lock"] {
            for hardLink in [false, true] {
                let fixture = try Fixture()
                defer { fixture.cleanup() }
                try fixture.seedPartial(Data(), marker: XCTUnwrap(fixture.descriptor.archiveSHA256))
                let external = fixture.base.appendingPathComponent("external")
                let contents = Data(String(repeating: "f", count: 64).utf8)
                try contents.write(to: external)
                let link = fixture.partial.deletingLastPathComponent().appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: link.path) { try FileManager.default.removeItem(at: link) }
                if hardLink { try FileManager.default.linkItem(at: external, to: link) } else { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external) }
                do {
                    _ = try await fixture.download { _, _, _ in XCTFail("Unsafe retained files must fail before network"); throw ProbeFailure.injected }
                    XCTFail("Expected unsafe link rejection")
                } catch let error as CompactSpeechModelArchiveTransport.Failure {
                    guard case let .unsafePartial(url) = error else { return XCTFail("Expected unsafePartial, got \(error)") }
                    XCTAssertEqual(url, link)
                    XCTAssertTrue(error.localizedDescription.contains(link.path))
                }
                XCTAssertEqual(try Data(contentsOf: external), contents)
                try fixture.assertSiblings()
            }
        }
    }

    func testCompletedArchiveOwnershipPreventsChecksumFailureResume() async throws {
        try await self.assertChecksumFailureRetry(seedCorruptPrefix: false)
    }

    func testDamagedAlignedRetainedPrefixCannotSurviveChecksumFailureRetry() async throws {
        try await self.assertChecksumFailureRetry(seedCorruptPrefix: true)
    }

    private func assertChecksumFailureRetry(seedCorruptPrefix: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let corrupted = Data("XXXXXXXXXX".utf8)
        if seedCorruptPrefix {
            try fixture.seedPartial(corrupted.prefix(4), marker: XCTUnwrap(fixture.descriptor.archiveSHA256))
        }
        let (ready, _) = try await fixture.download { request, _, progress in
            try fixture.chunk(request, progress: progress, payload: seedCorruptPrefix ? fixture.payload : corrupted)
        }
        XCTAssertNotEqual(try Fixture.sha256(Data(contentsOf: ready)), fixture.descriptor.archiveSHA256)
        // The outer installer's checksum failure deletes only this uniquely owned complete file.
        try FileManager.default.removeItem(at: ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partial.path))
        let recorder = Recorder()
        let (retry, _) = try await fixture.download { request, _, progress in
            recorder.add(request.value(forHTTPHeaderField: "Range") ?? "")
            return try fixture.chunk(request, progress: progress)
        }
        defer { try? FileManager.default.removeItem(at: retry) }
        XCTAssertEqual(recorder.values.first, "bytes=0-3")
        XCTAssertEqual(try Data(contentsOf: retry), fixture.payload)
        try fixture.assertSiblings()
    }

    func testNextAttemptRemovesDeadProcessHandoffAndPreservesActiveAndUnknownFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedPartial(Data(), marker: XCTUnwrap(fixture.descriptor.archiveSHA256))
        let directory = fixture.partial.deletingLastPathComponent()
        let deadOwner = Int32.max
        XCTAssertEqual(kill(deadOwner, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let abandoned = directory.appendingPathComponent("ready-\(deadOwner)-\(UUID().uuidString).tar")
        let active = directory.appendingPathComponent("ready-\(getpid())-\(UUID().uuidString).tar")
        let unknown = directory.appendingPathComponent("ready-\(deadOwner)-not-a-uuid.tar")
        for file in [abandoned, active, unknown] { try fixture.payload.write(to: file) }
        let (ready, _) = try await fixture.download { request, _, progress in try fixture.chunk(request, progress: progress) }
        XCTAssertEqual(ready.deletingLastPathComponent(), directory)
        XCTAssertTrue(ready.lastPathComponent.hasPrefix("ready-\(getpid())-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertEqual(try Data(contentsOf: active), fixture.payload)
        XCTAssertEqual(try Data(contentsOf: unknown), fixture.payload)
        XCTAssertEqual(try Data(contentsOf: ready), fixture.payload)
        try fixture.assertSiblings()
    }

    func testAbandonedHandoffLinksAndDirectoriesCannotDeleteExternalFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedPartial(Data(), marker: XCTUnwrap(fixture.descriptor.archiveSHA256))
        let directory = fixture.partial.deletingLastPathComponent()
        let external = fixture.base.appendingPathComponent("external-ready")
        try fixture.payload.write(to: external)
        let symlink = directory.appendingPathComponent("ready-\(Int32.max)-\(UUID().uuidString).tar")
        let hardlink = directory.appendingPathComponent("ready-\(Int32.max)-\(UUID().uuidString).tar")
        let folder = directory.appendingPathComponent("ready-\(Int32.max)-\(UUID().uuidString).tar")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        try FileManager.default.linkItem(at: external, to: hardlink)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let (ready, _) = try await fixture.download { request, _, progress in try fixture.chunk(request, progress: progress) }
        XCTAssertEqual(try Data(contentsOf: ready), fixture.payload)
        XCTAssertEqual(try Data(contentsOf: external), fixture.payload)
        for file in [symlink, hardlink, folder] { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        try fixture.assertSiblings()
    }

    func testAbandonedHandoffCleanupIsBoundedPerAttempt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.seedPartial(Data(), marker: XCTUnwrap(fixture.descriptor.archiveSHA256))
        let directory = fixture.partial.deletingLastPathComponent()
        for _ in 0..<160 {
            let file = directory.appendingPathComponent("ready-\(Int32.max)-\(UUID().uuidString).tar")
            try fixture.payload.write(to: file)
        }
        _ = try await fixture.download { request, _, progress in try fixture.chunk(request, progress: progress) }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("ready-\(Int32.max)-") }
        XCTAssertGreaterThanOrEqual(remaining.count, 160 - 128)
        XCTAssertLessThan(remaining.count, 160)
        try fixture.assertSiblings()
    }

    private enum ProbeFailure: Error { case injected }
    private enum Defect: CaseIterable, Equatable { case status, range, size, encoding, redirect }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] { self.lock.withLock { self.storage } }
        func add(_ value: String) { self.lock.withLock { self.storage.append(value) } }
    }

    private struct Fixture: Sendable {
        let base: URL
        let models: URL
        let descriptor: ParakeetSpeechModelCatalog.Descriptor
        let payload = Data("0123456789".utf8)
        var partial: URL { self.models.appendingPathComponent(".compact-downloads/\(self.descriptor.folderName)/archive.partial") }
        var marker: URL { self.partial.deletingLastPathComponent().appendingPathComponent("release.sha256") }

        init() throws {
            self.base = FileManager.default.temporaryDirectory.appendingPathComponent("FVCompactTransport-\(UUID().uuidString)")
            self.models = self.base.appendingPathComponent("models")
            try FileManager.default.createDirectory(at: self.models, withIntermediateDirectories: true)
            let payload = Data("0123456789".utf8)
            self.descriptor = ParakeetSpeechModelCatalog.mini.replacingArchive(url: ParakeetSpeechModelCatalog.mini.archiveURL, sha256: Self.sha256(payload), byteCount: Int64(payload.count))
            try Data("installed-old-weights".utf8).write(to: self.models.appendingPathComponent("preserved-installed"))
            let sibling = self.models.appendingPathComponent(".compact-downloads/\(ParakeetSpeechModelCatalog.pico.folderName)")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            try Data("other-model-partial".utf8).write(to: sibling.appendingPathComponent("archive.partial"))
        }

        func cleanup() { try? FileManager.default.removeItem(at: self.base) }
        func download(_ transport: @escaping CompactSpeechModelArchiveTransport.ChunkTransport) async throws -> (URL, URLResponse) {
            try await CompactSpeechModelArchiveTransport.download(descriptor: self.descriptor, in: self.models, progress: { _, _ in }, transport: transport, chunkBytes: 4)
        }

        func chunk(_ request: URLRequest, progress: @Sendable (Int64) -> Void, payload: Data? = nil, defect: Defect? = nil) throws -> (URL, URLResponse) {
            let payload = payload ?? self.payload
            let range = try XCTUnwrap(request.value(forHTTPHeaderField: "Range"))
            let bounds = range.dropFirst("bytes=".count).split(separator: "-")
            let start = try XCTUnwrap(Int(bounds[0]))
            let end = try XCTUnwrap(Int(bounds[1]))
            let file = self.base.appendingPathComponent("chunk-\(UUID().uuidString)")
            let contents = defect == .size ? Data([0]) : payload.subdata(in: start..<(end + 1))
            try contents.write(to: file)
            progress(Int64(contents.count))
            let url = defect == .redirect ? URL(string: "https://elsewhere.example/archive.tar") : request.url
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(url), statusCode: defect == .status ? 200 : 206, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Range": defect == .range ? "bytes 1-4/99" : "bytes \(start)-\(end)/\(payload.count)",
                "Content-Length": String(contents.count),
                "Content-Encoding": defect == .encoding ? "gzip" : "identity",
            ]))
            return (file, response)
        }

        func seedPartial(_ data: Data, marker: String) throws {
            try FileManager.default.createDirectory(at: self.partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: self.partial)
            try Data(marker.utf8).write(to: self.marker)
        }

        func assertSiblings() throws {
            XCTAssertEqual(try String(contentsOf: self.models.appendingPathComponent("preserved-installed"), encoding: .utf8), "installed-old-weights")
            let sibling = self.models.appendingPathComponent(".compact-downloads/\(ParakeetSpeechModelCatalog.pico.folderName)/archive.partial")
            XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "other-model-partial")
        }

        static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
}
