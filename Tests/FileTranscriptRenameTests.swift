import Foundation

// Standalone harness: compile the real store against in-memory persistence and
// inert transcription dependencies. Never touches the installed app's history.
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { self.values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { self.values[key] = value }
}

struct SpeakerTranscriptSegment: Codable, Equatable { let text: String }
struct SpeakerTranscriptGap: Codable, Equatable { let text: String }
struct TranscriptionResult {
    let id: UUID
    let text: String
    let confidence: Float
    let duration: TimeInterval
    let processingTime: TimeInterval
    let fileName: String
    let timestamp: Date
    let speakerSegments: [SpeakerTranscriptSegment]
    let speakerLabelingNotice: String?
    let speakerLabelingGaps: [SpeakerTranscriptGap]
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
            speakerSegments: [.init(text: "Speaker text")],
            speakerLabelingNotice: "Notice",
            speakerLabelingGaps: [.init(text: "Gap")]
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
        print("File transcript rename: 9 checks passed")
    }
}
