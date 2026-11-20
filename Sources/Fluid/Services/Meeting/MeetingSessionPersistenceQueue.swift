import Foundation

/// Serializes background saves while retaining only the latest pending snapshot per session.
/// Separate session slots preserve recovery updates when a new recording starts before a save
/// finishes. Intermediate snapshots are superseded, but their events remain in the latest one.
@MainActor
final class MeetingSessionPersistenceQueue {
    private let store: any MeetingSessionStoring
    private var pending: [MeetingSessionID: MeetingSession] = [:]
    private var order: [MeetingSessionID] = []
    private var completions: [MeetingSessionID: [(Result<Void, Error>) -> Void]] = [:]
    private var task: Task<Void, Never>?

    init(store: any MeetingSessionStoring) {
        self.store = store
    }

    func enqueue(_ session: MeetingSession) {
        self.enqueue(session, completion: nil)
    }

    /// Title edits await the same serialized writer as capture updates, without holding capture.
    func save(_ session: MeetingSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.enqueue(session) { continuation.resume(with: $0) }
        }
    }

    private func enqueue(_ session: MeetingSession, completion: ((Result<Void, Error>) -> Void)?) {
        if let completion { self.completions[session.id, default: []].append(completion) }
        if self.pending[session.id] == nil {
            self.order.append(session.id)
        }
        self.pending[session.id] = session
        guard self.task == nil else { return }
        self.task = Task {
            while !self.order.isEmpty {
                let id = self.order.removeFirst()
                guard let snapshot = self.pending.removeValue(forKey: id) else { continue }
                let completions = self.completions.removeValue(forKey: id) ?? []
                let result: Result<Void, Error>
                do {
                    try await self.store.save(snapshot)
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                // A failed save must still release waiters and let newer snapshots be written.
                for completion in completions {
                    completion(result)
                }
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
