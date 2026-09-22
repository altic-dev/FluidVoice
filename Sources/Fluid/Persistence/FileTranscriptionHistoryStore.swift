//
//  FileTranscriptionHistoryStore.swift
//  Fluid
//
//  Persistence for file (meeting) transcription history so results survive navigation.
//

import Combine
import Foundation

// MARK: - File Transcription Entry Model

nonisolated struct FileTranscriptionEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    /// User-facing name; never changes the source file or its original filename.
    var customTitle: String?
    var searchRevision: UInt64?
    var displayTitle: String { self.customTitle ?? self.fileName }
    let duration: TimeInterval
    let processingTime: TimeInterval
    let confidence: Float
    let text: String
    /// Speaker-attributed segments when diarization was enabled; empty otherwise.
    let speakerSegments: [SpeakerTranscriptSegment]
    let speakerLabelingNotice: String?
    let speakerLabelingGaps: [SpeakerTranscriptGap]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        fileName: String,
        duration: TimeInterval,
        processingTime: TimeInterval,
        confidence: Float,
        text: String,
        speakerSegments: [SpeakerTranscriptSegment] = [],
        speakerLabelingNotice: String? = nil,
        speakerLabelingGaps: [SpeakerTranscriptGap] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.fileName = fileName
        self.duration = duration
        self.processingTime = processingTime
        self.confidence = confidence
        self.text = text
        self.speakerSegments = speakerSegments
        self.speakerLabelingNotice = speakerLabelingNotice
        self.speakerLabelingGaps = speakerLabelingGaps
    }

    init(from result: TranscriptionResult) {
        self.id = result.id
        self.timestamp = result.timestamp
        self.fileName = result.fileName
        self.duration = result.duration
        self.processingTime = result.processingTime
        self.confidence = result.confidence
        self.text = result.text
        self.speakerSegments = result.speakerSegments
        self.speakerLabelingNotice = result.speakerLabelingNotice
        self.speakerLabelingGaps = result.speakerLabelingGaps
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, fileName, duration, processingTime, confidence, text, speakerSegments
        case speakerLabelingNotice, speakerLabelingGaps, customTitle, searchRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        self.searchRevision = try c.decodeIfPresent(UInt64.self, forKey: .searchRevision)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.processingTime = try c.decode(TimeInterval.self, forKey: .processingTime)
        self.confidence = try c.decode(Float.self, forKey: .confidence)
        self.text = try c.decode(String.self, forKey: .text)
        // Older history entries predate speaker labels — tolerate a missing key.
        self.speakerSegments = try c.decodeIfPresent([SpeakerTranscriptSegment].self, forKey: .speakerSegments) ?? []
        self.speakerLabelingNotice = try c.decodeIfPresent(String.self, forKey: .speakerLabelingNotice)
        self.speakerLabelingGaps = try c.decodeIfPresent([SpeakerTranscriptGap].self, forKey: .speakerLabelingGaps) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.timestamp, forKey: .timestamp)
        try c.encode(self.fileName, forKey: .fileName)
        try c.encodeIfPresent(self.customTitle, forKey: .customTitle)
        try c.encodeIfPresent(self.searchRevision, forKey: .searchRevision)
        try c.encode(self.duration, forKey: .duration)
        try c.encode(self.processingTime, forKey: .processingTime)
        try c.encode(self.confidence, forKey: .confidence)
        try c.encode(self.text, forKey: .text)
        if !self.speakerSegments.isEmpty {
            try c.encode(self.speakerSegments, forKey: .speakerSegments)
        }
        try c.encodeIfPresent(self.speakerLabelingNotice, forKey: .speakerLabelingNotice)
        if !self.speakerLabelingGaps.isEmpty {
            try c.encode(self.speakerLabelingGaps, forKey: .speakerLabelingGaps)
        }
    }

    /// Preview text for list display (first 80 chars)
    var previewText: String {
        let leadingTrimmed = self.text.drop(while: { $0.isWhitespace })
        let prefix = leadingTrimmed.prefix(81)
        if prefix.count > 80, !leadingTrimmed.dropFirst(80).allSatisfy(\.isWhitespace) {
            return String(prefix.prefix(77)) + "..."
        }
        return String(prefix.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Relative time string for display
    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self.timestamp, relativeTo: Date())
    }

    /// Full formatted date string
    var fullDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self.timestamp)
    }

    /// Convert to TranscriptionResult for reuse of export/copy UI
    func toTranscriptionResult() -> TranscriptionResult {
        TranscriptionResult(
            id: self.id,
            text: self.text,
            confidence: self.confidence,
            duration: self.duration,
            processingTime: self.processingTime,
            fileName: self.fileName,
            timestamp: self.timestamp,
            speakerSegments: self.speakerSegments,
            speakerLabelingNotice: self.speakerLabelingNotice,
            speakerLabelingGaps: self.speakerLabelingGaps
        )
    }
}

// MARK: - File Transcription History Store

@MainActor
final class FileTranscriptionHistoryStore: ObservableObject {
    static let shared = FileTranscriptionHistoryStore()

    private let defaults: UserDefaults
    private let maxEntries = 50

    private enum Keys {
        static let fileTranscriptionHistory = "FileTranscriptionHistoryEntries"
    }

    @Published private(set) var entries: [FileTranscriptionEntry] = []
    @Published var selectedEntryID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.loadEntries()
    }

    // MARK: - Public Methods

    var selectedEntry: FileTranscriptionEntry? {
        guard let id = selectedEntryID else { return nil }
        return self.entries.first(where: { $0.id == id })
    }

    /// Add a completed file transcription to history (call after successful transcribeFile).
    func addEntry(_ result: TranscriptionResult) {
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let entry = FileTranscriptionEntry(from: result)
        self.entries.insert(entry, at: 0)

        if self.entries.count > self.maxEntries {
            self.entries.removeLast()
        }

        self.selectedEntryID = entry.id
        self.saveEntries()

        DebugLogger.shared.debug(
            "Added file transcription to history (total: \(self.entries.count))",
            source: "FileTranscriptionHistoryStore"
        )
    }

    func renameEntry(id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = self.entries.firstIndex(where: { $0.id == id }),
              self.entries[index].displayTitle != trimmed else { return }
        self.entries[index].customTitle = trimmed
        let revision = self.entries[index].searchRevision ?? 1
        self.entries[index].searchRevision = revision == .max ? .max : revision + 1
        self.saveEntries()
    }

    func deleteEntry(id: UUID) {
        self.entries.removeAll { $0.id == id }
        if self.selectedEntryID == id {
            self.selectedEntryID = self.entries.first?.id
        }
        self.saveEntries()
    }

    func clearAll() {
        self.entries.removeAll()
        self.selectedEntryID = nil
        self.saveEntries()
        DebugLogger.shared.info("Cleared all file transcription history", source: "FileTranscriptionHistoryStore")
    }

    // MARK: - Persistence

    private func loadEntries() {
        guard let data = self.defaults.data(forKey: Keys.fileTranscriptionHistory),
              let decoded = try? JSONDecoder().decode([FileTranscriptionEntry].self, from: data)
        else {
            self.entries = []
            return
        }
        self.entries = decoded
    }

    private func saveEntries() {
        if let encoded = try? JSONEncoder().encode(self.entries) {
            self.defaults.set(encoded, forKey: Keys.fileTranscriptionHistory)
        }
        self.objectWillChange.send()
    }
}
