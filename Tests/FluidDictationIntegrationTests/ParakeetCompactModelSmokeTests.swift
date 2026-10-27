import AVFoundation
import CryptoKit
@testable import FluidVoice_Debug
import Foundation
import XCTest
#if arch(arm64)
import FluidAudio
#endif

@MainActor
final class ParakeetCompactModelSmokeTests: XCTestCase {
    func testShippedRuntimeCheckRecordingIsBundledAndUnchanged() throws {
        let url = try XCTUnwrap(CompactSpeechModelRuntimeCheck.recordingURL)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 131_162)
        XCTAssertEqual(
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "961ac4a204b913fb953e1ef9a7d4a54a235f69a3bf0a818a6712968bacdde68d"
        )
        let samples = try CompactSpeechModelRuntimeCheck.samples()
        XCTAssertEqual(samples.count, 65_581)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertTrue(samples.contains { abs($0) > 0.01 })
    }

    func testRuntimeCheckRequiresFiveDistinctWholeWords() {
        XCTAssertTrue(CompactSpeechModelRuntimeCheck.accepts("QUICK, brown fox jumps over."))
        XCTAssertTrue(CompactSpeechModelRuntimeCheck.accepts("The quick brown fox jumps over the lazy dog near quiet water."))
        XCTAssertFalse(CompactSpeechModelRuntimeCheck.accepts("quick brown fox jumps"))
        XCTAssertFalse(CompactSpeechModelRuntimeCheck.accepts("quick quick quick quick quick"))
        XCTAssertFalse(CompactSpeechModelRuntimeCheck.accepts("quickly brownish foxes jumping overhead"))
        XCTAssertFalse(CompactSpeechModelRuntimeCheck.accepts(""))
    }

    func testRuntimeCheckRejectsInvalidAndOversizedPCM() throws {
        for data in [Data(), Data([0]), Data(repeating: 0, count: 32_001), Data(repeating: 0, count: 480_002)] {
            XCTAssertThrowsError(try CompactSpeechModelRuntimeCheck.decode(data)) { error in
                XCTAssertEqual(error as? CompactSpeechModelRuntimeCheck.Failure, .invalidRecording)
            }
        }
        var data = Data(repeating: 0, count: 32_000)
        data[0] = 0xff
        data[1] = 0x7f
        data[2] = 0
        data[3] = 0x80
        let samples = try CompactSpeechModelRuntimeCheck.decode(data)
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertEqual(samples[0], 32_767.0 / 32_768)
        XCTAssertEqual(samples[1], -1)
    }

    func testRuntimeDeadlineJoinsCanceledProofCleanup() async throws {
        let activity = RuntimeCheckActivity()
        do {
            try await CompactSpeechModelRuntimeCheck.withDeadline(.milliseconds(10)) {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    await activity.finish()
                    throw error
                }
            }
            XCTFail("A blocked proof must time out")
        } catch {
            XCTAssertEqual(error as? CompactSpeechModelRuntimeCheck.Failure, .timedOut)
        }
        let finished = await activity.finished
        XCTAssertTrue(finished, "The installer must not delete staged files while proof still uses them")
    }

    func testCanceledRuntimeProofJoinsCleanupWithoutReportingBadWeights() async throws {
        let activity = RuntimeCheckActivity()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await CompactSpeechModelRuntimeCheck.withDeadline(.seconds(60)) {
                continuation.yield(())
                continuation.finish()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    await activity.finish()
                    throw error
                }
            }
        }
        for await _ in started { break }
        task.cancel()
        do {
            try await task.value
            XCTFail("Canceled verification must not publish weights")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let finished = await activity.finished
        XCTAssertTrue(finished)
    }

    func testSuccessfulRuntimeProofCancelsDeadline() async throws {
        let activity = RuntimeCheckActivity()
        try await CompactSpeechModelRuntimeCheck.withDeadline(.seconds(60)) {
            await activity.finish()
        }
        let finished = await activity.finished
        XCTAssertTrue(finished)
    }

    func testHostedOldWeightsStayUsableUntilExplicitValidatedUpdate() async throws {
        #if arch(arm64)
        guard ProcessInfo.processInfo.environment["FLUIDVOICE_COMPACT_MODEL_AUDIO"] != nil else {
            throw XCTSkip("Explicitly enable hosted compact model runtime checks")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoiceCompactUpdate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = SettingsStore.shared.selectedSpeechModel
        let fixtures: [(SettingsStore.SpeechModel, Int64, String)] = [
            (.fluidParakeetMini, 254_126_592, "12109f89c80b959847ac80ae963714a00af08f029144c3e4a2a8c1641f528a36"),
            (.fluidParakeetPico, 161_201_152, "afcdd76d4aba0328c97c858ee5c4c227ab5e23cc6885de5299d009c3671fe5d6"),
        ]
        for (model, bytes, oldHash) in fixtures {
            let latest = try XCTUnwrap(model.parakeetDescriptor)
            let oldURL = try XCTUnwrap(URL(string: "https://models.fluidvoice.app/parakeet/fluid-\(latest.variant.rawValue)/1.0.0/\(latest.folderName).tar"))
            let old = latest.replacingArchive(url: oldURL, sha256: oldHash, byteCount: bytes)
            let directory = try await ParakeetArchiveDownloader.ensurePresent(descriptor: old, in: root)
            let probe = SpeechModelInstallationSnapshot.Probe(modelID: model.id, kind: .parakeet(latest))
            let before = try await SpeechModelInstallationSnapshot.scanResult([probe], modelsDirectory: root)
            XCTAssertEqual(before.installedIDs, [model.id])
            XCTAssertEqual(before.updateAvailableIDs, [model.id])
            XCTAssertEqual(before.installedArchiveHashes[model.id], oldHash)
            do {
                let provider = FluidAudioProvider(modelOverride: model, configureWordBoosting: false)
                provider.modelCacheRootForTesting = root
                try await provider.prepare()
                XCTAssertTrue(provider.isReady)
                XCTAssertEqual(provider.pronunciationModelKeyForTesting, old.pronunciationModelKey)
                XCTAssertEqual(latest.installedArchiveSHA256(at: directory), oldHash)
            }
            let updater = FluidAudioProvider(modelOverride: model, configureWordBoosting: false, updateCompactWeights: true)
            updater.modelCacheRootForTesting = root
            try await updater.prepare()
            XCTAssertTrue(latest.artifactsAreComplete(at: directory))
            let after = try await SpeechModelInstallationSnapshot.scanResult([probe], modelsDirectory: root)
            XCTAssertEqual(after.installedIDs, [model.id])
            XCTAssertTrue(after.updateAvailableIDs.isEmpty)
            XCTAssertEqual(after.installedArchiveHashes[model.id], latest.archiveSHA256)
            let provider = FluidAudioProvider(modelOverride: model, configureWordBoosting: false)
            provider.modelCacheRootForTesting = root
            try await provider.prepare()
            XCTAssertTrue(provider.isReady)
            XCTAssertEqual(provider.pronunciationModelKeyForTesting, latest.pronunciationModelKey)
            XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selection)
        }
        #else
        throw XCTSkip("Compact Parakeet models require Apple silicon")
        #endif
    }

    func testHostedCompactModelsDownloadLoadTranscribeAndExtractDictionaryFrames() async throws {
        #if arch(arm64)
        guard let audioPath = ProcessInfo.processInfo.environment["FLUIDVOICE_COMPACT_MODEL_AUDIO"] else {
            throw XCTSkip("Set FLUIDVOICE_COMPACT_MODEL_AUDIO to an English test recording for the hosted model check")
        }
        let verificationSamples = try CompactSpeechModelRuntimeCheck.samples()
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
            // Exercise first-download publication through the real provider's staged proof.
            do {
                let model: SettingsStore.SpeechModel = descriptor.variant == .mini ? .fluidParakeetMini : .fluidParakeetPico
                let provider = FluidAudioProvider(modelOverride: model, configureWordBoosting: false)
                provider.modelCacheRootForTesting = root
                try await provider.prepare()
                XCTAssertTrue(provider.isReady)
                XCTAssertFalse(provider.isWordBoostingActive)
            }
            let directory = descriptor.cacheDirectory(in: root)
            XCTAssertTrue(descriptor.artifactsAreComplete(at: directory))
            let models = try await AsrModels.loadLocalOnly(from: directory, version: descriptor.asrModelVersion)
            XCTAssertEqual(models.version, descriptor.asrModelVersion)
            XCTAssertNotNil(models.splitEncoder)
            XCTAssertEqual(models.encoderOutputShape.count, 3)
            let hiddenDimension = try XCTUnwrap(models.encoderOutputShape.dropFirst().first)
            XCTAssertEqual(hiddenDimension, models.version.encoderHiddenSize)
            let manager = AsrManager(config: .default)
            do {
                try await manager.initialize(models: models)
                let verification = try await manager.transcribe(verificationSamples, source: .microphone)
                XCTAssertTrue(CompactSpeechModelRuntimeCheck.accepts(verification.text), "Shipped sentence failed: \(verification.text)")
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

private actor RuntimeCheckActivity {
    private(set) var finished = false
    func finish() { self.finished = true }
}
