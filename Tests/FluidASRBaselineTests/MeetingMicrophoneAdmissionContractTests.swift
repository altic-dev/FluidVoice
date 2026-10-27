@testable import FluidASRBaselineHost
import Foundation
import XCTest

final class MeetingMicrophoneAdmissionContractTests: XCTestCase {
    private typealias Evidence = MeetingMicrophoneEvidence
    private let sessionID = UUID()
    private let chunkID = UUID()

    private func identity(index: Int = 0, epoch: UInt64 = 0) -> Evidence.Identity {
        Evidence.Identity(
            sessionID: self.sessionID,
            chunkID: self.chunkID,
            turnIndex: index,
            captureEpoch: epoch,
            observation: .clusterLabel("0")
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        )!
    }

    // Fixed test fixture: missing required audio storage or evidence is a setup failure.
    // swiftlint:disable:next force_unwrapping
    private var interval: Evidence.Interval { .init(start: 0, end: 2)! }

    func testMissingPlaybackContextIsNotInvalidTemporalMeasurement() {
        let temporal = Evidence.TemporalDuplicate(
            state: .duplicateSupported,
            identity: self.identity(),
            interval: self.interval,
            supportingWindows: 3,
            microphoneDelaySeconds: .measured(0.06),
            lagSpreadSeconds: .measured(0),
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            coverage: .init(1)!
        )
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(self.evidence(playback: .unknown, temporal: .measured(temporal))).reason, .missingPlaybackContext)
    }

    func testTemporalBindingDeliberatelyRequiresTheExactEvidenceSnapshot() {
        let changedObservation = Evidence.Identity(
            sessionID: self.sessionID,
            chunkID: self.chunkID,
            turnIndex: 0,
            captureEpoch: 0,
            observation: .unavailable
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        )!
        let scopes: [(Evidence.Identity, Evidence.Interval)] = [
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            (changedObservation, self.interval), (self.identity(), .init(start: 0, end: 2.0.nextUp)!),
        ]
        for (scope, range) in scopes {
            let temporal = Evidence.TemporalDuplicate(
                state: .duplicateSupported,
                identity: scope,
                interval: range,
                supportingWindows: 3,
                microphoneDelaySeconds: .measured(0.06),
                lagSpreadSeconds: .measured(0),
                // Fixed test fixture: missing required audio storage or evidence is a setup failure.
                // swiftlint:disable:next force_unwrapping
                coverage: .init(1)!
            )
            XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(self.evidence(playback: .scoreablePlayback, temporal: .measured(temporal))).reason, .staleTemporalEvidence)
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
        Evidence(
            identity: self.identity(),
            interval: self.interval,
            playback: playback,
            signalVerdict: signal,
            textEcho: textEcho,
            speechActivity: activity,
            speechCoverage: .unavailable(.notMeasured),
            rms: rms,
            temporalDuplicate: temporal,
            embedding: .sharedClusterCentroid
        )
    }

    private func turn(signal: TurnEchoVerdict, textEcho: Bool, index: Int = 0) -> MeetingProcessingPipeline.StagedMicrophoneTurn {
        .init(
            chunkID: self.chunkID,
            index: index,
            clusterID: UUID(),
            clusterLabel: "0",
            diarizationObservationKey: self.identity(index: index).observationKey,
            start: 0,
            end: 2,
            text: "synthetic",
            overlapsRemote: true,
            isLikelyEcho: textEcho,
            echoScored: true,
            signalVerdict: signal
        )
    }

    func testLegacyTruthTableAndShadowInvocationCannotChangeTurns() {
        let cases: [(TurnEchoVerdict, Bool, Bool)] = [
            (.echo, false, true), (.echo, true, true),
            (.unknown, false, false), (.unknown, true, true),
            (.residualNotExplained, false, false), (.residualNotExplained, true, false),
        ]
        for (signal, textEcho, expected) in cases {
            let original = self.turn(signal: signal, textEcho: textEcho)
            let keysBefore = MeetingProcessingPipeline.trustedMicrophoneObservationKeys(from: [original])
            XCTAssertEqual(original.effectiveEcho, expected)
            let shadow = MeetingMicrophoneShadowPolicy.evaluate(self.evidence(signal: .measured(signal), textEcho: .measured(textEcho)))
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
            MeetingEchoSignalScorer.verdict(.init(
                fractions: [Double](repeating: 0.1, count: lowCount)
                    + [Double](repeating: other, count: 100 - lowCount),
                hopSeconds: 0.1
            ))
        }
        XCTAssertEqual(verdict(lowCount: 8, other: 0.9), .echo)
        XCTAssertEqual(verdict(lowCount: 8, other: 0.7), .residualNotExplained)
        XCTAssertEqual(verdict(lowCount: 16, other: 0.9), .residualNotExplained)
        XCTAssertEqual(MeetingEchoSignalScorer.verdict(.init(fractions: [], hopSeconds: 0.1)), .unknown)
    }

    func testShadowNamesRescueDisagreementWithoutChangingLegacy() {
        let input = self.evidence(signal: .measured(.residualNotExplained), textEcho: .measured(true))
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(input).reason, .legacyRescueDisagreement)
        XCTAssertFalse(input.legacySignalVerdict.legacyEffectiveEcho(textEcho: true))
    }

    func testActivityDoesNotProveNearEndSpeechEvenWithoutPlayback() {
        for playback in [Evidence.PlaybackContext.scoreablePlayback, .verifiedNoPlayback, .playbackExpectedButUnscoreable, .unknown] {
            let output = MeetingMicrophoneShadowPolicy.evaluate(self.evidence(activity: .measured(.detected), playback: playback))
            XCTAssertEqual(output.reason, .speechActivityIsNotNearEndProof)
            XCTAssertEqual(output.outcome, .uncertainCandidate)
        }
    }

    func testNegativeActivityAndZeroRMSDoNotProveSpeechAbsence() {
        let missing = self.evidence(activity: .measured(.notDetected))
        let zero = self.evidence(activity: .measured(.notDetected), rms: .measured(0))
        XCTAssertNotEqual(missing.rms, zero.rms)
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(zero).reason, .negativeActivityIsNotSpeechAbsenceProof)
    }

    func testUnknownReasonsRemainDistinctDespiteLegacyCollapse() {
        for reason in [Evidence.UnknownReason.noDelayLock, .referenceUnavailable, .unscoredCoverage, .scoredInconclusive] {
            let input = self.evidence(signal: .unavailable(reason))
            XCTAssertEqual(input.legacySignalVerdict, .unknown)
            XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(input).signalUnknownReason, reason)
        }
    }

    func testTurnIdentityPreservesSharedObservationAndEpochDistinctions() {
        XCTAssertNotEqual(self.identity(index: 0).turnKey, self.identity(index: 1).turnKey)
        XCTAssertEqual(self.identity(index: 0).observationKey, self.identity(index: 1).observationKey)
        XCTAssertNotEqual(self.identity(epoch: 0), self.identity(epoch: 1))
        XCTAssertNil(Evidence.Identity(sessionID: self.sessionID, chunkID: self.chunkID, turnIndex: -1, captureEpoch: 0, observation: .unavailable))
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let fallback = Evidence.Identity(sessionID: self.sessionID, chunkID: self.chunkID, turnIndex: 0, captureEpoch: 0, observation: .unavailable)!
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
        func evidence(for identity: Evidence.Identity, interval: Evidence.Interval) -> Evidence.Measurement<Evidence.TemporalDuplicate> { self.result }
    }

    func testFakeTemporalSourceIsOnlyEvidenceAndRequiresMatchingScope() {
        let stale = Evidence.TemporalDuplicate(
            state: .duplicateSupported,
            identity: self.identity(epoch: 1),
            interval: self.interval,
            supportingWindows: 6,
            microphoneDelaySeconds: .measured(0.06),
            lagSpreadSeconds: .measured(0.001),
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            coverage: .init(1)!
        )
        let fake = FakeTemporalDetector(result: .measured(stale))
        let input = self.evidence(playback: .scoreablePlayback, temporal: fake.evidence(for: self.identity(), interval: self.interval))
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(input).reason, .staleTemporalEvidence)
    }

    func testMalformedTemporalSupportDoesNotBecomeDuplicateEvidence() {
        let invalid = Evidence.TemporalDuplicate(
            state: .duplicateSupported,
            identity: self.identity(),
            interval: self.interval,
            supportingWindows: 0,
            microphoneDelaySeconds: .measured(.nan),
            lagSpreadSeconds: .measured(0),
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            coverage: .init(0)!
        )
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(self.evidence(temporal: .measured(invalid))).reason, .invalidTemporalEvidence)
    }

    func testSupportedDuplicateRemainsExperimentalAndCannotRescueMixedSpeech() {
        let temporal = Evidence.TemporalDuplicate(
            state: .duplicateSupported,
            identity: self.identity(),
            interval: self.interval,
            supportingWindows: 6,
            microphoneDelaySeconds: .measured(0.06),
            lagSpreadSeconds: .measured(0.001),
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            coverage: .init(1)!
        )
        let input = self.evidence(activity: .measured(.detected), playback: .scoreablePlayback, temporal: .measured(temporal))
        let result = MeetingMicrophoneShadowPolicy.evaluate(input)
        XCTAssertEqual(result.reason, .playbackDuplicateCandidate)
        XCTAssertEqual(result.outcome, .uncertainCandidate)
        XCTAssertTrue(result.experimental)
    }

    func testSharedCentroidStillCannotProveSpeechInShadow() {
        let input = self.evidence(signal: .measured(.residualNotExplained))
        XCTAssertEqual(input.embedding, .sharedClusterCentroid)
        XCTAssertEqual(MeetingMicrophoneShadowPolicy.evaluate(input).reason, .insufficientEvidence)
        // Characterization of the known production gap, not an assertion of desired enforcement.
        let siblings = [turn(signal: .echo, textEcho: true), turn(signal: .unknown, textEcho: false, index: 1)]
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        XCTAssertEqual(MeetingProcessingPipeline.trustedMicrophoneObservationKeys(from: siblings), [self.identity().observationKey!])
    }
}
