@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingAudioChunkLedgerTests: XCTestCase {
    func testIntentCheckpointAndTerminalAreDurableAndRoundTrip() throws {
        let root = try self.makeDirectory()
        let id = UUID()
        let store = MeetingAudioChunkLedgerStore(sessionDirectory: root)
        let intent = MeetingAudioChunkLedgerIntent(chunkID: id, sequence: 4,
            canonicalStart: MeetingMediaTime(value: 125, timescale: 1000), producerEpoch: 9,
            sourceFormat: MeetingAudioFormat(codec: "lpcm-f32", sampleRate: 48_000, channelCount: 2, bitRate: nil),
            partialRelativeFilePath: "tracks/application/4.partial.caf", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.writeIntent(intent)
        try store.writeCheckpoint(MeetingAudioChunkLedgerCheckpoint(chunkID: id, expectedFrames: 48000, writtenFrames: 24000,
            lastCanonicalPTS: MeetingMediaTime(value: 625, timescale: 1000), updatedAt: intent.createdAt), for: id)
        try store.writeCheckpoint(MeetingAudioChunkLedgerCheckpoint(chunkID: id, expectedFrames: 48000, writtenFrames: 48000,
            lastCanonicalPTS: MeetingMediaTime(value: 1125, timescale: 1000), updatedAt: intent.createdAt), for: id)
        try store.writeTerminal(MeetingAudioChunkLedgerTerminal(chunkID: id, status: .ready, updatedAt: intent.createdAt, detail: nil), for: id)
        XCTAssertEqual(try store.readIntent(for: id), intent)
        XCTAssertEqual(try store.readCheckpoint(for: id)?.writtenFrames, 48000)
        XCTAssertEqual(try store.readTerminal(for: id)?.status, .ready)
        let intentURL = root.appendingPathComponent("chunk-ledger/\(id.uuidString).intent.json")
        let mode = (try FileManager.default.attributesOfItem(atPath: intentURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, Int(0o600))
    }

    func testIntentIsImmutableAndUnknownTerminalStatusSurvivesDecode() throws {
        let root = try self.makeDirectory(); let id = UUID(); let store = MeetingAudioChunkLedgerStore(sessionDirectory: root)
        let intent = MeetingAudioChunkLedgerIntent(chunkID: id, sequence: 1, canonicalStart: MeetingMediaTime(value: 0, timescale: 1), producerEpoch: 0,
            sourceFormat: MeetingAudioFormat(codec: "lpcm-f32", sampleRate: 16_000, channelCount: 1, bitRate: nil), partialRelativeFilePath: "x.partial.caf", createdAt: Date())
        try store.writeIntent(intent)
        XCTAssertNoThrow(try store.writeIntent(intent))
        var changed = intent; changed.sequence = 2
        XCTAssertThrowsError(try store.writeIntent(changed)) { XCTAssertEqual($0 as? MeetingAudioChunkLedgerError, .conflictingIntent) }
        let terminalData = Data("{\"chunkID\":\"\(id.uuidString)\",\"status\":\"futureTerminal\",\"updatedAt\":\"2024-01-01T00:00:00Z\"}".utf8)
        let terminalURL = root.appendingPathComponent("chunk-ledger/\(id.uuidString).terminal.json")
        try terminalData.write(to: terminalURL)
        XCTAssertEqual(try store.readTerminal(for: id)?.status, .unknown("futureTerminal"))
    }

    func testCheckpointCannotRegressAndReadyRequiresCompleteFrames() throws {
        let root = try self.makeDirectory()
        let id = UUID()
        let store = MeetingAudioChunkLedgerStore(sessionDirectory: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try store.writeIntent(MeetingAudioChunkLedgerIntent(
            chunkID: id,
            sequence: 0,
            canonicalStart: MeetingMediaTime(value: 0, timescale: 1_000),
            producerEpoch: 0,
            sourceFormat: MeetingAudioFormat(codec: "lpcm-f32", sampleRate: 48_000, channelCount: 1, bitRate: nil),
            partialRelativeFilePath: "tracks/microphone/0.partial.caf",
            createdAt: now
        ))
        try store.writeCheckpoint(MeetingAudioChunkLedgerCheckpoint(
            chunkID: id,
            expectedFrames: 48_000,
            writtenFrames: 24_000,
            lastCanonicalPTS: MeetingMediaTime(value: 500, timescale: 1_000),
            updatedAt: now
        ), for: id)
        XCTAssertThrowsError(try store.writeTerminal(
            MeetingAudioChunkLedgerTerminal(chunkID: id, status: .ready, updatedAt: now, detail: nil),
            for: id
        )) {
            XCTAssertEqual($0 as? MeetingAudioChunkLedgerError, .incompleteReadyTerminal)
        }
        XCTAssertThrowsError(try store.writeCheckpoint(MeetingAudioChunkLedgerCheckpoint(
            chunkID: id,
            expectedFrames: 23_000,
            writtenFrames: 23_000,
            lastCanonicalPTS: MeetingMediaTime(value: 400, timescale: 1_000),
            updatedAt: now
        ), for: id)) {
            XCTAssertEqual($0 as? MeetingAudioChunkLedgerError, .checkpointRegression)
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoice-P0b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        return url
    }
}
