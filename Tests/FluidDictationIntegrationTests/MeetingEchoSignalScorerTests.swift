@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingEchoSignalScorerTests: XCTestCase {
    private let sampleRate = 16000.0
    private var hopSeconds: Double { Double(MeetingEchoSignalScorer.hopLength) / self.sampleRate }
    /// Tight enough to catch the sidelobe/wrong-sign regressions; the fixed estimator errs by 0 samples.
    private var delayAccuracySeconds: Double { 2.0 / self.sampleRate }

    func testEstimateDelayRecoversPositiveLag() throws {
        let delaySamples = 400
        var lcg = LCG(seed: 1)
        let reference = self.bandLimitedNoise(count: 12000, generator: &lcg)
        var noiseLCG = LCG(seed: 2)
        let mic = self.delayedAndScaled(reference, bySamples: delaySamples, scale: 0.5, noiseAmplitude: 0.01, generator: &noiseLCG)

        let estimate = try XCTUnwrap(
            MeetingEchoSignalScorer.estimateDelay(mic: mic, reference: reference, sampleRate: self.sampleRate, maxLagSeconds: 0.5)
        )
        let expectedSeconds = Double(delaySamples) / self.sampleRate
        XCTAssertEqual(estimate.seconds, expectedSeconds, accuracy: self.delayAccuracySeconds)
        XCTAssertGreaterThan(estimate.confidence, MeetingEchoSignalScorer.minimumDelayConfidence)
    }

    func testEstimateDelayRecoversNegativeLag() throws {
        let delaySamples = -350
        var lcg = LCG(seed: 3)
        let reference = self.bandLimitedNoise(count: 12000, generator: &lcg)
        var noiseLCG = LCG(seed: 4)
        let mic = self.delayedAndScaled(reference, bySamples: delaySamples, scale: 0.6, noiseAmplitude: 0.01, generator: &noiseLCG)

        let estimate = try XCTUnwrap(
            MeetingEchoSignalScorer.estimateDelay(mic: mic, reference: reference, sampleRate: self.sampleRate, maxLagSeconds: 0.5)
        )
        let expectedSeconds = Double(delaySamples) / self.sampleRate
        XCTAssertEqual(estimate.seconds, expectedSeconds, accuracy: self.delayAccuracySeconds)
        XCTAssertGreaterThan(estimate.confidence, MeetingEchoSignalScorer.minimumDelayConfidence)
    }

    func testEstimateDelayRecoversLagWithInvertedPolarity() throws {
        // Inverted polarity puts the true peak negative; signed argmax used to pick a sidelobe.
        let delaySamples = 400
        var lcg = LCG(seed: 60)
        let reference = self.bandLimitedNoise(count: 12000, generator: &lcg)
        var noiseLCG = LCG(seed: 61)
        let mic = self.delayedAndScaled(reference, bySamples: delaySamples, scale: -0.5, noiseAmplitude: 0.01, generator: &noiseLCG)

        let estimate = try XCTUnwrap(
            MeetingEchoSignalScorer.estimateDelay(mic: mic, reference: reference, sampleRate: self.sampleRate, maxLagSeconds: 0.5)
        )
        let expectedSeconds = Double(delaySamples) / self.sampleRate
        XCTAssertEqual(estimate.seconds, expectedSeconds, accuracy: self.delayAccuracySeconds)
        XCTAssertGreaterThan(estimate.confidence, MeetingEchoSignalScorer.minimumDelayConfidence)
    }

    func testEstimateDelayReturnsNilOnSilence() {
        var lcg = LCG(seed: 5)
        let tiny = self.bandLimitedNoise(count: 8000, generator: &lcg).map { $0 * 1e-6 }
        var lcg2 = LCG(seed: 6)
        let tiny2 = self.bandLimitedNoise(count: 8000, generator: &lcg2).map { $0 * 1e-6 }
        XCTAssertNil(MeetingEchoSignalScorer.estimateDelay(mic: tiny, reference: tiny2, sampleRate: self.sampleRate, maxLagSeconds: 0.5))
    }

    func testEstimateDelayReturnsNilForSubFrameInput() {
        let mic = [Float](repeating: 0.1, count: 100)
        let reference = [Float](repeating: 0.1, count: 100)
        XCTAssertNil(MeetingEchoSignalScorer.estimateDelay(mic: mic, reference: reference, sampleRate: self.sampleRate, maxLagSeconds: 0.5))
    }

    func testEstimateDelayHandlesMismatchedLengths() throws {
        let delaySamples = 200
        var lcg = LCG(seed: 62)
        let reference = self.bandLimitedNoise(count: 12000, generator: &lcg)
        var noiseLCG = LCG(seed: 63)
        let fullMic = self.delayedAndScaled(reference, bySamples: delaySamples, scale: 0.5, noiseAmplitude: 0.01, generator: &noiseLCG)
        let mic = Array(fullMic.prefix(9000))

        let estimate = try XCTUnwrap(
            MeetingEchoSignalScorer.estimateDelay(mic: mic, reference: reference, sampleRate: self.sampleRate, maxLagSeconds: 0.5)
        )
        let expectedSeconds = Double(delaySamples) / self.sampleRate
        XCTAssertEqual(estimate.seconds, expectedSeconds, accuracy: self.delayAccuracySeconds)
    }

    func testEstimateDelayHandlesDelayExceedingSignalLength() {
        var lcg = LCG(seed: 64)
        let reference = self.bandLimitedNoise(count: 2000, generator: &lcg)
        var noiseLCG = LCG(seed: 65)
        // Echo lies entirely outside the window; must not crash, whatever it returns.
        let mic = self.delayedAndScaled(reference, bySamples: 5000, scale: 0.5, noiseAmplitude: 0.01, generator: &noiseLCG)
        _ = MeetingEchoSignalScorer.estimateDelay(mic: mic, reference: reference, sampleRate: self.sampleRate, maxLagSeconds: 0.5)
    }

    func testEstimateDelayHandlesMaxLagBeyondSignalLength() throws {
        let delaySamples = 100
        var lcg = LCG(seed: 66)
        let reference = self.bandLimitedNoise(count: 2000, generator: &lcg)
        var noiseLCG = LCG(seed: 67)
        let mic = self.delayedAndScaled(reference, bySamples: delaySamples, scale: 0.5, noiseAmplitude: 0.01, generator: &noiseLCG)

        let estimate = try XCTUnwrap(
            MeetingEchoSignalScorer.estimateDelay(mic: mic, reference: reference, sampleRate: self.sampleRate, maxLagSeconds: 1000.0)
        )
        let expectedSeconds = Double(delaySamples) / self.sampleRate
        XCTAssertEqual(estimate.seconds, expectedSeconds, accuracy: self.delayAccuracySeconds)
    }

    func testEstimateDelayReturnsNilForNonFiniteMaxLag() {
        var lcg = LCG(seed: 68)
        let reference = self.bandLimitedNoise(count: 2000, generator: &lcg)
        var noiseLCG = LCG(seed: 69)
        let mic = self.delayedAndScaled(reference, bySamples: 100, scale: 0.5, noiseAmplitude: 0.01, generator: &noiseLCG)
        XCTAssertNil(MeetingEchoSignalScorer.estimateDelay(mic: mic, reference: reference, sampleRate: self.sampleRate, maxLagSeconds: .nan))
        XCTAssertNil(
            MeetingEchoSignalScorer.estimateDelay(mic: mic, reference: reference, sampleRate: self.sampleRate, maxLagSeconds: .infinity)
        )
    }

    func testPureEchoScoresHighAndVerdictIsEcho() {
        var lcg = LCG(seed: 10)
        let reference = self.bandLimitedNoise(count: Int(3.0 * self.sampleRate), generator: &lcg)
        // Multi-tap IR so the fixture isn't trivially cancelled by a one-tap model.
        let taps: [(delay: Int, gain: Float)] = [(150, 0.5), (190, 0.15), (230, 0.08), (270, 0.04), (310, 0.02)]
        var noiseLCG = LCG(seed: 11)
        let mic = self.multiTapEcho(reference, taps: taps, noiseAmplitude: 0.005, generator: &noiseLCG)

        let scores = MeetingEchoSignalScorer.explainedFractions(
            mic: mic, reference: reference, sampleRate: self.sampleRate, delaySeconds: Double(taps[0].delay) / self.sampleRate
        )
        let scoreable = scores.fractions.filter { !$0.isNaN }
        XCTAssertFalse(scoreable.isEmpty)
        XCTAssertGreaterThanOrEqual(MeetingEchoSignalScorer.median(scoreable), 0.5)

        let verdict = MeetingEchoSignalScorer.verdict(scores)
        XCTAssertEqual(verdict, .echo)
    }

    func testLocalSpeechOnlyIsUncorrelatedAndVerdictIsLocalSpeech() {
        var refLCG = LCG(seed: 20)
        let reference = self.bandLimitedNoise(count: Int(3.0 * self.sampleRate), generator: &refLCG)
        var micLCG = LCG(seed: 21)
        let mic = self.bandLimitedNoise(count: Int(3.0 * self.sampleRate), generator: &micLCG)

        let scores = MeetingEchoSignalScorer.explainedFractions(
            mic: mic, reference: reference, sampleRate: self.sampleRate, delaySeconds: 0
        )
        let verdict = MeetingEchoSignalScorer.verdict(scores)
        XCTAssertEqual(verdict, .containsLocalSpeech)
    }

    func testDoubleTalkBurstRescuesTurnAsLocalSpeech() {
        var refLCG = LCG(seed: 30)
        let totalCount = Int(3.0 * self.sampleRate)
        let reference = self.bandLimitedNoise(count: totalCount, generator: &refLCG)
        let delaySamples = 150
        var noiseLCG = LCG(seed: 31)
        var mic = self.delayedAndScaled(reference, bySamples: delaySamples, scale: 0.5, noiseAmplitude: 0.005, generator: &noiseLCG)

        // Real double talk is additive, not replacing. Rescue needs ~1.86x the echo energy;
        // 1.2 against the echo's 0.5 tap gain gives ~5.76x, clear of per-frame estimation noise.
        var burstLCG = LCG(seed: 32)
        let burstCount = Int(1.0 * self.sampleRate)
        let burstStart = (totalCount - burstCount) / 2
        let burst = self.bandLimitedNoise(count: burstCount, generator: &burstLCG)
        for i in 0..<burstCount {
            mic[burstStart + i] += burst[i] * 1.2
        }

        let scores = MeetingEchoSignalScorer.explainedFractions(
            mic: mic, reference: reference, sampleRate: self.sampleRate, delaySeconds: Double(delaySamples) / self.sampleRate
        )
        let verdict = MeetingEchoSignalScorer.verdict(scores)
        XCTAssertEqual(verdict, .containsLocalSpeech)
    }

    /// A long turn of pure bleed picks up a brief low-scoring run from estimation noise. Measured on
    /// a real speakerphone session: 0.75s inside a 22.4s turn at median 0.91, which the absolute
    /// rescue rule read as local speech and published as a visible duplicate of the far end.
    func testBriefLowRunInLongExplainedTurnIsNotRescued() {
        var refLCG = LCG(seed: 90)
        let totalCount = Int(22.0 * self.sampleRate)
        let reference = self.bandLimitedNoise(count: totalCount, generator: &refLCG)
        let delaySamples = 150
        var noiseLCG = LCG(seed: 91)
        var mic = self.delayedAndScaled(reference, bySamples: delaySamples, scale: 0.5, noiseAmplitude: 0.005, generator: &noiseLCG)

        // 0.8s of unexplained audio — over the absolute rescue floor, 3.6% of the turn.
        var burstLCG = LCG(seed: 92)
        let burstCount = Int(0.8 * self.sampleRate)
        let burstStart = totalCount / 2
        let burst = self.bandLimitedNoise(count: burstCount, generator: &burstLCG)
        for i in 0..<burstCount {
            mic[burstStart + i] += burst[i] * 1.2
        }

        let scores = MeetingEchoSignalScorer.explainedFractions(
            mic: mic, reference: reference, sampleRate: self.sampleRate, delaySeconds: Double(delaySamples) / self.sampleRate
        )
        XCTAssertEqual(MeetingEchoSignalScorer.verdict(scores), .echo)
    }

    /// The same absolute run length inside a short turn is a real interjection, and must survive.
    func testSameRunLengthInShortTurnStillRescues() {
        var refLCG = LCG(seed: 93)
        let totalCount = Int(3.0 * self.sampleRate)
        let reference = self.bandLimitedNoise(count: totalCount, generator: &refLCG)
        let delaySamples = 150
        var noiseLCG = LCG(seed: 94)
        var mic = self.delayedAndScaled(reference, bySamples: delaySamples, scale: 0.5, noiseAmplitude: 0.005, generator: &noiseLCG)

        var burstLCG = LCG(seed: 95)
        let burstCount = Int(0.8 * self.sampleRate)
        let burstStart = (totalCount - burstCount) / 2
        let burst = self.bandLimitedNoise(count: burstCount, generator: &burstLCG)
        for i in 0..<burstCount {
            mic[burstStart + i] += burst[i] * 1.2
        }

        let scores = MeetingEchoSignalScorer.explainedFractions(
            mic: mic, reference: reference, sampleRate: self.sampleRate, delaySeconds: Double(delaySamples) / self.sampleRate
        )
        XCTAssertEqual(MeetingEchoSignalScorer.verdict(scores), .containsLocalSpeech)
    }

    func testQuietAdditiveInterjectionDoesNotRescueTurn() {
        var refLCG = LCG(seed: 33)
        let totalCount = Int(3.0 * self.sampleRate)
        let reference = self.bandLimitedNoise(count: totalCount, generator: &refLCG)
        let delaySamples = 150
        var noiseLCG = LCG(seed: 34)
        var mic = self.delayedAndScaled(reference, bySamples: delaySamples, scale: 0.5, noiseAmplitude: 0.005, generator: &noiseLCG)

        // ~0.36x the echo energy, under the 1.86x rescue floor: a quiet interjection must not rescue.
        var burstLCG = LCG(seed: 35)
        let burstCount = Int(1.0 * self.sampleRate)
        let burstStart = (totalCount - burstCount) / 2
        let burst = self.bandLimitedNoise(count: burstCount, generator: &burstLCG)
        for i in 0..<burstCount {
            mic[burstStart + i] += burst[i] * 0.3
        }

        let scores = MeetingEchoSignalScorer.explainedFractions(
            mic: mic, reference: reference, sampleRate: self.sampleRate, delaySeconds: Double(delaySamples) / self.sampleRate
        )
        let verdict = MeetingEchoSignalScorer.verdict(scores)
        XCTAssertEqual(verdict, .echo)
    }

    func testSilentReferenceProducesNaNAndVerdictIsUnknownNotLocalSpeech() {
        let count = Int(3.0 * self.sampleRate)
        let reference = [Float](repeating: 0, count: count)
        var micLCG = LCG(seed: 40)
        let mic = self.bandLimitedNoise(count: count, generator: &micLCG)

        let scores = MeetingEchoSignalScorer.explainedFractions(
            mic: mic, reference: reference, sampleRate: self.sampleRate, delaySeconds: 0
        )
        XCTAssertTrue(scores.fractions.allSatisfy(\.isNaN), "absence of reference energy must not be scoreable")

        let verdict = MeetingEchoSignalScorer.verdict(scores)
        XCTAssertEqual(verdict, .unknown)
    }

    func testLowButNonzeroReferenceYieldsNaNFrames() {
        let count = Int(3.0 * self.sampleRate)
        var refLCG = LCG(seed: 80)
        // Below minimumSignalRMS but not silent: the old floor was ~10 orders too small to catch it.
        let reference = self.bandLimitedNoise(count: count, generator: &refLCG).map { $0 * 5e-5 }
        var micLCG = LCG(seed: 81)
        let mic = self.bandLimitedNoise(count: count, generator: &micLCG)

        let scores = MeetingEchoSignalScorer.explainedFractions(
            mic: mic, reference: reference, sampleRate: self.sampleRate, delaySeconds: 0
        )
        XCTAssertTrue(scores.fractions.allSatisfy(\.isNaN))
    }

    func testVerdictWithMostlyNaNInputIsUnknown() {
        var fractions = [Double](repeating: .nan, count: 40)
        fractions[0] = 0.9
        fractions[1] = 0.85
        let scores = EchoFrameScores(fractions: fractions, hopSeconds: self.hopSeconds)
        let verdict = MeetingEchoSignalScorer.verdict(scores)
        XCTAssertEqual(verdict, .unknown)
    }

    func testVerdictWithMostlyNaNButUnambiguousLocalSpeechRescues() {
        // Unambiguous local speech surrounded by NaN must rescue, not fall through the coverage gate.
        let lowRunFrames = Int((1.28 / self.hopSeconds).rounded(.up))
        var fractions = [Double](repeating: .nan, count: lowRunFrames + 40)
        for i in 0..<lowRunFrames {
            fractions[i] = 0.1
        }
        let scores = EchoFrameScores(fractions: fractions, hopSeconds: self.hopSeconds)
        let verdict = MeetingEchoSignalScorer.verdict(scores)
        XCTAssertEqual(verdict, .containsLocalSpeech)
    }

    func testExplainedFractionsAreClampedToUnitRange() {
        var refLCG = LCG(seed: 50)
        let totalCount = Int(3.0 * self.sampleRate)
        let reference = self.bandLimitedNoise(count: totalCount, generator: &refLCG)
        let delaySamples = 100
        var noiseLCG = LCG(seed: 51)
        var mic = self.delayedAndScaled(reference, bySamples: delaySamples, scale: 0.5, noiseAmplitude: 0.005, generator: &noiseLCG)

        // Muting mic while the reference stays hot makes block-fit H over-predict, so the raw
        // fraction goes negative and must clamp to 0.
        let muteStart = totalCount / 2
        let muteLength = 2000
        for i in muteStart..<(muteStart + muteLength) {
            mic[i] *= 0.01
        }

        let scores = MeetingEchoSignalScorer.explainedFractions(
            mic: mic, reference: reference, sampleRate: self.sampleRate, delaySeconds: Double(delaySamples) / self.sampleRate
        )
        let scoreable = scores.fractions.filter { !$0.isNaN }
        XCTAssertFalse(scoreable.isEmpty, "expected at least one scoreable frame")
        XCTAssertTrue(scoreable.contains(0.0), "expected the muted window to clamp a negative raw fraction to 0")
        for value in scoreable {
            XCTAssertGreaterThanOrEqual(value, 0.0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
    }

    func testExplainedFractionsHandlesNonFiniteDelayWithoutCrashing() {
        var refLCG = LCG(seed: 70)
        let reference = self.bandLimitedNoise(count: Int(2.0 * self.sampleRate), generator: &refLCG)
        var micLCG = LCG(seed: 71)
        let mic = self.bandLimitedNoise(count: Int(2.0 * self.sampleRate), generator: &micLCG)
        let scores = MeetingEchoSignalScorer.explainedFractions(
            mic: mic, reference: reference, sampleRate: self.sampleRate, delaySeconds: .nan
        )
        XCTAssertTrue(scores.fractions.allSatisfy(\.isNaN) || scores.fractions.isEmpty)
    }

    private struct LCG {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func nextUnit() -> Float {
            self.state = self.state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(self.state >> 11) / Double(1 << 53))
        }
        mutating func nextSigned() -> Float { self.nextUnit() * 2 - 1 }
    }

    /// Cheap 3-tap moving-average smoothing gives GCC-PHAT a less impulsive, more speech-like spectrum.
    private func bandLimitedNoise(count: Int, generator: inout LCG) -> [Float] {
        var white = [Float](repeating: 0, count: count)
        for i in 0..<count { white[i] = generator.nextSigned() }
        var smoothed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let a = white[i]
            let b = i > 0 ? white[i - 1] : 0
            let c = i > 1 ? white[i - 2] : 0
            smoothed[i] = (a + b + c) / 3
        }
        return smoothed
    }

    private func delayedAndScaled(
        _ reference: [Float], bySamples delay: Int, scale: Float, noiseAmplitude: Float, generator: inout LCG
    ) -> [Float] {
        var result = [Float](repeating: 0, count: reference.count)
        for i in 0..<reference.count {
            let sourceIndex = i - delay
            let echoValue = (sourceIndex >= 0 && sourceIndex < reference.count) ? reference[sourceIndex] * scale : 0
            result[i] = echoValue + generator.nextSigned() * noiseAmplitude
        }
        return result
    }

    /// A short decaying multi-tap "room impulse response" echo, rather than one scaled delta.
    private func multiTapEcho(
        _ reference: [Float], taps: [(delay: Int, gain: Float)], noiseAmplitude: Float, generator: inout LCG
    ) -> [Float] {
        var result = [Float](repeating: 0, count: reference.count)
        for i in 0..<reference.count {
            var value: Float = 0
            for tap in taps {
                let sourceIndex = i - tap.delay
                if sourceIndex >= 0, sourceIndex < reference.count {
                    value += reference[sourceIndex] * tap.gain
                }
            }
            result[i] = value + generator.nextSigned() * noiseAmplitude
        }
        return result
    }
}
