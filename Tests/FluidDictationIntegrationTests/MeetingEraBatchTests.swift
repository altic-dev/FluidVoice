@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Batch era-awareness: `captureEras[].startSeconds` is raw PTS; `microphoneEras(for:origin:)`'s domain conversion to origin-relative seconds is pinned here.
final class MeetingEraBatchTests: XCTestCase {
    private func track(
        captureMethod: MeetingAudioTrackCaptureMethod? = nil,
        clockDrift: MeetingClockDriftRecord? = nil,
        captureEras: [MeetingCaptureEra]? = nil
    ) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [], captureMethod: captureMethod, clockDrift: clockDrift,
            captureEras: captureEras
        )
    }

    private func era(
        _ method: MeetingAudioTrackCaptureMethod,
        startSeconds: Double,
        clockDrift: MeetingClockDriftRecord? = nil
    ) -> MeetingCaptureEra {
        MeetingCaptureEra(
            method: method, deviceUID: nil, deviceName: nil, roleAtElection: .unknown,
            startSeconds: startSeconds, clockDrift: clockDrift
        )
    }

    private func turn(
        clusterID: SessionSpeakerID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String = "hi",
        overlapsRemote: Bool = false,
        rms: Double = 0
    ) -> MeetingProcessingPipeline.StagedMicrophoneTurn {
        MeetingProcessingPipeline.StagedMicrophoneTurn(
            chunkID: UUID(), index: 0, clusterID: clusterID, clusterLabel: "spk",
            start: start, end: end, text: text, overlapsRemote: overlapsRemote, rms: rms
        )
    }

    // MARK: - Era resolution

    func testLegacyTrackYieldsSingleEraOfCaptureMethod() {
        let track = self.track(captureMethod: .voiceProcessing)
        let eras = MeetingProcessingPipeline.microphoneEras(for: track, origin: 0)
        XCTAssertEqual(eras.count, 1)
        XCTAssertEqual(eras[0].method, .voiceProcessing)
        XCTAssertEqual(eras[0].startSeconds, -.infinity, "the single era must own every turn regardless of origin")
    }

    func testLegacyTrackWithNilCaptureMethodFallsBackSafely() {
        let track = self.track(captureMethod: nil)
        let eras = MeetingProcessingPipeline.microphoneEras(for: track, origin: 0)
        XCTAssertEqual(eras.count, 1)
        XCTAssertEqual(eras[0].method, .avCaptureSession, "never default to VPIO for an unknown legacy method")
    }

    /// Era 0 is pinned to `-infinity`; every later era is converted to origin-relative — NOT returned verbatim.
    func testMultiEraTrackConvertsStoredRawPTSToOriginRelative() {
        let origin: TimeInterval = 100_000
        let rawEras = [self.era(.avCaptureSession, startSeconds: 0), self.era(.voiceProcessing, startSeconds: origin + 30)]
        let track = self.track(captureMethod: .avCaptureSession, captureEras: rawEras)
        let eras = MeetingProcessingPipeline.microphoneEras(for: track, origin: origin)
        XCTAssertEqual(eras.count, 2)
        XCTAssertEqual(eras[0].startSeconds, -.infinity)
        XCTAssertEqual(eras[1].startSeconds, 30, accuracy: 1e-9)
    }

    /// Domain-pinning regression: comparing turn times directly against the RAW (unconverted)
    /// boundary — the bug this guards against — would put both turns in era 0.
    func testEraIndexResolvesCorrectlyAcrossANonZeroOrigin() {
        let origin: TimeInterval = 100_000
        let rawEras = [self.era(.voiceProcessing, startSeconds: 0), self.era(.avCaptureSession, startSeconds: origin + 30)]
        let track = self.track(captureMethod: .avCaptureSession, captureEras: rawEras)
        let eras = MeetingProcessingPipeline.microphoneEras(for: track, origin: origin)

        XCTAssertEqual(MeetingProcessingPipeline.eraIndex(containing: 25, eras: eras), 0, "before the boundary")
        XCTAssertEqual(MeetingProcessingPipeline.eraIndex(containing: 35, eras: eras), 1, "after the boundary")

        XCTAssertEqual(MeetingProcessingPipeline.eraIndex(containing: 25, eras: rawEras), 0)
        XCTAssertEqual(
            MeetingProcessingPipeline.eraIndex(containing: 35, eras: rawEras), 0,
            "raw (unconverted) eras misclassify the post-boundary turn as era 0 — this is why conversion is mandatory"
        )
    }

    func testEraIndexMapsTurnToContainingEraIncludingExactBoundary() {
        let eras = [self.era(.avCaptureSession, startSeconds: 0), self.era(.voiceProcessing, startSeconds: 30)]
        XCTAssertEqual(MeetingProcessingPipeline.eraIndex(containing: 0, eras: eras), 0)
        XCTAssertEqual(MeetingProcessingPipeline.eraIndex(containing: 15, eras: eras), 0)
        XCTAssertEqual(MeetingProcessingPipeline.eraIndex(containing: 29.999, eras: eras), 0)
        XCTAssertEqual(MeetingProcessingPipeline.eraIndex(containing: 30, eras: eras), 1, "exact boundary belongs to the era that starts there")
        XCTAssertEqual(MeetingProcessingPipeline.eraIndex(containing: 1000, eras: eras), 1)
    }

    func testEraEndRelativeIsNextEraStartOrNilForTheLastEra() {
        let eras = [self.era(.avCaptureSession, startSeconds: 0), self.era(.voiceProcessing, startSeconds: 30)]
        XCTAssertEqual(MeetingProcessingPipeline.eraEndRelative(afterIndex: 0, eras: eras), 30)
        XCTAssertNil(MeetingProcessingPipeline.eraEndRelative(afterIndex: 1, eras: eras))
    }

    // MARK: - Multi-era widening: this must FAIL if any consumer still reads track.captureMethod

    func testWideningAppliesOnlyInsideTheVoiceProcessingEra() {
        let eras = [self.era(.voiceProcessing, startSeconds: 0), self.era(.avCaptureSession, startSeconds: 30)]
        let turns = [
            self.turn(start: 5, end: 8, overlapsRemote: false),   // inside VPIO era
            self.turn(start: 40, end: 42, overlapsRemote: false), // inside AVCapture era
        ]
        let (classified, widened) = MeetingProcessingPipeline.classifyMicrophoneTurns(
            turns, eras: eras, applicationTrackID: nil, segments: [], fallbackSpeakerID: nil
        )
        XCTAssertTrue(classified[0].echoScored, "VPIO-era turn must be widened")
        XCTAssertEqual(widened, [0], "only the VPIO-era turn widens; the AVCapture-era turn is untouched")
        XCTAssertFalse(classified[1].echoScored)
    }

    func testNonVoiceProcessingSingleEraNeverWidens() {
        let eras = [self.era(.avCaptureSession, startSeconds: 0)]
        let turns = [self.turn(start: 0, end: 3)]
        let (classified, widened) = MeetingProcessingPipeline.classifyMicrophoneTurns(
            turns, eras: eras, applicationTrackID: nil, segments: [], fallbackSpeakerID: nil
        )
        XCTAssertTrue(widened.isEmpty)
        XCTAssertFalse(classified[0].echoScored)
    }

    // MARK: - Per-era de-drift

    func testDeDriftCorrectsOnlyWithinItsOwnEraAndLeavesLaterErasRaw() {
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: 0.02, elapsedValidHostSeconds: 300, eligible: true)
        let vpioEra = self.era(.voiceProcessing, startSeconds: 0, clockDrift: drift)
        let avEra = self.era(.avCaptureSession, startSeconds: 30)
        let eras = [vpioEra, avEra]

        let preBoundaryEnd = MeetingProcessingPipeline.eraEndRelative(afterIndex: 0, eras: eras)
        let corrected = MeetingMicrophoneDeDrift.correct(20, era: vpioEra, eraEndRelative: preBoundaryEnd)
        XCTAssertNotEqual(corrected, 20, "materially drifted VPIO era must correct")

        let postEnd = MeetingProcessingPipeline.eraEndRelative(afterIndex: 1, eras: eras)
        let uncorrected = MeetingMicrophoneDeDrift.correct(40, era: avEra, eraEndRelative: postEnd)
        XCTAssertEqual(uncorrected, 40, "AVCapture era is never corrected")

        let outOfSpan = MeetingMicrophoneDeDrift.correct(40, era: vpioEra, eraEndRelative: preBoundaryEnd)
        XCTAssertEqual(outOfSpan, 40)
    }

    func testEraZeroSentinelSwapYieldsFiniteCorrection() {
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: 0.02, elapsedValidHostSeconds: 300, eligible: true)
        var track = self.track(captureMethod: .avCaptureSession)
        track.captureEras = [
            self.era(.voiceProcessing, startSeconds: 0, clockDrift: drift),
            self.era(.avCaptureSession, startSeconds: 100_030),
        ]
        let eras = MeetingProcessingPipeline.microphoneEras(for: track, origin: 100_000)
        var era0 = eras[0]
        XCTAssertEqual(era0.startSeconds, -.infinity)
        // The pipeline swaps the sentinel for the mic anchor before any arithmetic; prove finite.
        era0.startSeconds = 5.0
        let corrected = MeetingMicrophoneDeDrift.correct(
            20, era: era0, eraEndRelative: MeetingProcessingPipeline.eraEndRelative(afterIndex: 0, eras: eras)
        )
        XCTAssertTrue(corrected.isFinite)
        XCTAssertNotEqual(corrected, 20)
    }

    // MARK: - Near-field per-era gate

    func testTwelveDBEraStepProducesZeroCrossEraRejections() {
        let eras = [self.era(.voiceProcessing, startSeconds: 0), self.era(.avCaptureSession, startSeconds: 100)]
        let hotRMS = 0.04
        let quietRMS = hotRMS * pow(10, -12.0 / 20) // 12dB quieter, still above the AVCapture floor
        var turns: [MeetingProcessingPipeline.StagedMicrophoneTurn] = []
        for offset in stride(from: 0.0, to: 20.0, by: 2.0) {
            turns.append(self.turn(start: offset, end: offset + 1, rms: hotRMS))
        }
        for offset in stride(from: 100.0, to: 120.0, by: 2.0) {
            turns.append(self.turn(start: offset, end: offset + 1, rms: quietRMS))
        }
        let kept = MeetingProcessingPipeline.rejectingFarField(turns, eras: eras)
        XCTAssertEqual(kept.count, turns.count, "quiet-but-legit AVCapture-era turns must not be dropped against the hotter VPIO reference")
    }

    func testSubThreeSecondEraFailsOpen() {
        let eras = [self.era(.voiceProcessing, startSeconds: 0), self.era(.avCaptureSession, startSeconds: 100)]
        var turns = [self.turn(start: 0, end: 10, rms: 0.03)]
        turns.append(self.turn(start: 100, end: 100.5, text: "quiet", rms: 0.01))
        turns.append(self.turn(start: 101, end: 101.5, text: "quiet", rms: 0.01))
        let kept = MeetingProcessingPipeline.rejectingFarField(turns, eras: eras)
        XCTAssertEqual(kept.count, turns.count, "an era with <3s usable turns must fail open (no reference to gate against)")
    }

    func testSingleEraFixtureMatchesTodaysMath() {
        let eras = [self.era(.voiceProcessing, startSeconds: 0)]
        let userRMS = 0.0287
        let roomRMS = 0.0023
        var turns: [MeetingProcessingPipeline.StagedMicrophoneTurn] = []
        for offset in stride(from: 0.0, to: 40.0, by: 2.0) {
            turns.append(self.turn(start: offset, end: offset + 1.5, rms: userRMS))
        }
        for offset in stride(from: 100.0, to: 140.0, by: 2.0) {
            turns.append(self.turn(start: offset, end: offset + 1.5, rms: roomRMS))
        }
        let kept = MeetingProcessingPipeline.rejectingFarField(turns, eras: eras)
        XCTAssertTrue(kept.allSatisfy { $0.rms == userRMS }, "single-era gating still rejects the room-audio cluster wholesale")
        XCTAssertEqual(kept.count, 20)
    }

    // MARK: - Tolerant Codable

    func testMultiEraTrackRoundTrips() throws {
        let eras = [
            self.era(.voiceProcessing, startSeconds: 0, clockDrift: MeetingClockDriftRecord(cumulativeAbsorbedSeconds: 0.02, elapsedValidHostSeconds: 60, eligible: true)),
            self.era(.avCaptureSession, startSeconds: 45),
        ]
        let track = self.track(captureMethod: .avCaptureSession, captureEras: eras)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingAudioTrack.self, from: try encoder.encode(track))
        XCTAssertEqual(decoded.captureEras, eras)
    }

    func testLegacyJSONWithoutCaptureErasYieldsSingleEraViaHelper() throws {
        let legacyJSON: [String: Any] = [
            "id": UUID().uuidString,
            "kind": "microphone",
            "sourceIdentifier": "mic",
            "sourceDisplayName": "Mic",
            "timebase": ["startedHostTime": 0, "machTimebaseNumerator": 1, "machTimebaseDenominator": 1],
            "health": ["status": "waiting", "level": 0, "droppedSampleCount": 0],
            "chunks": [],
            "captureMethod": "voiceProcessing",
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let track = try JSONDecoder().decode(MeetingAudioTrack.self, from: data)
        XCTAssertNil(track.captureEras)
        let eras = MeetingProcessingPipeline.microphoneEras(for: track, origin: 0)
        XCTAssertEqual(eras.count, 1)
        XCTAssertEqual(eras[0].method, .voiceProcessing)
    }

    func testUnknownEraMethodIsToleratedBySkippingThatEra() throws {
        let legacyJSON: [String: Any] = [
            "id": UUID().uuidString,
            "kind": "microphone",
            "sourceIdentifier": "mic",
            "sourceDisplayName": "Mic",
            "timebase": ["startedHostTime": 0, "machTimebaseNumerator": 1, "machTimebaseDenominator": 1],
            "health": ["status": "waiting", "level": 0, "droppedSampleCount": 0],
            "chunks": [],
            "captureMethod": "avCaptureSession",
            "captureEras": [
                ["method": "avCaptureSession", "roleAtElection": "unknown", "startSeconds": 0],
                ["method": "someFutureMethodThisBuildDoesNotKnow", "roleAtElection": "unknown", "startSeconds": 30],
                ["method": "voiceProcessing", "roleAtElection": "unknown", "startSeconds": 60],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let track = try JSONDecoder().decode(MeetingAudioTrack.self, from: data)
        let eras = try XCTUnwrap(track.captureEras)
        XCTAssertEqual(eras.count, 2, "the unrecognized era is skipped, not defaulted, and the rest of the session still decodes")
        XCTAssertEqual(eras.map(\.startSeconds), [0, 60])
    }
}
