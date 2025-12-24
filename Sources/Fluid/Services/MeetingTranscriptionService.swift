import AVFoundation
import Foundation
#if arch(arm64)
import FluidAudio
#endif
import Combine

/// Result of a transcription operation
struct TranscriptionResult: Identifiable, Sendable, Codable {
    let id = UUID()
    let text: String
    let confidence: Float
    let duration: TimeInterval
    let processingTime: TimeInterval
    let fileName: String
    let timestamp: Date = .init()

    enum CodingKeys: String, CodingKey {
        case text, confidence, duration, processingTime, fileName, timestamp
    }
}

/// Service for transcribing complete audio/video files with optional speaker diarization
/// NOTE: This service shares the ASR models with ASRService to avoid duplicate memory usage
@MainActor
final class MeetingTranscriptionService: ObservableObject {
    @Published var isTranscribing: Bool = false
    @Published var progress: Double = 0.0
    @Published var currentStatus: String = ""
    @Published var error: String?
    @Published var result: TranscriptionResult?

    // Share the ASR service instance to avoid loading models twice
    private let asrService: ASRService

    init(asrService: ASRService) {
        self.asrService = asrService
    }

    enum TranscriptionError: LocalizedError {
        case modelLoadFailed(String)
        case audioConversionFailed(String)
        case transcriptionFailed(String)
        case fileNotSupported(String)

        var errorDescription: String? {
            switch self {
            case let .modelLoadFailed(msg):
                return "Failed to load ASR models: \(msg)"
            case let .audioConversionFailed(msg):
                return "Failed to convert audio: \(msg)"
            case let .transcriptionFailed(msg):
                return "Transcription failed: \(msg)"
            case let .fileNotSupported(msg):
                return "File format not supported: \(msg)"
            }
        }
    }

    private func errorCategory(for error: Error) -> String {
        guard let transcriptionError = error as? TranscriptionError else {
            return "unknownError"
        }
        return self.errorCategory(for: transcriptionError)
    }

    private func errorCategory(for error: TranscriptionError) -> String {
        switch error {
        case .modelLoadFailed:
            return "modelLoadFailed"
        case .audioConversionFailed:
            return "audioConversionFailed"
        case .transcriptionFailed:
            return "transcriptionFailed"
        case .fileNotSupported:
            return "fileNotSupported"
        }
    }

    /// Initialize the ASR models (reuses models from ASRService - no duplicate download!)
    func initializeModels() async throws {
        guard !self.asrService.isAsrReady else { return }

        self.currentStatus = "Preparing ASR models..."
        self.progress = 0.1

        do {
            try await self.asrService.ensureAsrReady()

            self.currentStatus = "Models ready"
            self.progress = 0.0
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Transcribe an audio or video file
    /// - Parameters:
    ///   - fileURL: URL to the audio/video file
    func transcribeFile(_ fileURL: URL) async throws -> TranscriptionResult {
        self.isTranscribing = true
        error = nil
        self.progress = 0.0
        let startTime = Date()

        defer {
            isTranscribing = false
            progress = 0.0
        }

        do {
            // Initialize models if not already done (reuses ASRService models)
            if !self.asrService.isAsrReady {
                try await self.initializeModels()
            }

            #if arch(arm64)
            guard let asrManager = asrService.asrManager else {
                throw TranscriptionError.modelLoadFailed("ASR Manager not initialized")
            }

            // Convert audio to required format (16kHz mono Float32)
            self.currentStatus = "Converting audio..."
            self.progress = 0.3

            let converter = AudioConverter()
            let samples: [Float]

            // Check file extension
            let fileExtension = fileURL.pathExtension.lowercased()
            let supportedFormats = ["wav", "mp3", "m4a", "aac", "flac", "aiff", "caf", "mp4", "mov"]

            guard supportedFormats.contains(fileExtension) else {
                throw TranscriptionError
                    .fileNotSupported("Format .\(fileExtension) not supported. Supported: \(supportedFormats.joined(separator: ", "))")
            }

            do {
                samples = try converter.resampleAudioFile(fileURL)
            } catch {
                throw TranscriptionError.audioConversionFailed(error.localizedDescription)
            }

            let duration = Double(samples.count) / 16_000.0 // 16kHz sample rate

            // Transcribe
            self.currentStatus = "Transcribing audio (\(Int(duration))s)..."
            self.progress = 0.6

            let transcriptionResult = try await asrManager.transcribe(samples, source: .system)

            self.currentStatus = "Complete!"
            self.progress = 1.0

            let processingTime = Date().timeIntervalSince(startTime)

            let result = TranscriptionResult(
                text: transcriptionResult.text,
                confidence: transcriptionResult.confidence,
                duration: duration,
                processingTime: processingTime,
                fileName: fileURL.lastPathComponent
            )

            AnalyticsService.shared.capture(
                .meetingTranscriptionCompleted,
                properties: [
                    "success": true,
                    "file_type": fileURL.pathExtension.lowercased(),
                    "audio_duration_bucket": AnalyticsBuckets.bucketSeconds(duration),
                    "processing_time_bucket": AnalyticsBuckets.bucketSeconds(processingTime),
                ]
            )

            self.result = result
            return result
            #else
            throw TranscriptionError
                .transcriptionFailed("File transcription is only supported on Apple Silicon Macs at this time.")
            #endif

        } catch let error as TranscriptionError {
            self.error = error.localizedDescription
            AnalyticsService.shared.capture(
                .meetingTranscriptionCompleted,
                properties: [
                    "success": false,
                    "file_type": fileURL.pathExtension.lowercased(),
                    "category": errorCategory(for: error),
                ]
            )
            throw error
        } catch {
            let wrappedError = TranscriptionError.transcriptionFailed(error.localizedDescription)
            self.error = wrappedError.localizedDescription
            AnalyticsService.shared.capture(
                .meetingTranscriptionCompleted,
                properties: [
                    "success": false,
                    "file_type": fileURL.pathExtension.lowercased(),
                    "category": self.errorCategory(for: wrappedError),
                ]
            )
            throw wrappedError
        }
    }

    /// Export transcription result to text file
    nonisolated func exportToText(_ result: TranscriptionResult, to destinationURL: URL) throws {
        let content = """
        Transcription: \(result.fileName)
        Date: \(result.timestamp.formatted())
        Duration: \(String(format: "%.1f", result.duration))s
        Processing Time: \(String(format: "%.1f", result.processingTime))s
        Confidence: \(String(format: "%.1f%%", result.confidence * 100))

        ---

        \(result.text)
        """

        try content.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    /// Export transcription result to JSON
    nonisolated func exportToJSON(_ result: TranscriptionResult, to destinationURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let jsonData = try encoder.encode(result)
        try jsonData.write(to: destinationURL)
    }

    /// Reset the service state
    func reset() {
        self.result = nil
        self.error = nil
        self.currentStatus = ""
        self.progress = 0.0
    }
}
