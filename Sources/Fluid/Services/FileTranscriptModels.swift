import Foundation

/// One speaker-attributed portion of a file transcription.
nonisolated struct SpeakerTranscriptSegment: Identifiable, Codable, Equatable {
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
nonisolated struct SpeakerTranscriptGap: Codable, Equatable {
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

/// Result of a transcription operation
nonisolated struct TranscriptionResult: Identifiable, Codable {
    let id: UUID
    let text: String
    let confidence: Float
    let duration: TimeInterval
    let processingTime: TimeInterval
    let fileName: String
    let timestamp: Date
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
        self.speakerSegments = speakerSegments
        self.speakerLabelingNotice = speakerLabelingNotice
        self.speakerLabelingGaps = speakerLabelingGaps
    }

    enum CodingKeys: String, CodingKey {
        case text, confidence, duration, processingTime, fileName, timestamp, speakerSegments
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
        if !self.speakerSegments.isEmpty {
            try c.encode(self.speakerSegments, forKey: .speakerSegments)
        }
        try c.encodeIfPresent(self.speakerLabelingNotice, forKey: .speakerLabelingNotice)
        if !self.speakerLabelingGaps.isEmpty {
            try c.encode(self.speakerLabelingGaps, forKey: .speakerLabelingGaps)
        }
    }

    var jsonExport: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
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
