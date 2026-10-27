import Accelerate
import Foundation

/// Pronunciation is on by default; a saved Off choice disables matching and enrollment.
nonisolated enum DictionaryMatcherExperiment {
    static let defaultEnabled = true
    static var sharedFeaturesEnabled: Bool {
        UserDefaults.standard.object(forKey: "DictionarySharedFeatureMatcherEnabled") as? Bool ?? self.defaultEnabled
    }

    static let didChangeNotification = Notification.Name("DictionaryPronunciationDidChange")
    static var generation: String { UserDefaults.standard.string(forKey: "DictionaryPronunciationGeneration") ?? "initial" }
    static func setEnabled(_ enabled: Bool) {
        guard self.sharedFeaturesEnabled != enabled else { return }
        UserDefaults.standard.set(UUID().uuidString, forKey: "DictionaryPronunciationGeneration")
        UserDefaults.standard.set(enabled, forKey: "DictionarySharedFeatureMatcherEnabled")
        NotificationCenter.default.post(name: self.didChangeNotification, object: nil)
    }

    static var positiveEnabled: Bool { sharedFeaturesEnabled }
    static var collectNegatives: Bool { sharedFeaturesEnabled && UserDefaults.standard.bool(forKey: "DictionaryNegativeLearningEnabled") }
    static var compareNegatives: Bool { sharedFeaturesEnabled && UserDefaults.standard.bool(forKey: "DictionaryNegativeComparisonEnabled") }
    static var needsFrames: Bool { sharedFeaturesEnabled }
    static let version = "parakeet-exact-rms005-frames-v1"
}

nonisolated struct DictionaryMatchFrames: Codable, Equatable, Sendable {
    let hiddenSize: Int
    let values: [Float]
    var count: Int { self.hiddenSize > 0 ? self.values.count / self.hiddenSize : 0 }
    var isValid: Bool {
        (1...1024).contains(self.hiddenSize) && (1...192).contains(self.count)
            && self.values.count == self.count * self.hiddenSize && self.values.allSatisfy(\.isFinite)
    }

    func normalized() -> Self {
        guard self.isValid else { return self }
        var result = self.values
        for f in 0..<self.count {
            let start = f * self.hiddenSize
            let length = sqrt(values[start..<(start + self.hiddenSize)].reduce(Float(0)) { $0 + $1 * $1 })
            for d in 0..<self.hiddenSize {
                result[start + d] /= max(length, 1e-12)
            }
        }
        return Self(hiddenSize: self.hiddenSize, values: result)
    }
}

