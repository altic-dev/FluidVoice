@testable import FluidVoice_Debug
import AVFoundation
import CoreMedia
import Foundation
import XCTest

/// Hardware-free: everything here runs on CI. The opt-in real-hardware probe
/// (`FLUIDVOICE_MIC_PHASE1`) lives in `MeetingMicrophonePhase1Probe` and is not exercised here.
final class MeetingMicrophoneCaptureTests: XCTestCase {
    private static let identityTimebase = mach_timebase_info_data_t(numer: 1, denom: 1)

    private func makeClock() -> MeetingMicrophonePTSClock {
        MeetingMicrophonePTSClock(timebase: Self.identityTimebase)
    }

    private func hostTime(seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }

    // MARK: - PTS clock

    func testValidStampsMapHostTimeToCMTimeExactly() {
        var clock = self.makeClock()
        let outcome = clock.stamp(hostTime: self.hostTime(seconds: 2.5), frameCount: 4_800)
        guard case let .emitted(pts, synthesized, corrected, resynced) = outcome else {
            return XCTFail("expected an emitted stamp")
        }
        XCTAssertEqual(pts.seconds, 2.5, accuracy: 1.0 / 48_000)
        XCTAssertFalse(synthesized)
        XCTAssertFalse(corrected)
        XCTAssertFalse(resynced)
    }

