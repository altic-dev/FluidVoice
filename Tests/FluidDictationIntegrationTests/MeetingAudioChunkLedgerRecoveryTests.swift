@testable import FluidVoice_Debug
import CryptoKit
import Foundation
import XCTest

@MainActor
final class MeetingAudioChunkLedgerRecoveryTests: XCTestCase {
    func testReadyPCMAssetMustMatchConfinedBytesAndHash() async throws {
        let root = try self.makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID(); let store = MeetingSessionStore(rootDirectory: root)
        let bytes = Data([1, 2, 3, 4]); let hash = self.hash(bytes)
        let asset = MeetingAudioAsset(role: .captureAnalysis, encoding: .linearPCMFloat32CAFV1, presence: .ready,
                                      relativeFilePath: "tracks/microphone/pcm.caf", byteCount: Int64(bytes.count), sha256: hash,
                                      sampleRate: 48_000, channelCount: 1, frameCount: 1)
        let missingArchive = MeetingAudioAsset(
            role: .playbackArchive,
            encoding: .aacLCM4AV1,
            presence: .ready,
            relativeFilePath: "tracks/microphone/archive.m4a",
            byteCount: 4,
            sha256: hash,
            sampleRate: 48_000,
            channelCount: 1,
            frameCount: 1
        )
        let chunk = MeetingAudioChunk(id: UUID(), sequence: 0, relativeFilePath: "legacy.m4a",
                                     presentationStart: MeetingMediaTime(value: 0, timescale: 1000), presentationEnd: MeetingMediaTime(value: 1, timescale: 1000),
                                     discontinuities: [], sha256: hash, byteCount: Int64(bytes.count), finalizationState: .finalized,
                                     audioSchemaVersion: 2, captureAnalysisAsset: asset,
                                     playbackArchiveAsset: missingArchive)
        var session = MeetingSession(id: sessionID, configuration: MeetingCaptureConfiguration(mode: .inRoom, title: "P0b", microphone: MeetingMicrophoneIdentity(captureDeviceID: "m", displayName: "M")),
                                     timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "m", sourceDisplayName: "M", format: nil, timebase: session.timebase, health: .waiting, chunks: [chunk])
        session.audioTracks = [track]
        try await store.create(session)
        let directory = try await store.sessionDirectory(for: sessionID)
        let pcmURL = directory.appendingPathComponent(asset.relativeFilePath)
        try FileManager.default.createDirectory(at: pcmURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: pcmURL)
        let trackURL = directory.appendingPathComponent("tracks/microphone/track.json")
        try JSONEncoder().encode(track).write(to: trackURL)
        let loaded = try await store.load(id: sessionID)
        XCTAssertEqual(loaded?.audioTracks.first?.chunks.first?.byteCount, Int64(bytes.count))
        XCTAssertEqual(loaded?.audioTracks.first?.chunks.first?.finalizationState, .finalized)
        XCTAssertEqual(loaded?.audioTracks.first?.chunks.first?.captureAnalysisAsset?.presence, .ready)
        XCTAssertEqual(loaded?.audioTracks.first?.chunks.first?.playbackArchiveAsset?.presence, .failed)
        try Data([9]).write(to: pcmURL)
        let mismatched = try await store.load(id: sessionID)
        XCTAssertEqual(mismatched?.audioTracks.first?.chunks.first?.finalizationState, .failed)
        XCTAssertEqual(mismatched?.audioTracks.first?.chunks.first?.byteCount, 0)
    }

    func testPartialOrEscapingNewAssetIsNeverPromoted() async throws {
        let chunk = MeetingAudioChunk(id: UUID(), sequence: 0, relativeFilePath: "legacy.m4a",
                                     presentationStart: MeetingMediaTime(value: 0, timescale: 1), presentationEnd: MeetingMediaTime(value: 1, timescale: 1),
                                     discontinuities: [], sha256: "legacy", byteCount: 1, finalizationState: .writing, audioSchemaVersion: 2,
                                     captureAnalysisAsset: MeetingAudioAsset(role: .captureAnalysis, encoding: .linearPCMFloat32CAFV1, presence: .partial,
                                                                              relativeFilePath: "../outside.partial.caf", byteCount: 0))
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let store = MeetingSessionStore(rootDirectory: root)
        var session = MeetingSession(
            id: sessionID,
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom,
                title: "P0b partial",
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "m", displayName: "M")
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            )
        )
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "m",
            sourceDisplayName: "M",
            format: nil,
            timebase: session.timebase,
            health: .waiting,
            chunks: [chunk]
        )
        session.audioTracks = [track]
        try await store.create(session)
        let directory = try await store.sessionDirectory(for: sessionID)
        let trackURL = directory.appendingPathComponent("tracks/microphone/track.json")
        try FileManager.default.createDirectory(
            at: trackURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(track).write(to: trackURL)

        let loaded = try await store.load(id: sessionID)

        XCTAssertEqual(loaded?.audioTracks.first?.chunks.first?.finalizationState, .failed)
        XCTAssertEqual(loaded?.audioTracks.first?.chunks.first?.captureAnalysisAsset?.presence, .partial)
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func makeDirectory() throws -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoice-P0b-recovery-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url }
}
