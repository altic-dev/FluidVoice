@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingAudioAssetCompatibilityTests: XCTestCase {
    func testLegacyChunkOmitsAllP0aKeysAndRoundTripsFullSession() throws {
        let chunk = MeetingAudioChunk(id: UUID(), sequence: 3, relativeFilePath: "tracks/microphone/3.caf",
                                      presentationStart: MeetingMediaTime(value: 0, timescale: 1000),
                                      presentationEnd: MeetingMediaTime(value: 1000, timescale: 1000),
                                      discontinuities: [], sha256: "legacy", byteCount: 42, finalizationState: .finalized)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(chunk)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "sequence", "relativeFilePath", "presentationStart", "presentationEnd", "discontinuities", "sha256", "byteCount", "finalizationState"]))
        XCTAssertNil(object["audioSchemaVersion"]); XCTAssertNil(object["captureAnalysisAsset"]); XCTAssertNil(object["playbackArchiveAsset"])
        let decodedChunk = try JSONDecoder().decode(MeetingAudioChunk.self, from: json)
        XCTAssertEqual(decodedChunk, chunk)

        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Legacy", microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic"))
        var session = MeetingSession(configuration: configuration, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                     timebase: MeetingTimebaseMetadata(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.audioTracks = [MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic", format: nil,
                                                   timebase: session.timebase, health: .waiting, chunks: [chunk])]
        let sessionData = try encoder.encode(session)
        XCTAssertEqual(try JSONDecoder().decode(MeetingSession.self, from: sessionData), session)
    }

    func testValidPCMAssetRoundTripsAndLegacyReadyMayOmitFrameFacts() throws {
        let asset = MeetingAudioAsset(role: .captureAnalysis, encoding: .linearPCMFloat32CAFV1, presence: .ready,
                                      relativeFilePath: "tracks/application/1.caf", byteCount: 128, sha256: String(repeating: "a", count: 64),
                                      sampleRate: 48_000, channelCount: 2, frameCount: 16)
        let data = try JSONEncoder().encode(asset)
        XCTAssertEqual(try JSONDecoder().decode(MeetingAudioAsset.self, from: data), asset)
        XCTAssertTrue(asset.validationIssues().isEmpty)
        let legacy = MeetingAudioAsset(role: .playbackArchive, encoding: .legacyAACUnknownPrimingV1, presence: .ready,
                                       relativeFilePath: "audio.m4a", byteCount: 1)
        XCTAssertTrue(legacy.validationIssues().isEmpty)
    }

    func testUnknownRawValuesRoundTripAndQuarantineOnlyThatAsset() throws {
        let json = Data(#"{"role":"futureRole","encoding":"futureEncoding","presence":"futurePresence","relativeFilePath":"future.bin","byteCount":1}"#.utf8)
        let asset = try JSONDecoder().decode(MeetingAudioAsset.self, from: json)
        XCTAssertEqual(asset.role.rawValue, "futureRole"); XCTAssertEqual(asset.encoding.rawValue, "futureEncoding"); XCTAssertEqual(asset.presence.rawValue, "futurePresence")
        XCTAssertEqual(asset.validationIssues(), [.unknownRole("futureRole"), .unknownEncoding("futureEncoding"), .unknownPresence("futurePresence")])
        let reencoded = try JSONDecoder().decode(MeetingAudioAsset.self, from: JSONEncoder().encode(asset))
        XCTAssertEqual(reencoded, asset)

        let validArchive = MeetingAudioAsset(
            role: .playbackArchive,
            encoding: .aacLCM4AV1,
            presence: .ready,
            relativeFilePath: "tracks/application/archive.m4a",
            byteCount: 64,
            sha256: String(repeating: "b", count: 64),
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 48_000
        )
        let chunk = MeetingAudioChunk(
            id: UUID(),
            sequence: 0,
            relativeFilePath: "tracks/application/legacy.m4a",
            presentationStart: MeetingMediaTime(value: 0, timescale: 1_000),
            presentationEnd: MeetingMediaTime(value: 1_000, timescale: 1_000),
            discontinuities: [],
            sha256: "legacy",
            byteCount: 1,
            finalizationState: .finalized,
            audioSchemaVersion: 2,
            captureAnalysisAsset: asset,
            playbackArchiveAsset: validArchive
        )
        XCTAssertEqual(chunk.captureAnalysisAsset?.validationIssues(), asset.validationIssues())
        XCTAssertTrue(validArchive.validationIssues().isEmpty)
        XCTAssertTrue(chunk.assetValidationIssues().contains(.unknownRole("futureRole")))
    }

    func testReadyPCMAssetWithoutFactsIsInvalidPurelyFromMetadata() {
        let invalid = MeetingAudioAsset(role: .captureAnalysis, encoding: .linearPCMFloat32CAFV1, presence: .ready,
                                        relativeFilePath: "tracks/application/1.caf", byteCount: 128)
        XCTAssertTrue(invalid.validationIssues().contains(.readyAssetMissingHash))
        XCTAssertTrue(invalid.validationIssues().contains(.readyAssetMissingSampleRate))
        XCTAssertTrue(invalid.validationIssues().contains(.readyAssetMissingChannelCount))
        XCTAssertTrue(invalid.validationIssues().contains(.readyAssetMissingFrameCount))
    }
}
