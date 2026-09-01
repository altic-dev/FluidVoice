@testable import FluidVoice_Debug
import Foundation
import XCTest

final class AnalyticsDatabaseTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        self.temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidVoiceAnalyticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.temporaryDirectory)
    }

    func testActivityIsDeduplicatedAndUsageIsAggregatedByDay() throws {
        let database = try self.makeDatabase()
        let firstDay = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC
        let secondDay = firstDay.addingTimeInterval(24 * 60 * 60)
        let descriptor = AnalyticsModelDescriptor(provider: "Fluid Audio", model: "Parakeet TDT")

        try database.recordActivity(.app, at: firstDay)
        try database.recordActivity(.app, at: firstDay.addingTimeInterval(60))
        try database.recordUsage(mode: .dictation, transcriptionModel: descriptor, aiModel: nil, at: firstDay)
        try database.recordUsage(mode: .dictation, transcriptionModel: descriptor, aiModel: nil, at: firstDay)
        try database.finalizeDays(before: secondDay)

        let events = try self.events(in: database)
        XCTAssertEqual(events.filter { $0.name == AnalyticsEvent.activeUser.rawValue }.count, 1)

        let usage = try XCTUnwrap(events.first { $0.name == AnalyticsEvent.usageDailySummary.rawValue })
        XCTAssertEqual(usage.properties["dictation_count"] as? Int, 2)
        XCTAssertEqual(usage.properties["command_count"] as? Int, 0)
        XCTAssertEqual(usage.properties["ram_gb"] as? Int, 24)
        XCTAssertEqual(usage.properties["chip"] as? String, "Apple M3 Pro")

        let personProperties = try XCTUnwrap(usage.properties["$set"] as? [String: Any])
        XCTAssertEqual(personProperties["ram_gb"] as? Int, 24)
        XCTAssertEqual(personProperties["chip"] as? String, "Apple M3 Pro")

        let model = try XCTUnwrap(events.first { $0.name == AnalyticsEvent.modelUsageDailySummary.rawValue })
        XCTAssertEqual(model.properties["provider"] as? String, "fluid_audio")
        XCTAssertEqual(model.properties["model"] as? String, "parakeet_tdt")
        XCTAssertEqual(model.properties["use_count"] as? Int, 2)
    }

    func testAcknowledgementPurgesOutboxAndTruncatesWAL() throws {
        let databaseURL = self.temporaryDirectory.appendingPathComponent("analytics.sqlite3")
        let database = try self.makeDatabase(url: databaseURL)
        let flushDate = Date()
        try database.recordActivity(.app, at: flushDate.addingTimeInterval(-8 * 24 * 60 * 60))
        let items = try database.readyOutbox(limit: 50, at: flushDate)
        XCTAssertEqual(items.count, 1)

        try database.acknowledgeUploaded(ids: items.map(\.id), at: flushDate)

        XCTAssertTrue(try database.readyOutbox(limit: 50, at: flushDate).isEmpty)
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        if FileManager.default.fileExists(atPath: walURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: walURL.path)
            XCTAssertEqual(attributes[.size] as? UInt64, 0)
        }
    }

    func testDailyActivityWaitsForWeekEndWhileDetailedEventsRemainReady() throws {
        let database = try self.makeDatabase()
        let monday = Date(timeIntervalSince1970: 1_736_121_600) // 2025-01-06 UTC
        let nextMonday = monday.addingTimeInterval(7 * 24 * 60 * 60)

        try database.recordOnboardingStarted(origin: .firstRun, at: monday)
        for dayOffset in 1..<7 {
            try database.recordActivity(.app, at: monday.addingTimeInterval(Double(dayOffset * 24 * 60 * 60)))
        }

        let duringWeek = try self.events(in: database, at: nextMonday.addingTimeInterval(-1))
        XCTAssertEqual(duringWeek.map(\.name), [AnalyticsEvent.onboardingStarted.rawValue])

        let afterWeek = try self.events(in: database, at: nextMonday)
        XCTAssertEqual(afterWeek.filter { $0.name == AnalyticsEvent.activeUser.rawValue }.count, 7)
        XCTAssertEqual(afterWeek.filter { $0.name == AnalyticsEvent.onboardingStarted.rawValue }.count, 1)
    }

    func testInterruptedDownloadIsRecoveredWithoutDuration() throws {
        let databaseURL = self.temporaryDirectory.appendingPathComponent("analytics.sqlite3")
        let id = UUID().uuidString.lowercased()
        let descriptor = AnalyticsModelDescriptor(provider: "whisper", model: "large")

        do {
            let database = try self.makeDatabase(url: databaseURL)
            try database.recordModelDownloadStarted(
                id: id,
                descriptor: descriptor,
                source: .settings,
                at: Date(timeIntervalSince1970: 100)
            )
        }

        let recovered = try self.makeDatabase(url: databaseURL)
        try recovered.recoverInterruptedModelDownloads(at: Date(timeIntervalSince1970: 200))
        let finish = try XCTUnwrap(
            try self.events(in: recovered).first { $0.name == AnalyticsEvent.modelDownloadFinished.rawValue }
        )
        XCTAssertEqual(finish.properties["outcome"] as? String, "interrupted")
        XCTAssertNil(finish.properties["duration_seconds"])
    }

    func testDownloadFinishBeforeStartStillProducesOneCompletePair() throws {
        let database = try self.makeDatabase()
        let id = UUID().uuidString.lowercased()
        let descriptor = AnalyticsModelDescriptor(provider: "whisper", model: "large")
        let finishedAt = Date(timeIntervalSince1970: 200)

        try database.recordModelDownloadFinished(
            id: id,
            descriptor: descriptor,
            source: .settings,
            outcome: .succeeded,
            duration: 25,
            at: finishedAt
        )
        try database.recordModelDownloadStarted(
            id: id,
            descriptor: descriptor,
            source: .settings,
            at: finishedAt.addingTimeInterval(1)
        )

        let events = try self.events(in: database)
        XCTAssertEqual(events.filter { $0.name == AnalyticsEvent.modelDownloadStarted.rawValue }.count, 1)
        XCTAssertEqual(events.filter { $0.name == AnalyticsEvent.modelDownloadFinished.rawValue }.count, 1)
        let finish = try XCTUnwrap(events.first { $0.name == AnalyticsEvent.modelDownloadFinished.rawValue })
        XCTAssertEqual(finish.properties["duration_seconds"] as? Double, 25)
    }

    func testOnboardingTryoutTerminalEventAggregatesAttemptsAndDimensions() throws {
        let database = try self.makeDatabase()
        let enteredAt = Date(timeIntervalSince1970: 100)

        try database.recordOnboardingStepViewed(.playground, origin: .firstRun, at: enteredAt)
        try database.recordOnboardingTryoutAttemptStarted(
            startMethod: .hotkey,
            origin: .firstRun,
            at: enteredAt.addingTimeInterval(5)
        )
        try database.recordOnboardingTryoutAttemptResult(
            outcome: .empty,
            failureStage: nil,
            origin: .firstRun,
            at: enteredAt.addingTimeInterval(20)
        )
        try database.recordOnboardingTryoutAttemptStarted(
            startMethod: .button,
            origin: .firstRun,
            at: enteredAt.addingTimeInterval(35)
        )
        try database.finishOnboardingTryout(
            outcome: .success,
            failureStage: .postProcessing,
            origin: .firstRun,
            at: enteredAt.addingTimeInterval(75)
        )
        try database.finishOnboardingTryout(
            outcome: .error,
            failureStage: .transcription,
            origin: .firstRun,
            at: enteredAt.addingTimeInterval(80)
        )

        let events = try self.events(in: database)
        let tryoutEvents = events.filter { $0.name == AnalyticsEvent.onboardingTryoutFinished.rawValue }
        let tryout = try XCTUnwrap(tryoutEvents.first)
        XCTAssertEqual(tryoutEvents.count, 1)
        XCTAssertEqual(tryout.properties["outcome"] as? String, "success")
        XCTAssertEqual(tryout.properties["attempt_count_bucket"] as? String, "2")
        XCTAssertEqual(tryout.properties["duration_bucket"] as? String, "30s_plus")
        XCTAssertEqual(tryout.properties["start_method"] as? String, "button")
        XCTAssertEqual(tryout.properties["failure_stage"] as? String, "post_processing")
        XCTAssertEqual(tryout.properties["$os"] as? String, "macOS")
        XCTAssertEqual(tryout.properties["ram_gb"] as? Int, 24)
        XCTAssertEqual(tryout.properties["chip"] as? String, "Apple M3 Pro")
    }

    func testOnboardingTryoutSkipBeforeAttemptOmitsAttemptProperties() throws {
        let database = try self.makeDatabase()
        let enteredAt = Date(timeIntervalSince1970: 100)

        try database.recordOnboardingStepViewed(.playground, origin: .firstRun, at: enteredAt)
        try database.skipOnboardingTryout(origin: .firstRun, at: enteredAt.addingTimeInterval(10))

        let tryout = try XCTUnwrap(
            try self.events(in: database).first { $0.name == AnalyticsEvent.onboardingTryoutFinished.rawValue }
        )
        XCTAssertEqual(tryout.properties["outcome"] as? String, "skipped_before_attempt")
        XCTAssertEqual(tryout.properties["duration_bucket"] as? String, "10s")
        XCTAssertNil(tryout.properties["attempt_count_bucket"])
        XCTAssertNil(tryout.properties["start_method"])
    }

    func testOnboardingTryoutDurationUsesGranularSubThirtySecondBuckets() throws {
        let cases: [(duration: TimeInterval, bucket: String)] = [
            (0, "500ms"),
            (0.5, "500ms"),
            (0.501, "1s"),
            (1, "1s"),
            (1.001, "1_5s"),
            (1.5, "1_5s"),
            (1.501, "2s"),
            (5.2, "5_5s"),
            (10, "10s"),
            (20.01, "20_5s"),
            (29.9, "30s"),
            (30, "30s_plus"),
            (75, "30s_plus"),
        ]

        for (index, testCase) in cases.enumerated() {
            let databaseURL = self.temporaryDirectory
                .appendingPathComponent("analytics-duration-\(index).sqlite3")
            let database = try self.makeDatabase(url: databaseURL)
            let enteredAt = Date(timeIntervalSince1970: 100)

            try database.recordOnboardingStepViewed(.playground, origin: .firstRun, at: enteredAt)
            try database.skipOnboardingTryout(
                origin: .firstRun,
                at: enteredAt.addingTimeInterval(testCase.duration)
            )

            let tryout = try XCTUnwrap(
                try self.events(in: database).first {
                    $0.name == AnalyticsEvent.onboardingTryoutFinished.rawValue
                }
            )
            XCTAssertEqual(tryout.properties["duration_bucket"] as? String, testCase.bucket)
        }
    }

    func testOnboardingTryoutSkipAfterFailureRetainsAttemptContext() throws {
        let database = try self.makeDatabase()
        let enteredAt = Date(timeIntervalSince1970: 100)

        try database.recordOnboardingStepViewed(.playground, origin: .firstRun, at: enteredAt)
        try database.recordOnboardingTryoutAttemptStarted(
            startMethod: .hotkey,
            origin: .firstRun,
            at: enteredAt.addingTimeInterval(5)
        )
        try database.recordOnboardingTryoutAttemptResult(
            outcome: .error,
            failureStage: .transcription,
            origin: .firstRun,
            at: enteredAt.addingTimeInterval(15)
        )
        try database.skipOnboardingTryout(origin: .firstRun, at: enteredAt.addingTimeInterval(40))

        let tryout = try XCTUnwrap(
            try self.events(in: database).first { $0.name == AnalyticsEvent.onboardingTryoutFinished.rawValue }
        )
        XCTAssertEqual(tryout.properties["outcome"] as? String, "skipped_after_attempt")
        XCTAssertEqual(tryout.properties["attempt_count_bucket"] as? String, "1")
        XCTAssertEqual(tryout.properties["duration_bucket"] as? String, "30s_plus")
        XCTAssertEqual(tryout.properties["start_method"] as? String, "hotkey")
        XCTAssertEqual(tryout.properties["failure_stage"] as? String, "transcription")
    }

    func testOnboardingTryoutAttemptStateSurvivesDatabaseReopen() throws {
        let databaseURL = self.temporaryDirectory.appendingPathComponent("analytics.sqlite3")
        let enteredAt = Date(timeIntervalSince1970: 100)

        do {
            let database = try self.makeDatabase(url: databaseURL)
            try database.recordOnboardingStepViewed(.playground, origin: .firstRun, at: enteredAt)
            try database.recordOnboardingTryoutAttemptStarted(
                startMethod: .hotkey,
                origin: .firstRun,
                at: enteredAt.addingTimeInterval(5)
            )
            try database.recordOnboardingTryoutAttemptResult(
                outcome: .empty,
                failureStage: nil,
                origin: .firstRun,
                at: enteredAt.addingTimeInterval(15)
            )
        }

        let reopened = try self.makeDatabase(url: databaseURL)
        try reopened.recordOnboardingTryoutAttemptStarted(
            startMethod: .hotkey,
            origin: .firstRun,
            at: enteredAt.addingTimeInterval(30)
        )
        try reopened.finishOnboardingTryout(
            outcome: .success,
            failureStage: nil,
            origin: .firstRun,
            at: enteredAt.addingTimeInterval(65)
        )

        let tryout = try XCTUnwrap(
            try self.events(in: reopened).first { $0.name == AnalyticsEvent.onboardingTryoutFinished.rawValue }
        )
        XCTAssertEqual(tryout.properties["attempt_count_bucket"] as? String, "2")
        XCTAssertEqual(tryout.properties["duration_bucket"] as? String, "30s_plus")
    }

    func testDetailedConsentGateRejectsWorkQueuedBeforeOptOut() {
        let gate = DetailedAnalyticsConsentGate()
        let queuedGeneration = gate.currentGeneration
        let currentGeneration = gate.advance()

        XCTAssertFalse(gate.accepts(queuedGeneration))
        XCTAssertTrue(gate.accepts(currentGeneration))
    }

    func testPurgingDetailedAnalyticsPreservesOnlyDailyActivity() throws {
        let database = try self.makeDatabase()
        let firstDay = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC
        let secondDay = firstDay.addingTimeInterval(24 * 60 * 60)
        let descriptor = AnalyticsModelDescriptor(provider: "Fluid Audio", model: "Parakeet TDT")
        let downloadID = UUID().uuidString.lowercased()

        try database.recordActivity(.app, at: firstDay)
        try database.recordUsage(mode: .dictation, transcriptionModel: descriptor, aiModel: nil, at: firstDay)
        try database.recordOnboardingStarted(origin: .firstRun, at: firstDay)
        try database.recordOnboardingStepViewed(.welcome, origin: .firstRun, at: firstDay)
        try database.recordModelDownloadStarted(
            id: downloadID,
            descriptor: descriptor,
            source: .onboarding,
            at: firstDay
        )
        try database.finalizeDays(before: secondDay)

        try database.purgeDetailedAnalytics()

        var events = try self.events(in: database)
        XCTAssertEqual(events.map(\.name), [AnalyticsEvent.activeUser.rawValue])

        try database.recordActivity(.coreAction, at: firstDay.addingTimeInterval(60))
        try database.finalizeDays(before: secondDay.addingTimeInterval(24 * 60 * 60))

        events = try self.events(in: database)
        XCTAssertEqual(events.map(\.name), [AnalyticsEvent.activeUser.rawValue])
    }

    private func makeDatabase(url: URL? = nil) throws -> AnalyticsDatabase {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 2
        return try AnalyticsDatabase(
            url: url ?? self.temporaryDirectory.appendingPathComponent("analytics.sqlite3"),
            distinctID: "test-install-id",
            appVersion: "test",
            systemConfiguration: AnalyticsSystemConfiguration(ramGB: 24, chip: "Apple M3 Pro"),
            calendar: calendar
        )
    }

    private func events(
        in database: AnalyticsDatabase,
        at date: Date = .distantFuture
    ) throws -> [(name: String, properties: [String: Any])] {
        try database.readyOutbox(limit: 100, at: date).map { item in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: item.payload) as? [String: Any])
            let name = try XCTUnwrap(object["event"] as? String)
            let properties = try XCTUnwrap(object["properties"] as? [String: Any])
            return (name, properties)
        }
    }
}
