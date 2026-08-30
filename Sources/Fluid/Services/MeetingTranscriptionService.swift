import AVFoundation
import Combine
import CoreMedia
import FluidAudio
import Foundation
import UniformTypeIdentifiers

struct SubtitleCue: Codable, Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
}

/// One speaker-attributed portion of a file transcription.
nonisolated struct SpeakerTranscriptSegment: Identifiable, Sendable, Codable, Equatable {
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

/// An audio interval for which speaker-attributed ASR produced no usable text.
nonisolated struct SpeakerTranscriptGap: Sendable, Codable, Equatable {
    let startSeconds: Double
    let endSeconds: Double

    var durationSeconds: Double {
        max(0, self.endSeconds - self.startSeconds)
    }

    var timestampRangeText: String {
        "\(Self.timestamp(self.startSeconds))-\(Self.timestamp(self.endSeconds))"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds)
        let wholeMinutes = Int(safeSeconds) / 60
        let remainingSeconds = safeSeconds - Double(wholeMinutes * 60)
        return String(format: "%d:%04.1f", wholeMinutes, remainingSeconds)
    }
}

nonisolated struct SpeakerChunkTranscription: Sendable, Equatable {
    let text: String
    let confidence: Float
}

nonisolated struct SpeakerTurnTranscription: Sendable, Equatable {
    let text: String
    let confidence: Float
    let gaps: [SpeakerTranscriptGap]
}

nonisolated struct SpeakerRecognizedTurn: Sendable, Equatable {
    let speaker: String
    let startSeconds: Double
    let endSeconds: Double
    let transcription: SpeakerTurnTranscription
}

nonisolated struct SpeakerLabeledTranscript: Sendable, Equatable {
    let segments: [SpeakerTranscriptSegment]
    let confidence: Float
    let gaps: [SpeakerTranscriptGap]
    let notice: String?
}

nonisolated struct SpeakerLabelingCoverage: Sendable, Equatable {
    let gapCount: Int
    let skippedDurationSeconds: Double
    let maxGapDurationSeconds: Double
    let diarizedDurationSeconds: Double

    var skippedRatio: Double {
        guard self.diarizedDurationSeconds.isFinite, self.diarizedDurationSeconds > 0 else {
            return self.skippedDurationSeconds > 0 ? .infinity : 0
        }
        return self.skippedDurationSeconds / self.diarizedDurationSeconds
    }
}