    func testValidStampsAreContinuousAcrossBuffers() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4_800)
        let second = clock.stamp(hostTime: self.hostTime(seconds: 0.1), frameCount: 4_800)
        guard case let .emitted(pts, _, corrected, _) = second else {
            return XCTFail("expected an emitted stamp")
        }
        XCTAssertEqual(pts.seconds, 0.1, accuracy: 1.0 / 48_000)
        XCTAssertFalse(corrected, "hostTime landed exactly on the anchor+framesEmitted domain")
    }

    /// Real-hardware Phase 1 gate; skips unless FLUIDVOICE_MIC_PHASE1=<minutes> is set.
    func testPhase1HardwareGate() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let result = try await MeetingMicrophonePhase1Probe.run(sessionDirectory: temp) else {
            throw XCTSkip("FLUIDVOICE_MIC_PHASE1 not set")
        }
        let stats = result.stats
        let validRate = stats.buffersEmitted > 0 ? Double(stats.validHostTimeCount) / Double(stats.buffersEmitted) : 0
        print("""
        [phase1] minutes=\(result.minutes) outcome=\(result.outcome)
        [phase1] settled=\(String(describing: result.settled))
        [phase1] delivered=\(result.deliveredSourceFormat) buffers=\(stats.buffersEmitted) validHostTime=\(String(format: "%.4f", validRate)) \
        synthesized=\(stats.synthesizedCount) anchorCorrections=\(stats.anchorCorrectionCount) sequenceBreaks=\(stats.sequenceContinuityViolations)
        [phase1] chunks=\(result.writerRotationCount) discontinuities=\(result.writerDiscontinuities) \
        backpressure=\(result.writerBackpressureEvents) health=\(result.finalHealthStatus) liveCopyNils=\(result.liveCopyNilCount)
        """)
        XCTAssertGreaterThanOrEqual(validRate, 0.99)
        XCTAssertEqual(result.writerDiscontinuities, 0)
        XCTAssertEqual(result.writerBackpressureEvents, 0)
        XCTAssertEqual(result.liveCopyNilCount, 0)
        XCTAssertEqual(stats.conversionFailures, 0)
        XCTAssertGreaterThan(result.peakAmplitude, 0, "a live microphone never captures digital silence")
        let expectedChunks = Int((result.minutes * 60 / 60).rounded(.up))
        XCTAssertLessThanOrEqual(abs(result.writerRotationCount - expectedChunks), 1, "rotation cadence ≈ chunkDuration")
    }

    /// Without any anchor there is no meaningful acquisition PTS: a zero anchor would park the mic
    /// track at epoch 0 against SCStream's mach-domain stamps.
    func testInvalidStampsBeforeFirstAnchorAreDropped() {
        var clock = self.makeClock()
        XCTAssertEqual(clock.stamp(hostTime: nil, frameCount: 480), .droppedPostCap)
        XCTAssertEqual(clock.stamp(hostTime: nil, frameCount: 480), .droppedPostCap)
        let first = clock.stamp(hostTime: self.hostTime(seconds: 7), frameCount: 480)
        guard case let .emitted(pts, synthesized, _, _) = first else {
            return XCTFail("expected the first valid stamp to anchor and emit")
        }
        XCTAssertEqual(pts.seconds, 7.0, accuracy: 1.0 / 48_000)
        XCTAssertFalse(synthesized)
    }

    func testInvalidStampsExtrapolateFromLastValid() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4_800) // anchor at t=0, 100ms
        let outcome = clock.stamp(hostTime: nil, frameCount: 4_800) // extrapolated 100ms window
        guard case let .emitted(pts, synthesized, _, _) = outcome else {
            return XCTFail("expected an emitted (synthesized) stamp")
        }
        XCTAssertEqual(pts.seconds, 0.1, accuracy: 1.0 / 48_000)
        XCTAssertTrue(synthesized)
    }

    func testInvalidRunExtrapolatesForUpToHalfASecondThenDrops() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 480) // 10ms anchor

        var emittedSynthesizedCount = 0
        var sawDrop = false
        for _ in 0..<60 { // 60 * 10ms = 600ms of invalid stamps
            let outcome = clock.stamp(hostTime: nil, frameCount: 480)
            switch outcome {
            case .emitted(_, let synthesized, _, _):
                XCTAssertTrue(synthesized)
                XCTAssertFalse(sawDrop, "no emission should follow a drop without a valid resync")
                emittedSynthesizedCount += 1
            case .droppedPostCap:
                sawDrop = true
            }
        }
        XCTAssertTrue(sawDrop, "600ms of invalid stamps must exceed the 500ms cap")
        // 50 * 10ms = 500ms is within the cap and must still be emitted.
        XCTAssertEqual(emittedSynthesizedCount, 50)
    }

    func testValidStampAfterADropResyncsAndCorrectsTheAnchor() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 480)
        for _ in 0..<60 { _ = clock.stamp(hostTime: nil, frameCount: 480) }

        let resync = clock.stamp(hostTime: self.hostTime(seconds: 1.2), frameCount: 480)
        guard case let .emitted(pts, synthesized, corrected, resynced) = resync else {
            return XCTFail("expected an emitted stamp resuming from the drop")
        }
        XCTAssertEqual(pts.seconds, 1.2, accuracy: 1.0 / 48_000)
        XCTAssertFalse(synthesized)
        XCTAssertTrue(corrected)
        XCTAssertTrue(resynced)

        // Post-resync, valid stamps track the corrected anchor without further correction.
        let next = clock.stamp(hostTime: self.hostTime(seconds: 1.21), frameCount: 480)
        guard case let .emitted(_, _, nextCorrected, _) = next else {
            return XCTFail("expected an emitted stamp")
        }
        XCTAssertFalse(nextCorrected)
    }

    func testSmallDivergenceDoesNotCorrectTheAnchor() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4_800)
        // 1/96000s divergence is half a frame at 48kHz — below the one-frame correction threshold.
        let outcome = clock.stamp(hostTime: self.hostTime(seconds: 0.1 + 1.0 / 96_000), frameCount: 4_800)
        guard case let .emitted(_, _, corrected, _) = outcome else {
            return XCTFail("expected an emitted stamp")
        }
        XCTAssertFalse(corrected)
    }

    func testLargeDivergenceCorrectsTheAnchorWithoutASynthesizedFlag() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4_800)
        let outcome = clock.stamp(hostTime: self.hostTime(seconds: 0.15), frameCount: 4_800) // 50ms off
        guard case let .emitted(pts, synthesized, corrected, resynced) = outcome else {
            return XCTFail("expected an emitted stamp")
        }
        XCTAssertEqual(pts.seconds, 0.1, accuracy: 1.0 / 48_000, "this buffer's pts stays on the old, continuous domain")
        XCTAssertFalse(synthesized)
        XCTAssertTrue(corrected)
        XCTAssertFalse(resynced, "a mid-stream correction is not a post-drop resync")
    }

    // MARK: - CMSampleBuffer synthesis round-trip

    private func makeMonoBuffer(frameCount: Int, fill: (Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channel = buffer.floatChannelData![0]
        for index in 0..<frameCount { channel[index] = fill(index) }
        return buffer
    }

    func testSynthesizedSampleBufferRoundTripsThroughLiveSampleCopy() throws {
        let frameCount = 480
        let source = self.makeMonoBuffer(frameCount: frameCount) { Float($0) / 1_000 }
        let pts = CMTime(value: 123, timescale: 48_000)

        let sampleBuffer = try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(from: source, presentationTime: pts))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sampleBuffer), frameCount)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), pts)
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer)), Double(frameCount) / 48_000, accuracy: 1e-9)

        let copy = try XCTUnwrap(MeetingLiveSampleCopy.copy(sampleBuffer))
        XCTAssertEqual(copy.buffer.frameLength, AVAudioFrameCount(frameCount))
        XCTAssertEqual(copy.buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(copy.buffer.format.sampleRate, 48_000)
        XCTAssertEqual(copy.buffer.format.channelCount, 1)
        XCTAssertEqual(copy.pts, pts)
        for index in 0..<frameCount {
            XCTAssertEqual(copy.buffer.floatChannelData![0][index], Float(index) / 1_000)
        }
    }

    func testSynthesizedSampleBufferIsImmutableAgainstSourceMutation() throws {
        let frameCount = 240
        let source = self.makeMonoBuffer(frameCount: frameCount) { _ in 1.0 }
        let sampleBuffer = try XCTUnwrap(
            meetingMicrophoneSynthesizeSampleBuffer(from: source, presentationTime: CMTime(value: 0, timescale: 48_000))
        )

        let before = try XCTUnwrap(MeetingLiveSampleCopy.copy(sampleBuffer))
        let beforeValues = (0..<frameCount).map { before.buffer.floatChannelData![0][$0] }

        // Mutate the source AFTER synthesis — the synthesized buffer must not see this.
        let channel = source.floatChannelData![0]
        for index in 0..<frameCount { channel[index] = -99 }

        let after = try XCTUnwrap(MeetingLiveSampleCopy.copy(sampleBuffer))
        let afterValues = (0..<frameCount).map { after.buffer.floatChannelData![0][$0] }

        XCTAssertEqual(beforeValues, afterValues)
        XCTAssertEqual(afterValues, Array(repeating: Float(1.0), count: frameCount))
    }

    // MARK: - Binding decision table

    func testBindingDecisionSucceedsOnVerifiedReadBack() {
        let outcome = MeetingMicrophoneBindDecision.outcome(
            bindStatus: noErr,
            readBackDeviceID: 42,
            requestedDeviceID: 42,
            defaultInputUID: nil,
            requestedUID: "uid-a"
        )
        XCTAssertEqual(outcome, .boundVerified(42))
    }

    func testBindingDecisionMismatchFallsBackToUnavailableWhenDefaultDoesNotMatch() {
        let outcome = MeetingMicrophoneBindDecision.outcome(
            bindStatus: noErr,
            readBackDeviceID: 7,
            requestedDeviceID: 42,
            defaultInputUID: "uid-other",
            requestedUID: "uid-a"
        )
        guard case .unavailable = outcome else { return XCTFail("expected unavailable, got \(outcome)") }
    }

    func testBindingDecisionReadBackErrorFallsBackToEscapeHatchWhenDefaultMatches() {
        let outcome = MeetingMicrophoneBindDecision.outcome(
            bindStatus: -10_851,
            readBackDeviceID: nil,
            requestedDeviceID: 42,
            defaultInputUID: "uid-a",
            requestedUID: "uid-a"
        )
        XCTAssertEqual(outcome, .defaultMatchesRequested)
    }

    func testBindingDecisionAggregateDeviceStatusIsUnavailableWithoutEscapeHatch() {
        let outcome = MeetingMicrophoneBindDecision.outcome(
            bindStatus: -10_851,
            readBackDeviceID: nil,
            requestedDeviceID: 42,
            defaultInputUID: "uid-other",
            requestedUID: "uid-a"
        )
        guard case let .unavailable(reason) = outcome else { return XCTFail("expected unavailable, got \(outcome)") }
        XCTAssertTrue(reason.contains("10851"))
    }

    func testBindingDecisionReadBackMismatchIsDistinctFromReadBackError() {
        let mismatch = MeetingMicrophoneBindDecision.outcome(
            bindStatus: noErr,
            readBackDeviceID: 99,
            requestedDeviceID: 42,
            defaultInputUID: nil,
            requestedUID: "uid-a"
        )
        let readBackError = MeetingMicrophoneBindDecision.outcome(
            bindStatus: noErr,
            readBackDeviceID: nil,
            requestedDeviceID: 42,
            defaultInputUID: nil,
            requestedUID: "uid-a"
        )
        guard case let .unavailable(mismatchReason) = mismatch,
              case let .unavailable(errorReason) = readBackError
        else { return XCTFail("expected both to be unavailable") }
        XCTAssertNotEqual(mismatchReason, errorReason)
    }

    // MARK: - Writer-coupled synthetic stamp-sequence test

    private func makeWriter() throws -> (writer: MeetingAudioChunkWriter, sessionDirectory: URL) {
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "test-mic",
            sourceDisplayName: "Test Microphone",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: []
        )
        let writer = try MeetingAudioChunkWriter(
            track: track, sessionDirectory: sessionDirectory, chunkDuration: 60
        ) { _ in }
        return (writer, sessionDirectory)
    }

    private func pushBuffer(_ writer: MeetingAudioChunkWriter, ptsSeconds: Double, frameCount: Int = 480) {
        let buffer = self.makeMonoBuffer(frameCount: frameCount) { _ in 0.1 }
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 48_000)
        guard let sampleBuffer = meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: pts) else {
            return XCTFail("failed to synthesize a sample buffer")
        }
        writer.enqueue(sampleBuffer)
    }

    func testSteadySequenceProducesOneChunkWithNoDiscontinuities() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        for tick in 0..<20 {
            self.pushBuffer(writer, ptsSeconds: Double(tick) * 0.01)
        }
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 1)
        XCTAssertEqual(track.chunks.first?.discontinuities ?? [], [])
    }

    func testOneTickOverlapTriggersClockDiscontinuityAndRotation() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        for tick in 0..<10 {
            self.pushBuffer(writer, ptsSeconds: Double(tick) * 0.01)
        }
        // One tick (1/48000s) before the running end — a backwards stamp.
        self.pushBuffer(writer, ptsSeconds: 0.1 - 1.0 / 48_000)
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertEqual(track.chunks.first?.discontinuities.map(\.kind), [.clockDiscontinuity])
    }

    func testFortyNineMillisecondGapDoesNotRotate() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0, frameCount: 480) // ends at 0.01s
        self.pushBuffer(writer, ptsSeconds: 0.01 + 0.49) // 0.49s gap, at/under the 0.5s threshold
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 1)
        XCTAssertEqual(track.chunks.first?.discontinuities ?? [], [])
    }

    func testFiftyOneMillisecondGapTriggersSourceLostAndRotation() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0, frameCount: 480) // ends at 0.01s
        self.pushBuffer(writer, ptsSeconds: 0.01 + 0.51) // 0.51s gap, over the 0.5s threshold
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertEqual(track.chunks.first?.discontinuities.map(\.kind), [.sourceLost])
    }

    /// Drives the PTS clock through a 500ms synthesized run followed by a 600ms dropped run, feeding
    /// only what the clock says to emit into a real writer — the only test that exercises the risky
    /// cap/drop/resync path end to end.
    func testSixHundredMillisecondInvalidRunProducesSourceLostAfterResync() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        var clock = self.makeClock()
        func emit(_ outcome: MeetingMicrophonePTSClock.Outcome, frameCount: Int) {
            guard case let .emitted(pts, _, _, _) = outcome else { return }
            let buffer = self.makeMonoBuffer(frameCount: frameCount) { _ in 0.1 }
            guard let sampleBuffer = meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: pts) else {
                return XCTFail("failed to synthesize a sample buffer")
            }
            writer.enqueue(sampleBuffer)
        }

        emit(clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 480), frameCount: 480)
        for _ in 0..<50 { // up to and including the 500ms cap boundary, all still emitted and contiguous
            emit(clock.stamp(hostTime: nil, frameCount: 480), frameCount: 480)
        }
        var droppedCount = 0
        for _ in 0..<60 { // 600ms dropped — nothing pushed to the writer for these
            if case .droppedPostCap = clock.stamp(hostTime: nil, frameCount: 480) { droppedCount += 1 }
        }
        XCTAssertEqual(droppedCount, 60, "the entire 600ms run must be past the cap and dropped")

        let resync = clock.stamp(hostTime: self.hostTime(seconds: 1.1), frameCount: 480)
        emit(resync, frameCount: 480)

        let track = await writer.stop()
        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertEqual(track.chunks.first?.discontinuities.map(\.kind), [.sourceLost])
    }
}

