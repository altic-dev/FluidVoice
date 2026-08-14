import Foundation
@testable import Voix_Debug
import XCTest

final class PracticeSessionStoreTests: XCTestCase {
    func testSessionRoundTripsThroughCodable() throws {
        let session = self.makeSession(transcript: "um so the plan is ready")

        let data = try PracticeSessionStore.encoder.encode([session])
        let decoded = try PracticeSessionStore.decoder.decode([PracticeSession].self, from: data)

        XCTAssertEqual(decoded, [session])
    }

    /// Exact, not to-the-second: a lossy date strategy would silently break
    /// `PracticeSession`'s Equatable conformance across a save/load cycle.
    func testDateSurvivesRoundTripExactly() throws {
        let session = self.makeSession(transcript: "the plan")

        let data = try PracticeSessionStore.encoder.encode([session])
        let decoded = try PracticeSessionStore.decoder.decode([PracticeSession].self, from: data)

        XCTAssertEqual(decoded[0].date, session.date)
    }

    func testMetricsSurviveRoundTrip() throws {
        let session = self.makeSession(transcript: "the plan")

        let data = try PracticeSessionStore.encoder.encode([session])
        let decoded = try PracticeSessionStore.decoder.decode([PracticeSession].self, from: data)

        XCTAssertEqual(decoded[0].metrics, session.metrics)
        XCTAssertEqual(decoded[0].metrics.pitchContour, session.metrics.pitchContour)
        XCTAssertEqual(decoded[0].metrics.pauses.count, session.metrics.pauses.count)
    }

    func testCoachingErrorIsPreservedForSessionsWithoutFeedback() throws {
        let session = PracticeSession(
            durationSeconds: 12,
            transcript: "the plan",
            feedback: "",
            model: "",
            coachingError: "No verified AI provider selected",
            metrics: .empty
        )

        let data = try PracticeSessionStore.encoder.encode([session])
        let decoded = try PracticeSessionStore.decoder.decode([PracticeSession].self, from: data)

        XCTAssertEqual(decoded[0].coachingError, "No verified AI provider selected")
        XCTAssertTrue(decoded[0].feedback.isEmpty)
    }

    /// Files written before the signal-quality gate lack `metrics.quality`. They
    /// must load with their measurements intact, flagged as never-assessed —
    /// not be wiped for missing one key.
    func testPreGateFileLoadsWithQualityDefaultingToUnknown() throws {
        let session = self.makeSession(transcript: "the plan")
        let data = try PracticeSessionStore.encoder.encode([session])

        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        var metrics = try XCTUnwrap(json[0]["metrics"] as? [String: Any])
        metrics.removeValue(forKey: "quality")
        json[0]["metrics"] = metrics
        let preGateData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try PracticeSessionStore.decodeSessions(from: preGateData)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].metrics.wordsPerMinute, session.metrics.wordsPerMinute)
        XCTAssertEqual(decoded[0].metrics.pitchContour, session.metrics.pitchContour)
        XCTAssertEqual(decoded[0].metrics.quality, .unknown)
    }

    /// One mangled entry drops that entry, never the neighbors around it.
    func testCorruptEntryIsDroppedWithoutWipingTheRest() throws {
        let keeper = self.makeSession(transcript: "the plan")
        let data = try PracticeSessionStore.encoder.encode([keeper, keeper])

        var json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        json[0]["date"] = "not a date"
        let corruptData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try PracticeSessionStore.decodeSessions(from: corruptData)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].transcript, keeper.transcript)
    }

    func testFormattedDurationRendersMinutesAndSeconds() {
        XCTAssertEqual(self.makeSession(duration: 0).formattedDuration, "0:00")
        XCTAssertEqual(self.makeSession(duration: 9).formattedDuration, "0:09")
        XCTAssertEqual(self.makeSession(duration: 65).formattedDuration, "1:05")
        XCTAssertEqual(self.makeSession(duration: 600).formattedDuration, "10:00")
    }

    func testPreviewTruncatesLongTranscripts() {
        let long = String(repeating: "word ", count: 100)
        let preview = self.makeSession(transcript: long).previewText

        XCTAssertEqual(preview.count, 80)
        XCTAssertTrue(preview.hasSuffix("..."))
    }

    // MARK: - Helpers

    private func makeSession(transcript: String = "the plan", duration: Double = 30) -> PracticeSession {
        PracticeSession(
            durationSeconds: duration,
            transcript: transcript,
            feedback: "## Core message\nThe plan is ready.",
            model: "test-model",
            metrics: self.makeMetrics()
        )
    }

    /// Runs the real analyzer so the persisted shape matches what the app stores,
    /// rather than a hand-built struct that could drift from it.
    private func makeMetrics() -> DeliveryMetrics {
        let sampleRate = 16_000.0
        var pcm = [Float](repeating: 0, count: Int(sampleRate))
        for index in 0..<pcm.count {
            pcm[index] = 0.4 * Float(sin(2 * .pi * 150 * Double(index) / sampleRate))
        }
        pcm += [Float](repeating: 0, count: Int(sampleRate))
        pcm += pcm.prefix(Int(sampleRate))

        return SpeechAnalysisService.analyze(
            pcm: pcm,
            sampleRate: sampleRate,
            rawTranscript: "um so the plan is ready",
            fillerWords: ["um"]
        )
    }
}
