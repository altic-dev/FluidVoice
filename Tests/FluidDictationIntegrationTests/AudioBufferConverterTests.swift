import AVFoundation
@testable import FluidVoice_Debug
import XCTest

final class AudioBufferConverterTests: XCTestCase {
    func testStereoDownmixIncludesRightChannel() throws {
        let buffer = try self.makeFloatBuffer(sampleRate: 16_000, channels: 2, frameCount: 16)
        self.fill(buffer, channel: 1, with: 1)

        let samples = try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)

        XCTAssertEqual(samples.count, 16)
        self.assertAllSamples(samples, equalTo: 0.5)
    }

    func testStereoDownmixIncludesLeftChannel() throws {
        let buffer = try self.makeFloatBuffer(sampleRate: 16_000, channels: 2, frameCount: 16)
        self.fill(buffer, channel: 0, with: 1)

        let samples = try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)

        XCTAssertEqual(samples.count, 16)
        self.assertAllSamples(samples, equalTo: 0.5)
    }

    func testStereoDownmixPreservesMatchingChannels() throws {
        let buffer = try self.makeFloatBuffer(sampleRate: 16_000, channels: 2, frameCount: 16)
        self.fill(buffer, channel: 0, with: 1)
        self.fill(buffer, channel: 1, with: 1)

        let samples = try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)

        XCTAssertEqual(samples.count, 16)
        self.assertAllSamples(samples, equalTo: 1)
    }

    func testMonoFloatFastPathPreservesSamples() throws {
        let expected: [Float] = [0.25, -0.5, 0.75, -1]
        let buffer = try self.makeFloatBuffer(
            sampleRate: 16_000,
            channels: 1,
            frameCount: expected.count
        )
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for (index, sample) in expected.enumerated() {
            channelData[0][index] = sample
        }

        let samples = try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)

        XCTAssertEqual(samples, expected)
    }

    func testStereoDownmixAndResampleIncludesRightChannel() throws {
        let buffer = try self.makeFloatBuffer(sampleRate: 48_000, channels: 2, frameCount: 480)
        self.fill(buffer, channel: 1, with: 1)

        let samples = try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)

        XCTAssertEqual(samples.count, 160)
        let average = samples.reduce(0, +) / Float(samples.count)
        XCTAssertEqual(average, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.4)
    }

    func testLocalAPIAudioChunkReaderBoundsMemoryAndPreservesFinalChunk() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-api-chunks-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let buffer = try self.makeFloatBuffer(sampleRate: 16_000, channels: 1, frameCount: 4000)
        do {
            let outputFile = try AVAudioFile(forWriting: fileURL, settings: buffer.format.settings)
            try outputFile.write(from: buffer)
        }

        let reader = try LocalAPIAudioDecoder.ChunkReader(
            fileURL: fileURL,
            chunkDurationSeconds: 0.1
        )

        let firstChunk = try await reader.nextSamples()
        let secondChunk = try await reader.nextSamples()
        let finalChunk = try await reader.nextSamples()

        XCTAssertEqual(firstChunk.count, 1600)
        XCTAssertEqual(secondChunk.count, 1600)
        XCTAssertEqual(finalChunk.count, 800)
        let exhaustedChunk = try await reader.nextSamples()
        XCTAssertTrue(exhaustedChunk.isEmpty)
        XCTAssertEqual(LocalAPIAudioDecoder.maxChunkDurationSeconds, 20 * 60)
    }

    func testLocalAPIExtensionlessUploadUsesTemporaryWAVAndCleansUp() async throws {
        let expectedData = Data([0, 1, 2, 3])
        let fileURL = try await LocalAPIAudioDecoder.temporaryFile(
            fromAudioData: expectedData,
            suggestedExtension: ""
        )

        XCTAssertEqual(fileURL.pathExtension, "wav")
        XCTAssertEqual(try Data(contentsOf: fileURL), expectedData)

        await LocalAPIAudioDecoder.removeTemporaryFile(at: fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeFloatBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frameCount: Int
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }

    private func fill(_ buffer: AVAudioPCMBuffer, channel: Int, with value: Float) {
        guard let channelData = buffer.floatChannelData else {
            XCTFail("Expected Float32 channel data")
            return
        }
        for frame in 0..<Int(buffer.frameLength) {
            channelData[channel][frame] = value
        }
    }

    private func assertAllSamples(
        _ samples: [Float],
        equalTo expected: Float,
        accuracy: Float = 0.00_001
    ) {
        for sample in samples {
            XCTAssertEqual(sample, expected, accuracy: accuracy)
        }
    }
}
