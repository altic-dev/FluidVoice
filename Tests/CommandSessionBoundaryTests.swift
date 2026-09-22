import Foundation

// This shadows Foundation.UserDefaults for the exact production store compiled by the script.
// No app history, terminal, model, or installed app is accessed.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    var writes = 0
    var writtenKeys: [String] = []
    func data(forKey key: String) -> Data? { self.values[key] as? Data }
    func string(forKey key: String) -> String? { self.values[key] as? String }
    func set(_ value: Any?, forKey key: String) {
        self.values[key] = value
        self.writes += 1
        self.writtenKeys.append(key)
    }
}

struct TerminalService {}

@MainActor final class NotchOverlayManager {
    static let shared = NotchOverlayManager()
    var shouldSyncCommandConversationToNotch = true
}

@MainActor final class NotchContentState {
    struct CommandOutputMessage: Equatable {
        enum Role { case user, assistant, status }
        let role: Role
        let content: String
    }

    static let shared = NotchContentState()
    var messages: [CommandOutputMessage] = []
    var clears = 0
    var refreshes = 0
    func clearCommandOutput() {
        self.messages = []
        self.clears += 1
    }

    func addCommandMessage(role: CommandOutputMessage.Role, content: String) {
        self.messages.append(.init(role: role, content: content))
    }

    func refreshRecentChats() { self.refreshes += 1 }
}

struct TransientState: Equatable {
    var pendingID: String?
    var currentTurnCount = 0
    var currentStep: CommandModeService.AgentStep?
    var streamingText = ""
    var streamingThinkingText = ""
    var streamingBuffer: [String] = []
    var thinkingBuffer: [String] = []
    var lastUIUpdate: CFAbsoluteTime = 0
    var lastThinkingUIUpdate: CFAbsoluteTime = 0
}

@MainActor private struct SessionSnapshot: Equatable {
    let currentID: String?
    let conversation: [CommandModeService.Message]
    let transient: TransientState
    let isProcessing: Bool
    let sessions: [ChatSession]
    let storeCurrentID: String?
    let writes: Int
    let notchMessages: [NotchContentState.CommandOutputMessage]
    let notchClears: Int
    let notchRefreshes: Int

    init(_ service: CommandModeService) {
        self.currentID = service.currentChatID
        self.conversation = service.conversationHistory
        self.transient = service.transientStateForTests
        self.isProcessing = service.isProcessing
        self.sessions = ChatHistoryStore.shared.sessions
        self.storeCurrentID = ChatHistoryStore.shared.currentChatID
        self.writes = UserDefaults.standard.writes
        self.notchMessages = NotchContentState.shared.messages
        self.notchClears = NotchContentState.shared.clears
        self.notchRefreshes = NotchContentState.shared.refreshes
    }
}

