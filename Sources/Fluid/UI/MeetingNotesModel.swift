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
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var isLoading = false
    /// The shown meeting's notes as last loaded or saved; text that differs has unsaved edits.
    private var lastSynced: String?
    /// Edits to meetings no longer shown that have not been saved yet. Showing that meeting again
    /// resumes from here rather than from its older stored notes.
    private var unsavedOffscreen: [MeetingSessionID: String] = [:]
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
            self.lastSynced = session.notes
            if let unsaved = self.unsavedOffscreen[session.id] {
                self.load(unsaved)
                if MeetingSession.normalizedNotes(unsaved) == session.notes {
                    self.unsavedOffscreen[session.id] = nil
                } else {
                    self.scheduleSave(after: .zero)
                }
            } else {
                self.load(session.notes ?? "")
            }
            return
        }
        guard self.pending == nil, self.inFlight == 0 else { return }
        let current = MeetingSession.normalizedNotes(self.text)
        if current == self.lastSynced {
            // No unsaved edits: newer stored notes win.
            guard session.notes != self.lastSynced else { return }
            self.lastSynced = session.notes
            self.load(session.notes ?? "")
        } else if session.notes != current {
            self.scheduleSave(after: .zero)
        }
    }

    /// Owners must call this when the editor goes away: a pending debounced edit is dropped when the model deinits.
    func flush() {
        guard self.pending != nil, let id = self.sessionID else { return }
        self.pending?.cancel()
        self.pending = nil
        let snapshot = self.text
        self.unsavedOffscreen[id] = snapshot
        Task { await self.persist(id, snapshot) }
    }

    /// Saves an unsaved edit now and waits for every save in flight. Quit and actions that need the
    /// coordinator's mutation gate call this, as a notes save holds that gate.
    func flushAndWait() async {
        if self.pending != nil, let id = self.sessionID {
            self.pending?.cancel()
            self.pending = nil
            await self.persist(id, self.text)
        }
        while self.inFlight > 0 {
            await withCheckedContinuation { self.idleWaiters.append($0) }
        }
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
            defer { self.finishSave() }
            _ = try await self.save(id, snapshot)
            if self.unsavedOffscreen[id] == snapshot || id == self.sessionID { self.unsavedOffscreen[id] = nil }
            if id == self.sessionID {
                self.saveError = nil
                self.lastSynced = MeetingSession.normalizedNotes(snapshot)
            }
        } catch MeetingCoordinatorError.activityInProgress {
            if id == self.sessionID {
                self.scheduleSave(after: self.retryDelay)
            } else if attempt < Self.maximumOffscreenAttempts {
                try? await Task.sleep(for: self.retryDelay)
                // Showing the meeting again hands the snapshot back to the editor, which saves it from there.
                guard id != self.sessionID, self.unsavedOffscreen[id] == snapshot else { return }
                await self.persist(id, snapshot, attempt: attempt + 1)
            } else {
                DebugLogger.shared.warning("Meeting notes stayed unsaved after \(attempt + 1) busy attempts; retrying when the meeting is shown again", source: "MeetingNotesModel")
            }
        } catch {
            if id == self.sessionID {
                self.saveError = error.localizedDescription
            } else {
                DebugLogger.shared.error("Meeting notes for a meeting no longer shown could not be saved: \(error.localizedDescription)", source: "MeetingNotesModel")
            }
        }
    }

    private func finishSave() {
        self.inFlight -= 1
        guard self.inFlight == 0 else { return }
        let waiters = self.idleWaiters
        self.idleWaiters = []
        waiters.forEach { $0.resume() }
    }
}
