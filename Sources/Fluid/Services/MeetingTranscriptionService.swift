import AVFoundation
import Combine
import CoreMedia
import Foundation

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

            // Get the current transcription provider (works for both Parakeet and Whisper)
            let provider = self.asrService.fileTranscriptionProvider
            guard provider.isReady else {
                throw TranscriptionError.modelLoadFailed("Transcription provider not ready")
            }

            // Check file extension
            let fileExtension = fileURL.pathExtension.lowercased()
            let supportedFormats = ["wav", "mp3", "m4a", "aac", "flac", "aiff", "caf", "mp4", "mov"]

            guard supportedFormats.contains(fileExtension) else {
                throw TranscriptionError
                    .fileNotSupported("Format .\(fileExtension) not supported. Supported: \(supportedFormats.joined(separator: ", "))")
            }

            // Get audio duration for progress display
            self.currentStatus = "Analyzing audio file..."
            self.progress = 0.2

            let asset = AVAsset(url: fileURL)
            let duration: Double
            do {
                let cmDuration = try await asset.load(.duration)
                duration = CMTimeGetSeconds(cmDuration)
            } catch {
                // Fall back to 0 if we can't determine duration
                duration = 0
                DebugLogger.shared.warning("Could not determine audio duration: \(error.localizedDescription)", source: "MeetingTranscriptionService")
            }

            // Transcribe using chunked processing for long files
            // This reads audio in ~20 minute segments to avoid memory overflow on 3+ hour files
            let chunkDurationSeconds: Double = 20 * 60 // 20 minutes per chunk (well under 24min model limit)
            let sampleRate: Double = 16_000 // Target sample rate for ASR
            let samplesPerChunk = Int(chunkDurationSeconds * sampleRate)

            var allTranscriptions: [String] = []
            var totalConfidence: Float = 0
            var chunkCount = 0

            // Open audio file for reading
            let audioFile: AVAudioFile
            do {
                audioFile = try AVAudioFile(forReading: fileURL)
            } catch {
                throw TranscriptionError.audioConversionFailed("Could not open audio file: \(error.localizedDescription)")
            }

            let fileFormat = audioFile.processingFormat
            let totalFrames = AVAudioFrameCount(audioFile.length)
            let fileSampleRate = fileFormat.sampleRate
            guard fileSampleRate > 0 else {
                throw TranscriptionError.audioConversionFailed("Invalid audio file: sample rate is 0")
            }
            let resampleRatio = sampleRate / fileSampleRate

            // Calculate chunk size in source file frames
            let sourceFramesPerChunk = AVAudioFrameCount(Double(samplesPerChunk) / resampleRatio)
            var currentFrame: AVAudioFramePosition = 0

            self.currentStatus = duration > 0 ? "Transcribing audio (\(Int(duration))s)..." : "Transcribing audio..."

            while currentFrame < audioFile.length {
                let remainingFrames = AVAudioFrameCount(audioFile.length - currentFrame)
                let framesToRead = min(sourceFramesPerChunk, remainingFrames)

                // Read chunk from file
                guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else {
                    throw TranscriptionError.audioConversionFailed("Could not create audio buffer")
                }

                audioFile.framePosition = currentFrame
                do {
                    try audioFile.read(into: buffer, frameCount: framesToRead)
                } catch {
                    throw TranscriptionError.audioConversionFailed("Could not read audio chunk: \(error.localizedDescription)")
                }

                // Convert buffer to 16kHz mono Float32 samples
                let samples: [Float]
                do {
                    samples = try self.resampleBuffer(buffer, targetSampleRate: sampleRate)
                } catch {
                    throw TranscriptionError.audioConversionFailed("Could not resample audio: \(error.localizedDescription)")
                }

                // Skip if chunk is too short (< 1 second)
                guard samples.count >= Int(sampleRate) else {
                    currentFrame += AVAudioFramePosition(framesToRead)
                    continue
                }

                // Transcribe this chunk using the provider (works for both Parakeet and Whisper)
                let chunkResult = try await provider.transcribe(samples)

                if !chunkResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allTranscriptions.append(chunkResult.text)
                    totalConfidence += chunkResult.confidence
                    chunkCount += 1
                }

                currentFrame += AVAudioFramePosition(framesToRead)

                // Update progress
                let progressPercent = Double(currentFrame) / Double(audioFile.length)
                self.progress = 0.3 + (progressPercent * 0.6) // Progress from 30% to 90%
                self.currentStatus = "Transcribing... \(Int(progressPercent * 100))%"
            }

            if allTranscriptions.isEmpty {
                DebugLogger.shared.warning(
                    "No audio chunks were long enough to transcribe (minimum 1 second required)",
                    source: "MeetingTranscriptionService"
                )
            }

            // Combine all chunk transcriptions
            let finalText = allTranscriptions.joined(separator: " ")
            let avgConfidence = chunkCount > 0 ? totalConfidence / Float(chunkCount) : 0

            let transcriptionResult = (text: finalText, confidence: avgConfidence)

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

    // MARK: - Audio Resampling Helpers

    /// Resample an audio buffer to 16kHz mono Float32 samples
    /// - Parameters:
    ///   - buffer: Source audio buffer
    ///   - targetSampleRate: Target sample rate (default 16000 Hz)
    /// - Returns: Array of Float32 samples at target sample rate
    private nonisolated func resampleBuffer(_ buffer: AVAudioPCMBuffer, targetSampleRate: Double = 16_000) throws -> [Float] {
        let sourceFormat = buffer.format
        let sourceSampleRate = sourceFormat.sampleRate
        let sourceChannels = sourceFormat.channelCount

        // Create target format (16kHz mono Float32)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "MeetingTranscriptionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create target audio format"]
            )
        }

        // If already in correct format, just extract samples
        // Must also verify the format is Float32 - if source is Float64, floatChannelData returns nil
        if sourceSampleRate == targetSampleRate,
           sourceChannels == 1,
           sourceFormat.commonFormat == .pcmFormatFloat32
        {
            guard let channelData = buffer.floatChannelData else {
                throw NSError(
                    domain: "MeetingTranscriptionService",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not access audio channel data"]
                )
            }
            let frameLength = Int(buffer.frameLength)
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
        }

        // Create converter
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw NSError(
                domain: "MeetingTranscriptionService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Could not create audio converter"]
            )
        }

        // Calculate output buffer size
        let ratio = targetSampleRate / sourceSampleRate
        let estimatedFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrameCount + 1024) else {
            throw NSError(
                domain: "MeetingTranscriptionService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Could not create output buffer"]
            )
        }

        // Convert
        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            throw error
        }

        // Extract samples
        guard let channelData = outputBuffer.floatChannelData else {
            throw NSError(
                domain: "MeetingTranscriptionService",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Could not access converted audio data"]
            )
        }

        let frameLength = Int(outputBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
    }
}
