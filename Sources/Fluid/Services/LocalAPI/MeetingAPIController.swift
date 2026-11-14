import Foundation

struct MeetingAPIController: LocalAPIRouteHandler {
    struct MeetingListResponse: Encodable {
        let count: Int
        let items: [MeetingItem]
    }

    struct MeetingItem: Encodable {
        let id: UUID
        let title: String
        let startedAt: Date
        let endedAt: Date?
        let updatedAt: Date
        let state: MeetingSessionState
        let languageCode: String
        let durationSeconds: TimeInterval
        let segmentCount: Int
        let transcriptIsComplete: Bool?
    }

    private enum TranscriptFormat: String {
        case json
        case text
        case markdown
    }

    let store: any MeetingSessionStoring
    let liveTranscript: any MeetingLiveTranscriptProviding

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        guard request.method == "GET" else {
            return LocalAPI.error("Method not allowed.", status: 405)
        }

        switch request.path {
        case "/v1/meetings":
            return await self.listMeetings(request)
        case "/v1/meetings/transcript":
            return await self.transcript(request)
        case "/v1/meetings/live":
            return await self.live(request)
        default:
            return LocalAPI.error("Route not found.", status: 404)
        }
    }

    private func listMeetings(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            let sessions = try await self.store.loadAll()
            let items = sessions.prefix(LocalAPI.boundedLimit(from: request)).map { session in
                MeetingItem(
                    id: session.id,
                    title: session.title,
                    startedAt: session.startedAt,
                    endedAt: session.endedAt,
                    updatedAt: session.updatedAt,
                    state: session.state,
                    languageCode: session.languageCode,
                    durationSeconds: session.duration,
                    segmentCount: session.transcriptSegments.count,
                    transcriptIsComplete: session.transcriptIsComplete
                )
            }
            return LocalAPI.json(MeetingListResponse(count: items.count, items: items))
        } catch {
            return LocalAPI.error("Meetings are unavailable. Retry from FluidMeet in FluidVoice.", status: 503)
        }
    }

    /// The in-progress meeting's live captions. Pollers pass back the `session` and `revision`
    /// they last saw as `session` and `since`, and get `304` while nothing has changed. Revisions
    /// restart with each meeting, so `304` needs both values to match.
    private func live(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        var since: UInt64?
        if let rawSince = request.query["since"] {
            guard let revision = UInt64(rawSince) else {
                return LocalAPI.error("The 'since' query parameter must be a non-negative integer revision.", status: 400)
            }
            since = revision
        }
        var sessionID: UUID?
        if let rawSession = request.query["session"] {
            guard let id = UUID(uuidString: rawSession) else {
                return LocalAPI.error("Provide a valid meeting UUID in the 'session' query parameter.", status: 400)
            }
            sessionID = id
        }

        // The router adds Cache-Control: no-store to every response on this path.
        let reading = await self.liveTranscript.currentLiveTranscript()
        if let since, let sessionID, sessionID == reading.sessionID, since == reading.snapshot.revision {
            return LocalAPI.Response(status: 304)
        }
        return LocalAPI.json(MeetingLiveResponse(reading: reading))
    }

    private func transcript(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        guard let rawID = request.query["id"], let id = UUID(uuidString: rawID) else {
            return LocalAPI.error("Provide a valid meeting UUID in the 'id' query parameter.", status: 400)
        }
        guard let format = TranscriptFormat(rawValue: request.query["format"] ?? "json") else {
            return LocalAPI.error("Transcript format must be 'json', 'text', or 'markdown'.", status: 400)
        }

        let session: MeetingSession
        do {
            guard let savedSession = try await self.store.load(id: id) else {
                return LocalAPI.error("Meeting not found.", status: 404)
            }
            session = savedSession
        } catch {
            return LocalAPI.error("Meeting is unavailable. Retry from FluidMeet in FluidVoice.", status: 503)
        }

        switch format {
        case .json:
            do {
                return try LocalAPI.Response(
                    status: 200,
                    headers: ["Content-Type": "application/json; charset=utf-8"],
                    body: MeetingTranscriptExporter.json(for: session)
                )
            } catch {
                return LocalAPI.error("Failed to encode meeting transcript.", status: 500)
            }
        case .text:
            return LocalAPI.Response(
                status: 200,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data(MeetingTranscriptExporter.text(for: session).utf8)
            )
        case .markdown:
            return LocalAPI.Response(
                status: 200,
                headers: ["Content-Type": "text/markdown; charset=utf-8"],
                body: Data(MeetingTranscriptExporter.markdown(for: session).utf8)
            )
        }
    }
}
