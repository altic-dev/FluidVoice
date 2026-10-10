import Foundation

/// Separate recognizers retain independent decoder state but must not write the model cache concurrently.
actor MeetingModelPreparationQueue {
    static let shared = MeetingModelPreparationQueue()
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var isPreparing = false
    private var waiters: [Waiter] = []

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await self.acquire()
        defer { self.release() }
        try Task.checkCancellation()
        try await operation()
        try Task.checkCancellation()
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.enqueue(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func enqueue(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else if !self.isPreparing {
            self.isPreparing = true
            continuation.resume()
        } else {
            self.waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
        self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if self.waiters.isEmpty {
            self.isPreparing = false
        } else {
            self.waiters.removeFirst().continuation.resume()
        }
    }
}
