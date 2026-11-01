@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingLiveAPIModelsTests: XCTestCase {
    func test_response_mapsUtterancesAndSpeakers() throws {
        let sessionID = UUID()
        let you = MeetingLiveUtterance(id: UUID(), speaker: .you, text: "Hello there", start: 1.25, end: 2.5)
        let them = MeetingLiveUtterance(id: UUID(), speaker: .them, text: "Hi 👋", start: 3.0, end: 4.75)
        var snapshot = MeetingLiveTranscriptSnapshot.empty.inserting(you).inserting(them)
        snapshot.revision = 7
        snapshot = snapshot.settingAvailability(.available)

        let body = try self.encode(MeetingLiveTranscriptReading(sessionID: sessionID, snapshot: snapshot))

        XCTAssertEqual(Set(body.keys), ["sessionID", "revision", "availability", "utterances", "partials"])
        XCTAssertEqual(body["sessionID"] as? String, sessionID.uuidString)
        XCTAssertEqual(body["revision"] as? Int, 7)
        let utterances = try XCTUnwrap(body["utterances"] as? [[String: Any]])
        XCTAssertEqual(utterances.count, 2)
        XCTAssertEqual(Set(utterances[0].keys), ["id", "speaker", "text", "start", "end"])
        XCTAssertEqual(utterances[0]["id"] as? String, you.id.uuidString)
        XCTAssertEqual(utterances[0]["speaker"] as? String, "you")
        XCTAssertEqual(utterances[0]["text"] as? String, "Hello there")
        XCTAssertEqual(utterances[0]["start"] as? Double, 1.25)
        XCTAssertEqual(utterances[0]["end"] as? Double, 2.5)
        XCTAssertEqual(utterances[1]["id"] as? String, them.id.uuidString)
        XCTAssertEqual(utterances[1]["speaker"] as? String, "them")
        XCTAssertEqual(utterances[1]["text"] as? String, "Hi 👋")
        XCTAssertEqual(utterances[1]["start"] as? Double, 3.0)
        XCTAssertEqual(utterances[1]["end"] as? Double, 4.75)
    }

    func test_response_partialsSortedYouThenThem() throws {
        let themPartial = MeetingLivePartial(id: UUID(), text: "they are", start: 1.0)
        let youPartial = MeetingLivePartial(id: UUID(), text: "I am", start: 2.0)
        // Set `them` first and give it the earlier start, so neither insertion order nor start
        // time can produce the expected order by accident.
        let snapshot = MeetingLiveTranscriptSnapshot.empty
            .settingPartial(themPartial, for: .them)
            .settingPartial(youPartial, for: .you)

        let body = try self.encode(MeetingLiveTranscriptReading(sessionID: UUID(), snapshot: snapshot))

        let partials = try XCTUnwrap(body["partials"] as? [[String: Any]])
        XCTAssertEqual(partials.count, 2)
        XCTAssertEqual(Set(partials[0].keys), ["id", "speaker", "text", "start"])
        XCTAssertEqual(partials.compactMap { $0["speaker"] as? String }, ["you", "them"])
        XCTAssertEqual(partials[0]["id"] as? String, youPartial.id.uuidString)
        XCTAssertEqual(partials[0]["text"] as? String, "I am")
        XCTAssertEqual(partials[0]["start"] as? Double, 2.0)
        XCTAssertEqual(partials[1]["id"] as? String, themPartial.id.uuidString)
        XCTAssertEqual(partials[1]["text"] as? String, "they are")
        XCTAssertEqual(partials[1]["start"] as? Double, 1.0)
    }

    func test_response_availabilityStates() throws {
        let cases: [(MeetingLiveAvailability, String, String?)] = [
            (.available, "available", nil),
            (.degraded(reason: "x"), "degraded", "x"),
            (.unavailable(reason: "y"), "unavailable", "y"),
        ]
        for (availability, state, reason) in cases {
            let snapshot = MeetingLiveTranscriptSnapshot.empty.settingAvailability(availability)
            let body = try self.encode(MeetingLiveTranscriptReading(sessionID: UUID(), snapshot: snapshot))
            let encoded = try XCTUnwrap(body["availability"] as? [String: Any])
            XCTAssertEqual(Set(encoded.keys), ["state", "reason"], "\(availability)")
            XCTAssertEqual(encoded["state"] as? String, state)
            if let reason {
                XCTAssertEqual(encoded["reason"] as? String, reason)
            } else {
                XCTAssertTrue(encoded["reason"] is NSNull, "reason must be an explicit null for \(availability)")
            }
        }
    }

    func test_response_emptyReading() throws {
        let body = try self.encode(MeetingLiveTranscriptReading(sessionID: nil, snapshot: .empty))

        XCTAssertEqual(Set(body.keys), ["sessionID", "revision", "availability", "utterances", "partials"])
        XCTAssertTrue(body["sessionID"] is NSNull, "sessionID must be an explicit null")
        XCTAssertEqual(body["revision"] as? Int, 0)
        XCTAssertEqual((body["utterances"] as? [Any])?.count, 0)
        XCTAssertEqual((body["partials"] as? [Any])?.count, 0)
        XCTAssertEqual((body["availability"] as? [String: Any])?["state"] as? String, "unavailable")
    }

    func test_idleReading_isUnavailableWithoutSession() {
        let idle = MeetingLiveTranscriptReading.idle
        XCTAssertNil(idle.sessionID)
        XCTAssertEqual(idle.snapshot.revision, 0)
        XCTAssertTrue(idle.snapshot.utterances.isEmpty)
        XCTAssertTrue(idle.snapshot.partials.isEmpty)
        guard case .unavailable = idle.snapshot.availability else {
            return XCTFail("Idle reading must be unavailable, got \(idle.snapshot.availability)")
        }
    }

    private func encode(_ reading: MeetingLiveTranscriptReading) throws -> [String: Any] {
        let data = try LocalAPI.encoder.encode(MeetingLiveResponse(reading: reading))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
