@testable import FluidVoice_Debug
import AVFoundation
import Foundation
import XCTest

#if arch(arm64)
import FluidAudio

/// Measurement: does `StreamingEouAsrManager` endpoint on sustained digital silence?
///
/// Option A for live echo suppression gates echo-dominated audio to zeros so the microphone regains
/// the pauses its endpointer needs. Nothing in FluidAudio's source answers whether a learned EOU
/// token head fires on pure zeros — the warmup pass feeds 1s of silence and never checks. If it does
/// not fire, gating cleans the audio but utterances still never close, and the endpointing half of
/// the plan has to be driven from gate state instead.
///
/// Run with FLUIDVOICE_SILENCE_EOU=<session dir>.
final class MeetingLiveSilenceEndpointTests: XCTestCase {
    func testEndpointerFiresOnSustainedDigitalSilence() async throws {
        guard let root = ProcessInfo.processInfo.environment["FLUIDVOICE_SILENCE_EOU"] else {
            throw XCTSkip("FLUIDVOICE_SILENCE_EOU not set")
        }
        let sessionDirectory = URL(fileURLWithPath: root, isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let micTrack = try decoder.decode(
            MeetingAudioTrack.self,
            from: Data(contentsOf: sessionDirectory.appending(path: "tracks/microphone/track.json"))
        )
        // Chunk 3 spans session 180-240s and contains known real user speech at 215.2-224.7.
        guard let chunk = micTrack.chunks.first(where: { $0.sequence == 3 }) else {
            throw XCTSkip("expected chunk sequence 3")
        }
        let speech = try MeetingProcessingPipeline.readSamples(
            fileURL: sessionDirectory.appending(path: chunk.relativeFilePath),
            startSeconds: 35.2,
            endSeconds: 44.7
        )
        XCTAssertFalse(speech.isEmpty)

        let manager = StreamingEouAsrManager(chunkSize: .ms160)
        try await manager.loadModelsFromHuggingFace()

        let events = EouEventLog()
        await manager.setEouCallback { transcript in
            Task { await events.record(transcript) }
        }

        let sampleRate = 16_000.0
        let blockFrames = 2_560  // one 160ms chunk

        func feed(_ samples: [Float]) async throws {
            var index = 0
            while index < samples.count {
                let end = min(index + blockFrames, samples.count)
                let slice = Array(samples[index..<end])
                guard let buffer = Self.buffer(slice, sampleRate: sampleRate) else { break }
                try await manager.appendAudio(buffer)
                try await manager.processBufferedAudio()
                index = end
            }
        }

        try await feed(speech)
        let afterSpeech = await events.count
        print("[silence-eou] fed \(String(format: "%.1f", Double(speech.count) / sampleRate))s speech, EOUs so far: \(afterSpeech)")

        // Then sustained digital silence, checked block by block so we can report WHEN it fires.
        let silenceBlocks = Int(8.0 * sampleRate) / blockFrames
        var firedAfterSeconds: Double?
        for block in 0..<silenceBlocks {
            guard let buffer = Self.buffer(Array(repeating: 0, count: blockFrames), sampleRate: sampleRate) else { break }
            try await manager.appendAudio(buffer)
            try await manager.processBufferedAudio()
            await Task.yield()
            if firedAfterSeconds == nil, await events.count > afterSpeech {
                firedAfterSeconds = Double(block + 1) * Double(blockFrames) / sampleRate
            }
        }
        // Callbacks hop through tasks; give them a moment to land.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let total = await events.count

        print("[silence-eou] total EOUs=\(total) (before silence: \(afterSpeech))")
        if let firedAfterSeconds {
            print(String(format: "[silence-eou] RESULT: EOU FIRED %.2fs into silence (debounce is 1.28s)", firedAfterSeconds))
        } else {
            print("[silence-eou] RESULT: NO EOU after 8.0s of digital silence")
        }
        for (index, text) in await events.transcripts.enumerated() {
            print("[silence-eou]   eou#\(index + 1) chars=\(text.count) text=\(text.prefix(90))")
        }
        await manager.reset()
    }

    private static func buffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

private actor EouEventLog {
    private(set) var transcripts: [String] = []
    var count: Int { self.transcripts.count }
    func record(_ text: String) { self.transcripts.append(text) }
}
#endif
