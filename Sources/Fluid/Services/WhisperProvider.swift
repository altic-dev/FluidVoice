import Foundation
import SwiftWhisper

/// TranscriptionProvider implementation using SwiftWhisper (whisper.cpp) for Intel Macs.
/// This provides on-device speech recognition that works on Intel x86_64 architecture.
final class WhisperProvider: TranscriptionProvider {
    let name = "Whisper (Intel/Universal)"

    /// Whether this provider is supported on the current system.
    /// SwiftWhisper (whisper.cpp) works on both Intel and Apple Silicon.
    var isAvailable: Bool {
        true
    }

    private var whisper: Whisper?
    private(set) var isReady: Bool = false
    private var loadedModelName: String?

    /// Model filename to use - reads from the unified SpeechModel setting
    /// Models: tiny (~75MB), base (~142MB), small (~466MB), medium (~1.5GB), large (~2.9GB)
    private var modelName: String {
        SettingsStore.shared.selectedSpeechModel.whisperModelFile ?? "ggml-base.bin"
    }

    private var modelURL: URL {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            preconditionFailure("Could not find caches directory")
        }
        return cacheDir.appendingPathComponent("WhisperModels").appendingPathComponent(self.modelName)
    }

    private var modelDirectory: URL {
        self.modelURL.deletingLastPathComponent()
    }

    func prepare(progressHandler: ((Double) -> Void)? = nil) async throws {
        // Detect model change: if a different model is now selected, force reload
        let currentModelName = self.modelName
        if self.isReady, self.loadedModelName != currentModelName {
            DebugLogger.shared.info("WhisperProvider: Model changed from \(self.loadedModelName ?? "nil") to \(currentModelName), forcing reload", source: "WhisperProvider")
            self.isReady = false
            self.whisper = nil
            self.loadedModelName = nil
        }

        guard self.isReady == false else { return }

        DebugLogger.shared.info("WhisperProvider: Starting model preparation", source: "WhisperProvider")

        // Ensure model directory exists
        try FileManager.default.createDirectory(at: self.modelDirectory, withIntermediateDirectories: true)

        // Download model if not present
        if !FileManager.default.fileExists(atPath: self.modelURL.path) {
            DebugLogger.shared.info("WhisperProvider: Downloading Whisper model...", source: "WhisperProvider")
            try await self.downloadModel(progressHandler: progressHandler)
        }

        // Load the model
        DebugLogger.shared.info("WhisperProvider: Loading Whisper model...", source: "WhisperProvider")
        self.whisper = Whisper(fromFileURL: self.modelURL)

        self.loadedModelName = currentModelName
        self.isReady = true
        DebugLogger.shared.info("WhisperProvider: Model ready (\(currentModelName))", source: "WhisperProvider")
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard let whisper = whisper else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model not loaded"]
            )
        }

        // SwiftWhisper expects 16kHz PCM audio frames (which is what we receive)
        let segments = try await whisper.transcribe(audioFrames: samples)

        // Combine all segments into one string
        let fullText = segments.map { $0.text }.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // SwiftWhisper doesn't provide confidence, so we use 1.0
        return ASRTranscriptionResult(text: fullText, confidence: 1.0)
    }

    func modelsExistOnDisk() -> Bool {
        return FileManager.default.fileExists(atPath: self.modelURL.path)
    }

    func clearCache() async throws {
        if FileManager.default.fileExists(atPath: self.modelDirectory.path) {
            try FileManager.default.removeItem(at: self.modelDirectory)
        }
        self.isReady = false
        self.whisper = nil
        self.loadedModelName = nil
    }

    // MARK: - Model Download

    private func downloadModel(progressHandler: ((Double) -> Void)?) async throws {
        // Whisper models are hosted on Hugging Face
        let modelURLString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelName)"

        guard let url = URL(string: modelURLString) else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid model URL"]
            )
        }

        DebugLogger.shared.info("WhisperProvider: Downloading from \(modelURLString)", source: "WhisperProvider")

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "WhisperProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid server response"]
                )
            }

            guard httpResponse.statusCode == 200 else {
                throw NSError(
                    domain: "WhisperProvider",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to download model (HTTP \(httpResponse.statusCode))"]
                )
            }

            // Move to final location
            if FileManager.default.fileExists(atPath: self.modelURL.path) {
                try FileManager.default.removeItem(at: self.modelURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: self.modelURL)

            DebugLogger.shared.info("WhisperProvider: Model downloaded successfully", source: "WhisperProvider")
        } catch let error as NSError {
            // Provide user-friendly error messages
            if error.domain == NSURLErrorDomain {
                let message: String
                switch error.code {
                case NSURLErrorNotConnectedToInternet:
                    message = "No internet connection. Please connect to the internet to download the Whisper model."
                case NSURLErrorTimedOut:
                    message = "Download timed out. Please check your internet connection and try again."
                case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                    message = "Cannot reach download server. Please check your internet connection."
                default:
                    message = "Network error: \(error.localizedDescription)"
                }
                throw NSError(
                    domain: "WhisperProvider",
                    code: error.code,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
            throw error
        }
    }
}
