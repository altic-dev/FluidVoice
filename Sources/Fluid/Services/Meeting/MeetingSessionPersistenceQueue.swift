import Foundation

/// Serializes background saves while retaining only the latest pending snapshot per session.
/// Separate session slots preserve recovery updates when a new recording starts before a save
/// finishes. Intermediate snapshots are superseded, but their events remain in the latest one.
@MainActor
final class MeetingSessionPersistenceQueue {
    private let store: any MeetingSessionStoring
    private var pending: [MeetingSessionID: MeetingSession] = [:]
    private var order: [MeetingSessionID] = []
    private var task: Task<Void, Never>?

    init(store: any MeetingSessionStoring) {
        self.store = store
    }

    func enqueue(_ session: MeetingSession) {
        if self.pending[session.id] == nil {
            self.order.append(session.id)
        }
        self.pending[session.id] = session
        guard self.task == nil else { return }
        self.task = Task {
            while !self.order.isEmpty {
                let id = self.order.removeFirst()
                guard let snapshot = self.pending.removeValue(forKey: id) else { continue }
                // Match the coordinator's best-effort background-save policy. A failed save
                // must not strand the worker or prevent newer snapshots from being written.
                try? await self.store.save(snapshot)
            }
            self.task = nil
        }
    }

    /// Includes updates enqueued during a save and any replacement worker started before this
    /// waiter resumes. Callers can then persist terminal state without an older queued overwrite.
    func flush() async {
        while let task = self.task {
            await task.value
        }
    }
}
