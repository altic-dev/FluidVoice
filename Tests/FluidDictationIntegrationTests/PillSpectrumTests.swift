import AVFoundation
@testable import FluidVoice_Debug
import QuartzCore
import XCTest

final class PillSpectrumTests: XCTestCase {
    private func tone(_ frequency: Double, amplitude: Double = 0.1, rate: Double = 16_000, count: Int = 2048) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    private func analyze(_ samples: [Float], rate: Double = 16_000) -> SIMD8<Float> {
        let analyzer = PillSpectrumAnalyzer(sampleRate: rate)
        return samples.withUnsafeBufferPointer { analyzer.analyze($0).amplitudes }
    }

    private func levels(_ samples: [Float], count: Int, sensitivity: Double) -> [Double] {
        let result = samples.withUnsafeBufferPointer { PillSpectrumAnalyzer().analyze($0) }
        return PillMeterMapping.levels(result.amplitudes, count: count, sensitivity: sensitivity, rms: result.rms)
    }

    func testSilenceNoiseAndFiniteBounds() {
        for samples in [[Float](repeating: 0, count: 2048), self.tone(700, amplitude: 0.0001), [.nan, .infinity, -.infinity]] {
            let values = self.levels(samples, count: 6, sensitivity: 0.4)
            XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
            XCTAssertEqual(values.max(), 0)
        }
    }

    func testFrequencySweepAndNarrowPeaksSurviveEveryCount() throws {
        let centers = [220.0, 400, 700, 1200, 2000, 3200, 4500, 5500]
        for (band, frequency) in centers.enumerated() {
            let amplitudes = self.analyze(self.tone(frequency, amplitude: 0.5))
            XCTAssertEqual((0..<8).max { amplitudes[$0] < amplitudes[$1] }, band)
            for count in 3...8 {
                let values = self.levels(self.tone(frequency, amplitude: 0.5), count: count, sensitivity: 0.4)
                XCTAssertGreaterThan(try XCTUnwrap(values.max()), 0.8)
                XCTAssertLessThanOrEqual(values.filter { $0 > 0.1 }.count, 3)
                XCTAssertEqual(try values.firstIndex(of: XCTUnwrap(values.max())), min(count - 1, (2 * band + 1) * count / 16))
            }
        }
    }

    func testAmplitudeLadderSensitivityAndVowelSibilantShape() throws {
        let maxima = [0.0001, 0.005, 0.015, 0.04, 0.1, 0.3, 0.6].map {
            self.levels(self.tone(400, amplitude: $0), count: 6, sensitivity: 0.4).max() ?? 0
        }
        XCTAssertEqual(maxima, maxima.sorted())
        XCTAssertEqual(maxima.first, 0)
        XCTAssertEqual(maxima.last, 1)
        let vowel = zip(self.tone(220, amplitude: 0.1), self.tone(700, amplitude: 0.045)).map(+)
        // Deterministic, densely spaced high-band mixture approximates unvoiced noise.
        var sibilant = [Float](repeating: 0, count: 2048)
        for frequency in stride(from: 4100.0, through: 5900, by: 113) {
            let part = self.tone(frequency, amplitude: 0.015)
            for index in part.indices {
                sibilant[index] += part[index]
            }
        }
        let low = self.levels(vowel, count: 6, sensitivity: 0.4)
        let high = self.levels(sibilant, count: 6, sensitivity: 0.4)
        XCTAssertGreaterThan(try XCTUnwrap(low.prefix(3).max()), try XCTUnwrap(low.suffix(2).max()) + 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(high.suffix(2).max()), try XCTUnwrap(high.prefix(3).max()) + 0.5)
        let samples = self.tone(700, amplitude: 0.015)
        let more = self.levels(samples, count: 6, sensitivity: 0.1)
        let less = self.levels(samples, count: 6, sensitivity: 0.8)
        XCTAssertGreaterThan(try XCTUnwrap(more.max()), try XCTUnwrap(less.max()))
    }

