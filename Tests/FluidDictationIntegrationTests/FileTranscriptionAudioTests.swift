import AVFoundation
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class FileTranscriptionAudioTests: XCTestCase {
    private final class RecordingProvider: TranscriptionProvider {
        let name = "Buffered file test provider"
        let isAvailable = true
        let isReady = true
        private(set) var inputs: [[Float]] = []

        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
            XCTFail("An already-ready provider must not prepare models")
        }

        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
            self.inputs.append(samples)
            // Observe the real file path without adding synthetic text to shared history.
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
    }

    func testSubsecondFilesPreserveSamplesAndAddOnlyTrailingSilence() async throws {
        for frameCount in [1, 8000, 15_999] {
            try await self.withTranscription(frameCount: frameCount) { result, provider in
                XCTAssertEqual(provider.inputs.count, 1, "Source frames: \(frameCount)")
                let input = try XCTUnwrap(provider.inputs.first)
                XCTAssertEqual(input.count, 16_000)
                XCTAssertEqual(Array(input.prefix(frameCount)), Array(repeating: 0.25, count: frameCount))
                XCTAssertEqual(Array(input.dropFirst(frameCount)), Array(repeating: 0, count: 16_000 - frameCount))
                XCTAssertEqual(result.duration, Double(frameCount) / 16_000, accuracy: 0.0001)
            }
        }
    }

    func testFilesAtOrAboveOneSecondAreNotPadded() async throws {
        for frameCount in [16_000, 16_001] {
            try await self.withTranscription(frameCount: frameCount) { result, provider in
                XCTAssertEqual(provider.inputs.count, 1, "Source frames: \(frameCount)")
                let input = try XCTUnwrap(provider.inputs.first)
                XCTAssertEqual(input, Array(repeating: 0.25, count: frameCount))
                XCTAssertEqual(result.duration, Double(frameCount) / 16_000, accuracy: 0.0001)
            }
        }
    }

    func testSubsecondTailAfterFullChunkStillReachesProvider() async throws {
        let fullChunkFrames = 20 * 60 * 16_000
        try await self.withTranscription(frameCount: fullChunkFrames + 4000) { result, provider in
            XCTAssertEqual(provider.inputs.count, 2)
            guard provider.inputs.count == 2 else { return }
            XCTAssertEqual(provider.inputs[0].count, fullChunkFrames)
            XCTAssertTrue(provider.inputs[0].allSatisfy { $0 == 0.25 })
            XCTAssertEqual(
                provider.inputs[1],
                Array(repeating: 0.25, count: 4000) + Array(repeating: 0, count: 12_000)
            )
            XCTAssertEqual(result.duration, 1200.25, accuracy: 0.0001)
        }
    }

    func testEmptyFileDoesNotCreatePaddedInference() async throws {
        try await self.withTranscription(frameCount: 0) { result, provider in
            XCTAssertTrue(provider.inputs.isEmpty)
            XCTAssertTrue(result.text.isEmpty)
            XCTAssertEqual(result.duration, 0)
        }
    }

    func testSubsecondSilenceIsPassedThroughWithoutChangingDuration() async throws {
        try await self.withTranscription(frameCount: 8000, sample: 0) { result, provider in
            XCTAssertEqual(provider.inputs.count, 1)
            let input = try XCTUnwrap(provider.inputs.first)
            XCTAssertEqual(input, Array(repeating: 0, count: 16_000))
            XCTAssertEqual(result.duration, 0.5, accuracy: 0.0001)
        }
    }

    private func withTranscription(
        frameCount: Int,
        sample: Float = 0.25,
        check: (TranscriptionResult, RecordingProvider) throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let keys = ["SelectedSpeechModel", "FileTranscriptionSpeakerLabelsEnabled"]
        let savedValues = keys.map { defaults.object(forKey: $0) }
        let settings = SettingsStore.shared
        settings.selectedSpeechModel = .whisperTiny
        settings.fileTranscriptionSpeakerLabelsEnabled = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTranscriptionAudio-\(UUID().uuidString)", isDirectory: true)
        defer {
            for (key, value) in zip(keys, savedValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("synthetic.wav")
        try Self.writeAudio(to: fileURL, frameCount: frameCount, sample: sample)

        let provider = RecordingProvider()
        let asr = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        asr.modelProvidersForTesting[.whisperTiny] = provider
        asr.isAsrReady = true
        let service = FileTranscriptionService(asrService: asr)
        do {
            let result = try await service.transcribeFile(fileURL)
            XCTAssertEqual(service.currentFileURL, fileURL)
            XCTAssertFalse(service.isTranscribing)
            XCTAssertNil(asr.activeExclusiveActivity)
            try check(result, provider)
            await asr.shutdownForTermination()
        } catch {
            await asr.shutdownForTermination()
            throw error
        }
    }

    private static func writeAudio(to url: URL, frameCount: Int, sample: Float) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ))
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let capacity: AVAudioFrameCount = 16_000
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity))
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        channel.update(repeating: sample, count: Int(capacity))
        var remaining = frameCount
        while remaining > 0 {
            let count = min(Int(capacity), remaining)
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            remaining -= count
        }
    }
}
