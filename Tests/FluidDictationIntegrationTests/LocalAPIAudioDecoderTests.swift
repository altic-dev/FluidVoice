import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import XCTest

final class LocalAPIAudioDecoderTests: XCTestCase {
    // The LocalAPI enforces a 300-second limit on transcription audio.
    private let overLimitSeconds: Double = 305
    private let underLimitSeconds: Double = 1
    private let fixtureSampleRate: Double = 8_000

    func testInlineAudioOverLimitThrowsInsteadOfTruncating() throws {
        let data = try Self.makeSilentWavData(durationSeconds: self.overLimitSeconds, sampleRate: self.fixtureSampleRate)

        XCTAssertThrowsError(
            try LocalAPIAudioDecoder.samples(fromAudioData: data, suggestedExtension: "wav"),
            "Inline audio over the 300s limit must throw instead of silently truncating."
        ) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "LocalAPIAudioDecoder")
            XCTAssertEqual(nsError.code, -5)
        }
    }

    func testInlineAudioUnderLimitDecodesNormally() throws {
        let data = try Self.makeSilentWavData(durationSeconds: self.underLimitSeconds, sampleRate: self.fixtureSampleRate)

        let samples = try LocalAPIAudioDecoder.samples(fromAudioData: data, suggestedExtension: "wav")

        // Source is 1s of mono audio resampled to 16 kHz, so expect roughly 16k samples.
        XCTAssertGreaterThan(samples.count, 8_000, "Under-limit inline audio should decode to samples.")
        XCTAssertLessThan(samples.count, 24_000, "Decoded sample count should stay near the 16 kHz expectation.")
    }

    func testFilePathDecodeRejectsOverLimitAudio() throws {
        let url = try Self.makeSilentWavFile(durationSeconds: self.overLimitSeconds, sampleRate: self.fixtureSampleRate)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try LocalAPIAudioDecoder.samples(from: url)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "LocalAPIAudioDecoder")
            XCTAssertEqual(nsError.code, -5)
        }
    }

    // MARK: - Helpers

    private static func makeSilentWavData(durationSeconds: Double, sampleRate: Double) throws -> Data {
        let url = try makeSilentWavFile(durationSeconds: durationSeconds, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    private static func makeSilentWavFile(durationSeconds: Double, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidvoice-decoder-test-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try writeSilentWav(to: url, durationSeconds: durationSeconds, sampleRate: sampleRate)
        return url
    }

    private static func writeSilentWav(to url: URL, durationSeconds: Double, sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        // AVAudioFile flushes and closes the file when this local reference deallocates
        // at the end of this function, so callers can safely read the bytes afterwards.
        let file = try AVAudioFile(forWriting: url, settings: settings)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "LocalAPIAudioDecoderTests",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create writer audio format."]
            )
        }

        let totalFrames = AVAudioFrameCount((sampleRate * durationSeconds).rounded())
        let chunkSize: AVAudioFrameCount = 16_000
        var remaining = totalFrames
        while remaining > 0 {
            let thisChunk = min(chunkSize, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: thisChunk) else {
                throw NSError(
                    domain: "LocalAPIAudioDecoderTests",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to allocate writer buffer."]
                )
            }
            buffer.frameLength = thisChunk
            try file.write(from: buffer)
            remaining -= thisChunk
        }
    }
}
