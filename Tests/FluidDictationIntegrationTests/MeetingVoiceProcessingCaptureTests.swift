@testable import FluidVoice_Debug
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import os
import XCTest

/// Hardware/permission-free: ScreenCaptureKit and AVAudioEngine integration paths need live
/// screen-recording/microphone permission and are not exercised here. This covers the pure
/// decision, gate, drift-eligibility, de-drift transform and Codable pieces of Phase 3.
final class MeetingVoiceProcessingCaptureTests: XCTestCase {
    // MARK: - Decision table (incl. role)

    private func mic(uid: String? = "mic-uid", role: MeetingMicrophoneRole = .personal) -> MeetingMicrophoneIdentity {
        MeetingMicrophoneIdentity(captureDeviceID: "dev-1", coreAudioUID: uid, displayName: "Mic", role: role)
    }

    private func viableRoute() -> MeetingOutputRouteSnapshot {
        MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: false, isBuiltIn: true, isHeadphonesDataSource: false)
    }

    func testDecisionSucceedsWhenEveryConditionIsMet() {
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: self.viableRoute())
        XCTAssertEqual(decision, .voiceProcessing)
    }

    func testDecisionDeclinesForInRoomMode() {
        let decision = MeetingCapturePathDecider.decide(mode: .inRoom, microphone: self.mic(), outputRoute: self.viableRoute())
        guard case .screenCaptureKit = decision else { return XCTFail("expected decline") }
    }

    func testDecisionDeclinesWithoutCoreAudioUID() {
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(uid: nil), outputRoute: self.viableRoute())
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("UID"))
    }

    func testDecisionDeclinesWithoutOutputDevice() {
        let route = MeetingOutputRouteSnapshot(deviceExists: false, isBluetooth: false, isBuiltIn: false, isHeadphonesDataSource: false)
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: route)
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("output device"))
    }

    func testDecisionDeclinesForBluetoothOutput() {
        let route = MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: true, isBuiltIn: false, isHeadphonesDataSource: false)
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: route)
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("Bluetooth"))
    }

    func testDecisionDeclinesForNonBuiltInOutput() {
        let route = MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: false, isBuiltIn: false, isHeadphonesDataSource: false)
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: route)
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("built-in"))
    }

    func testDecisionDeclinesForHeadphonesDataSource() {
        let route = MeetingOutputRouteSnapshot(deviceExists: true, isBluetooth: false, isBuiltIn: true, isHeadphonesDataSource: true)
        let decision = MeetingCapturePathDecider.decide(mode: .onlineCall, microphone: self.mic(), outputRoute: route)
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("headphones"))
    }

    func testDecisionSucceedsForPersonalRole() {
        let decision = MeetingCapturePathDecider.decide(
            mode: .onlineCall, microphone: self.mic(role: .personal), outputRoute: self.viableRoute()
        )
        XCTAssertEqual(decision, .voiceProcessing)
    }

    func testDecisionDeclinesForSharedRole() {
        let decision = MeetingCapturePathDecider.decide(
            mode: .onlineCall, microphone: self.mic(role: .shared), outputRoute: self.viableRoute()
        )
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("personal"))
    }

    func testDecisionDeclinesForUnknownRole() {
        let decision = MeetingCapturePathDecider.decide(
            mode: .onlineCall, microphone: self.mic(role: .unknown), outputRoute: self.viableRoute()
        )
        guard case let .screenCaptureKit(reason) = decision else { return XCTFail("expected decline") }
        XCTAssertTrue(reason.contains("personal"))
    }

    // MARK: - Commit gate

    private func makeSampleBuffer(ptsSeconds: Double = 0) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 48_000)
        return meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: pts)!
    }

    func testGateBuffersThenPassesThroughAfterCommit() {
        let gate = MeetingVoiceProcessingCommitGate()
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .buffered)
        let flushed = gate.beginCommitFlush()
        XCTAssertEqual(flushed?.count, 1)
        XCTAssertNil(gate.continueCommitFlush(), "drained ring flips to committed")
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .passthrough)
    }

    func testGateFlushSerializesConcurrentArrivalsBeforePassthrough() {
        let gate = MeetingVoiceProcessingCommitGate()
        XCTAssertEqual(gate.offer(self.makeSampleBuffer(ptsSeconds: 0)), .buffered)
        let first = gate.beginCommitFlush()
        XCTAssertEqual(first?.count, 1)
        // A sample landing mid-flush must queue behind the ring, never overtake it.
        XCTAssertEqual(gate.offer(self.makeSampleBuffer(ptsSeconds: 1)), .buffered)
        let second = gate.continueCommitFlush()
        XCTAssertEqual(second?.count, 1)
        XCTAssertNil(gate.continueCommitFlush())
        XCTAssertEqual(gate.offer(self.makeSampleBuffer(ptsSeconds: 2)), .passthrough)
    }

    func testGateAbortAndTerminalEventsAreNoOpsWhileFlushing() {
        let gate = MeetingVoiceProcessingCommitGate()
        _ = gate.offer(self.makeSampleBuffer())
        _ = gate.beginCommitFlush()
        gate.abort()
        XCTAssertFalse(gate.offerTerminalEventPreCommit())
        XCTAssertNil(gate.continueCommitFlush())
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .passthrough, "a promoted flush can never be aborted back out")
    }

    func testGateAbortsAndSwallowsAfterRingExhaustion() throws {
        // Cap sized to fit exactly one sample's worth of bytes: the second sample must not fit.
        let one = self.makeSampleBuffer()
        let bytes = CMBlockBufferGetDataLength(try XCTUnwrap(CMSampleBufferGetDataBuffer(one)))
        XCTAssertGreaterThan(bytes, 0)
        let gate = MeetingVoiceProcessingCommitGate(ringCapBytes: bytes)
        XCTAssertEqual(gate.offer(one), .buffered)
        XCTAssertEqual(gate.offer(self.makeSampleBuffer(ptsSeconds: 1)), .aborted, "ring-cap exhaustion must abort, never evict-and-commit")
        XCTAssertEqual(gate.offer(self.makeSampleBuffer(ptsSeconds: 2)), .aborted)
        XCTAssertNil(gate.beginCommitFlush(), "an aborted gate can never commit")
    }

    func testGateTerminalEventPreCommitAborts() {
        let gate = MeetingVoiceProcessingCommitGate()
        _ = gate.offer(self.makeSampleBuffer())
        XCTAssertTrue(gate.offerTerminalEventPreCommit())
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .aborted)
        XCTAssertNil(gate.beginCommitFlush())
    }

    func testGateTerminalEventPostCommitIsNotAnAbort() {
        let gate = MeetingVoiceProcessingCommitGate()
        _ = gate.beginCommitFlush()
        XCTAssertNil(gate.continueCommitFlush())
        XCTAssertFalse(gate.offerTerminalEventPreCommit(), "post-commit terminal events are the runtime's normal interrupt path, not a gate abort")
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .passthrough)
    }

    func testGateAbortIsIdempotentAndFinal() {
        let gate = MeetingVoiceProcessingCommitGate()
        gate.abort()
        gate.abort()
        XCTAssertEqual(gate.offer(self.makeSampleBuffer()), .aborted)
        XCTAssertNil(gate.beginCommitFlush())
    }

    // MARK: - Watchdog predicate

    func testWatchdogDoesNotTripBeforeThreshold() {
        XCTAssertFalse(MeetingVoiceProcessingWatchdog.isStalled(secondsSinceLastEmittedBuffer: 9.9))
    }

    func testWatchdogTripsAtThreshold() {
        XCTAssertTrue(MeetingVoiceProcessingWatchdog.isStalled(secondsSinceLastEmittedBuffer: 10))
        XCTAssertTrue(MeetingVoiceProcessingWatchdog.isStalled(secondsSinceLastEmittedBuffer: 30))
    }

    // MARK: - ScreenCaptureKit audio-settings plumbing (rebuild regression)

    func testIncludeMicrophoneFalseAttachesNoMicrophoneDevice() {
        let configuration = SCStreamConfiguration()
        MeetingScreenCaptureAudioSettings.apply(to: configuration, microphone: self.mic(), includeMicrophone: false)
        XCTAssertFalse(configuration.captureMicrophone)
        XCTAssertNil(configuration.microphoneCaptureDeviceID)
    }

    func testIncludeMicrophoneTrueSetsTheRequestedDevice() {
        let configuration = SCStreamConfiguration()
        MeetingScreenCaptureAudioSettings.apply(to: configuration, microphone: self.mic(), includeMicrophone: true)
        XCTAssertTrue(configuration.captureMicrophone)
        XCTAssertEqual(configuration.microphoneCaptureDeviceID, "dev-1")
    }

    // MARK: - Eligibility

    private func makeStats(
        resyncCount: Int = 0,
        resyncClampCount: Int = 0,
        divergenceStepEventCount: Int = 0,
        configurationChangeEvents: Int = 0,
        droppedPostCapCount: Int = 0
    ) -> MeetingMicrophoneCaptureStats.Snapshot {
        var snapshot = MeetingMicrophoneCaptureStats.Snapshot()
        snapshot.resyncCount = resyncCount
        snapshot.resyncClampCount = resyncClampCount
        snapshot.divergenceStepEventCount = divergenceStepEventCount
        snapshot.configurationChangeEvents = configurationChangeEvents
        snapshot.droppedPostCapCount = droppedPostCapCount
        return snapshot
    }

    func testCleanRunIsEligible() {
        XCTAssertTrue(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats()))
    }

    func testMidStreamResetMakesRunIneligible() {
        XCTAssertFalse(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats(resyncCount: 1)))
        XCTAssertFalse(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats(resyncClampCount: 1)))
        XCTAssertFalse(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats(divergenceStepEventCount: 1)))
        XCTAssertFalse(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats(configurationChangeEvents: 1)))
        XCTAssertFalse(MeetingVoiceProcessingDriftSnapshot.isEligible(self.makeStats(droppedPostCapCount: 1)))
    }

    func testElapsedValidHostSecondsFromStats() {
        var snapshot = MeetingMicrophoneCaptureStats.Snapshot()
        snapshot.firstValidHostSeconds = 10
        snapshot.lastValidHostSeconds = 22.5
        XCTAssertEqual(MeetingVoiceProcessingDriftSnapshot.elapsedValidHostSeconds(snapshot), 12.5, accuracy: 1e-9)
    }

    func testElapsedValidHostSecondsIsZeroWithoutBothBounds() {
        XCTAssertEqual(MeetingVoiceProcessingDriftSnapshot.elapsedValidHostSeconds(MeetingMicrophoneCaptureStats.Snapshot()), 0)
    }

    // MARK: - End-to-end de-drift sign

    private func makeTrack(chunkStart: Double, drift: MeetingClockDriftRecord?, captureMethod: MeetingAudioTrackCaptureMethod?) -> MeetingAudioTrack {
        var track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: [MeetingAudioChunk(
                id: UUID(), sequence: 0, relativeFilePath: "x.m4a",
                presentationStart: MeetingMediaTime(value: Int64(chunkStart * 48_000), timescale: 48_000),
                presentationEnd: MeetingMediaTime(value: Int64((chunkStart + 60) * 48_000), timescale: 48_000),
                discontinuities: [], sha256: "x", byteCount: 1, finalizationState: .finalized
            )]
        )
        track.captureMethod = captureMethod
        track.clockDrift = drift
        return track
    }

    /// Era anchored at origin-relative 0, mirroring a single-era track starting at the session origin.
    private func makeEra(drift: MeetingClockDriftRecord?, captureMethod: MeetingAudioTrackCaptureMethod?) -> MeetingCaptureEra {
        MeetingCaptureEra(
            method: captureMethod ?? .avCaptureSession,
            deviceUID: nil,
            deviceName: nil,
            roleAtElection: .unknown,
            startSeconds: 0,
            clockDrift: drift
        )
    }

    /// Drives the REAL clock fast-mic (host elapses SLOWER than frame count — the mirror of
    /// `testSlowDriftNeverFiresTheStepDetector`), then asserts the transform compresses the timeline.
    func testDeDriftCorrectsAFastMicAndTheInverseFormulaFails() {
        var clock = MeetingMicrophonePTSClock(timebase: mach_timebase_info_data_t(numer: 1, denom: 1))
        let ppm = 6.7e-6
        let windowSeconds = 0.1
        let windows = 9_500 // 950s: past the ~12.5min materiality crossover at 6.7ppm
        for i in 0..<windows {
            let hostSeconds = Double(i) * windowSeconds * (1 - ppm) // fast mic: less host time per window
            _ = clock.stamp(hostTime: UInt64(hostSeconds * 1_000_000_000), frameCount: 4_800)
        }
        let elapsed = Double(windows - 1) * windowSeconds * (1 - ppm)
        let cumulative = clock.cumulativeAbsorbedCorrectionSeconds
        XCTAssertLessThan(cumulative, 0, "a fast mic must show a NEGATIVE cumulative absorbed correction")
        XCTAssertGreaterThan(abs(cumulative), MeetingMicrophoneDeDrift.materialityThresholdSeconds)

        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: cumulative, elapsedValidHostSeconds: elapsed, eligible: true)
        let era = self.makeEra(drift: drift, captureMethod: .voiceProcessing)

        let rawEnd = Double(windows) * windowSeconds
        let corrected = MeetingMicrophoneDeDrift.correct(rawEnd, era: era, eraEndRelative: nil)
        XCTAssertLessThan(corrected, rawEnd, "correction must compress the fast timeline toward the reference, not expand it")
        XCTAssertEqual(corrected, rawEnd + cumulative, accuracy: 0.05, "k = 1 + cumulative/elapsed applied against the reference")

        // The v1 sign-bug inverse transform must move the WRONG direction (expand, not compress).
        let fraction = cumulative / elapsed
        let inverseCorrected = rawEnd / (1 + fraction)
        XCTAssertGreaterThan(inverseCorrected, rawEnd, "the inverted formula moves the WRONG direction — expands instead of compresses")
    }

    func testDeDriftIsANoOpWhenIneligible() {
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: -0.05, elapsedValidHostSeconds: 300, eligible: false)
        let era = self.makeEra(drift: drift, captureMethod: .voiceProcessing)
        XCTAssertEqual(MeetingMicrophoneDeDrift.correct(120, era: era, eraEndRelative: nil), 120)
    }

    func testDeDriftIsANoOpForNonVoiceProcessingTracks() {
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: -0.05, elapsedValidHostSeconds: 300, eligible: true)
        let era = self.makeEra(drift: drift, captureMethod: .screenCaptureKit)
        XCTAssertEqual(MeetingMicrophoneDeDrift.correct(120, era: era, eraEndRelative: nil), 120)
    }

    func testDeDriftIsANoOpBelowMaterialityThreshold() {
        // 1ms cumulative over 300s is below the 5ms materiality gate.
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: -0.001, elapsedValidHostSeconds: 300, eligible: true)
        let era = self.makeEra(drift: drift, captureMethod: .voiceProcessing)
        XCTAssertEqual(MeetingMicrophoneDeDrift.correct(120, era: era, eraEndRelative: nil), 120)
    }

    // MARK: - Ring flush pacing

    /// flushBatch's pacing (4 samples / 5ms) against a real writer: a full ~5s ring must not trip backpressure.
    func testPacedRingFlushProducesNoWriterBackpressure() async throws {
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let track = MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: []
        )
        let backpressureCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: sessionDirectory, chunkDuration: 60) { event in
            if case .interrupted(.writerBackpressure, _, _) = event {
                backpressureCount.withLock { $0 += 1 }
            }
        }

        let samples = (0..<50).map { self.makeSampleBuffer(ptsSeconds: Double($0) * 0.1) }
        for (index, sample) in samples.enumerated() {
            writer.enqueue(sample)
            if index % 4 == 3 {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        _ = await writer.stop()
        XCTAssertEqual(backpressureCount.withLock { $0 }, 0)
    }

    // MARK: - Provenance promotion

    func testProvenanceIsPessimisticThenPromotedOnCommit() async throws {
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let track = MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [], captureMethod: .screenCaptureKit
        )
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: sessionDirectory, chunkDuration: 60) { _ in }

        let beforeCommit = await writer.snapshot()
        XCTAssertEqual(beforeCommit.captureMethod, .screenCaptureKit, "pessimistic default before any commit")

        try await writer.updateTrackMetadata { track in
            track.captureMethod = .voiceProcessing
        }
        let afterCommit = await writer.snapshot()
        XCTAssertEqual(afterCommit.captureMethod, .voiceProcessing)
        _ = await writer.stop()
    }

    // MARK: - Codable tolerance

    func testUnknownCaptureMethodRawValueDecodesToNil() throws {
        var track = self.makeTrack(chunkStart: 0, drift: nil, captureMethod: .voiceProcessing)
        track.captureMethod = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(track)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["captureMethod"] = "someFutureCaptureMethodThisBuildDoesNotKnow"
        data = try JSONSerialization.data(withJSONObject: json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingAudioTrack.self, from: data)
        XCTAssertNil(decoded.captureMethod, "an unrecognized raw value must decode to nil, not throw")
    }

    func testPreExistingJSONWithoutCaptureMethodDecodesWithNilFields() throws {
        let track = self.makeTrack(chunkStart: 0, drift: nil, captureMethod: .voiceProcessing)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(track)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "captureMethod")
        json.removeValue(forKey: "voiceProcessingConfig")
        json.removeValue(forKey: "clockDrift")
        data = try JSONSerialization.data(withJSONObject: json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingAudioTrack.self, from: data)
        XCTAssertNil(decoded.captureMethod)
        XCTAssertNil(decoded.voiceProcessingConfig)
        XCTAssertNil(decoded.clockDrift)
    }

    func testCaptureMethodAndDriftRoundTripThroughCodable() throws {
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: -0.02, elapsedValidHostSeconds: 300, eligible: true)
        let track = self.makeTrack(chunkStart: 0, drift: drift, captureMethod: .voiceProcessing)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingAudioTrack.self, from: try encoder.encode(track))
        XCTAssertEqual(decoded.captureMethod, .voiceProcessing)
        XCTAssertEqual(decoded.clockDrift, drift)
    }

    // MARK: - Sheet default mic preselection

    private func identity(_ deviceID: String, uid: String?, role: MeetingMicrophoneRole = .unknown) -> MeetingMicrophoneIdentity {
        MeetingMicrophoneIdentity(captureDeviceID: deviceID, coreAudioUID: uid, displayName: deviceID, role: role)
    }

    func testPreselectionPrefersSystemDefaultOverSavedDevice() {
        let identities = [
            self.identity("saved", uid: "saved-uid", role: .personal),
            self.identity("default", uid: "default-uid"),
        ]
        let selection = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: "saved",
            savedRole: .personal,
            systemDefaultUID: "default-uid",
            preferredInputUID: nil,
            systemDefaultCaptureID: nil
        )
        XCTAssertEqual(selection.deviceID, "default")
        XCTAssertEqual(selection.role, .unknown)
    }

    func testPreselectionReusesSavedRoleOnlyWhenDeviceMatchesSaved() {
        let identities = [self.identity("saved", uid: "saved-uid", role: .personal)]
        let selection = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: "saved",
            savedRole: .personal,
            systemDefaultUID: "saved-uid",
            preferredInputUID: nil,
            systemDefaultCaptureID: nil
        )
        XCTAssertEqual(selection.deviceID, "saved")
        XCTAssertEqual(selection.role, .personal)
    }

    /// System default → preferred input UID → `AVCaptureDevice.default` unique ID → first identity.
    func testPreselectionFallsBackThroughPreferredInputThenCaptureDeviceIDThenFirstIdentity() {
        let identities = [
            self.identity("a", uid: "a-uid"),
            self.identity("b", uid: "b-uid"),
            self.identity("c", uid: nil),
        ]
        let byPreferredInput = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: nil,
            savedRole: .unknown,
            systemDefaultUID: "no-match-uid",
            preferredInputUID: "b-uid",
            systemDefaultCaptureID: "a"
        )
        XCTAssertEqual(byPreferredInput.deviceID, "b", "preferred input UID must win over the AVCaptureDevice.default fallback")

        let byCaptureID = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: nil,
            savedRole: .unknown,
            systemDefaultUID: "no-match-uid",
            preferredInputUID: "no-match-uid",
            systemDefaultCaptureID: "a"
        )
        XCTAssertEqual(byCaptureID.deviceID, "a")

        let byFirst = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: nil,
            savedRole: .unknown,
            systemDefaultUID: "no-match-uid",
            preferredInputUID: "no-match-uid",
            systemDefaultCaptureID: "no-match-id"
        )
        XCTAssertEqual(byFirst.deviceID, "a")
    }

    func testPreselectionWithEmptyIdentitiesReturnsNil() {
        let selection = MeetingMicrophonePreselection.select(
            identities: [],
            savedDeviceID: "saved",
            savedRole: .personal,
            systemDefaultUID: "default-uid",
            preferredInputUID: "preferred-uid",
            systemDefaultCaptureID: "default-id"
        )
        XCTAssertNil(selection.deviceID)
        XCTAssertEqual(selection.role, .unknown)
    }
}