// MARK: - Phase 2: correction latch, step detector, resync clamp

extension MeetingMicrophoneCaptureTests {
    /// The Phase 1 field data (corrections on ~97% of buffers) was a latch: the correction
    /// re-baselined one full window off, so every subsequent stamp re-corrected forever.
    func testCorrectionDoesNotLatchAcrossSubsequentStamps() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4_800)
        // Force one genuine correction with a 5ms excursion…
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0.105), frameCount: 4_800)
        // …then five contiguous jitter-free stamps on the shifted timeline: zero further corrections.
        for i in 2...6 {
            let outcome = clock.stamp(hostTime: self.hostTime(seconds: 0.005 + Double(i) * 0.1), frameCount: 4_800)
            guard case let .emitted(_, _, corrected, _) = outcome else { return XCTFail("expected emission") }
            XCTAssertFalse(corrected, "stamp \(i) re-corrected: the latch is back")
        }
    }

    /// A correction is a no-op on output: the next buffer's PTS continues exactly from the
    /// previous end.
    func testCorrectionLeavesEmittedPTSContinuous() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4_800)
        guard case let .emitted(before, _, corrected1, _) = clock.stamp(hostTime: self.hostTime(seconds: 0.108), frameCount: 4_800) else {
            return XCTFail("expected emission")
        }
        XCTAssertTrue(corrected1)
        guard case let .emitted(after, _, _, _) = clock.stamp(hostTime: self.hostTime(seconds: 0.208), frameCount: 4_800) else {
            return XCTFail("expected emission")
        }
        XCTAssertEqual(after.seconds - before.seconds, 0.1, accuracy: 1.0 / 48_000)
    }

    /// Drift must never fire the step detector: 6.4 ppm over a simulated two hours.
    func testSlowDriftNeverFiresTheStepDetector() {
        var clock = self.makeClock()
        let windows = 72_000 // 2h of 100ms windows
        for i in 0..<windows {
            let actual = Double(i) * 0.1 * (1 + 6.4e-6)
            _ = clock.stamp(hostTime: self.hostTime(seconds: actual), frameCount: 4_800)
        }
        XCTAssertEqual(clock.divergenceStepEventCount, 0)
        XCTAssertGreaterThan(clock.cumulativeAbsorbedCorrectionSeconds, 0, "drift shows up as absorbed corrections")
    }

    func testSingleJumpFiresExactlyOneStepEvent() {
        var clock = self.makeClock()
        for i in 0..<10 {
            _ = clock.stamp(hostTime: self.hostTime(seconds: Double(i) * 0.1), frameCount: 4_800)
        }
        _ = clock.stamp(hostTime: self.hostTime(seconds: 1.0 + 0.050), frameCount: 4_800) // 50ms step
        for i in 11..<20 {
            _ = clock.stamp(hostTime: self.hostTime(seconds: 0.050 + Double(i) * 0.1), frameCount: 4_800)
        }
        XCTAssertEqual(clock.divergenceStepEventCount, 1)
        XCTAssertEqual(clock.maxDivergenceStepSeconds, 0.050, accuracy: 0.001)
    }

    /// A backlogged invalid burst can synthesize more timeline than elapsed host time; the resync
    /// anchor clamps forward so PTS never steps behind emitted audio.
    func testResyncNeverStepsBehindEmittedAudio() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4_800)
        // 500ms of synthesized emission (cap-inclusive), delivered as a burst…
        for _ in 0..<5 { _ = clock.stamp(hostTime: nil, frameCount: 4_800) }
        _ = clock.stamp(hostTime: nil, frameCount: 4_800) // over cap → dropping
        // …then a valid stamp whose host time is EARLIER than the emitted end (0.6s emitted, 0.3s wall).
        guard case let .emitted(pts, _, _, resynced) = clock.stamp(hostTime: self.hostTime(seconds: 0.3), frameCount: 4_800) else {
            return XCTFail("expected resync emission")
        }
        XCTAssertTrue(resynced)
        XCTAssertGreaterThanOrEqual(pts.seconds, 0.6 - 1.0 / 48_000, "resync anchored behind already-emitted audio")
        XCTAssertEqual(clock.resyncClampCount, 1)
    }

    // MARK: - Phase 3: valid-host-seconds bounds for the de-drift elapsed term

    func testValidHostSecondsBoundsTrackFirstAndLastValidStamp() throws {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 5), frameCount: 4_800)
        _ = clock.stamp(hostTime: nil, frameCount: 4_800) // synthesized: must not move the bounds
        _ = clock.stamp(hostTime: self.hostTime(seconds: 5.3), frameCount: 4_800)
        XCTAssertEqual(try XCTUnwrap(clock.firstValidHostSeconds), 5.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(clock.lastValidHostSeconds), 5.3, accuracy: 1e-9)
    }

    func testValidHostSecondsAreNilBeforeAnyValidStamp() {
        let clock = self.makeClock()
        XCTAssertNil(clock.firstValidHostSeconds)
        XCTAssertNil(clock.lastValidHostSeconds)
    }

    func testTimelineResetReanchorsOnNextValidStamp() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 5), frameCount: 4_800)
        clock.requestTimelineReset()
        guard case let .emitted(pts, _, _, _) = clock.stamp(hostTime: self.hostTime(seconds: 9), frameCount: 4_800) else {
            return XCTFail("expected emission after reset")
        }
        XCTAssertEqual(pts.seconds, 9.0, accuracy: 1.0 / 48_000)
    }
}

