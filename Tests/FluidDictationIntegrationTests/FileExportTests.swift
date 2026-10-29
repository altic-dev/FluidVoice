@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class FileExportTests: XCTestCase {
    private func requireOwnedTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let configured = ProcessInfo.processInfo.environment["FLUID_EXPORT_TEST_SANDBOX_TEMP"]
        guard let configured,
              directory.path == URL(fileURLWithPath: configured).resolvingSymlinksInPath().standardizedFileURL.path,
              directory.path.contains("fluid-export-tests-")
        else {
            throw XCTSkip("Launch the test host with an owned fluid-export-tests-* TMPDIR and matching FLUID_EXPORT_TEST_SANDBOX_TEMP")
        }
        return directory
    }

    private func fixture(_ index: Int = 0, confidence: Float = 0.95) -> TranscriptionResult {
        TranscriptionResult(
            text: "Synthetic transcript \(index): Привет, Ёж!",
            confidence: confidence,
            duration: 12.5,
            processingTime: 0.75,
            fileName: "fixture-\(index).wav",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            speakerSegments: [SpeakerTranscriptSegment(
                speaker: "Speaker 1", startSeconds: 0, endSeconds: 2, text: "Synthetic speech"
            )],
            speakerLabelingNotice: "Synthetic notice",
            speakerLabelingGaps: [SpeakerTranscriptGap(startSeconds: 2, endSeconds: 2.5)]
        )
    }

    private func document(
        _ result: TranscriptionResult,
        format: FileTranscriptionView.ExportFormat
    ) throws -> TranscriptionDocument {
        TranscriptionDocument(result: result, format: format)
    }

    func testExportLeavesExistingTemporaryFilesUntouched() throws {
        let directory = try self.requireOwnedTemporaryDirectory()
        let urls = ["temp.txt", "temp.json"].map { directory.appendingPathComponent($0) }
        guard urls.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("Refusing to replace pre-existing temporary files")
        }
        let sentinel = Data("Owned export test sentinel".utf8)
        for url in urls { try sentinel.write(to: url, options: .withoutOverwriting) }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }

        for format in FileTranscriptionView.ExportFormat.allCases {
            _ = try self.document(self.fixture(), format: format).makeFileWrapper()
            for url in urls {
                XCTAssertEqual(try? Data(contentsOf: url), sentinel, "Export changed \(url.lastPathComponent)")
            }
        }
    }

    func testConcurrentDocumentsKeepTheirOwnPayloads() throws {
        let directory = try self.requireOwnedTemporaryDirectory()
        guard ["temp.txt", "temp.json"].allSatisfy({
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else {
            throw XCTSkip("Refusing to replace pre-existing temporary files")
        }
        let documents = try (0..<128).map { try self.document(self.fixture($0), format: .text) }
        let expected = (0..<128).map { Data(self.fixture($0).textExport.utf8) }
        let outcomes = ExportOutcomes()

        DispatchQueue.concurrentPerform(iterations: documents.count) { index in
            do {
                let bytes = try documents[index].makeFileWrapper().regularFileContents
                if bytes != expected[index] { outcomes.record("Wrong payload for document \(index)") }
            } catch {
                outcomes.record("Document \(index) failed: \(error)")
            }
        }

        XCTAssertEqual(outcomes.failures, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("temp.txt").path))
    }

    func testTextPreservesExistingMetadataAndUTF8() throws {
        let result = self.fixture()
        let wrapper = try self.document(result, format: .text).makeFileWrapper()
        XCTAssertTrue(wrapper.isRegularFile)
        XCTAssertEqual(wrapper.regularFileContents, Data(result.textExport.utf8))
        XCTAssertNil(wrapper.preferredFilename)
    }

    func testJSONPreservesExistingSchemaAndFormatting() throws {
        let result = self.fixture()
        let wrapper = try self.document(result, format: .json).makeFileWrapper()
        let bytes = try XCTUnwrap(wrapper.regularFileContents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(bytes, try encoder.encode(result))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(json.keys), [
            "text", "confidence", "duration", "processingTime", "fileName", "timestamp",
            "speakerSegments", "speakerLabelingNotice", "speakerLabelingGaps",
        ])
        XCTAssertEqual(json["fileName"] as? String, "fixture-0.wav")
        XCTAssertEqual(json["timestamp"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertNil(json["id"])
    }

    func testDocumentRetainsCapturedResultAndFormat() throws {
        var selectedResult = self.fixture()
        var selectedFormat = FileTranscriptionView.ExportFormat.text
        let expected = Data(selectedResult.textExport.utf8)
        let document = try self.document(selectedResult, format: selectedFormat)
        selectedResult = self.fixture(1)
        selectedFormat = .json

        _ = try self.document(selectedResult, format: selectedFormat).makeFileWrapper()
        XCTAssertEqual(try document.makeFileWrapper().regularFileContents, expected)
        XCTAssertEqual(try document.makeFileWrapper().regularFileContents, expected)
    }

    func testJSONEncodingFailureReachesDocumentWriter() throws {
        let document = try self.document(self.fixture(confidence: .nan), format: .json)
        for _ in 0..<2 {
            XCTAssertThrowsError(try document.makeFileWrapper()) { error in
                guard case EncodingError.invalidValue = error else {
                    return XCTFail("Expected JSON encoding failure, got \(error)")
                }
            }
        }
    }
}

private final class ExportOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    nonisolated func record(_ failure: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage.append(failure)
    }

    nonisolated var failures: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }
}
