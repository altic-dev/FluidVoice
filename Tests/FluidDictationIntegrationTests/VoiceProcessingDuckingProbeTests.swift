@testable import FluidVoice_Debug
import AVFoundation
import Foundation
import ScreenCaptureKit
import XCTest

/// Measurement: does instantiating Voice Processing I/O attenuate what ScreenCaptureKit captures
/// from another application?
///
/// VPIO is Apple's hardware-assisted AEC and would replace a hand-rolled echo gate entirely. It was
/// ruled out earlier on the assumption that its system-wide ducking of "other audio" would corrupt
/// the recorded `applicationAudio` track — an assumption never measured. SCStream taps per-process;
/// ducking applies at output mixing, so they may not be the same path.
///
/// Plays a steady tone from a separate process (`afplay`), captures it via SCStream, and compares
/// captured level across three phases: no VPIO, VPIO with default ducking, VPIO with ducking
/// minimised. Run with FLUIDVOICE_VPIO_PROBE=1.
final class VoiceProcessingDuckingProbeTests: XCTestCase {
    func testVoiceProcessingDuckingEffectOnScreenCaptureAudio() async throws {
        guard ProcessInfo.processInfo.environment["FLUIDVOICE_VPIO_PROBE"] != nil else {
            throw XCTSkip("FLUIDVOICE_VPIO_PROBE not set")
        }

        // Audio source is an external windowed application (a browser tab playing a tone). A
        // windowless helper such as `afplay` is not part of a display's shareable content, so
        // SCStream delivers buffers of pure zeros for it — measured: 584 buffers, all silent.
        try await Task.sleep(nanoseconds: 500_000_000)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw XCTSkip("no display") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let collector = AudioLevelCollector()
        let output = LevelStreamOutput(collector: collector)
        let errorDelegate = ProbeStreamDelegate()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: errorDelegate)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "vpio.probe"))
        try await stream.startCapture()
        defer { Task { try? await stream.stopCapture() } }
        print("[vpio] capture started")

        func phase(_ label: String, seconds: Double) async -> Double {
            await collector.mark(label)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return await collector.rms(for: label)
        }

        let baseline = await phase("1-no-vpio", seconds: 3.0)

        // Instantiating and running an engine with voice processing on the IO nodes is what turns
        // VPIO on process-wide; merely constructing AVAudioEngine does not.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Enabling on the input node switches the whole IO unit to VPIO; doing it on the output node
        // as well fails initialisation with -10875.
        try input.setVoiceProcessingEnabled(true)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { _, _ in }

        // Adding a render chain to satisfy VPIO's downlink fails initialisation with -10875 here, so
        // the engine runs capture-only. VPIO is still instantiated and active — it logs its own
        // downlink faults — which is what the ducking measurement needs.
        engine.prepare()
        try engine.start()
        defer { engine.stop() }
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let withDefaultDucking = await phase("2-vpio-default", seconds: 3.0)

        var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
        ducking.enableAdvancedDucking = false
        ducking.duckingLevel = .min
        input.voiceProcessingOtherAudioDuckingConfiguration = ducking
        try await Task.sleep(nanoseconds: 700_000_000)

        let withMinDucking = await phase("3-vpio-min-ducking", seconds: 3.0)

        func dB(_ value: Double) -> String {
            value > 0 ? String(format: "%.1f dBFS", 20 * log10(value)) : "silent"
        }
        print("[vpio] baseline (no VPIO)      rms=\(String(format: "%.5f", baseline))  \(dB(baseline))")
        print("[vpio] VPIO, default ducking   rms=\(String(format: "%.5f", withDefaultDucking))  \(dB(withDefaultDucking))")
        print("[vpio] VPIO, ducking = .min    rms=\(String(format: "%.5f", withMinDucking))  \(dB(withMinDucking))")
        if baseline > 0 {
            print(String(format: "[vpio] default ducking attenuation: %.1f dB", 20 * log10(withDefaultDucking / baseline)))
            print(String(format: "[vpio] min ducking attenuation:     %.1f dB", 20 * log10(withMinDucking / baseline)))
        }
        let stats = await collector.diagnostics()
        print("[vpio] buffers=\(stats.buffers) copyFailures=\(stats.copyFailures) framesTotal=\(stats.frames) streamError=\(errorDelegate.lastError ?? "none")")
        XCTAssertGreaterThan(baseline, 0, "SCStream captured no audio; tone or permission problem")
    }

}

private actor AudioLevelCollector {
    private var current: String?
    private var sums: [String: (total: Double, frames: Int)] = [:]
    private var buffers = 0
    private var copyFailures = 0
    private var frames = 0

    func mark(_ label: String) { self.current = label }

    func diagnostics() -> (buffers: Int, copyFailures: Int, frames: Int) {
        (self.buffers, self.copyFailures, self.frames)
    }

    func noteBuffer() { self.buffers += 1 }
    func noteCopyFailure() { self.copyFailures += 1 }

    func add(sumOfSquares: Double, frames: Int) {
        self.frames += frames
        guard let current else { return }
        let existing = self.sums[current] ?? (0, 0)
        self.sums[current] = (existing.total + sumOfSquares, existing.frames + frames)
    }

    func rms(for label: String) -> Double {
        guard let entry = self.sums[label], entry.frames > 0 else { return 0 }
        return (entry.total / Double(entry.frames)).squareRoot()
    }
}

private final class LevelStreamOutput: NSObject, SCStreamOutput {
    private let collector: AudioLevelCollector
    init(collector: AudioLevelCollector) { self.collector = collector }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        Task { [collector] in await collector.noteBuffer() }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd)
        else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        ) == noErr, let channel = buffer.floatChannelData?[0] else {
            Task { [collector] in await collector.noteCopyFailure() }
            return
        }
        var sum = 0.0
        for i in 0..<Int(frames) { sum += Double(channel[i]) * Double(channel[i]) }
        Task { [collector] in await collector.add(sumOfSquares: sum, frames: Int(frames)) }
    }
}

private final class ProbeStreamDelegate: NSObject, SCStreamDelegate {
    private let lock = NSLock()
    private var stored: String?
    var lastError: String? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.stored
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.stored = String(describing: error)
    }
}
