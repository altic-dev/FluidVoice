import Foundation
@testable import Voix_Debug
import XCTest

final class SpeechAnalysisServiceTests: XCTestCase {
    private let sampleRate = 16_000.0

    // MARK: - Pitch

    func testRecoversPitchOfPureTone() {
        let pcm = self.sine(frequency: 440, seconds: 1)

        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: "",
            fillerWords: []
        )

        XCTAssertEqual(metrics.meanPitchHz, 440, accuracy: 5)
    }

    /// A period multiple correlates about as well as the period itself, so a naive
    /// peak pick reports half the pitch. Low tones have the most room to halve.
    func testDoesNotReportSubharmonicForLowTone() {
        let pcm = self.sine(frequency: 120, seconds: 1)

        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: "",
            fillerWords: []
        )

        XCTAssertEqual(metrics.meanPitchHz, 120, accuracy: 3)
    }

    func testConstantToneScoresAsMonotone() {
        let pcm = self.sine(frequency: 200, seconds: 2)

        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: "",
            fillerWords: []
        )

        XCTAssertEqual(metrics.pitchStdDevHz, 0, accuracy: 1)
        XCTAssertEqual(metrics.pitchRangeHz, 0, accuracy: 2)
    }

    func testPitchVariationIsReportedAsVariety() {
        // Two tones a fifth apart; standard deviation must clearly exceed the
        // near-zero figure the constant tone produces.
        let pcm = self.sine(frequency: 150, seconds: 1) + self.sine(frequency: 225, seconds: 1)

        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: "",
            fillerWords: []
        )

        XCTAssertGreaterThan(metrics.pitchStdDevHz, 20)
        XCTAssertEqual(metrics.pitchRangeHz, 75, accuracy: 10)
    }

    // MARK: - Pauses

    func testDetectsInsertedSilenceGaps() {
        // 2s speech, 1s silence, 2s speech, 1s silence, 2s speech.
        var pcm = self.speechShapedNoise(seconds: 2, seed: 1)
        pcm += self.silence(seconds: 1)
        pcm += self.speechShapedNoise(seconds: 2, seed: 2)
        pcm += self.silence(seconds: 1)
        pcm += self.speechShapedNoise(seconds: 2, seed: 3)

        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: "",
            fillerWords: []
        )

        XCTAssertEqual(metrics.pauseCount, 2)
        XCTAssertEqual(metrics.pauses[0].startSeconds, 2, accuracy: 0.05)
        XCTAssertEqual(metrics.pauses[0].durationSeconds, 1, accuracy: 0.05)
        XCTAssertEqual(metrics.pauses[1].startSeconds, 5, accuracy: 0.05)
        XCTAssertEqual(metrics.pauses[1].durationSeconds, 1, accuracy: 0.05)
        XCTAssertEqual(metrics.totalPauseSeconds, 2, accuracy: 0.1)
        XCTAssertEqual(metrics.longestPauseSeconds, 1, accuracy: 0.05)
        XCTAssertEqual(metrics.durationSeconds, 8, accuracy: 0.01)
    }

    func testIgnoresGapsShorterThanThreshold() {
        // A 0.2s gap is a breath, not a pause.
        var pcm = self.speechShapedNoise(seconds: 1, seed: 1)
        pcm += self.silence(seconds: 0.2)
        pcm += self.speechShapedNoise(seconds: 1, seed: 2)

        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: "",
            fillerWords: []
        )

        XCTAssertEqual(metrics.pauseCount, 0)
    }

    /// Hitting record and waiting is not a rhetorical pause, and it must not drag
    /// the pace numbers down either.
    func testLeadingAndTrailingSilenceIsNotAPause() {
        var pcm = self.silence(seconds: 3)
        pcm += self.speechShapedNoise(seconds: 2, seed: 1)
        pcm += self.silence(seconds: 3)

        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: "",
            fillerWords: []
        )

        XCTAssertEqual(metrics.pauseCount, 0)
        XCTAssertEqual(metrics.durationSeconds, 8, accuracy: 0.01)
        XCTAssertEqual(metrics.speechSpanSeconds, 2, accuracy: 0.1)
    }

    func testFlagsPausesOfTwoSecondsOrMore() {
        var pcm = self.speechShapedNoise(seconds: 1, seed: 1)
        pcm += self.silence(seconds: 2.5)
        pcm += self.speechShapedNoise(seconds: 1, seed: 2)

        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: "",
            fillerWords: []
        )

        XCTAssertEqual(metrics.pauseCount, 1)
        XCTAssertEqual(metrics.longPauses.count, 1)
        XCTAssertEqual(metrics.longPauses[0].durationSeconds, 2.5, accuracy: 0.05)
    }

    // MARK: - Pace

    func testPaceSeparatesOverallRateFromArticulationRate() {
        // 60 words over a 2s + 2s silence + 2s span. Overall pace is measured across
        // the whole 6s span; articulation excludes the pause, so it must be higher.
        var pcm = self.speechShapedNoise(seconds: 2, seed: 1)
        pcm += self.silence(seconds: 2)
        pcm += self.speechShapedNoise(seconds: 2, seed: 2)

        let transcript = (0..<60).map { "word\($0)" }.joined(separator: " ")
        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: transcript,
            fillerWords: []
        )

        XCTAssertEqual(metrics.totalWords, 60)
        XCTAssertEqual(metrics.wordsPerMinute, 600, accuracy: 20)
        XCTAssertEqual(metrics.articulationRate, 900, accuracy: 30)
        XCTAssertGreaterThan(metrics.articulationRate, metrics.wordsPerMinute)
        XCTAssertEqual(metrics.speakingRatio, 2.0 / 3.0, accuracy: 0.05)
    }

    // MARK: - Fillers

    func testCountsFillersPerType() {
        let metrics = SpeechAnalysisService.analyze(
            pcm: self.speechShapedNoise(seconds: 60, seed: 1),
            sampleRate: self.sampleRate,
            rawTranscript: "um so like the plan um is uh ready",
            fillerWords: ["um", "uh", "so", "like"]
        )

        XCTAssertEqual(metrics.fillerCounts, ["um": 2, "so": 1, "like": 1, "uh": 1])
        XCTAssertEqual(metrics.totalFillers, 5)
        XCTAssertEqual(metrics.fillersPerMinute, 5, accuracy: 0.3)
    }

    /// The shipped default list is vocalized hesitations only, so "so" and "like"
    /// are not fillers unless the user adds them.
    func testOnlyCountsWordsOnTheConfiguredList() {
        let metrics = SpeechAnalysisService.analyze(
            pcm: self.speechShapedNoise(seconds: 10, seed: 1),
            sampleRate: self.sampleRate,
            rawTranscript: "um so like the plan um",
            fillerWords: ["um", "uh"]
        )

        XCTAssertEqual(metrics.fillerCounts, ["um": 2])
    }

    func testFillerMatchingIgnoresCaseAndPunctuation() {
        let metrics = SpeechAnalysisService.analyze(
            pcm: self.speechShapedNoise(seconds: 10, seed: 1),
            sampleRate: self.sampleRate,
            rawTranscript: "Um, the plan... UH! and uh,",
            fillerWords: ["um", "uh"]
        )

        XCTAssertEqual(metrics.fillerCounts, ["um": 1, "uh": 2])
    }

    // MARK: - Degenerate input

    func testEmptyAudioProducesEmptyMetrics() {
        let metrics = SpeechAnalysisService.analyze(
            pcm: [],
            sampleRate: self.sampleRate,
            rawTranscript: "anything",
            fillerWords: ["um"]
        )

        XCTAssertEqual(metrics, .empty)
    }

    func testPureSilenceProducesEmptyMetrics() {
        let metrics = SpeechAnalysisService.analyze(
            pcm: self.silence(seconds: 3),
            sampleRate: self.sampleRate,
            rawTranscript: "",
            fillerWords: []
        )

        XCTAssertEqual(metrics, .empty)
    }

    // MARK: - Serialization and rendering

    func testMetricsRoundTripThroughCodable() throws {
        var pcm = self.speechShapedNoise(seconds: 2, seed: 1)
        pcm += self.silence(seconds: 1)
        pcm += self.speechShapedNoise(seconds: 2, seed: 2)

        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: "um the plan",
            fillerWords: ["um"]
        )

        let data = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(DeliveryMetrics.self, from: data)

        XCTAssertEqual(decoded, metrics)
    }

    func testSummaryTextCitesTheMeasurements() {
        var pcm = self.speechShapedNoise(seconds: 2, seed: 1)
        pcm += self.silence(seconds: 2.5)
        pcm += self.speechShapedNoise(seconds: 2, seed: 2)

        let metrics = SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: self.sampleRate,
            rawTranscript: "um the plan is ready",
            fillerWords: ["um"]
        )
        let summary = metrics.summaryText()

        // The coaching prompt asks the model to quote these back, so they have to be present.
        XCTAssertTrue(summary.contains("WPM"))
        XCTAssertTrue(summary.contains("Articulation rate"))
        XCTAssertTrue(summary.contains("um x1"))
        XCTAssertTrue(summary.contains("Pauses >= 2s: 1"))
        XCTAssertFalse(summary.contains("nan"))
        XCTAssertFalse(summary.contains("inf"))
    }

    func testContourIsDownsampledForPlotting() {
        let metrics = SpeechAnalysisService.analyze(
            pcm: self.speechShapedNoise(seconds: 120, seed: 1),
            sampleRate: self.sampleRate,
            rawTranscript: "",
            fillerWords: []
        )

        // 120s of 20ms frames is 6000 raw points; charts get a bounded series back.
        XCTAssertEqual(metrics.energyContour.count, 240)
        XCTAssertGreaterThan(metrics.contourIntervalSeconds, 0)
        let span = metrics.contourIntervalSeconds * Double(metrics.energyContour.count)
        XCTAssertEqual(span, metrics.durationSeconds, accuracy: 1)
    }

    // MARK: - Signal helpers

    private func sine(frequency: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        let count = Int(self.sampleRate * seconds)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * .pi * frequency * Double(index) / self.sampleRate))
        }
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(self.sampleRate * seconds))
    }

    /// Broadband noise at a speech-like level. Seeded so failures reproduce.
    private func speechShapedNoise(seconds: Double, seed: UInt64, amplitude: Float = 0.2) -> [Float] {
        var generator = SplitMix64(seed: seed)
        let count = Int(self.sampleRate * seconds)
        return (0..<count).map { _ in
            amplitude * (Float(generator.nextUnitInterval()) * 2 - 1)
        }
    }
}

/// Deterministic PRNG so a failing audio test reproduces exactly.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func nextUnitInterval() -> Double {
        self.state &+= 0x9E37_79B9_7F4A_7C15
        var z = self.state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
}
