import Foundation

/// Bounded, drop-oldest queue handing capture-thread audio off to a background worker without ever
/// blocking the capture callback. Mirrors `MeetingAudioChunkWriter`'s bounded-slot philosophy, but
/// drops the oldest element instead of rejecting the newest: a dropped live sample degrades a
/// transcript, not the recording, so newer audio is worth more than older audio here.
final nonisolated class MeetingLiveBoundedQueue<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Element] = []
    private let capacity: Int
    private var droppedCount = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Never blocks. Returns true when enqueueing dropped an older element.
    @discardableResult
    func enqueue(_ element: Element) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        var dropped = false
        if self.buffer.count >= self.capacity {
            self.buffer.removeFirst()
            self.droppedCount += 1
            dropped = true
        }
        self.buffer.append(element)
        return dropped
    }

    func drainAll() -> [Element] {
        self.lock.lock()
        defer { self.lock.unlock() }
        defer { self.buffer.removeAll(keepingCapacity: true) }
        return self.buffer
    }

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.buffer.count
    }

    func takeDroppedCount() -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        defer { self.droppedCount = 0 }
        return self.droppedCount
    }
}
