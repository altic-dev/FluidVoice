import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import XCTest
#if arch(arm64)
import FluidAudio
#endif

@MainActor
final class ParakeetCompactModelSmokeTests: XCTestCase {
    func testHostedCompactModelsDownloadLoadTranscribeAndExtractDictionaryFrames() async throws {
        #if arch(arm64)
        guard let audioPath = ProcessInfo.processInfo.environment["FLUIDVOICE_COMPACT_MODEL_AUDIO"] else {
            throw XCTSkip("Set FLUIDVOICE_COMPACT_MODEL_AUDIO to a real English recording for the live model check")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath), commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        XCTAssertFalse(samples.isEmpty)
        XCTAssertLessThanOrEqual(samples.count, 240_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoiceCompactModels-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = SettingsStore.shared.selectedSpeechModel
        for descriptor in [ParakeetSpeechModelCatalog.mini, ParakeetSpeechModelCatalog.pico] {
            let directory = try await ParakeetArchiveDownloader.ensurePresent(descriptor: descriptor, in: root)
            let models = try await AsrModels.loadLocalOnly(from: directory, version: descriptor.asrModelVersion)
            XCTAssertEqual(models.version, descriptor.asrModelVersion)
            XCTAssertNotNil(models.splitEncoder)
            XCTAssertEqual(models.encoderOutputShape.count, 3)
            let hiddenDimension = try XCTUnwrap(models.encoderOutputShape.dropFirst().first)
            XCTAssertEqual(hiddenDimension, models.version.encoderHiddenSize)
            let manager = AsrManager(config: .default)
            do {
                try await manager.initialize(models: models)
                let result = try await manager.transcribe(samples, source: .microphone)
                XCTAssertGreaterThanOrEqual(result.text.split(separator: " ").count, 3)
                let embedding = try await manager.pronunciationEmbedding(audioSamples: samples, focalSampleRange: 0..<samples.count)
                XCTAssertEqual(embedding.values.count, models.version.encoderHiddenSize)
                XCTAssertTrue(embedding.values.allSatisfy(\.isFinite))
                let frames = try await DictionaryTemporalEncoder.encode(samples, models: models)
                XCTAssertTrue(frames.isValid)
                XCTAssertEqual(frames.hiddenSize, models.version.encoderHiddenSize)
                XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selection)
                await manager.cleanup()
            } catch {
                await manager.cleanup()
                throw error
            }
        }
        #else
        throw XCTSkip("Compact Parakeet models require Apple silicon")
        #endif
    }
}
