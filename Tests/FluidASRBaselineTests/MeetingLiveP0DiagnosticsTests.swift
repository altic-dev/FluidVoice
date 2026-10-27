import AVFoundation
import CoreMedia
@testable import FluidASRBaselineHost
import Foundation
import XCTest

#if arch(arm64)
final class MeetingLiveP0DiagnosticsTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        func now() -> Double { self.lock.lock(); defer { lock.unlock() }; return self.value }
        func set(_ value: Double) { self.lock.lock(); defer { lock.unlock() }; self.value = value }
    }

    private actor Recognizer: MeetingLiveRecognizer {
        var resets = 0
        var processed = 0
        private let process: @Sendable () throws -> Void
        init(process: @escaping @Sendable () throws -> Void = {}) { self.process = process }
        func prepareModels() async throws { XCTFail("P0 deterministic tests must not load models") }
        func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {}
        func processBufferedAudio() async throws { self.processed += 1; try self.process() }
        func finish() async throws -> String { "" }
        func reset() async { self.resets += 1 }
        func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {}
        func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async {}
    }

    private func sample(at seconds: Double) -> MeetingLiveSampleCopy.Sample {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
        )!
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        buffer.floatChannelData![0].update(repeating: 0, count: 1600)
        return .init(
            buffer: buffer,
            pts: CMTime(seconds: seconds, preferredTimescale: 16_000),
            duration: CMTime(seconds: 0.1, preferredTimescale: 16_000)
        )
    }

    func testExistingWatchdogCannotRotateBeforeFirstPartial() async {
        let clock = Clock()
        let recognizer = Recognizer()
        let engine = MeetingLiveTrackEngine(
            kind: .microphone,
            recognizer: recognizer,
            uptime: { clock.now() },
            diagnosticsEnabled: true
        )
        for index in 0..<400 {
            clock.set(Double(index) / 10)
            await engine.diagnosticConsume(self.sample(at: clock.now()))
        }
        let snapshot = await engine.diagnosticSnapshotValue()
        XCTAssertEqual(snapshot.processCompletions, 400)
        XCTAssertEqual(snapshot.feedSeconds, 40, accuracy: 0.0001)
        XCTAssertEqual(snapshot.partialCallbacks, 0)
        XCTAssertEqual(snapshot.resetInvocations, 0, "Characterizes the P0 blind spot; not desired P1 behavior")
        let resets = await recognizer.resets
        XCTAssertEqual(resets, 0)
    }

    func testLongPhraseDoesNotResetWhileTextGapIsBelowTwoMinutes() async {
        let clock = Clock()
        let recognizer = Recognizer()
        let engine = MeetingLiveTrackEngine(
            kind: .microphone,
            recognizer: recognizer,
            uptime: { clock.now() },
            diagnosticsEnabled: true
        )
        await engine.diagnosticConsume(self.sample(at: 0))
        await engine.diagnosticPartial("synthetic fixture")
        // Advancing audio time alone must not reset an active phrase.
        clock.set(1)
        await engine.diagnosticConsume(self.sample(at: 21))
        var snapshot = await engine.diagnosticSnapshotValue()
        XCTAssertEqual(snapshot.resetInvocations, 0)
        for index in 1...380 {
            clock.set(1 + Double(index) / 10)
            await engine.diagnosticConsume(self.sample(at: 21 + Double(index) / 10))
        }
        snapshot = await engine.diagnosticSnapshotValue()
        XCTAssertEqual(snapshot.processCompletions, 382)
        XCTAssertEqual(snapshot.resetInvocations, 0, "The text gap is still below the recovery timeout")
        XCTAssertNil(snapshot.firstPartialAfterResetSeconds)
        await engine.diagnosticPartial("synthetic resumed fixture")
        snapshot = await engine.diagnosticSnapshotValue()
        XCTAssertNil(snapshot.firstPartialAfterResetSeconds)
        XCTAssertEqual(snapshot.wrapperGeneration, 0)
    }

    func testDiagnosticsCanBeExplicitlyDisabled() async {
        let engine = MeetingLiveTrackEngine(kind: .microphone, recognizer: Recognizer(), diagnosticsEnabled: false)
        await engine.diagnosticConsume(self.sample(at: 0))
        let snapshot = await engine.diagnosticSnapshotValue()
        XCTAssertEqual(snapshot.processStarts, 0)
        XCTAssertEqual(snapshot.convertedBuffers, 0)
    }

    func testProcessLatencyUsesInjectedClockWithoutSleeping() async {
        let clock = Clock()
        let recognizer = Recognizer(process: { clock.set(7) })
        let engine = MeetingLiveTrackEngine(
            kind: .microphone,
            recognizer: recognizer,
            uptime: { clock.now() },
            diagnosticsEnabled: true
        )
        await engine.diagnosticConsume(self.sample(at: 0))
        let snapshot = await engine.diagnosticSnapshotValue()
        XCTAssertEqual(snapshot.appendStarts, 1)
        XCTAssertEqual(snapshot.appendCompletions, 1)
        XCTAssertEqual(snapshot.processStarts, 1)
        XCTAssertEqual(snapshot.processCompletions, 1)
        XCTAssertEqual(snapshot.maxProcessSeconds, 7)
    }

    func testThrownProcessIsNotCountedAsCompletion() async {
        enum FixtureError: Error { case injected }
        let recognizer = Recognizer(process: { throw FixtureError.injected })
        let engine = MeetingLiveTrackEngine(
            kind: .microphone,
            recognizer: recognizer,
            diagnosticsEnabled: true
        )
        await engine.diagnosticConsume(self.sample(at: 0))
        let snapshot = await engine.diagnosticSnapshotValue()
        XCTAssertEqual(snapshot.processStarts, 1)
        XCTAssertEqual(snapshot.processCompletions, 0)
        XCTAssertEqual(snapshot.appendOrProcessErrors, 1)
        XCTAssertEqual(snapshot.resetInvocations, 1)
        XCTAssertEqual(snapshot.recognizerResetReturned, 1, "Completion records return only, not decoder reset success")
    }
}
#endif
