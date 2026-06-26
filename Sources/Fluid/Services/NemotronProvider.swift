import Foundation

#if arch(arm64)
import AVFoundation
@preconcurrency import CoreML
import FluidAudio

@available(macOS 14.0, *)
final class NemotronProvider: TranscriptionProvider {
    enum Mode: Hashable {
        case offline
        case streaming
        case streaming320

        var displayName: String {
            switch self {
            case .offline: return "Nemotron 3.5 Multilingual"
            case .streaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .streaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            }
        }

        var folderHint: String {
            switch self {
            case .offline: return "nemotron-3.5-asr-offline-6bit-CoreML"
            case .streaming: return "nemotron-3.5-asr-streaming320-int8-CoreML"
            case .streaming320: return "nemotron-3.5-asr-streaming320-int8-CoreML"
            }
        }

        var repositoryName: String { self.folderHint }
    }

    var name: String { self.mode.displayName }
    var isAvailable: Bool { true }
    private(set) var isReady: Bool = false
    var prefersNativeFileTranscription: Bool { true }

    private let repositoryOwner = "BarathwajAnandan"
    private let repositoryRevision = "main"
    private let requiredFiles = [
        "metadata.json",
        "preprocessor.mlpackage",
        "encoder.mlpackage",
        "decoder.mlpackage",
        "joint.mlpackage",
        "joint_decision.mlpackage",
        "tokenizer.model",
    ]

