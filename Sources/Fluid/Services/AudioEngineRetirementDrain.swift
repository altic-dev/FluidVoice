import Foundation

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
    private let stateLock = NSLock()
    private var scheduledReleaseCount = 0

    init(label: String = "app.fluidvoice.audio-engine-retirement") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    func schedule(_ token: AudioEngineRetirementToken) {
        self.stateLock.lock()
        self.scheduledReleaseCount += 1
        self.queue.async { [self] in
            token.releaseEngine()
            self.completeScheduledRelease()
        }
        self.stateLock.unlock()
    }

    func releaseAndWait(_ token: AudioEngineRetirementToken) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.stateLock.lock()
            self.scheduledReleaseCount += 1
            self.queue.async { [self] in
                token.releaseEngine()
                self.completeScheduledRelease()
                continuation.resume()
            }
            self.stateLock.unlock()
        }
    }

    /// Waits for every release already submitted to this drain. This is used at
    /// capture start so a fire-and-forget retirement from a non-route path cannot
    /// overlap construction of the next AVAudioEngine.
    func waitForScheduledReleases() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.stateLock.lock()
            guard self.scheduledReleaseCount > 0 else {
                self.stateLock.unlock()
                continuation.resume()
                return
            }

            // Enqueue while holding the same lock used by schedule(_:). This
            // preserves the barrier ordering without paying a utility-queue hop
            // when no AVAudioEngine release is pending.
            self.queue.async {
                continuation.resume()
            }
            self.stateLock.unlock()
        }
    }

    private func completeScheduledRelease() {
        self.stateLock.lock()
        self.scheduledReleaseCount -= 1
        self.stateLock.unlock()
    }
}
