import Foundation

/// Standalone harness: compile the real store and transcript models against
/// in-memory persistence. Never touches the installed app's history.
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? {
        self.values[key] as? Data
    }

    func set(_ value: Any?, forKey key: String) {
        self.values[key] = value
    }
}

final class DebugLogger {
    static let shared = DebugLogger()
    func debug(_: String, source _: String) {}
    func info(_: String, source _: String) {}
}

@main @MainActor struct FileTranscriptRenameTests {
    static func main() throws {
        let defaults = UserDefaults()
        let store = FileTranscriptionHistoryStore(defaults: defaults)
        let result = TranscriptionResult(
            id: UUID(),
            text: "Keep the transcript",
            confidence: 0.9,
            duration: 12,
            processingTime: 1,
            fileName: "original.wav",
            timestamp: Date(),
            speakerSegments: [.init(speaker: "Speaker 1", startSeconds: 0, endSeconds: 1, text: "Speaker text")],
            speakerLabelingNotice: "Notice",
            speakerLabelingGaps: [.init(startSeconds: 1, endSeconds: 2)]
        )
        store.addEntry(result)
        guard let original = store.selectedEntry else { preconditionFailure("Adding a transcript must select it") }
        store.renameEntry(id: original.id, to: "  Weekly review  ")
        guard let renamed = store.selectedEntry else { preconditionFailure("Renaming must retain selection") }
        precondition(renamed.displayTitle == "Weekly review")
        precondition(renamed.fileName == original.fileName && renamed.text == original.text)
        precondition(renamed.speakerSegments == original.speakerSegments && renamed.speakerLabelingGaps == original.speakerLabelingGaps)
        precondition(renamed.timestamp == original.timestamp && renamed.id == original.id)
        precondition(renamed.searchRevision == 2)
        store.renameEntry(id: original.id, to: "  ")
        store.renameEntry(id: UUID(), to: "Stale")
        store.renameEntry(id: original.id, to: renamed.displayTitle)
        precondition(store.selectedEntry == renamed)
        precondition(FileTranscriptionHistoryStore(defaults: defaults).entries == [renamed])
        store.renameEntry(id: original.id, to: "Second title")
        precondition(store.selectedEntry?.searchRevision == 3)
        guard var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(renamed)) as? [String: Any] else {
            preconditionFailure("Encoded transcript must be a JSON object")
        }
        legacy.removeValue(forKey: "customTitle")
        legacy.removeValue(forKey: "searchRevision")
        let decoded = try JSONDecoder().decode(FileTranscriptionEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(decoded.displayTitle == original.fileName && decoded.searchRevision == nil)
        try self.testSpeakerNaming()
        print("PASS: transcript titles and speaker names, persistence, legacy history, reset, stable identities, search revisions, and text/JSON export")
    }

    private static func testSpeakerNaming() throws {
        let defaults = UserDefaults()
        let store = FileTranscriptionHistoryStore(defaults: defaults)
        let segments = [
            SpeakerTranscriptSegment(speaker: "Speaker 1", startSeconds: 0, endSeconds: 1, text: "Speaker 2 helped with the launch."),
            SpeakerTranscriptSegment(speaker: "Speaker 2", startSeconds: 1, endSeconds: 2, text: "Thank you, Speaker 1."),
            SpeakerTranscriptSegment(speaker: "Speaker 1", startSeconds: 2, endSeconds: 3, text: "Résumé 日本語 👋"),
        ]
        let result = TranscriptionResult(
            text: segments.map(\.plainText).joined(separator: "\n\n"),
            confidence: 0.9,
            duration: 3,
            processingTime: 1,
            fileName: "speakers.wav",
            speakerSegments: segments,
            speakerLabelingNotice: "Partial labels",
            speakerLabelingGaps: [.init(startSeconds: 3, endSeconds: 4)]
        )
        store.addEntry(result)
        let original = store.entries[0]
        precondition(original.speakerIdentifiers == ["Speaker 1", "Speaker 2"])
        store.renameSpeakers(entryID: original.id, names: ["Speaker 1": "  Alice  ", "unknown": "Ignored"])
        let named = store.entries[0]
        precondition(named.speakerDisplayName(for: "Speaker 1") == "Alice")
        precondition(named.speakerDisplayName(for: "Speaker 2") == "Speaker 2")
        precondition(named.text == "[0:00] Alice: Speaker 2 helped with the launch.\n\n[0:01] Speaker 2: Thank you, Speaker 1.\n\n[0:02] Alice: Résumé 日本語 👋")
        precondition(named.speakerSegments == segments, "Names must not alter speech, timing, or speaker identities")
        precondition(named.speakerSegments.map(\.id) == original.speakerSegments.map(\.id))
        precondition(named.previewText.contains("Alice") && named.searchRevision == 2)
        precondition(named.timestamp == original.timestamp && named.duration == original.duration && named.id == original.id)
        precondition(named.speakerLabelingNotice == original.speakerLabelingNotice && named.speakerLabelingGaps == original.speakerLabelingGaps)
        precondition(FileTranscriptionHistoryStore(defaults: defaults).entries == [named])

        let exported = named.toTranscriptionResult()
        precondition(exported.speakerSegments.map(\.speaker) == ["Alice", "Speaker 2", "Alice"])
        precondition(exported.textExport.contains(named.text))
        let json = try JSONDecoder.withISO8601Dates.decode(TranscriptionResult.self, from: exported.jsonExport)
        precondition(json.text == named.text && json.speakerSegments == exported.speakerSegments)
        store.renameSpeakers(entryID: original.id, names: ["Speaker 1": "Alice"])
        store.renameSpeakers(entryID: UUID(), names: ["Speaker 1": "Stale"])
        precondition(store.entries[0] == named, "Unchanged names and stale transcripts must be no-ops")

        // Identical display names do not merge diarization identities; either can be renamed again.
        store.renameSpeakers(entryID: original.id, names: ["Speaker 2": "Alice"])
        precondition(store.entries[0].speakerIdentifiers.count == 2)
        store.renameSpeakers(entryID: original.id, names: ["Speaker 2": "Bób"])
        precondition(store.entries[0].speakerDisplayName(for: "Speaker 1") == "Alice")
        precondition(store.entries[0].speakerDisplayName(for: "Speaker 2") == "Bób")
        let backup = store.makeBackupPayload()
        let restored = FileTranscriptionHistoryStore(defaults: UserDefaults())
        restored.restore(from: backup)
        precondition(restored.entries[0].speakerNames == store.entries[0].speakerNames)
        store.renameSpeakers(entryID: original.id, names: ["Speaker 1": " \n ", "Speaker 2": "Speaker 2"])
        precondition(store.entries[0].speakerNames.isEmpty && store.entries[0].text == original.text)

        guard var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any] else {
            preconditionFailure("Encoded transcript must be a JSON object")
        }
        legacy.removeValue(forKey: "speakerNames")
        let decoded = try JSONDecoder().decode(FileTranscriptionEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(decoded.speakerNames.isEmpty && decoded.speakerSegments == segments)
        var plain = FileTranscriptionEntry(fileName: "plain.wav", duration: 1, processingTime: 1, confidence: 1, text: "Untouched")
        precondition(!plain.renameSpeakers(["Speaker 1": "Ignored"]) && plain.text == "Untouched")
    }
}

private extension JSONDecoder {
    static var withISO8601Dates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
