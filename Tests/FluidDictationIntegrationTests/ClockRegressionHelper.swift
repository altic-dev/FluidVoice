import Foundation

/// Least-squares fit of a (mach seconds, PTS seconds) series, shared by the Phase 0 clock-domain
/// probe and the Phase 2 cross-path drift probe. Regression, never per-sample deltas: arrival
/// jitter perturbs points, not a long-run slope.
final actor ClockPairRecorder {
    struct Fit {
        let count: Int
        let slopePPM: Double
        let slopeCI95PPM: Double
        let residualStdMs: Double
        let ptsSpanSeconds: Double
    }

    private var machTimes: [Double] = []
    private var ptsTimes: [Double] = []

    func record(mach: Double, pts: Double) {
        self.machTimes.append(mach)
        self.ptsTimes.append(pts)
    }

    func count() -> Int { self.machTimes.count }

    func regression() -> Fit? {
        Self.fit(machTimes: self.machTimes, ptsTimes: self.ptsTimes)
    }

    /// Fits each half separately: a warm-up drift transient shows as disagreeing halves even when
    /// the whole-run CI looks tight.
    func halfSplitSlopesPPM() -> (first: Double, second: Double)? {
        let n = self.machTimes.count
        guard n > 200 else { return nil }
        let mid = n / 2
        guard let a = Self.fit(machTimes: Array(self.machTimes[..<mid]), ptsTimes: Array(self.ptsTimes[..<mid])),
              let b = Self.fit(machTimes: Array(self.machTimes[mid...]), ptsTimes: Array(self.ptsTimes[mid...]))
        else { return nil }
        return (a.slopePPM, b.slopePPM)
    }

    static func fit(machTimes: [Double], ptsTimes: [Double]) -> Fit? {
        let n = machTimes.count
        guard n > 10 else { return nil }
        let x0 = machTimes[0]
        let y0 = ptsTimes[0]
        let xs = machTimes.map { $0 - x0 }
        let ys = ptsTimes.map { $0 - y0 }
        let meanX = xs.reduce(0, +) / Double(n)
        let meanY = ys.reduce(0, +) / Double(n)
        var sxx = 0.0
        var sxy = 0.0
        for i in 0..<n {
            let dx = xs[i] - meanX
            sxx += dx * dx
            sxy += dx * (ys[i] - meanY)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        var sse = 0.0
        for i in 0..<n {
            let r = ys[i] - (intercept + slope * xs[i])
            sse += r * r
        }
        let residualVariance = sse / Double(max(1, n - 2))
        let slopeStdErr = (residualVariance / sxx).squareRoot()
        return Fit(
            count: n,
            slopePPM: (slope - 1) * 1_000_000,
            slopeCI95PPM: 1.96 * slopeStdErr * 1_000_000,
            residualStdMs: residualVariance.squareRoot() * 1_000,
            ptsSpanSeconds: ys.last ?? 0
        )
    }
}
