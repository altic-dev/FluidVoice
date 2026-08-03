import Foundation

nonisolated enum AudioCaptureReadinessResult: Equatable {
    case ready
    case cancelled
    case formatInvalidated
    case timedOut
    case staleSession
}

actor AudioCaptureReadinessGate {
    private struct Key: Equatable {
        let sessionID: Int
        let attemptID: UInt64
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<AudioCaptureReadinessResult, Never>
    }

    private var key: Key?
    private var result: AudioCaptureReadinessResult?
    private var waiter: Waiter?
    private var timeoutTask: Task<Void, Never>?

    func arm(sessionID: Int, attemptID: UInt64) {
        self.finishCurrent(with: .cancelled)
        self.key = Key(sessionID: sessionID, attemptID: attemptID)
        self.result = nil
    }

    func wait(
        sessionID: Int,
        attemptID: UInt64,
        timeoutNanoseconds: UInt64
    ) async -> AudioCaptureReadinessResult {
        let key = Key(sessionID: sessionID, attemptID: attemptID)
        guard Task.isCancelled == false else { return .cancelled }
        guard self.key == key else { return .staleSession }
        if let result {
            return result
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard self.key == key else {
                    continuation.resume(returning: .staleSession)
                    return
                }
                if let result = self.result {
                    continuation.resume(returning: result)
                    return
                }
                guard self.waiter == nil else {
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
                    await self?.finish(
                        key: key,
                        waiterID: waiterID,
                        with: .timedOut
                    )
                }
            }
        } onCancel: {
            Task {
                await self.finish(
                    key: key,
                    waiterID: waiterID,
                    with: .cancelled
                )
            }
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
        guard self.key == key, self.result == nil else { return }
        if let waiterID, self.waiter?.id != waiterID {
            return
        }
        self.result = result
        self.timeoutTask?.cancel()
        self.timeoutTask = nil
        let waiter = self.waiter
        self.waiter = nil
        waiter?.continuation.resume(returning: result)
    }

    private func finishCurrent(with result: AudioCaptureReadinessResult) {
        guard let key else { return }
        self.finish(key: key, with: result)
        self.key = nil
        self.result = nil
    }
}