/// No labels, settings, disk, audio capture, or model loading inside the decision layer.
nonisolated enum DictionaryExperimentalMatcher {
    struct Metrics: Equatable, Sendable { let mean: Float; let lower: Float }
    struct Decision: Sendable { let accepted: Bool; let meanRelative: Float; let lowerRelative: Float }

    @concurrent static func comparePositive(query: DictionaryMatchFrames, references: [DictionaryMatchFrames]) async -> Decision? {
        self.positive(query: query, references: references)
    }

    @concurrent static func compareNegative(query: DictionaryMatchFrames, references: [DictionaryMatchFrames], negatives: [DictionaryMatchFrames]) async -> Bool {
        self.negativeAllows(query: query, references: references, negatives: negatives)
    }

    static func metrics(reference: DictionaryMatchFrames, query: DictionaryMatchFrames) -> Metrics? {
        guard reference.isValid, query.isValid, reference.hiddenSize == query.hiddenSize else { return nil }
        let r = reference.normalized(), q = query.normalized()
        let n = r.count, m = q.count, width = m + 1, hidden = r.hiddenSize
        var sim = [Float](repeating: 0, count: n * m)
        r.values.withUnsafeBufferPointer { rp in q.values.withUnsafeBufferPointer { qp in sim.withUnsafeMutableBufferPointer { sp in
            guard let referencePointer = rp.baseAddress, let queryPointer = qp.baseAddress, let outputPointer = sp.baseAddress else { return }
            cblas_sgemm(
                CblasRowMajor,
                CblasNoTrans,
                CblasTrans,
                Int32(n),
                Int32(m),
                Int32(hidden),
                1,
                referencePointer,
                Int32(hidden),
                queryPointer,
                Int32(hidden),
                0,
                outputPointer,
                Int32(m)
            )
        } } }
        var cost = [Double](repeating: .infinity, count: (n + 1) * width)
        var previous = [UInt8](repeating: 0, count: cost.count)
        cost[0] = 0
        for i in 1...n {
            for j in 1...m {
                if abs(Double(i - 1) / Double(max(1, n - 1)) - Double(j - 1) / Double(max(1, m - 1))) > 0.25 + 1 / Double(min(n, m)) { continue }
                var best = cost[(i - 1) * width + j - 1]
                var step: UInt8 = 0
                let up = cost[(i - 1) * width + j] + 0.05
                if up < best { best = up; step = 1 }
                let left = cost[i * width + j - 1] + 0.05
                if left < best { best = left; step = 2 }
                cost[i * width + j] = best + 1 - Double(sim[(i - 1) * m + j - 1])
                previous[i * width + j] = step
            }
        }
        guard cost[n * width + m].isFinite else { return nil }
        var sums = [Double](repeating: 0, count: n), counts = [Int](repeating: 0, count: n)
        var i = n, j = m
        while i > 0 || j > 0 {
            guard i > 0, j > 0 else { return nil }
            sums[i - 1] += Double(sim[(i - 1) * m + j - 1]); counts[i - 1] += 1
            switch previous[i * width + j] {
            case 0: i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        guard counts.allSatisfy({ $0 > 0 }) else { return nil }
        let values = zip(sums, counts).map { $0.0 / Double($0.1) }.sorted()
        let index = Double(n - 1) * 0.25, lo = Int(index), hi = min(n - 1, Int(ceil(index)))
        return Metrics(mean: Float(values.reduce(0, +) / Double(n)), lower: Float(values[lo] + (values[hi] - values[lo]) * (index - Double(lo))))
    }

    /// Separate operating point for sentence-context queries against isolated enrollment frames.
    /// These development-set cutoffs must never be applied to isolated query encodings.
    @concurrent static func compareSharedFeatures(query: DictionaryMatchFrames, references: [DictionaryMatchFrames], chunked: Bool = false) async -> Decision? {
        self.positive(query: query, references: references, meanThreshold: chunked ? 0.55 : 0.59, lowerThreshold: chunked ? 0.35 : 0.50)
    }

    static func positive(query: DictionaryMatchFrames, references: [DictionaryMatchFrames], meanThreshold: Float = 0.70, lowerThreshold: Float = 0.55) -> Decision? {
        guard references.count >= 3, references.count <= 10 else { return nil }
        var calibration: [Metrics] = []
        for i in references.indices {
            for j in references.indices where i != j {
                guard let value = metrics(reference: references[i], query: references[j]) else { return nil }
                calibration.append(value)
            }
        }
        let mean = max(0.1, calibration.map(\.mean).reduce(0, +) / Float(calibration.count))
        let lower = max(0.1, calibration.map(\.lower).reduce(0, +) / Float(calibration.count))
        let scores = references.compactMap { self.metrics(reference: $0, query: query) }
        guard scores.count == references.count else { return nil }
        let a = (scores.map(\.mean).max() ?? -1) / mean, b = (scores.map(\.lower).max() ?? -1) / lower
        return Decision(accepted: a >= meanThreshold && b >= lowerThreshold, meanRelative: a, lowerRelative: b)
    }

    static func similarity(_ a: DictionaryMatchFrames, _ b: DictionaryMatchFrames) -> Float? {
        guard let ab = metrics(reference: a, query: b), let ba = metrics(reference: b, query: a) else { return nil }
        return (ab.mean + ba.mean) / 2
    }

    /// A negative may veto an existing acceptance; it can never create an acceptance.
    static func negativeAllows(query: DictionaryMatchFrames, references: [DictionaryMatchFrames], negatives: [DictionaryMatchFrames]) -> Bool {
        guard !negatives.isEmpty else { return true }
        guard let positive = references.compactMap({ similarity(query, $0) }).max(),
              let negative = negatives.compactMap({ similarity(query, $0) }).max() else { return true }
        // Require a close negative and an advantage over every enrolled positive.
        // One correction must not suppress a broad neighborhood of valid pronunciations.
        return !(negative >= 0.75 && negative > positive + 0.05)
    }
}
