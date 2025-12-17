import Combine
import Foundation

// MARK: - Chat Message Model (Codable version of CommandModeService.Message)

struct ChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let toolCall: ToolCall?
    let stepType: StepType
    let timestamp: Date

    enum Role: String, Codable, Equatable {
        case user
        case assistant
        case tool
    }

    enum StepType: String, Codable, Equatable {
        case normal
        case thinking
        case checking
        case executing
        case verifying
        case success
        case failure
    }

    struct ToolCall: Codable, Equatable {
        let id: String
        let command: String
        let workingDirectory: String?
        let purpose: String?
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        toolCall: ToolCall? = nil,
        stepType: StepType = .normal,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCall = toolCall
        self.stepType = stepType
        self.timestamp = timestamp
    }
}

// MARK: - Chat Session Model

struct ChatSession: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

    init(
        id: String = UUID().uuidString,
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    /// Generate title from first user message (max 50 chars)
    mutating func updateTitleFromFirstMessage() {
        guard let firstUserMessage = messages.first(where: { $0.role == .user }) else { return }
        let content = firstUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.count > 50 {
            self.title = String(content.prefix(47)) + "..."
        } else {
            self.title = content.isEmpty ? "New Chat" : content
        }
    }

    /// Relative time string for display
    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self.updatedAt, relativeTo: Date())
    }
}

// MARK: - Chat History Store

@MainActor
final class ChatHistoryStore: ObservableObject {
    static let shared = ChatHistoryStore()

    private let defaults = UserDefaults.standard
    private let maxChats = 30

    private enum Keys {
        static let chatSessions = "CommandModeChatSessions"
        static let currentChatID = "CommandModeCurrentChatID"
    }

    @Published private(set) var sessions: [ChatSession] = []
    @Published var currentChatID: String?

    private init() {
        self.loadSessions()

        // Ensure there's always a current chat
        if self.currentChatID == nil || self.sessions.first(where: { $0.id == currentChatID }) == nil {
            if let first = sessions.first {
                self.currentChatID = first.id
            } else {
                // Create initial chat
                let newChat = ChatSession()
                self.sessions = [newChat]
                self.currentChatID = newChat.id
                self.saveSessions()
            }
        }
    }

    // MARK: - Public Methods

    /// Get the current active chat session
    var currentSession: ChatSession? {
        guard let id = currentChatID else { return nil }
        return self.sessions.first(where: { $0.id == id })
    }

    /// Get recent chats for dropdown (excluding current, sorted by updatedAt)
    func getRecentChats(excludingCurrent: Bool = true) -> [ChatSession] {
        var result = self.sessions.sorted { $0.updatedAt > $1.updatedAt }
        if excludingCurrent, let currentID = currentChatID {
            result = result.filter { $0.id != currentID }
        }
        return result
    }

    /// Create a new chat and set it as current
    @discardableResult
    func createNewChat() -> ChatSession {
        let newChat = ChatSession()
        self.sessions.insert(newChat, at: 0)
        self.currentChatID = newChat.id

        // Trim old chats if over limit
        self.trimOldChats()
        self.saveSessions()

        return newChat
    }

    /// Save/update a chat session
    func saveChat(_ session: ChatSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            var updated = session
            updated.updatedAt = Date()
            self.sessions[index] = updated
        } else {
            var updated = session
            updated.updatedAt = Date()
            self.sessions.insert(updated, at: 0)
        }

        self.trimOldChats()
        self.saveSessions()
    }

    /// Update current chat with messages
    func updateCurrentChat(messages: [ChatMessage]) {
        guard let id = currentChatID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        var session = self.sessions[index]
        session.messages = messages
        session.updatedAt = Date()
        session.updateTitleFromFirstMessage()
        self.sessions[index] = session

        self.saveSessions()
    }

    /// Load a chat by ID and set as current
    func loadChat(id: String) -> ChatSession? {
        guard let session = sessions.first(where: { $0.id == id }) else { return nil }
        self.currentChatID = id
        self.saveCurrentChatID()
        return session
    }

    /// Switch to a different chat
    func switchToChat(id: String) -> ChatSession? {
        return self.loadChat(id: id)
    }

    /// Delete a chat by ID
    func deleteChat(id: String) {
        self.sessions.removeAll { $0.id == id }

        // If deleted current chat, switch to most recent or create new
        if self.currentChatID == id {
            if let first = sessions.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                self.currentChatID = first.id
            } else {
                // No chats left, create new
                let newChat = self.createNewChat()
                self.currentChatID = newChat.id
            }
        }

        self.saveSessions()
    }

    /// Delete current chat and switch to next
    func deleteCurrentChat() {
        guard let id = currentChatID else { return }
        self.deleteChat(id: id)
    }

    /// Clear current chat (delete messages but keep session)
    func clearCurrentChat() {
        guard let id = currentChatID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }

        self.sessions[index].messages = []
        self.sessions[index].title = "New Chat"
        self.sessions[index].updatedAt = Date()

        self.saveSessions()
    }

    // MARK: - Private Methods

    private func loadSessions() {
        guard let data = defaults.data(forKey: Keys.chatSessions),
              let decoded = try? JSONDecoder().decode([ChatSession].self, from: data)
        else {
            self.sessions = []
            return
        }
        self.sessions = decoded

        // Load current chat ID
        self.currentChatID = self.defaults.string(forKey: Keys.currentChatID)
    }

    private func saveSessions() {
        if let encoded = try? JSONEncoder().encode(sessions) {
            self.defaults.set(encoded, forKey: Keys.chatSessions)
        }
        self.saveCurrentChatID()
        objectWillChange.send()
    }

    private func saveCurrentChatID() {
        self.defaults.set(self.currentChatID, forKey: Keys.currentChatID)
    }

    private func trimOldChats() {
        if self.sessions.count > self.maxChats {
            // Sort by updatedAt and keep most recent
            let sorted = self.sessions.sorted { $0.updatedAt > $1.updatedAt }
            self.sessions = Array(sorted.prefix(self.maxChats))
        }
    }
}
