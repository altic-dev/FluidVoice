import Foundation
#if arch(arm64)
import FluidAudio

/// TranscriptionProvider implementation using FluidAudio (optimized for Apple Silicon)
/// This wraps the existing FluidAudio-based ASR for use on Apple Silicon Macs.
final class FluidAudioProvider: TranscriptionProvider {
    let name = "FluidAudio (Apple Silicon Optimized)"

    /// Whether this provider is supported on the current system.
    /// FluidAudio is optimized for Apple Silicon, but may still function on Intel.
    var isAvailable: Bool {
        true
    }

    private var asrManager: AsrManager?
    private(set) var isReady: Bool = false

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        guard self.isReady == false else { return }

        DebugLogger.shared.info("FluidAudioProvider: Starting model preparation", source: "FluidAudioProvider")

        // Download and load models
        let models = try await AsrModels.downloadAndLoad()

        // Initialize AsrManager
        let manager = AsrManager(config: ASRConfig.default)
        try await manager.initialize(models: models)
        self.asrManager = manager

        self.isReady = true
        DebugLogger.shared.info("FluidAudioProvider: Models ready", source: "FluidAudioProvider")
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let manager = asrManager else {
            throw NSError(
                domain: "FluidAudioProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ASR manager not initialized"]
            )
        }

        let result = try await manager.transcribe(samples, source: AudioSource.microphone)
        return ASRTranscriptionResult(text: result.text, confidence: result.confidence)
    }

    func modelsExistOnDisk() -> Bool {
        let baseCacheDir = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        let v3CacheDir = baseCacheDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
        return FileManager.default.fileExists(atPath: v3CacheDir.path)
    }

    func clearCache() async throws {
        let baseCacheDir = AsrModels.defaultCacheDirectory().deletingLastPathComponent()

        // Clear v2 cache
        let v2CacheDir = baseCacheDir.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml")
        if FileManager.default.fileExists(atPath: v2CacheDir.path) {
            try FileManager.default.removeItem(at: v2CacheDir)
        }

        // Clear v3 cache
        let v3CacheDir = baseCacheDir.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
        if FileManager.default.fileExists(atPath: v3CacheDir.path) {
            try FileManager.default.removeItem(at: v3CacheDir)
        }

        self.isReady = false
        self.asrManager = nil
    }

    /// Provides direct access to the underlying AsrManager for advanced use cases
    /// (e.g., MeetingTranscriptionService sharing)
    var underlyingManager: AsrManager? {
        return self.asrManager
    }
}
#else
/// Check-shim for Intel Macs where FluidAudio is not available
final class FluidAudioProvider: TranscriptionProvider {
    let name = "FluidAudio (Apple Silicon ONLY)"
    var isAvailable: Bool { false }
    var isReady: Bool { false }

    func prepare(progressHandler: ((Double) -> Void)?) async throws {
        throw NSError(
            domain: "FluidAudioProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not supported on Intel Macs"]
        )
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "FluidAudioProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not supported on Intel Macs"]
        )
    }
}
#endif
