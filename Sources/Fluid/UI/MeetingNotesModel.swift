import Combine
import Foundation

/// One editable copy of the open meeting's notes, shared by the recording and result views.
@MainActor
final class MeetingNotesModel: ObservableObject {
    /// Explicitly nonisolated: on macOS 15.4+ the synthesized main-actor deinit can abort until the OS runtime has the fix (swiftlang/swift#88036).
    nonisolated deinit {}

    typealias Save = @MainActor (MeetingSessionID, String) async throws -> MeetingSession

    @Published var text = "" {
        didSet { if self.text != oldValue, !self.isLoading { self.scheduleSave(after: self.debounce) } }
    }

    @Published private(set) var saveError: String?
    private(set) var sessionID: MeetingSessionID?
    private let save: Save
    private let debounce: Duration
    private let retryDelay: Duration
    private var pending: Task<Void, Never>?
    private var inFlight = 0
    private var isLoading = false
    private static let maximumOffscreenAttempts = 30

    init(debounce: Duration = .seconds(1), retryDelay: Duration = .seconds(2), save: @escaping Save) {
        self.debounce = debounce
        self.retryDelay = retryDelay
        self.save = save
    }

    func show(_ session: MeetingSession) {
        guard session.id == self.sessionID else {
            self.flush()
            self.sessionID = session.id
            self.saveError = nil
            self.load(session.notes ?? "")
            return
        }
        // Only this model edits notes, so a refresh that disagrees means the coordinator missed an edit.
        if self.pending == nil, self.inFlight == 0, session.notes != MeetingSession.normalizedNotes(self.text) {
            self.scheduleSave(after: .zero)
        }
    }

    /// Owners must call this when the editor goes away: a pending debounced edit is dropped when the model deinits.
    func flush() {
        guard self.pending != nil, let id = self.sessionID else { return }
        self.pending?.cancel()
        self.pending = nil
        let snapshot = self.text
        Task { await self.persist(id, snapshot) }
    }

    /// Saves an unsaved edit now and waits for it. Quit calls this, as it can't wait out the debounce.
    func flushAndWait() async {
        guard self.pending != nil, let id = self.sessionID else { return }
        self.pending?.cancel()
        self.pending = nil
        await self.persist(id, self.text)
    }

    private func load(_ text: String) {
        self.pending?.cancel()
        self.pending = nil
        self.isLoading = true
        self.text = text
        self.isLoading = false
    }

    private func scheduleSave(after delay: Duration) {
        guard let id = self.sessionID else { return }
        self.pending?.cancel()
        self.pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            await self.persist(id, self.text)
        }
    }

    private func persist(_ id: MeetingSessionID, _ snapshot: String, attempt: Int = 0) async {
        do {
            self.inFlight += 1
            defer { self.inFlight -= 1 }
            _ = try await self.save(id, snapshot)
            if id == self.sessionID { self.saveError = nil }
        } catch MeetingCoordinatorError.activityInProgress {
            if id == self.sessionID {
                self.scheduleSave(after: self.retryDelay)
            } else if attempt < Self.maximumOffscreenAttempts {
                // Edits to a meeting no longer shown: retry the frozen snapshot.
                try? await Task.sleep(for: self.retryDelay)
                await self.persist(id, snapshot, attempt: attempt + 1)
            }
        } catch {
            if id == self.sessionID { self.saveError = error.localizedDescription }
        }
    }
}
