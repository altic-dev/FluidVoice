import Accelerate
import Foundation

/// Delivery metrics measured from the raw microphone PCM rather than from the
/// transcript, so they are identical no matter which of the ASR providers ran.
///
/// Timing vocabulary, because three different "durations" matter and mixing them
/// up produces nonsense pace numbers:
/// - `durationSeconds` — the whole recording, including dead air at either end.
/// - `speechSpanSeconds` — first speech to last speech. Pace is measured over this,
///   so hitting record and pausing to collect yourself does not count against WPM.
/// - `speakingSeconds` — time actually above the silence threshold. Articulation
///   rate is measured over this, which is what separates "talks fast" from
///   "never pauses".
/// `nonisolated` on purpose: the target builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise bind this
/// type — and its Codable/Equatable conformances — to the main actor and make the
/// off-main analysis in PracticeSessionService illegal.
nonisolated struct DeliveryMetrics: Codable, Equatable {
    struct Pause: Codable, Equatable {
        let startSeconds: Double
        let durationSeconds: Double
    }

    /// Whether the recording is good enough for the delivery numbers to mean anything.
    ///
    /// Every other metric here is computed against an *adaptive* threshold, which is
    /// what makes them robust across rooms and microphones — and also what makes them
    /// fail silently. A recording of nothing but room tone has its threshold fitted to
    /// the room tone, so it reads as continuous confident speech: 99.6% voiced, zero
    /// pauses, a pitch track fitted to noise. The numbers stay precise while becoming
    /// entirely fictional, which is worse than refusing to answer.
    struct SignalQuality: Codable, Equatable {
        /// Separation between the loud and quiet populations of the level
        /// distribution (95th minus 10th percentile). Speech typically clears 20 dB;
        /// a room with no speech in it sits near zero.
        let signalToNoiseDb: Double
        /// Level of the loud population, for catching recordings that are simply faint.
        let speechLevelDb: Double
        /// Fraction of samples pinned at full scale — the opposite failure, distortion.
        let clippedSampleRatio: Double
        let isReliable: Bool
        /// Why the recording was rejected, phrased for the user. Nil when reliable.
        let warning: String?

        static let unknown = SignalQuality(
            signalToNoiseDb: 0,
            speechLevelDb: 0,
            clippedSampleRatio: 0,
            isReliable: false,
            warning: "No audio was analyzed."
        )
    }

    // Basics
    let durationSeconds: Double
    let speechSpanSeconds: Double
    let speakingSeconds: Double
    let totalWords: Int

    // Pauses (silence runs inside the speech span only)
    let pauses: [Pause]
    let totalPauseSeconds: Double
    let longestPauseSeconds: Double
    let speakingRatio: Double

    // Pace
    let wordsPerMinute: Double
    let articulationRate: Double

    // Fillers
    let fillerCounts: [String: Int]
    let fillersPerMinute: Double

    // Pitch — 0 in the contour means unvoiced
    let meanPitchHz: Double
    let pitchRangeHz: Double
    let pitchStdDevHz: Double
    let pitchContour: [Double]

    // Volume, dB relative to full scale (so values are negative)
    let meanLevelDb: Double
    let dynamicRangeDb: Double
    let levelStdDevDb: Double
    let energyContour: [Double]

    /// Spacing between contour samples, for plotting against a time axis.
    let contourIntervalSeconds: Double

    /// Read this before trusting anything above it.
    let quality: SignalQuality

    /// Carries a quality verdict onto an otherwise empty result, so a rejected
    /// recording can explain itself instead of reading as "nothing was captured".
    func replacingQuality(_ quality: SignalQuality) -> DeliveryMetrics {
        DeliveryMetrics(
            durationSeconds: self.durationSeconds,
            speechSpanSeconds: self.speechSpanSeconds,
            speakingSeconds: self.speakingSeconds,
            totalWords: self.totalWords,
            pauses: self.pauses,
            totalPauseSeconds: self.totalPauseSeconds,
            longestPauseSeconds: self.longestPauseSeconds,
            speakingRatio: self.speakingRatio,
            wordsPerMinute: self.wordsPerMinute,
            articulationRate: self.articulationRate,
            fillerCounts: self.fillerCounts,
            fillersPerMinute: self.fillersPerMinute,
            meanPitchHz: self.meanPitchHz,
            pitchRangeHz: self.pitchRangeHz,
            pitchStdDevHz: self.pitchStdDevHz,
            pitchContour: self.pitchContour,
            meanLevelDb: self.meanLevelDb,
            dynamicRangeDb: self.dynamicRangeDb,
            levelStdDevDb: self.levelStdDevDb,
            energyContour: self.energyContour,
            contourIntervalSeconds: self.contourIntervalSeconds,
            quality: quality
        )
    }

    var pauseCount: Int { self.pauses.count }
    var totalFillers: Int { self.fillerCounts.values.reduce(0, +) }

    /// Pauses long enough that an audience reads them as hesitation rather than emphasis.
    var longPauses: [Pause] { self.pauses.filter { $0.durationSeconds >= 2 } }

    static let empty = DeliveryMetrics(
        durationSeconds: 0,
        speechSpanSeconds: 0,
        speakingSeconds: 0,
        totalWords: 0,
        pauses: [],
        totalPauseSeconds: 0,
        longestPauseSeconds: 0,
        speakingRatio: 0,
        wordsPerMinute: 0,
        articulationRate: 0,
        fillerCounts: [:],
        fillersPerMinute: 0,
        meanPitchHz: 0,
        pitchRangeHz: 0,
        pitchStdDevHz: 0,
        pitchContour: [],
        meanLevelDb: 0,
        dynamicRangeDb: 0,
        levelStdDevDb: 0,
        energyContour: [],
        contourIntervalSeconds: 0,
        quality: .unknown
    )

    /// Compact rendering handed to the coaching LLM alongside the transcript.
    /// Units are spelled out because the model has to cite these numbers back.
    func summaryText() -> String {
        func f(_ value: Double, _ places: Int = 1) -> String {
            String(format: "%.\(places)f", value)
        }

        // Withhold the numbers rather than caveating them. A model handed unreliable
        // measurements plus a warning will still reason about them — we watched it
        // explain, fluently and precisely, a 24.5 WPM delivery that never happened.
        guard self.quality.isReliable else {
            return """
            DELIVERY METRICS UNAVAILABLE
            The recording could not be measured reliably: \(self.quality.warning ?? "unknown audio problem").
            Do not comment on pace, pauses, pitch, volume or filler rate, and do not \
            estimate them from the transcript. Say plainly that delivery could not be \
            measured this time and that the recording needs to be redone, then critique \
            the content only.
            """
        }

        var lines: [String] = []
        lines.append("MEASURED DELIVERY METRICS")
        lines.append("Duration: \(f(self.durationSeconds))s total, \(f(self.speechSpanSeconds))s from first to last word")
        lines.append("Words: \(self.totalWords)")
        lines.append("Speaking rate: \(f(self.wordsPerMinute)) WPM overall")
        lines.append("Articulation rate: \(f(self.articulationRate)) WPM excluding pauses")
        lines.append("Speaking vs silence: \(f(self.speakingRatio * 100))% of the speech span was voiced")

        lines.append("Pauses (>= 0.5s): \(self.pauseCount), totalling \(f(self.totalPauseSeconds))s")
        lines.append("Longest pause: \(f(self.longestPauseSeconds))s")
        if self.longPauses.isEmpty {
            lines.append("Pauses >= 2s: none")
        } else {
            let stamps = self.longPauses
                .map { "\(f($0.startSeconds))s for \(f($0.durationSeconds))s" }
                .joined(separator: ", ")
            lines.append("Pauses >= 2s: \(self.longPauses.count) (\(stamps))")
        }

        if self.fillerCounts.isEmpty {
            lines.append("Filler words: none detected")
        } else {
            let breakdown = self.fillerCounts
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .map { "\($0.key) x\($0.value)" }
                .joined(separator: ", ")
            lines.append("Filler words: \(self.totalFillers) total (\(breakdown)), \(f(self.fillersPerMinute)) per minute")
        }

        if self.meanPitchHz > 0 {
            lines.append("Pitch: mean \(f(self.meanPitchHz)) Hz, range \(f(self.pitchRangeHz)) Hz, standard deviation \(f(self.pitchStdDevHz)) Hz (lower = more monotone)")
        } else {
            lines.append("Pitch: no voiced audio detected")
        }

        lines.append("Volume: mean \(f(self.meanLevelDb)) dBFS, dynamic range \(f(self.dynamicRangeDb)) dB, standard deviation \(f(self.levelStdDevDb)) dB (lower = flatter delivery)")

        return lines.joined(separator: "\n")
    }
}

