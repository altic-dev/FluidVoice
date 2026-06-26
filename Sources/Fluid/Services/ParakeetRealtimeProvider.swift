import AVFoundation
import Foundation
#if arch(arm64)
@preconcurrency import CoreML
import FluidAudio

/// TranscriptionProvider implementation using FluidAudio's true streaming Parakeet EOU pipeline.
final class ParakeetRealtimeProvider: TranscriptionProvider {
    let name = "Parakeet Flash (FluidAudio)"

    var isAvailable: Bool { true }

    private(set) var isReady: Bool = false

    private let chunkSize: StreamingChunkSize
    private var engine: StreamingEouAsrManager?
    private var streamedSampleCount: Int = 0

    init(chunkSize: StreamingChunkSize = .ms160) {
        self.chunkSize = chunkSize
    }

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        guard self.isReady == false else { return }

        let modelDirectory = self.modelDirectory()
        let missingBefore = self.missingRequiredModelFiles()
        DebugLogger.shared.info(
            "ParakeetRealtimeProvider.prepare: cacheRoot=\(Self.cacheRootDirectory().path), modelDir=\(modelDirectory.path), chunkSize=\(self.chunkSize.modelSubdirectory)",
            source: "ParakeetRealtimeProvider"
        )
        if missingBefore.isEmpty {
            DebugLogger.shared.info(
                "ParakeetRealtimeProvider.prepare: all required Flash files already present on disk",
                source: "ParakeetRealtimeProvider"
            )
        } else {
            DebugLogger.shared.warning(
                "ParakeetRealtimeProvider.prepare: missing required Flash files before load: \(missingBefore.joined(separator: ", "))",
                source: "ParakeetRealtimeProvider"
            )
            DebugLogger.shared.debug(
                "ParakeetRealtimeProvider.prepare: cache snapshot before load: \(self.cacheSnapshotDescription())",
                source: "ParakeetRealtimeProvider"
            )
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.allowLowPrecisionAccumulationOnGPU = true

        let engine = StreamingEouAsrManager(configuration: configuration, chunkSize: self.chunkSize)
        do {
            try await engine.loadModelsFromHuggingFace(progressHandler: { progress in
                progressHandler?(max(0.0, min(1.0, progress.fractionCompleted)))
            })
        } catch {
            let missingAfterFailure = self.missingRequiredModelFiles()
            DebugLogger.shared.error(
                "ParakeetRealtimeProvider.prepare: Flash load failed. modelDir=\(modelDirectory.path), missingAfterFailure=\(missingAfterFailure.joined(separator: ", "))",
                source: "ParakeetRealtimeProvider"
            )
            DebugLogger.shared.debug(
                "ParakeetRealtimeProvider.prepare: cache snapshot after failure: \(self.cacheSnapshotDescription())",
                source: "ParakeetRealtimeProvider"
            )
            throw error
        }

        let missingAfter = self.missingRequiredModelFiles()
        guard missingAfter.isEmpty else {
            DebugLogger.shared.error(
                "ParakeetRealtimeProvider.prepare: Flash load returned, but required files are still missing: \(missingAfter.joined(separator: ", "))",
                source: "ParakeetRealtimeProvider"
            )
            DebugLogger.shared.debug(
                "ParakeetRealtimeProvider.prepare: cache snapshot after load: \(self.cacheSnapshotDescription())",
                source: "ParakeetRealtimeProvider"
            )
            throw NSError(
                domain: "ParakeetRealtimeProvider",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Parakeet Flash models are incomplete after load",
                    "modelDirectory": modelDirectory.path,
                    "missingFiles": missingAfter.joined(separator: ", "),
                ]
            )
        }

        DebugLogger.shared.info(
            "ParakeetRealtimeProvider.prepare: Flash models verified at \(modelDirectory.path)",
            source: "ParakeetRealtimeProvider"
        )

