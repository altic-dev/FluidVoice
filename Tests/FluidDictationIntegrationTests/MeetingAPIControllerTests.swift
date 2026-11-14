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

            let response = await router.route(self.request(query: ["id": session.id.uuidString, "format": "markdown"]))
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

            let response = await router.route(self.request(query: ["id": session.id.uuidString, "format": "markdown"]))
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

            for format in ["xml", "html", "md", "Markdown"] {
                let response = await router.route(self.request(query: ["id": UUID().uuidString, "format": format]))
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

        let response = await router.route(self.request())

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

        let response = await router.route(self.request(query: ["since": "5", "session": self.sessionID.uuidString.lowercased()]))

        XCTAssertEqual(response.status, 304)
        XCTAssertTrue(response.body.isEmpty)
    }

    func test_live_sinceMatchesButSessionMissing_returns200() async throws {
        let router = self.router(self.reading(revision: 5))

        let response = await router.route(self.request(query: ["since": "5"]))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try self.json(response)["revision"] as? Int, 5)
    }

    func test_live_sessionMatchesButSinceMissing_returns200() async throws {
        let router = self.router(self.reading(revision: 5))

        let response = await router.route(self.request(query: ["session": self.sessionID.uuidString]))

        XCTAssertEqual(response.status, 200)
    }

    func test_live_sinceBehindCurrentRevision_returns200() async throws {
        let router = self.router(self.reading(revision: 6))

        let response = await router.route(self.request(query: ["since": "5", "session": self.sessionID.uuidString]))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try self.json(response)["revision"] as? Int, 6)
    }

    func test_live_newSessionSameRevision_returns200() async throws {
        // Revisions restart with each meeting, so an old poller's `since` can equal the new
        // meeting's revision. Only the session ID tells them apart.
        let oldSessionID = UUID()
        let router = self.router(self.reading(revision: 3))

        let response = await router.route(self.request(query: ["since": "3", "session": oldSessionID.uuidString]))

        XCTAssertEqual(response.status, 200)
        let body = try self.json(response)
        XCTAssertEqual(body["sessionID"] as? String, self.sessionID.uuidString)
        XCTAssertEqual(body["revision"] as? Int, 3)
    }

    func test_live_noActiveMeeting_returns200WithNullSession() async throws {
        let router = self.router(.idle)

        for query in [[:], ["since": "0"], ["since": "0", "session": self.sessionID.uuidString]] {
            let response = await router.route(self.request(query: query))
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
            let response = await router.route(self.request(query: ["since": since, "session": self.sessionID.uuidString]))
            XCTAssertEqual(response.status, 400, "since=\(since)")
            let message = try XCTUnwrap(self.json(response)["error"] as? String)
            XCTAssertTrue(message.contains("since"), message)
        }
    }

    func test_live_badSession_returns400() async throws {
        let router = self.router(self.reading(revision: 1))

        for session in ["not-a-uuid", "", "../session.json"] {
            let response = await router.route(self.request(query: ["since": "1", "session": session]))
            XCTAssertEqual(response.status, 400, "session=\(session)")
            let message = try XCTUnwrap(self.json(response)["error"] as? String)
            XCTAssertTrue(message.contains("session"), message)
        }
    }

    func test_live_post_returns405() async throws {
        let router = self.router(self.reading(revision: 1))

        for method in ["POST", "DELETE", "PUT"] {
            let response = await router.route(self.request(method: method))
            XCTAssertEqual(response.status, 405, method)
        }
    }

    func test_live_responsesAreNotCached() async throws {
        let router = self.router(self.reading(revision: 5))

        let full = await router.route(self.request())
        XCTAssertEqual(full.status, 200)
        XCTAssertEqual(full.headers["Cache-Control"], "no-store")
        let notModified = await router.route(self.request(query: ["since": "5", "session": self.sessionID.uuidString]))
        XCTAssertEqual(notModified.status, 304)
        XCTAssertEqual(notModified.headers["Cache-Control"], "no-store")
        let badQuery = await router.route(self.request(query: ["since": "-1"]))
        XCTAssertEqual(badQuery.status, 400)
        XCTAssertEqual(badQuery.headers["Cache-Control"], "no-store")
        let wrongMethod = await router.route(self.request(method: "POST"))
        XCTAssertEqual(wrongMethod.status, 405)
        XCTAssertEqual(wrongMethod.headers["Cache-Control"], "no-store")
    }

    func test_wireHeaders_omitContentLengthWithoutBody() {
        for status in [204, 304] {
            let headers = LocalAPI.wireHeaders(for: LocalAPI.Response(status: status))
            XCTAssertNil(headers["Content-Length"], "\(status)")
            XCTAssertEqual(headers["Connection"], "close")
        }
        let ok = LocalAPI.wireHeaders(for: LocalAPI.Response(status: 200, headers: ["X": "1"], body: Data("{}".utf8)))
        XCTAssertEqual(ok["Content-Length"], "2")
        XCTAssertEqual(ok["Connection"], "close")
        XCTAssertEqual(ok["X"], "1")
    }

    func test_untrustedRequestRejection_allowsLoopbackHostsWithoutOrigin() {
        for host in ["127.0.0.1:47733", "localhost:47733", "LOCALHOST:47733", "[::1]:47733"] {
            let request = self.request(headers: ["host": host])
            XCTAssertNil(LocalAPI.untrustedRequestRejection(for: request, port: 47733), host)
        }
    }

    func test_untrustedRequestRejection_onPort80AllowsHostsWithoutPort() throws {
        for host in ["127.0.0.1", "localhost", "[::1]", "127.0.0.1:80"] {
            let request = self.request(headers: ["host": host])
            XCTAssertNil(LocalAPI.untrustedRequestRejection(for: request, port: 80), host)
        }
        let foreign = try XCTUnwrap(LocalAPI.untrustedRequestRejection(for: self.request(headers: ["host": "evil.example"]), port: 80))
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
            let response = try XCTUnwrap(LocalAPI.untrustedRequestRejection(for: request, port: 47733), "\(headers)")
            XCTAssertEqual(response.status, 403, "\(headers)")
        }
    }

    func test_notModified_hasReasonPhrase() {
        XCTAssertEqual(LocalAPI.reasonPhrase(for: 304), "Not Modified")
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
