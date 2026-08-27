import Foundation

nonisolated enum AudioCaptureReadinessResult: Equatable {
    case ready
    case cancelled
    case formatInvalidated
    case timedOut
    case staleSession
}

final nonisolated class AudioCaptureReadinessGate: @unchecked Sendable {
    private struct Key: Equatable {
        let sessionID: Int
        let attemptID: UInt64
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<AudioCaptureReadinessResult, Never>
    }

    private let lock = NSLock()
    private var key: Key?
    private var result: AudioCaptureReadinessResult?
    private var waiter: Waiter?
    private var cancelledWaiterIDs = Set<UUID>()
    private var timeoutTask: Task<Void, Never>?

    func arm(sessionID: Int, attemptID: UInt64) {
        self.lock.lock()
        let previousTimeoutTask = self.timeoutTask
        let previousWaiter = self.waiter
        self.timeoutTask = nil
        self.waiter = nil
        self.cancelledWaiterIDs.removeAll(keepingCapacity: true)
        self.key = Key(sessionID: sessionID, attemptID: attemptID)
        self.result = nil
        self.lock.unlock()

        previousTimeoutTask?.cancel()
        previousWaiter?.continuation.resume(returning: .cancelled)
    }

    func wait(
        sessionID: Int,
        attemptID: UInt64,
        timeoutNanoseconds: UInt64
    ) async -> AudioCaptureReadinessResult {
        let key = Key(sessionID: sessionID, attemptID: attemptID)
        guard Task.isCancelled == false else { return .cancelled }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                guard Task.isCancelled == false else {
                    self.lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard self.key == key else {
                    self.lock.unlock()
                    continuation.resume(returning: .staleSession)
                    return
                }
                if let result = self.result {
                    self.lock.unlock()
                    continuation.resume(returning: result)
                    return
                }
                guard self.waiter == nil else {
                    self.lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard self.cancelledWaiterIDs.remove(waiterID) == nil else {
                    self.lock.unlock()
                    continuation.resume(returning: .cancelled)
                    return
                }

                self.waiter = Waiter(id: waiterID, continuation: continuation)
                self.timeoutTask?.cancel()
                self.timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    self?.finish(
                        key: key,
                        waiterID: waiterID,
                        with: .timedOut
                    )
                }
                self.lock.unlock()
            }
        } onCancel: {
            self.finish(
                key: key,
                waiterID: waiterID,
                with: .cancelled
            )
        }
    }

    func signalFirstPCM(sessionID: Int, attemptID: UInt64) {
        self.finish(
            key: Key(sessionID: sessionID, attemptID: attemptID),
            with: .ready
        )
    }

    func cancel(sessionID: Int, attemptID: UInt64) {
        self.finish(
            key: Key(sessionID: sessionID, attemptID: attemptID),
            with: .cancelled
        )
    }

    func signalFormatInvalidation(sessionID: Int, attemptID: UInt64) {
        self.finish(
            key: Key(sessionID: sessionID, attemptID: attemptID),
            with: .formatInvalidated
        )
    }

    private func finish(
        key: Key,
        waiterID: UUID? = nil,
        with result: AudioCaptureReadinessResult
    ) {
        self.lock.lock()
        guard self.key == key, self.result == nil else {
            self.lock.unlock()
            return
        }
        if let waiterID {
            guard let waiter = self.waiter else {
                if result == .cancelled {
                    self.cancelledWaiterIDs.insert(waiterID)
                }
                self.lock.unlock()
                return
            }
            guard waiter.id == waiterID else {
                self.lock.unlock()
                return
            }
        }
        self.result = result
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        let waiter = self.waiter
        self.waiter = nil
        self.lock.unlock()

        timeoutTask?.cancel()
        waiter?.continuation.resume(returning: result)
    }
}
