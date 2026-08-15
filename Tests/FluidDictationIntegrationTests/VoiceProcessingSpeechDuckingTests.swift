@testable import FluidVoice_Debug
import AVFoundation
import Foundation
import ScreenCaptureKit
import XCTest

/// Two measurements in one run, both needed before adopting Apple's AEC for the meeting microphone.
///
/// A. Ducking against REAL SPEECH rather than a steady tone. Ducking is voice-activity driven, so a
///    tone understates both its depth and its variability. Reports a per-second level timeline.
/// B. Relative clock drift between an `AVAudioEngine` microphone and SCStream application audio.
///    Moving the microphone off SCStream costs the shared capture clock; this quantifies what that
///    is worth in parts per million.
///
/// Play speech through a windowed app, then run with FLUIDVOICE_VPIO_SPEECH=1.
final class VoiceProcessingSpeechDuckingTests: XCTestCase {
    func testDuckingAgainstSpeechAndClockDrift() async throws {
        guard ProcessInfo.processInfo.environment["FLUIDVOICE_VPIO_SPEECH"] != nil else {
            throw XCTSkip("FLUIDVOICE_VPIO_SPEECH not set")
        }

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

        let recorder = TimelineRecorder()
        let output = TimelineStreamOutput(recorder: recorder)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "vpio.speech"))
        try await stream.startCapture()
        defer { Task { try? await stream.stopCapture() } }

        await recorder.mark("baseline")
        try await Task.sleep(nanoseconds: 6_000_000_000)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
        ducking.enableAdvancedDucking = false
        ducking.duckingLevel = .min
        input.voiceProcessingOtherAudioDuckingConfiguration = ducking

        // Count microphone frames against host time to derive this clock's true rate.
        let micClock = ClockCounter(nominalRate: input.outputFormat(forBus: 0).sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            Task { await micClock.add(frames: Int(buffer.frameLength)) }
        }
        engine.prepare()
        try engine.start()
        defer { engine.stop() }
        try await Task.sleep(nanoseconds: 1_000_000_000)

        await recorder.mark("vpio-min-ducking")
        await micClock.begin()
        try await Task.sleep(nanoseconds: 20_000_000_000)

        let timeline = await recorder.timeline()
        let baseline = timeline.filter { $0.phase == "baseline" }.map(\.rms)
        let ducked = timeline.filter { $0.phase == "vpio-min-ducking" }.map(\.rms)

        func dB(_ v: Double) -> Double { v > 0 ? 20 * log10(v) : -120 }
        func summarise(_ label: String, _ values: [Double]) {
            guard !values.isEmpty else { print("[speech] \(label): no data"); return }
            let mean = values.reduce(0, +) / Double(values.count)
            print(String(
                format: "[speech] %-18@ seconds=%d  mean=%.1f dBFS  min=%.1f  max=%.1f  swing=%.1f dB",
                label as NSString, values.count, dB(mean), dB(values.min() ?? 0), dB(values.max() ?? 0),
                dB(values.max() ?? 0) - dB(values.min() ?? 0)
            ))
        }
        summarise("baseline", baseline)
        summarise("VPIO min ducking", ducked)
        if let b = baseline.max(), let d = ducked.max(), b > 0, d > 0 {
            print(String(format: "[speech] peak-to-peak attenuation: %.1f dB", dB(d) - dB(b)))
        }
        print("[speech] per-second dBFS (ducked): "
            + ducked.map { String(format: "%.0f", dB($0)) }.joined(separator: " "))

        let (micFrames, micSeconds) = await micClock.result()
        let (appFrames, appSeconds) = await recorder.clockResult()
        func ppm(_ frames: Int, _ seconds: Double, _ nominal: Double) -> Double {
            guard seconds > 0, nominal > 0 else { return .nan }
            return (Double(frames) / seconds / nominal - 1) * 1_000_000
        }
        let micPPM = ppm(micFrames, micSeconds, await micClock.nominalRate)
        let appPPM = ppm(appFrames, appSeconds, 48_000)
        print(String(format: "[drift] mic clock  %.0f ppm vs nominal (%d frames / %.2fs)", micPPM, micFrames, micSeconds))
        print(String(format: "[drift] app clock  %.0f ppm vs nominal (%d frames / %.2fs)", appPPM, appFrames, appSeconds))
        print(String(format: "[drift] RELATIVE   %.0f ppm  =>  %.0f ms of skew per hour", micPPM - appPPM, abs(micPPM - appPPM) * 3.6))

        XCTAssertFalse(baseline.isEmpty, "no baseline audio captured — is speech playing?")
    }
}

private actor ClockCounter {
    let nominalRate: Double
    private var frames = 0
    private var start: CFAbsoluteTime?
    init(nominalRate: Double) { self.nominalRate = nominalRate }
    func begin() { self.start = CFAbsoluteTimeGetCurrent(); self.frames = 0 }
    func add(frames count: Int) { if self.start != nil { self.frames += count } }
    func result() -> (Int, Double) {
        guard let start else { return (0, 0) }
        return (self.frames, CFAbsoluteTimeGetCurrent() - start)
    }
}

private actor TimelineRecorder {
    struct Sample { let phase: String; let rms: Double }
    private var phase = ""
    private var bucketStart = CFAbsoluteTimeGetCurrent()
    private var bucketSum = 0.0
    private var bucketFrames = 0
    private var samples: [Sample] = []
    private var clockFrames = 0
    private var clockStart: CFAbsoluteTime?

    func mark(_ label: String) {
        self.phase = label
        if self.clockStart == nil { self.clockStart = CFAbsoluteTimeGetCurrent() }
    }

    func add(sumOfSquares: Double, frames: Int) {
        guard !self.phase.isEmpty else { return }
        self.clockFrames += frames
        self.bucketSum += sumOfSquares
        self.bucketFrames += frames
        let now = CFAbsoluteTimeGetCurrent()
        if now - self.bucketStart >= 1.0, self.bucketFrames > 0 {
            self.samples.append(Sample(phase: self.phase, rms: (self.bucketSum / Double(self.bucketFrames)).squareRoot()))
            self.bucketStart = now
            self.bucketSum = 0
            self.bucketFrames = 0
        }
    }

    func timeline() -> [Sample] { self.samples }
    func clockResult() -> (Int, Double) {
        guard let clockStart else { return (0, 0) }
        return (self.clockFrames, CFAbsoluteTimeGetCurrent() - clockStart)
    }
}

private final class TimelineStreamOutput: NSObject, SCStreamOutput {
    private let recorder: TimelineRecorder
    init(recorder: TimelineRecorder) { self.recorder = recorder }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd)
        else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        ) == noErr, let channel = buffer.floatChannelData?[0] else { return }
        var sum = 0.0
        for i in 0..<Int(frames) { sum += Double(channel[i]) * Double(channel[i]) }
        Task { [recorder] in await recorder.add(sumOfSquares: sum, frames: Int(frames)) }
    }
}
