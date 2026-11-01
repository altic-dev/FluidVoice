import AppKit

final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
}

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    var trusted = true
    var supported = true
    var result = DictationAccessibilityPreparationWorker.Outcome.enabled
    private(set) var checks = 0
    private(set) var writes = 0

    func isTrusted() -> Bool { self.lock.withLock { self.trusted } }
    func supports(_ request: DictationAccessibilityPreparationWorker.Request) -> Bool {
        self.lock.withLock { self.checks += 1; return self.supported }
    }

    func enable(_ request: DictationAccessibilityPreparationWorker.Request) -> DictationAccessibilityPreparationWorker.Outcome {
        self.lock.withLock { self.writes += 1; return self.result }
    }

    func worker(capacity: Int = 64) -> DictationAccessibilityPreparationWorker {
        .init(capacity: capacity, isTrusted: { self.isTrusted() }, supportsPreparation: { self.supports($0) }, enable: { self.enable($0) })
    }
}

@main
enum DictationAccessibilityPreparationTests {
    static func request(_ pid: pid_t = 123, launchedAt: Date? = Date(timeIntervalSince1970: 1)) -> DictationAccessibilityPreparationWorker.Request {
        .init(pid: pid, launchedAt: launchedAt, bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"))
    }

    static func main() async {
        let probe = Probe(), worker = probe.worker()
        let request = self.request()
        let first = await worker.prepare(request)
        precondition(first == .enabled)
        for _ in 0..<20 {
            _ = await worker.prepare(request)
        }
        precondition(probe.writes == 1 && probe.checks == 1, "Repeat activations must not repeat disk/AX work")
        _ = await worker.prepare(self.request(124))
        _ = await worker.prepare(self.request(123, launchedAt: Date(timeIntervalSince1970: 2)))
        precondition(probe.writes == 3, "Relaunch/PID reuse must receive fresh preparation")

        let unsupported = Probe(); unsupported.supported = false
        let native = unsupported.worker()
        let nativeResult = await native.prepare(request)
        precondition(nativeResult == .unsupported)
        _ = await native.prepare(request)
        precondition(unsupported.writes == 0 && unsupported.checks == 1, "Native apps must receive no AX writes")

        let permission = Probe(); permission.trusted = false
        let permissionWorker = permission.worker()
        let denied = await permissionWorker.prepare(request)
        precondition(denied == .untrusted && permission.checks == 0 && permission.writes == 0)
        permission.trusted = true
        let granted = await permissionWorker.prepare(request)
        precondition(granted == .enabled && permission.writes == 1)

        let failed = Probe(); failed.result = .failed(-25_212)
        let retryWorker = failed.worker()
        _ = await retryWorker.prepare(request)
        failed.result = .enabled
        let retry = await retryWorker.prepare(request)
        precondition(retry == .enabled && failed.writes == 2, "A failed attempt must not suppress later activations")

        let bounded = Probe(), small = bounded.worker(capacity: 2)
        _ = await small.prepare(self.request(1)); _ = await small.prepare(self.request(2))
        _ = await small.prepare(self.request(3)); _ = await small.prepare(self.request(1))
        precondition(bounded.writes == 4, "Old entries must be evicted")
        let invalid = await small.prepare(self.request(0))
        let own = await small.prepare(self.request(getpid()))
        precondition(invalid == .stale && own == .stale && bounded.writes == 4)

        let cancelledProbe = Probe(), cancelledWorker = cancelledProbe.worker()
        let gate = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cancelledWorker.prepare(request)
        }
        let cancelled = await gate.value
        precondition(cancelled == .cancelled && cancelledProbe.writes == 0)

        let rapidProbe = Probe(), rapid = rapidProbe.worker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask { _ = await rapid.prepare(request) }
            }
        }
        precondition(rapidProbe.checks == 1 && rapidProbe.writes == 1, "Concurrent duplicates must coalesce")
        print("PASS: once-per-process preparation, relaunch/PID reuse, native-app non-effects, permission grant, failure retry, bounded eviction, invalid/self targets, cancellation and concurrent activation")
    }
}
