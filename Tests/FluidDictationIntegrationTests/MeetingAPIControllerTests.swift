@testable import FluidVoice_Debug
import Foundation
import HTTPTypes
import Hummingbird
import Logging
import NIOEmbedded
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
                let response = try await router.route(self.request(path: "/v1/meetings", query: ["limit": limit]))
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

            let response = try await router.route(self.request(path: "/v1/meetings"))
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
            let response = try await router.route(self.request(query: ["id": session.id.uuidString.lowercased()]))
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
            _ = try await router.route(self.request(query: ["id": session.id.uuidString, "format": "text"]))

            session.speakers[0].displayName = "Renée"
            session.transcriptSegments[0].text = "Corrected words 👋"
            var echo = session.transcriptSegments[0]
            echo.id = UUID()
            echo.text = "Hidden echo"
            echo.isLikelyEcho = true
            session.transcriptSegments.append(echo)
            try await store.save(session)

            let response = try await router.route(self.request(query: ["id": session.id.uuidString, "format": "text"]))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.headers["Content-Type"], "text/plain; charset=utf-8")
            XCTAssertEqual(String(data: response.body, encoding: .utf8), "[00:01] Renée: Corrected words 👋")
        }
    }

    func testMarkdownTranscriptMatchesExporterOmitsEchoesAndEscapesContent() async throws {
        try await self.withStore { store in
            var session = self.makeSession()
            session.speakers[0].displayName = "Renée [lead]"
            session.transcriptSegments[0].text = "Corrected **words** 👋"
            var echo = session.transcriptSegments[0]
            echo.id = UUID()
            echo.text = "Hidden echo"
            echo.isLikelyEcho = true
            session.transcriptSegments.append(echo)
            try await store.create(session)
            let router = LocalAPIRouter(meetingStore: store)

            let response = try await router.route(self.request(query: ["id": session.id.uuidString, "format": "markdown"]))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.headers["Content-Type"], "text/markdown; charset=utf-8")
            let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
            XCTAssertEqual(body, MeetingTranscriptExporter.markdown(for: session))
            XCTAssertFalse(body.contains("Hidden echo"))
            XCTAssertTrue(body.contains(#"Renée \[lead\]"#))
            XCTAssertTrue(body.contains(#"Corrected \*\*words\*\* 👋"#))
        }
    }

    func testMarkdownTranscriptForEmptySessionReturnsHeadings() async throws {
        try await self.withStore { store in
            var session = self.makeSession()
            session.state = .recording
            session.endedAt = nil
            session.transcriptSegments = []
            session.transcriptIsComplete = nil
            try await store.create(session)
            let router = LocalAPIRouter(meetingStore: store)

            let response = try await router.route(self.request(query: ["id": session.id.uuidString, "format": "markdown"]))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.headers["Content-Type"], "text/markdown; charset=utf-8")
            let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
            XCTAssertEqual(body, MeetingTranscriptExporter.markdown(for: session))
            XCTAssertEqual(body, "# API meeting\n\n## Transcript\n")
            XCTAssertFalse(body.isEmpty)
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

            let response = try await router.route(self.request(query: ["id": session.id.uuidString]))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try (self.json(response)["segments"] as? [Any])?.count, 0)
            let text = try await router.route(self.request(query: ["id": session.id.uuidString, "format": "text"]))
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
                let response = try await router.route(self.request(query: query))
                XCTAssertEqual(response.status, 400)
                XCTAssertNotNil(try self.json(response)["error"] as? String)
            }

            for format in ["xml", "html", "md", "Markdown"] {
                let response = try await router.route(self.request(query: ["id": UUID().uuidString, "format": format]))
                XCTAssertEqual(response.status, 400, format)
                let message = try XCTUnwrap(self.json(response)["error"] as? String)
                XCTAssertTrue(message.contains("markdown"), message)
                XCTAssertTrue(message.contains("json"), message)
                XCTAssertTrue(message.contains("text"), message)
            }
        }
    }

    func testMissingAndDeletedMeetingsReturnNotFound() async throws {
        try await self.withStore { store in
            let session = self.makeSession()
            let router = LocalAPIRouter(meetingStore: store)
            let request = self.request(query: ["id": session.id.uuidString])
            let missing = try await router.route(request)
            XCTAssertEqual(missing.status, 404)

            try await store.create(session)
            try await store.delete(id: session.id)
            let deleted = try await router.route(request)
            XCTAssertEqual(deleted.status, 404)
        }
    }

    func testRoutesRejectWritesAndUnknownPaths() async throws {
        try await self.withStore { store in
            let router = LocalAPIRouter(meetingStore: store)
            for path in ["/v1/meetings", "/v1/meetings/transcript"] {
                for method in ["POST", "DELETE", "PUT"] {
                    let response = try await router.route(self.request(method: method, path: path))
                    XCTAssertEqual(response.status, 405)
                }
            }
            let unknown = try await router.route(self.request(path: "/v1/meetings/unknown"))
            XCTAssertEqual(unknown.status, 404)
            let health = try await router.route(self.request(path: "/v1/health"))
            XCTAssertEqual(health.status, 200)
        }
    }

    func testCorruptMeetingReturnsServiceUnavailable() async throws {
        try await self.withStore { store in
            let session = self.makeSession()
            try await store.create(session)
            let directory = try await store.sessionDirectory(for: session.id)
            try Data("invalid private manifest".utf8).write(to: directory.appendingPathComponent("session.json"))
            let response = try await LocalAPIRouter(meetingStore: store).route(self.request(query: ["id": session.id.uuidString]))
            XCTAssertEqual(response.status, 503)
            let body = try XCTUnwrap(String(data: response.body, encoding: .utf8))
            XCTAssertFalse(body.contains(directory.path))
        }
    }

    func testEmptyListAndUnavailableStore() async throws {
        try await self.withStore { store in
            let response = try await LocalAPIRouter(meetingStore: store).route(self.request(path: "/v1/meetings"))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(try self.json(response)["count"] as? Int, 0)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let store = MeetingSessionStore(rootDirectory: root)
        let response = try await LocalAPIRouter(meetingStore: store).route(self.request(path: "/v1/meetings"))
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

@MainActor
final class MeetingLiveAPIControllerTests: XCTestCase {
    private let sessionID = UUID()

    func test_live_returnsSnapshot() async throws {
        let utterance = MeetingLiveUtterance(id: UUID(), speaker: .them, text: "Agenda first", start: 0.5, end: 1.75)
        let partial = MeetingLivePartial(id: UUID(), text: "Sounds", start: 2.0)
        var snapshot = MeetingLiveTranscriptSnapshot.empty
            .inserting(utterance)
            .settingPartial(partial, for: .you)
            .settingAvailability(.degraded(reason: "Application audio is silent."))
        snapshot.revision = 12
        let router = self.router(MeetingLiveTranscriptReading(sessionID: self.sessionID, snapshot: snapshot))

        let response = try await router.route(self.request())

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/json; charset=utf-8")
        let body = try self.json(response)
        XCTAssertEqual(body["sessionID"] as? String, self.sessionID.uuidString)
        XCTAssertEqual(body["revision"] as? Int, 12)
        let availability = try XCTUnwrap(body["availability"] as? [String: Any])
        XCTAssertEqual(availability["state"] as? String, "degraded")
        XCTAssertEqual(availability["reason"] as? String, "Application audio is silent.")
        let utterances = try XCTUnwrap(body["utterances"] as? [[String: Any]])
        XCTAssertEqual(utterances.count, 1)
        XCTAssertEqual(utterances[0]["id"] as? String, utterance.id.uuidString)
        XCTAssertEqual(utterances[0]["speaker"] as? String, "them")
        XCTAssertEqual(utterances[0]["text"] as? String, "Agenda first")
        XCTAssertEqual(utterances[0]["start"] as? Double, 0.5)
        XCTAssertEqual(utterances[0]["end"] as? Double, 1.75)
        let partials = try XCTUnwrap(body["partials"] as? [[String: Any]])
        XCTAssertEqual(partials.count, 1)
        XCTAssertEqual(partials[0]["id"] as? String, partial.id.uuidString)
        XCTAssertEqual(partials[0]["speaker"] as? String, "you")
        XCTAssertEqual(partials[0]["text"] as? String, "Sounds")
    }

    func test_live_sinceAndSessionMatch_returns304() async throws {
        let router = self.router(self.reading(revision: 5))

        let response = try await router.route(self.request(query: ["since": "5", "session": self.sessionID.uuidString.lowercased()]))

        XCTAssertEqual(response.status, 304)
        XCTAssertTrue(response.body.isEmpty)
    }

    func test_live_sinceMatchesButSessionMissing_returns200() async throws {
        let router = self.router(self.reading(revision: 5))

        let response = try await router.route(self.request(query: ["since": "5"]))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try self.json(response)["revision"] as? Int, 5)
    }

    func test_live_sessionMatchesButSinceMissing_returns200() async throws {
        let router = self.router(self.reading(revision: 5))

        let response = try await router.route(self.request(query: ["session": self.sessionID.uuidString]))

        XCTAssertEqual(response.status, 200)
    }

    func test_live_sinceBehindCurrentRevision_returns200() async throws {
        let router = self.router(self.reading(revision: 6))

        let response = try await router.route(self.request(query: ["since": "5", "session": self.sessionID.uuidString]))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try self.json(response)["revision"] as? Int, 6)
    }

    func test_live_newSessionSameRevision_returns200() async throws {
        // Revisions restart with each meeting, so an old poller's `since` can equal the new
        // meeting's revision. Only the session ID tells them apart.
        let oldSessionID = UUID()
        let router = self.router(self.reading(revision: 3))

        let response = try await router.route(self.request(query: ["since": "3", "session": oldSessionID.uuidString]))

        XCTAssertEqual(response.status, 200)
        let body = try self.json(response)
        XCTAssertEqual(body["sessionID"] as? String, self.sessionID.uuidString)
        XCTAssertEqual(body["revision"] as? Int, 3)
    }

    func test_live_noActiveMeeting_returns200WithNullSession() async throws {
        let router = self.router(.idle)

        for query in [[:], ["since": "0"], ["since": "0", "session": self.sessionID.uuidString]] {
            let response = try await router.route(self.request(query: query))
            XCTAssertEqual(response.status, 200, "\(query)")
            let body = try self.json(response)
            XCTAssertTrue(body["sessionID"] is NSNull)
            XCTAssertEqual(body["revision"] as? Int, 0)
            XCTAssertEqual((body["availability"] as? [String: Any])?["state"] as? String, "unavailable")
            XCTAssertEqual((body["utterances"] as? [Any])?.count, 0)
            XCTAssertEqual((body["partials"] as? [Any])?.count, 0)
        }
    }

    func test_live_badSince_returns400() async throws {
        let router = self.router(self.reading(revision: 1))

        for since in ["abc", "-1", "", "1.5", "18446744073709551616"] {
            let response = try await router.route(self.request(query: ["since": since, "session": self.sessionID.uuidString]))
            XCTAssertEqual(response.status, 400, "since=\(since)")
            let message = try XCTUnwrap(self.json(response)["error"] as? String)
            XCTAssertTrue(message.contains("since"), message)
        }
    }

    func test_live_badSession_returns400() async throws {
        let router = self.router(self.reading(revision: 1))

        for session in ["not-a-uuid", "", "../session.json"] {
            let response = try await router.route(self.request(query: ["since": "1", "session": session]))
            XCTAssertEqual(response.status, 400, "session=\(session)")
            let message = try XCTUnwrap(self.json(response)["error"] as? String)
            XCTAssertTrue(message.contains("session"), message)
        }
    }

    func test_live_post_returns405() async throws {
        let router = self.router(self.reading(revision: 1))

        for method in ["POST", "DELETE", "PUT"] {
            let response = try await router.route(self.request(method: method))
            XCTAssertEqual(response.status, 405, method)
        }
    }

    func test_live_responsesAreNotCached() async throws {
        let router = self.router(self.reading(revision: 5))

        let full = try await router.route(self.request())
        XCTAssertEqual(full.status, 200)
        XCTAssertEqual(full.headers["Cache-Control"], "no-store")
        let notModified = try await router.route(self.request(query: ["since": "5", "session": self.sessionID.uuidString]))
        XCTAssertEqual(notModified.status, 304)
        XCTAssertEqual(notModified.headers["Cache-Control"], "no-store")
        XCTAssertNil(notModified.headers["Content-Length"])
        XCTAssertTrue(notModified.body.isEmpty)
        let badQuery = try await router.route(self.request(query: ["since": "-1"]))
        XCTAssertEqual(badQuery.status, 400)
        XCTAssertEqual(badQuery.headers["Cache-Control"], "no-store")
        let wrongMethod = try await router.route(self.request(method: "POST"))
        XCTAssertEqual(wrongMethod.status, 405)
        XCTAssertEqual(wrongMethod.headers["Cache-Control"], "no-store")
    }

    func test_untrustedRequestRejection_allowsLoopbackHostsWithoutOrigin() {
        for host in ["127.0.0.1:47733", "localhost:47733", "LOCALHOST:47733", "[::1]:47733"] {
            let request = self.request(headers: ["host": host])
            XCTAssertNil(LocalAPI.untrustedRequestRejection(host: request.headers["host"], hasOrigin: request.headers["origin"] != nil, port: 47733), host)
        }
    }

    func test_untrustedRequestRejection_onPort80AllowsHostsWithoutPort() throws {
        for host in ["127.0.0.1", "localhost", "[::1]", "127.0.0.1:80"] {
            let request = self.request(headers: ["host": host])
            XCTAssertNil(LocalAPI.untrustedRequestRejection(host: request.headers["host"], hasOrigin: false, port: 80), host)
        }
        let foreign = try XCTUnwrap(LocalAPI.untrustedRequestRejection(host: "evil.example", hasOrigin: false, port: 80))
        XCTAssertEqual(foreign.status, 403)
    }

    func test_untrustedRequestRejection_rejectsRebindingHostsAndBrowsers() throws {
        let cases: [[String: String]] = [
            [:],
            ["host": "evil.example:47733"],
            ["host": "127.0.0.1.evil.example:47733"],
            ["host": "127.0.0.1"],
            ["host": "127.0.0.1:8080"],
            ["host": "127.0.0.1:47733", "origin": "http://127.0.0.1:47733"],
            ["host": "localhost:47733", "origin": "null"],
        ]
        for headers in cases {
            let request = self.request(headers: headers)
            let response = try XCTUnwrap(LocalAPI.untrustedRequestRejection(host: request.headers["host"], hasOrigin: request.headers["origin"] != nil, port: 47733), "\(headers)")
            XCTAssertEqual(response.status, 403, "\(headers)")
        }
    }

    private func router(_ reading: MeetingLiveTranscriptReading) -> LocalAPIRouter {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return LocalAPIRouter(
            meetingStore: MeetingSessionStore(rootDirectory: root),
            liveTranscript: FixedLiveTranscriptProvider(reading: reading)
        )
    }

    private func reading(revision: UInt64) -> MeetingLiveTranscriptReading {
        var snapshot = MeetingLiveTranscriptSnapshot.empty.settingAvailability(.available)
        snapshot.revision = revision
        return MeetingLiveTranscriptReading(sessionID: self.sessionID, snapshot: snapshot)
    }

    private func request(
        method: String = "GET",
        query: [String: String] = [:],
        headers: [String: String] = [:]
    ) -> LocalAPI.Request {
        LocalAPI.Request(method: method, path: "/v1/meetings/live", query: query, headers: headers, body: Data())
    }

    private func json(_ response: LocalAPI.Response) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }
}

