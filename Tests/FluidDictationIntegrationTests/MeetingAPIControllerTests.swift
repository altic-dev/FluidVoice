@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingAPIControllerTests: XCTestCase {
    func testListReturnsNewestMeetingsWithIDsAndBoundedLimit() async throws {
        try await self.withStore { store in
            let older = self.makeSession(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
            let newer = self.makeSession(startedAt: older.startedAt.addingTimeInterval(120))
            try await store.create(newer)
            try await store.create(older)
            let router = LocalAPIRouter(meetingStore: store)

            for limit in ["1", "0", "-1"] {
                let response = await router.route(self.request(path: "/v1/meetings", query: ["limit": limit]))
                XCTAssertEqual(response.status, 200)
                let body = try self.json(response)
                XCTAssertEqual(body["count"] as? Int, 1)
                let items = try XCTUnwrap(body["items"] as? [[String: Any]])
                XCTAssertEqual(items.count, 1)
                XCTAssertEqual(items.first?["id"] as? String, newer.id.uuidString)
                XCTAssertEqual(items.first?["state"] as? String, "completed")
                XCTAssertEqual(items.first?["segmentCount"] as? Int, 1)
                XCTAssertEqual(items.first?["transcriptIsComplete"] as? Bool, true)
                XCTAssertNil(items.first?["audioTracks"])
            }

            let response = await router.route(self.request(path: "/v1/meetings"))
            let items = try XCTUnwrap(self.json(response)["items"] as? [[String: Any]])
            XCTAssertEqual(items.compactMap { $0["id"] as? String }, [newer.id.uuidString, older.id.uuidString])
        }
    }

    func testJSONTranscriptPreservesTextTimestampsSpeakersAndEchoFlags() async throws {
        try await self.withStore { store in
            var session = self.makeSession()
            session.transcriptSegments[0].text = String(repeating: "Résumé 👋\n", count: 2000)
            var earlier = session.transcriptSegments[0]
            earlier.id = UUID()
            earlier.start = MeetingMediaTime(value: 0, timescale: 1000)
            earlier.end = MeetingMediaTime(value: 500, timescale: 1000)
            earlier.text = "Echo"
            earlier.isLikelyEcho = true
            session.transcriptSegments.append(earlier)
            try await store.create(session)

            let router = LocalAPIRouter(meetingStore: store)
            let response = await router.route(self.request(query: ["id": session.id.uuidString.lowercased()]))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.headers["Content-Type"], "application/json; charset=utf-8")
            let body = try self.json(response)
            XCTAssertEqual(body["schemaVersion"] as? Int, 1)
            XCTAssertEqual(body["title"] as? String, "API meeting")
            let segments = try XCTUnwrap(body["segments"] as? [[String: Any]])
            XCTAssertEqual(segments.count, 2)
            XCTAssertEqual(segments[0]["text"] as? String, "Echo")
            XCTAssertEqual(segments[0]["isLikelyEcho"] as? Bool, true)
            XCTAssertEqual(segments[1]["text"] as? String, session.transcriptSegments[0].text)
            XCTAssertEqual(segments[1]["startSeconds"] as? Double, 1.25)
            XCTAssertEqual(segments[1]["endSeconds"] as? Double, 2.5)
            XCTAssertEqual(segments[1]["speakerID"] as? String, session.speakers[0].id.uuidString)
            let speakers = try XCTUnwrap(body["speakers"] as? [[String: Any]])
            XCTAssertEqual(speakers.first?["displayName"] as? String, "Maya")
            XCTAssertNil(body["selectedMicrophone"])
            XCTAssertNil(body["audioTracks"])
        }
    }

    func testTextTranscriptReflectsSavedCorrectionsAndOmitsEchoes() async throws {
        try await self.withStore { store in
            var session = self.makeSession()
            try await store.create(session)
            let router = LocalAPIRouter(meetingStore: store)
            _ = await router.route(self.request(query: ["id": session.id.uuidString, "format": "text"]))

            session.speakers[0].displayName = "Renée"
            session.transcriptSegments[0].text = "Corrected words 👋"
            var echo = session.transcriptSegments[0]
            echo.id = UUID()
            echo.text = "Hidden echo"
            echo.isLikelyEcho = true
            session.transcriptSegments.append(echo)
            try await store.save(session)

            let response = await router.route(self.request(query: ["id": session.id.uuidString, "format": "text"]))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.headers["Content-Type"], "text/plain; charset=utf-8")
            XCTAssertEqual(String(data: response.body, encoding: .utf8), "[00:01] Renée: Corrected words 👋")
        }
    }

    func testExistingMeetingWithoutTranscriptReturnsEmptyExport() async throws {
        try await self.withStore { store in
            var session = self.makeSession()
            session.state = .recording
            session.endedAt = nil
            session.transcriptSegments = []
            session.transcriptIsComplete = nil
            try await store.create(session)
            let router = LocalAPIRouter(meetingStore: store)

            let response = await router.route(self.request(query: ["id": session.id.uuidString]))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try (self.json(response)["segments"] as? [Any])?.count, 0)
            let text = await router.route(self.request(query: ["id": session.id.uuidString, "format": "text"]))
            XCTAssertEqual(text.status, 200)
            XCTAssertTrue(text.body.isEmpty)
        }
    }

    func testInvalidIDAndFormatReturnBadRequest() async throws {
        try await self.withStore { store in
            let router = LocalAPIRouter(meetingStore: store)
            let queries = [
                [:], ["id": ""], ["id": "../session.json"],
                ["id": UUID().uuidString, "format": "xml"],
            ]
            for query in queries {
                let response = await router.route(self.request(query: query))
                XCTAssertEqual(response.status, 400)
                XCTAssertNotNil(try self.json(response)["error"] as? String)
            }
        }
    }

    func testMissingAndDeletedMeetingsReturnNotFound() async throws {
        try await self.withStore { store in
            let session = self.makeSession()
            let router = LocalAPIRouter(meetingStore: store)
            let request = self.request(query: ["id": session.id.uuidString])
            let missing = await router.route(request)
            XCTAssertEqual(missing.status, 404)

            try await store.create(session)
            try await store.delete(id: session.id)
            let deleted = await router.route(request)
            XCTAssertEqual(deleted.status, 404)
        }
    }

    func testRoutesRejectWritesAndUnknownPaths() async throws {
        try await self.withStore { store in
            let router = LocalAPIRouter(meetingStore: store)
            for path in ["/v1/meetings", "/v1/meetings/transcript"] {
                for method in ["POST", "DELETE", "PUT"] {
                    let response = await router.route(self.request(method: method, path: path))
                    XCTAssertEqual(response.status, 405)
                }
            }
            let unknown = await router.route(self.request(path: "/v1/meetings/unknown"))
            XCTAssertEqual(unknown.status, 404)
            let health = await router.route(self.request(path: "/v1/health"))
            XCTAssertEqual(health.status, 200)
        }
    }

    func testCorruptMeetingReturnsServiceUnavailable() async throws {
        try await self.withStore { store in
            let session = self.makeSession()
            try await store.create(session)
            let directory = try await store.sessionDirectory(for: session.id)
            try Data("invalid private manifest".utf8).write(to: directory.appendingPathComponent("session.json"))
            let response = await LocalAPIRouter(meetingStore: store).route(self.request(query: ["id": session.id.uuidString]))
            XCTAssertEqual(response.status, 503)
            let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
            XCTAssertFalse(body.contains(directory.path))
        }
    }

    func testEmptyListAndUnavailableStore() async throws {
        try await self.withStore { store in
            let response = await LocalAPIRouter(meetingStore: store).route(self.request(path: "/v1/meetings"))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try self.json(response)["count"] as? Int, 0)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let store = MeetingSessionStore(rootDirectory: root)
        let response = await LocalAPIRouter(meetingStore: store).route(self.request(path: "/v1/meetings"))
        XCTAssertEqual(response.status, 503)
    }

    private func withStore(_ body: (MeetingSessionStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(MeetingSessionStore(rootDirectory: root))
    }

    private func request(
        method: String = "GET",
        path: String = "/v1/meetings/transcript",
        query: [String: String] = [:]
    ) -> LocalAPI.Request {
        LocalAPI.Request(method: method, path: path, query: query, headers: [:], body: Data())
    }

    private func json(_ response: LocalAPI.Response) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func makeSession(startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(
            mode: .inRoom,
            title: "API meeting",
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")
        )
        var session = MeetingSession(
            configuration: configuration,
            startedAt: startedAt,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            )
        )
        session.state = .completed
        session.endedAt = startedAt.addingTimeInterval(60)
        session.transcriptIsComplete = true
        let trackID = UUID()
        let speakerID = UUID()
        session.audioTracks = [MeetingAudioTrack(
            id: trackID,
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: session.timebase,
            health: .waiting,
            chunks: []
        )]
        session.speakers = [MeetingSessionSpeaker(
            id: speakerID,
            displayName: "Maya",
            diarizationClusterID: nil,
            trackKind: .microphone,
            isLocalUser: false,
            identityCandidates: []
        )]
        session.transcriptSegments = [MeetingTranscriptSegment(
            id: UUID(),
            start: MeetingMediaTime(value: 1250, timescale: 1000),
            end: MeetingMediaTime(value: 2500, timescale: 1000),
            sourceTrackID: trackID,
            speakerID: speakerID,
            text: "Hello",
            revision: 1,
            status: .final,
            overlap: .none,
            completeness: .complete
        )]
        return session
    }
}
