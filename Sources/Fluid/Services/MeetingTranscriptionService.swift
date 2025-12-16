import Foundation
import AVFoundation
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
    let timestamp: Date = Date()
    
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
            case .modelLoadFailed(let msg):
                return "Failed to load ASR models: \(msg)"
            case .audioConversionFailed(let msg):
                return "Failed to convert audio: \(msg)"
            case .transcriptionFailed(let msg):
                return "Transcription failed: \(msg)"
            case .fileNotSupported(let msg):
                return "File format not supported: \(msg)"
            }
        }
    }
    
    /// Initialize the ASR models (reuses models from ASRService - no duplicate download!)
    func initializeModels() async throws {
        guard !asrService.isAsrReady else { return }
        
        currentStatus = "Preparing ASR models..."
        progress = 0.1
        
        do {
            try await asrService.ensureAsrReady()
            
            currentStatus = "Models ready"
            progress = 0.0
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
    }
    
    /// Transcribe an audio or video file
    /// - Parameters:
    ///   - fileURL: URL to the audio/video file
    func transcribeFile(_ fileURL: URL) async throws -> TranscriptionResult {
        isTranscribing = true
        error = nil
        progress = 0.0
        let startTime = Date()
        
        defer {
            isTranscribing = false
            progress = 0.0
        }
        
        do {
            // Initialize models if not already done (reuses ASRService models)
            if !asrService.isAsrReady {
                try await initializeModels()
            }
            
            #if arch(arm64)
            guard let asrManager = asrService.asrManager else {
                throw TranscriptionError.modelLoadFailed("ASR Manager not initialized")
            }
            
            // Convert audio to required format (16kHz mono Float32)
            currentStatus = "Converting audio..."
            progress = 0.3
            
            let converter = AudioConverter()
            let samples: [Float]
            
            // Check file extension
            let fileExtension = fileURL.pathExtension.lowercased()
            let supportedFormats = ["wav", "mp3", "m4a", "aac", "flac", "aiff", "caf", "mp4", "mov"]
            
            guard supportedFormats.contains(fileExtension) else {
                throw TranscriptionError.fileNotSupported("Format .\(fileExtension) not supported. Supported: \(supportedFormats.joined(separator: ", "))")
            }
            
            do {
                samples = try converter.resampleAudioFile(fileURL)
            } catch {
                throw TranscriptionError.audioConversionFailed(error.localizedDescription)
            }
            
            let duration = Double(samples.count) / 16000.0 // 16kHz sample rate
            
            // Transcribe
            currentStatus = "Transcribing audio (\(Int(duration))s)..."
            progress = 0.6
            
            let transcriptionResult = try await asrManager.transcribe(samples, source: .system)
            
            currentStatus = "Complete!"
            progress = 1.0
            
            let processingTime = Date().timeIntervalSince(startTime)
            
            let result = TranscriptionResult(
                text: transcriptionResult.text,
                confidence: transcriptionResult.confidence,
                duration: duration,
                processingTime: processingTime,
                fileName: fileURL.lastPathComponent
            )
            
            self.result = result
            return result
            #else
            throw TranscriptionError.transcriptionFailed("File transcription is only supported on Apple Silicon Macs at this time.")
            #endif
            
        } catch let error as TranscriptionError {
            self.error = error.localizedDescription
            throw error
        } catch {
            let wrappedError = TranscriptionError.transcriptionFailed(error.localizedDescription)
            self.error = wrappedError.localizedDescription
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
        result = nil
        error = nil
        currentStatus = ""
        progress = 0.0
    }
}
