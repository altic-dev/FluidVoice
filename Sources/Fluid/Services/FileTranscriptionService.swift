import AVFoundation
import Combine
import CoreMedia
import Foundation
import UniformTypeIdentifiers

/// One speaker-attributed portion of a file transcription.
struct SpeakerTranscriptSegment: Identifiable, Sendable, Codable, Equatable {
    let speaker: String
    let startSeconds: Double
    let endSeconds: Double
    let text: String

    var id: String {
        "\(self.speaker)-\(self.startSeconds)"
    }

    var timestampText: String {
        let total = Int(self.startSeconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var plainText: String {
        "[\(self.timestampText)] \(self.speaker): \(self.text)"
    }

    enum CodingKeys: String, CodingKey {
        case speaker, startSeconds, endSeconds, text
    }
}

/// Result of a transcription operation
struct TranscriptionResult: Identifiable, Sendable, Codable {
    let id: UUID
    let text: String
    let confidence: Float
    let duration: TimeInterval
    let processingTime: TimeInterval
    let fileName: String
    let timestamp: Date
    /// Speaker-attributed segments when diarization was enabled; empty otherwise.
    let speakerSegments: [SpeakerTranscriptSegment]

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        duration: TimeInterval,
        processingTime: TimeInterval,
        fileName: String,
        timestamp: Date = Date(),
        speakerSegments: [SpeakerTranscriptSegment] = []
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.duration = duration
        self.processingTime = processingTime
        self.fileName = fileName
        self.timestamp = timestamp
        self.speakerSegments = speakerSegments
    }

    enum CodingKeys: String, CodingKey {
        case text, confidence, duration, processingTime, fileName, timestamp, speakerSegments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.text = try c.decode(String.self, forKey: .text)
        self.confidence = try c.decode(Float.self, forKey: .confidence)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.processingTime = try c.decode(TimeInterval.self, forKey: .processingTime)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.speakerSegments = try c.decodeIfPresent([SpeakerTranscriptSegment].self, forKey: .speakerSegments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.text, forKey: .text)
        try c.encode(self.confidence, forKey: .confidence)
        try c.encode(self.duration, forKey: .duration)
        try c.encode(self.processingTime, forKey: .processingTime)
        try c.encode(self.fileName, forKey: .fileName)
        try c.encode(self.timestamp, forKey: .timestamp)
        if !self.speakerSegments.isEmpty {
            try c.encode(self.speakerSegments, forKey: .speakerSegments)
        }
    }
}

/// Service for transcribing complete audio/video files with optional speaker diarization
/// NOTE: This service shares the ASR models with ASRService to avoid duplicate memory usage
@MainActor
final class FileTranscriptionService: ObservableObject {
    @Published var isTranscribing: Bool = false
    @Published var progress: Double = 0.0
    @Published var currentStatus: String = ""
    @Published var error: String?
    @Published var result: TranscriptionResult?
    @Published var fallbackNotice: String?
    @Published private(set) var currentFileURL: URL?

    // MARK: - Supported Formats

    /// File extensions the OS can actually decode, queried dynamically from AVFoundation.
    /// Filtered to audio/video types only — excludes subtitles, playlists, etc.
    static let supportedFileExtensions: Set<String> = {
        let avTypes = AVURLAsset.audiovisualTypes()
        let extensions = avTypes.compactMap { fileType -> String? in
            guard let utType = UTType(fileType.rawValue) else { return nil }
            guard utType.conforms(to: .audio) || utType.conforms(to: .movie) else { return nil }
            return utType.preferredFilenameExtension
        }
        return Set(extensions)
    }()

    /// Content types accepted by the file picker — broad categories so the OS filters naturally.
    static let allowedContentTypes: [UTType] = [.audio, .movie]

    /// User-facing description of supported formats (curated for readability).
    static let supportedFormatsDescription = "Supported: WAV, MP3, M4A, OGG, MP4, MOV, and more"

    /// Error copy shown when a dropped file is not accepted.
    static let dropErrorCopy = "Accepted file types: WAV, MP3, M4A, OGG, MP4, MOV, and more."

    /// Share the ASR service instance to avoid loading models twice
    private let asrService: ASRService

    init(asrService: ASRService) {
        self.asrService = asrService
    }

