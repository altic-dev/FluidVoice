import AppKit
import ApplicationServices

/// Requests Electron's documented accessibility support before a dictation
/// captures its destination. Never changes focus, reads text or sends input.
@MainActor
final class DictationAccessibilityPreparation {
    static let shared = DictationAccessibilityPreparation()
    private let worker = DictationAccessibilityPreparationWorker()
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    nonisolated deinit {}

    func start() {
        guard self.observer == nil else { return }
        self.prepare(NSWorkspace.shared.frontmostApplication)
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.prepare(app) }
        }
    }

    private func prepare(_ app: NSRunningApplication?) {
        self.pending?.cancel()
        guard let app, app.processIdentifier != getpid(), let bundleURL = app.bundleURL else { return }
        let request = DictationAccessibilityPreparationWorker.Request(
            pid: app.processIdentifier, launchedAt: app.launchDate, bundleURL: bundleURL
        )
        self.pending = Task(priority: .utility) {
            let result = await self.worker.prepare(request)
            guard !Task.isCancelled, result == .enabled else { return }
            DebugLogger.shared.info("FOCUS_ACCESSIBILITY enabled pid=\(request.pid)", source: "DictationAccessibilityPreparation")
        }
    }
}

actor DictationAccessibilityPreparationWorker {
    nonisolated struct Request: Hashable, Sendable {
        let pid: pid_t
        let launchedAt: Date?
        let bundleURL: URL
    }

    nonisolated enum Outcome: Equatable, Sendable {
        case enabled, unsupported, untrusted, stale, cancelled
        case failed(Int32)
    }

    private let isTrusted: @Sendable () -> Bool
    private let supportsPreparation: @Sendable (Request) -> Bool
    private let enable: @Sendable (Request) -> Outcome
    private let capacity: Int
    private var prepared: [Request: Outcome] = [:]
    private var order: [Request] = []

    init(
        capacity: Int = 64,
        isTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        supportsPreparation: @escaping @Sendable (Request) -> Bool = { request in
            FileManager.default.fileExists(atPath: request.bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        },
        enable: @escaping @Sendable (Request) -> Outcome = { request in
            guard let app = NSRunningApplication(processIdentifier: request.pid),
                  !app.isTerminated, app.bundleURL == request.bundleURL, app.launchDate == request.launchedAt
            else { return .stale }
            let element = AXUIElementCreateApplication(request.pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            let result = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            return result == .success ? .enabled : .failed(result.rawValue)
        }
    ) {
        self.capacity = max(1, capacity)
        self.isTrusted = isTrusted
        self.supportsPreparation = supportsPreparation
        self.enable = enable
    }

    func prepare(_ request: Request) -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        guard request.pid > 0, request.pid != getpid() else { return .stale }
        // A missing permission is not cached: granting it must permit a later attempt.
        guard self.isTrusted() else { return .untrusted }
        if let previous = self.prepared[request] { return previous }
        let result = self.supportsPreparation(request) ? self.enable(request) : .unsupported
        // Failed requests may succeed on the next activation; never poll or retry
        // during a recording. Successful/unsupported processes are bounded in memory.
        if result == .enabled || result == .unsupported {
            if self.order.count == self.capacity { self.prepared.removeValue(forKey: self.order.removeFirst()) }
            self.order.append(request)
            self.prepared[request] = result
        }
        return result
    }
}