private struct FixedLiveTranscriptProvider: MeetingLiveTranscriptProviding {
    let reading: MeetingLiveTranscriptReading

    func currentLiveTranscript() async -> MeetingLiveTranscriptReading {
        self.reading
    }
}

private extension LocalAPIRouter {
    func route(_ request: LocalAPI.Request) async throws -> LocalAPI.Response {
        var target = URLComponents()
        target.path = request.path
        if !request.query.isEmpty {
            target.queryItems = request.query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let head = HTTPRequest(
            method: try XCTUnwrap(HTTPRequest.Method(request.method)),
            scheme: "http",
            authority: "127.0.0.1:\(LocalAPI.defaultPort)",
            path: target.string
        )
        let input = Request(head: head, body: .init(buffer: ByteBuffer(bytes: request.body)))
        let channel = NIOAsyncTestingChannel()
        let context = BasicRequestContext(source: .init(channel: channel, logger: Logger(label: "LocalAPIRouterTests")))
        let response = try await self.respond(to: input, context: context)
        var body = Data()
        try await response.body.write(TestResponseWriter { body.append(contentsOf: $0.readableBytesView) })
        return LocalAPI.Response(
            status: response.status.code,
            headers: Dictionary(uniqueKeysWithValues: response.headers.map { ($0.name.rawName, $0.value) }),
            body: body
        )
    }
}

private struct TestResponseWriter: ResponseBodyWriter {
    let append: (ByteBuffer) -> Void