    func testBassDoesNotSaturateAtMaximumSensitivity() throws {
        // Keep ordinary low speech expressive, quiet rumble still, and loud peaks
        // possible even at the most sensitive setting.
        for count in 3...8 {
            let weak = self.levels(self.tone(220, amplitude: 0.002), count: count, sensitivity: 0.01)
            let ordinary = self.levels(self.tone(220, amplitude: 0.02), count: count, sensitivity: 0.01)
            let strong = self.levels(self.tone(220, amplitude: 0.5), count: count, sensitivity: 0.01)
            XCTAssertEqual(weak[0], 0)
            XCTAssertGreaterThan(ordinary[0], 0.5)
            XCTAssertLessThan(ordinary[0], 0.7)
            XCTAssertGreaterThan(strong[0], 0.95)
        }
        // The second/low-mid region is also less eager, without silencing it.
        let mid = self.levels(self.tone(400, amplitude: 0.02), count: 6, sensitivity: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(mid.max()), 0.5)
        XCTAssertLessThan(try XCTUnwrap(mid.max()), 0.85)
    }

    func testSpeechPresenceCalibrationIsLinearAndKeepsRMSIndependent() {
        for frequency in [2000.0, 3200, 5500] {
            for amplitude in [0.005, 0.02, 0.08] {
                let bands = self.analyze(self.tone(frequency, amplitude: amplitude))
                let peak = (0..<8).map { Double(bands[$0]) }.max() ?? 0
                let gainDB = min(12, max(0, 9 * log2(frequency / 800)))
                let expected = amplitude * pow(10, gainDB / 20)
                XCTAssertEqual(peak, expected, accuracy: expected * 0.02)
            }
        }
        let quiet = self.analyze(self.tone(220, amplitude: 0.02))[0]
        let loud = self.analyze(self.tone(220, amplitude: 0.08))[0]
        XCTAssertEqual(loud / quiet, 4, accuracy: 0.001)
        // RMS remains an independent, unweighted capture measurement.
        let samples = self.tone(220, amplitude: 0.08)
        let result = samples.withUnsafeBufferPointer { PillSpectrumAnalyzer().analyze($0) }
        XCTAssertEqual(result.rms, Float(0.08 / sqrt(2)), accuracy: 0.001)
    }

    func testSpectralShapeIsIndependentOfOverallLoudness() throws {
        let quiet = SIMD8<Float>(0.01, 0.007, 0.004, 0.002, 0, 0, 0, 0)
        let loud = quiet * 2
        for count in 3...8 {
            let first = PillMeterMapping.levels(quiet, count: count, sensitivity: 0.01, rms: 0.02)
            let second = PillMeterMapping.levels(loud, count: count, sensitivity: 0.01, rms: 0.04)
            let firstPeak = try XCTUnwrap(first.max())
            let secondPeak = try XCTUnwrap(second.max())
            XCTAssertGreaterThan(secondPeak, firstPeak)
            for index in first.indices {
                XCTAssertEqual(first[index] / firstPeak, second[index] / secondPeak, accuracy: 0.000_001)
            }
        }
    }

    func testPresenceCannotNormalizeTinyNoiseButUnvoicedSpeechWakesHighBars() throws {
        let boostedNoise = SIMD8<Float>(repeating: 0.003)
        XCTAssertEqual(PillMeterMapping.levels(boostedNoise, count: 6, sensitivity: 0.01, rms: 0.0002), [Double](repeating: 0, count: 6))
        let samples = self.tone(5500, amplitude: 0.003)
        let result = samples.withUnsafeBufferPointer { PillSpectrumAnalyzer().analyze($0) }
        let levels = PillMeterMapping.levels(result.amplitudes, count: 6, sensitivity: 0.01, rms: result.rms)
        XCTAssertGreaterThan(try XCTUnwrap(levels.suffix(2).max()), 0.7)
        XCTAssertEqual(try XCTUnwrap(levels.prefix(3).max()), 0)
        XCTAssertEqual(PillMeterMapping.levels(boostedNoise, count: 6, sensitivity: 0.01, rms: .nan), [Double](repeating: 0, count: 6))
    }

    func testFormantsNearBandBoundariesDriveMiddleBarsWithoutDistantMotion() {
        // Real PCM near the old hard boundaries: a middle band must hear its
        // overlapping window, while distant frequency regions remain dots.
        let lowerFormant = self.levels(self.tone(750, amplitude: 0.025), count: 6, sensitivity: 0.01)
        let upperFormant = self.levels(self.tone(1250, amplitude: 0.025), count: 6, sensitivity: 0.01)
        XCTAssertGreaterThan(lowerFormant[2], 0.15)
        XCTAssertGreaterThan(upperFormant[3], 0.15)
        XCTAssertEqual(lowerFormant[5], 0)
        XCTAssertEqual(upperFormant[5], 0)
    }