nonisolated enum SpeakerLabeledTranscriptionPolicy {
    static func transcribeChunks(
        _ ranges: [SpeakerTranscriptGap],
        operation: (SpeakerTranscriptGap) async throws -> SpeakerChunkTranscription?
    ) async rethrows -> SpeakerTurnTranscription {
        var pieces: [String] = []
        var confidenceSum: Float = 0
        var gaps: [SpeakerTranscriptGap] = []

        for range in ranges {
            let result = try await operation(range)
            let text = result?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, let result else {
                gaps.append(range)
                continue
            }

            pieces.append(text)
            confidenceSum += result.confidence
        }

        let confidence = pieces.isEmpty ? 0 : confidenceSum / Float(pieces.count)
        return SpeakerTurnTranscription(
            text: pieces.joined(separator: " "),
            confidence: confidence,
            gaps: gaps
        )
    }

    static func shouldKeepSpeakerLabels(
        hasRecognizedText: Bool,
        gaps: [SpeakerTranscriptGap],
        diarizedDurationSeconds: Double
    ) -> Bool {
        guard hasRecognizedText else { return false }
        guard !gaps.isEmpty else { return true }
        guard diarizedDurationSeconds.isFinite, diarizedDurationSeconds > 0 else { return false }

        let coverage = self.coverage(
            gaps: gaps,
            diarizedDurationSeconds: diarizedDurationSeconds
        )
        guard coverage.maxGapDurationSeconds <= 5 else { return false }

        let allowedSkippedDuration = min(30, diarizedDurationSeconds * 0.01)
        return coverage.skippedDurationSeconds <= allowedSkippedDuration
    }

    static func coverage(
        gaps: [SpeakerTranscriptGap],
        diarizedDurationSeconds: Double
    ) -> SpeakerLabelingCoverage {
        let durations = gaps.map(\.durationSeconds)
        return SpeakerLabelingCoverage(
            gapCount: gaps.count,
            skippedDurationSeconds: durations.reduce(0, +),
            maxGapDurationSeconds: durations.max() ?? 0,
            diarizedDurationSeconds: diarizedDurationSeconds
        )
    }

    static func fallbackDiagnostic(
        hasRecognizedText: Bool,
        gaps: [SpeakerTranscriptGap],
        diarizedDurationSeconds: Double
    ) -> String {
        guard hasRecognizedText else {
            return "Speaker labeling produced no recognized text"
        }
        guard diarizedDurationSeconds.isFinite, diarizedDurationSeconds > 0 else {
            return "Speaker labeling produced an invalid diarized duration"
        }

        let coverage = self.coverage(
            gaps: gaps,
            diarizedDurationSeconds: diarizedDurationSeconds
        )
        return String(
            format: "Speaker labeling omitted too much audio (gaps=%d, skipped=%.3fs, maxGap=%.3fs, diarized=%.3fs, ratio=%.4f)",
            coverage.gapCount,
            coverage.skippedDurationSeconds,
            coverage.maxGapDurationSeconds,
            coverage.diarizedDurationSeconds,
            coverage.skippedRatio
        )
    }

    static func limitationNotice(for gaps: [SpeakerTranscriptGap]) -> String? {
        guard !gaps.isEmpty else { return nil }
        let noun = gaps.count == 1 ? "section" : "sections"
        let duration = gaps.reduce(0) { $0 + $1.durationSeconds }
        return "Speaker labels were kept, but \(gaps.count) short audio \(noun) totaling \(String(format: "%.1f", duration)) seconds produced no text."
    }

    static func assembleTurns(_ turns: [SpeakerRecognizedTurn]) -> SpeakerLabeledTranscript? {
        let gaps = turns.flatMap(\.transcription.gaps)
        let recognizedTurns = turns.filter {
            !$0.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let diarizedDuration = turns.reduce(0) {
            $0 + max(0, $1.endSeconds - $1.startSeconds)
        }
        guard self.shouldKeepSpeakerLabels(
            hasRecognizedText: !recognizedTurns.isEmpty,
            gaps: gaps,
            diarizedDurationSeconds: diarizedDuration
        ) else {
            return nil
        }

        let segments = recognizedTurns.map { turn in
            SpeakerTranscriptSegment(
                speaker: turn.speaker,
                startSeconds: turn.startSeconds,
                endSeconds: turn.endSeconds,
                text: turn.transcription.text
            )
        }
        let confidence = recognizedTurns.reduce(0) {
            $0 + $1.transcription.confidence
        } / Float(recognizedTurns.count)
        return SpeakerLabeledTranscript(
            segments: segments,
            confidence: confidence,
            gaps: gaps,
            notice: self.limitationNotice(for: gaps)
        )
    }
}

/// Result of a transcription operation
nonisolated struct TranscriptionResult: Identifiable, Sendable, Codable {
    let id: UUID
    let text: String
    let confidence: Float
    let duration: TimeInterval
    let processingTime: TimeInterval
    let fileName: String
    let timestamp: Date
    let subtitleCues: [SubtitleCue]
    /// Speaker-attributed segments when diarization was enabled; empty otherwise.
    let speakerSegments: [SpeakerTranscriptSegment]
    /// Persisted explanation when speaker labeling was partial or unavailable.
    let speakerLabelingNotice: String?
    /// Exact intervals omitted from an otherwise accepted speaker-attributed transcript.
    let speakerLabelingGaps: [SpeakerTranscriptGap]

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        duration: TimeInterval,
        processingTime: TimeInterval,
        fileName: String,
        timestamp: Date = Date(),
        subtitleCues: [SubtitleCue] = [],
        speakerSegments: [SpeakerTranscriptSegment] = [],
        speakerLabelingNotice: String? = nil,
        speakerLabelingGaps: [SpeakerTranscriptGap] = []
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.duration = duration
        self.processingTime = processingTime
        self.fileName = fileName
        self.timestamp = timestamp
        self.subtitleCues = subtitleCues
        self.speakerSegments = speakerSegments
        self.speakerLabelingNotice = speakerLabelingNotice
        self.speakerLabelingGaps = speakerLabelingGaps
    }

    enum CodingKeys: String, CodingKey {
        case text, confidence, duration, processingTime, fileName, timestamp, subtitleCues, speakerSegments
        case speakerLabelingNotice, speakerLabelingGaps
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
        self.subtitleCues = try c.decodeIfPresent([SubtitleCue].self, forKey: .subtitleCues) ?? []
        self.speakerSegments = try c.decodeIfPresent([SpeakerTranscriptSegment].self, forKey: .speakerSegments) ?? []
        self.speakerLabelingNotice = try c.decodeIfPresent(String.self, forKey: .speakerLabelingNotice)
        self.speakerLabelingGaps = try c.decodeIfPresent([SpeakerTranscriptGap].self, forKey: .speakerLabelingGaps) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.text, forKey: .text)
        try c.encode(self.confidence, forKey: .confidence)
        try c.encode(self.duration, forKey: .duration)
        try c.encode(self.processingTime, forKey: .processingTime)
        try c.encode(self.fileName, forKey: .fileName)
        try c.encode(self.timestamp, forKey: .timestamp)
        try c.encode(self.subtitleCues, forKey: .subtitleCues)
        if !self.speakerSegments.isEmpty {
            try c.encode(self.speakerSegments, forKey: .speakerSegments)
        }
        try c.encodeIfPresent(self.speakerLabelingNotice, forKey: .speakerLabelingNotice)
        if !self.speakerLabelingGaps.isEmpty {
            try c.encode(self.speakerLabelingGaps, forKey: .speakerLabelingGaps)
        }
    }

    var textExport: String {
        var metadata = [
            "Transcription: \(self.fileName)",
            "Date: \(self.timestamp.formatted())",
            "Duration: \(String(format: "%.1f", self.duration))s",
            "Processing Time: \(String(format: "%.1f", self.processingTime))s",
            "Confidence: \(String(format: "%.1f%%", self.confidence * 100))",
        ]
        if let speakerLabelingNotice {
            metadata.append("Speaker labeling: \(speakerLabelingNotice)")
        }
        if !self.speakerLabelingGaps.isEmpty {
            metadata.append("Unlabeled audio ranges: \(self.speakerLabelingGaps.map(\.timestampRangeText).joined(separator: ", "))")
        }
        return metadata.joined(separator: "\n") + "\n\n---\n\n" + self.text
    }
}

