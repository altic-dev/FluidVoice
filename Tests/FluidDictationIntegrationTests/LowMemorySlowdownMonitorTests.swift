@testable import FluidVoice_Debug
import XCTest

final class LowMemorySlowdownMonitorTests: XCTestCase {
    private typealias Reading = LowMemorySlowdownMonitor.MemoryReading

    private let normal = Reading(pressureLevel: 1, swapUsedMB: 0, appFootprintMB: 900)
    private let warning = Reading(pressureLevel: 2, swapUsedMB: 2048, appFootprintMB: 2600)

    private let usualSpeeds: [Double] = [400, 420, 380, 410, 400, 390, 405, 415, 395, 400]

    func testThreeCleanupsUnderHalfTheUsualSpeedAreASlowdown() {
        var detector = CleanupSlowdownDetector()
        for speed in self.usualSpeeds + [150, 160] {
            XCTAssertNil(detector.record(model: "fluid-1.1-splash", tokensPerSecond: speed))
        }
        XCTAssertEqual(
            detector.record(model: "fluid-1.1-splash", tokensPerSecond: 140),
            CleanupSlowdownDetector.Slowdown(recent: [150, 160, 140], usual: 400)
        )
    }

    func testOneFastCleanupBreaksTheStreak() {
        var detector = CleanupSlowdownDetector()
        for speed in self.usualSpeeds + [150, 160] {
            _ = detector.record(model: "fluid-1.1-splash", tokensPerSecond: speed)
        }
        XCTAssertNil(detector.record(model: "fluid-1.1-splash", tokensPerSecond: 390))
    }

    func testASteadilySlowMacIsComparedWithItself() {
        var detector = CleanupSlowdownDetector()
        for speed in [90.0, 95, 85, 92, 88, 90, 86, 91, 89, 93, 87, 90, 94, 88, 91] {
            XCTAssertNil(detector.record(model: "fluid-1.1-splash", tokensPerSecond: speed))
        }
    }

    func testNothingIsJudgedBeforeTenCleanupsSetTheUsualSpeed() {
        var detector = CleanupSlowdownDetector()
        for _ in 0..<12 {
            XCTAssertNil(detector.record(model: "fluid-1-mini-96k-dflash", tokensPerSecond: 20))
        }
        XCTAssertEqual(
            detector.record(model: "fluid-1-mini-96k-dflash", tokensPerSecond: 20),
            CleanupSlowdownDetector.Slowdown(recent: [20, 20, 20], usual: 20)
        )
    }

    func testModelsKeepSeparateHistories() {
        var detector = CleanupSlowdownDetector()
        for _ in 0..<12 {
            XCTAssertNil(detector.record(model: "a", tokensPerSecond: 20))
            XCTAssertNil(detector.record(model: "b", tokensPerSecond: 20))
        }
        XCTAssertNotNil(detector.record(model: "a", tokensPerSecond: 20))
    }

    @MainActor
    func testSlowCleanupUnderPressureShowsOnceOnTheNextDictationAndReportsIt() {
        var reports: [AnalyticsLowMemoryWarning] = []
        var memory = self.warning
        let monitor = LowMemorySlowdownMonitor(readMemory: { memory }, report: { reports.append($0) })
        for _ in 0..<13 {
            monitor.recordCleanup(modelID: "fluid-1.1-splash", tokensPerSecond: 20, cleanupMilliseconds: 4200)
        }
        XCTAssertFalse(monitor.isNoticeVisible)

        memory = Reading(pressureLevel: 4, swapUsedMB: 3072, appFootprintMB: 2700)
        monitor.dictationOverlayAppeared()
        XCTAssertTrue(monitor.isNoticeVisible)
        XCTAssertEqual(reports, [AnalyticsLowMemoryWarning(
            model: "fluid-1.1-splash",
            pressureLevel: 4,
            swapUsedMB: 3072,
            appFootprintMB: 2700,
            recentTokensPerSecond: [20, 20, 20],
            usualTokensPerSecond: 20,
            lastCleanupMilliseconds: 4200
        )])

        monitor.dictationOverlayDismissed()
        XCTAssertFalse(monitor.isNoticeVisible)
        for _ in 0..<13 {
            monitor.recordCleanup(modelID: "fluid-1.1-splash", tokensPerSecond: 20, cleanupMilliseconds: 4200)
        }
        monitor.dictationOverlayAppeared()
        XCTAssertFalse(monitor.isNoticeVisible)
        XCTAssertEqual(reports.count, 1)
    }

    @MainActor
    func testSlowCleanupWithFreeMemoryStaysQuiet() {
        var reports: [AnalyticsLowMemoryWarning] = []
        let monitor = LowMemorySlowdownMonitor(readMemory: { self.normal }, report: { reports.append($0) })
        for _ in 0..<13 {
            monitor.recordCleanup(modelID: "fluid-1.1-splash", tokensPerSecond: 20, cleanupMilliseconds: 4200)
        }
        monitor.dictationOverlayAppeared()
        XCTAssertFalse(monitor.isNoticeVisible)
        XCTAssertTrue(reports.isEmpty)
    }

    @MainActor
    func testPressureThatClearsBeforeTheNextDictationStaysQuiet() {
        var reports: [AnalyticsLowMemoryWarning] = []
        var memory = self.warning
        let monitor = LowMemorySlowdownMonitor(readMemory: { memory }, report: { reports.append($0) })
        for _ in 0..<13 {
            monitor.recordCleanup(modelID: "fluid-1.1-splash", tokensPerSecond: 20, cleanupMilliseconds: 4200)
        }
        memory = self.normal
        monitor.dictationOverlayAppeared()
        XCTAssertFalse(monitor.isNoticeVisible)
        XCTAssertTrue(reports.isEmpty)
    }

    @MainActor
    func testCleanupsWithoutASpeedAreIgnored() {
        let monitor = LowMemorySlowdownMonitor(readMemory: { self.warning }, report: { _ in XCTFail("no report") })
        for _ in 0..<13 {
            monitor.recordCleanup(modelID: "gpt-5", tokensPerSecond: nil, cleanupMilliseconds: 4200)
        }
        monitor.dictationOverlayAppeared()
        XCTAssertFalse(monitor.isNoticeVisible)
    }

    func testTheLiveMemoryReadingWorksOnThisMac() {
        let reading = LowMemorySlowdownMonitor.MemoryReading.current()
        XCTAssertTrue([1, 2, 4].contains(reading.pressureLevel), "\(reading)")
        XCTAssertGreaterThan(reading.appFootprintMB, 0)
    }
}
