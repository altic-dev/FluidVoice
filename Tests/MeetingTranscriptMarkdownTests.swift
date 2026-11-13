import Foundation

// MARK: - Linux-only stand-ins
//
// MeetingSessionStore imports Darwin and CryptoKit. History, dictionary, and
// inference controllers pull AppKit / AVFoundation / app singletons.
// LocalAPIRouter's default live provider reaches AppServices. These types exist
// so the real Foundation-safe sources compile; tests pass a fake store and a
// fake live-transcript provider explicitly.

nonisolated protocol MeetingSessionStoring: Sendable {
    func create(_ session: MeetingSession) async throws
    func save(_ session: MeetingSession) async throws
    func load(id: MeetingSessionID) async throws -> MeetingSession?
    func loadAll() async throws -> [MeetingSession]
    func loadHistory() async throws -> [MeetingSession]
    func loadTranscript(id: MeetingSessionID) async throws -> MeetingSession?
    func loadRecoverable() async throws -> [MeetingSession]
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL?
    func delete(id: MeetingSessionID) async throws
    func deleteAudioFiles(for id: MeetingSessionID) async throws
}

final class MeetingSessionStore: MeetingSessionStoring {
    static let shared = MeetingSessionStore()

    func create(_ session: MeetingSession) async throws {}
    func save(_ session: MeetingSession) async throws {}
    func load(id: MeetingSessionID) async throws -> MeetingSession? { nil }
    func loadAll() async throws -> [MeetingSession] { [] }
    func loadHistory() async throws -> [MeetingSession] { [] }
    func loadTranscript(id: MeetingSessionID) async throws -> MeetingSession? { nil }
    func loadRecoverable() async throws -> [MeetingSession] { [] }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL {
        URL(fileURLWithPath: "/tmp")
    }
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? { nil }
    func delete(id: MeetingSessionID) async throws {}
    func deleteAudioFiles(for id: MeetingSessionID) async throws {}
}

struct MeetingCoordinatorLiveTranscriptProvider: MeetingLiveTranscriptProviding {
    func currentLiveTranscript() async -> MeetingLiveTranscriptReading { .idle }
}

struct HistoryAPIController: LocalAPIRouteHandler {
    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        LocalAPI.error("History is not available in this test.", status: 501)
    }
}

struct DictionaryAPIController: LocalAPIRouteHandler {
    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        LocalAPI.error("Dictionary is not available in this test.", status: 501)
    }
}

final class InferenceAPIController: LocalAPIRouteHandler {
    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        LocalAPI.error("Inference is not available in this test.", status: 501)
    }
}

nonisolated struct MeetingMicrophoneSettledConfig: Codable, Equatable, Sendable {}

final nonisolated class MeetingAudioComparisonProbe: @unchecked Sendable {}

nonisolated struct MeetingPostProcessingArtifact: Codable, Equatable, Sendable {
    let attemptID: UUID
    let transcriptHash: String
    let providerID: String
    let modelID: String
    let error: String?
}

nonisolated struct MeetingResultSidecarReference: Codable, Equatable {
    let formatVersion: Int
    let fileName: String
    let sha256: String
    let byteCount: Int
}

nonisolated enum VoiceEngineLanguageCatalog {
    static let parakeetV3LanguageIDs: Set<String> = ["en"]
}

nonisolated enum MeetingLiveSpeaker: Sendable, Equatable, Hashable {
    case you
    case them
}

nonisolated enum MeetingLiveAvailability: Sendable, Equatable {
    case unavailable(reason: String)
    case degraded(reason: String)
    case available
}

nonisolated struct MeetingLiveUtterance: Identifiable, Sendable, Equatable {
    var id: UUID
    var speaker: MeetingLiveSpeaker
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

nonisolated struct MeetingLivePartial: Sendable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var start: TimeInterval
}

nonisolated struct MeetingLiveTranscriptSnapshot: Sendable, Equatable {
    var revision: UInt64 = 0
    var utterances: [MeetingLiveUtterance] = []
    var partials: [MeetingLiveSpeaker: MeetingLivePartial] = [:]
    var availability: MeetingLiveAvailability = .unavailable(reason: "Live captions have not started.")

    static let empty = MeetingLiveTranscriptSnapshot()

    func settingAvailability(_ availability: MeetingLiveAvailability) -> MeetingLiveTranscriptSnapshot {
        var copy = self
        copy.availability = availability
        return copy
    }
}