    enum TranscriptionError: LocalizedError {
        case activityInProgress(String)
        case modelLoadFailed(String)
        case audioConversionFailed(String)
        case transcriptionFailed(String)
        case fileNotSupported(String)

        var errorDescription: String? {
            switch self {
            case let .activityInProgress(msg):
                return msg
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
        case .activityInProgress:
            return "activityInProgress"
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
        guard !self.isTranscribing else {
            throw TranscriptionError.activityInProgress("This file is already being transcribed.")
        }

        let activityLease: ASRActivityLease
        do {
            activityLease = try self.asrService.acquireExclusiveActivity(.fileTranscription)
        } catch {
            let wrappedError = TranscriptionError.activityInProgress(error.localizedDescription)
            self.error = wrappedError.localizedDescription
            throw wrappedError
        }

        self.isTranscribing = true
        self.currentFileURL = fileURL
        error = nil
        self.fallbackNotice = nil
        self.progress = 0.0
        let startTime = Date()

        defer {
            self.isTranscribing = false
            self.progress = 0.0
            self.asrService.releaseExclusiveActivity(activityLease)
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

            guard Self.supportedFileExtensions.contains(fileExtension) else {
                throw TranscriptionError
                    .fileNotSupported("Format .\(fileExtension) not supported. \(Self.supportedFormatsDescription)")
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
                DebugLogger.shared.warning("Could not determine audio duration: \(error.localizedDescription)", source: "FileTranscriptionService")
            }

            let isVideoContainer = UTType(filenameExtension: fileExtension)
                .map { $0.conforms(to: .movie) } ?? false

            // Speaker-labeled path: diarize first, then transcribe each speaker turn.
            // Any diarization failure falls back to the standard paths below.
            if SettingsStore.shared.fileTranscriptionSpeakerLabelsEnabled,
               SpeakerDiarizationService.isSupported,
               !isVideoContainer
            {
                if let labeledResult = await self.transcribeFileWithSpeakerLabels(
                    fileURL,
                    provider: provider,
                    duration: duration,
                    startTime: startTime
                ) {
                    return labeledResult
                }
                DebugLogger.shared.warning(
                    "Speaker labeling unavailable for this file; falling back to standard transcription",
                    source: "FileTranscriptionService"
                )
                self.fallbackNotice = "Speaker labeling was unavailable for this file. The transcript was completed without speaker labels."
                self.progress = 0.3
            } else if SettingsStore.shared.fileTranscriptionSpeakerLabelsEnabled, isVideoContainer {
                DebugLogger.shared.info(
                    "Speaker labeling skipped for video container; using standard transcription",
                    source: "FileTranscriptionService"
                )
            }

            if provider.prefersNativeFileTranscription && !isVideoContainer {
                self.currentStatus = duration > 0 ? "Transcribing audio (\(Int(duration))s)..." : "Transcribing audio..."
                self.progress = 0.3

                DebugLogger.shared.info(
                    "FileTranscriptionService: using native file transcription path for provider=\(provider.name)",
                    source: "FileTranscriptionService"
                )

                let nativeResult = try await provider.transcribeFile(at: fileURL)
                let processingTime = Date().timeIntervalSince(startTime)
                let result = TranscriptionResult(
                    text: nativeResult.text,
                    confidence: nativeResult.confidence,
                    duration: duration,
                    processingTime: processingTime,
                    fileName: fileURL.lastPathComponent
                )

                self.currentStatus = "Complete!"
                self.progress = 1.0

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
                FileTranscriptionHistoryStore.shared.addEntry(result)
                return result
            }

            if provider.prefersNativeFileTranscription && isVideoContainer {
                DebugLogger.shared.info(
                    "FileTranscriptionService: using buffered transcription path for video container [provider=\(provider.name), extension=\(fileExtension)]",
                    source: "FileTranscriptionService"
                )
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
                    samples = try AudioBufferConverter.monoSamples(
                        from: buffer,
                        targetSampleRate: sampleRate
                    )
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
                    source: "FileTranscriptionService"
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
            FileTranscriptionHistoryStore.shared.addEntry(result)
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
        guard !self.isTranscribing else { return }
        self.result = nil
        self.error = nil
        self.fallbackNotice = nil
        self.currentFileURL = nil
        self.currentStatus = ""
        self.progress = 0.0
    }

    // MARK: - Speaker-Labeled Transcription

    /// Diarize-first pipeline: identify speaker turns, then transcribe the audio slice for
    /// each turn with the active provider. Returns nil when diarization fails or yields
    /// nothing usable, so the caller can fall back to the standard transcription paths.
    private func transcribeFileWithSpeakerLabels(
        _ fileURL: URL,
        provider: TranscriptionProvider,
        duration: Double,
        startTime: Date
    ) async -> TranscriptionResult? {
        self.currentStatus = "Identifying speakers..."
        self.progress = 0.25

        let expectedSpeakers = SettingsStore.shared.fileTranscriptionExpectedSpeakerCount
        let diarizer = SpeakerDiarizationService(
            expectedSpeakers: expectedSpeakers > 0 ? expectedSpeakers : nil
        )

        let turns: [SpeakerDiarizationService.SpeakerTurn]
        do {
            turns = try await diarizer.diarize(fileURL: fileURL)
        } catch {
            DebugLogger.shared.warning(
                "Diarization failed: \(error.localizedDescription)",
                source: "FileTranscriptionService"
            )
            return nil
        }

        guard !turns.isEmpty else {
            DebugLogger.shared.info(
                "Diarization found no speaker turns",
                source: "FileTranscriptionService"
            )
            return nil
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            DebugLogger.shared.warning(
                "Could not open audio for speaker slicing: \(error.localizedDescription)",
                source: "FileTranscriptionService"
            )
            return nil
        }

        var segments: [SpeakerTranscriptSegment] = []
        var totalConfidence: Float = 0

        for (index, turn) in turns.enumerated() {
            self.currentStatus = "Transcribing speaker segments (\(index + 1)/\(turns.count))..."
            self.progress = 0.3 + (Double(index) / Double(turns.count)) * 0.65

            let transcribed: (text: String, confidence: Float)?
            do {
                transcribed = try await self.transcribeSpeakerTurn(turn, from: audioFile, provider: provider)
            } catch {
                // A genuine audio-read or ASR failure would drop this turn's time range,
                // leaving a silent gap in the labeled transcript. Abandon the labeled path
                // so the caller re-transcribes the whole file — baseline behavior is never
                // at risk (a complete unlabeled transcript beats a labeled one with holes).
                DebugLogger.shared.warning(
                    "Speaker labeling aborted at segment \(index + 1)/\(turns.count) (\(String(format: "%.1f", turn.startSeconds))s): \(error.localizedDescription); falling back to standard transcription",
                    source: "FileTranscriptionService"
                )
                return nil
            }

            // An empty result would omit this turn's time range. Fall back to the complete
            // full-file transcript rather than persist a labeled transcript with a silent gap.
            guard let transcribed else {
                DebugLogger.shared.warning(
                    "Speaker segment \(index + 1)/\(turns.count) produced no text; falling back to standard transcription",
                    source: "FileTranscriptionService"
                )
                return nil
            }

            segments.append(SpeakerTranscriptSegment(
                speaker: turn.speakerLabel,
                startSeconds: turn.startSeconds,
                endSeconds: turn.endSeconds,
                text: transcribed.text
            ))
            totalConfidence += transcribed.confidence
        }

        guard !segments.isEmpty else {
            DebugLogger.shared.warning(
                "No speaker segments produced text",
                source: "FileTranscriptionService"
            )
            return nil
        }

        let labeledText = segments
            .map(\.plainText)
            .joined(separator: "\n\n")
        let avgConfidence = totalConfidence / Float(segments.count)
        let processingTime = Date().timeIntervalSince(startTime)

        let result = TranscriptionResult(
            text: labeledText,
            confidence: avgConfidence,
            duration: duration,
            processingTime: processingTime,
            fileName: fileURL.lastPathComponent,
            speakerSegments: segments
        )

        self.currentStatus = "Complete!"
        self.progress = 1.0

        AnalyticsService.shared.capture(
            .meetingTranscriptionCompleted,
            properties: [
                "success": true,
                "file_type": fileURL.pathExtension.lowercased(),
                "audio_duration_bucket": AnalyticsBuckets.bucketSeconds(duration),
                "processing_time_bucket": AnalyticsBuckets.bucketSeconds(processingTime),
                "speaker_labels": true,
                "speaker_count": Set(segments.map(\.speaker)).count,
            ]
        )

        self.result = result
        FileTranscriptionHistoryStore.shared.addEntry(result)
        return result
    }

    /// Transcribe a single speaker turn, splitting overlong turns into bounded chunks.
    /// Returns the concatenated text and mean confidence, or nil
    /// when the turn holds no usable audio (too short or silent). Throws on a genuine audio-read
    /// or ASR failure so the caller can fall back to full-file transcription rather than emit a
    /// transcript with silent gaps.
    private func transcribeSpeakerTurn(
        _ turn: SpeakerDiarizationService.SpeakerTurn,
        from audioFile: AVAudioFile,
        provider: TranscriptionProvider
    ) async throws -> (text: String, confidence: Float)? {
        // Bound memory for unusually long single-speaker stretches. Providers remain free to
        // apply their own model-specific, energy-aware chunking within each request.
        let maxChunkSeconds: Double = 20 * 60

        var ranges: [(start: Double, end: Double)] = []
        if turn.endSeconds - turn.startSeconds > maxChunkSeconds {
            var chunkStart = turn.startSeconds
            while chunkStart < turn.endSeconds {
                let chunkEnd = min(chunkStart + maxChunkSeconds, turn.endSeconds)
                ranges.append((chunkStart, chunkEnd))
                chunkStart = chunkEnd
            }
        } else {
            ranges.append((turn.startSeconds, turn.endSeconds))
        }

        var pieces: [String] = []
        var confidenceSum: Float = 0
        var transcribedChunks = 0

        for range in ranges {
            let samples = try self.readSamples(
                from: audioFile,
                startSeconds: range.start,
                endSeconds: range.end,
                minimumDurationSeconds: 1.1
            )
            // Mirror the standard path's 1-second ASR minimum.
            guard samples.count >= 16_000 else { return nil }

            let chunkResult = try await provider.transcribe(samples)
            let text = chunkResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            pieces.append(text)
            confidenceSum += chunkResult.confidence
            transcribedChunks += 1
        }

        guard transcribedChunks > 0 else { return nil }
        return (pieces.joined(separator: " "), confidenceSum / Float(transcribedChunks))
    }

    /// Read a time range from an audio file as 16kHz mono Float32 samples.
    /// Ranges shorter than `minimumDurationSeconds` are padded with trailing silence
    /// (never widened into neighboring audio) so very brief speaker turns meet the ASR
    /// input minimum without absorbing an adjacent speaker's words.
    private nonisolated func readSamples(
        from audioFile: AVAudioFile,
        startSeconds: Double,
        endSeconds: Double,
        minimumDurationSeconds: Double
    ) throws -> [Float] {
        let sourceSampleRate = audioFile.processingFormat.sampleRate
        guard sourceSampleRate > 0 else {
            throw TranscriptionError.audioConversionFailed("Invalid audio file: sample rate is 0")
        }
        let fileDurationSeconds = Double(audioFile.length) / sourceSampleRate

        let start = max(0, startSeconds)
        let end = min(endSeconds, fileDurationSeconds)
        guard end > start else { return [] }

        let startFrame = AVAudioFramePosition((start * sourceSampleRate).rounded(.down))
        let frameCount = AVAudioFrameCount(((end - start) * sourceSampleRate).rounded(.up))
        guard frameCount > 0 else { return [] }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw TranscriptionError.audioConversionFailed("Could not create audio buffer")
        }

        audioFile.framePosition = startFrame
        try audioFile.read(into: buffer, frameCount: frameCount)
        var samples = try self.resampleBuffer(buffer)

        // Pad short turns with trailing silence (at the 16kHz ASR rate) rather than widening
        // the window into adjacent turns — absorbing a neighbor's audio would attribute their
        // words to this speaker. Trailing silence keeps the segment single-speaker.
        let minimumSamples = Int((minimumDurationSeconds * 16_000).rounded(.up))
        if samples.count < minimumSamples {
            samples.append(contentsOf: repeatElement(Float(0), count: minimumSamples - samples.count))
        }
        return samples
    }

    // MARK: - Audio Resampling Helpers

    /// Resample an audio buffer to 16 kHz mono Float32 samples using the shared downmixer.
    private nonisolated func resampleBuffer(
        _ buffer: AVAudioPCMBuffer,
        targetSampleRate: Double = 16_000
    ) throws -> [Float] {
        try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: targetSampleRate)
    }
}
