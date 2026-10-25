import Combine
import Darwin
import Foundation

/// Experimental: tells the user, at most once per launch, that on-device cleanup is slow because
/// the Mac is short on memory. It needs both signals: several slow cleanups in a row and macOS
/// reporting memory pressure. A slow Mac with free memory, or pressure with fast cleanup, stays quiet.
@MainActor
final class LowMemorySlowdownMonitor: ObservableObject {
    static let shared = LowMemorySlowdownMonitor()
    static let message = "Low memory · cleanup may be slower"

    struct MemoryReading: Equatable {
        /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
        let pressureLevel: Int
        let swapUsedMB: Int
        let appFootprintMB: Int

        var isUnderPressure: Bool { self.pressureLevel >= 2 }

        static func current() -> MemoryReading {
            var level: Int32 = 0
            var levelSize = MemoryLayout<Int32>.size
            let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 ? Int(level) : 0

            var swap = xsw_usage()
            var swapSize = MemoryLayout<xsw_usage>.size
            let swapUsed = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 ? Int(swap.xsu_used / 1_048_576) : 0

            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            let footprint = result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
            return MemoryReading(pressureLevel: pressure, swapUsedMB: swapUsed, appFootprintMB: footprint)
        }
    }

    @Published private(set) var isNoticeVisible = false

    private var detector = CleanupSlowdownDetector()
    private var pending: AnalyticsLowMemoryWarning?
    private var hasShownThisLaunch = false
    private let readMemory: () -> MemoryReading
    private let report: (AnalyticsLowMemoryWarning) -> Void

    init(
        readMemory: @escaping () -> MemoryReading = MemoryReading.current,
        report: @escaping (AnalyticsLowMemoryWarning) -> Void = { AnalyticsService.shared.recordBetaLowMemoryWarning($0) }
    ) {
        self.readMemory = readMemory
        self.report = report
    }

    // Explicitly nonisolated: on macOS 15.4+ the synthesized main-actor deinit can abort until the OS runtime has the fix (swiftlang/swift#88036).
    nonisolated deinit {}

    /// Called after each on-device cleanup. Only Fluid Intelligence reports a speed.
    func recordCleanup(modelID: String?, tokensPerSecond: Double?, cleanupMilliseconds: Int?) {
        guard !self.hasShownThisLaunch, let modelID, let tokensPerSecond, tokensPerSecond.isFinite, tokensPerSecond > 0 else { return }
        guard let slowdown = self.detector.record(model: modelID, tokensPerSecond: tokensPerSecond) else {
            self.pending = nil
            return
        }
        let memory = self.readMemory()
        guard memory.isUnderPressure else {
            self.pending = nil
            return
        }
        self.pending = AnalyticsLowMemoryWarning(
            model: modelID,
            pressureLevel: memory.pressureLevel,
            swapUsedMB: memory.swapUsedMB,
            appFootprintMB: memory.appFootprintMB,
            recentTokensPerSecond: slowdown.recent.map { Int($0.rounded()) },
            usualTokensPerSecond: Int(slowdown.usual.rounded()),
            lastCleanupMilliseconds: cleanupMilliseconds
        )
    }

    /// Shows the notice on the next dictation, if memory is still under pressure.
    func dictationOverlayAppeared() {
        guard !self.hasShownThisLaunch, let pending else { return }
        let memory = self.readMemory()
        guard memory.isUnderPressure else { return }
        let warning = AnalyticsLowMemoryWarning(
            model: pending.model,
            pressureLevel: memory.pressureLevel,
            swapUsedMB: memory.swapUsedMB,
            appFootprintMB: memory.appFootprintMB,
            recentTokensPerSecond: pending.recentTokensPerSecond,
            usualTokensPerSecond: pending.usualTokensPerSecond,
            lastCleanupMilliseconds: pending.lastCleanupMilliseconds
        )
        self.hasShownThisLaunch = true
        self.pending = nil
        self.isNoticeVisible = true
        DebugLogger.shared.info(
            "LOW_MEMORY_WARNING model=\(warning.model) pressure=\(warning.pressureLevel) "
                + "swapMB=\(warning.swapUsedMB) appMB=\(warning.appFootprintMB) "
                + "recentTps=\(warning.recentTokensPerSecond) usualTps=\(warning.usualTokensPerSecond ?? -1) "
                + "cleanupMs=\(warning.lastCleanupMilliseconds ?? -1)",
            source: "LowMemorySlowdownMonitor"
        )
        self.report(warning)
    }

    func dictationOverlayDismissed() {
        self.isNoticeVisible = false
    }
}

/// Counts a cleanup as slow when it runs under half this Mac's usual speed for the model, or under
/// a floor no supported Mac should drop to without swapping. Compares a Mac with itself, so an M1 is
/// not judged against an M5. Judges nothing until it has seen enough cleanups to know the usual speed.
struct CleanupSlowdownDetector {
    struct Slowdown: Equatable {
        let recent: [Double]
        let usual: Double
    }

    static let streak = 3
    static let minimumBaselineSamples = 10
    static let historyLimit = 20
    static let slowFractionOfUsual = 0.5
    static let floorTokensPerSecond = 40.0

    private var samples: [String: [Double]] = [:]

    mutating func record(model: String, tokensPerSecond: Double) -> Slowdown? {
        var history = self.samples[model, default: []]
        history.append(tokensPerSecond)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        self.samples[model] = history
        guard history.count >= Self.minimumBaselineSamples + Self.streak else { return nil }

        let recent = Array(history.suffix(Self.streak))
        let earlier = history.dropLast(Self.streak).sorted()
        let usual = earlier[earlier.count / 2]
        let isSlow = { (speed: Double) in
            speed < Self.floorTokensPerSecond || speed < usual * Self.slowFractionOfUsual
        }
        return recent.allSatisfy(isSlow) ? Slowdown(recent: recent, usual: usual) : nil
    }
}
