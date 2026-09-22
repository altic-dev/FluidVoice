import Combine
import Foundation

// Shadows Foundation.UserDefaults in the production store compiled by the runner.
// All persistence stays in this dictionary; no installed app or search index is opened.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { self.values[key] as? Data }
    func string(forKey key: String) -> String? { self.values[key] as? String }
    func set(_ value: Any?, forKey key: String) { self.values[key] = value }
}

final class SearchIndex: Sendable {
    static let shared = SearchIndex()
}

final class ZeppelinCancellationToken {}
enum SettingsSearchTarget: Hashable, Sendable { case test }

struct TranscriptionHistoryEntry {
    let id: UUID
    let searchRevision: UInt64?
    let timestamp: Date
    let processedText: String
    let appName: String
    let windowTitle: String
}

struct FileTranscriptionEntry {
    let id: UUID
    let timestamp: Date
    let fileName: String
    let text: String
    var searchRevision: UInt64? { nil }
    var displayTitle: String { self.fileName }
}

@main @MainActor struct CommandArchiveSearchTests {
    private static var checks = 0

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        self.checks += 1
    }

    private static func require<Value>(_ value: Value?, _ message: String) -> Value {
        guard let value else { preconditionFailure(message) }
        return value
    }

    private static func testRename() {
        let store = ChatHistoryStore.shared
        let original = ChatSession(title: "Automatic", messages: [.init(role: .user, content: "Original prompt")])
        let other = ChatSession(title: "Other", isArchived: true)
        store.resetForTests([original, other], currentChatID: original.id)
        store.renameChat(id: original.id, to: "  My project  ")
        let renamed = self.require(store.currentSession, "Rename retains current session")
        self.check(renamed.title == "My project" && renamed.hasCustomTitle, "Trim and persist custom title")
        self.check(renamed.messages == original.messages && renamed.updatedAt == original.updatedAt, "Rename preserves messages and date")
        self.check(renamed.searchRecord!.revision > original.searchRecord!.revision, "Rename advances search revision")
        self.check(store.sessions[1] == other, "Rename leaves unrelated archives unchanged")
        let snapshot = store.sessions
        store.renameChat(id: original.id, to: "  ")
        store.renameChat(id: original.id, to: "My project")
        store.renameChat(id: "missing", to: "Deleted session")
        self.check(store.sessions == snapshot, "Blank, duplicate and stale renames are no-ops")
        store.updateCurrentChat(messages: [.init(role: .user, content: "New message")])
        self.check(store.currentSession?.title == "My project", "Message autosave never overwrites a custom title")
        let encoded = try! JSONEncoder().encode(renamed)
        let decoded = try! JSONDecoder().decode(ChatSession.self, from: encoded)
        self.check(decoded == renamed, "Custom title survives reload")
        var legacy = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "hasCustomTitle")
        let legacyData = try! JSONSerialization.data(withJSONObject: legacy)
        self.check(!(try! JSONDecoder().decode(ChatSession.self, from: legacyData)).hasCustomTitle, "Old sessions decode without migration")
        store.renameChat(id: other.id, to: "Archived project")
        self.check(store.sessions[1].isArchived && store.currentChatID == original.id, "Archived rename never restores or selects it")
    }

    static func main() {
        self.testRename()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let active = ChatSession(title: "Active searchable", updatedAt: date, messages: [.init(role: .user, content: "hello")])
        let archived = ChatSession(title: "Archived hidden", updatedAt: date, isArchived: true, messages: [.init(role: .user, content: "hidden")])
        let another = ChatSession(title: "Another active", updatedAt: date)
        let store = ChatHistoryStore.shared
        store.resetForTests([active, archived, another], currentChatID: active.id)
        let original = self.require(active.searchRecord, "An active session must produce an index record")
        self.check(archived.searchRecord == nil, "Archived sessions must be absent from the index snapshot")
        self.check(ChatSession(id: "broken").searchRecord == nil, "Malformed IDs must still be excluded")

        let history = AppSearchGroup(kind: .history, hits: [.init(kind: .history, target: .history(UUID()), title: "History", snippet: "", date: date)])
        let activeHit = AppSearchHit(kind: .chats, target: .chat(active.id), title: active.title, snippet: "", date: date)
        let archivedHit = AppSearchHit(kind: .chats, target: .chat(archived.id), title: archived.title, snippet: "", date: date)
        let rawResults = [history, AppSearchGroup(kind: .chats, hits: [activeHit, archivedHit])]
        let visible = AppSearchService.removingUnavailableChats(from: rawResults, availableIDs: [active.id, another.id])
        self.check(visible.count == 2 && visible[0] == history, "Filtering chats must preserve other result groups")
        self.check(visible[1].hits == [activeHit], "The active hit keeps its rank and metadata while the archived hit disappears")

        let service = AppSearchService()
        service.publishForTests(visible)
        self.check(store.archiveChat(id: active.id), "The active session can be archived")
        self.check(service.groups == [history], "Archive must prune displayed hits synchronously before the index debounce")
        let archivedActive = self.require(store.sessions.first { $0.id == active.id }, "Archiving must retain the session")
        self.check(archivedActive.searchRecord == nil, "The archived session no longer contributes a search document")
        self.check(archivedActive.messages == active.messages && archivedActive.updatedAt == date, "Archiving preserves conversation text and date")
        self.check(
            AppSearchService.removingUnavailableChats(from: visible, availableIDs: [another.id]) == [history],
            "The final publication filter must reject a late query containing an archived hit"
        )

        self.check(store.restoreChat(id: active.id), "The archived session can be restored")
        let restored = self.require(store.sessions.first { $0.id == active.id }, "Restoring must retain the session")
        let restoredRecord = self.require(restored.searchRecord, "Restoring makes the session indexable again")
        self.check(restored.updatedAt == date && restoredRecord.timestamp == original.timestamp, "Restore must preserve recency and result timestamps")
        self.check(restoredRecord.revision > original.revision, "The restored record must beat Zeppelin's tombstoned revision")
        self.check(restoredRecord.text == original.text, "A visibility change must not rewrite indexed conversation text")
        self.check(service.groups == [history], "Restore waits for real query matches instead of fabricating results")
        let reopened = AppSearchService.removingUnavailableChats(from: visible, availableIDs: [active.id, another.id])
        self.check(reopened == visible, "A refreshed matching result becomes visible after restore")

        service.publishForTests(reopened)
        var publications = 0
        let subscription = service.$groups.dropFirst().sink { _ in publications += 1 }
        _ = store.loadChat(id: active.id)
        store.updateCurrentChat(messages: [.init(role: .user, content: "Changed content")])
        self.check(publications == 0 && service.groups == reopened, "Message saves with unchanged availability must not republish result groups")
        store.createNewChat()
        self.check(publications == 0 && service.groups == reopened, "An unrelated new session must not invalidate existing matches")
        store.deleteChat(id: active.id)
        self.check(service.groups == [history] && publications == 1, "Deleting a matching session prunes it immediately while preserving unrelated hits")
        subscription.cancel()
        print("Command archive search: \(self.checks) checks passed")
    }
}
