import Foundation
#if arch(arm64)
import VoxtralCore
#endif

/// TranscriptionProvider implementation using Voxtral MLX for Apple Silicon.
/// This provides on-device speech recognition using Mistral's Voxtral model via MLX.
final class VoxtralMLXProvider: TranscriptionProvider {
    let name = "Voxtral MLX"

    /// Whether this provider is supported on the current system.
    /// Voxtral MLX requires Apple Silicon.
    var isAvailable: Bool {
        CPUArchitecture.isAppleSilicon
    }

    #if arch(arm64)
    private var pipeline: VoxtralPipeline?
    #endif
    
    private(set) var isReady: Bool = false
    private var loadedModelId: String?

    /// Optional model override - if set, uses this model instead of the global setting.
    var modelOverride: SettingsStore.SpeechModel?

    init(modelOverride: SettingsStore.SpeechModel? = nil) {
        self.modelOverride = modelOverride
    }

    /// The model to use - reads from override first, then global setting
    private var currentModel: SettingsStore.SpeechModel {
        modelOverride ?? SettingsStore.shared.selectedSpeechModel
    }

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        #if arch(arm64)
        guard isReady == false else { return }

        let model = currentModel
        let modelId = model.id

        // Detect model change
        if isReady, loadedModelId != modelId {
            DebugLogger.shared.info("VoxtralMLXProvider: Model changed, forcing reload", source: "VoxtralMLXProvider")
            isReady = false
            pipeline?.unload()
            pipeline = nil
            loadedModelId = nil
        }

        DebugLogger.shared.info("VoxtralMLXProvider: Starting model preparation for \(model.displayName)", source: "VoxtralMLXProvider")

        // Map SpeechModel to VoxtralPipeline.Model
        let voxtralModel: VoxtralPipeline.Model
        switch model {
        case .voxtralMini:
            voxtralModel = .mini3b
        case .voxtralMini8bit:
            voxtralModel = .mini3b8bit
        case .voxtralMini4bit:
            voxtralModel = .mini3b4bit
        default:
            voxtralModel = .mini3b8bit // Default to 8-bit for best speed/quality balance
        }

        pipeline = VoxtralPipeline(model: voxtralModel, backend: .auto)

        do {
            try await pipeline?.loadModel { progress, status in
                DebugLogger.shared.debug("VoxtralMLXProvider: [\(Int(progress * 100))%] \(status)", source: "VoxtralMLXProvider")
                progressHandler?(progress)
            }

            loadedModelId = modelId
            isReady = true
            DebugLogger.shared.info("VoxtralMLXProvider: Model ready (\(model.displayName))", source: "VoxtralMLXProvider")
        } catch {
            DebugLogger.shared.error("VoxtralMLXProvider: Failed to load model: \(error)", source: "VoxtralMLXProvider")
            throw error
        }
        #else
        throw NSError(
            domain: "VoxtralMLXProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Voxtral MLX requires Apple Silicon"]
        )
        #endif
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        #if arch(arm64)
        guard let pipeline = pipeline else {
            throw NSError(
                domain: "VoxtralMLXProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Voxtral model not loaded"]
            )
        }

        // Voxtral expects audio files, so we need to create a temporary WAV file
        let tempURL = try createTempAudioFile(from: samples)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        DebugLogger.shared.debug("VoxtralMLXProvider: Starting transcription with \(samples.count) samples", source: "VoxtralMLXProvider")

        do {
            // Use "auto" for automatic language detection
            let text = try await pipeline.transcribe(audio: tempURL, language: "auto")
            let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            DebugLogger.shared.debug("VoxtralMLXProvider: Transcription completed: '\(cleanedText)'", source: "VoxtralMLXProvider")
            
            return ASRTranscriptionResult(text: cleanedText, confidence: 1.0)
        } catch {
            DebugLogger.shared.error("VoxtralMLXProvider: Transcription failed: \(error)", source: "VoxtralMLXProvider")
            throw error
        }
        #else
        throw NSError(
            domain: "VoxtralMLXProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Voxtral MLX requires Apple Silicon"]
        )
        #endif
    }

    func modelsExistOnDisk() -> Bool {
        // VoxtralCore handles model caching via HuggingFace Hub
        // For simplicity, we return true and let VoxtralCore handle downloading
        return true
    }

    func clearCache() async throws {
        #if arch(arm64)
        pipeline?.unload()
        pipeline = nil
        #endif
        isReady = false
        loadedModelId = nil
        DebugLogger.shared.info("VoxtralMLXProvider: Cache cleared", source: "VoxtralMLXProvider")
    }

    // MARK: - Audio File Conversion

    /// Creates a temporary WAV file from Float PCM samples.
    /// Voxtral expects audio file input rather than raw samples.
    private func createTempAudioFile(from samples: [Float]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("voxtral_input_\(UUID().uuidString).wav")

        // WAV file parameters (16kHz mono 16-bit PCM)
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(samples.count * 2) // 2 bytes per sample (16-bit)

        var data = Data()

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: (36 + dataSize).littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Chunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // Audio format (PCM)
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = numChannels * bitsPerSample / 8
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        // Convert Float [-1.0, 1.0] samples to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16Value.littleEndian) { Array($0) })
        }

        try data.write(to: tempURL)
        return tempURL
    }
}
