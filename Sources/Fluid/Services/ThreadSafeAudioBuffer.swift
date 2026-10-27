import Foundation

/// A thread-safe wrapper around a float array to prevent data races between
/// the audio engine (background thread) and the ASR service (main thread).
final nonisolated class ThreadSafeAudioBuffer {
    private var buffer: [Float] = []
    private let lock = NSLock()

    /// Appends new samples to the buffer in a thread-safe manner
    func append(_ newSamples: [Float]) {
        self.lock.lock()
        defer { lock.unlock() }
        self.buffer.append(contentsOf: newSamples)
    }

    /// Clears the buffer, optionally keeping capacity to optimize for reuse
    func clear(keepingCapacity: Bool = false) {
        self.lock.lock()
        defer { lock.unlock() }
        self.buffer.removeAll(keepingCapacity: keepingCapacity)
    }

    /// Returns the current number of samples
    var isEmpty: Bool { self.lock.withLock { self.buffer.isEmpty } }

    var count: Int {
        self.lock.lock()
        defer { lock.unlock() }
        return self.buffer.count
    }

    /// Returns a copy of the prefix of the buffer (thread-safe)
    func getPrefix(_ length: Int) -> [Float] {
        self.lock.lock()
        defer { lock.unlock() }
        let safeLength = min(length, buffer.count)
        return Array(self.buffer[0..<safeLength])
    }

    /// Returns an exact range when enough samples are available.
    func getRange(startingAt start: Int, count: Int) -> [Float] {
        self.lock.lock()
        defer { lock.unlock() }
        guard start >= 0,
              count > 0,
              start <= self.buffer.count,
              count <= self.buffer.count - start
        else {
            return []
        }
        return Array(self.buffer[start..<(start + count)])
    }

    /// Returns a copy of the entire buffer
    func getAll() -> [Float] {
        self.lock.lock()
        defer { lock.unlock() }
        return self.buffer
    }
}
