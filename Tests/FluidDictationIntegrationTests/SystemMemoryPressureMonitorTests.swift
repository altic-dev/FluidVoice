@testable import FluidVoice_Debug
import XCTest

final class MemoryPressureEvaluatorTests: XCTestCase {
    private func run(_ samples: [Int]) -> Bool {
        var evaluator = MemoryPressureEvaluator()
        for percent in samples {
            evaluator.observe(availablePercent: percent)
        }
        return evaluator.isConstrained
    }

    func testHealthyMachineStaysClear() {
        XCTAssertFalse(self.run([94, 75, 51]))
    }

    func testNeedsTwoConsecutiveLowSamples() {
        XCTAssertFalse(self.run([48]))
        XCTAssertFalse(self.run([48, 70, 49]))
        XCTAssertTrue(self.run([48, 46]))
        // An in-band sample breaks the streak while not yet constrained.
        XCTAssertFalse(self.run([48, 55, 49]))
    }

    func testClearsOnlyAtExitThreshold() {
        XCTAssertTrue(self.run([48, 46, 59]))
        XCTAssertTrue(self.run([48, 46, 55, 55]))
        XCTAssertFalse(self.run([48, 46, 60]))
    }
}

@MainActor
final class SystemMemoryPressureMonitorTests: XCTestCase {
    func testKernelReadSucceedsOnThisMac() throws {
        let percent = try XCTUnwrap(SystemMemoryPressureMonitor.readAvailableMemoryPercent())
        XCTAssertTrue((0...100).contains(percent))
        XCTAssertTrue(SystemMemoryPressureMonitor.diagnosticsSummary().hasPrefix("sysAvailMem="))
    }

    func testSettingDefaultsOnAndRoundTripsThroughBackup() {
        let key = "ShowSystemLoadAlerts"
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer { previous.map { defaults.set($0, forKey: key) } ?? defaults.removeObject(forKey: key) }

        defaults.removeObject(forKey: key)
        XCTAssertTrue(SettingsStore.shared.showSystemLoadAlerts)
        SettingsStore.shared.showSystemLoadAlerts = false
        XCTAssertEqual(SettingsStore.shared.makeBackupPayload().showSystemLoadAlerts, false)
    }
}
