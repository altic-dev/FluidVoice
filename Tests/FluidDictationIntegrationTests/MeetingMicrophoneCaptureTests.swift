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

    // MARK: - Writer-coupled synthetic stamp-sequence test (plan rev #17)

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
