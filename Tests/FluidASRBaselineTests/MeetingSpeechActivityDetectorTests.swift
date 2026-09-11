@testable import FluidASRBaselineHost
import Foundation
import XCTest

final class MeetingSpeechActivityDetectorTests: XCTestCase {
    private struct Fake: MeetingSpeechActivityFrameModel {
        var p: Float
        var probabilityOnReset: Float = 0.1
        mutating func probability(samples: [Float], reset: Bool) throws -> Float {
            reset ? probabilityOnReset : p
        }
    }
    private let session = UUID()
    private let samples = [Float](repeating: 0.1, count: 4096)
    private let valid = [Bool](repeating: true, count: 4096)

    func testWarmupThenMeasuredActivity() {
        var detector = MeetingSpeechActivityDetector(model: Fake(p: 0.9))
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 0, session: session, epoch: 0, route: "a").unknown, .contextWarmup)
        let result = detector.process(samples: samples, valid: valid, start: 0.256, session: session, epoch: 0, route: "a")
        XCTAssertEqual(result.active, true); XCTAssertEqual(result.probability, 0.9)
    }
    func testMasksAndGapRequireWarmupAgain() {
        var detector = MeetingSpeechActivityDetector(model: Fake(p: 0.9))
        _ = detector.process(samples: samples, valid: valid, start: 0, session: session, epoch: 0, route: "a")
        var masked = valid; masked[10] = false
        XCTAssertEqual(detector.process(samples: samples, valid: masked, start: 0.256, session: session, epoch: 0, route: "a").unknown, .unscoredCoverage)
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 0.512, session: session, epoch: 0, route: "a").unknown, .contextWarmup)
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 2, session: session, epoch: 0, route: "a").unknown, .contextWarmup)
    }
    func testEpochAndRouteReset() {
        var detector = MeetingSpeechActivityDetector(model: Fake(p: 0.9))
        _ = detector.process(samples: samples, valid: valid, start: 0, session: session, epoch: 0, route: "a")
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 0.256, session: session, epoch: 1, route: "a").unknown, .contextWarmup)
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 0.512, session: session, epoch: 1, route: "b").unknown, .contextWarmup)
    }
    func testNaNAndPartialFramesAreUnavailable() {
        var detector = MeetingSpeechActivityDetector(model: Fake(p: .nan, probabilityOnReset: .nan))
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 0, session: session, epoch: 0, route: "a").unknown, .modelFailure)
        XCTAssertEqual(detector.process(samples: [0.1], valid: [true], start: 0.256, session: session, epoch: 0, route: "a").unknown, .invalidInput)
    }
    func testCancellationBeforeAndAfterPrediction() {
        var detector = MeetingSpeechActivityDetector(model: Fake(p: 0.9))
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 0, session: session, epoch: 0, route: "a", cancelled: { true }).unknown, .cancelled)
        var calls = 0
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 0.256, session: session, epoch: 0, route: "a", cancelled: { calls += 1; return calls > 1 }).unknown, .cancelled)
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 0.512, session: session, epoch: 0, route: "a").unknown, .contextWarmup)
    }
    func testBudgetFailuresDisableContribution() {
        var time = 0.0
        var detector = MeetingSpeechActivityDetector(model: Fake(p: 0.9), clock: { time += 1; return time })
        for i in 0..<3 {
            XCTAssertEqual(detector.process(samples: samples, valid: valid, start: Double(i) * 0.256, session: session, epoch: 0, route: "a").unknown, .overBudget)
        }
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 0.768, session: session, epoch: 0, route: "a").unknown, .disabled)
    }
    func testCombinedPolicyNeverTreatsActivityAsNearEndOrAbsenceProof() {
        XCTAssertEqual(MeetingSpeechPlaybackShadowPolicy.reason(activity: true, reliableDuplicate: true), .mixedOrLeakedActivity)
        XCTAssertEqual(MeetingSpeechPlaybackShadowPolicy.reason(activity: true, reliableDuplicate: false), .activityWithoutReliablePlaybackMatch)
        XCTAssertEqual(MeetingSpeechPlaybackShadowPolicy.reason(activity: false, reliableDuplicate: true), .duplicateWithoutDetectedActivity)
        XCTAssertEqual(MeetingSpeechPlaybackShadowPolicy.reason(activity: false, reliableDuplicate: false), .negativeActivityIsNotAbsence)
        XCTAssertEqual(MeetingSpeechPlaybackShadowPolicy.reason(activity: nil, reliableDuplicate: true), .missingSpeechEvidence)
    }
    func testUnavailableModelDoesNotDownload() {
        XCTAssertThrowsError(try MeetingLocalSileroActivityModel(modelURL: URL(fileURLWithPath: "/private/tmp/fv-missing-vad-artifact.mlmodelc")))
    }

    func testNewSessionAndUnknownFramesResetFailureAllowance() {
        var time = 0.0
        var detector = MeetingSpeechActivityDetector(model: Fake(p: 0.9), clock: { time += 1; return time })
        for i in 0..<2 { _ = detector.process(samples: samples, valid: valid, start: Double(i) * 0.256, session: session, epoch: 0, route: "a") }
        var masked = valid; masked[0] = false
        _ = detector.process(samples: samples, valid: masked, start: 0.512, session: session, epoch: 0, route: "a")
        for i in 3..<6 { XCTAssertEqual(detector.process(samples: samples, valid: valid, start: Double(i) * 0.256, session: session, epoch: 0, route: "a").unknown, .overBudget) }
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 1.536, session: session, epoch: 0, route: "a").unknown, .disabled)
        XCTAssertEqual(detector.process(samples: samples, valid: valid, start: 0, session: UUID(), epoch: 0, route: "a").unknown, .overBudget)
    }

    private func temporal(_ start: Double, supported: Bool, epoch: UInt64 = 0) -> MeetingPlaybackDuplicateDetector.Result {
        .init(start: start, end: start + 2, epoch: epoch,
              state: supported ? .duplicateSupported : .observing,
              reason: supported ? .stableSupport : .scoredInconclusive,
              supportingWindows: supported ? 3 : 0, correlation: 0.9, controlCorrelation: 0.1,
              microphoneDelaySeconds: 0.06, lagSpreadSeconds: 0, elapsedSeconds: 0)
    }
    func testCrossGridFrameUsesBothWindowsWithoutDroppingCoverage() {
        let windows = [temporal(0, supported: true), temporal(2, supported: true)]
        XCTAssertEqual(MeetingSpeechPlaybackShadowPolicy.temporalContext(start: 1.792, epoch: 0, windows: windows), .supported)
        XCTAssertEqual(MeetingSpeechPlaybackShadowPolicy.temporalContext(start: 1.792, epoch: 0, windows: [windows[0]]), .unavailable)
    }
    func testCrossGridMixedOrStaleEvidenceCannotBorrowSupport() {
        XCTAssertEqual(MeetingSpeechPlaybackShadowPolicy.temporalContext(start: 1.792, epoch: 0,
            windows: [temporal(0, supported: true), temporal(2, supported: false)]), .mixed)
        XCTAssertEqual(MeetingSpeechPlaybackShadowPolicy.temporalContext(start: 1.792, epoch: 0,
            windows: [temporal(0, supported: true), temporal(2, supported: true, epoch: 1)]), .unavailable)
    }
}
