import Foundation

/// One reconciler owns all media queries and commands. Recording events update
/// intent synchronously; they never wait for media control or delay first PCM.
@MainActor
final class MediaPlaybackService {
    static let shared = MediaPlaybackService(transport: MediaPlaybackProcessTransport())

    private struct Session {
        let id: Int
        var mayPause: Bool
    }

    private let transport: any MediaPlaybackTransport
    private let settle: @Sendable () async -> Void
    private let now: @Sendable () -> TimeInterval
    private var session: Session?
    private var revision: UInt64 = 0
    private var attemptedSession: Int?
    private var pausedTarget: MediaPlaybackSnapshot?
    private var worker: Task<Void, Never>?
    private var suspendedUntil: TimeInterval = 0
    private var isShuttingDown = false

    init(
        transport: any MediaPlaybackTransport,
        settle: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: 150_000_000)
        },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.transport = transport
        self.settle = settle
        self.now = now
    }

    func recordingStarted(sessionID: Int, enabled: Bool) {
        guard !self.isShuttingDown else { return }
        self.session = enabled ? Session(id: sessionID, mayPause: true) : nil
        self.revision &+= 1
        self.log("recording_started session=\(sessionID) enabled=\(enabled)")
        self.wake()
    }

    /// Prevent a slow query from issuing pause after the hotkey is released.
    /// A previously confirmed pause stays owned until transcription finishes.
    func recordingStopped(sessionID: Int) {
        guard self.session?.id == sessionID else { return }
        self.session?.mayPause = false
        self.revision &+= 1
        self.log("recording_stopped session=\(sessionID)")
        self.wake()
    }

    /// An older transcription finishing cannot resume a newer recording's media.
    func sessionFinished(sessionID: Int) {
        guard self.session?.id == sessionID else { return }
        self.session = nil
        self.revision &+= 1
        self.log("session_finished session=\(sessionID)")
        self.wake()
    }

    func shutdown() async {
        self.isShuttingDown = true
        self.session = nil
        self.revision &+= 1
        self.wake()
        await self.waitUntilSettled()
    }

    /// Also used by deterministic tests; no continuous observer or polling task.
    func waitUntilSettled() async {
        while let worker = self.worker {
            await worker.value
        }
    }

    private func wake() {
        guard self.worker == nil else { return }
        self.worker = Task { await self.reconcile() }
    }

    private func reconcile() async {
        while true {
            let observedRevision = self.revision
            if let session = self.session {
                if session.mayPause, self.attemptedSession != session.id {
                    self.attemptedSession = session.id
                    await self.pause(sessionID: session.id)
                }
            } else if let target = self.pausedTarget {
                await self.resume(target: target)
            }
            guard observedRevision != self.revision else {
                self.worker = nil
                return
            }
        }
    }

    private func canPause(_ sessionID: Int) -> Bool {
        self.session?.id == sessionID && self.session?.mayPause == true
    }

    private func pause(sessionID: Int) async {
        guard self.now() >= self.suspendedUntil else {
            self.log("pause_suppressed session=\(sessionID) reason=player_backoff")
            return
        }
        guard let before = await self.query(context: "before_pause session=\(sessionID)") else { return }
        guard self.canPause(sessionID) else {
            self.log("pause_skipped session=\(sessionID) reason=stale_recording")
            return
        }
        if let owned = self.pausedTarget, owned.matches(before), before.isPlaying == false {
            self.log("pause_retained session=\(sessionID) reason=already_owned")
            return
        }
        // A player change or manual playback invalidates our previous ownership.
        self.pausedTarget = nil
        guard before.isPlaying == true else {
            self.log("pause_skipped session=\(sessionID) reason=not_known_playing")
            return
        }
        let result = await self.transport.send(.pause)
        self.logCommand(.pause, result: result, sessionID: sessionID)
        // Even a timed-out helper might have sent its command before exiting.
        // Observe state before deciding whether we own a pause to restore.
        if let paused = await self.verify(target: before, playing: false, context: "pause session=\(sessionID)") {
            self.pausedTarget = paused
            self.log("pause_verified session=\(sessionID)")
        } else {
            self.backOff(context: "pause session=\(sessionID)")
        }
    }

    private func resume(target: MediaPlaybackSnapshot) async {
        // Do not clear ownership until after the query: a new recording arriving
        // during it can inherit this verified pause without a play/pause burst.
        guard let before = await self.queryBeforeResume() else {
            guard self.session == nil else { return }
            self.pausedTarget = nil
            self.log("resume_skipped reason=unknown_player")
            return
        }
        guard self.session == nil else {
            self.log("resume_skipped reason=new_recording")
            return
        }
        self.pausedTarget = nil
        guard target.matches(before), before.isPlaying == false else {
            self.log("resume_skipped reason=player_item_or_state_changed")
            return
        }
        let result = await self.transport.send(.play)
        self.logCommand(.play, result: result, sessionID: nil)
        if await self.verify(target: before, playing: true, context: "resume") != nil {
            self.log("resume_verified")
        } else {
            self.backOff(context: "resume")
        }
    }

    private func queryBeforeResume() async -> MediaPlaybackSnapshot? {
        // Retain confirmed ownership across brief metadata outages. Retry reads,
        // never playback commands; give up after three bounded helper calls.
        for attempt in 1...3 {
            guard self.session == nil else { return nil }
            if let snapshot = await self.query(context: "before_resume attempt=\(attempt)") {
                return snapshot
            }
            guard self.session == nil else { return nil }
            if attempt < 3 { await self.settle() }
        }
        return nil
    }

    private func verify(
        target: MediaPlaybackSnapshot, playing: Bool, context: String
    ) async -> MediaPlaybackSnapshot? {
        // Read at most twice; never retry a playback command blindly. This checks
        // reported state, not rendered video: Netflix can disagree with its UI.
        for attempt in 1...2 {
            await self.settle()
            guard let observed = await self.query(context: "verify_\(context) attempt=\(attempt)") else {
                continue
            }
            guard target.matches(observed) else {
                self.log("verification_failed context=\(context) reason=player_or_item_changed")
                return nil
            }
            if observed.isPlaying == playing { return observed }
        }
        self.log("verification_failed context=\(context) reason=state_not_confirmed")
        return nil
    }

    private func query(context: String) async -> MediaPlaybackSnapshot? {
        let started = self.now()
        let result = await self.transport.query()
        let elapsed = Int((self.now() - started) * 1000)
        switch result {
        case let .snapshot(snapshot):
            self.log(
                "query context=\(context) elapsedMs=\(elapsed) " +
                    "bundle=\(snapshot.bundleIdentifier) pid=\(snapshot.processID) " +
                    "playing=\(snapshot.isPlaying.map(String.init) ?? "unknown") " +
                    "hasTitle=\(snapshot.title != nil)"
            )
            return snapshot
        case let .unavailable(reason):
            self.log("query_unavailable context=\(context) elapsedMs=\(elapsed) reason=\(reason)")
            return nil
        }
    }

    private func backOff(context: String) {
        // A finite cooldown limits damage from hotkey spam against an unresponsive
        // player. The next recording after the cooldown performs a fresh query.
        self.suspendedUntil = self.now() + 10
        self.log("commands_suspended context=\(context) seconds=10")
    }

    private func logCommand(
        _ command: MediaPlaybackCommand, result: MediaPlaybackCommandResult, sessionID: Int?
    ) {
        let status: String
        switch result {
        case .helperCompleted: status = "helper_completed_player_unconfirmed"
        case let .failed(reason): status = "failed:\(reason)"
        }
        self.log("command=\(command.rawValue) session=\(sessionID.map(String.init) ?? "none") result=\(status)")
    }

    private func log(_ message: String) {
        DebugLogger.shared.info("MEDIA_CONTROL \(message)", source: "MediaPlaybackService")
    }
}
