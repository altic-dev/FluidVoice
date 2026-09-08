import AppKit
import Carbon.HIToolbox

/// One process-wide snapshot of a value derived from the active keyboard layout, refreshed
/// at launch and on input-source notifications.
///
/// Carbon's Text Input Source APIs are main-thread-only. Reading one from a background queue
/// can trap inside HIToolbox - `TISGetInputSourceProperty` validates the source against the
/// input-source list, and rebuilding that list calls `dispatch_assert_queue`. The trap is not
/// reliable enough to catch in testing: the same binary read the layout off the main thread
/// successfully for weeks before an input-source change made every call fatal.
///
/// So the resolve closure runs on the main thread only, and readers take the snapshot and
/// never dispatch to the main queue.
final class KeyboardLayoutSnapshotCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    private var observer: NSObjectProtocol?
    private let resolve: () -> Value
    private let notificationName: Notification.Name
    private var refreshScheduled = false

    init(
        initialValue: Value,
        notificationName: Notification.Name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
        resolve: @escaping () -> Value
    ) {
        self.value = initialValue
        self.notificationName = notificationName
        self.resolve = resolve
    }

    func start() {
        precondition(Thread.isMainThread)
        guard self.observer == nil else { return }
        self.observer = DistributedNotificationCenter.default().addObserver(
            forName: self.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
        }
        self.refresh()
    }

    private func scheduleRefresh() {
        precondition(Thread.isMainThread)
        guard !self.refreshScheduled else { return }
        self.refreshScheduled = true
        // Let TIS process the source-change event before reading its current layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        precondition(Thread.isMainThread)
        let updated = self.resolve()
        self.lock.lock()
        self.value = updated
        self.lock.unlock()
    }

    func snapshot() -> Value {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
