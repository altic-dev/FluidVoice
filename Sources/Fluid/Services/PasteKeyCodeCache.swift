import AppKit
import Carbon.HIToolbox

/// One process-wide snapshot, refreshed at launch and on input-source notifications.
/// Paste requests only read the snapshot and never dispatch to the main queue.
final class PasteKeyCodeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var keyCode: CGKeyCode = 9
    private var observer: NSObjectProtocol?
    private let resolve: () -> CGKeyCode
    private let notificationName: Notification.Name
    private var refreshScheduled = false

    init(
        notificationName: Notification.Name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
        resolve: @escaping () -> CGKeyCode
    ) {
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
        self.keyCode = updated
        self.lock.unlock()
    }

    func snapshot() -> CGKeyCode {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.keyCode
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
