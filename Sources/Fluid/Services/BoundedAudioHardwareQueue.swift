import Foundation

/// Cancellation releases callers, never the native operation's memory or queue.
/// Healthy startup has no deadline. Recovery queries and teardown can explicitly
/// bound their caller wait without aborting or freeing a native call.
/// Interrupted hardware must finish serialized cleanup before another operation
/// can be admitted. In particular, cancellation must not launch a second IOProc.
final nonisolated class BoundedAudioHardwareQueue: @unchecked Sendable {
    enum Failure: LocalizedError {
        case timedOut
        case recovering
        case cleanupFailed
        case deviceStopped

        var errorDescription: String? {
            switch self {
            case .timedOut, .recovering, .deviceStopped:
                "The microphone is not responding. Try again shortly. If it remains unavailable, quit and reopen FluidVoice."
            case .cleanupFailed:
                "The microphone could not be reset safely. Quit and reopen FluidVoice before recording again."
            }
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { self.lock.withLock { self.cancelled } }

        func cancel() { self.lock.withLock { self.cancelled = true } }
    }

    private struct Pending {
        let fail: @Sendable (Error) -> Void
        let timer: DispatchWorkItem?
        let recover: @Sendable () -> Bool
    }

    private struct AvailabilityWaiter {
        let continuation: CheckedContinuation<Bool, Never>
        let timer: DispatchWorkItem?
    }

    let queue: DispatchQueue
    private let timeout: TimeInterval?
    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]
    private var recovering = false
    private var cleanupFailed = false
    private var availabilityWaiters: [UUID: AvailabilityWaiter] = [:]

    init(queue: DispatchQueue, timeout: TimeInterval? = nil) {
        self.queue = queue
        self.timeout = timeout
    }

    var isAvailable: Bool {
        self.lock.withLock { self.recovering == false && self.cleanupFailed == false }
    }

    func checkAvailable() throws {
        try self.lock.withLock {
            if self.cleanupFailed { throw Failure.cleanupFailed }
            if self.recovering { throw Failure.recovering }
        }
    }

    /// Only the serialized owner can establish that an earlier cleanup failure
    /// is now safe (for example, after a matching device-removal notification).
    /// A running native operation must still complete its own recovery first.
    @discardableResult
    func clearFailureAfterSerializedRecovery() -> Bool {
        dispatchPrecondition(condition: .onQueue(self.queue))
        let cleared = self.lock.withLock {
            guard self.recovering == false, self.cleanupFailed else { return false }
            self.cleanupFailed = false
            return true
        }
        if cleared { self.resumeAvailabilityWaitersIfReady() }
        return cleared
    }

    /// Wait for serialized cleanup without starting another hardware operation.
    /// Cancellation removes only this waiter; it must not interrupt the cleanup.
    func waitUntilAvailable(timeout: TimeInterval? = nil) async -> Bool {
        let id = UUID()
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                if cancellation.isCancelled {
                    self.lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                if self.recovering == false, self.cleanupFailed == false {
                    self.lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                let timer = timeout.map { _ in DispatchWorkItem { [weak self] in self?.finishAvailabilityWaiter(id) } }
                self.availabilityWaiters[id] = AvailabilityWaiter(continuation: continuation, timer: timer)
                self.lock.unlock()
                if let timeout, let timer {
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timer)
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.finishAvailabilityWaiter(id)
        }
    }

    private func finishAvailabilityWaiter(_ id: UUID) {
        guard let waiter = self.lock.withLock({ self.availabilityWaiters.removeValue(forKey: id) }) else { return }
        waiter.timer?.cancel()
        waiter.continuation.resume(returning: false)
    }

    private func resumeAvailabilityWaitersIfReady() {
        let waiters = self.lock.withLock {
            guard self.recovering == false, self.cleanupFailed == false else { return [AvailabilityWaiter]() }
            let waiters = Array(self.availabilityWaiters.values)
            self.availabilityWaiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.timer?.cancel()
            waiter.continuation.resume(returning: true)
        }
    }

    func run<Value: Sendable>(
        cancellable: Bool = true,
        timeout: TimeInterval? = nil,
        recover: @escaping @Sendable () -> Bool,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let id = UUID()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                if cancellation.isCancelled || self.recovering || self.cleanupFailed {
                    let error: Error = cancellation.isCancelled
                        ? CancellationError()
                        : (self.cleanupFailed ? Failure.cleanupFailed : Failure.recovering)
                    self.lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                let deadline = timeout ?? self.timeout
                let timer = deadline.map { _ in DispatchWorkItem { [weak self] in
                    self?.interrupt(requestID: id, error: Failure.timedOut)
                } }
                self.pending[id] = Pending(
                    fail: { continuation.resume(throwing: $0) },
                    timer: timer,
                    recover: recover
                )
                // Enqueue under the admission lock so interruption cannot put
                // cleanup ahead of an admitted native operation.
                self.queue.async {
                    guard self.lock.withLock({ self.pending[id] != nil }) else { return }
                    let result = Result { try operation() }
                    self.lock.lock()
                    let request = self.pending.removeValue(forKey: id)
                    self.lock.unlock()
                    guard let request else { return } // Already cancelled/timed out.
                    request.timer?.cancel()
                    continuation.resume(with: result)
                }
                if let deadline, let timer {
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + deadline,
                        execute: timer
                    )
                }
                self.lock.unlock()
            }
        } onCancel: {
            guard cancellable else { return }
            cancellation.cancel()
            self.interrupt(requestID: id, error: CancellationError())
        }
    }

    /// Used when the UI cancels a recording without cancelling its Swift task.
    /// No work is created when startup has already finished.
    func cancelPendingOperations() {
        self.interrupt(requestID: nil, error: CancellationError())
    }

    /// A device notification can establish failure before a native call returns.
    /// The caller is released, but cleanup still waits behind the native owner.
    func failPendingOperationsAfterDeviceStopped() {
        self.interrupt(requestID: nil, error: Failure.deviceStopped)
    }

    private func interrupt(requestID: UUID?, error: Error) {
        self.lock.lock()
        guard self.recovering == false,
              let request = requestID.flatMap({ self.pending[$0] }) ??
              (requestID == nil ? self.pending.values.first : nil)
        else {
            self.lock.unlock()
            return
        }
        self.recovering = true
        let requests = Array(self.pending.values)
        self.pending.removeAll(keepingCapacity: false)
        // The native call may still be running. Never stop/free its resources
        // from this thread, and do not allocate replacement hardware meanwhile.
        let recover = request.recover
        self.queue.async {
            let recovered = recover()
            self.lock.withLock {
                self.cleanupFailed = recovered == false
                self.recovering = false
            }
            if recovered { self.resumeAvailabilityWaitersIfReady() }
        }
        self.lock.unlock()
        for request in requests {
            request.timer?.cancel()
            request.fail(error)
        }
    }
}