/// Service for transcribing complete audio/video files with optional speaker diarization
/// NOTE: This service shares the ASR models with ASRService to avoid duplicate memory usage
@MainActor
final class MeetingTranscriptionService: ObservableObject {
    @Published var isTranscribing: Bool = false
    @Published var progress: Double = 0.0
    @Published var currentStatus: String = ""
    @Published var liveTranscript: String = ""
    @Published var elapsedProcessingTime: Double = 0
    @Published var processedAudioDuration: Double = 0
    @Published var error: String?
    @Published var result: TranscriptionResult?
    @Published var fallbackNotice: String?

    // MARK: - Supported Formats

    /// File extensions the OS can actually decode, queried dynamically from AVFoundation.
    /// Filtered to audio/video types only — excludes subtitles, playlists, etc.
    /// Uses every extension tag of each type, not just the preferred one: `.opus`/`.oga`
    /// (e.g. WhatsApp voice notes) map to the same UTType as `.ogg` and decode natively.
    static let supportedFileExtensions: Set<String> = {
        let avTypes = AVURLAsset.audiovisualTypes()
        let extensions = avTypes.flatMap { fileType -> [String] in
            guard let utType = UTType(fileType.rawValue) else { return [] }
            guard utType.conforms(to: .audio) || utType.conforms(to: .movie) else { return [] }
            return utType.tags[.filenameExtension] ?? []
        }
        return Set(extensions.map { $0.lowercased() }).union(["mkv"])
    }()

    /// Content types accepted by the file picker — broad categories so the OS filters naturally.
    static let allowedContentTypes: [UTType] = [
        .audio,
        .movie,
        UTType(filenameExtension: "mkv") ?? UTType(importedAs: "org.matroska.mkv", conformingTo: .audiovisualContent),
    ]

    /// User-facing description of supported formats (curated for readability).
    static let supportedFormatsDescription = "Supported: WAV, MP3, M4A, OGG, OPUS, MP4, MOV, MKV, and more"

    /// Error copy shown when a dropped file is not accepted.
    static let dropErrorCopy = "Accepted file types: WAV, MP3, M4A, OGG, OPUS, MP4, MOV, MKV, and more."

    /// Share the ASR service instance to avoid loading models twice
    private let asrService: ASRService
    private var preparedProvider: TranscriptionProvider?
    private var preparedProviderModel: SettingsStore.SpeechModel?
    private var diarizer: OfflineDiarizerManager?

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

