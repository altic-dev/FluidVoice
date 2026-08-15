@testable import FluidVoice_Debug
import AVFoundation
import Foundation
import XCTest

#if arch(arm64)
import FluidAudio

/// Measurement: does Apple's Voice Processing I/O degrade transcription of the user's OWN voice?
///
/// macOS bundles noise suppression and automatic gain control with its echo canceller, and shipping
/// dictation products disable all three for dictation while enabling them only for meetings — which
/// implies the processing costs something. Two takes of the same passage, one raw and one
/// VPIO-processed, each transcribed and compared against the known text.
///
/// Deliberately avoids ScreenCaptureKit: the test host loses its Screen Recording grant on every
/// rebuild, and nothing here needs it.
///
/// Run with FLUIDVOICE_ASR_AB=1.
final class VoiceProcessingAsrQualityTests: XCTestCase {
    private static let captureSeconds = 22.0

    func testVpioEffectOnOwnVoiceTranscription() async throws {
        guard ProcessInfo.processInfo.environment["FLUIDVOICE_ASR_AB"] != nil else {
            throw XCTSkip("FLUIDVOICE_ASR_AB not set")
        }

        // Lead-in so the operator can start speaking before the first take opens.
        print("\n[ab] starting in 15 seconds — begin reading now and keep going\n")
        try await Task.sleep(nanoseconds: 15_000_000_000)
        let raw = try await Self.capture(voiceProcessing: false, label: "TAKE 1 of 2 — voice processing OFF")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let processed = try await Self.capture(voiceProcessing: true, label: "TAKE 2 of 2 — voice processing ON")

        print(String(format: "\n[ab] raw   %.1fs  rms=%.5f  (%.1f dBFS)",
                     Double(raw.count) / 16_000, Self.rms(raw), 20 * log10(max(Self.rms(raw), 1e-9))))
        print(String(format: "[ab] vpio  %.1fs  rms=%.5f  (%.1f dBFS)",
                     Double(processed.count) / 16_000, Self.rms(processed), 20 * log10(max(Self.rms(processed), 1e-9))))

        let rawText = try await Self.transcribe(raw)
        let vpioText = try await Self.transcribe(processed)
        print("\n[ab] RAW  : \(rawText)")
        print("\n[ab] VPIO : \(vpioText)\n")
        print("[ab] words  raw=\(rawText.split(separator: " ").count)  vpio=\(vpioText.split(separator: " ").count)")

        XCTAssertFalse(raw.isEmpty, "no audio captured on take 1")
        XCTAssertFalse(processed.isEmpty, "no audio captured on take 2")
    }

    private static func capture(voiceProcessing: Bool, label: String) async throws -> [Float] {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
            ducking.enableAdvancedDucking = false
            ducking.duckingLevel = .min
            input.voiceProcessingOtherAudioDuckingConfiguration = ducking
        }
        let format = input.outputFormat(forBus: 0)
        let sink = SampleSink()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let slice = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            Task { await sink.append(slice, sourceRate: format.sampleRate) }
        }
        engine.prepare()
        try engine.start()
        print("\n[ab] ==========================================================")
        print("[ab] \(label)")
        print("[ab] READ THE PASSAGE NOW — \(Int(Self.captureSeconds)) seconds")
        print("[ab] ==========================================================\n")
        try await Task.sleep(nanoseconds: UInt64(Self.captureSeconds * 1_000_000_000))
        engine.stop()
        input.removeTap(onBus: 0)
        return await sink.samples()
    }

    private static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    private static func transcribe(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty else { return "(no audio)" }
        let manager = StreamingEouAsrManager(chunkSize: .ms160)
        try await manager.loadModelsFromHuggingFace()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { return "(format error)" }
        var index = 0
        while index < samples.count {
            let end = min(index + 2_560, samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - index)) else { break }
            buffer.frameLength = AVAudioFrameCount(end - index)
            samples[index..<end].withUnsafeBufferPointer { source in
                buffer.floatChannelData?[0].update(from: source.baseAddress!, count: end - index)
            }
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
            index = end
        }
        let text = try await manager.finish()
        await manager.reset()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Accumulates mono 16 kHz float samples, decimating from the source rate.
private actor SampleSink {
    private var storage: [Float] = []

    func append(_ incoming: [Float], sourceRate: Double) {
        guard sourceRate > 0 else { return }
        let ratio = sourceRate / 16_000
        guard ratio > 1.01 else {
            self.storage.append(contentsOf: incoming)
            return
        }
        var position = 0.0
        while Int(position) < incoming.count {
            self.storage.append(incoming[Int(position)])
            position += ratio
        }
    }

    func samples() -> [Float] { self.storage }
}
#endif
