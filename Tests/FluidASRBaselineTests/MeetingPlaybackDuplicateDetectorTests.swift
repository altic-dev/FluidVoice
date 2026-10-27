#if !TEMPORAL_STANDALONE
@testable import FluidASRBaselineHost
#endif
import Foundation
import XCTest

final class MeetingPlaybackDuplicateDetectorTests: XCTestCase {
    private typealias Detector = MeetingPlaybackDuplicateDetector
    private let session = UUID()
    private func noise(_ n: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<n).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Float(Double(state >> 32) / Double(UInt32.max) - 0.5)
        }
    }

    private func window(
        start: Double = 1,
        lag: Int = 120,
        epoch: UInt64 = 0,
        route: String = "test",
        mode: String = "echo"
    ) -> Detector.Window {
        var reference = self.noise(6000, seed: UInt64(start * 100) + 1)
        if mode == "periodic" { reference = (0..<6000).map { sin(Float($0) * 0.1) } }
        var mic = Array(reference[(1000 - lag)..<(5000 - lag)])
        if mode == "wrong" { mic = self.noise(4000, seed: 92) }
        if mode == "silence" { mic = [Float](repeating: 0, count: 4000) }
        if mode == "doubleTalk" {
            let local = self.noise(4000, seed: 519)
            mic = zip(mic, local).map { $0 + 0.05 * $1 }
        }
        func pcm(_ samples: [Float], _ pts: Double) -> Detector.PCM {
            .init(start: pts, samples: samples, valid: [Bool](repeating: true, count: samples.count))
        }
        return .init(
            sessionID: self.session,
            epoch: epoch,
            routeID: route,
            start: start,
            microphone: pcm(mic, start),
            reference: pcm(reference, start - 0.5),
            mismatchedReference: pcm(self.noise(6000, seed: 982), start - 0.5)
        )
    }

    private func detector() -> Detector {
        var c = Detector.Configuration(); c.budgetSeconds = 10
        return Detector(configuration: c)
    }

    func testLagSignAndRepeatedSupport() throws {
        for lag in [-120, 0, 120] {
            var d = self.detector()
            XCTAssertEqual(d.process(self.window(lag: lag)).state, .duplicateCandidate)
            XCTAssertEqual(d.process(self.window(start: 3, lag: lag)).state, .duplicateCandidate)
            let result = d.process(self.window(start: 5, lag: lag))
            XCTAssertEqual(result.state, .duplicateSupported)
            XCTAssertEqual(try XCTUnwrap(result.microphoneDelaySeconds), Double(lag) / 2000, accuracy: 0.001)
        }
    }

    func testWrongAndPeriodicReferencesDoNotLock() {
        for mode in ["wrong", "periodic", "silence"] {
            var d = self.detector()
            for start in [1.0, 3, 5, 7] {
                XCTAssertNotEqual(d.process(self.window(start: start, mode: mode)).state, .duplicateSupported)
            }
        }
    }

    func testGapEpochAndRouteRequireFreshSupport() {
        for reset in ["gap", "epoch", "route"] {
            var d = self.detector()
            for start in [1.0, 3, 5] {
                _ = d.process(self.window(start: start))
            }
            let result = d.process(self.window(
                start: reset == "gap" ? 9 : 7,
                epoch: reset == "epoch" ? 1 : 0,
                route: reset == "route" ? "new" : "test"
            ))
            XCTAssertEqual(result.state, .duplicateCandidate)
            XCTAssertEqual(result.supportingWindows, 1)
        }
    }

    func testMissingAndMaskedReferenceResetImmediately() {
        for masked in [true, false] {
            var d = self.detector()
            for start in [1.0, 3, 5] {
                _ = d.process(self.window(start: start))
            }
            let w = self.window(start: 7)
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            var mask = w.reference!.valid; mask[200] = false
            let bad = Detector.Window(
                sessionID: self.session,
                epoch: 0,
                routeID: "test",
                start: 7,
                microphone: w.microphone,
                // Fixed test fixture: missing required audio storage or evidence is a setup failure.
                // swiftlint:disable:next force_unwrapping
                reference: masked ? .init(start: 6.5, samples: w.reference!.samples, valid: mask) : nil,
                mismatchedReference: w.mismatchedReference
            )
            XCTAssertEqual(d.process(bad).state, .insufficientEvidence)
            XCTAssertEqual(d.process(self.window(start: 9)).supportingWindows, 1)
        }
    }

    func testReleaseHasNoHoldAndDelayJumpRestarts() {
        var d = self.detector()
        for start in [1.0, 3, 5] {
            _ = d.process(self.window(start: start))
        }
        let released = d.process(self.window(start: 7, mode: "wrong"))
        XCTAssertEqual(released.reason, .released)
        XCTAssertEqual(released.supportingWindows, 0)
        for start in [9.0, 11, 13] {
            _ = d.process(self.window(start: start))
        }
        XCTAssertEqual(d.process(self.window(start: 15, lag: -120)).supportingWindows, 1)
    }

    func testQuietDoubleTalkRemainsAConfoundNotSpeechAbsenceProof() {
        var d = self.detector()
        for start in [1.0, 3, 5] {
            _ = d.process(self.window(start: start))
        }
        XCTAssertEqual(
            d.process(self.window(start: 7, mode: "doubleTalk")).state,
            .duplicateSupported,
            "Temporal match survives quiet local audio: NEVER use this alone to suppress speech"
        )
    }

    func testControlMatchRejectsEvenPerfectCorrelation() {
        var d = self.detector(); let w = self.window()
        let matchingControl = Detector.Window(
            sessionID: self.session,
            epoch: 0,
            routeID: "test",
            start: 1,
            microphone: w.microphone,
            reference: w.reference,
            mismatchedReference: w.reference
        )
        XCTAssertEqual(d.process(matchingControl).reason, .scoredInconclusive)
    }

    func testBudgetDisablesAfterBoundedFailures() {
        final class Clock: @unchecked Sendable {
            let lock = NSLock(); var value = 0.0
            func now() -> Double { self.lock.lock(); defer { lock.unlock() }; self.value += 1; return self.value }
        }
        let clock = Clock()
        var d = Detector(clock: { clock.now() })
        for start in [1.0, 3, 5] {
            XCTAssertEqual(d.process(self.window(start: start)).reason, .overBudget)
        }
        XCTAssertEqual(d.process(self.window(start: 7)).reason, .detectorUnavailable)
        let w = self.window()
        let newSession = Detector.Window(
            sessionID: UUID(),
            epoch: 0,
            routeID: "test",
            start: 1,
            microphone: w.microphone,
            reference: w.reference,
            mismatchedReference: w.mismatchedReference
        )
        XCTAssertEqual(d.process(newSession).reason, .overBudget)
    }

    func testMalformedSamplesAndTimestampsDoNotTrap() {
        let w = self.window()
        for pts in [Double.nan, .infinity, -1, 1e100] {
            var d = self.detector()
            let bad = Detector.Window(
                sessionID: self.session,
                epoch: 0,
                routeID: "test",
                start: pts,
                microphone: w.microphone,
                reference: w.reference,
                mismatchedReference: w.mismatchedReference
            )
            XCTAssertEqual(d.process(bad).state, .insufficientEvidence)
        }
        var d = self.detector(); var samples = w.microphone.samples; samples[4] = .nan
        let bad = Detector.Window(
            sessionID: self.session,
            epoch: 0,
            routeID: "test",
            start: 1,
            microphone: .init(start: 1, samples: samples, valid: w.microphone.valid),
            reference: w.reference,
            mismatchedReference: w.mismatchedReference
        )
        XCTAssertEqual(d.process(bad).reason, .unscoredCoverage)
    }

    func testReferenceSilenceIsInsufficientNotNegativeEvidence() {
        var d = self.detector(); let w = self.window()
        let silent = Detector.PCM(
            start: 0.5,
            samples: [Float](repeating: 0, count: 6000),
            valid: [Bool](repeating: true, count: 6000)
        )
        let input = Detector.Window(
            sessionID: self.session,
            epoch: 0,
            routeID: "test",
            start: 1,
            microphone: w.microphone,
            reference: silent,
            mismatchedReference: w.mismatchedReference
        )
        XCTAssertEqual(d.process(input).reason, .insufficientEnergy)
    }

    func testReferencePTSMovesEstimatedLagInBothDirections() {
        for shift in [-0.02, 0.02] {
            var d = self.detector(); let w = self.window()
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            let padded = [Float](repeating: 0, count: 200) + w.reference!.samples
                + [Float](repeating: 0, count: 200)
            let ref = Detector.PCM(
                start: 0.4 + shift,
                samples: padded,
                valid: [Bool](repeating: true, count: padded.count)
            )
            let input = Detector.Window(
                sessionID: self.session,
                epoch: 0,
                routeID: "test",
                start: 1,
                microphone: w.microphone,
                reference: ref,
                mismatchedReference: w.mismatchedReference
            )
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            XCTAssertEqual(d.process(input).microphoneDelaySeconds!, 0.06 - shift, accuracy: 0.001)
        }
    }

    func testExactLagSpreadBoundaryRetainsSupport() {
        var d = self.detector()
        _ = d.process(self.window(start: 1, lag: 200))
        _ = d.process(self.window(start: 3, lag: 224))
        XCTAssertEqual(d.process(self.window(start: 5, lag: 200)).state, .duplicateSupported)
    }

    func testUnavailableControlIsDistinctFromMissingPlayback() {
        var d = self.detector(); let w = self.window()
        let input = Detector.Window(
            sessionID: self.session,
            epoch: 0,
            routeID: "test",
            start: 1,
            microphone: w.microphone,
            reference: w.reference,
            mismatchedReference: nil
        )
        XCTAssertEqual(d.process(input).reason, .controlUnavailable)
    }
}