    private func provider(for model: SettingsStore.SpeechModel) async throws -> TranscriptionProvider {
        if self.preparedProviderModel != model {
            self.preparedProvider = self.asrService.fileTranscriptionProvider(for: model)
            self.preparedProviderModel = model
        }

        guard let provider = self.preparedProvider else {
            throw TranscriptionError.modelLoadFailed("Could not create the selected transcription provider")
        }
        guard !provider.isReady else { return provider }

        self.currentStatus = "Preparing \(model.displayName)..."
        self.progress = 0.1

        do {
            try await provider.prepare(progressHandler: nil)
            self.currentStatus = "Model ready"
            return provider
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Transcribe an audio or video file
    /// - Parameters:
    ///   - fileURL: URL to the audio/video file
    func transcribeFile(
        _ fileURL: URL,
        model: SettingsStore.SpeechModel = .whisperLargeTurbo,
        diarizeSpeakers: Bool = false
    ) async throws -> TranscriptionResult {
        self.isTranscribing = true
        error = nil
        self.fallbackNotice = nil
        self.progress = 0.0
        self.liveTranscript = ""
        self.elapsedProcessingTime = 0
        self.processedAudioDuration = 0
        let startTime = Date()

        defer {
            isTranscribing = false
            progress = 0.0
        }

        do {
            let provider = try await self.provider(for: model)

            // Check file extension
            let fileExtension = fileURL.pathExtension.lowercased()

            guard Self.supportedFileExtensions.contains(fileExtension) else {
                throw TranscriptionError
                    .fileNotSupported("Format .\(fileExtension) not supported. \(Self.supportedFormatsDescription)")
            }

            AnalyticsService.shared.recordUsage(
                mode: .meeting,
                transcriptionModel: SettingsStore.shared.selectedSpeechModel.analyticsDescriptor
            )

            // Get audio duration for progress display
            self.currentStatus = "Analyzing audio file..."
            self.progress = 0.2

            let asset = AVAsset(url: fileURL)
            var duration: Double
            do {
                let cmDuration = try await asset.load(.duration)
                duration = CMTimeGetSeconds(cmDuration)
            } catch {
                // Fall back to 0 if we can't determine duration
                duration = 0
                DebugLogger.shared.warning("Could not determine audio duration: \(error.localizedDescription)", source: "MeetingTranscriptionService")
            }
            if (!duration.isFinite || duration <= 0), fileExtension == "mkv" {
                duration = self.probeMediaDuration(fileURL) ?? 0
            }

            let isVideoContainer = fileExtension == "mkv" || (UTType(filenameExtension: fileExtension)
                .map { $0.conforms(to: .movie) } ?? false)

            if diarizeSpeakers {
                let diarizedResult = try await self.transcribeWithSpeakerDiarization(
                    fileURL,
                    provider: provider
                )
                let processingTime = Date().timeIntervalSince(startTime)
                let result = TranscriptionResult(
                    text: diarizedResult.text,
                    confidence: diarizedResult.confidence,
                    duration: duration,
                    processingTime: processingTime,
                    fileName: fileURL.lastPathComponent,
                    subtitleCues: diarizedResult.subtitleCues
                )

                self.currentStatus = "Complete!"
                self.progress = 1.0
                self.result = result
                FileTranscriptionHistoryStore.shared.addEntry(result)
                return result
            }

            if isVideoContainer, let whisperProvider = provider as? WhisperProvider {
                self.currentStatus = "Preparing video audio..."
                self.progress = 0.3
                let samples: [Float]
                do {
                    samples = try self.decodeAudioSamples(fileURL)
                } catch {
                    throw TranscriptionError.audioConversionFailed(
                        "Could not decode video audio: \(error.localizedDescription)"
                    )
                }

                self.currentStatus = "Creating timestamped subtitles..."
                self.progress = 0.5
                let segments = try await whisperProvider.transcribeTimed(samples) { [weak self] newSegments, processed in
                    guard let self else { return }
                    self.appendLiveSegments(newSegments, processed: processed, duration: duration, startedAt: startTime)
                }
                let cues = segments.map {
                    SubtitleCue(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, text: $0.text)
                }
                let text = cues.map(\.text).joined(separator: " ")
                guard !text.isEmpty else {
                    throw TranscriptionError.transcriptionFailed("No speech was detected in this video")
                }

                let processingTime = Date().timeIntervalSince(startTime)
                let result = TranscriptionResult(
                    text: text,
                    confidence: 1,
                    duration: duration,
                    processingTime: processingTime,
                    fileName: fileURL.lastPathComponent,
                    subtitleCues: cues
                )
                self.currentStatus = "Complete!"
                self.progress = 1
                self.result = result
                FileTranscriptionHistoryStore.shared.addEntry(result)
                return result
            }

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
                    source: "MeetingTranscriptionService"
                )
                self.fallbackNotice = "Speaker labeling was unavailable for this file. The transcript was completed without speaker labels."
                self.progress = 0.3
            } else if SettingsStore.shared.fileTranscriptionSpeakerLabelsEnabled, isVideoContainer {
                DebugLogger.shared.info(
                    "Speaker labeling skipped for video container; using standard transcription",
                    source: "MeetingTranscriptionService"
                )
            }

            if provider.prefersNativeFileTranscription && !isVideoContainer {
                self.currentStatus = duration > 0 ? "Transcribing audio (\(Int(duration))s)..." : "Transcribing audio..."
                self.progress = 0.3

                DebugLogger.shared.info(
                    "MeetingTranscriptionService: using native file transcription path for provider=\(provider.name)",
                    source: "MeetingTranscriptionService"
                )

                let nativeResult = try await provider.transcribeFile(at: fileURL)
                let processingTime = Date().timeIntervalSince(startTime)
                let result = TranscriptionResult(
                    text: nativeResult.text,
                    confidence: nativeResult.confidence,
                    duration: duration,
                    processingTime: processingTime,
                    fileName: fileURL.lastPathComponent,
                    speakerLabelingNotice: self.fallbackNotice
                )

                self.currentStatus = "Complete!"
                self.progress = 1.0

                self.result = result
                FileTranscriptionHistoryStore.shared.addEntry(result)
                return result
            }

            if provider.prefersNativeFileTranscription && isVideoContainer {
                DebugLogger.shared.info(
                    "MeetingTranscriptionService: using buffered transcription path for video container [provider=\(provider.name), extension=\(fileExtension)]",
                    source: "MeetingTranscriptionService"
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
                    self.liveTranscript = allTranscriptions.joined(separator: " ")
                    totalConfidence += chunkResult.confidence
                    chunkCount += 1
                }

                currentFrame += AVAudioFramePosition(framesToRead)

                // Update progress
                let progressPercent = Double(currentFrame) / Double(audioFile.length)
                self.processedAudioDuration = duration * progressPercent
                self.elapsedProcessingTime = Date().timeIntervalSince(startTime)
                self.progress = 0.3 + (progressPercent * 0.6) // Progress from 30% to 90%
                let speed = self.elapsedProcessingTime > 0 ? self.processedAudioDuration / self.elapsedProcessingTime : 0
                self.currentStatus = "Transcribing... \(Int(progressPercent * 100))% • \(String(format: "%.1f", speed))x realtime"
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
                fileName: fileURL.lastPathComponent,
                speakerLabelingNotice: self.fallbackNotice
            )


            self.result = result
            FileTranscriptionHistoryStore.shared.addEntry(result)
            return result

        } catch let error as TranscriptionError {
            self.error = error.localizedDescription
            throw error
        } catch {
            let wrappedError = TranscriptionError.transcriptionFailed(error.localizedDescription)
            self.error = wrappedError.localizedDescription
            throw wrappedError
        }
    }