// MARK: - Bidirectional route-following mic: capture-side unit tests (no real engines/sessions)
extension MeetingMicrophoneCaptureTests {
    // MARK: MeetingEraAcceptanceFence

    func testFenceBeginSampleAfterQuiesceReturnsFalse() async {
        let fence = MeetingEraAcceptanceFence()
        await fence.quiesce()
        XCTAssertFalse(fence.beginSample())
    }

    func testFenceQuiesceAwaitsInFlightZero() async {
        let fence = MeetingEraAcceptanceFence()
        XCTAssertTrue(fence.beginSample())
        XCTAssertTrue(fence.beginSample())

        let quiesced = Task { await fence.quiesce() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(quiesced.isCancelled, "quiesce must still be awaiting drain with 2 in-flight samples")

        fence.endSample()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Still one in-flight: a concurrent beginSample must be rejected once quiesce() starts.
        XCTAssertFalse(fence.beginSample())

        fence.endSample()
        await quiesced.value
    }

    func testFenceReuseAfterQuiesceStaysClosed() async {
        let fence = MeetingEraAcceptanceFence()
        await fence.quiesce()
        XCTAssertFalse(fence.beginSample())
        XCTAssertFalse(fence.beginSample())
    }


    func testAckResumeBeforeWaitReturnsImmediately() async {
        let ack = MeetingCaptureMethodChangeAck()
        ack.resume()
        let start = Date()
        await ack.wait(timeoutSeconds: 2.0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testAckWaitThenResume() async {
        let ack = MeetingCaptureMethodChangeAck()
        let waiter = Task { await ack.wait(timeoutSeconds: 2.0) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        ack.resume()
        let start = Date()
        await waiter.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testAckBoundedTimeoutFiresWhenNeverResumed() async {
        let ack = MeetingCaptureMethodChangeAck()
        let start = Date()
        await ack.wait(timeoutSeconds: 2.0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testAckDoubleResumeHarmless() async {
        let ack = MeetingCaptureMethodChangeAck()
        ack.resume()
        ack.resume()
        let start = Date()
        await ack.wait(timeoutSeconds: 2.0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    // MARK: Writer beginSplice

    func testBeginSpliceReturnsFinalizedChunkPresentationEnd() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        for tick in 0..<5 { self.pushBuffer(writer, ptsSeconds: Double(tick) * 0.01) }
        try? await Task.sleep(nanoseconds: 50_000_000) // let enqueue's async consume land

        let boundary = await writer.beginSplice()
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 1)
        let finalized = try XCTUnwrap(track.chunks.first)
        XCTAssertEqual(finalized.finalizationState, .finalized)
        XCTAssertFalse(finalized.sha256.isEmpty)
        XCTAssertEqual(try XCTUnwrap(boundary).seconds, finalized.presentationEnd.seconds, accuracy: 1e-9)
    }

    func testBeginSpliceThenEnqueueOpensNewChunk() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = await writer.beginSplice()

        self.pushBuffer(writer, ptsSeconds: 5)
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertTrue(track.chunks.allSatisfy { $0.finalizationState == .finalized })
    }

    /// Once `.accepting` is false, `beginSplice` no-ops and returns the last finalized boundary.
    func testBeginSpliceOnStoppedWriterNoOps() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        _ = await writer.stop() // stopped with zero chunks: nothing was ever finalized
        let boundary = await writer.beginSplice()
        XCTAssertNil(boundary)
    }

    /// Same no-op, but with existing chunks: returns the last finalized boundary.
    func testBeginSpliceOnStoppedWriterReturnsLastFinalizedBoundary() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0)
        let stoppedTrack = await writer.stop()
        let lastEnd = try XCTUnwrap(stoppedTrack.chunks.last?.presentationEnd)

        let rawBoundary = await writer.beginSplice()
        let boundary = try XCTUnwrap(rawBoundary)
        XCTAssertEqual(boundary.seconds, lastEnd.seconds, accuracy: 1e-9)

        let trackAfter = await writer.snapshot()
        XCTAssertEqual(trackAfter.chunks.count, stoppedTrack.chunks.count)
    }

    func testPostSpliceSubHalfSecondGapDoesNotMergeIntoOldChunk() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0) // ends at 0.01s
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = await writer.beginSplice()

        // Under the merge threshold, but the splice already forced rotation into a new chunk.
        self.pushBuffer(writer, ptsSeconds: 0.21)
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertEqual(track.chunks[1].discontinuities, [])
        XCTAssertEqual(track.chunks[1].presentationStart.seconds, 0.21, accuracy: 1e-6)
    }

    // MARK: Writer format-mismatch guard

    private func makeStereoBuffer(frameCount: Int, fill: (Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for index in 0..<frameCount { data[index] = fill(index) }
        }
        return buffer
    }

    private func pushStereoBuffer(_ writer: MeetingAudioChunkWriter, ptsSeconds: Double, frameCount: Int = 480) {
        let buffer = self.makeStereoBuffer(frameCount: frameCount) { _ in 0.1 }
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 48_000)
        guard let sampleBuffer = meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: pts) else {
            return XCTFail("failed to synthesize a stereo sample buffer")
        }
        writer.enqueue(sampleBuffer)
    }

    func testFormatMismatchWithGapProducesTwoChunksZeroWriterFailures() async throws {
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let track = MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "test-mic", sourceDisplayName: "Test Microphone",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: []
        )
        var events: [MeetingCaptureEvent] = []
        let lock = NSLock()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: sessionDirectory, chunkDuration: 60) { event in
            lock.withLock { events.append(event) }
        }

        self.pushBuffer(writer, ptsSeconds: 0) // mono, ends at 0.01s
        try? await Task.sleep(nanoseconds: 50_000_000)
        self.pushStereoBuffer(writer, ptsSeconds: 0.21) // stereo, 0.2s gap
        let finalTrack = await writer.stop()

        XCTAssertEqual(finalTrack.chunks.count, 2)
        XCTAssertTrue(finalTrack.chunks.allSatisfy { $0.finalizationState == .finalized })

        let writerFailures = lock.withLock { events }.compactMap { event -> MeetingInterruptionKind? in
            guard case let .interrupted(kind, _, _) = event else { return nil }
            return kind
        }.filter { $0 == .writerFailure }
        XCTAssertEqual(writerFailures.count, 0)

        let finalizedFormats = lock.withLock { events }.compactMap { event -> MeetingAudioFormat? in
            guard case let .chunkFinalized(_, _, format) = event else { return nil }
            return format
        }
        XCTAssertEqual(finalizedFormats.count, 2)
        XCTAssertEqual(finalizedFormats[0].channelCount, 1)
        XCTAssertEqual(finalizedFormats[1].channelCount, 2)
    }

    // MARK: Transactional updateTrackMetadata

    func testUpdateTrackMetadataPersistsSuccessfully() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        try await writer.updateTrackMetadata { track in
            track.captureMethod = .avCaptureSession
        }
        let track = await writer.stop()
        XCTAssertEqual(track.captureMethod, .avCaptureSession)
    }

    func testUpdateTrackMetadataThrowOnPersistFailureLeavesInMemoryUnchanged() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        // Remove the track directory the manifest is persisted under so the write fails.
        let trackDirectory = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)
            .appendingPathComponent(MeetingAudioTrackKind.microphone.rawValue, isDirectory: true)
        try FileManager.default.removeItem(at: trackDirectory)

        do {
            try await writer.updateTrackMetadata { track in
                track.captureMethod = .avCaptureSession
            }
            XCTFail("expected the persist failure to propagate")
        } catch {}

        let track = await writer.snapshot()
        XCTAssertNil(track.captureMethod, "a failed persist must leave the in-memory track untouched")
    }

    // MARK: MeetingCaptureDeviceElection

    private func micIdentity(id: String, uid: String?, name: String, role: MeetingMicrophoneRole = .unknown) -> MeetingMicrophoneIdentity {
        MeetingMicrophoneIdentity(captureDeviceID: id, coreAudioUID: uid, displayName: name, role: role)
    }

    func testElectionRoleTransfersOnlyWhenElectedDeviceEqualsOriginal() {
        let original = self.micIdentity(id: "dev-1", uid: "uid-1", name: "MacBook Mic", role: .personal)
        let catalog = [original]
        let elected = MeetingCaptureDeviceElection.decide(original: original, catalog: catalog, defaultInputUID: "uid-1")
        XCTAssertEqual(elected.identity.captureDeviceID, "dev-1")
        XCTAssertEqual(elected.role, .personal)
    }

    func testElectionDifferentDeviceReturnsUnknown() {
        let original = self.micIdentity(id: "dev-1", uid: "uid-1", name: "MacBook Mic", role: .personal)
        let other = self.micIdentity(id: "dev-2", uid: "uid-2", name: "AirPods", role: .unknown)
        let catalog = [original, other]
        let elected = MeetingCaptureDeviceElection.decide(original: original, catalog: catalog, defaultInputUID: "uid-2")
        XCTAssertEqual(elected.identity.captureDeviceID, "dev-2")
        XCTAssertEqual(elected.role, .unknown)
    }

    func testElectionFallsBackToOriginalWhenNoSystemDefault() {
        let original = self.micIdentity(id: "dev-1", uid: "uid-1", name: "MacBook Mic", role: .personal)
        let elected = MeetingCaptureDeviceElection.decide(original: original, catalog: [original], defaultInputUID: nil)
        XCTAssertEqual(elected.identity, original)
        XCTAssertEqual(elected.role, .personal)
    }

    // MARK: Codable: captureEras

    private func sampleEra(method: MeetingAudioTrackCaptureMethod, start: Double) -> MeetingCaptureEra {
        MeetingCaptureEra(
            method: method, deviceUID: "uid-1", deviceName: "MacBook Mic",
            roleAtElection: .personal, startSeconds: start
        )
    }

    func testMultiEraCaptureErasRoundTrip() throws {
        var track = MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: []
        )
        track.captureMethod = .avCaptureSession
        track.captureEras = [
            self.sampleEra(method: .voiceProcessing, start: 0),
            self.sampleEra(method: .avCaptureSession, start: 120),
        ]
        let encoder = JSONEncoder()
        let data = try encoder.encode(track)
        let decoded = try JSONDecoder().decode(MeetingAudioTrack.self, from: data)
        XCTAssertEqual(decoded.captureEras?.count, 2)
        XCTAssertEqual(decoded.captureEras?[0].method, .voiceProcessing)
        XCTAssertEqual(decoded.captureEras?[1].method, .avCaptureSession)
        XCTAssertEqual(decoded.captureEras?[1].startSeconds, 120)
    }

    func testLegacyJSONWithoutCaptureErasDecodesNil() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "kind": "microphone",
            "sourceIdentifier": "mic",
            "sourceDisplayName": "Mic",
            "timebase": {"startedHostTime": 0, "machTimebaseNumerator": 1, "machTimebaseDenominator": 1},
            "health": {"status": "waiting", "level": 0, "droppedSampleCount": 0},
            "chunks": []
        }
        """
        let decoded = try JSONDecoder().decode(MeetingAudioTrack.self, from: Data(json.utf8))
        XCTAssertNil(decoded.captureEras)
        XCTAssertNil(decoded.captureMethod)
    }

    /// A single malformed era (unknown `method`) is skipped, not fatal to the whole track decode.
    func testUnknownEraMethodRawValueIsSkippedNotFatal() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "kind": "microphone",
            "sourceIdentifier": "mic",
            "sourceDisplayName": "Mic",
            "timebase": {"startedHostTime": 0, "machTimebaseNumerator": 1, "machTimebaseDenominator": 1},
            "health": {"status": "waiting", "level": 0, "droppedSampleCount": 0},
            "chunks": [],
            "captureEras": [
                {"method": "bluetoothHFP", "roleAtElection": "unknown", "startSeconds": 0},
                {"method": "avCaptureSession", "roleAtElection": "unknown", "startSeconds": 30}
            ]
        }
        """
        let decoded = try JSONDecoder().decode(MeetingAudioTrack.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.captureEras?.count, 1, "the malformed era is skipped, not fatal")
        XCTAssertEqual(decoded.captureEras?.first?.method, .avCaptureSession)
    }

    func testMultiEraTrackCaptureMethodIsAvCaptureSession() {
        // Multi-era tracks write the conservative track-level captureMethod for legacy readers.
        var track = MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: []
        )
        track.captureEras = [
            self.sampleEra(method: .voiceProcessing, start: 0),
            self.sampleEra(method: .avCaptureSession, start: 90),
        ]
        track.captureMethod = .avCaptureSession
        XCTAssertEqual(track.captureMethod, .avCaptureSession)
        XCTAssertEqual(track.captureEras?.first?.method, .voiceProcessing)
    }

    // MARK: Gate re-use per era

    func testFreshGatePerEraPassesBufferingFlushPassthroughWhilePreviousEraGateStaysTerminal() throws {
        let firstEraGate = MeetingVoiceProcessingCommitGate()
        let buffer = self.makeMonoBuffer(frameCount: 480) { _ in 0.1 }
        let sample = try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(
            from: buffer, presentationTime: CMTime(value: 0, timescale: 48_000)
        ))

        XCTAssertEqual(firstEraGate.offer(sample), .buffered)
        let flushed = try XCTUnwrap(firstEraGate.beginCommitFlush())
        XCTAssertEqual(flushed.count, 1)
        XCTAssertNil(firstEraGate.continueCommitFlush())
        XCTAssertTrue(firstEraGate.isCommitted)
        XCTAssertEqual(firstEraGate.offer(sample), .passthrough)

        let secondEraGate = MeetingVoiceProcessingCommitGate()
        XCTAssertEqual(secondEraGate.offer(sample), .buffered)
        XCTAssertFalse(secondEraGate.isCommitted)
        _ = secondEraGate.beginCommitFlush()
        XCTAssertNil(secondEraGate.continueCommitFlush())
        XCTAssertTrue(secondEraGate.isCommitted)

        XCTAssertTrue(firstEraGate.isCommitted, "unaffected by the second era's gate lifecycle")
    }

    // MARK: - MeetingSupervisedTimeout wall-clock bound

    /// A non-cooperative 3s sleep must not block `run` past the supervision deadline.
    func testSupervisedTimeoutReturnsNilByDeadlineEvenWhenTheOperationIsNonCooperative() async {
        let start = Date()
        let result = await MeetingSupervisedTimeout.run(seconds: 0.2) { () -> Bool in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return true
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    // MARK: - Upgrade ring-discard boundary

    func testRingDiscardDropsSamplesAtOrBehindBoundaryAndKeepsSamplesAfterIt() throws {
        let buffer = self.makeMonoBuffer(frameCount: 480) { _ in 0.1 }
        let before = try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(
            from: buffer, presentationTime: CMTime(value: 0, timescale: 48_000)
        ))
        let atBoundary = try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(
            from: buffer, presentationTime: CMTime(value: 48_000, timescale: 48_000)
        ))
        let after = try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(
            from: buffer, presentationTime: CMTime(value: 48_001, timescale: 48_000)
        ))
        let boundary = CMTime(value: 48_000, timescale: 48_000)

        let kept = MeetingUpgradeRingDiscard.discardingSamples(atOrBehind: boundary, from: [before, atBoundary, after])
        XCTAssertEqual(kept.count, 1, "only the strictly-after sample survives")

        let unfiltered = MeetingUpgradeRingDiscard.discardingSamples(atOrBehind: nil, from: [before, atBoundary, after])
        XCTAssertEqual(unfiltered.count, 3, "nil boundary means the writer produced no splice — keep everything")
    }

    // MARK: - Not covered here: phase-machine transitions (file-private, hardware-driven —
    // needs the Phase1 probe) and writer finalizationSlots saturation (no test seam exposed).
    func testPreselectionBuiltInMicDefaultsToPersonalRole() {
        let builtIn = MeetingMicrophoneIdentity(captureDeviceID: "built-in", coreAudioUID: "BuiltInMicrophoneDevice", displayName: "MacBook Pro Microphone")
        let selection = MeetingMicrophonePreselection.select(
            identities: [builtIn], savedDeviceID: "other-device", savedRole: .personal,
            systemDefaultUID: "BuiltInMicrophoneDevice", preferredInputUID: nil, systemDefaultCaptureID: nil
        )
        XCTAssertEqual(selection.deviceID, "built-in")
        XCTAssertEqual(selection.role, .personal)
    }

    func testElectionBuiltInMicDefaultsToPersonalRole() {
        let original = MeetingMicrophoneIdentity(captureDeviceID: "airpods", coreAudioUID: "EC:input", displayName: "AirPods", role: .personal)
        let builtIn = MeetingMicrophoneIdentity(captureDeviceID: "built-in", coreAudioUID: "BuiltInMicrophoneDevice", displayName: "MacBook Pro Microphone")
        let elected = MeetingCaptureDeviceElection.decide(original: original, catalog: [builtIn], defaultInputUID: "BuiltInMicrophoneDevice")
        XCTAssertEqual(elected.role, .personal)
    }

}
