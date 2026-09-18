#if DEBUG

    import Accelerate
    import Foundation

    // MARK: - Reason codes

    /// Machine-stable reasons. Every unusable number carries one; absence of a reason is never
    /// how a caller learns a metric was skipped.
    nonisolated enum MeetingVPIOAcousticReason: String, Codable, Sendable {
        case insufficientFrames
        case referenceBelowExcitationFloor
        case capturedBelowNoiseFloor
        case delayUnresolved
        case delayConfidenceBelowThreshold
        case splitHalfDelayDisagreement
        case emptyAnalysisWindow
        case bandSupportBelowThreshold
        case bandCoherenceBelowFloor
        case tooFewCoherentBands
        case captureWindowIncomplete
        case renderStartUnresolved
        case renderReadbackSilent
        case controlNotApplied
        case stimulusOutsideSafetyBounds
        case captureNotRunning
        case probeDisabled
        case outputRouteUnavailable
        case outputVolumeUnreadable
        case outputLevelUnsafe
        case renderTimingInvalid
        case playbackTimedOut
        case negativeDelay
        case captureGap
        case captureOverlap
        /// The sample values are present, but their PTS was synthesized while host time was
        /// unavailable. They are not valid evidence for a shared-clock delay measurement.
        case captureTimingSynthesized
        /// A synthesized timing run has not yet reached a valid host-time resynchronization.
        case captureTimingResyncRequired
        case probeCancelled
    }

    // MARK: - Stimulus

    /// Numeric description of the rendered stimulus. Records what was actually synthesized, not
    /// what was requested: `measuredPeak`/`measuredRMS` are computed from the emitted samples.
    nonisolated struct MeetingVPIOAcousticStimulusDescriptor: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var seed: UInt64
        var sampleRate: Double
        var totalFrameCount: Int
        var leadingSilenceFrameCount: Int
        var chirpFrameCount: Int
        var gapFrameCount: Int
        var speechLikeFrameCount: Int
        var trailingSilenceFrameCount: Int
        var chirpStartHz: Double
        var chirpEndHz: Double
        var speechF0StartHz: Double
        var speechF0EndHz: Double
        var targetPeak: Double
        var measuredPeak: Double
        var measuredRMS: Double
        var safetyPeakLimit: Double
        var safetyMinimumRMS: Double
        var safetyMaximumRMS: Double
        var withinSafetyBounds: Bool
    }

    /// Deterministic diagnostic stimulus: a log sweep (alignment-rich, broadband) followed by a
    /// speech-like voiced/fricative segment (representative of what VPIO is tuned for). Identical
    /// bytes for identical `seed` and `sampleRate` so two runs are directly comparable.
    nonisolated enum MeetingVPIOAcousticStimulus {
        static let defaultSeed: UInt64 = 0x5F1D_A00D_C0DE_0001

        /// Bounded so a diagnostic can never drive the speaker into an uncomfortable level. The
        /// runner refuses to render a stimulus that lands outside these.
        static let targetPeak: Float = 0.25
        static let safetyPeakLimit: Float = 0.35
        static let safetyMinimumRMS: Float = 0.02
        static let safetyMaximumRMS: Float = 0.15
        /// Player gain applied on top of the already-bounded stimulus.
        static let maximumRenderVolume: Float = 0.6

        static let leadingSilenceSeconds = 0.20
        static let chirpSeconds = 1.00
        static let gapSeconds = 0.20
        static let speechLikeSeconds = 1.20
        static let trailingSilenceSeconds = 0.30

        static let chirpStartHz = 180.0
        static let chirpEndHz = 7_800.0
        static let speechF0StartHz = 115.0
        static let speechF0EndHz = 145.0

        nonisolated struct Generated: Equatable, Sendable {
            var samples: [Float]
            var descriptor: MeetingVPIOAcousticStimulusDescriptor

            var totalSeconds: Double {
                self.descriptor.sampleRate > 0
                    ? Double(self.descriptor.totalFrameCount) / self.descriptor.sampleRate
                    : 0
            }
        }

        static func make(sampleRate: Double, seed: UInt64 = MeetingVPIOAcousticStimulus.defaultSeed) -> Generated? {
            guard sampleRate >= 8_000, sampleRate <= 192_000 else { return nil }

            let lead = Self.frames(Self.leadingSilenceSeconds, sampleRate)
            let chirp = Self.frames(Self.chirpSeconds, sampleRate)
            let gap = Self.frames(Self.gapSeconds, sampleRate)
            let speech = Self.frames(Self.speechLikeSeconds, sampleRate)
            let trail = Self.frames(Self.trailingSilenceSeconds, sampleRate)

            var samples = [Float](repeating: 0, count: lead + chirp + gap + speech + trail)
            Self.writeLogSweep(into: &samples, at: lead, count: chirp, sampleRate: sampleRate)
            Self.writeSpeechLike(into: &samples, at: lead + chirp + gap, count: speech, sampleRate: sampleRate, seed: seed)

            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
            if peak > 0 {
                var scale = Self.targetPeak / peak
                vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(samples.count))
            }
            // Belt-and-braces against a future segment change: never emit past the safety ceiling.
            var lowerLimit = -Self.safetyPeakLimit
            var upperLimit = Self.safetyPeakLimit
            vDSP_vclip(samples, 1, &lowerLimit, &upperLimit, &samples, 1, vDSP_Length(samples.count))

            let measuredPeak = Self.peak(samples)
            let measuredRMS = Self.rms(samples)
            let withinBounds = measuredPeak <= Self.safetyPeakLimit
                && measuredRMS >= Self.safetyMinimumRMS
                && measuredRMS <= Self.safetyMaximumRMS

            return Generated(
                samples: samples,
                descriptor: MeetingVPIOAcousticStimulusDescriptor(
                    schemaVersion: MeetingVPIOAcousticStimulusDescriptor.currentSchemaVersion,
                    seed: seed,
                    sampleRate: sampleRate,
                    totalFrameCount: samples.count,
                    leadingSilenceFrameCount: lead,
                    chirpFrameCount: chirp,
                    gapFrameCount: gap,
                    speechLikeFrameCount: speech,
                    trailingSilenceFrameCount: trail,
                    chirpStartHz: Self.chirpStartHz,
                    chirpEndHz: Self.chirpEndHz,
                    speechF0StartHz: Self.speechF0StartHz,
                    speechF0EndHz: Self.speechF0EndHz,
                    targetPeak: Double(Self.targetPeak),
                    measuredPeak: Double(measuredPeak),
                    measuredRMS: Double(measuredRMS),
                    safetyPeakLimit: Double(Self.safetyPeakLimit),
                    safetyMinimumRMS: Double(Self.safetyMinimumRMS),
                    safetyMaximumRMS: Double(Self.safetyMaximumRMS),
                    withinSafetyBounds: withinBounds
                )
            )
        }

        private static func frames(_ seconds: Double, _ sampleRate: Double) -> Int {
            max(0, Int((seconds * sampleRate).rounded()))
        }

        /// Exponential sweep: constant energy per octave, so every analysis band gets excitation
        /// and the autocorrelation peak stays narrow enough to time-align on.
        private static func writeLogSweep(into samples: inout [Float], at offset: Int, count: Int, sampleRate: Double) {
            guard count > 1 else { return }
            let duration = Double(count) / sampleRate
            let ratio = Self.chirpEndHz / Self.chirpStartHz
            let logRatio = log(ratio)
            let fadeFrames = min(count / 4, Self.frames(0.010, sampleRate))
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let phase = 2 * Double.pi * Self.chirpStartHz * duration / logRatio * (pow(ratio, t / duration) - 1)
                let value = sin(phase) * Self.fadeEnvelope(index: i, count: count, fadeFrames: fadeFrames)
                samples[offset + i] = Float(value)
            }
        }

        /// Voiced harmonic stack under fixed formants, a syllabic envelope, and two deterministic
        /// fricative bursts. Not speech — a signal whose spectrum and modulation resemble it.
        private static func writeSpeechLike(
            into samples: inout [Float],
            at offset: Int,
            count: Int,
            sampleRate: Double,
            seed: UInt64
        ) {
            guard count > 1 else { return }
            let duration = Double(count) / sampleRate
            let formants: [(center: Double, bandwidth: Double, gain: Double)] = [
                (500, 140, 1.0), (1_500, 220, 0.55), (2_600, 320, 0.30)
            ]
            let fadeFrames = min(count / 4, Self.frames(0.020, sampleRate))
            let nyquist = sampleRate / 2
            var generator = MeetingVPIOAcousticPRNG(seed: seed)
            var previousNoise = 0.0
            var phase = 0.0

            for i in 0..<count {
                let t = Double(i) / sampleRate
                let progress = t / duration
                let f0 = Self.speechF0StartHz + (Self.speechF0EndHz - Self.speechF0StartHz) * progress
                phase += 2 * Double.pi * f0 / sampleRate

                var voiced = 0.0
                var harmonic = 1
                while Double(harmonic) * f0 < min(nyquist, 8_000) {
                    let frequency = Double(harmonic) * f0
                    var weight = 0.0
                    for formant in formants {
                        let offsetHz = (frequency - formant.center) / formant.bandwidth
                        weight += formant.gain * exp(-offsetHz * offsetHz)
                    }
                    // 1/h source tilt on top of the formant envelope.
                    voiced += weight * sin(phase * Double(harmonic)) / Double(harmonic)
                    harmonic += 1
                }

                // First-difference tilt turns flat PRNG noise into a fricative-shaped band.
                let white = generator.nextSymmetricUnit()
                let tilted = white - previousNoise
                previousNoise = white
                let fricative = tilted * Self.fricativeEnvelope(progress: progress)

                let syllabic = 0.35 + 0.65 * (0.5 - 0.5 * cos(2 * Double.pi * 3.5 * t))
                let value = (voiced * syllabic + fricative * 0.5)
                    * Self.fadeEnvelope(index: i, count: count, fadeFrames: fadeFrames)
                samples[offset + i] = Float(value)
            }
        }

        /// Two fixed bursts; deterministic in `progress` so the descriptor fully predicts them.
        private static func fricativeEnvelope(progress: Double) -> Double {
            let bursts = [(start: 0.22, end: 0.30), (start: 0.62, end: 0.72)]
            for burst in bursts where progress >= burst.start && progress < burst.end {
                let local = (progress - burst.start) / (burst.end - burst.start)
                return 0.5 - 0.5 * cos(2 * Double.pi * local)
            }
            return 0
        }

        private static func fadeEnvelope(index: Int, count: Int, fadeFrames: Int) -> Double {
            guard fadeFrames > 0 else { return 1 }
            if index < fadeFrames {
                return 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(fadeFrames))
            }
            let tail = count - 1 - index
            if tail < fadeFrames {
                return 0.5 - 0.5 * cos(Double.pi * Double(tail) / Double(fadeFrames))
            }
            return 1
        }

        static func rms(_ signal: [Float]) -> Float {
            guard !signal.isEmpty else { return 0 }
            var meanSquare: Float = 0
            vDSP_measqv(signal, 1, &meanSquare, vDSP_Length(signal.count))
            return sqrt(meanSquare)
        }

        static func peak(_ signal: [Float]) -> Float {
            guard !signal.isEmpty else { return 0 }
            var value: Float = 0
            vDSP_maxmgv(signal, 1, &value, vDSP_Length(signal.count))
            return value
        }
    }

    /// SplitMix64. Foundation's RNG is seeded per-process; a probe stimulus must be reproducible
    /// across processes and machines.
    nonisolated struct MeetingVPIOAcousticPRNG {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            self.state &+= 0x9E37_79B9_7F4A_7C15
            var z = self.state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in [-1, 1].
        mutating func nextSymmetricUnit() -> Double {
            let unit = Double(self.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
            return unit * 2 - 1
        }
    }

#endif
