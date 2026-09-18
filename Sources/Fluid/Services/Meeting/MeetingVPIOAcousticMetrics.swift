#if DEBUG

    import Accelerate
    import Foundation

    // MARK: - Metric records

    nonisolated struct MeetingVPIOAcousticDelayMetrics: Codable, Equatable, Sendable {
        /// Positive means the captured signal lags the rendered reference on the shared host-time
        /// grid. Negative is physically impossible for an acoustic path and therefore evidence of a
        /// timestamp-domain error rather than of a fast echo.
        var signedSeconds: Double?
        var peakToMedianRatio: Double?
        var firstHalfSignedSeconds: Double?
        var secondHalfSignedSeconds: Double?
        /// Half the split-half spread, floored at the sample quantum. Not a confidence interval.
        var uncertaintySeconds: Double?
        var quantizationSeconds: Double
        var maxLagSeconds: Double
        var resolved: Bool
        var reasons: [MeetingVPIOAcousticReason]
    }

    nonisolated struct MeetingVPIOAcousticBandMetrics: Codable, Equatable, Sendable {
        var lowHz: Double
        var highHz: Double
        var binCount: Int
        var frameCount: Int
        var supportedCellCount: Int
        /// Share of (frame, bin) cells where the reference actually excited this band. A band with
        /// no excitation cannot report attenuation, however quiet the capture is.
        var supportFraction: Double
        var coherence: Double?
        /// 10·log10(referenceBandEnergy / capturedBandEnergy). Positive means the captured band is
        /// quieter than the rendered band. Uncalibrated: it mixes the electrical reference with an
        /// acoustic capture, so only differences between variants on one unchanged rig are readable.
        var attenuationDB: Double?
        var referenceEnergyFraction: Double
        var capturedEnergyFraction: Double
        var supported: Bool
        var coherent: Bool
        var reasons: [MeetingVPIOAcousticReason]
    }

    nonisolated struct MeetingVPIOAcousticMeasurement: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var sampleRate: Double
        var referenceFrameCount: Int
        var capturedFrameCount: Int
        var analysisStartFrame: Int
        var analysisFrameCount: Int
        var referenceRMS: Double
        var referencePeak: Double
        var capturedRMS: Double
        var capturedPeak: Double
        var capturedNoiseFloorRMS: Double?
        var signalToNoiseFloorDB: Double?
        /// Broadband counterpart of `MeetingVPIOAcousticBandMetrics.attenuationDB`, same caveat.
        var attenuationDB: Double?
        var attenuationUncertaintyDB: Double?
        var delay: MeetingVPIOAcousticDelayMetrics
        var bands: [MeetingVPIOAcousticBandMetrics]
        var supportedBandCount: Int
        var coherentBandCount: Int
        /// True only when the delay resolved *and* enough bands were both excited and coherent.
        /// A false `valid` never means "no echo"; it means this measurement says nothing.
        var valid: Bool
        var reasons: [MeetingVPIOAcousticReason]
    }

    // MARK: - Metrics

    nonisolated enum MeetingVPIOAcousticMetrics {
        static let frameLength = 1_024
        static let hopLength = 512
        static let maxLagSeconds = 0.5
        static let minimumAnalysisFrames = 4_096
        static let minimumReferenceRMS: Float = 1e-4
        static let minimumCapturedRMS: Float = 1e-5
        static let minimumDelayConfidence = MeetingEchoSignalScorer.minimumDelayConfidence
        static let maximumSplitHalfDisagreementSeconds = 0.005
        static let minimumBandSupportFraction = 0.25
        static let minimumBandCoherence = 0.30
        static let minimumCoherentBandCount = 2
        static let minimumBandFrameCount = 8
        /// Fraction of the reference peak that still counts as excitation when bounding the
        /// analysis window; below it the segment is the stimulus's own silence.
        static let excitationOnsetFraction: Float = 0.005

        static let bands: [(lowHz: Double, highHz: Double)] = [
            (180, 400), (400, 900), (900, 1_800), (1_800, 3_600), (3_600, 7_800)
        ]

        /// `reference` and `captured` share one index origin: index 0 is the same nominal instant on
        /// the host-time grid. `silencePrefixFrames` marks the leading span the reference is known to
        /// be silent in, used for the captured noise floor.
        static func measure(
            reference: [Float],
            captured: [Float],
            sampleRate: Double,
            silencePrefixFrames: Int
        ) -> MeetingVPIOAcousticMeasurement {
            let quantization = sampleRate > 0 ? 1 / sampleRate : 0
            let emptyDelay = MeetingVPIOAcousticDelayMetrics(
                signedSeconds: nil,
                peakToMedianRatio: nil,
                firstHalfSignedSeconds: nil,
                secondHalfSignedSeconds: nil,
                uncertaintySeconds: nil,
                quantizationSeconds: quantization,
                maxLagSeconds: Self.maxLagSeconds,
                resolved: false,
                reasons: []
            )
            var measurement = MeetingVPIOAcousticMeasurement(
                schemaVersion: MeetingVPIOAcousticMeasurement.currentSchemaVersion,
                sampleRate: sampleRate,
                referenceFrameCount: reference.count,
                capturedFrameCount: captured.count,
                analysisStartFrame: 0,
                analysisFrameCount: 0,
                referenceRMS: Double(MeetingVPIOAcousticStimulus.rms(reference)),
                referencePeak: Double(MeetingVPIOAcousticStimulus.peak(reference)),
                capturedRMS: Double(MeetingVPIOAcousticStimulus.rms(captured)),
                capturedPeak: Double(MeetingVPIOAcousticStimulus.peak(captured)),
                capturedNoiseFloorRMS: nil,
                signalToNoiseFloorDB: nil,
                attenuationDB: nil,
                attenuationUncertaintyDB: nil,
                delay: emptyDelay,
                bands: [],
                supportedBandCount: 0,
                coherentBandCount: 0,
                valid: false,
                reasons: []
            )

            guard sampleRate > 0,
                  reference.count >= Self.minimumAnalysisFrames,
                  captured.count >= Self.minimumAnalysisFrames
            else {
                measurement.reasons.append(.insufficientFrames)
                return measurement
            }
            if Float(measurement.referenceRMS) < Self.minimumReferenceRMS {
                measurement.reasons.append(.referenceBelowExcitationFloor)
            }
            if Float(measurement.capturedRMS) < Self.minimumCapturedRMS {
                measurement.reasons.append(.capturedBelowNoiseFloor)
            }
            guard measurement.reasons.isEmpty else { return measurement }

            measurement.delay = Self.estimateDelay(reference: reference, captured: captured, sampleRate: sampleRate)
            measurement.reasons.append(contentsOf: measurement.delay.reasons)

            // Unresolved delay still gets band numbers, at zero lag, so the sidecar shows why the
            // run was rejected instead of showing nothing.
            let delayFrames = Int(((measurement.delay.signedSeconds ?? 0) * sampleRate).rounded())
            let aligned = Self.shift(reference, byFrames: delayFrames, targetCount: captured.count)

            guard let analysis = Self.excitedRange(aligned) else {
                measurement.reasons.append(.emptyAnalysisWindow)
                return measurement
            }
            measurement.analysisStartFrame = analysis.lowerBound
            measurement.analysisFrameCount = analysis.count

            let alignedWindow = Array(aligned[analysis])
            let capturedWindow = Array(captured[analysis])
            if let floor = Self.noiseFloorRMS(captured, prefixFrames: min(silencePrefixFrames, analysis.lowerBound)) {
                measurement.capturedNoiseFloorRMS = Double(floor)
                measurement.signalToNoiseFloorDB = Self.decibels(
                    numerator: MeetingVPIOAcousticStimulus.rms(capturedWindow),
                    denominator: floor
                )
            }
            measurement.attenuationDB = Self.decibels(
                numerator: MeetingVPIOAcousticStimulus.rms(alignedWindow),
                denominator: MeetingVPIOAcousticStimulus.rms(capturedWindow)
            )
            measurement.attenuationUncertaintyDB = Self.splitHalfAttenuationSpreadDB(
                reference: alignedWindow,
                captured: capturedWindow
            )

            measurement.bands = Self.bandMetrics(
                reference: alignedWindow,
                captured: capturedWindow,
                sampleRate: sampleRate
            )
            measurement.supportedBandCount = measurement.bands.filter { $0.supported }.count
            measurement.coherentBandCount = measurement.bands.filter { $0.coherent }.count
            if measurement.coherentBandCount < Self.minimumCoherentBandCount {
                measurement.reasons.append(.tooFewCoherentBands)
            }
            measurement.valid = measurement.delay.resolved && measurement.reasons.isEmpty
            return measurement
        }

        // MARK: Delay

        private static func estimateDelay(
            reference: [Float],
            captured: [Float],
            sampleRate: Double
        ) -> MeetingVPIOAcousticDelayMetrics {
            let quantization = 1 / sampleRate
            var metrics = MeetingVPIOAcousticDelayMetrics(
                signedSeconds: nil,
                peakToMedianRatio: nil,
                firstHalfSignedSeconds: nil,
                secondHalfSignedSeconds: nil,
                uncertaintySeconds: nil,
                quantizationSeconds: quantization,
                maxLagSeconds: Self.maxLagSeconds,
                resolved: false,
                reasons: []
            )

            // Shared with the production echo scorer, including its sign convention: the estimate is
            // the lag of the first argument relative to the second.
            guard let full = MeetingEchoSignalScorer.estimateDelay(
                mic: captured,
                reference: reference,
                sampleRate: sampleRate,
                maxLagSeconds: Self.maxLagSeconds
            ) else {
                metrics.reasons.append(.delayUnresolved)
                return metrics
            }
            metrics.signedSeconds = full.seconds
            metrics.peakToMedianRatio = full.confidence
            if full.seconds < 0 {
                metrics.reasons.append(.negativeDelay)
            }

            let halfCount = min(reference.count, captured.count) / 2
            if halfCount >= MeetingEchoSignalScorer.frameLength {
                let firstHalf = MeetingEchoSignalScorer.estimateDelay(
                    mic: Array(captured[0..<halfCount]),
                    reference: Array(reference[0..<halfCount]),
                    sampleRate: sampleRate,
                    maxLagSeconds: Self.maxLagSeconds
                )
                let secondHalf = MeetingEchoSignalScorer.estimateDelay(
                    mic: Array(captured[halfCount..<(2 * halfCount)]),
                    reference: Array(reference[halfCount..<(2 * halfCount)]),
                    sampleRate: sampleRate,
                    maxLagSeconds: Self.maxLagSeconds
                )
                metrics.firstHalfSignedSeconds = firstHalf?.seconds
                metrics.secondHalfSignedSeconds = secondHalf?.seconds
                if let first = firstHalf?.seconds, let second = secondHalf?.seconds {
                    let spread = abs(first - second) / 2
                    metrics.uncertaintySeconds = max(spread, quantization)
                    if abs(first - second) > Self.maximumSplitHalfDisagreementSeconds {
                        metrics.reasons.append(.splitHalfDelayDisagreement)
                    }
                }
            }
            if metrics.uncertaintySeconds == nil {
                metrics.uncertaintySeconds = quantization
            }
            if full.confidence < Self.minimumDelayConfidence {
                metrics.reasons.append(.delayConfidenceBelowThreshold)
            }
            metrics.resolved = metrics.reasons.isEmpty
            return metrics
        }

        // MARK: Bands

        private static func bandMetrics(
            reference: [Float],
            captured: [Float],
            sampleRate: Double
        ) -> [MeetingVPIOAcousticBandMetrics] {
            guard let spectra = Self.crossSpectra(reference: reference, captured: captured) else {
                return Self.bands.map { band in
                    MeetingVPIOAcousticBandMetrics(
                        lowHz: band.lowHz,
                        highHz: band.highHz,
                        binCount: 0,
                        frameCount: 0,
                        supportedCellCount: 0,
                        supportFraction: 0,
                        coherence: nil,
                        attenuationDB: nil,
                        referenceEnergyFraction: 0,
                        capturedEnergyFraction: 0,
                        supported: false,
                        coherent: false,
                        reasons: [.insufficientFrames]
                    )
                }
            }

            let binWidth = sampleRate / Double(Self.frameLength)
            let totalReferenceEnergy = spectra.referencePower.reduce(0, +)
            let totalCapturedEnergy = spectra.capturedPower.reduce(0, +)

            return Self.bands.map { band in
                var referenceEnergy = 0.0
                var capturedEnergy = 0.0
                var weightedCoherence = 0.0
                var coherenceWeight = 0.0
                var binCount = 0
                var supportedCells = 0

                // Bin 0 carries DC and Nyquist packed together in vDSP's real FFT; never used.
                for bin in 1..<spectra.binCount {
                    let frequency = Double(bin) * binWidth
                    guard frequency >= band.lowHz, frequency < band.highHz else { continue }
                    binCount += 1
                    let referencePower = spectra.referencePower[bin]
                    let capturedPower = spectra.capturedPower[bin]
                    referenceEnergy += referencePower
                    capturedEnergy += capturedPower
                    supportedCells += spectra.supportedCells[bin]
                    guard referencePower > 0, capturedPower > 0 else { continue }
                    let crossMagnitudeSquared = spectra.crossReal[bin] * spectra.crossReal[bin]
                        + spectra.crossImaginary[bin] * spectra.crossImaginary[bin]
                    let coherence = min(1, crossMagnitudeSquared / (referencePower * capturedPower))
                    weightedCoherence += coherence * referencePower
                    coherenceWeight += referencePower
                }

                let cellCount = binCount * spectra.frameCount
                let supportFraction = cellCount > 0 ? Double(supportedCells) / Double(cellCount) : 0
                let coherence = coherenceWeight > 0 ? weightedCoherence / coherenceWeight : nil
                let supported = supportFraction >= Self.minimumBandSupportFraction
                    && spectra.frameCount >= Self.minimumBandFrameCount
                let attenuation = supported && referenceEnergy > 0 && capturedEnergy > 0
                    ? 10 * log10(referenceEnergy / capturedEnergy)
                    : nil
                var reasons: [MeetingVPIOAcousticReason] = []
                if !supported { reasons.append(.bandSupportBelowThreshold) }
                let coherent = supported && (coherence ?? 0) >= Self.minimumBandCoherence
                if supported, !coherent { reasons.append(.bandCoherenceBelowFloor) }

                return MeetingVPIOAcousticBandMetrics(
                    lowHz: band.lowHz,
                    highHz: band.highHz,
                    binCount: binCount,
                    frameCount: spectra.frameCount,
                    supportedCellCount: supportedCells,
                    supportFraction: supportFraction,
                    coherence: coherence,
                    attenuationDB: attenuation,
                    referenceEnergyFraction: totalReferenceEnergy > 0 ? referenceEnergy / totalReferenceEnergy : 0,
                    capturedEnergyFraction: totalCapturedEnergy > 0 ? capturedEnergy / totalCapturedEnergy : 0,
                    supported: supported,
                    coherent: coherent,
                    reasons: reasons
                )
            }
        }

        private struct CrossSpectra {
            var binCount: Int
            var frameCount: Int
            var referencePower: [Double]
            var capturedPower: [Double]
            var crossReal: [Double]
            var crossImaginary: [Double]
            var supportedCells: [Int]
        }

        /// Welch-style accumulation over Hann frames. Absolute scaling is deliberately not undone:
        /// every published number here is a ratio, so vDSP's real-FFT factor cancels.
        private static func crossSpectra(reference: [Float], captured: [Float]) -> CrossSpectra? {
            let count = min(reference.count, captured.count)
            guard count >= Self.frameLength else { return nil }
            let frameCount = (count - Self.frameLength) / Self.hopLength + 1
            guard frameCount > 0 else { return nil }

            let log2n = vDSP_Length(log2(Double(Self.frameLength)))
            guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
            defer { vDSP_destroy_fftsetup(setup) }

            var window = [Float](repeating: 0, count: Self.frameLength)
            vDSP_hann_window(&window, vDSP_Length(Self.frameLength), Int32(vDSP_HANN_NORM))
            var windowPower: Float = 0
            vDSP_svesq(window, 1, &windowPower, vDSP_Length(window.count))
            // Parseval-consistent floor: the same RMS threshold expressed in accumulated bin units.
            let supportFloor = Double(Self.minimumReferenceRMS * Self.minimumReferenceRMS * windowPower)

            let binCount = Self.frameLength / 2
            var spectra = CrossSpectra(
                binCount: binCount,
                frameCount: frameCount,
                referencePower: [Double](repeating: 0, count: binCount),
                capturedPower: [Double](repeating: 0, count: binCount),
                crossReal: [Double](repeating: 0, count: binCount),
                crossImaginary: [Double](repeating: 0, count: binCount),
                supportedCells: [Int](repeating: 0, count: binCount)
            )

            for frame in 0..<frameCount {
                let start = frame * Self.hopLength
                var referenceFrame = [Float](repeating: 0, count: Self.frameLength)
                var capturedFrame = [Float](repeating: 0, count: Self.frameLength)
                vDSP_vmul(Array(reference[start..<start + Self.frameLength]), 1, window, 1, &referenceFrame, 1, vDSP_Length(Self.frameLength))
                vDSP_vmul(Array(captured[start..<start + Self.frameLength]), 1, window, 1, &capturedFrame, 1, vDSP_Length(Self.frameLength))

                guard let referenceSpectrum = Self.forwardFFT(&referenceFrame, setup: setup, log2n: log2n),
                      let capturedSpectrum = Self.forwardFFT(&capturedFrame, setup: setup, log2n: log2n)
                else { return nil }

                for bin in 1..<binCount {
                    let rr = Double(referenceSpectrum.real[bin]), ri = Double(referenceSpectrum.imaginary[bin])
                    let cr = Double(capturedSpectrum.real[bin]), ci = Double(capturedSpectrum.imaginary[bin])
                    let referencePower = rr * rr + ri * ri
                    spectra.referencePower[bin] += referencePower
                    spectra.capturedPower[bin] += cr * cr + ci * ci
                    spectra.crossReal[bin] += cr * rr + ci * ri
                    spectra.crossImaginary[bin] += ci * rr - cr * ri
                    if referencePower > supportFloor { spectra.supportedCells[bin] += 1 }
                }
            }
            return spectra
        }

        private struct Spectrum {
            var real: [Float]
            var imaginary: [Float]
        }

        private static func forwardFFT(_ signal: inout [Float], setup: FFTSetup, log2n: vDSP_Length) -> Spectrum? {
            let halfCount = Self.frameLength / 2
            var real = [Float](repeating: 0, count: halfCount)
            var imaginary = [Float](repeating: 0, count: halfCount)
            var spectrum: Spectrum?
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    guard let realBase = realPointer.baseAddress, let imaginaryBase = imaginaryPointer.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                    signal.withUnsafeBufferPointer { signalPointer in
                        guard let signalBase = signalPointer.baseAddress else { return }
                        signalBase.withMemoryRebound(to: DSPComplex.self, capacity: halfCount) { complexPointer in
                            vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(halfCount))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    spectrum = Spectrum(real: Array(realPointer), imaginary: Array(imaginaryPointer))
                }
            }
            return spectrum
        }

        // MARK: Helpers

        private static func shift(_ signal: [Float], byFrames frames: Int, targetCount: Int) -> [Float] {
            var result = [Float](repeating: 0, count: targetCount)
            for index in 0..<targetCount {
                let source = index - frames
                guard source >= 0, source < signal.count else { continue }
                result[index] = signal[source]
            }
            return result
        }

        /// Span the reference actually excites, so the RMS ratio is not diluted by the stimulus's
        /// own leading and trailing silence.
        private static func excitedRange(_ signal: [Float]) -> Range<Int>? {
            let peak = MeetingVPIOAcousticStimulus.peak(signal)
            guard peak > 0 else { return nil }
            let threshold = peak * Self.excitationOnsetFraction
            guard let first = signal.firstIndex(where: { abs($0) > threshold }),
                  let last = signal.lastIndex(where: { abs($0) > threshold }),
                  last > first
            else { return nil }
            return first..<(last + 1)
        }

        private static func noiseFloorRMS(_ captured: [Float], prefixFrames: Int) -> Float? {
            guard prefixFrames >= Self.hopLength, prefixFrames <= captured.count else { return nil }
            return MeetingVPIOAcousticStimulus.rms(Array(captured[0..<prefixFrames]))
        }

        private static func decibels(numerator: Float, denominator: Float) -> Double? {
            guard numerator > 0, denominator > 0 else { return nil }
            return 20 * log10(Double(numerator) / Double(denominator))
        }

        /// Spread between the two halves of the analysis window. Widens whenever gain drifted
        /// (AGC) or the acoustic path moved mid-stimulus; it is a stability figure, not a CI.
        private static func splitHalfAttenuationSpreadDB(reference: [Float], captured: [Float]) -> Double? {
            let count = min(reference.count, captured.count)
            let half = count / 2
            guard half >= Self.hopLength else { return nil }
            guard let first = Self.decibels(
                numerator: MeetingVPIOAcousticStimulus.rms(Array(reference[0..<half])),
                denominator: MeetingVPIOAcousticStimulus.rms(Array(captured[0..<half]))
            ), let second = Self.decibels(
                numerator: MeetingVPIOAcousticStimulus.rms(Array(reference[half..<(2 * half)])),
                denominator: MeetingVPIOAcousticStimulus.rms(Array(captured[half..<(2 * half)]))
            ) else { return nil }
            return abs(first - second) / 2
        }
    }

#endif
