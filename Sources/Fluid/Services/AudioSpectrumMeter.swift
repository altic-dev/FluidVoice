import Accelerate
import Foundation

/// Splits the most recent microphone audio into log-spaced frequency bands for the
/// overlay visualizer. Read-only tap: it never alters or delays the captured samples.
final class AudioSpectrumMeter: @unchecked Sendable {
    static let shared = AudioSpectrumMeter()
    static let bandCount = 11

    private static let log2n: vDSP_Length = 9
    private static let frameSize = 1 << 9
    private static let sampleRate: Float = 16_000
    private static let lowestFrequency: Float = 120
    private static let highestFrequency: Float = 6000
    private static let floorDecibels: Float = -62
    private static let rangeDecibels: Float = 50
    /// Speech energy falls off with pitch; lift higher bands so consonants register.
    private static let tiltDecibelsPerOctave: Float = 3

    private let lock = NSLock()
    private let setup: FFTSetup?
    private let window: [Float]
    private let bandEdges: [Int]
    private var ring = [Float](repeating: 0, count: AudioSpectrumMeter.frameSize)
    private var ringIndex = 0
    private var frame = [Float](repeating: 0, count: AudioSpectrumMeter.frameSize)
    private var real = [Float](repeating: 0, count: AudioSpectrumMeter.frameSize / 2)
    private var imaginary = [Float](repeating: 0, count: AudioSpectrumMeter.frameSize / 2)
    private var magnitudes = [Float](repeating: 0, count: AudioSpectrumMeter.frameSize / 2)
    private var latest = [Float](repeating: 0, count: AudioSpectrumMeter.bandCount)

    private init() {
        self.setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        var window = [Float](repeating: 0, count: Self.frameSize)
        vDSP_hann_window(&window, vDSP_Length(Self.frameSize), Int32(vDSP_HANN_NORM))
        self.window = window

        let binWidth = Self.sampleRate / Float(Self.frameSize)
        let ratio = Self.highestFrequency / Self.lowestFrequency
        var edges: [Int] = []
        for band in 0...Self.bandCount {
            let frequency = Self.lowestFrequency * pow(ratio, Float(band) / Float(Self.bandCount))
            let bin = Int((frequency / binWidth).rounded())
            // Low bands are narrower than one bin; keep every band at least one bin wide.
            edges.append(max(bin, (edges.last ?? 0) + 1))
        }
        self.bandEdges = edges
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    /// Feed 16 kHz mono samples. Called from the capture pipeline.
    func ingest(_ samples: [Float]) {
        guard let setup, samples.isEmpty == false else { return }
        self.lock.lock()
        defer { self.lock.unlock() }

        for sample in samples.suffix(Self.frameSize) {
            self.ring[self.ringIndex] = sample
            self.ringIndex = (self.ringIndex + 1) % Self.frameSize
        }
        for index in 0..<Self.frameSize {
            self.frame[index] = self.ring[(self.ringIndex + index) % Self.frameSize] * self.window[index]
        }

        let halfSize = Self.frameSize / 2
        self.real.withUnsafeMutableBufferPointer { realPointer in
            self.imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                self.frame.withUnsafeBufferPointer { framePointer in
                    framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &self.magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // zrip output is scaled by 2; the normalized Hann window halves amplitude again.
        let amplitudeScale = 2 / Float(Self.frameSize)
        for band in 0..<Self.bandCount {
            let lower = min(self.bandEdges[band], halfSize - 1)
            let upper = min(max(self.bandEdges[band + 1], lower + 1), halfSize)
            var peak: Float = 0
            self.magnitudes.withUnsafeBufferPointer { pointer in
                vDSP_maxv(pointer.baseAddress! + lower, 1, &peak, vDSP_Length(upper - lower))
            }
            let octave = Float(band) / Float(Self.bandCount) * log2(Self.highestFrequency / Self.lowestFrequency)
            let decibels = 20 * log10(max(peak * amplitudeScale, 1e-9)) + octave * Self.tiltDecibelsPerOctave
            let value = min(max((decibels - Self.floorDecibels) / Self.rangeDecibels, 0), 1)
            // Single FFT frames flicker; ease toward each new reading.
            self.latest[band] += (value - self.latest[band]) * 0.45
        }
    }

    func reset() {
        self.lock.lock()
        defer { self.lock.unlock() }
        for index in self.ring.indices { self.ring[index] = 0 }
        for index in self.latest.indices { self.latest[index] = 0 }
    }

    /// Band levels in 0...1, low frequencies first, resampled to `count` bars.
    func bands(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        self.lock.lock()
        let snapshot = self.latest
        self.lock.unlock()
        guard count != snapshot.count else { return snapshot.map { CGFloat($0) } }
        return (0..<count).map { index in
            let position = Float(index) / Float(max(count - 1, 1)) * Float(snapshot.count - 1)
            let lower = Int(position)
            let upper = min(lower + 1, snapshot.count - 1)
            let fraction = position - Float(lower)
            return CGFloat(snapshot[lower] * (1 - fraction) + snapshot[upper] * fraction)
        }
    }
}
