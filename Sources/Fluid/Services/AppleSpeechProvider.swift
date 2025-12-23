import AVFoundation
import Foundation
import Speech

// MARK: - Apple Speech Provider

/// A TranscriptionProvider that uses Apple's native SFSpeechRecognizer.
/// This runs strictly on-device, requires no downloads, and has 0 memory footprint when idle.
final class AppleSpeechProvider: TranscriptionProvider {
    var name: String { "Apple Speech (Legacy)" }

    /// Always available on macOS 10.15+ (Catalina and later)
    var isAvailable: Bool {
        SFSpeechRecognizer.authorizationStatus() != .restricted
    }

    /// Apple Speech is "always ready" (no downloads needed),
    /// but we track if we've checked permissions.
    private(set) var isReady: Bool = false

    /// The recognizer instance. We intentionally re-create it if the locale changes,
    /// but for now we default to the system locale.
    private var recognizer: SFSpeechRecognizer?

    init() {
        // Initialize with user's current locale
        self.recognizer = SFSpeechRecognizer(locale: Locale.current)
    }

    // MARK: - Lifecycle

    func prepare(progressHandler: ((Double) -> Void)?) async throws {
        // 1. Request Authorization
        let status = await self.requestAuthorization()

        switch status {
        case .authorized:
            self.isReady = true
            DebugLogger.shared.info("AppleSpeechProvider authorized and ready", source: "AppleSpeechProvider")
        case .denied:
            throw NSError(domain: "AppleSpeechProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission denied"])
        case .restricted:
            throw NSError(domain: "AppleSpeechProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is restricted on this device"])
        case .notDetermined:
            // Should not happen after requestAuthorization returns, but handled for safety
            self.isReady = false
        @unknown default:
            self.isReady = false
        }
    }

    func clearCache() async throws {
        // No cache to clear for system speech
    }

    func modelsExistOnDisk() -> Bool {
        return true // System models are always "on disk"
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard self.isAvailable else {
            throw NSError(domain: "AppleSpeechProvider", code: 3, userInfo: [NSLocalizedDescriptionKey: "Speech recognition unavailable"])
        }

        // 1. Convert [Float] samples to AVAudioPCMBuffer
        guard let buffer = self.createPCMBuffer(from: samples) else {
            throw NSError(domain: "AppleSpeechProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        // 2. Ensure recognizer exists
        if self.recognizer == nil {
            self.recognizer = SFSpeechRecognizer(locale: Locale.current)
        }
        guard let recognizer = self.recognizer else {
            throw NSError(domain: "AppleSpeechProvider", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize SFSpeechRecognizer"])
        }

        if !recognizer.isAvailable {
            throw NSError(domain: "AppleSpeechProvider", code: 6, userInfo: [NSLocalizedDescriptionKey: "SFSpeechRecognizer is currently unavailable"])
        }

        // 3. Create Request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false // We want the final result for this chunk
        request.requiresOnDeviceRecognition = true // Enforce strict privacy/offline
        request.append(buffer)
        request.endAudio() // Signal that this buffer is the complete utterance for this request

        // 4. Execute Recognition
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false

            recognizer.recognitionTask(with: request) { result, error in
                // Ensure we only resume once
                guard !hasResumed else { return }

                if let error = error {
                    hasResumed = true
                    // Ignore "No speech detected" errors often returned for silent chunks
                    DebugLogger.shared.warning("Apple transcribed error: \(error.localizedDescription)", source: "AppleSpeechProvider")
                    continuation.resume(returning: ASRTranscriptionResult(text: "", confidence: 0.0))
                    return
                }

                if let result = result, result.isFinal {
                    hasResumed = true
                    let transcription = result.bestTranscription.formattedString
                    DebugLogger.shared.debug("AppleSpeechProvider: Got final result: '\(transcription)'", source: "AppleSpeechProvider")
                    continuation.resume(returning: ASRTranscriptionResult(text: transcription, confidence: 1.0))
                }
                // Partial results ignored as we requested final only
            }
        }
    }

    // MARK: - Helpers

    /// Converts raw [Float] samples (16kHz mono) to AVAudioPCMBuffer
    private func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        // Define format: 16kHz, Mono, Float32 (standard for ML/ASR)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Efficient copy
        guard let channelData = buffer.floatChannelData else { return nil }

        // Use withUnsafeBufferPointer for safe memory access
        samples.withUnsafeBufferPointer { samplePtr in
            guard let baseAddress = samplePtr.baseAddress else { return }
            // Copy memory from array to AVAudioPCMBuffer
            // channelData[0] is UnsafeMutablePointer<Float>
            channelData[0].update(from: baseAddress, count: samples.count)
        }

        return buffer
    }

    /// Structured concurrency wrapper for authorization
    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
