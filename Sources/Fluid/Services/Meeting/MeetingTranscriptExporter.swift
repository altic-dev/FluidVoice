import Foundation

/// Single source of truth for rendering a `MeetingSession` transcript as plain text or JSON.
nonisolated enum MeetingTranscriptExporter {
    static func text(for session: MeetingSession, includeEchoes: Bool = false) -> String {
        let speakerNames = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        let segments = session.transcriptSegments
            .filter { includeEchoes || !$0.isEcho }
            .sorted { $0.start.seconds < $1.start.seconds }
        return segments.map { segment in
            let speaker = Self.resolvedSpeakerName(segment.speakerID, in: session, speakerNames: speakerNames)
            return "[\(Self.timestampText(segment.start.seconds))] \(speaker): \(segment.text)"
        }.joined(separator: "\n\n")
    }

    static func json(for session: MeetingSession) throws -> Data {
        let speakers = session.activeSpeakers.map {
            ExportedSpeaker(id: $0.id, displayName: $0.displayName, isLocalUser: $0.isLocalUser)
        }
        let activeSpeakerIDs = Set(speakers.map(\.id))
        let segments = session.transcriptSegments
            .sorted { $0.start.seconds < $1.start.seconds }
            .map {
                ExportedSegment(
                    id: $0.id,
                    startSeconds: $0.start.seconds,
                    endSeconds: $0.end.seconds,
                    speakerID: Self.resolvedSpeakerID(
                        $0.speakerID,
                        in: session,
                        activeSpeakerIDs: activeSpeakerIDs
                    ),
                    text: $0.text,
                    revision: $0.revision,
                    status: $0.status.rawValue,
                    overlap: $0.overlap.rawValue,
                    completeness: $0.completeness.rawValue,
                    isLikelyEcho: $0.isEcho
                )
            }
        let document = ExportedTranscript(
            schemaVersion: 1,
            title: session.title,
            languageCode: session.languageCode,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            durationSeconds: session.duration,
            mode: session.mode.rawValue,
            applicationDisplayName: session.capturedApplication?.displayName,
            speakers: speakers,
            segments: segments
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// A segment may still point at a speaker that was merged away; walk the alias chain
    /// defensively even though post-merge segments are already repointed to the target.
    private static func resolvedSpeakerName(
        _ speakerID: SessionSpeakerID?,
        in session: MeetingSession,
        speakerNames: [SessionSpeakerID: String]
    ) -> String {
        guard let resolvedID = speakerID.map({ Self.resolvedAliasID($0, in: session) }) else {
            return "Unknown speaker"
        }
        return speakerNames[resolvedID] ?? "Unknown speaker"
    }

    /// The same alias-chain walk as `resolvedSpeakerName`, but returning the id itself so JSON
    /// export never references a speaker absent from the exported `speakers` array.
    private static func resolvedSpeakerID(
        _ speakerID: SessionSpeakerID?,
        in session: MeetingSession,
        activeSpeakerIDs: Set<SessionSpeakerID>
    ) -> SessionSpeakerID? {
        guard let resolvedID = speakerID.map({ Self.resolvedAliasID($0, in: session) }) else { return nil }
        return activeSpeakerIDs.contains(resolvedID) ? resolvedID : nil
    }

    private static func resolvedAliasID(_ speakerID: SessionSpeakerID, in session: MeetingSession) -> SessionSpeakerID {
        var resolvedID = speakerID
        var hops = 0
        while let alias = session.speakers.first(where: { $0.id == resolvedID })?.mergedIntoSpeakerID, hops < session.speakers.count {
            resolvedID = alias
            hops += 1
        }
        return resolvedID
    }

    static func timestampText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

private struct ExportedSpeaker: Codable {
    var id: SessionSpeakerID
    var displayName: String
    var isLocalUser: Bool
}

private struct ExportedSegment: Codable {
    var id: MeetingTranscriptSegmentID
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval
    var speakerID: SessionSpeakerID?
    var text: String
    var revision: Int
    var status: String
    var overlap: String
    var completeness: String
    var isLikelyEcho: Bool
}

private struct ExportedTranscript: Codable {
    var schemaVersion: Int
    var title: String
    var languageCode: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: TimeInterval
    var mode: String
    var applicationDisplayName: String?
    var speakers: [ExportedSpeaker]
    var segments: [ExportedSegment]
}
