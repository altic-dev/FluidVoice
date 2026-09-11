import Foundation

/// Offline, experimental sidecar evidence only. No capture, transcript or profile consumers.
/// Input is mono PCM explicitly resampled by the caller to 2 kHz (including anti-aliasing).
/// Invalid samples include decoder padding, missing channels and ±2 s discontinuity guards.
/// Correlation is not a speech detector and cannot rule out quiet double talk.
nonisolated struct MeetingPlaybackDuplicateDetector {
    static let version = "temporal-shadow-b1-v1"
    static let sampleRate = 2_000.0

    struct Configuration: Codable, Sendable {
        // Exploratory engineering constants, not calibrated admission thresholds.
        var minimumCorrelation = 0.25
        var minimumControlMargin = 0.08
        var minimumPeakMargin = 0.025
        var minimumRMS = 0.00001
        var stableLagSeconds = 0.012
        var supportWindows = 3
        var budgetSeconds = 0.5
        var maximumConsecutiveBudgetFailures = 3
    }

    struct PCM: Sendable {
        let start: Double
        let samples: [Float]
        let valid: [Bool]
    }

    struct Window: Sendable {
        let sessionID: UUID
        let epoch: UInt64
        let routeID: String
        let start: Double
        let microphone: PCM
        /// Must include ±0.5 s of reference halo around the two-second mic interval.
        let reference: PCM?
        /// Independent time-shifted window, aligned to this interval solely as a null control.
        let mismatchedReference: PCM?
    }

    enum State: String, Codable, Sendable {
        case insufficientEvidence, observing, duplicateCandidate, duplicateSupported
    }
    enum Reason: String, Codable, Sendable {
        case referenceUnavailable, controlUnavailable, invalidInput, unscoredCoverage, insufficientEnergy
        case ambiguousPeak, scoredInconclusive, accumulating, stableSupport, released
        case overBudget, detectorUnavailable
    }
    struct Result: Codable, Sendable {
        let start: Double
        let end: Double
        let epoch: UInt64
        let state: State
        let reason: Reason
        let supportingWindows: Int
        let correlation: Double?
        let controlCorrelation: Double?
        /// Positive lag means microphone follows reference: mic(t) matches ref(t-lag).
        let microphoneDelaySeconds: Double?
        let lagSpreadSeconds: Double?
        let elapsedSeconds: Double
    }

    private let configuration: Configuration
    private let clock: @Sendable () -> Double
    private var scope: String?
    private var sessionID: UUID?
    private var lastEnd: Double?
    private var lags: [Double] = []
    private var budgetFailures = 0
    private var disabled = false

    init(configuration: Configuration = .init(),
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration
        self.clock = clock
    }

    /// Bounded work: exactly 4,000 mic samples, 1,001 lags, two references. No growing PCM/history.
    /// No release hangover in v1: failed support immediately removes supported evidence. This
    /// conservative zero-hold choice must be measured before introducing a nonzero hold period.
    mutating func process(_ window: Window) -> Result {
        let began = clock()
        // Failure latch is attempt-local; a new recording gets a fresh budget allowance.
        if sessionID != window.sessionID { budgetFailures = 0; disabled = false }
        sessionID = window.sessionID
        let newScope = "\(window.sessionID):\(window.epoch):\(window.routeID)"
        if scope != newScope || lastEnd.map({ abs($0 - window.start) > 0.00025 }) != false {
            lags.removeAll()
        }
        scope = newScope
        lastEnd = window.start + 2
        func result(_ reason: Reason, _ state: State = .insufficientEvidence,
                    _ correlation: Double? = nil, _ control: Double? = nil,
                    _ delay: Double? = nil) -> Result {
            Result(start: window.start.isFinite ? window.start : 0,
                   end: window.start.isFinite ? window.start + 2 : 0,
                   epoch: window.epoch, state: state, reason: reason,
                   supportingWindows: lags.count, correlation: correlation,
                   controlCorrelation: control, microphoneDelaySeconds: delay,
                   lagSpreadSeconds: lags.isEmpty ? nil : lags.max()! - lags.min()!,
                   elapsedSeconds: max(0, clock() - began))
        }
        if disabled { lags.removeAll(); return result(.detectorUnavailable) }
        let c = configuration
        guard window.start.isFinite, window.start >= 0, !window.routeID.isEmpty,
              c.minimumCorrelation.isFinite, (0...1).contains(c.minimumCorrelation),
              c.minimumControlMargin.isFinite, (0...1).contains(c.minimumControlMargin),
              c.minimumPeakMargin.isFinite, (0...1).contains(c.minimumPeakMargin),
              c.minimumRMS.isFinite, c.minimumRMS > 0,
              c.stableLagSeconds.isFinite, (0...0.5).contains(c.stableLagSeconds),
              (2...16).contains(c.supportWindows), c.budgetSeconds.isFinite, c.budgetSeconds > 0,
              (1...10).contains(c.maximumConsecutiveBudgetFailures) else {
            lags.removeAll(); return result(.invalidInput)
        }
        guard let reference = window.reference else {
            lags.removeAll(); budgetFailures = 0; return result(.referenceUnavailable)
        }
        guard let control = window.mismatchedReference else {
            lags.removeAll(); budgetFailures = 0; return result(.controlUnavailable)
        }
        // Validate sizes before allocating aligned arrays. ±0.5s search needs a 3-second halo.
        func aligned(_ pcm: PCM, halo: Int) -> [Double]? {
            guard pcm.start.isFinite, pcm.samples.count == pcm.valid.count,
                  pcm.samples.count <= 16_000 else { return nil }
            let offset = (window.start - pcm.start) * Self.sampleRate - Double(halo)
            guard offset.isFinite, offset >= 0, offset <= Double(pcm.samples.count),
                  abs(offset - offset.rounded()) < 0.001 else { return nil }
            let first = Int(offset.rounded()), count = 4_000 + 2 * halo
            guard first <= pcm.samples.count - count else { return nil }
            let range = first..<(first + count)
            guard range.allSatisfy({ pcm.valid[$0] && pcm.samples[$0].isFinite }) else { return nil }
            return range.map { Double(pcm.samples[$0]) }
        }
        guard let mic = aligned(window.microphone, halo: 0),
              let ref = aligned(reference, halo: 1_000),
              let null = aligned(control, halo: 1_000) else {
            lags.removeAll(); budgetFailures = 0; return result(.unscoredCoverage)
        }
        let mean = mic.reduce(0, +) / 4_000
        let centered = mic.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        func usableEnergy(_ samples: [Double]) -> Bool {
            let average = samples.reduce(0, +) / Double(samples.count)
            return samples.reduce(0) { $0 + ($1 - average) * ($1 - average) }
                / Double(samples.count) >= c.minimumRMS * c.minimumRMS
        }
        guard energy / 4_000 >= c.minimumRMS * c.minimumRMS,
              usableEnergy(ref), usableEnergy(null) else {
            lags.removeAll(); budgetFailures = 0; return result(.insufficientEnergy)
        }
        // Search at 1 ms resolution. Peak ambiguity excludes a ±12ms neighborhood.
        func scores(_ samples: [Double]) -> [(lag: Int, score: Double)]? {
            var output: [(Int, Double)] = []
            for lag in stride(from: -1_000, through: 1_000, by: 2) {
                if clock() - began > c.budgetSeconds { return nil }
                let first = 1_000 - lag
                var sum = 0.0, squared = 0.0, cross = 0.0
                for i in 0..<4_000 {
                    let value = samples[first + i]
                    sum += value; squared += value * value; cross += centered[i] * value
                }
                let refEnergy = max(0, squared - sum * sum / 4_000)
                let score = refEnergy / 4_000 >= c.minimumRMS * c.minimumRMS
                    ? min(1, abs(cross) / sqrt(energy * refEnergy)) : 0
                output.append((lag, score))
            }
            return output
        }
        guard let matches = scores(ref), let controls = scores(null) else {
            lags.removeAll(); budgetFailures += 1
            disabled = budgetFailures >= c.maximumConsecutiveBudgetFailures
            return result(.overBudget)
        }
        budgetFailures = 0
        let peak = matches.max { $0.score < $1.score }!
        let nullPeak = controls.map(\.score).max()!
        let secondary = matches.filter { abs($0.lag - peak.lag) > 24 }.map(\.score).max() ?? 0
        let lag = Double(peak.lag) / Self.sampleRate
        let wasSupported = lags.count >= c.supportWindows
        guard peak.score >= c.minimumCorrelation, peak.score - nullPeak >= c.minimumControlMargin else {
            lags.removeAll()
            return result(wasSupported ? .released : .scoredInconclusive, .observing, peak.score, nullPeak, lag)
        }
        guard peak.score - secondary >= c.minimumPeakMargin, abs(peak.lag) < 1_000 else {
            lags.removeAll(); return result(.ambiguousPeak, .observing, peak.score, nullPeak, lag)
        }
        // Compare quantized sample offsets so an exact 12ms spread cannot become
        // 0.012000000000000004 and spuriously reset support.
        if let low = lags.min(), let high = lags.max(),
           Int(((max(high, lag) - min(low, lag)) * Self.sampleRate).rounded())
            > Int((c.stableLagSeconds * Self.sampleRate).rounded(.down)) {
            lags.removeAll()
        }
        lags.append(lag)
        if lags.count > c.supportWindows { lags.removeFirst() }
        return result(lags.count >= c.supportWindows ? .stableSupport : .accumulating,
                      lags.count >= c.supportWindows ? .duplicateSupported : .duplicateCandidate,
                      peak.score, nullPeak, lag)
    }
}