        self.engine = engine
        self.streamedSampleCount = 0
        self.isReady = true
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let engine = try self.requireEngine()
        let delta = try await self.consumeDelta(from: samples, engine: engine)
        if !delta.isEmpty {
            try await engine.appendAudio(self.createPCMBuffer(from: delta))
            try await engine.processBufferedAudio()
        }
        let partial = await engine.getPartialTranscript()
        return ASRTranscriptionResult(text: partial, confidence: partial.isEmpty ? 0 : 1)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let engine = try self.requireEngine()
        let delta = try await self.consumeDelta(from: samples, engine: engine)
        if !delta.isEmpty {
            try await engine.appendAudio(self.createPCMBuffer(from: delta))
            try await engine.processBufferedAudio()
        }

        let text = try await engine.finish()
        await engine.reset()
        self.streamedSampleCount = 0
        return ASRTranscriptionResult(text: text, confidence: text.isEmpty ? 0 : 1)
    }

    func modelsExistOnDisk() -> Bool {
        self.missingRequiredModelFiles().isEmpty
    }

    func clearCache() async throws {
        let cacheRoot = Self.cacheRootDirectory()
        if FileManager.default.fileExists(atPath: cacheRoot.path) {
            try FileManager.default.removeItem(at: cacheRoot)
        }
        self.isReady = false
        self.streamedSampleCount = 0
        self.engine = nil
    }

    private func requireEngine() throws -> StreamingEouAsrManager {
        guard let engine = self.engine else {
            throw NSError(
                domain: "ParakeetRealtimeProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Real-time ASR engine not initialized"]
            )
        }
        return engine
    }

    private func consumeDelta(from samples: [Float], engine: StreamingEouAsrManager) async throws -> [Float] {
        if samples.count < self.streamedSampleCount {
            await engine.reset()
            self.streamedSampleCount = 0
        }

        let delta = Array(samples.dropFirst(self.streamedSampleCount))
        self.streamedSampleCount = samples.count
        return delta
    }

    private func createPCMBuffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ),
            let channelData = buffer.floatChannelData
        else {
            throw NSError(
                domain: "ParakeetRealtimeProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer for streaming ASR"]
            )
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { samplePtr in
            guard let baseAddress = samplePtr.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: samples.count)
        }
        return buffer
    }

    private func modelDirectory() -> URL {
        Self.cacheRootDirectory().appendingPathComponent(Repo.parakeetEou160.folderName, isDirectory: true)
    }

    private func missingRequiredModelFiles() -> [String] {
        let modelDirectory = self.modelDirectory()
        return ModelNames.ParakeetEOU.requiredModels
            .sorted()
            .filter { fileName in
                !FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(fileName).path)
            }
    }

    private func cacheSnapshotDescription() -> String {
        let fm = FileManager.default
        let modelDirectory = self.modelDirectory()
        let rootDirectory = Self.cacheRootDirectory()
        let rootContents = (try? fm.contentsOfDirectory(atPath: rootDirectory.path).sorted()) ?? []
        let modelContents = (try? fm.contentsOfDirectory(atPath: modelDirectory.path).sorted()) ?? []
        let rootExists = fm.fileExists(atPath: rootDirectory.path)
        let modelExists = fm.fileExists(atPath: modelDirectory.path)
        return "rootExists=\(rootExists), modelExists=\(modelExists), rootContents=\(rootContents), modelContents=\(modelContents)"
    }

    private static func cacheRootDirectory() -> URL {
        let baseDirectory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )

        return baseDirectory
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
    }
}
#else
final class ParakeetRealtimeProvider: TranscriptionProvider {
    let name = "Parakeet Flash (FluidAudio)"
    var isAvailable: Bool { false }
    var isReady: Bool { false }

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        throw NSError(domain: "ParakeetRealtimeProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet Flash requires Apple Silicon"])
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NSError(domain: "ParakeetRealtimeProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Parakeet Flash requires Apple Silicon"])
    }
}
#endif