    func write(_ buffer: ByteBuffer) async throws {
        self.append(buffer)
    }

    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}

@MainActor
final class LocalAPIServerTests: XCTestCase {
    func testServesBothLoopbackAddressesAndReleasesPortOnStop() async throws {
        let port = try Self.availablePort()
        let server = LocalAPIServer()
        server.start(configuration: .init(enabled: true, port: port))
        defer { server.stop() }

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for host in ["127.0.0.1", "[::1]"] {
            let url = try XCTUnwrap(URL(string: "http://\(host):\(port)/v1/health"))
            var request = URLRequest(url: url, timeoutInterval: 2)
            let (body, response) = try await self.waitUntilReady(session: session, request: request)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Connection"), "close")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["status"], "ok")
            XCTAssertFalse(try XCTUnwrap(json["version"]).isEmpty)

            request.setValue("https://example.com", forHTTPHeaderField: "Origin")
            let (_, rejected) = try await session.data(for: request)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 403)
        }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/postprocess"))
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"text":42}"#.utf8)
        let (body, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
        let error = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(error["error"], "Invalid JSON text payload.")

        let rejected = try await self.sendRawRequest(
            "GET /v1/health HTTP/1.1\r\nHost: example.com:\(port)\r\n\r\n",
            port: port
        )
        XCTAssertTrue(rejected.hasPrefix("HTTP/1.1 403 "), rejected)
        XCTAssertTrue(rejected.contains("Host not allowed."), rejected)

        // An oversized Content-Length must get a response without sending the body.
        let oversized = try await self.sendRawRequest(
            "POST /v1/transcribe HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: \(LocalAPI.maxRequestBytes + 1)\r\n\r\n",
            port: port
        )
        XCTAssertTrue(oversized.hasPrefix("HTTP/1.1 413 "), oversized)
        XCTAssertTrue(oversized.contains("Request too large."), oversized)

        server.stop()
        for _ in 0..<40 {
            do {
                _ = try await session.data(for: request)
            } catch let error as URLError where error.code == .cannotConnectToHost {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Local API still accepts connections after stop()")
    }

    func testRecoversWhenAnOccupiedPortIsReleased() async throws {
        let blocker = try Self.bindLoopbackSocket()
        defer { blocker.release() }
        XCTAssertEqual(listen(blocker.descriptor, 1), 0)

        let server = LocalAPIServer()
        defer { server.stop() }
        server.start(configuration: .init(enabled: true, port: blocker.port))
        try await Task.sleep(for: .milliseconds(650))
        blocker.release()

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for host in ["127.0.0.1", "[::1]"] {
            let url = try XCTUnwrap(URL(string: "http://\(host):\(blocker.port)/v1/health"))
            let (body, response) = try await self.waitUntilReady(session: session, request: URLRequest(url: url, timeoutInterval: 2))
            XCTAssertEqual(response.statusCode, 200)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["status"], "ok")
        }
    }

    func testStopCancelsPendingBindRetry() async throws {
        let blocker = try Self.bindLoopbackSocket()
        defer { blocker.release() }
        XCTAssertEqual(listen(blocker.descriptor, 1), 0)

        let server = LocalAPIServer()
        server.start(configuration: .init(enabled: true, port: blocker.port))
        try await Task.sleep(for: .milliseconds(650))
        server.stop()
        try await Task.sleep(for: .milliseconds(250))
        blocker.release()

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(blocker.port)/v1/health"))
        do {
            _ = try await self.waitUntilReady(session: session, request: URLRequest(url: url, timeoutInterval: 2))
            XCTFail("The server restarted after stop()")
        } catch let error as URLError where error.code == .cannotConnectToHost {
            // The port stayed closed through the next scheduled attempts.
        }
    }

    private func sendRawRequest(_ request: String, port: UInt16) async throws -> String {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-w", "2", "127.0.0.1", String(port)]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { try? input.fileHandleForWriting.close() }
        try input.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func waitUntilReady(session: URLSession, request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        for _ in 0..<40 {
            do {
                let (body, response) = try await session.data(for: request)
                return (body, try XCTUnwrap(response as? HTTPURLResponse))
            } catch let error as URLError where error.code == .cannotConnectToHost {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw URLError(.cannotConnectToHost)
    }

    private static func availablePort() throws -> UInt16 {
        let socket = try Self.bindLoopbackSocket()
        socket.release()
        return socket.port
    }

    private static func bindLoopbackSocket() throws -> BoundSocket {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(descriptor, $0, length) == 0 else { return Int32(-1) }
                return getsockname(descriptor, $0, &length)
            }
        }
        guard status == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        return BoundSocket(descriptor: descriptor, port: UInt16(bigEndian: address.sin_port))
    }

    private final class BoundSocket {
        let descriptor: Int32
        let port: UInt16
        private var isOpen = true

        init(descriptor: Int32, port: UInt16) {
            self.descriptor = descriptor
            self.port = port
        }

        deinit { self.release() }

        func release() {
            guard self.isOpen else { return }
            self.isOpen = false
            close(self.descriptor)
        }
    }
}
