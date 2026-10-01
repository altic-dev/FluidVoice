import AVFoundation
import Combine
@testable import FluidVoice_Debug
import QuartzCore
import XCTest

final class PillTransportTests: XCTestCase {
    private let samples: [Float] = (0..<160).map { index in
        let phase = 2.0 * Double.pi * 700.0 * Double(index) / 16_000.0
        return Float(0.1 * sin(phase))
    }

    func testStartStopStartReplacementAndStaleResults() async throws {
        let pipeline = PillSpectrumPipeline()
        pipeline.setVisible(true)
        pipeline.begin(session: 1, attempt: 1)
        pipeline.offer(self.samples, sampleRate: 16_000, hostTime: 111, discontinuity: false)
        try await Task.sleep(for: .milliseconds(50))
        let first = try XCTUnwrap(pipeline.latest())
        XCTAssertEqual(first.session, 1)
        XCTAssertEqual(first.attempt, 1)
        XCTAssertEqual(first.captureHostTime, 111)
        pipeline.end()
        XCTAssertNil(pipeline.latest())
        pipeline.begin(session: 1, attempt: 2) // device/attempt replacement within session
        XCTAssertNil(pipeline.latest())
        pipeline.offer(self.samples, sampleRate: 48_000, hostTime: 222, discontinuity: true)
        try await Task.sleep(for: .milliseconds(50))
        let replacement = try XCTUnwrap(pipeline.latest())
        XCTAssertEqual(replacement.attempt, 2)
        XCTAssertEqual(replacement.captureHostTime, 222)
        XCTAssertNotEqual(replacement.epoch, first.epoch)
        XCTAssertTrue(replacement.discontinuity)
        pipeline.setVisible(false) // stop-to-loading invalidates in-flight publication
        XCTAssertNil(pipeline.latest())
        pipeline.end()
        pipeline.begin(session: 2, attempt: 3)
        pipeline.setVisible(true)
        pipeline.offer([Float](repeating: 0, count: 512), sampleRate: 16_000, hostTime: 333, discontinuity: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(pipeline.latest()?.amplitudes, .zero)
        XCTAssertEqual(pipeline.latest()?.session, 2)
        pipeline.end()
    }

    func testBoundedWorkerWithStalledReader() async throws {
        let pipeline = PillSpectrumPipeline()
        pipeline.setVisible(true)
        pipeline.begin(session: 6, attempt: 7)
        // Thousands of packets while the UI does not read. One immutable latest result.
        for index in 0..<10_000 {
            pipeline.offer(self.samples, sampleRate: 16_000, hostTime: UInt64(index), discontinuity: false)
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(pipeline.droppedPackets, 0)
        let frame = try XCTUnwrap(pipeline.latest())
        XCTAssertEqual(frame.session, 6)
        XCTAssertTrue((0..<8).allSatisfy { frame.amplitudes[$0].isFinite })
        pipeline.end()
        XCTAssertNil(pipeline.latest())
    }

    @MainActor
    func testPresentationLatencyAndSilenceSettling() async throws {
        let pipeline = PillSpectrumPipeline.shared
        let presentation = PillMeterPresentation()
        pipeline.setVisible(true)
        pipeline.begin(session: 10, attempt: 10)
        presentation.start(count: 6, sensitivity: 0.4)
        defer { presentation.stop(); pipeline.end(); pipeline.setVisible(false) }
        for _ in 0..<120 {
            pipeline.offer(self.samples, sampleRate: 16_000, hostTime: mach_absolute_time(), discontinuity: false)
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(presentation.levels.max() ?? 0, 0.6)
        let latencies = presentation.presentationLatencies.sorted()
        XCTAssertGreaterThan(latencies.count, 30)
        let p95 = latencies[Int(Double(latencies.count - 1) * 0.95)]
        print("PILL_PRESENTATION available_frame_to_tick_p95_ms=\(p95) n=\(latencies.count)")
        XCTAssertLessThan(p95, 34)
        for _ in 0..<100 {
            pipeline.offer([Float](repeating: 0, count: 160), sampleRate: 16_000, hostTime: mach_absolute_time(), discontinuity: false)
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(presentation.levels, [Double](repeating: 0, count: 6))
    }

    func testOrdinaryWorkerBatchingPreservesEveryAcceptedPacket() async throws {
        let pipeline = PillSpectrumPipeline()
        pipeline.setVisible(true)
        pipeline.begin(session: 21, attempt: 1)
        let source = (0..<640).map { Float(0.1 * sin(2 * Double.pi * 700 * Double($0) / 16_000)) }
        pipeline.offer(Array(source[0..<160]), sampleRate: 16_000, hostTime: mach_absolute_time(), discontinuity: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNotNil(pipeline.latest())
        pipeline.withWorkerPausedForTesting {
            for start in stride(from: 160, to: 640, by: 160) {
                pipeline.offer(Array(source[start..<(start + 160)]), sampleRate: 16_000, hostTime: mach_absolute_time(), discontinuity: false)
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        let frame = try XCTUnwrap(pipeline.latest())
        let expected = source.withUnsafeBufferPointer { PillSpectrumAnalyzer().analyze($0) }
        XCTAssertFalse(frame.discontinuity, "Ordinary queued packets must not be treated as lost audio")
        XCTAssertEqual(frame.sequence, 4)
        for band in 0..<8 {
            XCTAssertEqual(frame.amplitudes[band], expected.amplitudes[band], accuracy: 0.000_001)
        }
        XCTAssertEqual(frame.rms, expected.rms, accuracy: 0.000_001)
        pipeline.end()
    }

    @MainActor
    func testVisualizationGapDoesNotFlashAllBarsToDots() async throws {
        let pipeline = PillSpectrumPipeline.shared
        let presentation = PillMeterPresentation()
        pipeline.setVisible(true)
        pipeline.begin(session: 22, attempt: 1)
        presentation.start(count: 6, sensitivity: 0.01)
        defer { presentation.stop(); pipeline.end(); pipeline.setVisible(false) }
        for _ in 0..<35 {
            pipeline.offer(self.samples, sampleRate: 16_000, hostTime: mach_absolute_time(), discontinuity: false)
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = try XCTUnwrap(presentation.levels.max())
        XCTAssertGreaterThan(before, 0.6)
        var published: [Double] = []
        let observation = presentation.$levels.dropFirst().sink { published.append($0.max() ?? 0) }
        pipeline.offer(self.samples, sampleRate: 16_000, hostTime: mach_absolute_time(), discontinuity: true)
        try await Task.sleep(for: .milliseconds(50))
        observation.cancel()
        XCTAssertFalse(published.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(published.min()), before * 0.4)
        pipeline.end()
        pipeline.begin(session: 23, attempt: 2)
        XCTAssertFalse(presentation.levelsAreCurrent, "The renderer must hide old heights even before its next tick")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(presentation.levels, [Double](repeating: 0, count: 6), "New attempts still discard all old visual state")
    }

    @MainActor
    func testPresentationArmsBeforeControllerVisibilityAndWakesOnSpeech() async throws {
        let pipeline = PillSpectrumPipeline()
        let presentation = PillMeterPresentation(pipeline: pipeline)
        presentation.start(count: 6, sensitivity: 0.01)
        defer { presentation.stop(); pipeline.end(); pipeline.setVisible(false) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(presentation.levels, [Double](repeating: 0, count: 6))
        pipeline.setVisible(true)
        pipeline.begin(session: 30, attempt: 1)
        for _ in 0..<20 {
            pipeline.offer(self.samples, sampleRate: 16_000, hostTime: mach_absolute_time(), discontinuity: false)
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(presentation.levels.max() ?? 0, 0.6)
        pipeline.setVisible(false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(presentation.levels, [Double](repeating: 0, count: 6))
    }

    @MainActor
    func testReleasedPresentationInvalidatesItsRunLoopTimer() async throws {
        let pipeline = PillSpectrumPipeline()
        var presentation: PillMeterPresentation? = PillMeterPresentation(pipeline: pipeline)
        presentation?.start(count: 6, sensitivity: 0.01)
        let timer = try XCTUnwrap(presentation?.timerForTesting)
        weak var released = presentation
        presentation = nil
        XCTAssertNil(released)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(timer.isValid, "The run loop must not retain a repeating orphan timer")
    }

    @MainActor
    func testTranscriptionPCMIdenticalWithVisualizationOnAndOff() {
        for rate in [16_000.0, 44_100, 48_000] {
            for fallback in [false, true] {
                let packets = (0..<12).map { packet in
                    (0..<480).map { Float(sin(Double(packet * 480 + $0) * 0.03) * 0.1) }
                }
                let off = ASRService.acceptedPCMForPillTesting(packets, sampleRate: rate, fallback: fallback, visualization: false)
                let on = ASRService.acceptedPCMForPillTesting(packets, sampleRate: rate, fallback: fallback, visualization: true)
                XCTAssertFalse(off.isEmpty)
                XCTAssertEqual(on, off, "Every accepted sample, count, and order must match for rate \(rate), fallback=\(fallback)")
                if rate == 16_000 {
                    XCTAssertEqual(on, packets.flatMap { $0 })
                }
            }
        }
    }
}
