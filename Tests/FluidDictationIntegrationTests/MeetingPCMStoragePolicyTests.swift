@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingPCMStoragePolicyTests: XCTestCase {
    func testBudgetMatchesFloat32CaptureTopologyAndIncludesWorkingHeadroom() {
        XCTAssertEqual(MeetingPCMStoragePolicy.pcmBytesPerSecond(trackCount: 1), 192_000)
        XCTAssertEqual(MeetingPCMStoragePolicy.pcmBytesPerSecond(trackCount: 2), 576_000)
        XCTAssertEqual(MeetingPCMStoragePolicy.estimatedPCMBytes(trackCount: 2), 576_000 * 60 * 60)
        let required = MeetingPCMStoragePolicy.requiredFreeBytes(trackCount: 2)
        XCTAssertGreaterThan(required, MeetingPCMStoragePolicy.estimatedPCMBytes(trackCount: 2))
        XCTAssertGreaterThan(required, 512 * 1024 * 1024)
        XCTAssertEqual(MeetingPCMStoragePolicy.trackCount(for: .onlineCall), 2)
        XCTAssertEqual(MeetingPCMStoragePolicy.trackCount(for: .inRoom), 1)
    }

    func testFirstPlaybackURLUsesArchiveWhenReadyAndOtherwiseUsesFinalizedCAFPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoice-PCM-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pcmPath = "tracks/microphone/000000.caf"
        let archivePath = "archive/microphone/000000.m4a"
        let pcmURL = root.appendingPathComponent(pcmPath)
        try FileManager.default.createDirectory(at: pcmURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: pcmURL)

        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "PCM", microphone: microphone)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: configuration, timebase: timebase)
        let chunk = MeetingAudioChunk(
            id: UUID(), sequence: 0, relativeFilePath: pcmPath,
            presentationStart: MeetingMediaTime(value: 0, timescale: 1),
            presentationEnd: MeetingMediaTime(value: 1, timescale: 1),
            discontinuities: [], sha256: "hash", byteCount: 1, finalizationState: .finalized,
            audioSchemaVersion: 2,
            captureAnalysisAsset: MeetingAudioAsset(
                role: .captureAnalysis, encoding: .linearPCMFloat32CAFV1, presence: .ready,
                relativeFilePath: pcmPath, byteCount: 1, sha256: "hash", sampleRate: 48_000,
                channelCount: 1, frameCount: 1
            )
        )
        session.audioTracks = [MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic",
            format: nil, timebase: timebase, health: .waiting, chunks: [chunk]
        )]

        XCTAssertEqual(MeetingAudioPresentation.firstPlaybackURL(in: session, directory: root), pcmURL)

        var archivedChunk = chunk
        archivedChunk.playbackArchiveAsset = MeetingAudioAsset(
            role: .playbackArchive, encoding: .aacLCM4AV1, presence: .ready,
            relativeFilePath: archivePath, byteCount: 1, sha256: "archive", sampleRate: 48_000,
            channelCount: 1, frameCount: 1, sourceAssetSHA256: "hash"
        )
        session.audioTracks[0].chunks = [archivedChunk]
        let archiveURL = root.appendingPathComponent(archivePath)
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([2]).write(to: archiveURL)
        XCTAssertEqual(MeetingAudioPresentation.firstPlaybackURL(in: session, directory: root), archiveURL)
    }
}
