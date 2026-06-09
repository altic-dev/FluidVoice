import Foundation

#if arch(arm64)
import FluidAudio

private actor SenseVoiceProgressSink {
    private let handler: ((Double) -> Void)?

    init(handler: ((Double) -> Void)?) {
        self.handler = handler
    }

    func emit(_ progress: Double) {
        self.handler?(progress)
    }
}

final class SenseVoiceProvider: TranscriptionProvider {
    let name = "SenseVoice"
    var isAvailable: Bool { true }
    private(set) var isReady = false

    private let precision: SenseVoiceEncoderPrecision = .int8
    private let language: Int32 = SenseVoiceConfig.englishLanguage
    private let maxSamplesPerPass = 96 * SenseVoiceConfig.sampleRate
    private var manager: SenseVoiceManager?

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        guard self.isReady == false else { return }

        let progressSink = SenseVoiceProgressSink(handler: progressHandler)
        await progressSink.emit(0.05)
        let progressTicker = Task(priority: .utility) {
            var stagedProgress = 0.05
            let stageCap = 0.82
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { break }
                if stagedProgress >= stageCap { continue }

                let remaining = stageCap - stagedProgress
                let step = max(0.008, remaining * 0.12)
                stagedProgress = min(stageCap, stagedProgress + step)
                await progressSink.emit(stagedProgress)
            }
        }
        defer { progressTicker.cancel() }

        let manager = try await SenseVoiceManager.load(
            precision: self.precision,
            language: self.language,
            progressHandler: { progress in
                Task {
                    await progressSink.emit(min(0.88, progress.fractionCompleted * 0.88))
                }
            }
        )

        progressTicker.cancel()
        self.manager = manager
        self.isReady = true
        await progressSink.emit(1.0)
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard samples.count >= SenseVoiceConfig.sampleRate else {
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
        return try await self.transcribeChunked(samples)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeChunked(samples)
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        let converter = AudioConverter(sampleRate: Double(SenseVoiceConfig.sampleRate))
        let samples = try converter.resampleAudioFile(fileURL)
        return try await self.transcribeChunked(samples)
    }

    func modelsExistOnDisk() -> Bool {
        guard let directory = Self.cacheDirectory else { return false }
        return SenseVoiceModels.modelsExist(at: directory, precision: self.precision)
    }

    func clearCache() async throws {
        self.manager = nil
        self.isReady = false
        guard let directory = Self.cacheDirectory,
              FileManager.default.fileExists(atPath: directory.path)
        else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func transcribeChunked(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard samples.isEmpty == false else {
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
        guard let manager = self.manager else {
            throw Self.makeError("SenseVoice model is not initialized.")
        }

        if samples.count <= self.maxSamplesPerPass {
            let text = try await manager.transcribe(audio: samples)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ASRTranscriptionResult(text: text, confidence: text.isEmpty ? 0 : 1)
        }

        var transcriptions: [String] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + self.maxSamplesPerPass, samples.count)
            let chunkText = try await manager.transcribe(audio: Array(samples[offset..<end]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if chunkText.isEmpty == false {
                transcriptions.append(chunkText)
            }
            offset = end
        }

        let text = transcriptions.joined(separator: " ")
        return ASRTranscriptionResult(text: text, confidence: text.isEmpty ? 0 : 1)
    }

    private static var cacheDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.senseVoiceSmall.folderName, isDirectory: true)
    }

    private static func makeError(_ description: String) -> NSError {
        NSError(domain: "SenseVoiceProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
#else
final class SenseVoiceProvider: TranscriptionProvider {
    let name = "SenseVoice"
    var isAvailable: Bool { false }
    var isReady: Bool { false }

    func prepare(progressHandler: ((Double) -> Void)?) async throws {
        throw NSError(
            domain: "SenseVoiceProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "SenseVoice requires Apple Silicon."]
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "SenseVoiceProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "SenseVoice requires Apple Silicon."]
        )
    }
}
#endif
