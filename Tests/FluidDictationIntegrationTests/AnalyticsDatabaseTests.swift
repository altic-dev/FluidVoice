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
