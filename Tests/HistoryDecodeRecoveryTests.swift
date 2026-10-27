import Foundation

// Standalone harness: compile the real chat and file transcription stores against
// in-memory persistence. Never touches the installed app's history.
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { self.values[key] as? Data }
    func string(forKey key: String) -> String? { self.values[key] as? String }
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

@main @MainActor struct HistoryDecodeRecoveryTests {
    static let chatKey = "CommandModeChatSessions"
    static let fileKey = "FileTranscriptionHistoryEntries"

    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        // File transcription history: one unreadable entry between two readable ones.
        let files = (0..<2).map {
            FileTranscriptionEntry(fileName: "meeting\($0).wav", duration: 60, processingTime: 5, confidence: 0.9, text: "Transcript \($0)")
        }
        var unreadableFile = try self.object(files[0])
        unreadableFile["id"] = UUID().uuidString
        unreadableFile["confidence"] = NSNull()
        let fileDefaults = UserDefaults()
        fileDefaults.set(try self.array(files, inserting: unreadableFile), forKey: self.fileKey)
        let fileStore = FileTranscriptionHistoryStore(defaults: fileDefaults)
        check(fileStore.entries == files, "Readable file transcripts must survive one unreadable entry")
        fileStore.addEntry(TranscriptionResult(
            id: UUID(),
            text: "New transcript",
            confidence: 0.8,
            duration: 10,
            processingTime: 1,
            fileName: "new.wav",
            timestamp: Date(),
            speakerSegments: [],
            speakerLabelingNotice: nil,
            speakerLabelingGaps: []
        ))
        let reloadedFiles = FileTranscriptionHistoryStore(defaults: fileDefaults).entries
        check(reloadedFiles.count == 3 && Array(reloadedFiles.dropFirst()) == files, "The next save must keep every readable transcript, newest first")

        // Literal JSON, so no encoder normalizes the inputs: other element shapes and an
        // out-of-range number are skipped or ignored per element.
        // A complete entry that only becomes unreadable because its duration overflows Double.
        let overflowSource = try self.json(FileTranscriptionEntry(fileName: "overflow.wav", duration: 60, processingTime: 5, confidence: 0.9, text: "Overflow"))
        let overflowing = overflowSource.replacingOccurrences(of: #""duration":60"#, with: #""duration":1e400"#)
        check(overflowing != overflowSource, "The overflow fixture must replace the duration")
        check((try? JSONDecoder().decode(FileTranscriptionEntry.self, from: Data(overflowSource.utf8))) != nil, "The overflow fixture is readable before the change")
        let literalDefaults = UserDefaults()
        literalDefaults.set(Data(#"""
        [\#(try self.json(files[0])),"junk",null,\#(overflowing),\#(try self.json(files[1], extra: #""futureField":1e400"#))]
        """#.utf8), forKey: self.fileKey)
        check(FileTranscriptionHistoryStore(defaults: literalDefaults).entries == files, "Readable transcripts survive any mix of unreadable elements")

        let garbageDefaults = UserDefaults()
        garbageDefaults.set(Data("not json".utf8), forKey: self.fileKey)
        check(FileTranscriptionHistoryStore(defaults: garbageDefaults).entries.isEmpty, "Unparseable history loads empty")

        let cleanFileDefaults = UserDefaults()
        let cleanFileBytes = try JSONEncoder().encode(files)
        cleanFileDefaults.set(cleanFileBytes, forKey: self.fileKey)
        check(FileTranscriptionHistoryStore(defaults: cleanFileDefaults).entries == files, "Readable history loads unchanged")
        check(cleanFileDefaults.data(forKey: self.fileKey) == cleanFileBytes, "Loading readable history must not rewrite it")

        // Command Mode chats: the launch save used to rewrite the key with a single new chat.
        let chats = (0..<2).map {
            ChatSession(title: "Chat \($0)", messages: [ChatMessage(role: .user, content: "Hello \($0)")])
        }
        var unreadableChat = try self.object(chats[0])
        let unreadableChatID = UUID().uuidString
        unreadableChat["id"] = unreadableChatID
        guard var messages = unreadableChat["messages"] as? [[String: Any]] else { preconditionFailure("Encoded chat must carry messages") }
        messages[0]["stepType"] = "stepFromANewerVersion"
        unreadableChat["messages"] = messages
        let chatDefaults = UserDefaults()
        chatDefaults.set(try self.array(chats, inserting: unreadableChat), forKey: self.chatKey)
        chatDefaults.set(unreadableChatID, forKey: "CommandModeCurrentChatID")
        let chatStore = ChatHistoryStore(defaults: chatDefaults)
        check(chatStore.sessions.map(\.id) == chats.map(\.id), "Readable chats must survive one unreadable chat")
        check(chats.contains { $0.id == chatStore.currentChatID }, "A missing current chat falls back to a readable one")
        let savedChats = try JSONDecoder().decode([ChatSession].self, from: chatDefaults.data(forKey: self.chatKey) ?? Data())
        check(savedChats.map(\.id) == chats.map(\.id), "The launch save must keep every readable chat")

        let cleanChatDefaults = UserDefaults()
        let cleanChatBytes = try JSONEncoder().encode(chats)
        cleanChatDefaults.set(cleanChatBytes, forKey: self.chatKey)
        cleanChatDefaults.set(chats[1].id, forKey: "CommandModeCurrentChatID")
        let cleanChatStore = ChatHistoryStore(defaults: cleanChatDefaults)
        check(cleanChatStore.sessions == chats && cleanChatStore.currentChatID == chats[1].id, "Readable chats load unchanged")
        check(cleanChatDefaults.data(forKey: self.chatKey) == cleanChatBytes, "Loading readable chats must not rewrite them")

        print("History decode recovery: \(checks) checks passed")
    }

    static func object(_ value: some Encodable) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
            preconditionFailure("Encoded history entry must be a JSON object")
        }
        return object
    }

    static func json(_ value: some Encodable, extra: String? = nil) throws -> String {
        guard let text = String(bytes: try JSONEncoder().encode(value), encoding: .utf8) else {
            preconditionFailure("Encoded history entry must be UTF-8")
        }
        guard let extra else { return text }
        return String(text.dropLast()) + "," + extra + "}"
    }

    static func array(_ values: [some Encodable], inserting unreadable: [String: Any]) throws -> Data {
        guard var array = try JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as? [Any] else {
            preconditionFailure("Encoded history must be a JSON array")
        }
        array.insert(unreadable, at: 1)
        return try JSONSerialization.data(withJSONObject: array)
    }
}
