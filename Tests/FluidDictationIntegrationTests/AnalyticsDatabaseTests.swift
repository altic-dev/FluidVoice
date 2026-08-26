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

        let model = try XCTUnwrap(events.first { $0.name == AnalyticsEvent.modelUsageDailySummary.rawValue })
        XCTAssertEqual(model.properties["provider"] as? String, "fluid_audio")
        XCTAssertEqual(model.properties["model"] as? String, "parakeet_tdt")
        XCTAssertEqual(model.properties["use_count"] as? Int, 2)
    }

    func testInsertionLatencyIsAggregatedUntilTheDayIsFinalized() throws {
        let database = try self.makeDatabase()
        let firstDay = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 UTC
        let secondDay = firstDay.addingTimeInterval(24 * 60 * 60)

        try database.recordInsertionLatency(
            path: .direct,
            outcome: .dispatched,
            requestMilliseconds: 10,
            readyMilliseconds: 40,
            at: firstDay
        )
        try database.recordInsertionLatency(
            path: .direct,
            outcome: .dispatched,
            requestMilliseconds: 20,
            readyMilliseconds: nil,
            at: firstDay.addingTimeInterval(60)
        )
        try database.recordInsertionLatency(
            path: .direct,
            outcome: .dispatched,
            requestMilliseconds: 35,
            readyMilliseconds: 70,
            at: firstDay.addingTimeInterval(120)
        )

        XCTAssertTrue(try self.events(in: database).isEmpty)

        try database.finalizeDays(before: secondDay)
        let summary = try XCTUnwrap(
            try self.events(in: database).first {
                $0.name == AnalyticsEvent.insertionLatencyDailySummary.rawValue
            }
        )
        XCTAssertEqual(summary.properties["latency_date"] as? String, "2025-01-01")
        XCTAssertEqual(summary.properties["delivery_path"] as? String, "direct")
        XCTAssertEqual(summary.properties["outcome"] as? String, "dispatched")
        XCTAssertEqual(summary.properties["request_count"] as? Int, 3)
        XCTAssertEqual(summary.properties["request_total_ms"] as? Int, 65)
        XCTAssertEqual(summary.properties["request_average_ms"] as? Double, 21.7)
        XCTAssertEqual(summary.properties["request_min_ms"] as? Int, 10)
        XCTAssertEqual(summary.properties["request_max_ms"] as? Int, 35)
        XCTAssertEqual(summary.properties["ready_count"] as? Int, 2)
        XCTAssertEqual(summary.properties["ready_total_ms"] as? Int, 110)
        XCTAssertEqual(summary.properties["ready_average_ms"] as? Double, 55)
        XCTAssertEqual(summary.properties["ready_min_ms"] as? Int, 40)
        XCTAssertEqual(summary.properties["ready_max_ms"] as? Int, 70)

        try database.finalizeDays(before: secondDay.addingTimeInterval(60))
        let summaries = try self.events(in: database).filter {
            $0.name == AnalyticsEvent.insertionLatencyDailySummary.rawValue
        }
        XCTAssertEqual(summaries.count, 1)
    }

    func testInsertionLatencySeparatesPathsAndOutcomes() throws {
        let database = try self.makeDatabase()
        let firstDay = Date(timeIntervalSince1970: 1_735_689_600)
        let secondDay = firstDay.addingTimeInterval(24 * 60 * 60)

        try database.recordInsertionLatency(
            path: .clipboard,
            outcome: .dispatched,
            requestMilliseconds: 5,
            readyMilliseconds: nil,
            at: firstDay
        )
        try database.recordInsertionLatency(
            path: .clipboardFallback,
            outcome: .pasteCommandFailed,
            requestMilliseconds: 12,
            readyMilliseconds: nil,
            at: firstDay
        )
        try database.recordInsertionLatency(
            path: .notAttempted,
            outcome: .accessibilityNotTrusted,
            requestMilliseconds: -4,
            readyMilliseconds: nil,
            at: firstDay
        )
        try database.finalizeDays(before: secondDay)

        let summaries = try self.events(in: database).filter {
            $0.name == AnalyticsEvent.insertionLatencyDailySummary.rawValue
        }
        XCTAssertEqual(summaries.count, 3)
        XCTAssertTrue(summaries.contains {
            $0.properties["delivery_path"] as? String == "clipboard" &&
                $0.properties["outcome"] as? String == "dispatched"
        })
        XCTAssertTrue(summaries.contains {
            $0.properties["delivery_path"] as? String == "clipboard_fallback" &&
                $0.properties["outcome"] as? String == "paste_command_failed"
        })
        let rejected = try XCTUnwrap(summaries.first {
            $0.properties["delivery_path"] as? String == "not_attempted"
        })
        XCTAssertEqual(rejected.properties["request_min_ms"] as? Int, 0)
        XCTAssertEqual(rejected.properties["ready_count"] as? Int, 0)
        XCTAssertNil(rejected.properties["ready_total_ms"])
        XCTAssertNil(rejected.properties["ready_average_ms"])
        XCTAssertNil(rejected.properties["ready_min_ms"])
        XCTAssertNil(rejected.properties["ready_max_ms"])
    }

    func testClipboardToggleLatencyAggregatesOnlySuccessfulClipboardDispatches() throws {
        let database = try self.makeDatabase()
        let firstDay = Date(timeIntervalSince1970: 1_735_689_600)
        let secondDay = firstDay.addingTimeInterval(24 * 60 * 60)

        try database.recordInsertionLatency(
            path: .clipboard,
            outcome: .dispatched,
            requestMilliseconds: 4,
            readyMilliseconds: 12,
            toggleStopMilliseconds: 100,
            at: firstDay
        )
        try database.recordInsertionLatency(
            path: .clipboard,
            outcome: .dispatched,
            requestMilliseconds: 5,
            readyMilliseconds: 15,
            toggleStopMilliseconds: 250,
            at: firstDay
        )
        try database.recordInsertionLatency(
            path: .clipboardFallback,
            outcome: .dispatched,
            requestMilliseconds: 7,
            readyMilliseconds: 18,
            toggleStopMilliseconds: 400,
            at: firstDay
        )
        try database.recordInsertionLatency(
            path: .direct,
            outcome: .dispatched,
            requestMilliseconds: 3,
            readyMilliseconds: 10,
            toggleStopMilliseconds: 500,
            at: firstDay
        )
        try database.recordInsertionLatency(
            path: .clipboard,
            outcome: .pasteCommandFailed,
            requestMilliseconds: 6,
            readyMilliseconds: 20,
            toggleStopMilliseconds: 600,
            at: firstDay
        )

        XCTAssertTrue(try self.events(in: database).isEmpty)
        try database.finalizeDays(before: secondDay)

        let summaries = try self.events(in: database).filter {
            $0.name == AnalyticsEvent.insertionLatencyDailySummary.rawValue &&
                $0.properties["outcome"] as? String == "dispatched" &&
                $0.properties["toggle_stop_to_dispatch_count"] != nil
        }
        XCTAssertEqual(summaries.count, 2)
        let clipboard = try XCTUnwrap(summaries.first {
            $0.properties["delivery_path"] as? String == "clipboard"
        })
        XCTAssertEqual(clipboard.properties["outcome"] as? String, "dispatched")
        XCTAssertEqual(clipboard.properties["toggle_stop_to_dispatch_count"] as? Int, 2)
        XCTAssertEqual(clipboard.properties["toggle_stop_to_dispatch_total_ms"] as? Int, 350)
        XCTAssertEqual(clipboard.properties["toggle_stop_to_dispatch_average_ms"] as? Double, 175)
        XCTAssertEqual(clipboard.properties["toggle_stop_to_dispatch_min_ms"] as? Int, 100)
        XCTAssertEqual(clipboard.properties["toggle_stop_to_dispatch_max_ms"] as? Int, 250)

        let fallback = try XCTUnwrap(summaries.first {
            $0.properties["delivery_path"] as? String == "clipboard_fallback"
        })
        XCTAssertEqual(fallback.properties["toggle_stop_to_dispatch_count"] as? Int, 1)
        XCTAssertEqual(fallback.properties["toggle_stop_to_dispatch_average_ms"] as? Double, 400)

        let failedClipboard = try XCTUnwrap(try self.events(in: database).first {
            $0.name == AnalyticsEvent.insertionLatencyDailySummary.rawValue &&
                $0.properties["delivery_path"] as? String == "clipboard" &&
                $0.properties["outcome"] as? String == "paste_command_failed"
        })
        XCTAssertNil(failedClipboard.properties["toggle_stop_to_dispatch_count"])
    }

    func testInsertionLatencySurvivesReopeningAndIsPurgedOnOptOut() throws {
        let databaseURL = self.temporaryDirectory.appendingPathComponent("analytics.sqlite3")
        let firstDay = Date(timeIntervalSince1970: 1_735_689_600)
        let secondDay = firstDay.addingTimeInterval(24 * 60 * 60)

        do {
            let database = try self.makeDatabase(url: databaseURL)
            try database.recordInsertionLatency(
                path: .clipboard,
                outcome: .dispatched,
                requestMilliseconds: 8,
                readyMilliseconds: 18,
                toggleStopMilliseconds: 28,
                at: firstDay
            )
        }

        do {
            let reopened = try self.makeDatabase(url: databaseURL)
            try reopened.finalizeDays(before: secondDay)
            let summaries = try self.events(in: reopened).filter {
                $0.name == AnalyticsEvent.insertionLatencyDailySummary.rawValue
            }
            XCTAssertEqual(summaries.count, 1)
            XCTAssertEqual(summaries.first?.properties["toggle_stop_to_dispatch_count"] as? Int, 1)
            XCTAssertEqual(summaries.first?.properties["toggle_stop_to_dispatch_average_ms"] as? Double, 28)
        }

        let reopened = try self.makeDatabase(url: databaseURL)
        try reopened.recordInsertionLatency(
            path: .clipboard,
            outcome: .dispatched,
            requestMilliseconds: 4,
            readyMilliseconds: nil,
            toggleStopMilliseconds: 12,
            at: secondDay
        )
        try reopened.purgeAll()
        XCTAssertTrue(try self.events(in: reopened).isEmpty)
        try reopened.finalizeDays(before: secondDay.addingTimeInterval(24 * 60 * 60))
        XCTAssertTrue(try self.events(in: reopened).isEmpty)
    }

    func testAcknowledgementPurgesOutboxAndTruncatesWAL() throws {
        let databaseURL = self.temporaryDirectory.appendingPathComponent("analytics.sqlite3")
        let database = try self.makeDatabase(url: databaseURL)
        try database.recordActivity(.app, at: Date())
        let items = try database.readyOutbox(limit: 50, at: Date())
        XCTAssertEqual(items.count, 1)

        try database.acknowledgeUploaded(ids: items.map(\.id), at: Date())

        XCTAssertTrue(try database.readyOutbox(limit: 50, at: Date()).isEmpty)
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        if FileManager.default.fileExists(atPath: walURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: walURL.path)
            XCTAssertEqual(attributes[.size] as? UInt64, 0)
        }
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

    func testConsentGateRejectsWorkQueuedBeforeOptOut() {
        let gate = AnalyticsConsentGate()
        let queuedGeneration = gate.currentGeneration
        let currentGeneration = gate.advance()

        XCTAssertFalse(gate.accepts(queuedGeneration))
        XCTAssertTrue(gate.accepts(currentGeneration))
    }

    private func makeDatabase(url: URL? = nil) throws -> AnalyticsDatabase {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        return try AnalyticsDatabase(
            url: url ?? self.temporaryDirectory.appendingPathComponent("analytics.sqlite3"),
            distinctID: "test-install-id",
            appVersion: "test",
            calendar: calendar
        )
    }

    private func events(in database: AnalyticsDatabase) throws -> [(name: String, properties: [String: Any])] {
        try database.readyOutbox(limit: 100, at: Date.distantFuture).map { item in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: item.payload) as? [String: Any])
            let name = try XCTUnwrap(object["event"] as? String)
            let properties = try XCTUnwrap(object["properties"] as? [String: Any])
            return (name, properties)
        }
    }
}