actor InMemoryMeetingSessionStore: MeetingSessionStoring {
    private var sessions: [MeetingSessionID: MeetingSession] = [:]

    func create(_ session: MeetingSession) async throws {
        self.sessions[session.id] = session
    }

    func save(_ session: MeetingSession) async throws {
        self.sessions[session.id] = session
    }

    func load(id: MeetingSessionID) async throws -> MeetingSession? {
        self.sessions[id]
    }

    func loadAll() async throws -> [MeetingSession] {
        Array(self.sessions.values)
    }

    func loadHistory() async throws -> [MeetingSession] { try await self.loadAll() }
    func loadTranscript(id: MeetingSessionID) async throws -> MeetingSession? { try await self.load(id: id) }
    func loadRecoverable() async throws -> [MeetingSession] { [] }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL {
        URL(fileURLWithPath: "/tmp")
    }
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? { nil }
    func delete(id: MeetingSessionID) async throws { self.sessions.removeValue(forKey: id) }
    func deleteAudioFiles(for id: MeetingSessionID) async throws {}
}

struct IdleLiveTranscriptProvider: MeetingLiveTranscriptProviding {
    func currentLiveTranscript() async -> MeetingLiveTranscriptReading { .idle }
}

// MARK: - Tests

@main @MainActor
enum MeetingTranscriptMarkdownTests {
    static func main() async {
        var checks = 0
        var failures: [String] = []

        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition {
                failures.append(message)
                print("FAIL: \(message)")
            }
        }

