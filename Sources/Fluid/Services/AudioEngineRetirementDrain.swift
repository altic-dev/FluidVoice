import Foundation

private final nonisolated class AudioEngineRetirementWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(completed: Bool) {
        self.lock.lock()
        guard let continuation = self.continuation else {
            self.lock.unlock()
            return
        }
        self.continuation = nil
        self.lock.unlock()
        continuation.resume(returning: completed)
    }
}

/// Owns the last strong reference to an audio engine while it is waiting to be
/// released on the dedicated retirement queue.
///
/// The token is intentionally separate from the drain. Callers may retain the
/// token across an `await`, but its engine is still released on the retirement
/// queue rather than on the caller's actor.
final nonisolated class AudioEngineRetirementToken: @unchecked Sendable {
    private var engine: AnyObject?

    init(_ engine: AnyObject) {
        self.engine = engine
    }

    func releaseEngine() {
        self.engine = nil
    }
}

/// Serializes final audio-engine releases and provides a completion barrier.
///
/// `-[AVAudioEngine dealloc]` may wait for AVAudioIOUnit's internal queue. The
/// drain must therefore never run on the main actor, and replacement engine
/// construction must be able to await its completion.
final nonisolated class AudioEngineRetirementDrain: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String = "app.fluidvoice.audio-engine-retirement") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    func schedule(_ token: AudioEngineRetirementToken) {
        self.queue.async {
            token.releaseEngine()
        }
    }

    @discardableResult
    func releaseAndWait(
        _ token: AudioEngineRetirementToken,
        timeout: TimeInterval
    ) async -> Bool {
        await self.enqueueAndWait(timeout: timeout) {
            token.releaseEngine()
        }
    }

    /// Waits for every release already submitted to this drain. This is used at
    /// capture start so a fire-and-forget retirement from a non-route path cannot
    /// overlap construction of the next AVAudioEngine.
    @discardableResult
    func waitForScheduledReleases(timeout: TimeInterval) async -> Bool {
        await self.enqueueAndWait(timeout: timeout) {}
    }

    private func enqueueAndWait(
        timeout: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) async -> Bool {
        precondition(timeout > 0, "Audio engine retirement timeout must be positive")

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let wait = AudioEngineRetirementWait(continuation)
            self.queue.async {
                operation()
                wait.finish(completed: true)
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                wait.finish(completed: false)
            }
        }
    }
}