    func testActualSampleRatesAndReset() {
        for rate in [8000.0, 16_000, 44_100, 48_000, 96_000] {
            let amplitudes = self.analyze(self.tone(1200, rate: rate, count: Int(rate / 10)), rate: rate)
            XCTAssertEqual((0..<8).max { amplitudes[$0] < amplitudes[$1] }, 3)
        }
        let analyzer = PillSpectrumAnalyzer()
        _ = self.tone(700).withUnsafeBufferPointer { analyzer.analyze($0) }
        analyzer.reset()
        let zero = [Float](repeating: 0, count: 160).withUnsafeBufferPointer { analyzer.analyze($0) }
        XCTAssertEqual(zero.amplitudes, .zero)
    }

    func testDynamicsEquivalentAt30_60_120HzAndNoDoubleIntegration() {
        var results: [Double] = []
        for hz in [30, 60, 120] {
            var dynamics = PillMeterDynamics()
            _ = dynamics.advance(target: [1], at: 0)
            for tick in 1...hz {
                _ = dynamics.advance(target: [1], at: Double(tick) / Double(hz))
            }
            for tick in 1...(hz / 10) {
                _ = dynamics.advance(target: [0], at: 1 + Double(tick) / Double(hz))
            }
            results.append(dynamics.levels[0])
            let before = dynamics.levels
            XCTAssertEqual(dynamics.advance(target: [1], at: 1.1), before)
            _ = dynamics.advance(target: [0], at: 5)
            XCTAssertEqual(dynamics.levels, [0])
        }
        for value in results {
            XCTAssertEqual(value, exp(-0.1 / 0.095), accuracy: 0.000_001)
        }
    }

    func testEveryCountAndSpokenSendGeometry() {
        for count in 3...8 {
            for width in [32.0, 46] {
                let geometry = PillMeterGeometry(count: count, availableWidth: width, availableHeight: 30)
                XCTAssertLessThanOrEqual(geometry.groupWidth, width + 0.0001)
                XCTAssertEqual(geometry.maximumHeight, 28)
                if count <= 6 {
                    XCTAssertEqual(geometry.width, 8.0 / 3, accuracy: 0.000_001)
                }
            }
        }
        XCTAssertEqual(PillMeterGeometry(count: 6, availableWidth: 46, availableHeight: 30).groupWidth, 26)
    }

    func testAnalyzerPerformance() {
        let analyzer = PillSpectrumAnalyzer()
        let samples = self.tone(700)
        var durations: [Double] = []
        for _ in 0..<1000 {
            let start = CACurrentMediaTime()
            _ = samples.withUnsafeBufferPointer { analyzer.analyze($0) }
            durations.append((CACurrentMediaTime() - start) * 1000)
        }
        durations.sort()
        print("PILL_ANALYSIS p50_ms=\(durations[500]) p95_ms=\(durations[950]) max_ms=\(durations[999]) n=1000")
        XCTAssertLessThan(durations[950], 2)
    }

    @MainActor
    func testDefaultAndBackupCompatibility() throws {
        let settings = SettingsStore.shared
        let previous = UserDefaults.standard.object(forKey: "PillBarCount")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "PillBarCount")
            } else {
                UserDefaults.standard.removeObject(forKey: "PillBarCount")
            }
        }
        UserDefaults.standard.removeObject(forKey: "PillBarCount")
        XCTAssertEqual(settings.pillBarCount, 6)
        for count in 3...8 {
            settings.pillBarCount = count; XCTAssertEqual(settings.pillBarCount, count)
        }
        settings.pillBarCount = 99
        XCTAssertEqual(settings.pillBarCount, 6)
        let encoded = try JSONEncoder().encode(settings.makeBackupPayload())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "pillBarCount")
        let legacy = try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.pillBarCount)
        settings.pillBarCount = 5
        settings.restore(from: legacy)
        XCTAssertEqual(settings.pillBarCount, 5, "A legacy backup must preserve an existing explicit choice")
        UserDefaults.standard.removeObject(forKey: "PillBarCount")
        settings.restore(from: legacy)
        XCTAssertEqual(settings.pillBarCount, 6, "An unset choice still defaults to six")
        for value in [-1, 0, 2, 9] {
            XCTAssertEqual(SettingsStore.validPillBarCount(value), 6)
        }
    }
}
