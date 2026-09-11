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
            state = state &* 6364136223846793005 &+ 1
            return Float(Double(state >> 32) / Double(UInt32.max) - 0.5)
        }
    }
    private func window(start: Double = 1, lag: Int = 120, epoch: UInt64 = 0,
                        route: String = "test", mode: String = "echo") -> Detector.Window {
        var reference = noise(6_000, seed: UInt64(start * 100) + 1)
        if mode == "periodic" { reference = (0..<6_000).map { sin(Float($0) * 0.1) } }
        var mic = Array(reference[(1_000 - lag)..<(5_000 - lag)])
        if mode == "wrong" { mic = noise(4_000, seed: 92) }
        if mode == "silence" { mic = [Float](repeating: 0, count: 4_000) }
        if mode == "doubleTalk" {
            let local = noise(4_000, seed: 519)
            mic = zip(mic, local).map { $0 + 0.05 * $1 }
        }
        func pcm(_ samples: [Float], _ pts: Double) -> Detector.PCM {
            .init(start: pts, samples: samples, valid: [Bool](repeating: true, count: samples.count))
        }
        return .init(sessionID: session, epoch: epoch, routeID: route, start: start,
                     microphone: pcm(mic, start), reference: pcm(reference, start - 0.5),
                     mismatchedReference: pcm(noise(6_000, seed: 982), start - 0.5))
    }
    private func detector() -> Detector {
        var c = Detector.Configuration(); c.budgetSeconds = 10
        return Detector(configuration: c)
    }

    func testLagSignAndRepeatedSupport() {
        for lag in [-120, 0, 120] {
            var d = detector()
            XCTAssertEqual(d.process(window(lag: lag)).state, .duplicateCandidate)
            XCTAssertEqual(d.process(window(start: 3, lag: lag)).state, .duplicateCandidate)
            let result = d.process(window(start: 5, lag: lag))
            XCTAssertEqual(result.state, .duplicateSupported)
            XCTAssertEqual(result.microphoneDelaySeconds!, Double(lag) / 2_000, accuracy: 0.001)
        }
    }
    func testWrongAndPeriodicReferencesDoNotLock() {
        for mode in ["wrong", "periodic", "silence"] {
            var d = detector()
            for start in [1.0, 3, 5, 7] {
                XCTAssertNotEqual(d.process(window(start: start, mode: mode)).state, .duplicateSupported)
            }
        }
    }
    func testGapEpochAndRouteRequireFreshSupport() {
        for reset in ["gap", "epoch", "route"] {
            var d = detector()
            for start in [1.0, 3, 5] { _ = d.process(window(start: start)) }
            let result = d.process(window(start: reset == "gap" ? 9 : 7,
                                          epoch: reset == "epoch" ? 1 : 0,
                                          route: reset == "route" ? "new" : "test"))
            XCTAssertEqual(result.state, .duplicateCandidate)
            XCTAssertEqual(result.supportingWindows, 1)
        }
    }
    func testMissingAndMaskedReferenceResetImmediately() {
        for masked in [true, false] {
            var d = detector()
            for start in [1.0, 3, 5] { _ = d.process(window(start: start)) }
            let w = window(start: 7)
            var mask = w.reference!.valid; mask[200] = false
            let bad = Detector.Window(sessionID: session, epoch: 0, routeID: "test", start: 7,
                                      microphone: w.microphone,
                                      reference: masked ? .init(start: 6.5, samples: w.reference!.samples, valid: mask) : nil,
                                      mismatchedReference: w.mismatchedReference)
            XCTAssertEqual(d.process(bad).state, .insufficientEvidence)
            XCTAssertEqual(d.process(window(start: 9)).supportingWindows, 1)
        }
    }
    func testReleaseHasNoHoldAndDelayJumpRestarts() {
        var d = detector()
        for start in [1.0, 3, 5] { _ = d.process(window(start: start)) }
        let released = d.process(window(start: 7, mode: "wrong"))
        XCTAssertEqual(released.reason, .released)
        XCTAssertEqual(released.supportingWindows, 0)
        for start in [9.0, 11, 13] { _ = d.process(window(start: start)) }
        XCTAssertEqual(d.process(window(start: 15, lag: -120)).supportingWindows, 1)
    }
    func testQuietDoubleTalkRemainsAConfoundNotSpeechAbsenceProof() {
        var d = detector()
        for start in [1.0, 3, 5] { _ = d.process(window(start: start)) }
        XCTAssertEqual(d.process(window(start: 7, mode: "doubleTalk")).state, .duplicateSupported,
                       "Temporal match survives quiet local audio: NEVER use this alone to suppress speech")
    }
    func testControlMatchRejectsEvenPerfectCorrelation() {
        var d = detector(); let w = window()
        let matchingControl = Detector.Window(sessionID: session, epoch: 0, routeID: "test", start: 1,
                                             microphone: w.microphone, reference: w.reference,
                                             mismatchedReference: w.reference)
        XCTAssertEqual(d.process(matchingControl).reason, .scoredInconclusive)
    }
    func testBudgetDisablesAfterBoundedFailures() {
        final class Clock: @unchecked Sendable {
            let lock = NSLock(); var value = 0.0
            func now() -> Double { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        }
        let clock = Clock()
        var d = Detector(clock: { clock.now() })
        for start in [1.0, 3, 5] { XCTAssertEqual(d.process(window(start: start)).reason, .overBudget) }
        XCTAssertEqual(d.process(window(start: 7)).reason, .detectorUnavailable)
        let w = window()
        let newSession = Detector.Window(sessionID: UUID(), epoch: 0, routeID: "test", start: 1,
                                         microphone: w.microphone, reference: w.reference, mismatchedReference: w.mismatchedReference)
        XCTAssertEqual(d.process(newSession).reason, .overBudget)
    }
    func testMalformedSamplesAndTimestampsDoNotTrap() {
        let w = window()
        for pts in [Double.nan, .infinity, -1, 1e100] {
            var d = detector()
            let bad = Detector.Window(sessionID: session, epoch: 0, routeID: "test", start: pts,
                                      microphone: w.microphone, reference: w.reference,
                                      mismatchedReference: w.mismatchedReference)
            XCTAssertEqual(d.process(bad).state, .insufficientEvidence)
        }
        var d = detector(); var samples = w.microphone.samples; samples[4] = .nan
        let bad = Detector.Window(sessionID: session, epoch: 0, routeID: "test", start: 1,
                                  microphone: .init(start: 1, samples: samples, valid: w.microphone.valid),
                                  reference: w.reference, mismatchedReference: w.mismatchedReference)
        XCTAssertEqual(d.process(bad).reason, .unscoredCoverage)
    }

    func testReferenceSilenceIsInsufficientNotNegativeEvidence() {
        var d = detector(); let w = window()
        let silent = Detector.PCM(start: 0.5, samples: [Float](repeating: 0, count: 6_000),
                                  valid: [Bool](repeating: true, count: 6_000))
        let input = Detector.Window(sessionID: session, epoch: 0, routeID: "test", start: 1,
                                    microphone: w.microphone, reference: silent,
                                    mismatchedReference: w.mismatchedReference)
        XCTAssertEqual(d.process(input).reason, .insufficientEnergy)
    }

    func testReferencePTSMovesEstimatedLagInBothDirections() {
        for shift in [-0.02, 0.02] {
            var d = detector(); let w = window()
            let padded = [Float](repeating: 0, count: 200) + w.reference!.samples
                + [Float](repeating: 0, count: 200)
            let ref = Detector.PCM(start: 0.4 + shift, samples: padded,
                                    valid: [Bool](repeating: true, count: padded.count))
            let input = Detector.Window(sessionID: session, epoch: 0, routeID: "test", start: 1,
                                        microphone: w.microphone, reference: ref,
                                        mismatchedReference: w.mismatchedReference)
            XCTAssertEqual(d.process(input).microphoneDelaySeconds!, 0.06 - shift, accuracy: 0.001)
        }
    }

    func testExactLagSpreadBoundaryRetainsSupport() {
        var d = detector()
        _ = d.process(window(start: 1, lag: 200))
        _ = d.process(window(start: 3, lag: 224))
        XCTAssertEqual(d.process(window(start: 5, lag: 200)).state, .duplicateSupported)
    }

    func testUnavailableControlIsDistinctFromMissingPlayback() {
        var d = detector(); let w = window()
        let input = Detector.Window(sessionID: session, epoch: 0, routeID: "test", start: 1,
                                    microphone: w.microphone, reference: w.reference, mismatchedReference: nil)
        XCTAssertEqual(d.process(input).reason, .controlUnavailable)
    }
}
