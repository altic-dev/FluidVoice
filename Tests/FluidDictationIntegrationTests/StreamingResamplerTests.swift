@testable import FluidVoice_Debug
import XCTest

@MainActor
final class StreamingResamplerTests: XCTestCase {
    func testPassthroughReturnsIdenticalArrayAt16kHz() {
        let samples: [Float] = [0, 0.125, -0.25, 0.5, -0.75, 1, -1, 0.0625]
        let resampler = StreamingResampler()

        let output = resampler.process(samples, sourceRate: 16_000)

        XCTAssertEqual(output, samples)
    }

    func testLengthRatioFrom48kHzTo16kHz() {
        let samples = Self.sineWave(frequency: 440, sampleRate: 48_000, duration: 1)
        let resampler = StreamingResampler()

        let output = resampler.process(samples, sourceRate: 48_000)

        XCTAssertLessThanOrEqual(abs(output.count - 16_000), 32)
    }

    func testAntiAliasingSuppresses10kHzFoldoverTo6kHz() {
        let aliasedSource = Self.sineWave(frequency: 10_000, sampleRate: 24_000, duration: 1)
        let inBandSource = Self.sineWave(frequency: 6000, sampleRate: 24_000, duration: 1)

        let aliasedOutput = StreamingResampler().process(aliasedSource, sourceRate: 24_000)
        let inBandOutput = StreamingResampler().process(inBandSource, sourceRate: 24_000)

        let aliasedPower = Goertzel.power(
            in: aliasedOutput,
            targetFrequency: 6000,
            sampleRate: 16_000
        )
        let inBandPower = Goertzel.power(
            in: inBandOutput,
            targetFrequency: 6000,
            sampleRate: 16_000
        )

        XCTAssertGreaterThan(inBandPower, 0)
        XCTAssertLessThan(10 * log10(aliasedPower / inBandPower), -30)
    }

    func testInBand4kHzTonePowerIsPreserved() {
        let source = Self.sineWave(frequency: 4000, sampleRate: 48_000, duration: 1)
        let groundTruth = Self.sineWave(frequency: 4000, sampleRate: 16_000, duration: 1)

        let output = StreamingResampler().process(source, sourceRate: 48_000)

        let convertedPower = Goertzel.power(
            in: output,
            targetFrequency: 4000,
            sampleRate: 16_000
        )
        let groundTruthPower = Goertzel.power(
            in: groundTruth,
            targetFrequency: 4000,
            sampleRate: 16_000
        )

        XCTAssertGreaterThan(groundTruthPower, 0)
        XCTAssertLessThan(abs(10 * log10(convertedPower / groundTruthPower)), 3)
    }

    func testChunkedConversionMaintainsContinuity() {
        let source = Self.sineWave(frequency: 440, sampleRate: 48_000, duration: 1)
        let chunkedResampler = StreamingResampler()
        var chunkedOutput: [Float] = []

        var startIndex = 0
        while startIndex < source.count {
            let endIndex = min(startIndex + 128, source.count)
            chunkedOutput.append(contentsOf: chunkedResampler.process(
                Array(source[startIndex..<endIndex]),
                sourceRate: 48_000
            ))
            startIndex = endIndex
        }

        let oneShotOutput = StreamingResampler().process(source, sourceRate: 48_000)

        XCTAssertLessThanOrEqual(abs(chunkedOutput.count - oneShotOutput.count), 64)
        let comparableFrameCount = min(chunkedOutput.count, oneShotOutput.count)
        for index in 0..<comparableFrameCount {
            XCTAssertLessThanOrEqual(
                abs(chunkedOutput[index] - oneShotOutput[index]),
                1e-3,
                "Chunked output diverged from one-shot output at index \(index)"
            )
        }
        for index in 1..<chunkedOutput.count {
            XCTAssertLessThanOrEqual(
                abs(chunkedOutput[index] - chunkedOutput[index - 1]),
                0.5,
                "Adjacent jump exceeded threshold at index \(index)"
            )
        }
    }

    func testFlushReturnsBufferedTailAndConverterKeepsWorking() {
        let source = Self.sineWave(frequency: 440, sampleRate: 48_000, duration: 1)
        let resampler = StreamingResampler()

        let output = resampler.process(source, sourceRate: 48_000)
        let tail = resampler.flush()

        XCTAssertGreaterThan(tail.count, 0)
        XCTAssertLessThan(tail.count, 512)
        XCTAssertLessThanOrEqual(abs((output.count + tail.count) - 16_000), 64)

        let secondOutput = resampler.process(source, sourceRate: 48_000)
        XCTAssertLessThanOrEqual(abs(secondOutput.count - 16_000), 64)
    }

    private static func sineWave(
        frequency: Double,
        sampleRate: Double,
        duration: Double,
        amplitude: Double = 0.8
    ) -> [Float] {
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { index in
            Float(amplitude * sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }
}

private enum Goertzel {
    static func power(in samples: [Float], targetFrequency: Double, sampleRate: Double) -> Double {
        guard samples.isEmpty == false, sampleRate > 0 else { return 0 }

        let normalizedFrequency = targetFrequency / sampleRate
        let coefficient = 2 * cos(2 * Double.pi * normalizedFrequency)
        var q1 = 0.0
        var q2 = 0.0

        for sample in samples {
            let q0 = coefficient * q1 - q2 + Double(sample)
            q2 = q1
            q1 = q0
        }

        return q1 * q1 + q2 * q2 - coefficient * q1 * q2
    }
}