@main @MainActor enum CommandSessionBoundaryTests {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        self.checks += 1
    }

    static func fixture() -> CommandModeService {
        let sessions = ["active", "recent", "older"].enumerated().map { index, id in
            ChatSession(
                id: id,
                title: id,
                updatedAt: Date(timeIntervalSince1970: Double(300 - index * 100)),
                messages: [.init(role: .user, content: "\(id) saved message")]
            )
        }
        ChatHistoryStore.shared.resetForTests(sessions: sessions, currentChatID: "active")
        UserDefaults.standard.values = [:]
        UserDefaults.standard.writes = 0
        UserDefaults.standard.writtenKeys = []
        NotchOverlayManager.shared.shouldSyncCommandConversationToNotch = true
        let service = CommandModeService()
        service.conversationHistory.append(.init(role: .assistant, content: "unsaved active answer"))
        service.seedTransientStateForTests()
        NotchContentState.shared.addCommandMessage(role: .assistant, content: "active notch answer")
        return service
    }

    static func main() throws {
        self.deletingAnotherSessionPreservesCurrent()
        self.deletingCurrentResetsAndLoadsNext()
        self.deletingLastSessionCreatesEmptyChat()
        self.activeWorkBlocksSessionMutations()
        self.invalidAndRepeatedActionsAreNoOps()
        self.switchingAndCreatingResetTransientState()
        self.sessionChangesRespectNotchRouting()
        self.browsingDoesNotRewriteHistory()
        self.semanticMessageChangesStillPersist()
        self.appendedCancellationPersistsOnSwitch()
        try self.archiveMigrationAndRoundTrip()
        self.archivingCurrentPreservesMessagesAndLoadsNext()
        self.archivingAnotherAndRestoringPreserveCurrent()
        self.archiveOperationsRejectBlockedAndStaleActions()
        self.deletingCurrentNeverSelectsAnArchive()
        self.archivesHaveAnIndependentBoundedBudget()
        try self.launchWithOnlyArchivesKeepsThemAndCreatesActiveChat()
        print("Command session boundary: \(self.checks) checks passed")
    }

    static func deletingAnotherSessionPreservesCurrent() {
        let service = self.fixture()
        let before = SessionSnapshot(service)
        self.check(service.deleteChat(id: "older"), "An inactive saved session can be deleted")
        let after = SessionSnapshot(service)
        self.check(after.currentID == before.currentID && after.storeCurrentID == before.storeCurrentID, "Deleting another session preserves both active IDs")
        self.check(after.conversation == before.conversation && after.transient == before.transient, "Deleting another session preserves unsaved messages, steps, and streaming state")
        self.check(ChatHistoryStore.shared.currentSession == before.sessions.first { $0.id == "active" }, "Deleting another session cannot save, retitle, or reorder the active chat")
        self.check(!after.sessions.contains { $0.id == "older" } && after.sessions.count == 2, "Only the requested session is removed")
        self.check(after.notchMessages == before.notchMessages && after.notchClears == before.notchClears, "Inactive deletion does not clear or repopulate notch output")
        self.check(after.notchRefreshes == before.notchRefreshes + 1 && after.writes > before.writes, "Deletion refreshes history and persists the removal")
    }

    static func deletingCurrentResetsAndLoadsNext() {
        let service = self.fixture()
        service.deleteCurrentChat()
        self.check(service.currentChatID == "recent" && ChatHistoryStore.shared.currentChatID == "recent", "Current delete forwards and selects the most recently updated remaining session")
        self.check(service.conversationHistory.map(\.content) == ["recent saved message"], "The next session replaces the deleted conversation")
        self.check(service.transientStateForTests == TransientState(), "Current deletion clears step, turn limit, pending command, and all streaming state")
        self.check(!ChatHistoryStore.shared.sessions.contains { $0.id == "active" }, "Deleting current does not save or resurrect it")
        self.check(NotchContentState.shared.messages.map(\.content) == ["recent saved message"], "Notch output follows the new active conversation")
    }

    static func deletingLastSessionCreatesEmptyChat() {
        let service = self.fixture()
        self.check(service.deleteChat(id: "older") && service.deleteChat(id: "recent"), "Other sessions can be removed in sequence")
        self.check(service.deleteChat(id: "active"), "The final existing session can be deleted")
        self.check(ChatHistoryStore.shared.sessions.count == 1 && service.currentChatID != "active", "Deleting the final session creates one replacement")
        self.check(service.currentChatID == ChatHistoryStore.shared.currentChatID, "Service and store agree on the replacement ID")
        self.check(service.conversationHistory.isEmpty && service.transientStateForTests == TransientState(), "The replacement starts empty without stale progress")
        self.check(NotchContentState.shared.messages.isEmpty, "Deleted messages disappear from notch output")
    }

    static func activeWorkBlocksSessionMutations() {
        for pendingApproval in [false, true] {
            let service = self.fixture()
            if pendingApproval {
                service.pendingCommand = .init(id: "approval", command: "test command", workingDirectory: nil, purpose: "test")
            } else {
                service.isProcessing = true
            }
            let before = SessionSnapshot(service)
            service.createNewChat()
            self.check(!service.switchToChat(id: "recent"), "Session switching is blocked while work or approval is pending")
            self.check(!service.deleteChat(id: "older"), "Inactive deletion is blocked while work or approval is pending")
            self.check(!service.deleteChat(id: "active"), "Active deletion is blocked while work or approval is pending")
            service.deleteCurrentChat()
            self.check(SessionSnapshot(service) == before, "Blocked actions preserve every conversation, pending command, streaming state, persistence write count, and notch state")
        }
    }

    static func invalidAndRepeatedActionsAreNoOps() {
        let service = self.fixture()
        let before = SessionSnapshot(service)
        for id in ["missing", "", "missing"] {
            self.check(!service.switchToChat(id: id), "A missing target cannot switch or save the active conversation")
            self.check(!service.deleteChat(id: id), "A missing target cannot delete or refresh history")
        }
        self.check(service.switchToChat(id: "active"), "Selecting the current session is successful without reloading")
        self.check(SessionSnapshot(service) == before, "Invalid and repeated selection have no writes, output resets, or transient changes")
        self.check(service.deleteChat(id: "older"), "Initial delete succeeds")
        let afterDelete = SessionSnapshot(service)
        self.check(!service.deleteChat(id: "older") && !service.switchToChat(id: "older"), "Repeated stale row actions are rejected")
        self.check(SessionSnapshot(service) == afterDelete, "Repeated stale row actions preserve the selected session")
    }

    static func switchingAndCreatingResetTransientState() {
        let service = self.fixture()
        self.check(service.switchToChat(id: "recent"), "An existing session can be selected")
        self.check(service.currentChatID == "recent" && service.conversationHistory.map(\.content) == ["recent saved message"], "Selecting loads exactly the requested conversation")
        self.check(service.transientStateForTests == TransientState(), "Selecting clears old steps and streaming state")
        self.check(ChatHistoryStore.shared.sessions.first { $0.id == "active" }?.messages.last?.content == "unsaved active answer", "Selecting preserves the outgoing conversation through a save")
        service.seedTransientStateForTests()
        service.createNewChat()
        self.check(service.currentChatID == ChatHistoryStore.shared.currentChatID && service.currentChatID != "recent", "New session changes both current IDs")
        self.check(service.conversationHistory.isEmpty && service.transientStateForTests == TransientState(), "New sessions start without previous output or progress")
        self.check(ChatHistoryStore.shared.sessions.contains { $0.id == "recent" }, "New sessions preserve previous saved conversations")
    }

    static func sessionChangesRespectNotchRouting() {
        let service = self.fixture()
        NotchOverlayManager.shared.shouldSyncCommandConversationToNotch = false
        let before = SessionSnapshot(service)
        self.check(service.deleteChat(id: "active"), "Active session deletion is independent of the overlay selection")
        self.check(NotchContentState.shared.messages == before.notchMessages && NotchContentState.shared.clears == before.notchClears, "Loading the next session respects existing notch routing and does not clear another overlay domain")
    }

    static func browsingDoesNotRewriteHistory() {
        let service = self.fixture()
        service.conversationHistory.removeLast()
        let before = ChatHistoryStore.shared.sessions
        self.check(service.conversationHistory.first?.id != before.first?.messages.first?.id, "The fixture exercises regenerated display message IDs")
        service.saveCurrentChat()
        self.check(UserDefaults.standard.writes == 0, "Saving a restored, unchanged conversation performs no persistence writes")
        for id in ["recent", "older", "active", "recent", "active"] {
            self.check(service.switchToChat(id: id), "Browsing can select another saved session")
            self.check(ChatHistoryStore.shared.sessions == before, "Browsing preserves message IDs, timestamps, updatedAt, and searchRevision for every session")
        }
        self.check(UserDefaults.standard.writtenKeys == Array(repeating: "CommandModeCurrentChatID", count: 5), "Browsing persists only the selected ID, without rewriting or reordering session history")
        let writesBefore = UserDefaults.standard.writes
        service.saveCurrentChat()
        self.check(UserDefaults.standard.writes == writesBefore, "Repeated unchanged saves remain write-free")
    }

    static func semanticMessageChangesStillPersist() {
        typealias Message = CommandModeService.Message
        let tool = Message.ToolCall(id: "tool", command: "pwd", workingDirectory: "/tmp", purpose: "Inspect location")
        let changes: [(String, Message)] = [
            ("role", .init(role: .tool, content: "original", toolCall: tool, stepType: .checking)),
            ("content", .init(role: .assistant, content: "updated", toolCall: tool, stepType: .checking)),
            ("step", .init(role: .assistant, content: "original", toolCall: tool, stepType: .success)),
            ("tool ID", .init(role: .assistant, content: "original", toolCall: .init(id: "other", command: "pwd", workingDirectory: "/tmp", purpose: "Inspect location"), stepType: .checking)),
            ("command", .init(role: .assistant, content: "original", toolCall: .init(id: "tool", command: "ls", workingDirectory: "/tmp", purpose: "Inspect location"), stepType: .checking)),
            ("directory", .init(role: .assistant, content: "original", toolCall: .init(id: "tool", command: "pwd", workingDirectory: "/var", purpose: "Inspect location"), stepType: .checking)),
            ("purpose", .init(role: .assistant, content: "original", toolCall: .init(id: "tool", command: "pwd", workingDirectory: "/tmp", purpose: "Updated purpose"), stepType: .checking)),
            ("removed tool", .init(role: .assistant, content: "original", stepType: .checking)),
        ]
        for (name, replacement) in changes {
            let service = self.fixture()
            service.conversationHistory = [.init(role: .assistant, content: "original", toolCall: tool, stepType: .checking)]
            service.saveCurrentChat()
            let before = ChatHistoryStore.shared.currentSession
            let writesBefore = UserDefaults.standard.writes
            service.conversationHistory = [replacement]
            service.saveCurrentChat()
            let after = ChatHistoryStore.shared.currentSession
            self.check(UserDefaults.standard.writes > writesBefore, "A changed \(name) still persists even when message count is unchanged")
            self.check(after?.searchRevision != before?.searchRevision, "A changed \(name) updates the search revision")
            self.check(after?.messages.first?.content == replacement.content && after?.messages.first?.toolCall?.command == replacement.toolCall?.command, "The changed \(name) is saved rather than discarded")
            let writesAfter = UserDefaults.standard.writes
            service.saveCurrentChat()
            self.check(UserDefaults.standard.writes == writesAfter, "Repeating the same \(name) save does not produce another history write")
        }
        let service = self.fixture()
        service.saveCurrentChat()
        let writesBefore = UserDefaults.standard.writes
        service.conversationHistory.removeLast()
        service.saveCurrentChat()
        self.check(UserDefaults.standard.writes > writesBefore && ChatHistoryStore.shared.currentSession?.messages.count == 1, "Removing a message remains a persisted edit")
    }

    static func appendedCancellationPersistsOnSwitch() {
        let service = self.fixture()
        service.conversationHistory.removeLast()
        // This is the message appended by cancelPendingCommand; no model or terminal call is needed.
        service.conversationHistory.append(.init(role: .assistant, content: "Command cancelled.", stepType: .failure))
        self.check(service.switchToChat(id: "recent"), "A resolved approval permits switching")
        let saved = ChatHistoryStore.shared.sessions.first { $0.id == "active" }
        self.check(saved?.messages.last?.content == "Command cancelled." && saved?.messages.last?.stepType == .failure, "Switching preserves the appended cancellation message")
        self.check(saved?.searchRevision != nil, "The cancellation is an actual edit and advances the stored revision")
    }

    static func archiveMigrationAndRoundTrip() throws {
        let legacy = ChatSession(id: "legacy", title: "Old conversation", messages: [.init(role: .user, content: "Keep my message")])
        let data = try JSONEncoder().encode(legacy)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("Encoded session must be a JSON object")
        }
        object.removeValue(forKey: "isArchived")
        let decoded = try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: object))
        self.check(decoded == legacy && !decoded.isArchived, "Legacy sessions without the new archive field decode as active without losing fields")
        let service = self.fixture()
        self.check(service.archiveChat(id: "older"), "An existing session can be archived before persistence roundtrip")
        let expected = ChatHistoryStore.shared.sessions
        let encoded = try JSONEncoder().encode(expected)
        try self.check(JSONDecoder().decode([ChatSession].self, from: encoded) == expected, "Archive state, conversation data, and dates survive Codable roundtrip")
        let reloaded = ChatHistoryStore.reloadedForTests()
        self.check(reloaded.sessions == expected && reloaded.currentChatID == "active", "A new store instance restores archived sessions and selection from persisted data")
        self.check(!reloaded.getRecentChats(excludingCurrent: false).contains { $0.isArchived }, "Notch and recent-chat consumers receive only active sessions")
    }

    static func archivingCurrentPreservesMessagesAndLoadsNext() {
        let service = self.fixture()
        self.check(service.archiveChat(id: "active"), "The current conversation can be archived")
        let archived = ChatHistoryStore.shared.sessions.first { $0.id == "active" }
        self.check(archived?.isArchived == true && archived?.messages.last?.content == "unsaved active answer", "Archiving current saves pending conversation edits before moving it")
        self.check(service.currentChatID == "recent" && ChatHistoryStore.shared.currentChatID == "recent", "Archiving current selects the latest remaining active conversation")
        self.check(service.transientStateForTests == TransientState() && service.conversationHistory.map(\.content) == ["recent saved message"], "The new active conversation has its own messages without old streaming or turn state")
        self.check(NotchContentState.shared.messages.map(\.content) == ["recent saved message"], "Notch follows the replacement active conversation")
        self.check(service.archiveChat(id: "older") && service.archiveChat(id: "recent"), "All original sessions can be archived")
        self.check(ChatHistoryStore.shared.sessions.filter(\.isArchived).count == 3, "Archiving the last active conversation preserves every archive")
        self.check(ChatHistoryStore.shared.currentSession?.isArchived == false && service.conversationHistory.isEmpty, "Archiving the last active conversation creates a blank active session")
        self.check(service.currentChatID == ChatHistoryStore.shared.currentChatID, "Replacement active selection stays synchronized")
    }

    static func archivingAnotherAndRestoringPreserveCurrent() {
        let service = self.fixture()
        let before = SessionSnapshot(service)
        let original = ChatHistoryStore.shared.sessions.first { $0.id == "older" }
        self.check(service.archiveChat(id: "older"), "Another conversation can be archived")
        let archived = ChatHistoryStore.shared.sessions.first { $0.id == "older" }
        self.check(archived?.messages == original?.messages && archived?.updatedAt == original?.updatedAt, "Archiving another conversation preserves messages and browsing date")
        self.check(ChatHistoryStore.shared.currentSession == before.sessions.first { $0.id == "active" }, "Archiving another conversation does not save or reorder the active conversation")
        self.check(
            service.currentChatID == before.currentID && service.conversationHistory == before.conversation && service.transientStateForTests == before.transient,
            "Archiving another conversation preserves active IDs, unsaved messages, and transient state"
        )
        self.check(NotchContentState.shared.messages == before.notchMessages && NotchContentState.shared.clears == before.notchClears, "Archiving another conversation leaves notch output intact")
        self.check(service.restoreChat(id: "older"), "An archived conversation can be restored")
        let restored = ChatHistoryStore.shared.sessions.first { $0.id == "older" }
        self.check(restored?.isArchived == false && restored?.messages == original?.messages && restored?.updatedAt == original?.updatedAt, "Restore preserves original conversation messages and date")
        self.check((restored?.searchRevision ?? 0) > (archived?.searchRevision ?? 0), "Restore advances the search revision past the archived record's tombstone without changing the browsing date")
        self.check(service.currentChatID == before.currentID && service.conversationHistory == before.conversation && service.transientStateForTests == before.transient, "Restore alone never changes selection or current progress")
        self.check(service.switchToChat(id: "older"), "The UI may explicitly select a restored conversation")
    }

    static func archiveOperationsRejectBlockedAndStaleActions() {
        for pendingApproval in [false, true] {
            let service = self.fixture()
            self.check(service.archiveChat(id: "older"), "Seed an archive before checking blocked actions")
            if pendingApproval {
                service.pendingCommand = .init(id: "approval", command: "test command", workingDirectory: nil, purpose: nil)
            } else {
                service.isProcessing = true
            }
            let before = SessionSnapshot(service)
            self.check(!service.archiveChat(id: "active") && !service.archiveChat(id: "recent") && !service.restoreChat(id: "older"), "Processing and pending approvals block archive and restore")
            self.check(SessionSnapshot(service) == before, "Blocked archive actions have no persistence, active conversation, or notch side effects")
        }
        let service = self.fixture()
        let before = SessionSnapshot(service)
        for id in ["missing", "", "missing"] {
            self.check(!service.archiveChat(id: id) && !service.restoreChat(id: id), "Missing archive and restore IDs are rejected")
        }
        self.check(!service.restoreChat(id: "active") && SessionSnapshot(service) == before, "Restoring an already active session is a complete no-op")
        self.check(service.archiveChat(id: "older"), "Initial archive succeeds")
        let after = SessionSnapshot(service)
        self.check(!service.archiveChat(id: "older") && !service.switchToChat(id: "older"), "Duplicate archive and direct archived selection are rejected")
        self.check(SessionSnapshot(service) == after, "Stale archive row actions do not save the active session or update output")
        self.check(service.restoreChat(id: "older"), "Initial restore succeeds")
        let restored = SessionSnapshot(service)
        self.check(!service.restoreChat(id: "older") && SessionSnapshot(service) == restored, "Duplicate restore is a complete no-op")
    }

    static func archivesHaveAnIndependentBoundedBudget() {
        let archives = (0..<30).map { index in
            ChatSession(id: "archive-\(index)", updatedAt: Date(timeIntervalSince1970: Double(index)), isArchived: true, messages: [.init(role: .user, content: "Archived \(index)")])
        }
        let active = (0..<30).map { index in
            ChatSession(id: "active-\(index)", updatedAt: Date(timeIntervalSince1970: Double(index + 100)), messages: [.init(role: .user, content: "Active \(index)")])
        }
        ChatHistoryStore.shared.resetForTests(sessions: active + archives, currentChatID: "active-29")
        let service = CommandModeService()
        service.conversationHistory.append(.init(role: .assistant, content: "unsaved at capacity"))
        let before = SessionSnapshot(service)
        self.check(!service.archiveChat(id: "active-29") && !service.archiveChat(id: "active-0"), "Archive capacity rejects both current and other-session archive requests")
        self.check(SessionSnapshot(service) == before, "A full archive causes no save, trim, selection, or notch mutation")
        for _ in 0..<40 {
            service.createNewChat()
        }
        self.check(ChatHistoryStore.shared.sessions.count == 60, "Retention is bounded to 30 active plus 30 archived sessions")
        self.check(ChatHistoryStore.shared.sessions.filter(\.isArchived) == archives, "Routine new-chat trimming never removes or rewrites archived conversations")
        let currentID = service.currentChatID
        self.check(service.restoreChat(id: "archive-0"), "The oldest archive can be restored when active history is full")
        self.check(ChatHistoryStore.shared.sessions.filter { !$0.isArchived }.count == 30, "Restoring trims only the active-session budget")
        self.check(ChatHistoryStore.shared.sessions.contains { $0.id == "archive-0" && !$0.isArchived }, "The restored session is protected even when its date is older than every active conversation")
        self.check(service.currentChatID == currentID && ChatHistoryStore.shared.currentChatID == currentID, "Restore trimming preserves current selection")
        self.check(service.archiveChat(id: "archive-0"), "Restoring frees one archive slot for a later archive")
        self.check(ChatHistoryStore.shared.sessions.filter(\.isArchived).count == ChatHistoryStore.maxArchivedChats, "Archive count returns to the published bound without deleting another archive")
    }

    static func deletingCurrentNeverSelectsAnArchive() {
        let service = self.fixture()
        self.check(service.archiveChat(id: "recent") && service.archiveChat(id: "older"), "Seed archived alternatives to the current session")
        service.deleteCurrentChat()
        self.check(ChatHistoryStore.shared.sessions.filter(\.isArchived).count == 2, "Deleting current leaves archived alternatives intact")
        self.check(ChatHistoryStore.shared.currentSession?.isArchived == false && service.conversationHistory.isEmpty, "Existing delete callers create a blank active session instead of selecting an archive")
    }

    static func launchWithOnlyArchivesKeepsThemAndCreatesActiveChat() throws {
        let archives = [ChatSession(id: "only-archive", isArchived: true, messages: [.init(role: .user, content: "Keep forever within budget")])]
        try UserDefaults.standard.set(JSONEncoder().encode(archives), forKey: "CommandModeChatSessions")
        UserDefaults.standard.set("only-archive", forKey: "CommandModeCurrentChatID")
        let reloaded = ChatHistoryStore.reloadedForTests()
        self.check(reloaded.sessions.filter(\.isArchived) == archives, "Launching with only archives preserves their data")
        self.check(reloaded.sessions.count == 2 && reloaded.currentSession?.isArchived == false && reloaded.currentSession?.messages.isEmpty == true, "Launching cannot select an archive and creates a visible blank active conversation")
        self.check(reloaded.currentChatID != "only-archive", "Stale persisted archive selection is repaired")
    }
}