/// Manual decode in an extension (so the memberwise init survives) solely to give
/// `quality` a fallback: session files written before the signal-quality gate
/// existed lack the field, and wiping every measurement in them over one missing
/// key is worse than admitting the quality was never assessed.
nonisolated extension DeliveryMetrics {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            durationSeconds: try c.decode(Double.self, forKey: .durationSeconds),
            speechSpanSeconds: try c.decode(Double.self, forKey: .speechSpanSeconds),
            speakingSeconds: try c.decode(Double.self, forKey: .speakingSeconds),
            totalWords: try c.decode(Int.self, forKey: .totalWords),
            pauses: try c.decode([Pause].self, forKey: .pauses),
            totalPauseSeconds: try c.decode(Double.self, forKey: .totalPauseSeconds),
            longestPauseSeconds: try c.decode(Double.self, forKey: .longestPauseSeconds),
            speakingRatio: try c.decode(Double.self, forKey: .speakingRatio),
            wordsPerMinute: try c.decode(Double.self, forKey: .wordsPerMinute),
            articulationRate: try c.decode(Double.self, forKey: .articulationRate),
            fillerCounts: try c.decode([String: Int].self, forKey: .fillerCounts),
            fillersPerMinute: try c.decode(Double.self, forKey: .fillersPerMinute),
            meanPitchHz: try c.decode(Double.self, forKey: .meanPitchHz),
            pitchRangeHz: try c.decode(Double.self, forKey: .pitchRangeHz),
            pitchStdDevHz: try c.decode(Double.self, forKey: .pitchStdDevHz),
            pitchContour: try c.decode([Double].self, forKey: .pitchContour),
            meanLevelDb: try c.decode(Double.self, forKey: .meanLevelDb),
            dynamicRangeDb: try c.decode(Double.self, forKey: .dynamicRangeDb),
            levelStdDevDb: try c.decode(Double.self, forKey: .levelStdDevDb),
            energyContour: try c.decode([Double].self, forKey: .energyContour),
            contourIntervalSeconds: try c.decode(Double.self, forKey: .contourIntervalSeconds),
            quality: try c.decodeIfPresent(SignalQuality.self, forKey: .quality) ?? .unknown
        )
    }
}

