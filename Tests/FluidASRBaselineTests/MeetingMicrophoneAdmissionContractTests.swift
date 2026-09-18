@testable import FluidASRBaselineHost
import Foundation
import XCTest

final class MeetingMicrophoneAdmissionContractTests: XCTestCase {
    private typealias Evidence = MeetingMicrophoneEvidence
    private let sessionID = UUID()
    private let chunkID = UUID()

    private func identity(index: Int = 0, epoch: UInt64 = 0) -> Evidence.Identity {
        Evidence.Identity(sessionID: sessionID, chunkID: chunkID, turnIndex: index,
                          captureEpoch: epoch, observation: .clusterLabel("0"))!
    }
    private var interval: Evidence.Interval { .init(start: 0, end: 2)! }

    func testMissingPlaybackContextIsNotInvalidTemporalMeasurement() {
        let temporal = Evidence.TemporalDuplicate(state: .duplicateSupported, identity: identity(), interval: interval,
            supportingWindows: 3, microphoneDelaySeconds: .measured(0.06), lagSpreadSeconds: .measured(0), coverage: .init(1)!)
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(evidence(playback: .unknown, temporal: .measured(temporal))).reason, .missingPlaybackContext)
    }

    func testTemporalBindingDeliberatelyRequiresTheExactEvidenceSnapshot() {
        let changedObservation = Evidence.Identity(sessionID: sessionID, chunkID: chunkID, turnIndex: 0,
            captureEpoch: 0, observation: .unavailable)!
        let scopes: [(Evidence.Identity, Evidence.Interval)] = [
            (changedObservation, interval), (identity(), .init(start: 0, end: 2.0.nextUp)!)
        ]
        for (scope, range) in scopes {
            let temporal = Evidence.TemporalDuplicate(state: .duplicateSupported, identity: scope, interval: range,
                supportingWindows: 3, microphoneDelaySeconds: .measured(0.06), lagSpreadSeconds: .measured(0), coverage: .init(1)!)
            XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(evidence(playback: .scoreablePlayback, temporal: .measured(temporal))).reason, .staleTemporalEvidence)
        }
    }

    private func evidence(
        signal: Evidence.Measurement<TurnEchoVerdict> = .unavailable(.notMeasured),
        textEcho: Evidence.Measurement<Bool> = .unavailable(.notMeasured),
        activity: Evidence.Measurement<Evidence.SpeechActivity> = .unavailable(.notMeasured),
        playback: Evidence.PlaybackContext = .unknown,
        temporal: Evidence.Measurement<Evidence.TemporalDuplicate> = .unavailable(.notMeasured),
        rms: Evidence.Measurement<Double> = .unavailable(.notMeasured)
    ) -> Evidence {
        Evidence(identity: identity(), interval: interval, playback: playback, signalVerdict: signal,
                 textEcho: textEcho, speechActivity: activity, speechCoverage: .unavailable(.notMeasured),
                 rms: rms, temporalDuplicate: temporal, embedding: .sharedClusterCentroid)
    }

    private func turn(signal: TurnEchoVerdict, textEcho: Bool, index: Int = 0) -> MeetingProcessingPipeline.StagedMicrophoneTurn {
        .init(chunkID: chunkID, index: index, clusterID: UUID(), clusterLabel: "0",
              diarizationObservationKey: identity(index: index).observationKey,
              start: 0, end: 2, text: "synthetic", overlapsRemote: true,
              isLikelyEcho: textEcho, echoScored: true, signalVerdict: signal)
    }

    func testLegacyTruthTableAndShadowInvocationCannotChangeTurns() {
        let cases: [(TurnEchoVerdict, Bool, Bool)] = [
            (.echo, false, true), (.echo, true, true),
            (.unknown, false, false), (.unknown, true, true),
            (.residualNotExplained, false, false), (.residualNotExplained, true, false)
        ]
        for (signal, textEcho, expected) in cases {
            let original = turn(signal: signal, textEcho: textEcho)
            let keysBefore = MeetingProcessingPipeline.trustedMicrophoneObservationKeys(from: [original])
            XCTAssertEqual(original.effectiveEcho, expected)
            let shadow = MeetingMicrophoneShadowPolicy.evaluate(evidence(signal: .measured(signal), textEcho: .measured(textEcho)))
            XCTAssertTrue(shadow.experimental)
            XCTAssertEqual(shadow.outcome, .uncertainCandidate)
            XCTAssertEqual(original.effectiveEcho, expected)
            XCTAssertEqual(MeetingProcessingPipeline.trustedMicrophoneObservationKeys(from: [original]), keysBefore)
            XCTAssertEqual(keysBefore.isEmpty, textEcho, "Stage A preserves even the known text-only profile gap")
        }
    }

    func testLegacyScorerRescueStillPrecedesCoverageGate() {
        let fractions = [Double](repeating: 0.1, count: 8) + [Double](repeating: .nan, count: 12)
        XCTAssertEqual(MeetingEchoSignalScorer.verdict(.init(fractions: fractions, hopSeconds: 0.1)), .residualNotExplained)
    }

    func testLegacyShortNaNGapStillBridgesLowRun() {
        let fractions = [Double](repeating: 0.1, count: 4) + [Double](repeating: .nan, count: 3)
            + [Double](repeating: 0.1, count: 4) + [Double](repeating: 0.9, count: 20)
        XCTAssertEqual(MeetingEchoSignalScorer.verdict(.init(fractions: fractions, hopSeconds: 0.1)), .residualNotExplained)
    }

    func testLegacyLongNaNGapStillBreaksLowRun() {
        let fractions = [Double](repeating: 0.1, count: 4) + [Double](repeating: .nan, count: 8)
            + [Double](repeating: 0.1, count: 4) + [Double](repeating: 0.9, count: 20)
        XCTAssertEqual(MeetingEchoSignalScorer.verdict(.init(fractions: fractions, hopSeconds: 0.1)), .echo)
    }

    func testLegacyTrivialRunDenialRequiresAllConditions() {
        func verdict(lowCount: Int, other: Double) -> TurnEchoVerdict {
            MeetingEchoSignalScorer.verdict(.init(fractions: [Double](repeating: 0.1, count: lowCount)
                + [Double](repeating: other, count: 100 - lowCount), hopSeconds: 0.1))
        }
        XCTAssertEqual(verdict(lowCount: 8, other: 0.9), .echo)
        XCTAssertEqual(verdict(lowCount: 8, other: 0.7), .residualNotExplained)
        XCTAssertEqual(verdict(lowCount: 16, other: 0.9), .residualNotExplained)
        XCTAssertEqual(MeetingEchoSignalScorer.verdict(.init(fractions: [], hopSeconds: 0.1)), .unknown)
    }

    func testShadowNamesRescueDisagreementWithoutChangingLegacy() {
        let input = evidence(signal: .measured(.residualNotExplained), textEcho: .measured(true))
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(input).reason, .legacyRescueDisagreement)
        XCTAssertFalse(input.legacySignalVerdict.legacyEffectiveEcho(textEcho: true))
    }

    func testActivityDoesNotProveNearEndSpeechEvenWithoutPlayback() {
        for playback in [Evidence.PlaybackContext.scoreablePlayback, .verifiedNoPlayback, .playbackExpectedButUnscoreable, .unknown] {
            let output = MeetingMicrophoneShadowPolicy.evaluate(evidence(activity: .measured(.detected), playback: playback))
            XCTAssertEqual(output.reason, .speechActivityIsNotNearEndProof)
            XCTAssertEqual(output.outcome, .uncertainCandidate)
        }
    }

    func testNegativeActivityAndZeroRMSDoNotProveSpeechAbsence() {
        let missing = evidence(activity: .measured(.notDetected))
        let zero = evidence(activity: .measured(.notDetected), rms: .measured(0))
        XCTAssertNotEqual(missing.rms, zero.rms)
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(zero).reason, .negativeActivityIsNotSpeechAbsenceProof)
    }

    func testUnknownReasonsRemainDistinctDespiteLegacyCollapse() {
        for reason in [Evidence.UnknownReason.noDelayLock, .referenceUnavailable, .unscoredCoverage, .scoredInconclusive] {
            let input = evidence(signal: .unavailable(reason))
            XCTAssertEqual(input.legacySignalVerdict, .unknown)
            XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(input).signalUnknownReason, reason)
        }
    }

    func testTurnIdentityPreservesSharedObservationAndEpochDistinctions() {
        XCTAssertNotEqual(identity(index: 0).turnKey, identity(index: 1).turnKey)
        XCTAssertEqual(identity(index: 0).observationKey, identity(index: 1).observationKey)
        XCTAssertNotEqual(identity(epoch: 0), identity(epoch: 1))
        XCTAssertNil(Evidence.Identity(sessionID: sessionID, chunkID: chunkID, turnIndex: -1, captureEpoch: 0, observation: .unavailable))
        let fallback = Evidence.Identity(sessionID: sessionID, chunkID: chunkID, turnIndex: 0, captureEpoch: 0, observation: .unavailable)!
        XCTAssertNil(fallback.observationKey)
    }

    func testRangesAndCoverageRejectNonfiniteAndInvalidValues() {
        XCTAssertNil(Evidence.Interval(start: .nan, end: 2))
        XCTAssertNil(Evidence.Interval(start: 0, end: .infinity))
        XCTAssertNil(Evidence.Interval(start: 2, end: 1))
        XCTAssertNil(Evidence.Interval(start: -1, end: 1))
        XCTAssertNil(Evidence.Fraction(.nan))
        XCTAssertNil(Evidence.Fraction(1.1))
        XCTAssertEqual(Evidence.Fraction(0)?.value, 0)
    }

    private struct FakeTemporalDetector: MeetingPlaybackDuplicateEvidenceSource {
        let result: Evidence.Measurement<Evidence.TemporalDuplicate>
        func evidence(for identity: Evidence.Identity, interval: Evidence.Interval) -> Evidence.Measurement<Evidence.TemporalDuplicate> { result }
    }

    func testFakeTemporalSourceIsOnlyEvidenceAndRequiresMatchingScope() {
        let stale = Evidence.TemporalDuplicate(state: .duplicateSupported, identity: identity(epoch: 1), interval: interval,
            supportingWindows: 6, microphoneDelaySeconds: .measured(0.06), lagSpreadSeconds: .measured(0.001), coverage: .init(1)!)
        let fake = FakeTemporalDetector(result: .measured(stale))
        let input = evidence(playback: .scoreablePlayback, temporal: fake.evidence(for: identity(), interval: interval))
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(input).reason, .staleTemporalEvidence)
    }

    func testMalformedTemporalSupportDoesNotBecomeDuplicateEvidence() {
        let invalid = Evidence.TemporalDuplicate(state: .duplicateSupported, identity: identity(), interval: interval,
            supportingWindows: 0, microphoneDelaySeconds: .measured(.nan), lagSpreadSeconds: .measured(0), coverage: .init(0)!)
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(evidence(temporal: .measured(invalid))).reason, .invalidTemporalEvidence)
    }

    func testSupportedDuplicateRemainsExperimentalAndCannotRescueMixedSpeech() {
        let temporal = Evidence.TemporalDuplicate(state: .duplicateSupported, identity: identity(), interval: interval,
            supportingWindows: 6, microphoneDelaySeconds: .measured(0.06), lagSpreadSeconds: .measured(0.001), coverage: .init(1)!)
        let input = evidence(activity: .measured(.detected), playback: .scoreablePlayback, temporal: .measured(temporal))
        let result = MeetingMicrophoneShadowPolicy.evaluate(input)
        XCTAssertEqual(result.reason, .playbackDuplicateCandidate)
        XCTAssertEqual(result.outcome, .uncertainCandidate)
        XCTAssertTrue(result.experimental)
    }

    func testSharedCentroidStillCannotProveSpeechInShadow() {
        let input = evidence(signal: .measured(.residualNotExplained))
        XCTAssertEqual(input.embedding, .sharedClusterCentroid)
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(input).reason, .insufficientEvidence)
        // Characterization of the known production gap, not an assertion of desired enforcement.
        let siblings = [turn(signal: .echo, textEcho: true), turn(signal: .unknown, textEcho: false, index: 1)]
        XCTAssertEqual(MeetingProcessingPipeline.trustedMicrophoneObservationKeys(from: siblings), [identity().observationKey!])
    }
}
