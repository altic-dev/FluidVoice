@testable import FluidVoice_Debug
import Foundation
import XCTest

final class HistoryAutoClearIntervalTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) throws -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return try XCTUnwrap(self.calendar.date(from: components))
    }

    func testNeverHasNoCutoff() {
        XCTAssertNil(SettingsStore.HistoryAutoClearInterval.never.cutoffDate(relativeTo: Date(), calendar: self.calendar))
    }

    func testEndOfDayCutoffIsStartOfToday() throws {
        let now = try self.date(2026, 7, 2, hour: 15, minute: 30)

        let cutoff = SettingsStore.HistoryAutoClearInterval.endOfDay.cutoffDate(relativeTo: now, calendar: self.calendar)

        XCTAssertEqual(cutoff, try self.date(2026, 7, 2))
    }

    func testEndOfDayKeepsTodayAndExpiresYesterday() throws {
        let now = try self.date(2026, 7, 2, hour: 9)
        let cutoff = try XCTUnwrap(
            SettingsStore.HistoryAutoClearInterval.endOfDay.cutoffDate(relativeTo: now, calendar: self.calendar)
        )

        let earlierToday = try self.date(2026, 7, 2, hour: 0, minute: 1)
        let lateYesterday = try self.date(2026, 7, 1, hour: 23, minute: 59)

        XCTAssertFalse(earlierToday < cutoff, "Today's entries must survive an end-of-day prune")
        XCTAssertTrue(lateYesterday < cutoff, "Yesterday's entries must expire after midnight")
    }

    func testRollingIntervalsAnchorToStartOfDay() throws {
        let now = try self.date(2026, 7, 2, hour: 18, minute: 45)

        XCTAssertEqual(
            SettingsStore.HistoryAutoClearInterval.afterWeek.cutoffDate(relativeTo: now, calendar: self.calendar),
            try self.date(2026, 6, 25)
        )
        XCTAssertEqual(
            SettingsStore.HistoryAutoClearInterval.afterMonth.cutoffDate(relativeTo: now, calendar: self.calendar),
            try self.date(2026, 6, 2)
        )
        XCTAssertEqual(
            SettingsStore.HistoryAutoClearInterval.afterQuarter.cutoffDate(relativeTo: now, calendar: self.calendar),
            try self.date(2026, 4, 3)
        )
    }

    func testUnknownPersistedValueFallsBackSafely() {
        XCTAssertNil(SettingsStore.HistoryAutoClearInterval(rawValue: "sometimes"))
        XCTAssertEqual(SettingsStore.HistoryAutoClearInterval(rawValue: "endOfDay"), .endOfDay)
    }
}