    private func transcribeWithSpeakerDiarization(
        _ fileURL: URL,
        provider: TranscriptionProvider
    ) async throws -> (text: String, confidence: Float, subtitleCues: [SubtitleCue]) {
        self.currentStatus = "Preparing local speaker detection..."
        self.progress = 0.25

        let diarizer: OfflineDiarizerManager
        if let existing = self.diarizer {
            diarizer = existing
        } else {
            let created = OfflineDiarizerManager(config: .default)
            self.diarizer = created
            diarizer = created
        }

        try await diarizer.prepareModels()
        self.currentStatus = "Detecting speakers..."
        self.progress = 0.35

        let samples: [Float]
        do {
            samples = try self.decodeAudioSamples(fileURL)
        } catch {
            throw TranscriptionError.audioConversionFailed(
                "Speaker detection could not decode this file: \(error.localizedDescription)"
            )
        }

        let diarization = try await diarizer.process(audio: samples)
        if let whisperProvider = provider as? WhisperProvider {
            return try await self.transcribeContinuousWhisperWithSpeakerLabels(
                samples: samples,
                diarization: diarization.segments,
                provider: whisperProvider
            )
        }

        let turns = self.mergedSpeakerTurns(diarization.segments)
        guard !turns.isEmpty else {
            throw TranscriptionError.transcriptionFailed("No speakers were detected in this file")
        }

        var speakerNumbers: [String: Int] = [:]
        var lines: [String] = []
        var confidenceTotal: Float = 0
        var transcribedTurnCount = 0

        for (index, turn) in turns.enumerated() {
            let startSample = max(0, min(samples.count, Int(Double(turn.start) * 16_000)))
            let endSample = max(startSample, min(samples.count, Int(Double(turn.end) * 16_000)))
            guard endSample > startSample else { continue }

            var turnSamples = Array(samples[startSample ..< endSample])
            if turnSamples.count < 16_000 {
                turnSamples.append(contentsOf: repeatElement(0, count: 16_000 - turnSamples.count))
            }

            let transcription = try await provider.transcribe(turnSamples)
            let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let speakerNumber: Int
            if let existing = speakerNumbers[turn.speakerID] {
                speakerNumber = existing
            } else {
                speakerNumber = speakerNumbers.count + 1
                speakerNumbers[turn.speakerID] = speakerNumber
            }

            lines.append("Speaker \(speakerNumber): \(text)")
            confidenceTotal += transcription.confidence
            transcribedTurnCount += 1

            let fraction = Double(index + 1) / Double(turns.count)
            self.progress = 0.5 + (fraction * 0.45)
            self.currentStatus = "Transcribing speaker turns... \(Int(fraction * 100))%"
        }

        guard !lines.isEmpty else {
            throw TranscriptionError.transcriptionFailed("Speakers were detected, but no speech could be transcribed")
        }

        let confidence = transcribedTurnCount > 0
            ? confidenceTotal / Float(transcribedTurnCount)
            : 0
        return (lines.joined(separator: "\n\n"), confidence, [])
    }