        func jsonObject(_ response: LocalAPI.Response) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        }

        func errorMessage(_ response: LocalAPI.Response) -> String {
            jsonObject(response)["error"] as? String ?? String(data: response.body, encoding: .utf8) ?? ""
        }

        func request(
            method: String = "GET",
            path: String = "/v1/meetings/transcript",
            query: [String: String] = [:]
        ) -> LocalAPI.Request {
            LocalAPI.Request(method: method, path: path, query: query, headers: [:], body: Data())
        }

        func makeSession(
            title: String = "API meeting",
            speakerName: String = "Maya",
            text: String = "Hello",
            segments: Bool = true
        ) -> MeetingSession {
            let configuration = MeetingCaptureConfiguration(
                mode: .inRoom,
                title: title,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")
            )
            var session = MeetingSession(
                configuration: configuration,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                timebase: MeetingTimebaseMetadata(
                    startedHostTime: 0,
                    machTimebaseNumerator: 1,
                    machTimebaseDenominator: 1,
                    firstPresentationTime: nil
                )
            )
            session.state = .completed
            session.endedAt = session.startedAt.addingTimeInterval(60)
            session.transcriptIsComplete = true
            let trackID = UUID()
            let speakerID = UUID()
            session.speakers = [MeetingSessionSpeaker(
                id: speakerID,
                displayName: speakerName,
                diarizationClusterID: nil,
                trackKind: .microphone,
                isLocalUser: false,
                identityCandidates: []
            )]
            if segments {
                session.transcriptSegments = [MeetingTranscriptSegment(
                    id: UUID(),
                    start: MeetingMediaTime(value: 1250, timescale: 1000),
                    end: MeetingMediaTime(value: 2500, timescale: 1000),
                    sourceTrackID: trackID,
                    speakerID: speakerID,
                    text: text,
                    revision: 1,
                    status: .final,
                    overlap: .none,
                    completeness: .complete
                )]
            }
            return session
        }

        let store = InMemoryMeetingSessionStore()
        let router = LocalAPIRouter(meetingStore: store, liveTranscript: IdleLiveTranscriptProvider())

        // 1. format=markdown matches the exporter, omits echoes, and escapes speaker/text.
        var session = makeSession(speakerName: "Renée [lead]", text: "Hello")
        session.transcriptSegments[0].text = "Corrected **words** 👋"
        var echo = session.transcriptSegments[0]
        echo.id = UUID()
        echo.start = MeetingMediaTime(value: 500, timescale: 1000)
        echo.end = MeetingMediaTime(value: 900, timescale: 1000)
        echo.text = "Hidden echo"
        echo.isLikelyEcho = true
        session.transcriptSegments.append(echo)
        try? await store.create(session)

        let markdownResponse = await router.route(
            request(query: ["id": session.id.uuidString, "format": "markdown"])
        )
        let markdownBody = String(data: markdownResponse.body, encoding: .utf8) ?? ""
        let expectedMarkdown = MeetingTranscriptExporter.markdown(for: session)

        print("MARKDOWN STATUS: \(markdownResponse.status)")
        print("MARKDOWN CONTENT-TYPE: \(markdownResponse.headers["Content-Type"] ?? "")")
        print("MARKDOWN BODY BEGIN")
        print(markdownBody, terminator: markdownBody.hasSuffix("\n") ? "" : "\n")
        print("MARKDOWN BODY END")
        print("EXPORTER BODY BEGIN")
        print(expectedMarkdown, terminator: expectedMarkdown.hasSuffix("\n") ? "" : "\n")
        print("EXPORTER BODY END")

        check(markdownResponse.status == 200, "format=markdown returns 200, got \(markdownResponse.status): \(errorMessage(markdownResponse))")
        check(
            markdownResponse.headers["Content-Type"] == "text/markdown; charset=utf-8",
            "format=markdown Content-Type is text/markdown; charset=utf-8, got \(markdownResponse.headers["Content-Type"] ?? "<nil>")"
        )
        check(markdownBody == expectedMarkdown, "format=markdown body equals MeetingTranscriptExporter.markdown(for: session)")
        check(!markdownBody.contains("Hidden echo"), "format=markdown omits echo segments")
        check(markdownBody.contains(#"Renée \[lead\]"#), "speaker name is Markdown-escaped")
        check(markdownBody.contains(#"Corrected \*\*words\*\* 👋"#), "segment text is Markdown-escaped")

        // 2. Empty / no-segment session still 200s with heading structure.
        var empty = makeSession(title: "Empty meeting", segments: false)
        empty.transcriptSegments = []
        try? await store.create(empty)
        let emptyResponse = await router.route(
            request(query: ["id": empty.id.uuidString, "format": "markdown"])
        )
        let emptyBody = String(data: emptyResponse.body, encoding: .utf8) ?? ""
        let expectedEmpty = MeetingTranscriptExporter.markdown(for: empty)
        print("EMPTY MARKDOWN STATUS: \(emptyResponse.status)")
        print("EMPTY MARKDOWN BODY BEGIN")
        print(emptyBody, terminator: emptyBody.hasSuffix("\n") ? "" : "\n")
        print("EMPTY MARKDOWN BODY END")
        check(emptyResponse.status == 200, "empty session format=markdown returns 200, got \(emptyResponse.status): \(errorMessage(emptyResponse))")
        check(emptyBody == expectedEmpty, "empty session body equals MeetingTranscriptExporter.markdown(for: session)")
        check(emptyBody == "# Empty meeting\n\n## Transcript\n", "empty session keeps heading structure")
        check(!emptyBody.isEmpty, "empty session markdown is not an empty body")

        // 3. Unknown formats stay 400 and mention markdown.
        for format in ["xml", "html", "md", "Markdown"] {
            let response = await router.route(
                request(query: ["id": session.id.uuidString, "format": format])
            )
            let message = errorMessage(response)
            check(response.status == 400, "format=\(format) returns 400, got \(response.status)")
            check(message.contains("markdown"), "format=\(format) error mentions markdown: \(message)")
            check(message.contains("json"), "format=\(format) error mentions json: \(message)")
            check(message.contains("text"), "format=\(format) error mentions text: \(message)")
        }

        // 4. JSON is unchanged: 200, application/json, echoes included with the flag.
        let jsonResponse = await router.route(request(query: ["id": session.id.uuidString]))
        check(jsonResponse.status == 200, "format=json (default) returns 200")
        check(
            jsonResponse.headers["Content-Type"] == "application/json; charset=utf-8",
            "format=json Content-Type stays application/json; charset=utf-8"
        )
        do {
            let expectedJSON = try MeetingTranscriptExporter.json(for: session)
            check(jsonResponse.body == expectedJSON, "format=json body equals MeetingTranscriptExporter.json(for: session)")
        } catch {
            check(false, "json exporter threw \(error)")
        }
        let json = jsonObject(jsonResponse)
        let jsonSegments = json["segments"] as? [[String: Any]] ?? []
        check(jsonSegments.count == 2, "JSON still includes echo segments, count=\(jsonSegments.count)")
        let echoFlags = jsonSegments.compactMap { $0["isLikelyEcho"] as? Bool }
        check(echoFlags.contains(true), "JSON still reports isLikelyEcho on echo segments")
        check(
            jsonSegments.contains { ($0["text"] as? String) == "Hidden echo" },
            "JSON still includes echo text"
        )

        // 5. Text is unchanged: 200, text/plain, echoes omitted.
        let textResponse = await router.route(
            request(query: ["id": session.id.uuidString, "format": "text"])
        )
        let textBody = String(data: textResponse.body, encoding: .utf8) ?? ""
        check(textResponse.status == 200, "format=text returns 200")
        check(
            textResponse.headers["Content-Type"] == "text/plain; charset=utf-8",
            "format=text Content-Type stays text/plain; charset=utf-8"
        )
        check(
            textBody == MeetingTranscriptExporter.text(for: session),
            "format=text body equals MeetingTranscriptExporter.text(for: session)"
        )
        check(!textBody.contains("Hidden echo"), "format=text still omits echoes")
        check(textBody.contains("Renée [lead]: Corrected **words** 👋"), "format=text still has the corrected line")

        // 6. Empty session text stays an empty body (exporter difference vs markdown).
        let emptyText = await router.route(
            request(query: ["id": empty.id.uuidString, "format": "text"])
        )
        check(emptyText.status == 200, "empty session format=text returns 200")
        check(emptyText.body.isEmpty, "empty session format=text body is empty")

        print("checks=\(checks) failures=\(failures.count)")
        if failures.isEmpty {
            print("PASS: meeting transcript markdown local API (\(checks) checks)")
        } else {
            print("FAILED \(failures.count) of \(checks) meeting transcript markdown checks")
            exit(1)
        }
    }
}
