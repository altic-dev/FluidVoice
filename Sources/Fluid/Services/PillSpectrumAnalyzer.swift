import Accelerate
import Foundation

/// Worker-confined FFT, adapted from the upstream AudioSpectrumMeter primitives.
/// No temporal smoothing or loudness normalization: quiet frequency regions stay quiet.
final nonisolated class PillSpectrumAnalyzer {
    static let centerFrequencies: [Double] = [220, 400, 700, 1200, 2000, 3200, 4300, 5500]
    let sampleRate: Double
    private let size: Int
    private let logSize: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let scale: Float
    private let bandPowerWeights: [SIMD8<Float>]
    private var ring: [Float]
    private var cursor = 0
    private var frame: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var powers: [Float]

    init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
        self.logSize = vDSP_Length(max(8, min(12, ceil(log2(max(sampleRate, 1) * 0.032)))))
        self.size = 1 << self.logSize
        let binWidth = sampleRate / Double(self.size)
        let centers = Self.centerFrequencies.map { log2($0) }
        self.bandPowerWeights = (0..<(self.size / 2)).map { bin in
            let frequency = Double(bin) * binWidth
            guard frequency >= 120, frequency < 6000 else { return .zero }
            // Speech-focused overlapping windows avoid hard holes between formants.
            // Adjacent power weights sum to one; no energy is invented at boundaries.
            let position = log2(frequency)
            var weights = SIMD8<Float>.zero
            let attenuationDB = 15 * max(0, min(1, log(1600 / max(220, frequency)) / log(1600.0 / 220)))
            let presenceDB = min(12, max(0, 9 * log2(frequency / 800)))
            let gain = Float(pow(10, (presenceDB - attenuationDB) / 10))
            for band in 0..<8 {
                let rising = band == 0 ? 1 : (position - centers[band - 1]) / (centers[band] - centers[band - 1])
                let falling = band == 7 ? 1 : (centers[band + 1] - position) / (centers[band + 1] - centers[band])
                weights[band] = Float(max(0, min(rising, falling))) * gain
            }
            return weights
        }
        guard let setup = vDSP_create_fftsetup(self.logSize, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("Unable to allocate Pill FFT setup")
        }
        self.setup = setup
        var window = [Float](repeating: 0, count: self.size)
        vDSP_hann_window(&window, vDSP_Length(self.size), Int32(vDSP_HANN_NORM))
        self.window = window
        // zrip doubles the FFT amplitude. Hann energy spans ~1.5 bins.
        self.scale = 1 / (window.reduce(0, +) * sqrt(1.5))
        self.ring = .init(repeating: 0, count: self.size)
        self.frame = self.ring
        self.real = .init(repeating: 0, count: self.size / 2)
        self.imaginary = self.real
        self.powers = self.real
    }

    deinit { vDSP_destroy_fftsetup(self.setup) }

    func reset() {
        self.ring = .init(repeating: 0, count: self.size)
        self.cursor = 0
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples.suffix(self.size) {
            self.ring[self.cursor] = sample.isFinite ? min(max(sample, -1), 1) : 0
            self.cursor = (self.cursor + 1) % self.size
        }
    }

    func analyze(_ samples: UnsafeBufferPointer<Float>) -> (amplitudes: SIMD8<Float>, rms: Float) {
        self.append(samples)
        return self.currentSpectrum()
    }

    func currentSpectrum() -> (amplitudes: SIMD8<Float>, rms: Float) {
        var squareSum: Float = 0
        for index in 0..<self.size {
            let sample = self.ring[(self.cursor + index) % self.size]
            squareSum += sample * sample
            self.frame[index] = sample * self.window[index]
        }
        self.real.withUnsafeMutableBufferPointer { real in
            self.imaginary.withUnsafeMutableBufferPointer { imaginary in
                guard let realBase = real.baseAddress, let imaginaryBase = imaginary.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                self.frame.withUnsafeBufferPointer { frame in
                    guard let frameBase = frame.baseAddress else { return }
                    frameBase.withMemoryRebound(to: DSPComplex.self, capacity: self.size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(self.size / 2))
                    }
                }
                vDSP_fft_zrip(self.setup, &split, 1, self.logSize, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &self.powers, 1, vDSP_Length(self.size / 2))
            }
        }
        var energies = SIMD8<Float>.zero
        for bin in 1..<(self.size / 2) {
            energies += self.bandPowerWeights[bin] * SIMD8<Float>(repeating: self.powers[bin])
        }
        var amplitudes = SIMD8<Float>.zero
        for band in 0..<8 {
            amplitudes[band] = min(1, sqrt(max(energies[band], 0)) * self.scale)
        }
        return (amplitudes, sqrt(squareSum / Float(self.size)))
    }
}