    private func transcribeContinuousWhisperWithSpeakerLabels(
        samples: [Float],
        diarization: [TimedSpeakerSegment],
        provider: WhisperProvider
    ) async throws -> (text: String, confidence: Float, subtitleCues: [SubtitleCue]) {
        self.currentStatus = "Transcribing continuous audio..."
        self.progress = 0.5

        let transcriptionStart = Date()
        let totalDuration = Double(samples.count) / 16_000
        let timedSegments = try await provider.transcribeTimed(samples) { [weak self] newSegments, processed in
            guard let self else { return }
            self.appendLiveSegments(newSegments, processed: processed, duration: totalDuration, startedAt: transcriptionStart)
        }
        let speakerSegments = diarization
            .filter { $0.endTimeSeconds > $0.startTimeSeconds }
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }

        var speakerNumbers: [String: Int] = [:]
        var paragraphs: [(speaker: Int, text: String)] = []
        var subtitleCues: [SubtitleCue] = []

        for segment in timedSegments {
            guard let speakerID = self.bestSpeakerID(
                forStart: segment.startSeconds,
                end: segment.endSeconds,
                diarization: speakerSegments
            ) else {
                continue
            }

            let speakerNumber: Int
            if let existing = speakerNumbers[speakerID] {
                speakerNumber = existing
            } else {
                speakerNumber = speakerNumbers.count + 1
                speakerNumbers[speakerID] = speakerNumber
            }

            if let last = paragraphs.last, last.speaker == speakerNumber {
                paragraphs[paragraphs.count - 1].text += " " + segment.text
            } else {
                paragraphs.append((speakerNumber, segment.text))
            }
            subtitleCues.append(SubtitleCue(
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                text: "Speaker \(speakerNumber): \(segment.text)"
            ))
        }

        guard !paragraphs.isEmpty else {
            throw TranscriptionError.transcriptionFailed(
                "Speech was detected, but no timestamped transcription overlapped it"
            )
        }

