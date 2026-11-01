import Foundation

/// Where the local API reads FluidMeet's live transcript. `MeetingSessionCoordinator` in the app.
protocol MeetingLiveTranscriptSource: AnyObject {
    var liveTranscriptReading: MeetingLiveTranscriptReading { get }
}

extension MeetingSessionCoordinator: MeetingLiveTranscriptSource {
    var liveTranscriptReading: MeetingLiveTranscriptReading {
        .live(isRecording: self.isRecording, sessionID: self.activeSession?.id, snapshot: self.liveTranscript)
    }
}

extension MeetingLiveTranscriptReading {
    /// Live captions only while a meeting records. After Stop the coordinator keeps the last
    /// snapshot, which must not be served as current.
    nonisolated static func live(
        isRecording: Bool,
        sessionID: UUID?,
        snapshot: MeetingLiveTranscriptSnapshot
    ) -> MeetingLiveTranscriptReading {
        guard isRecording, let sessionID else { return .idle }
        return MeetingLiveTranscriptReading(sessionID: sessionID, snapshot: snapshot)
    }
}

/// Serves `GET /v1/meetings/live` from the shared meeting coordinator.
nonisolated struct MeetingCoordinatorLiveTranscriptProvider: MeetingLiveTranscriptProviding {
    private let source: @MainActor @Sendable () -> (any MeetingLiveTranscriptSource)?

    init(source: @escaping @MainActor @Sendable () -> (any MeetingLiveTranscriptSource)? = {
        // A poll must not create the coordinator: without one, no meeting is recording.
        AppServices.shared.isMeetingSessionCoordinatorMaterialized ? AppServices.shared.meetingSessionCoordinator : nil
    }) {
        self.source = source
    }

    func currentLiveTranscript() async -> MeetingLiveTranscriptReading {
        // One main-actor hop, so the session ID and the snapshot come from the same moment.
        await MainActor.run { self.source()?.liveTranscriptReading ?? .idle }
    }
}