nonisolated struct PillSpectrumFrame: Sendable {
    let epoch: UInt64
    let session: UInt64
    let attempt: UInt64
    let sequence: UInt64
    let captureHostTime: UInt64
    let publishedAt: Double
    let amplitudes: SIMD8<Float>
    let rms: Float
    let discontinuity: Bool
    let analysisMilliseconds: Double
}

nonisolated enum PillMeterMapping {
    static func levels(_ amplitudes: SIMD8<Float>, count: Int, sensitivity: Double, rms: Float) -> [Double] {
        let count = min(8, max(3, count))
        // Same control direction, with a bounded absolute gate before normalization.
        let threshold = sensitivity.isFinite ? min(0.95, max(0.01, sensitivity)) : 0.4
        let shiftDB = 18 * (threshold - 0.01)
        var decibels = SIMD8<Double>(repeating: -180)
        var peakDB = -180.0
        for band in 0..<8 {
            let amplitude = Double(amplitudes[band])
            guard amplitude.isFinite, amplitude > 0 else { continue }
            decibels[band] = 20 * log10(min(1, amplitude))
            peakDB = max(peakDB, decibels[band])
        }
        // Require the unweighted measurement: presence-weighted spectrum cannot
        // safely estimate the absolute noise gate. No voiced detector is involved.
        let energy = rms.isFinite ? max(0, Double(rms)) : 0
        let activity = min(1, max(0, (20 * log10(max(energy, 1e-9)) - (-62 + shiftDB)) / 8))
        let body = pow(min(1, max(0, (peakDB - (-64 + shiftDB)) / 30)), 0.8) * activity
        var result = [Double](repeating: 0, count: count)
        guard body > 0 else { return result }
        for band in 0..<8 {
            // Relative contrast preserves the changing shape when loudness changes.
            // The absolute per-band gate keeps a quiet region at its resting dot.
            let shape = pow(min(1, max(0, (decibels[band] - peakDB + 24) / 24)), 1.4)
            let gate = min(1, max(0, (decibels[band] - (-66 + shiftDB)) / 10))
            let bar = min(count - 1, (2 * band + 1) * count / 16)
            result[bar] = max(result[bar], body * shape * gate)
        }
        return result
    }
}

nonisolated struct PillMeterDynamics {
    private(set) var levels: [Double] = []
    private var lastTime: Double?

    mutating func reset() {
        self.levels = []; self.lastTime = nil
    }

    mutating func advance(target: [Double], at time: Double) -> [Double] {
        guard time.isFinite else { return self.levels }
        if self.levels.count != target.count {
            self.levels = .init(repeating: 0, count: target.count)
            self.lastTime = nil
        }
        let dt = max(0, time - (self.lastTime ?? time))
        if let lastTime = self.lastTime, time < lastTime || dt > 0.5 {
            self.levels = .init(repeating: 0, count: target.count)
        }
        self.lastTime = time
        for index in target.indices {
            let value = target[index].isFinite ? min(1, max(0, target[index])) : 0
            let tau = value > self.levels[index] ? 0.025 : 0.095
            self.levels[index] += (value - self.levels[index]) * (1 - exp(-min(dt, 0.5) / tau))
            if value == 0, self.levels[index] < 0.001 {
                self.levels[index] = 0
            }
        }
        return self.levels
    }
}

nonisolated struct PillMeterGeometry {
    let count: Int
    let width: Double
    let gap: Double
    let maximumHeight: Double
    var groupWidth: Double {
        Double(self.count) * self.width + Double(self.count - 1) * self.gap
    }

    init(count: Int, availableWidth: Double, availableHeight: Double) {
        self.count = min(8, max(3, count))
        let naturalWidth = Double(self.count) * (8.0 / 3) + Double(self.count - 1) * 2
        let scale = max(0, min(1, availableWidth / naturalWidth))
        self.width = (8.0 / 3) * scale
        self.gap = 2 * scale
        self.maximumHeight = max(self.width, min(28, availableHeight))
    }
}