        self.progress = 0.95
        let text = paragraphs
            .map { "Speaker \($0.speaker): \($0.text)" }
            .joined(separator: "\n\n")
        return (text, 1.0, subtitleCues)
    }

    private func bestSpeakerID(
        forStart start: Double,
        end: Double,
        diarization: [TimedSpeakerSegment]
    ) -> String? {
        var bestSpeakerID: String?
        var bestOverlap = 0.0

        for speakerSegment in diarization {
            let speakerStart = Double(speakerSegment.startTimeSeconds)
            let speakerEnd = Double(speakerSegment.endTimeSeconds)
            if speakerStart >= end { break }
            guard speakerEnd > start else { continue }

            let overlap = min(end, speakerEnd) - max(start, speakerStart)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeakerID = speakerSegment.speakerId
            }
        }

        return bestSpeakerID
    }

    private func mergedSpeakerTurns(
        _ segments: [TimedSpeakerSegment]
    ) -> [(speakerID: String, start: Float, end: Float)] {
        let sorted = segments
            .filter { $0.endTimeSeconds > $0.startTimeSeconds }
            .sorted { lhs, rhs in lhs.startTimeSeconds < rhs.startTimeSeconds }

        var turns: [(speakerID: String, start: Float, end: Float)] = []
        for segment in sorted {
            if let last = turns.last,
               last.speakerID == segment.speakerId,
               segment.startTimeSeconds - last.end <= 0.75
            {
                turns[turns.count - 1].end = max(last.end, segment.endTimeSeconds)
            } else {
                turns.append((segment.speakerId, segment.startTimeSeconds, segment.endTimeSeconds))
            }
        }
        return turns
    }

    /// Export transcription result to text file
    nonisolated func exportToText(_ result: TranscriptionResult, to destinationURL: URL) throws {
        try result.textExport.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    nonisolated func exportToSRT(_ result: TranscriptionResult, to destinationURL: URL) throws {
        let normalizedCues = result.subtitleCues
            .filter {
                $0.startSeconds.isFinite &&
                    $0.endSeconds.isFinite &&
                    $0.endSeconds > $0.startSeconds &&
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted {
                if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
                if $0.endSeconds != $1.endSeconds { return $0.endSeconds < $1.endSeconds }
                return $0.text < $1.text
            }
        guard !normalizedCues.isEmpty else {
            throw TranscriptionError.transcriptionFailed("This transcription does not contain subtitle timestamps")
        }
        try Self.srtContent(for: normalizedCues)
            .write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    private nonisolated static func srtContent(for cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(Self.srtTimestamp(cue.startSeconds)) --> \(Self.srtTimestamp(cue.endSeconds))
            \(cue.text.replacingOccurrences(of: "\n", with: " "))
            """
        }.joined(separator: "\n\n") + "\n"
    }

    private nonisolated static func srtTimestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let secs = (milliseconds % 60_000) / 1000
        let millis = milliseconds % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
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
        self.fallbackNotice = nil
        self.currentStatus = ""
        self.progress = 0.0
        self.liveTranscript = ""
        self.elapsedProcessingTime = 0
        self.processedAudioDuration = 0
    }

    private func appendLiveSegments(
        _ segments: [WhisperTimedSegment],
        processed: Double,
        duration: Double,
        startedAt: Date
    ) {
        let text = segments.map(\.text).joined(separator: " ")
        if !text.isEmpty {
            self.liveTranscript += self.liveTranscript.isEmpty ? text : " " + text
        }
        self.processedAudioDuration = processed
        self.elapsedProcessingTime = Date().timeIntervalSince(startedAt)
        let fraction = duration > 0 ? min(1, processed / duration) : 0
        self.progress = 0.5 + (fraction * 0.45)
        let speed = self.elapsedProcessingTime > 0 ? processed / self.elapsedProcessingTime : 0
        self.currentStatus = "Transcribed \(Int(processed))s • \(String(format: "%.1f", speed))x realtime"
    }

    private nonisolated func decodeAudioSamples(_ fileURL: URL) throws -> [Float] {
        guard fileURL.pathExtension.lowercased() == "mkv" else {
            return try AudioConverter().resampleAudioFile(fileURL)
        }

        guard let ffmpegURL = Self.mediaToolURL(named: "ffmpeg") else {
            throw NSError(
                domain: "MeetingTranscriptionService",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "MKV transcription requires FFmpeg. Install it with: brew install ffmpeg"]
            )
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidvoice-mkv-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", fileURL.path,
            "-map", "0:a:0", "-vn",
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_f32le",
            temporaryURL.path,
        ]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "MeetingTranscriptionService",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "FFmpeg could not extract audio from this MKV file"]
            )
        }

        return try AudioConverter().resampleAudioFile(temporaryURL)
    }

    private nonisolated func probeMediaDuration(_ fileURL: URL) -> Double? {
        guard let ffprobeURL = Self.mediaToolURL(named: "ffprobe") else { return nil }
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", fileURL.path,
        ]
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let value = String(data: data, encoding: .utf8)
                .flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
                value.isFinite,
                value > 0
            else { return nil }
            return value
        } catch {
            return nil
        }
    }

    private nonisolated static func mediaToolURL(named name: String) -> URL? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Speaker-Labeled Transcription

    /// Diarize-first pipeline: identify speaker turns, then transcribe the audio slice for
    /// each turn with the active provider. Tiny empty ASR intervals can be retained as explicit
    /// gaps. Material omissions or genuine errors return nil so the caller can run the standard
    /// full-file transcription path instead.
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
                source: "MeetingTranscriptionService"
            )
            return nil
        }

        guard !turns.isEmpty else {
            DebugLogger.shared.info(
                "Diarization found no speaker turns",
                source: "MeetingTranscriptionService"
            )
            return nil
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            DebugLogger.shared.warning(
                "Could not open audio for speaker slicing: \(error.localizedDescription)",
                source: "MeetingTranscriptionService"
            )
            return nil
        }

        var recognizedTurns: [SpeakerRecognizedTurn] = []

        for (index, turn) in turns.enumerated() {
            self.currentStatus = "Transcribing speaker segments (\(index + 1)/\(turns.count))..."
            self.progress = 0.3 + (Double(index) / Double(turns.count)) * 0.65

            let transcribed: SpeakerTurnTranscription
            do {
                transcribed = try await self.transcribeSpeakerTurn(turn, from: audioFile, provider: provider)
            } catch {
                // A genuine audio-read or ASR failure can omit an unknown amount of speech.
                // Use the standard full-file path rather than accepting uncertain labels.
                DebugLogger.shared.warning(
                    "Speaker labeling aborted at segment \(index + 1)/\(turns.count) (\(String(format: "%.1f", turn.startSeconds))s): \(error.localizedDescription); falling back to standard transcription",
                    source: "MeetingTranscriptionService"
                )
                return nil
            }

            recognizedTurns.append(SpeakerRecognizedTurn(
                speaker: turn.speakerLabel,
                startSeconds: turn.startSeconds,
                endSeconds: turn.endSeconds,
                transcription: transcribed
            ))
        }

        guard let labeledTranscript = SpeakerLabeledTranscriptionPolicy.assembleTurns(recognizedTurns) else {
            let gaps = recognizedTurns.flatMap(\.transcription.gaps)
            let diarizedDuration = recognizedTurns.reduce(0) {
                $0 + max(0, $1.endSeconds - $1.startSeconds)
            }
            let hasRecognizedText = recognizedTurns.contains {
                !$0.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let diagnostic = SpeakerLabeledTranscriptionPolicy.fallbackDiagnostic(
                hasRecognizedText: hasRecognizedText,
                gaps: gaps,
                diarizedDurationSeconds: diarizedDuration
            )
            DebugLogger.shared.warning(
                "\(diagnostic); falling back to standard transcription",
                source: "MeetingTranscriptionService"
            )
            return nil
        }

        let labeledText = labeledTranscript.segments
            .map(\.plainText)
            .joined(separator: "\n\n")
        let processingTime = Date().timeIntervalSince(startTime)

        let result = TranscriptionResult(
            text: labeledText,
            confidence: labeledTranscript.confidence,
            duration: duration,
            processingTime: processingTime,
            fileName: fileURL.lastPathComponent,
            speakerSegments: labeledTranscript.segments,
            speakerLabelingNotice: labeledTranscript.notice,
            speakerLabelingGaps: labeledTranscript.gaps
        )

        self.currentStatus = "Complete!"
        self.progress = 1.0

        self.result = result
        FileTranscriptionHistoryStore.shared.addEntry(result)
        return result
    }

    /// Transcribe a single speaker turn, splitting overlong turns into bounded chunks.
    /// Returns the concatenated text, mean confidence, and explicit empty ASR intervals.
    /// Throws on a genuine audio-read or ASR failure so the caller can use full-file transcription.
    private func transcribeSpeakerTurn(
        _ turn: SpeakerDiarizationService.SpeakerTurn,
        from audioFile: AVAudioFile,
        provider: TranscriptionProvider
    ) async throws -> SpeakerTurnTranscription {
        // Bound memory for unusually long single-speaker stretches. Providers remain free to
        // apply their own model-specific, energy-aware chunking within each request.
        let maxChunkSeconds: Double = 20 * 60

        var ranges: [SpeakerTranscriptGap] = []
        if turn.endSeconds - turn.startSeconds > maxChunkSeconds {
            var chunkStart = turn.startSeconds
            while chunkStart < turn.endSeconds {
                let chunkEnd = min(chunkStart + maxChunkSeconds, turn.endSeconds)
                ranges.append(SpeakerTranscriptGap(startSeconds: chunkStart, endSeconds: chunkEnd))
                chunkStart = chunkEnd
            }
        } else {
            ranges.append(SpeakerTranscriptGap(startSeconds: turn.startSeconds, endSeconds: turn.endSeconds))
        }

        return try await SpeakerLabeledTranscriptionPolicy.transcribeChunks(ranges) { range in
            let samples = try self.readSamples(
                from: audioFile,
                startSeconds: range.startSeconds,
                endSeconds: range.endSeconds,
                minimumDurationSeconds: 1.1
            )
            guard samples.count >= 16_000 else { return nil }

            let chunkResult = try await provider.transcribe(samples)
            return SpeakerChunkTranscription(
                text: chunkResult.text,
                confidence: chunkResult.confidence
            )
        }
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
