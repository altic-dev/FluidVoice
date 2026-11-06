import Foundation

/// Reads FluidMeet's in-memory live transcript for `GET /v1/meetings/live`.
nonisolated protocol MeetingLiveTranscriptProviding: Sendable {
    func currentLiveTranscript() async -> MeetingLiveTranscriptReading
}

/// The live snapshot together with the session it belongs to, read at the same moment.
nonisolated struct MeetingLiveTranscriptReading: Sendable, Equatable {
    let sessionID: UUID?
    let snapshot: MeetingLiveTranscriptSnapshot

    /// No meeting is recording.
    static let idle = MeetingLiveTranscriptReading(
        sessionID: nil,
        snapshot: MeetingLiveTranscriptSnapshot.empty.settingAvailability(.unavailable(reason: "No meeting is recording."))
    )
}

/// Wire format for `GET /v1/meetings/live`. A separate DTO, so the in-memory snapshot is never
/// persisted or made `Codable`.
nonisolated struct MeetingLiveResponse: Encodable {
    struct Availability: Encodable {
        let state: String
        let reason: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.state, forKey: .state)
            // Always present, so clients can rely on the key.
            try container.encode(self.reason, forKey: .reason)
        }

        private enum CodingKeys: String, CodingKey {
            case state
            case reason
        }
    }

    struct Utterance: Encodable {
        let id: UUID
        let speaker: String
        let text: String
        let start: Double
        let end: Double
    }

    struct Partial: Encodable {
        let id: UUID
        let speaker: String
        let text: String
        let start: Double
    }

    let sessionID: UUID?
    let revision: UInt64
    let availability: Availability
    let utterances: [Utterance]
    let partials: [Partial]

    init(reading: MeetingLiveTranscriptReading) {
        let snapshot = reading.snapshot
        self.sessionID = reading.sessionID
        self.revision = snapshot.revision
        self.availability = Self.availability(snapshot.availability)
        self.utterances = snapshot.utterances.map {
            Utterance(id: $0.id, speaker: Self.speaker($0.speaker), text: $0.text, start: $0.start, end: $0.end)
        }
        self.partials = [MeetingLiveSpeaker.you, .them].compactMap { speaker in
            snapshot.partials[speaker].map {
                Partial(id: $0.id, speaker: Self.speaker(speaker), text: $0.text, start: $0.start)
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // `sessionID` is always present; it is null when no meeting is recording.
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.revision, forKey: .revision)
        try container.encode(self.availability, forKey: .availability)
        try container.encode(self.utterances, forKey: .utterances)
        try container.encode(self.partials, forKey: .partials)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case revision
        case availability
        case utterances
        case partials
    }

    private static func speaker(_ speaker: MeetingLiveSpeaker) -> String {
        switch speaker {
        case .you: "you"
        case .them: "them"
        }
    }

    private static func availability(_ availability: MeetingLiveAvailability) -> Availability {
        switch availability {
        case .available:
            Availability(state: "available", reason: nil)
        case let .degraded(reason):
            Availability(state: "degraded", reason: reason)
        case let .unavailable(reason):
            Availability(state: "unavailable", reason: reason)
        }
    }
}
