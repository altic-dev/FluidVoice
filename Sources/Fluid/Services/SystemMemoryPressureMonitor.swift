//
//  SystemMemoryPressureMonitor.swift
//  Fluid
//
//  Tells the dictation overlay when the Mac is low on memory. Everything Fluid
//  runs lives in unified memory; when other apps fill RAM, macOS evicts the idle
//  model pages and the next request pays to bring them back.
//
//  Signal: `kern.memorystatus_level`, the percent of RAM that is neither wired
//  nor compressed (Activity Monitor's pressure graph is 100 minus this).
//  The kernel's own warn/critical level is deliberately not used: it was observed
//  stuck at "warn" for minutes with 94% available (tasks/memory-pressure-toast.md).
//

import Combine
import Foundation

/// Pure hysteresis over available-memory samples. Unit tested.
nonisolated struct MemoryPressureEvaluator {
    var enterPercent = 50
    var exitPercent = 60
    private(set) var lowStreak = 0
    private(set) var isConstrained = false

    mutating func observe(availablePercent percent: Int) {
        if percent <= self.enterPercent {
            self.lowStreak += 1
        } else if !self.isConstrained || percent >= self.exitPercent {
            // Any non-low sample breaks the streak; while constrained, the band below
            // `exitPercent` keeps it so the chip does not flicker.
            self.lowStreak = 0
        }
        // Two consecutive low samples to enter; stay until memory rises to `exitPercent`.
        self.isConstrained = self.lowStreak >= 2 || (self.isConstrained && percent < self.exitPercent)
    }
}

@MainActor
final class SystemMemoryPressureMonitor: ObservableObject {
    static let shared = SystemMemoryPressureMonitor()

    @Published private(set) var isConstrained = false

    private var evaluator = MemoryPressureEvaluator()
    private var source: DispatchSourceMemoryPressure?
    private var timer: Timer?

    /// One sysctl per 10 s, plus an extra sample on kernel pressure events. Idempotent.
    func start() {
        guard self.source == nil else { return }
        // `FLUID_MEMORY_ADVISORY_THRESHOLD=99` shows the chip on any Mac for manual testing.
        if let raw = ProcessInfo.processInfo.environment["FLUID_MEMORY_ADVISORY_THRESHOLD"],
           let enter = Int(raw), (1...100).contains(enter)
        {
            self.evaluator.enterPercent = enter
            self.evaluator.exitPercent = min(enter + 10, 100)
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.activate()
        self.source = source

        self.timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer?.tolerance = 5
        self.refresh()
    }

    private func refresh() {
        guard let percent = Self.readAvailableMemoryPercent() else { return }
        let was = self.evaluator.isConstrained
        self.evaluator.observe(availablePercent: percent)
        guard self.evaluator.isConstrained != was else { return }
        self.isConstrained = self.evaluator.isConstrained
        DebugLogger.shared.info("Memory constrained=\(self.isConstrained) available=\(percent)%", source: "SystemMemory")
    }

    /// For diagnostics log lines, read fresh from the kernel.
    nonisolated static func diagnosticsSummary() -> String {
        "sysAvailMem=\(self.readAvailableMemoryPercent().map { "\($0)%" } ?? "?")"
    }

    /// `kern.memorystatus_level`: percent of RAM that is neither wired nor compressed.
    nonisolated static func readAvailableMemoryPercent() -> Int? {
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        return sysctlbyname("kern.memorystatus_level", &value, &size, nil, 0) == 0 ? Int(min(value, 100)) : nil
    }
}