    private let mode: Mode
    private var manager: NemotronStreamingAsrManager?
    private var streamedSampleCount: Int = 0
    private var activeLanguageCode: String?
    private var componentProfilingSessionActive = false
    private var maxTranscriptionSamples: Int = 240_000
    private let minimumFinalChunkSamples: Int = 16_000
    private let chunkBoundarySearchRadiusSamples: Int = 32_000
    private let chunkBoundaryAnalysisWindowSamples: Int = 1280
    private let chunkBoundaryAnalysisStrideSamples: Int = 320
    private static var componentProfilingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ASRComponentProfilingEnabled")
    }

    private var folderHint: String { self.mode.folderHint }
    private var repositoryName: String { self.mode.repositoryName }

    init(mode: Mode = .offline) {
        self.mode = mode
    }

    private var cacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(self.folderHint, isDirectory: true)
    }

    func modelsExistOnDisk() -> Bool {
        guard let dir = self.cacheDirectory else { return false }
        return self.requiredFiles.allSatisfy { entry in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(entry).path)
        }
    }

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        guard self.isReady == false else { return }
        guard let dir = self.cacheDirectory else {
            throw Self.makeError("Unable to resolve a cache directory for \(self.name).")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A file-existence check alone would trust a corrupt cache: a network proxy can have
        // returned an HTML block page (HTTP 200) in place of a model file, persisting markup as
        // e.g. a `.mlpackage` binary or `tokenizer.model`. Re-sniff the present artifacts so such
        // a payload forces a re-download (the downloader then deletes + re-fetches the bad files
        // via `needsDownload`) instead of being loaded as a model forever. See #353.
        let modelsPresent = self.modelsExistOnDisk()
        let cachedArtifactsCorrupt = modelsPresent
            && HuggingFaceModelDownloader.cachedPayloadContainsMarkup(root: dir, relativePaths: self.requiredFiles)
        if modelsPresent && !cachedArtifactsCorrupt {
            DebugLogger.shared.info(
                "Nemotron: artifacts present at \(dir.path); skipping download",
                source: "Nemotron"
            )
            progressHandler?(0.8)
        } else {
            if cachedArtifactsCorrupt {
                DebugLogger.shared.warning(
                    "Nemotron: cached artifacts at \(dir.path) contain an HTML/markup payload (corrupt); re-downloading",
                    source: "Nemotron"
                )
            }
            DebugLogger.shared.info(
                "Nemotron: artifacts missing; downloading from \(self.repositoryOwner)/\(self.repositoryName)",
                source: "Nemotron"
            )
            let downloader = HuggingFaceModelDownloader(
                owner: self.repositoryOwner,
                repo: self.repositoryName,
                revision: self.repositoryRevision,
                requiredItems: self.requiredFiles.map {
                    .init(path: $0, isDirectory: $0.hasSuffix(".mlpackage"))
                }
            )
            try await downloader.ensureModelsPresent(at: dir) { progress, _ in
                progressHandler?(progress * 0.8)
            }
            guard self.modelsExistOnDisk() else {
                throw Self.makeError("Nemotron artifacts incomplete after download at \(dir.path).")
            }
        }

        self.maxTranscriptionSamples = Self.loadMaxAudioSamples(from: dir) ?? self.maxTranscriptionSamples
        let manager: NemotronStreamingAsrManager
        do {
            manager = try await self.loadManager(modelDirectory: dir, computeUnits: .cpuAndNeuralEngine)
        } catch {
            guard Self.shouldRetryWithoutNeuralEngine(error) else {
                throw error
            }
            DebugLogger.shared.warning(
                "Nemotron: ANE model load failed; retrying with cpuAndGPU fallback [error=\(error.localizedDescription)]",
                source: "Nemotron"
            )
            manager = try await self.loadManager(modelDirectory: dir, computeUnits: .cpuAndGPU)
        }
        try await self.applySelectedLanguage(to: manager)
        self.manager = manager
        self.isReady = true
        progressHandler?(1.0)
        DebugLogger.shared.info(
            "Nemotron: provider ready [mode=\(self.mode.displayName), lang=\(SettingsStore.shared.selectedNemotronLanguage.rawValue), maxSamples=\(self.maxTranscriptionSamples)]",
            source: "Nemotron"
        )
    }

    private func loadManager(modelDirectory: URL, computeUnits: MLComputeUnits) async throws -> NemotronStreamingAsrManager {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        configuration.allowLowPrecisionAccumulationOnGPU = true
        let manager = NemotronStreamingAsrManager(configuration: configuration)
        try await manager.loadModels(modelDir: modelDirectory)
        DebugLogger.shared.info(
            "Nemotron: loaded CoreML models with \(Self.describeComputeUnits(computeUnits))",
            source: "Nemotron"
        )
        return manager
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard self.mode != .offline else {
            return try await self.transcribeFinal(samples)
        }
        guard let manager = self.manager else {
            throw Self.makeError("Nemotron provider is not ready.")
        }

        try await self.applySelectedLanguage(to: manager)
        await self.startComponentProfilingIfNeeded(on: manager)
        let delta = await self.consumeDelta(from: samples, manager: manager)
        if delta.isEmpty == false {
            do {
                try await manager.appendAudio(Self.makeBuffer(delta))
                try await manager.processBufferedAudio()
            } catch {
                await self.stopComponentProfilingIfNeeded(on: manager)
                throw error
            }
        }
        let text = await manager.getPartialTranscript()
        return ASRTranscriptionResult(text: text, confidence: text.isEmpty ? 0 : 1)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let manager = self.manager else {
            throw Self.makeError("Nemotron provider is not ready.")
        }
        guard samples.isEmpty == false else {
            await self.stopComponentProfilingIfNeeded(on: manager)
            await manager.reset()
            self.streamedSampleCount = 0
            return ASRTranscriptionResult(text: "", confidence: 0)
        }

        if self.mode != .offline {
            try await self.applySelectedLanguage(to: manager)
            await self.startComponentProfilingIfNeeded(on: manager)
            let delta = await self.consumeDelta(from: samples, manager: manager)
            if delta.isEmpty == false {
                do {
                    try await manager.appendAudio(Self.makeBuffer(delta))
                    try await manager.processBufferedAudio()
                } catch {
                    await self.stopComponentProfilingIfNeeded(on: manager)
                    await manager.reset()
                    self.streamedSampleCount = 0
                    throw error
                }
            }

            let text: String
            do {
                text = try await manager.finish()
            } catch {
                await self.stopComponentProfilingIfNeeded(on: manager)
                await manager.reset()
                self.streamedSampleCount = 0
                throw error
            }
            await self.finishComponentProfilingIfNeeded(on: manager, samples: samples)
            await manager.reset()
            self.streamedSampleCount = 0
            return ASRTranscriptionResult(text: text, confidence: text.isEmpty ? 0 : 1)
        }

        return try await self.transcribeBatched(samples)
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        guard self.manager != nil else {
            throw Self.makeError("Nemotron provider is not ready.")
        }

        let audioFile = try AVAudioFile(forReading: fileURL)
        let sourceFormat = audioFile.processingFormat
        let targetSampleRate = 16_000.0
        let resampleRatio = targetSampleRate / sourceFormat.sampleRate
        let sourceFramesPerRead = AVAudioFrameCount(
            max(1, Double(self.regularChunkSamples) / resampleRatio)
        )
        var currentFrame: AVAudioFramePosition = 0
        var pendingSamples: [Float] = []
        var transcriptions: [String] = []

        while currentFrame < audioFile.length {
            let remainingFrames = AVAudioFrameCount(audioFile.length - currentFrame)
            let framesToRead = min(sourceFramesPerRead, remainingFrames)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: framesToRead) else {
                throw Self.makeError("Failed to allocate file audio buffer.")
            }

            audioFile.framePosition = currentFrame
            try audioFile.read(into: buffer, frameCount: framesToRead)
            try pendingSamples.append(contentsOf: Self.resampleBuffer(buffer, targetSampleRate: targetSampleRate))
            while pendingSamples.count > self.maxTranscriptionSamples {
                let end = self.chunkEnd(in: pendingSamples, offset: 0)
                let text = try await self.transcribeSinglePass(Array(pendingSamples[..<end]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty == false {
                    transcriptions.append(text)
                }
                pendingSamples.removeFirst(end)
            }
            currentFrame += AVAudioFramePosition(framesToRead)
        }

        if pendingSamples.count >= Int(targetSampleRate) {
            let result = try await self.transcribeBatched(pendingSamples)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty == false {
                transcriptions.append(text)
            }
        }

        let text = transcriptions.joined(separator: " ")
        return ASRTranscriptionResult(text: text, confidence: text.isEmpty ? 0 : 1)
    }

    func clearCache() async throws {
        if let manager = self.manager {
            await self.stopComponentProfilingIfNeeded(on: manager)
        }
        if let dir = self.cacheDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        self.manager = nil
        self.isReady = false
        self.streamedSampleCount = 0
        self.activeLanguageCode = nil
    }

    private func transcribeBatched(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard samples.isEmpty == false else { return ASRTranscriptionResult(text: "", confidence: 0) }

        if samples.count <= self.maxTranscriptionSamples {
            let text = try await self.transcribeSinglePass(samples)
            return ASRTranscriptionResult(text: text, confidence: text.isEmpty ? 0 : 1)
        }

        var transcriptions: [String] = []
        var offset = 0
        while offset < samples.count {
            let end = self.chunkEnd(in: samples, offset: offset)
            let text = try await self.transcribeSinglePass(Array(samples[offset..<end]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty == false {
                transcriptions.append(text)
            }
            offset = end
        }

        let text = transcriptions.joined(separator: " ")
        return ASRTranscriptionResult(text: text, confidence: text.isEmpty ? 0 : 1)
    }

    private var regularChunkSamples: Int {
        max(self.maxTranscriptionSamples - self.minimumFinalChunkSamples, self.minimumFinalChunkSamples)
    }

    private func chunkEnd(in samples: [Float], offset: Int) -> Int {
        let maxEnd = min(offset + self.maxTranscriptionSamples, samples.count)
        guard maxEnd < samples.count else { return samples.count }

        let preferredEnd = min(offset + self.regularChunkSamples, maxEnd)
        let latestEndWithValidTail = max(offset + self.minimumFinalChunkSamples, samples.count - self.minimumFinalChunkSamples)
        let upperBound = min(maxEnd, latestEndWithValidTail, preferredEnd + self.chunkBoundarySearchRadiusSamples)
        let lowerBound = max(offset + self.minimumFinalChunkSamples, preferredEnd - self.chunkBoundarySearchRadiusSamples)
        guard lowerBound < upperBound else { return preferredEnd }

        return self.quietestBoundary(
            in: samples,
            lowerBound: lowerBound,
            upperBound: upperBound,
            preferredEnd: preferredEnd
        ) ?? preferredEnd
    }

    private func quietestBoundary(
        in samples: [Float],
        lowerBound: Int,
        upperBound: Int,
        preferredEnd: Int
    ) -> Int? {
        let analysisWindow = min(self.chunkBoundaryAnalysisWindowSamples, max(1, upperBound - lowerBound))
        let halfWindow = max(1, analysisWindow / 2)
        let stride = max(1, self.chunkBoundaryAnalysisStrideSamples)
        var bestBoundary: Int?
        var bestScore = Float.greatestFiniteMagnitude
        var boundary = lowerBound

        while boundary <= upperBound {
            let windowStart = max(0, boundary - halfWindow)
            let windowEnd = min(samples.count, boundary + halfWindow)
            var energy: Float = 0
            for index in windowStart..<windowEnd {
                energy += abs(samples[index])
            }

            let sampleCount = max(1, windowEnd - windowStart)
            let distancePenalty = Float(abs(boundary - preferredEnd)) / Float(max(1, self.chunkBoundarySearchRadiusSamples)) * 0.0001
            let score = energy / Float(sampleCount) + distancePenalty
            if score < bestScore {
                bestScore = score
                bestBoundary = boundary
            }
            boundary += stride
        }

        return bestBoundary
    }

    private func transcribeSinglePass(_ samples: [Float]) async throws -> String {
        guard let manager = self.manager else {
            throw Self.makeError("Nemotron provider is not ready.")
        }
        try await self.applySelectedLanguage(to: manager)
        await self.startComponentProfilingIfNeeded(on: manager)
        let buffer = try Self.makeBuffer(samples)
        let text: String
        do {
            text = try await manager.transcribe(audioBuffer: buffer)
        } catch {
            await self.stopComponentProfilingIfNeeded(on: manager)
            await manager.reset()
            self.streamedSampleCount = 0
            throw error
        }
        await self.finishComponentProfilingIfNeeded(on: manager, samples: samples)
        await manager.reset()
        self.streamedSampleCount = 0
        return text
    }

    private func startComponentProfilingIfNeeded(on manager: NemotronStreamingAsrManager) async {
        guard Self.componentProfilingEnabled else {
            await self.stopComponentProfilingIfNeeded(on: manager)
            return
        }
        guard self.componentProfilingSessionActive == false else { return }
        await manager.setComponentProfilingEnabled(true)
        self.componentProfilingSessionActive = true
    }

    private func finishComponentProfilingIfNeeded(on manager: NemotronStreamingAsrManager, samples: [Float]) async {
        guard self.componentProfilingSessionActive else { return }
        let profile = await manager.componentProfileSnapshot()
        self.logComponentProfile(profile, samples: samples)
        await self.stopComponentProfilingIfNeeded(on: manager)
    }

    private func stopComponentProfilingIfNeeded(on manager: NemotronStreamingAsrManager) async {
        guard self.componentProfilingSessionActive else { return }
        await manager.setComponentProfilingEnabled(false)
        self.componentProfilingSessionActive = false
    }

    private func applySelectedLanguage(to manager: NemotronStreamingAsrManager) async throws {
        let languageCode = SettingsStore.shared.selectedNemotronLanguage.rawValue
        guard self.activeLanguageCode != languageCode else { return }
        try await manager.setTargetLanguage(languageCode)
        self.activeLanguageCode = languageCode
    }

    private func consumeDelta(from samples: [Float], manager: NemotronStreamingAsrManager) async -> [Float] {
        if samples.count < self.streamedSampleCount {
            await manager.reset()
            self.streamedSampleCount = 0
        }

        let delta = Array(samples.dropFirst(self.streamedSampleCount))
        self.streamedSampleCount = samples.count
        return delta
    }

    private static func makeBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))
            )
        else {
            throw self.makeError("Failed to allocate audio buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if samples.isEmpty == false {
            guard let channelData = buffer.floatChannelData else {
                throw self.makeError("Failed to access audio buffer channel data.")
            }
            samples.withUnsafeBufferPointer { samplePtr in
                guard let baseAddress = samplePtr.baseAddress else { return }
                channelData[0].update(from: baseAddress, count: samples.count)
            }
        }
        return buffer
    }

    private func logComponentProfile(_ profile: NemotronComponentProfile, samples: [Float]) {
        let audioMs = Int((Double(samples.count) / 16_000.0 * 1000).rounded())
        DebugLogger.shared.info(
            """
            ASR_COMPONENT provider=nemotron model=\(self.mode.displayName) samples=\(samples.count) audioMs=\(audioMs) \
            totalMs=\(Self.ms(profile.totalChunkTime)) inputMs=\(Self.ms(profile.audioInputTime)) \
            preprocessorMs=\(Self.ms(profile.preprocessorTime)) melInputMs=\(Self.ms(profile.melInputTime)) \
            encoderMs=\(Self.ms(profile.encoderTime)) decodeMs=\(Self.ms(profile.decodeLoopTime)) \
            decoderMs=\(Self.ms(profile.decoderTime)) jointDecisionMs=\(Self.ms(profile.jointDecisionTime)) \
            jointMs=\(Self.ms(profile.jointTime)) encoderStepCopyMs=\(Self.ms(profile.encoderStepCopyTime)) \
            decodeSteps=\(profile.decodeSteps) chunks=\(profile.chunks)
            """,
            source: "ASRBenchmark"
        )
    }

    private static func ms(_ seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    private static func resampleBuffer(_ buffer: AVAudioPCMBuffer, targetSampleRate: Double) throws -> [Float] {
        let sourceFormat = buffer.format
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw Self.makeError("Failed to create target audio format.")
        }

        if sourceFormat.sampleRate == targetSampleRate,
           sourceFormat.channelCount == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32
        {
            guard let channelData = buffer.floatChannelData else {
                throw Self.makeError("Failed to access audio channel data.")
            }
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw Self.makeError("Failed to create audio converter.")
        }
        let ratio = targetSampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw Self.makeError("Failed to allocate converted audio buffer.")
        }

        var consumedInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if consumedInput {
                status.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }
        guard let channelData = outputBuffer.floatChannelData else {
            throw Self.makeError("Failed to access converted audio channel data.")
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    private static func loadMaxAudioSamples(from dir: URL) -> Int? {
        let url = dir.appendingPathComponent("metadata.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let samples = json["max_audio_samples"] as? Int, samples > 0 {
            return samples
        }
        if let shapes = json["shapes"] as? [String: Any],
           let audioSignal = shapes["audio_signal"] as? [Int],
           audioSignal.count > 1,
           audioSignal[1] > 0
        {
            return audioSignal[1]
        }
        return nil
    }

    private static func shouldRetryWithoutNeuralEngine(_ error: Error) -> Bool {
        if self.hasNeuralEngineRetryCode(error as NSError) {
            return true
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("model execution plan")
            || description.contains("error code: -14")
            || description.contains("error code -14")
    }

    private static func hasNeuralEngineRetryCode(_ error: NSError) -> Bool {
        if error.code == -14 {
            return true
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           self.hasNeuralEngineRetryCode(underlying)
        {
            return true
        }

        if let underlyingErrors = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
            return underlyingErrors.contains { self.hasNeuralEngineRetryCode($0) }
        }

        return false
    }

    private static func describeComputeUnits(_ computeUnits: MLComputeUnits) -> String {
        switch computeUnits {
        case .cpuOnly: return "cpuOnly"
        case .cpuAndGPU: return "cpuAndGPU"
        case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
        case .all: return "all"
        @unknown default: return "unknown"
        }
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(domain: "NemotronProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
#else
final class NemotronProvider: TranscriptionProvider {
    enum Mode {
        case offline
        case streaming
        case streaming320

        var displayName: String {
            switch self {
            case .offline: return "Nemotron 3.5 Multilingual"
            case .streaming: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            case .streaming320: return "Nemotron Speech 3.5 - Ultra Fast Low Latency"
            }
        }
    }

    var name: String { self.mode.displayName }
    var isAvailable: Bool { false }
    private(set) var isReady: Bool = false
    var prefersNativeFileTranscription: Bool { false }

    private let mode: Mode

    init(mode: Mode = .offline) {
        self.mode = mode
    }

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        throw Self.makeError("Nemotron requires Apple Silicon.")
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw Self.makeError("Nemotron requires Apple Silicon.")
    }

    func modelsExistOnDisk() -> Bool { false }

    private static func makeError(_ description: String) -> NSError {
        NSError(domain: "NemotronProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
#endif
