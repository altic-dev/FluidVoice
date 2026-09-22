//
//  ChatHistoryStore.swift
//  Fluid
//
//  Persistence manager for Command Mode chat history
//

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

    init(id: UUID = UUID(), role: Role, content: String, toolCall: ToolCall? = nil, stepType: StepType = .normal, timestamp: Date = Date()) {
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
    var hasCustomTitle: Bool = false
    let createdAt: Date
    var updatedAt: Date
    var searchRevision: UInt64?
    var isArchived: Bool
    var messages: [ChatMessage]

    private enum CodingKeys: String, CodingKey {
        case id, title, hasCustomTitle, createdAt, updatedAt, searchRevision, isArchived, messages
    }

    init(
        id: String = UUID().uuidString,
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        searchRevision: UInt64? = nil,
        isArchived: Bool = false,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.searchRevision = searchRevision
        self.isArchived = isArchived
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.hasCustomTitle = try container.decodeIfPresent(Bool.self, forKey: .hasCustomTitle) ?? false
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.searchRevision = try container.decodeIfPresent(UInt64.self, forKey: .searchRevision)
        self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.messages = try container.decode([ChatMessage].self, forKey: .messages)
    }

    mutating func markUpdated(at date: Date = Date()) {
        let timestampRevision = UInt64(max(1, self.updatedAt.timeIntervalSince1970 * 1000))
        let previousRevision = max(self.searchRevision ?? timestampRevision, timestampRevision)
        self.searchRevision = previousRevision == .max ? .max : previousRevision + 1
        self.updatedAt = date
    }

    /// Generate title from first user message (max 50 chars)
    mutating func updateTitleFromFirstMessage() {
        guard !self.hasCustomTitle else { return }
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
    static let maxArchivedChats = 30

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

        // Archived sessions remain saved, but cannot become the active conversation on launch.
        if self.currentSession == nil {
            self.selectMostRecentActiveChat()
            self.saveSessions()
        }
    }

    // MARK: - Public Methods

    /// Get the current active chat session
    var currentSession: ChatSession? {
        guard let id = currentChatID else { return nil }
        return self.sessions.first(where: { $0.id == id && !$0.isArchived })
    }

    /// Get recent chats for dropdown (excluding current, sorted by updatedAt)
    func getRecentChats(excludingCurrent: Bool = true) -> [ChatSession] {
        var result = self.sessions.filter { !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
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
        if session.isArchived,
           !self.sessions.contains(where: { $0.id == session.id && $0.isArchived }),
           self.sessions.filter(\.isArchived).count >= Self.maxArchivedChats
        {
            return
        }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            var updated = session
            updated.markUpdated()
            self.sessions[index] = updated
        } else {
            var updated = session
            updated.markUpdated()
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
        session.markUpdated()
        session.updateTitleFromFirstMessage()
        self.sessions[index] = session

        self.saveSessions()
    }

    /// Rename only metadata; preserve selection, messages, archive state and ordering.
    func renameChat(id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = self.sessions.firstIndex(where: { $0.id == id }),
              self.sessions[index].title != trimmed else { return }
        self.sessions[index].title = trimmed
        self.sessions[index].hasCustomTitle = true
        let date = self.sessions[index].updatedAt
        self.sessions[index].markUpdated(at: date)
        self.saveSessions()
    }

    /// Load a chat by ID and set as current
    func loadChat(id: String) -> ChatSession? {
        guard let session = sessions.first(where: { $0.id == id && !$0.isArchived }) else { return nil }
        self.currentChatID = id
        self.saveCurrentChatID()
        return session
    }

    /// Switch to a different chat
    func switchToChat(id: String) -> ChatSession? {
        return self.loadChat(id: id)
    }

    /// Archives never expire implicitly; at capacity, restore one before archiving another.
    @discardableResult
    func archiveChat(id: String) -> Bool {
        guard let index = self.sessions.firstIndex(where: { $0.id == id && !$0.isArchived }),
              self.sessions.filter(\.isArchived).count < Self.maxArchivedChats else { return false }
        self.sessions[index].isArchived = true
        // A restored search record must be newer than its deletion tombstone, without reordering history.
        let updatedAt = self.sessions[index].updatedAt
        self.sessions[index].markUpdated(at: updatedAt)
        if self.currentChatID == id { self.selectMostRecentActiveChat() }
        self.trimOldChats()
        self.saveSessions()
        return true
    }

    /// Restoring preserves conversation dates and does not change the selected session.
    @discardableResult
    func restoreChat(id: String) -> Bool {
        guard let index = self.sessions.firstIndex(where: { $0.id == id && $0.isArchived }) else { return false }
        self.sessions[index].isArchived = false
        let updatedAt = self.sessions[index].updatedAt
        self.sessions[index].markUpdated(at: updatedAt)
        self.trimOldChats(preservingID: id)
        self.saveSessions()
        return true
    }

    /// Delete a chat by ID
    func deleteChat(id: String) {
        guard self.sessions.contains(where: { $0.id == id }) else { return }
        self.sessions.removeAll { $0.id == id }

        // If deleted current chat, switch to most recent or create new
        if self.currentChatID == id {
            self.selectMostRecentActiveChat()
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
        self.sessions[index].hasCustomTitle = false
        self.sessions[index].markUpdated()

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

    private func selectMostRecentActiveChat() {
        if let recent = self.getRecentChats(excludingCurrent: false).first {
            self.currentChatID = recent.id
        } else {
            let newChat = ChatSession()
            self.sessions.insert(newChat, at: 0)
            self.currentChatID = newChat.id
        }
    }

    private func trimOldChats(preservingID: String? = nil) {
        let active = self.sessions.filter { !$0.isArchived }
        guard active.count > self.maxChats else { return }
        // Retain archives independently; new sessions only trim the 30-session active budget.
        let protected = active.filter { $0.id == self.currentChatID || $0.id == preservingID }
        let candidates = active.filter { $0.id != self.currentChatID && $0.id != preservingID }
            .sorted { $0.updatedAt > $1.updatedAt }
        let retainedIDs = Set((protected + candidates.prefix(self.maxChats - protected.count)).map(\.id))
        self.sessions.removeAll { !$0.isArchived && !retainedIDs.contains($0.id) }
    }
}
