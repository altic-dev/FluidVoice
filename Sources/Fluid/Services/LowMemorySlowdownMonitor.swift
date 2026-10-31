import Combine
import Darwin
import Foundation

@MainActor
final class LowMemorySlowdownMonitor: ObservableObject {
    static let shared = LowMemorySlowdownMonitor()
    static let lastShownKey = "LowMemoryCleanupNoticeLastShown"
    @Published private(set) var isNoticeVisible = false

    private struct Attempt {
        let id: UUID
        let model: String
        let isWarm: Bool
        let startedAt: TimeInterval
        let startReading: Task<CleanupMemoryReading, Never>
    }

    private var policy = LowMemorySlowdownPolicy()
    private var active: Attempt?
    private var latestAttemptID: UUID?
    private var noticeTask: Task<Void, Never>?
    private var hasPresentedForAttempt = false
    private let defaults: UserDefaults
    private let sampleMemory: @Sendable () async -> CleanupMemoryReading
    private let uptime: () -> TimeInterval
    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    init(
        defaults: UserDefaults = .standard,
        sampleMemory: @escaping @Sendable () async -> CleanupMemoryReading = {
            await Task.detached(priority: .utility) { CleanupMemoryReading.current() }.value
        },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.defaults = defaults
        self.sampleMemory = sampleMemory
        self.uptime = uptime
        self.now = now
        self.sleep = sleep
    }

    // Avoid the main-actor deinit runtime issue on older macOS versions (swiftlang/swift#88036).
    nonisolated deinit {}

    /// Invoked only after microphone capture has stopped. Never await sampling on the dictation path.
    func beginCleanup(model: String?, isLocal: Bool, isModelReady: Bool, inputCharacters: Int) -> UUID? {
        self.cancelCleanup()
        self.latestAttemptID = nil
        guard isLocal, let model, !model.isEmpty, inputCharacters >= 80 else {
            self.policy.resetEvidence()
            return nil
        }
        let startedAt = self.uptime()
        let sampleMemory = self.sampleMemory
        let recentlyUsed = self.policy.begin(model: model, at: startedAt)
        if !isModelReady { self.policy.resetEvidence() }
        let attempt = Attempt(
            id: UUID(),
            model: model,
            isWarm: recentlyUsed && isModelReady,
            startedAt: startedAt,
            startReading: Task { await sampleMemory() }
        )
        self.active = attempt
        self.latestAttemptID = attempt.id
        self.hasPresentedForAttempt = false
        guard attempt.isWarm, self.cooldownAllowsNotice,
              let delay = self.policy.noticeDelay(model: model, at: startedAt) else { return attempt.id }
        self.noticeTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            let start = await attempt.startReading.value
            let current = await sampleMemory()
            guard let self, !Task.isCancelled, self.active?.id == attempt.id, self.cooldownAllowsNotice,
                  self.policy.noticeDelay(model: model, at: self.uptime()) != nil else { return }
            guard current.hasActivePressure(since: start) else {
                self.policy.resetEvidence()
                return
            }
            self.isNoticeVisible = true
            // Expire eligibility even when captions or hidden previews prevent display.
            do { try await sleep(8) } catch { return }
            guard !Task.isCancelled, self.active?.id == attempt.id else { return }
            self.isNoticeVisible = false
        }
        return attempt.id
    }

    /// Samples asynchronously after cleanup; text insertion never waits for diagnostics.
    @discardableResult
    func finishCleanup(id: UUID?, tokensPerSecond: Double?, succeeded: Bool) -> Task<Void, Never>? {
        guard let attempt = self.active, attempt.id == id else { return nil }
        self.active = nil
        self.hideNotice()
        guard succeeded else {
            self.policy.resetEvidence()
            return nil
        }
        let completedAt = self.uptime()
        let sampleMemory = self.sampleMemory
        return Task { [weak self] in
            let start = await attempt.startReading.value
            let end = await sampleMemory()
            guard let self else { return }
            // A newer attempt must not inherit late evidence from an older lifecycle.
            guard self.active == nil, self.latestAttemptID == attempt.id else { return }
            self.policy.record(.init(
                model: attempt.model,
                isWarm: attempt.isWarm,
                tokensPerSecond: tokensPerSecond,
                seconds: completedAt - attempt.startedAt,
                start: start,
                end: end,
                completedAt: completedAt
            ))
        }
    }

    func cancelCleanup() {
        if self.active != nil {
            self.policy.resetEvidence()
            self.latestAttemptID = nil
        }
        self.active = nil
        self.hideNotice()
    }

    /// The cooldown starts only if a visible overlay actually rendered the line.
    func noticeDidAppear() {
        guard self.isNoticeVisible, self.active != nil, !self.hasPresentedForAttempt else { return }
        self.hasPresentedForAttempt = true
        self.defaults.set(self.now(), forKey: Self.lastShownKey)
        self.policy.resetEvidence()
    }

    private var cooldownAllowsNotice: Bool {
        LowMemorySlowdownPolicy.cooldownAllowsNotice(
            lastShown: self.defaults.object(forKey: Self.lastShownKey) as? Date, now: self.now()
        )
    }

    private func hideNotice() {
        self.noticeTask?.cancel()
        self.noticeTask = nil
        if self.isNoticeVisible { self.isNoticeVisible = false }
    }
}

extension CleanupMemoryReading {
    /// The masked sysctl can be unavailable on a future OS. Unknown readings must stay quiet.
    /// XNU converts this sysctl to Dispatch pressure flags (1/2/4) before returning it.
    static func current() -> Self {
        var rawPressure: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.memorystatus_vm_pressure_level", &rawPressure, &size, nil, 0)
        let pressure = result == 0 ? Pressure(rawValue: Int(rawPressure)) : nil
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return Self(
            pressure: pressure,
            swapIns: status == KERN_SUCCESS ? statistics.swapins : nil,
            compressions: status == KERN_SUCCESS ? statistics.compressions : nil,
            pageSize: UInt64(vm_kernel_page_size)
        )
    }
}