/// Acoustic analysis over the 16 kHz mono PCM that `ASRService` already accumulates.
///
/// Pure and synchronous by design: no singletons, no settings reads, no actor
/// hops, so it can be unit-tested on synthetic PCM. Callers run it off the main
/// thread — a 10 minute speech is ~9.6 M samples.
///
/// ponytail: energy-threshold VAD + autocorrelation F0 with parabolic peak
/// interpolation. Upgrade to an ML VAD / YIN refinement if noisy-room accuracy
/// complains. Word-aligned metrics (rolling WPM, filler locations) need Parakeet
/// tokenTimings surfaced through ASRTranscriptionResult — v2.
nonisolated enum SpeechAnalysisService {
    // Calibration knobs. Real rooms are not the ideal case these defaults assume,
    // so leave them reachable rather than inlining the numbers.
    private static let frameSeconds = 0.020
    private static let pitchWindowSeconds = 0.050
    private static let minPauseSeconds = 0.5

    /// Floor borrowed from the live meter's noise gate in ASRService
    /// (`calculateAudioLevel`: rms < 0.002 is treated as silence) and its
    /// -55 dBFS normalization floor.
    private static let absoluteSilenceFloorDb = -50.0
    /// How far above the estimated room noise floor counts as speech.
    private static let silenceMarginDb = 10.0

    private static let minPitchHz = 60.0
    /// Above the top of the human speaking range on purpose: capping at ~400 Hz
    /// makes high voices wrap to a half-frequency octave error.
    private static let maxPitchHz = 500.0
    /// Normalized autocorrelation peak required to call a frame voiced.
    private static let voicingThreshold = 0.3
    /// How close to the best correlation an earlier peak must be to be preferred
    /// over it. Guards against reporting half or a third of the true pitch.
    private static let subharmonicTolerance = 0.9

    private static let maxContourPoints = 240

    /// Minimum separation between the loud and quiet populations for the delivery
    /// numbers to be trustworthy. Speech in a quiet room clears 30 dB and in a noisy
    /// one still clears ~18 dB; a recording of room tone alone sits under 8 dB. 12 dB
    /// sits in the empty space between those, well clear of both.
    private static let minSignalToNoiseDb = 12.0
    /// Below this the recording is simply too faint to analyze, however clean it is.
    private static let minSpeechLevelDb = -45.0
    /// Above this fraction of samples pinned at full scale, the waveform is distorted
    /// and every level-derived number is compressed.
    private static let maxClippedSampleRatio = 0.005

    static func analyze(
        pcm: [Float],
        sampleRate: Double = 16_000,
        rawTranscript: String,
        fillerWords: [String]
    ) -> DeliveryMetrics {
        guard !pcm.isEmpty, sampleRate > 0 else { return .empty }

        let duration = Double(pcm.count) / sampleRate
        let frameLength = max(1, Int(sampleRate * self.frameSeconds))
        let frameDuration = Double(frameLength) / sampleRate

        let levelsDb = self.frameLevelsDb(pcm: pcm, frameLength: frameLength)
        guard !levelsDb.isEmpty else { return .empty }

        let quality = self.assessQuality(pcm: pcm, levelsDb: levelsDb)

        let threshold = self.silenceThresholdDb(levelsDb: levelsDb)
        let isSpeech = levelsDb.map { $0 > threshold }

        // Trim dead air at the ends: waiting to start is not a rhetorical pause.
        guard let firstSpeech = isSpeech.firstIndex(of: true),
              let lastSpeech = isSpeech.lastIndex(of: true)
        else {
            // Nothing above the threshold. Carry the quality verdict out anyway, so the
            // user is told *why* rather than just "no audio".
            return .empty.replacingQuality(quality)
        }

        let speechSpanSeconds = Double(lastSpeech - firstSpeech + 1) * frameDuration
        let speakingFrames = isSpeech[firstSpeech...lastSpeech].filter { $0 }.count
        let speakingSeconds = Double(speakingFrames) * frameDuration

        let pauses = self.detectPauses(
            isSpeech: isSpeech,
            range: firstSpeech...lastSpeech,
            frameDuration: frameDuration
        )
        let totalPauseSeconds = pauses.reduce(0) { $0 + $1.durationSeconds }

        let words = self.words(in: rawTranscript)
        let fillerCounts = self.countFillers(words: words, fillerWords: fillerWords)

        let speechSpanMinutes = speechSpanSeconds / 60
        let speakingMinutes = speakingSeconds / 60

        let pitches = self.pitchTrack(pcm: pcm, sampleRate: sampleRate)
        let voiced = pitches.filter { $0 > 0 }

        let speakingLevels = zip(levelsDb, isSpeech).filter(\.1).map(\.0)

        return DeliveryMetrics(
            durationSeconds: duration,
            speechSpanSeconds: speechSpanSeconds,
            speakingSeconds: speakingSeconds,
            totalWords: words.count,
            pauses: pauses,
            totalPauseSeconds: totalPauseSeconds,
            longestPauseSeconds: pauses.map(\.durationSeconds).max() ?? 0,
            speakingRatio: speechSpanSeconds > 0 ? speakingSeconds / speechSpanSeconds : 0,
            wordsPerMinute: speechSpanMinutes > 0 ? Double(words.count) / speechSpanMinutes : 0,
            articulationRate: speakingMinutes > 0 ? Double(words.count) / speakingMinutes : 0,
            fillerCounts: fillerCounts,
            fillersPerMinute: speechSpanMinutes > 0
                ? Double(fillerCounts.values.reduce(0, +)) / speechSpanMinutes
                : 0,
            meanPitchHz: self.mean(voiced),
            pitchRangeHz: voiced.isEmpty ? 0 : (voiced.max()! - voiced.min()!),
            pitchStdDevHz: self.standardDeviation(voiced),
            pitchContour: self.downsample(pitches),
            meanLevelDb: self.mean(speakingLevels),
            dynamicRangeDb: self.percentileSpread(speakingLevels),
            levelStdDevDb: self.standardDeviation(speakingLevels),
            energyContour: self.downsample(levelsDb),
            contourIntervalSeconds: self.contourInterval(
                frameCount: levelsDb.count,
                frameDuration: frameDuration
            ),
            quality: quality
        )
    }

    // MARK: - Signal quality

    /// The gate. Runs on the same per-frame levels every other metric uses, so it
    /// costs one extra pass over the samples for clipping and nothing else.
    private static func assessQuality(pcm: [Float], levelsDb: [Double]) -> DeliveryMetrics.SignalQuality {
        let sorted = levelsDb.sorted()
        let noiseFloor = self.percentile(sorted, 0.10)
        let speechLevel = self.percentile(sorted, 0.95)
        let separation = speechLevel - noiseFloor

        var clipped = 0
        for sample in pcm where abs(sample) >= 0.99 { clipped += 1 }
        let clippedRatio = pcm.isEmpty ? 0 : Double(clipped) / Double(pcm.count)

        // Most specific failure first: a clipped recording is also loud, and a silent
        // one also has poor separation, so reporting the wrong cause would send the
        // user to fix the wrong thing.
        let warning: String?
        if clippedRatio > self.maxClippedSampleRatio {
            warning = "the input is clipping — lower the microphone gain or move further from it"
        } else if speechLevel < self.minSpeechLevelDb {
            warning = "the recording is too quiet — move closer to the microphone or raise its input level"
        } else if separation < self.minSignalToNoiseDb {
            warning = String(
                format: "speech is not clearly separated from background noise (%.0f dB of separation, %.0f dB needed)",
                separation,
                self.minSignalToNoiseDb
            )
        } else {
            warning = nil
        }

        return DeliveryMetrics.SignalQuality(
            signalToNoiseDb: separation,
            speechLevelDb: speechLevel,
            clippedSampleRatio: clippedRatio,
            isReliable: warning == nil,
            warning: warning
        )
    }

    // MARK: - Energy

    /// Per-frame RMS converted to dBFS. `vDSP_rmsqv` is the same primitive the
    /// live meter uses, just applied to fixed windows instead of the tap buffer.
    private static func frameLevelsDb(pcm: [Float], frameLength: Int) -> [Double] {
        let frameCount = pcm.count / frameLength
        guard frameCount > 0 else { return [] }

        var levels = [Double]()
        levels.reserveCapacity(frameCount)

        pcm.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for frame in 0..<frameCount {
                var rms: Float = 0
                vDSP_rmsqv(base + frame * frameLength, 1, &rms, vDSP_Length(frameLength))
                levels.append(20 * log10(max(Double(rms), 1e-10)))
            }
        }
        return levels
    }

    /// Silence threshold bracketed from both ends of the level distribution.
    ///
    /// Estimating it from the noise floor alone breaks on continuous speech: with
    /// no silence in the recording the quiet percentile *is* speech, so the margin
    /// pushes the threshold above every frame and the whole take reads as silent.
    /// Holding it below the loud percentile as well keeps the threshold between the
    /// two populations whether or not the recording actually contains silence.
    private static func silenceThresholdDb(levelsDb: [Double]) -> Double {
        let sorted = levelsDb.sorted()
        let noiseFloor = self.percentile(sorted, 0.10)
        let speechLevel = self.percentile(sorted, 0.95)

        let adaptive = min(
            noiseFloor + self.silenceMarginDb,
            speechLevel - self.silenceMarginDb
        )
        return max(adaptive, self.absoluteSilenceFloorDb)
    }

    /// Nearest-rank percentile over an already-sorted array.
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[index]
    }

    private static func detectPauses(
        isSpeech: [Bool],
        range: ClosedRange<Int>,
        frameDuration: Double
    ) -> [DeliveryMetrics.Pause] {
        var pauses: [DeliveryMetrics.Pause] = []
        var runStart: Int?

        for index in range {
            if isSpeech[index] {
                if let start = runStart {
                    self.appendPause(&pauses, start: start, end: index, frameDuration: frameDuration)
                    runStart = nil
                }
            } else if runStart == nil {
                runStart = index
            }
        }
        // A trailing run cannot exist: `range` ends on a speech frame by construction.
        return pauses
    }

    private static func appendPause(
        _ pauses: inout [DeliveryMetrics.Pause],
        start: Int,
        end: Int,
        frameDuration: Double
    ) {
        let duration = Double(end - start) * frameDuration
        guard duration >= self.minPauseSeconds else { return }
        pauses.append(
            DeliveryMetrics.Pause(
                startSeconds: Double(start) * frameDuration,
                durationSeconds: duration
            )
        )
    }

    // MARK: - Pitch

    /// Autocorrelation F0 per non-overlapping window. Unvoiced windows yield 0 so
    /// the contour stays aligned to a uniform time axis.
    private static func pitchTrack(pcm: [Float], sampleRate: Double) -> [Double] {
        let windowLength = max(1, Int(sampleRate * self.pitchWindowSeconds))
        let windowCount = pcm.count / windowLength
        guard windowCount > 0 else { return [] }

        var pitches = [Double]()
        pitches.reserveCapacity(windowCount)

        pcm.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for window in 0..<windowCount {
                let start = base + window * windowLength
                pitches.append(
                    self.estimateF0(window: start, count: windowLength, sampleRate: sampleRate) ?? 0
                )
            }
        }
        return pitches
    }

    private static func estimateF0(
        window: UnsafePointer<Float>,
        count: Int,
        sampleRate: Double
    ) -> Double? {
        let minLag = max(1, Int(sampleRate / self.maxPitchHz))
        let maxLag = min(Int(sampleRate / self.minPitchHz), count - 1)
        guard maxLag > minLag else { return nil }

        // Prefix sums of squares make each lag's two window energies O(1), which is
        // what keeps proper normalization affordable across every lag.
        var prefix = [Double](repeating: 0, count: count + 1)
        for index in 0..<count {
            let sample = Double(window[index])
            prefix[index + 1] = prefix[index] + sample * sample
        }
        guard prefix[count] > 0 else { return nil }

        // Normalized cross-correlation, so values land in [-1, 1] and are directly
        // comparable across lags. Raw or length-normalized autocorrelation both
        // carry a lag-dependent bias, and for a periodic signal that bias is enough
        // to make a period multiple outscore the true period — an octave error.
        var correlations = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag {
            var value: Float = 0
            vDSP_dotpr(window, 1, window + lag, 1, &value, vDSP_Length(count - lag))
            let headEnergy = prefix[count - lag]
            let tailEnergy = prefix[count] - prefix[lag]
            let scale = (headEnergy * tailEnergy).squareRoot()
            correlations[lag] = scale > 0 ? Double(value) / scale : 0
        }

        let peak = correlations[minLag...maxLag].max() ?? 0
        guard peak >= self.voicingThreshold else { return nil }

        // Every integer multiple of the true period correlates about as well as the
        // period itself, so the global maximum is not reliably the fundamental.
        // Take the earliest local maximum that is competitive with the global peak;
        // requiring it to be near the peak rejects spurious formant-driven bumps.
        var bestLag = minLag
        for lag in minLag...maxLag
            where correlations[lag] >= self.subharmonicTolerance * peak
            && correlations[lag] >= correlations[lag - 1]
            && correlations[lag] >= correlations[lag + 1]
        {
            bestLag = lag
            break
        }

        return sampleRate / self.refineLag(bestLag, correlations: correlations, maxLag: maxLag)
    }

    /// Parabolic interpolation across the peak and its neighbours. Integer lags
    /// quantize badly up high — at 16 kHz the lags for 430 Hz and 444 Hz are
    /// adjacent, so without this the error near the top of the range is ~15 Hz.
    private static func refineLag(_ lag: Int, correlations: [Double], maxLag: Int) -> Double {
        guard lag > 0, lag < maxLag else { return Double(lag) }
        let previous = correlations[lag - 1]
        let current = correlations[lag]
        let next = correlations[lag + 1]
        let denominator = previous - 2 * current + next
        guard abs(denominator) > .ulpOfOne else { return Double(lag) }
        let offset = 0.5 * (previous - next) / denominator
        guard abs(offset) <= 1 else { return Double(lag) }
        return Double(lag) + offset
    }

    // MARK: - Transcript

    private static func words(in transcript: String) -> [String] {
        transcript
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Counts against the same user-editable list the dictation path strips with,
    /// matching its normalization (lowercase, punctuation trimmed).
    ///
    /// ponytail: single tokens only. Multi-word fillers ("you know", "sort of")
    /// need n-gram matching; the shipped default list has none.
    private static func countFillers(words: [String], fillerWords: [String]) -> [String: Int] {
        let fillers = Set(fillerWords.map { $0.lowercased() })
        guard !fillers.isEmpty else { return [:] }

        var counts: [String: Int] = [:]
        for word in words {
            let normalized = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if fillers.contains(normalized) {
                counts[normalized, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - Statistics

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let average = self.mean(values)
        let variance = values.reduce(0) { $0 + ($1 - average) * ($1 - average) } / Double(values.count)
        return variance.squareRoot()
    }

    /// 5th-to-95th percentile rather than min-to-max: one cough or one clipped
    /// syllable should not define someone's "dynamic range".
    private static func percentileSpread(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let sorted = values.sorted()
        return self.percentile(sorted, 0.95) - self.percentile(sorted, 0.05)
    }

    /// Bucket-average down to a plottable number of points. Averaging rather than
    /// striding so a downsampled pitch contour keeps unvoiced gaps visible instead
    /// of aliasing them away.
    private static func downsample(_ values: [Double]) -> [Double] {
        guard values.count > self.maxContourPoints else { return values }
        let bucketSize = Double(values.count) / Double(self.maxContourPoints)

        return (0..<self.maxContourPoints).map { index in
            let start = Int(Double(index) * bucketSize)
            let end = min(values.count, max(start + 1, Int(Double(index + 1) * bucketSize)))
            return self.mean(Array(values[start..<end]))
        }
    }

    private static func contourInterval(frameCount: Int, frameDuration: Double) -> Double {
        guard frameCount > self.maxContourPoints else { return frameDuration }
        return frameDuration * Double(frameCount) / Double(self.maxContourPoints)
    }
}
