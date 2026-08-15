import Accelerate
import Foundation

nonisolated struct DelayEstimate: Equatable, Sendable {
    let seconds: TimeInterval
    let confidence: Double
}

nonisolated enum TurnEchoVerdict: Equatable, Sendable {
    case echo
    case containsLocalSpeech
    case unknown
}

nonisolated struct EchoFrameScores: Equatable, Sendable {
    let fractions: [Double]
    let hopSeconds: Double
}

/// Separates far-end echo from local speech by correlating the mic against what the meeting app
/// played. Calibrated on one 3.2-minute Zoom recording: pure echo scored median 0.62-0.82 with
/// low-runs of 0.24-0.59 s, local speech median 0.00-0.38 with low-runs of 0.96-10.27 s. Since the
/// statistic is `1 - residual/mic`, additive double talk only rescues a turn when local speech
/// carries ~1.86x the echo energy - true near the talker, false for a quiet interjection.
nonisolated enum MeetingEchoSignalScorer {
    static let frameLength = 1024
    static let hopLength = 256
    static let blockSeconds = 2.0
    static let localSpeechFractionThreshold = 0.35
    /// Calibrated against frame-*start* span, which undercounts coverage by 48 ms.
    static let minimumLocalSpeechRunSeconds = 0.75
    static let echoMedianThreshold = 0.5
    /// The rescue's `minimumLocalSpeechRunSeconds` is absolute, so on a long turn it fires on a few
    /// percent of the span: measured 0.75s inside a 22.4s turn at median 0.91 — indistinguishable
    /// from a 21.5s turn at median 0.86 whose run happened to stop at 0.48s. A turn is only denied
    /// the rescue when it is BOTH overwhelmingly explained by the far end AND the low run is a
    /// trivial share of it; genuine double talk clears the share test (a 1.0s burst in a 3.0s turn
    /// is 33%), and calibrated mixed turns sit near median 0.38, far under the median test.
    static let overwhelminglyExplainedMedian = 0.8
    static let minimumLocalSpeechRunFraction = 0.15
    static let minimumDelayConfidence = 8.0
    static let minimumSignalRMS: Float = 1e-4
    static let minimumScoreableFraction = 0.5
    /// Fewer frames than this and the per-bin fit is exact, manufacturing "echo" from noise.
    static let minimumFramesPerBlock = 8
    static let minimumUsableBinFraction = 0.5
    /// Bounds estimateDelay's FFT size (and memory) for pathologically long turns.
    static let maximumDelayEstimationSeconds = 20.0

    private static let hannWindowPower: Float = {
        let window = MeetingEchoSignalScorer.hannWindow(MeetingEchoSignalScorer.frameLength)
        var sum: Float = 0
        vDSP_svesq(window, 1, &sum, vDSP_Length(window.count))
        return sum
    }()

    /// Divide-by-zero guard for PHAT normalization, not a physical threshold.
    private static let phatMagnitudeFloor: Float = 1e-12

    static func estimateDelay(
        mic: [Float],
        reference: [Float],
        sampleRate: Double,
        maxLagSeconds: TimeInterval
    ) -> DelayEstimate? {
        guard mic.count >= self.frameLength, reference.count >= self.frameLength else { return nil }
        guard self.rms(mic) >= self.minimumSignalRMS, self.rms(reference) >= self.minimumSignalRMS else { return nil }

        let fullN = max(mic.count, reference.count)
        let maxSamples = self.safeInt(self.maximumDelayEstimationSeconds * sampleRate)
            .map { max($0, self.frameLength) } ?? fullN
        let start = max(0, (fullN - maxSamples) / 2)
        let boundedMic = self.boundedSlice(mic, start: start, maxLength: maxSamples)
        let boundedReference = self.boundedSlice(reference, start: start, maxLength: maxSamples)
        guard !boundedMic.isEmpty, !boundedReference.isEmpty else { return nil }

        let n = max(boundedMic.count, boundedReference.count)
        let fftSize = self.nextPowerOfTwo(2 * n)
        let log2n = vDSP_Length(log2(Double(fftSize)))

        // Rectangular: a per-signal Hann would give each a different envelope, biasing toward lag 0.
        var micPadded = self.zeroPadded(boundedMic, fftSize: fftSize)
        var refPadded = self.zeroPadded(boundedReference, fftSize: fftSize)

        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        guard let micSpectrum = self.forwardFFT(&micPadded, fftSize: fftSize, setup: setup, log2n: log2n),
              let refSpectrum = self.forwardFFT(&refPadded, fftSize: fftSize, setup: setup, log2n: log2n)
        else { return nil }

        let crossCorrelation = self.phatCrossCorrelation(
            mic: micSpectrum, reference: refSpectrum, fftSize: fftSize, setup: setup, log2n: log2n
        )
        guard !crossCorrelation.isEmpty else { return nil }

        guard let maxLagSamplesRaw = self.safeInt(maxLagSeconds * sampleRate) else { return nil }
        let maxLagSamples = min(maxLagSamplesRaw, fftSize / 2 - 1)
        guard maxLagSamples > 0 else { return nil }

        var bestLag = 0
        var bestMagnitude: Float = -1
        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(2 * maxLagSamples + 1)
        for lag in -maxLagSamples...maxLagSamples {
            // Negative lags wrap to the tail of the circular cross-correlation buffer.
            let index = lag >= 0 ? lag : fftSize + lag
            let magnitude = abs(crossCorrelation[index])
            magnitudes.append(magnitude)
            if magnitude > bestMagnitude {
                bestMagnitude = magnitude
                bestLag = lag
            }
        }

        let median = self.median(magnitudes)
        guard median > 0 else { return nil }
        let confidence = Double(bestMagnitude) / Double(median)
        let seconds = Double(bestLag) / sampleRate
        return DelayEstimate(seconds: seconds, confidence: confidence)
    }

    /// NaN marks unscoreable frames: "no information" must never read as "no echo".
    static func explainedFractions(
        mic: [Float],
        reference: [Float],
        sampleRate: Double,
        delaySeconds: TimeInterval
    ) -> EchoFrameScores {
        let hopSeconds = Double(self.hopLength) / sampleRate
        let shiftedReference = self.shift(reference, bySeconds: delaySeconds, sampleRate: sampleRate, targetCount: mic.count)
        guard mic.count >= self.frameLength else { return EchoFrameScores(fractions: [], hopSeconds: hopSeconds) }

        let hopCount = (mic.count - self.frameLength) / self.hopLength + 1
        guard hopCount > 0 else { return EchoFrameScores(fractions: [], hopSeconds: hopSeconds) }

        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(self.frameLength))), FFTRadix(kFFTRadix2)) else {
            return EchoFrameScores(fractions: [], hopSeconds: hopSeconds)
        }
        defer { vDSP_destroy_fftsetup(setup) }
        let log2n = vDSP_Length(log2(Double(self.frameLength)))
        let window = self.hannWindow(self.frameLength)

        var micFrameRMS: [Float] = []
        var micSpectra: [Spectrum] = []
        var refSpectra: [Spectrum] = []
        micFrameRMS.reserveCapacity(hopCount)
        micSpectra.reserveCapacity(hopCount)
        refSpectra.reserveCapacity(hopCount)
        for i in 0..<hopCount {
            let start = i * self.hopLength
            var m = Array(mic[start..<start + self.frameLength])
            var r = Array(shiftedReference[start..<start + self.frameLength])
            vDSP_vmul(m, 1, window, 1, &m, 1, vDSP_Length(self.frameLength))
            vDSP_vmul(r, 1, window, 1, &r, 1, vDSP_Length(self.frameLength))
            micFrameRMS.append(self.rms(m))
            guard let mSpectrum = self.forwardFFT(&m, fftSize: self.frameLength, setup: setup, log2n: log2n),
                  let rSpectrum = self.forwardFFT(&r, fftSize: self.frameLength, setup: setup, log2n: log2n)
            else { return EchoFrameScores(fractions: [Double](repeating: .nan, count: hopCount), hopSeconds: hopSeconds) }
            micSpectra.append(mSpectrum)
            refSpectra.append(rSpectrum)
        }

        let framesPerBlock = max(self.minimumFramesPerBlock, Int((self.blockSeconds * sampleRate) / Double(self.hopLength)))
        var result = [Double](repeating: .nan, count: hopCount)

        var blockRanges: [Range<Int>] = []
        var blockStart = 0
        while blockStart < hopCount {
            let blockEnd = min(blockStart + framesPerBlock, hopCount)
            blockRanges.append(blockStart..<blockEnd)
            blockStart = blockEnd
        }
        // Short tail can't be fit alone; fold it into the preceding block.
        if blockRanges.count > 1, blockRanges[blockRanges.count - 1].count < self.minimumFramesPerBlock {
            let tail = blockRanges.removeLast()
            let previous = blockRanges.removeLast()
            blockRanges.append(previous.lowerBound..<tail.upperBound)
        }
        for range in blockRanges where range.count >= self.minimumFramesPerBlock {
            self.scoreBlock(
                micFrameRMS: micFrameRMS, micSpectra: micSpectra, refSpectra: refSpectra,
                range: range, into: &result
            )
        }
        return EchoFrameScores(fractions: result, hopSeconds: hopSeconds)
    }

    private static func scoreBlock(
        micFrameRMS: [Float],
        micSpectra: [Spectrum],
        refSpectra: [Spectrum],
        range: Range<Int>,
        into result: inout [Double]
    ) {
        let binCount = micSpectra[range.lowerBound].real.count
        var crossReal = [Float](repeating: 0, count: binCount)
        var crossImag = [Float](repeating: 0, count: binCount)
        var refPower = [Float](repeating: 0, count: binCount)

        for i in range {
            let m = micSpectra[i], r = refSpectra[i]
            for k in 0..<binCount {
                crossReal[k] += m.real[k] * r.real[k] + m.imag[k] * r.imag[k]
                crossImag[k] += m.imag[k] * r.real[k] - m.real[k] * r.imag[k]
                refPower[k] += r.real[k] * r.real[k] + r.imag[k] * r.imag[k]
            }
        }

        var hReal = [Float](repeating: 0, count: binCount)
        var hImag = [Float](repeating: 0, count: binCount)
        var referenceUsableBins = 0
        // Parseval, so the floor lands in refPower's accumulated units rather than orders off.
        let refFloor = Float(self.minimumSignalRMS * self.minimumSignalRMS) * self.hannWindowPower * Float(range.count)
        // vDSP packs DC and Nyquist together in bin 0; excluded so H never mixes the two.
        for k in 1..<binCount where refPower[k] > refFloor {
            hReal[k] = crossReal[k] / refPower[k]
            hImag[k] = crossImag[k] / refPower[k]
            referenceUsableBins += 1
        }
        let usableBinFraction = Double(referenceUsableBins) / Double(binCount - 1)
        guard usableBinFraction >= self.minimumUsableBinFraction else { return }

        for i in range {
            let micRMS = micFrameRMS[i]
            guard micRMS >= self.minimumSignalRMS else { continue }
            let m = micSpectra[i], r = refSpectra[i]
            var micEnergy: Float = 0
            var residualEnergy: Float = 0
            for k in 1..<binCount {
                micEnergy += m.real[k] * m.real[k] + m.imag[k] * m.imag[k]
                let predictedReal = hReal[k] * r.real[k] - hImag[k] * r.imag[k]
                let predictedImag = hReal[k] * r.imag[k] + hImag[k] * r.real[k]
                let residualReal = m.real[k] - predictedReal
                let residualImag = m.imag[k] - predictedImag
                residualEnergy += residualReal * residualReal + residualImag * residualImag
            }
            guard micEnergy > 0 else { continue }
            let fraction = 1.0 - Double(residualEnergy / micEnergy)
            result[i] = min(1.0, max(0.0, fraction))
        }
    }

    static func verdict(
        _ scores: EchoFrameScores,
        minimumScoreableFraction requiredScoreableFraction: Double = MeetingEchoSignalScorer.minimumScoreableFraction
    ) -> TurnEchoVerdict {
        let explainedFractions = scores.fractions
        let hopSeconds = scores.hopSeconds
        guard !explainedFractions.isEmpty else { return .unknown }

        // Hiding real speech is the costly failure, so the rescue runs before the coverage gate;
        // only the echo verdict requires enough scoreable frames.
        var longestLowRun = 0
        var currentRun = 0
        var gapRun = 0
        for value in explainedFractions {
            if !value.isNaN, value < self.localSpeechFractionThreshold {
                currentRun += 1
                gapRun = 0
                longestLowRun = max(longestLowRun, currentRun)
            } else if value.isNaN {
                gapRun += 1
                // A gap long enough to itself be a run means the thread is lost.
                if Double(gapRun) * hopSeconds >= self.minimumLocalSpeechRunSeconds {
                    currentRun = 0
                }
            } else {
                currentRun = 0
                gapRun = 0
            }
        }
        let scoreableIndices = explainedFractions.indices.filter { !explainedFractions[$0].isNaN }
        let scoreableFraction = Double(scoreableIndices.count) / Double(explainedFractions.count)
        let scoreableValues = scoreableIndices.map { explainedFractions[$0] }
        let median = scoreableValues.isEmpty ? Double.nan : self.median(scoreableValues)
        let lowRunSeconds = Double(longestLowRun) * hopSeconds
        let turnSeconds = Double(explainedFractions.count) * hopSeconds
        let lowRunFraction = turnSeconds > 0 ? lowRunSeconds / turnSeconds : 0
        let isTrivialRunInExplainedTurn = !median.isNaN
            && scoreableFraction >= requiredScoreableFraction
            && median >= self.overwhelminglyExplainedMedian
            && lowRunFraction < self.minimumLocalSpeechRunFraction

        if !isTrivialRunInExplainedTurn, lowRunSeconds >= self.minimumLocalSpeechRunSeconds {
            return .containsLocalSpeech
        }

        guard scoreableFraction >= requiredScoreableFraction else { return .unknown }
        if !median.isNaN, median >= self.echoMedianThreshold {
            return .echo
        }
        return .unknown
    }

    private static func rms(_ signal: [Float]) -> Float {
        guard !signal.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_measqv(signal, 1, &result, vDSP_Length(signal.count))
        return sqrt(result)
    }

    private static func safeInt(_ value: Double) -> Int? {
        guard value.isFinite, value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }

    private static func boundedSlice(_ signal: [Float], start: Int, maxLength: Int) -> [Float] {
        guard start < signal.count, maxLength > 0 else { return [] }
        let end = min(signal.count, start + maxLength)
        return Array(signal[start..<end])
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var power = 1
        while power < value { power <<= 1 }
        return power
    }

    private static func hannWindow(_ length: Int) -> [Float] {
        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        return window
    }

    private static func zeroPadded(_ signal: [Float], fftSize: Int) -> [Float] {
        var padded = [Float](repeating: 0, count: fftSize)
        padded.replaceSubrange(0..<signal.count, with: signal)
        return padded
    }

    private struct Spectrum {
        var real: [Float]
        var imag: [Float]
    }

    private static func forwardFFT(
        _ signal: inout [Float], fftSize: Int, setup: FFTSetup, log2n: vDSP_Length
    ) -> Spectrum? {
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var spectrum: Spectrum?
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                signal.withUnsafeBufferPointer { signalPtr in
                    signalPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                spectrum = Spectrum(real: Array(realPtr), imag: Array(imagPtr))
            }
        }
        return spectrum
    }

    private static func phatCrossCorrelation(
        mic: Spectrum, reference: Spectrum, fftSize: Int, setup: FFTSetup, log2n: vDSP_Length
    ) -> [Float] {
        let halfN = fftSize / 2
        var crossReal = [Float](repeating: 0, count: halfN)
        var crossImag = [Float](repeating: 0, count: halfN)

        for k in 0..<halfN {
            let mr = mic.real[k], mi = mic.imag[k]
            let rr = reference.real[k], ri = reference.imag[k]
            crossReal[k] = mr * rr + mi * ri
            crossImag[k] = mi * rr - mr * ri
        }
        // Bin 0 packs DC and Nyquist together in vDSP's real-FFT format; zeroed to avoid mixing them.
        crossReal[0] = 0
        crossImag[0] = 0

        for k in 0..<halfN {
            let magnitude = sqrt(crossReal[k] * crossReal[k] + crossImag[k] * crossImag[k])
            guard magnitude > self.phatMagnitudeFloor else {
                crossReal[k] = 0
                crossImag[k] = 0
                continue
            }
            crossReal[k] /= magnitude
            crossImag[k] /= magnitude
        }

        var result = [Float](repeating: 0, count: fftSize)
        crossReal.withUnsafeMutableBufferPointer { realPtr in
            crossImag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                result.withUnsafeMutableBufferPointer { resultPtr in
                    resultPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ztoc(&split, 1, complexPtr, 2, vDSP_Length(halfN))
                    }
                }
            }
        }
        var scale = Float(1.0 / Double(fftSize))
        vDSP_vsmul(result, 1, &scale, &result, 1, vDSP_Length(fftSize))
        return result
    }

    private static func shift(_ signal: [Float], bySeconds seconds: TimeInterval, sampleRate: Double, targetCount: Int) -> [Float] {
        // An unusable delay means no reference, not a trap.
        guard let offset = self.safeInt((seconds * sampleRate).rounded()) else {
            return [Float](repeating: 0, count: targetCount)
        }
        var result = [Float](repeating: 0, count: targetCount)
        for i in 0..<targetCount {
            let sourceIndex = i - offset
            guard sourceIndex >= 0, sourceIndex < signal.count else { continue }
            result[i] = signal[sourceIndex]
        }
        return result
    }

    static func median<T: FloatingPoint>(_ values: [T]) -> T {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
