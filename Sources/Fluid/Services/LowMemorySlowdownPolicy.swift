import Foundation

/// Evidence about this cleanup, not the amount of RAM installed or swap left over from earlier work.
struct CleanupMemoryReading: Equatable, Sendable {
    enum Pressure: Int, Sendable {
        // The sysctl exports Dispatch values, not the kernel's internal pressure enum.
        case normal = 1
        case warning = 2
        case critical = 4
    }

    let pressure: Pressure?
    let swapIns: UInt64?
    let compressions: UInt64?
    let pageSize: UInt64

    var isUnderPressure: Bool { self.pressure == .warning || self.pressure == .critical }

    func hasActivePressure(since earlier: Self) -> Bool {
        guard self.isUnderPressure, earlier.isUnderPressure, self.pageSize > 0,
              self.pageSize == earlier.pageSize else { return false }
        // Small background changes are common. Require actual memory movement during the cleanup.
        func grew(_ current: UInt64?, _ previous: UInt64?, byBytes bytes: UInt64) -> Bool {
            guard let current, let previous, current >= previous else { return false }
            return current - previous >= max(1, bytes / self.pageSize)
        }
        return grew(self.swapIns, earlier.swapIns, byBytes: 16 * 1_048_576) ||
            grew(self.compressions, earlier.compressions, byBytes: 64 * 1_048_576)
    }
}

/// Bounded, per-model learning. Pressure samples never teach the monitor what "normal" speed is.
struct LowMemorySlowdownPolicy {
    static let evidenceLifetime: TimeInterval = 5 * 60
    static let cooldown: TimeInterval = 24 * 60 * 60
    static let minimumBaselineCount = 5
    static let requiredSlowCleanups = 3

    struct Cleanup {
        let model: String
        let isWarm: Bool
        let tokensPerSecond: Double?
        let seconds: TimeInterval
        let start: CleanupMemoryReading
        let end: CleanupMemoryReading
        let completedAt: TimeInterval
    }

    private struct Profile {
        var healthySpeeds: [Double] = []
        var lastStartedAt: TimeInterval = 0
        var lastSlowAt: TimeInterval?
        var slowCount = 0
        var noticeDelay: TimeInterval = 3
    }

    private var profiles: [String: Profile] = [:]
    private var currentModel: String?

    mutating func begin(model: String, at uptime: TimeInterval) -> Bool {
        let previous = self.profiles[model]
        let isWarm = self.currentModel == model && previous.map {
            (0...Self.evidenceLifetime).contains(uptime - $0.lastStartedAt)
        } == true
        if !isWarm { self.resetEvidence() }
        if previous == nil, self.profiles.count >= 4,
           let oldest = self.profiles.min(by: { $0.value.lastStartedAt < $1.value.lastStartedAt })?.key
        {
            self.profiles.removeValue(forKey: oldest)
        }
        self.currentModel = model
        self.profiles[model, default: Profile()].lastStartedAt = uptime
        return isWarm
    }

    mutating func record(_ cleanup: Cleanup) {
        guard cleanup.model == self.currentModel, var profile = self.profiles[cleanup.model] else { return }
        defer { self.profiles[cleanup.model] = profile }
        guard cleanup.isWarm, let speed = cleanup.tokensPerSecond, speed.isFinite, speed > 0,
              cleanup.seconds.isFinite, cleanup.seconds > 0
        else {
            profile.slowCount = 0
            profile.lastSlowAt = nil
            return
        }

        if cleanup.start.pressure == .normal, cleanup.end.pressure == .normal {
            profile.healthySpeeds.append(speed)
            if profile.healthySpeeds.count > 20 { profile.healthySpeeds.removeFirst() }
        }
        let baseline = profile.healthySpeeds.count >= Self.minimumBaselineCount
            ? profile.healthySpeeds.sorted()[profile.healthySpeeds.count / 2] : nil
        // Without a baseline, only repeated severe pressure and substantial waits qualify.
        let isSlow = baseline.map { speed <= $0 * 0.5 } ??
            (cleanup.start.pressure == .critical && cleanup.end.pressure == .critical && cleanup.seconds >= 8)
        guard cleanup.seconds >= 3, isSlow, cleanup.end.hasActivePressure(since: cleanup.start) else {
            profile.slowCount = 0
            profile.lastSlowAt = nil
            return
        }
        if let previous = profile.lastSlowAt,
           !(0...Self.evidenceLifetime).contains(cleanup.completedAt - previous)
        {
            profile.slowCount = 0
        }
        profile.slowCount = min(Self.requiredSlowCleanups, profile.slowCount + 1)
        profile.lastSlowAt = cleanup.completedAt
        profile.noticeDelay = baseline == nil ? 8 : 3
    }

    func noticeDelay(model: String, at uptime: TimeInterval) -> TimeInterval? {
        guard model == self.currentModel, let profile = self.profiles[model],
              profile.slowCount >= Self.requiredSlowCleanups, let recent = profile.lastSlowAt,
              (0...Self.evidenceLifetime).contains(uptime - recent) else { return nil }
        return profile.noticeDelay
    }

    mutating func resetEvidence() {
        for model in Array(self.profiles.keys) {
            self.profiles[model]?.slowCount = 0
            self.profiles[model]?.lastSlowAt = nil
        }
    }

    static func cooldownAllowsNotice(lastShown: Date?, now: Date) -> Bool {
        guard let lastShown else { return true }
        return now.timeIntervalSince(lastShown) >= Self.cooldown
    }
}
