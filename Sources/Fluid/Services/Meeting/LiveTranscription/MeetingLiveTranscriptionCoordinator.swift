import AVFoundation
import CoreMedia
import Foundation

/// Owns the two live-transcription engines for one meeting recording and publishes a snapshot for
/// the UI. Entirely additive to the recording path: `offer(kind:sampleBuffer:)` is the only entry
/// point invoked from the capture tee, and it never blocks or throws into the capture callback.
///
/// Not `@MainActor` on purpose — `offer` must be callable synchronously from the SCStream callback
/// thread. `onUpdate` is responsible for hopping to the main actor if the caller needs that.
final nonisolated class MeetingLiveTranscriptionCoordinator: @unchecked Sendable {
    /// Two `StreamingEouAsrManager` instances measured at ~470MB RSS each. Below this, skip live
    /// entirely rather than risk contending with the recording or the later batch model.
    static let minimumPhysicalMemoryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let echoWindowSeconds: TimeInterval = 20

    static func isMemorySufficient(physicalMemory: UInt64) -> Bool {
        physicalMemory >= Self.minimumPhysicalMemoryBytes
    }

    private let stateLock = NSLock()
    private var snapshot: MeetingLiveTranscriptSnapshot = .empty
    private var recentThemUtterances: [MeetingLiveUtterance] = []
    private var offerCounts: [MeetingAudioTrackKind: Int] = [:]
    /// nil (fail-safe) keeps the echo filter ON; guarded by `stateLock` on both sides.
    private var microphoneCaptureMethod: MeetingAudioTrackCaptureMethod?
    private let originBox = MeetingLiveOriginBox()
    private let onUpdate: @Sendable (MeetingLiveTranscriptSnapshot) -> Void

    #if arch(arm64)
    private var microphoneEngine: MeetingLiveTrackEngine?
    private var applicationEngine: MeetingLiveTrackEngine?
    #endif

    init(onUpdate: @escaping @Sendable (MeetingLiveTranscriptSnapshot) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Clears any in-progress "You" partial at a capture-side mic splice, so it can't straddle eras.
    func resetMicrophoneUtterance() {
        self.publish { $0.settingPartial(nil, for: .you) }
    }

    func setMicrophoneCaptureMethod(_ method: MeetingAudioTrackCaptureMethod?) {
        self.stateLock.withLock { self.microphoneCaptureMethod = method }
        DebugLogger.shared.info(
            "[live/ECHO] setter-armed captureMethod=\(method.map(String.init(describing:)) ?? "nil")",
            source: "MeetingLive"
        )
    }

    func start(mode: MeetingCaptureMode) {
        #if arch(arm64)
        guard Self.isMemorySufficient(physicalMemory: ProcessInfo.processInfo.physicalMemory) else {
            DebugLogger.shared.info(
                "Live meeting transcription skipped: below memory threshold.",
                source: "MeetingLiveTranscriptionCoordinator"
            )
            self.publish { $0.settingAvailability(.unavailable(reason: "Not enough memory available for live captions.")) }
            return
        }

        DebugLogger.shared.info(
            "[live] starting engines mode=\(mode) physicalMemory=\(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)GB",
            source: "MeetingLive"
        )
        let microphone = MeetingLiveTrackEngine(kind: .microphone)
        self.stateLock.withLock { self.microphoneEngine = microphone }
        self.launch(microphone)

        if mode == .onlineCall {
            let application = MeetingLiveTrackEngine(kind: .applicationAudio)
            self.stateLock.withLock { self.applicationEngine = application }
            self.launch(application)
        }
        self.publish { $0.settingAvailability(.unavailable(reason: "Live captions are loading…")) }
        #else
        self.publish { $0.settingAvailability(.unavailable(reason: "Live captions require Apple Silicon.")) }
        #endif
    }

    /// The capture-tee entry point. Copies the sample immediately, then hands it to the matching
    /// track's bounded queue — never retains the `CMSampleBuffer` beyond this call.
    func offer(kind: MeetingAudioTrackKind, sampleBuffer: CMSampleBuffer) {
        #if arch(arm64)
        guard let sample = MeetingLiveSampleCopy.copy(sampleBuffer) else {
            DebugLogger.shared.info("[live/tee] sample copy FAILED kind=\(kind)", source: "MeetingLive")
            return
        }
        self.originBox.establish(sample.pts)
        let engine: MeetingLiveTrackEngine? = self.stateLock.withLock { () -> MeetingLiveTrackEngine? in
            let count = (self.offerCounts[kind] ?? 0) + 1
            self.offerCounts[kind] = count
            if count == 1 {
                DebugLogger.shared.info(
                    "[live/tee] first sample kind=\(kind) pts=\(String(format: "%.3f", sample.pts.seconds)) sr=\(sample.buffer.format.sampleRate) ch=\(sample.buffer.format.channelCount)",
                    source: "MeetingLive"
                )
            }
            let engine = kind == .microphone ? self.microphoneEngine : self.applicationEngine
            if engine == nil, count == 1 {
                DebugLogger.shared.info("[live/tee] no engine for kind=\(kind) — samples discarded", source: "MeetingLive")
            }
            return engine
        }
        engine?.offer(sample)
        #endif
    }

    /// Must complete before the batch pipeline calls `ensureAsrReady()`, so both engines' CoreML
    /// models are released before the offline model loads.
    func stop() async {
        #if arch(arm64)
        let (microphone, application) = self.stateLock.withLock { () -> (MeetingLiveTrackEngine?, MeetingLiveTrackEngine?) in
            defer {
                self.microphoneEngine = nil
                self.applicationEngine = nil
            }
            return (self.microphoneEngine, self.applicationEngine)
        }
        DebugLogger.shared.info(
            "[live] stopping engines offers=\(self.offerCounts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))",
            source: "MeetingLive"
        )
        await microphone?.stop()
        await application?.stop()
        DebugLogger.shared.info("[live] engines stopped, models released", source: "MeetingLive")
        #endif
    }

    #if arch(arm64)
    private func launch(_ engine: MeetingLiveTrackEngine) {
        Task { [weak self] in
            guard let self else { return }
            await engine.configure(
                onPartial: { [weak self] kind, id, text, start, end in
                    self?.handlePartial(kind: kind, id: id, text: text, start: start, end: end)
                },
                onUtterance: { [weak self] kind, id, text, start, end in
                    self?.handleUtterance(kind: kind, id: id, text: text, start: start, end: end)
                },
                onDegraded: { [weak self] kind, reason in
                    self?.handleDegraded(kind: kind, reason: reason)
                },
                onReady: { [weak self] kind in
                    self?.handleReady(kind: kind)
                }
            )
            await engine.start()
        }
    }

    private func handlePartial(kind: MeetingAudioTrackKind, id: UUID, text: String, start: CMTime, end: CMTime) {
        guard let origin = self.originBox.current else { return }
        let startSeconds = MeetingLiveTimeConversion.sessionSeconds(pts: start, origin: origin)
        let speaker = Self.speaker(for: kind)
        let partial = MeetingLivePartial(id: id, text: text, start: startSeconds)
        self.publish { $0.settingPartial(partial, for: speaker) }
    }

    /// Not `private`: Phase 4 tests drive it directly, predating the solidify UUID — hence the default.
    func handleUtterance(kind: MeetingAudioTrackKind, id: UUID = UUID(), text: String, start: CMTime, end: CMTime) {
        guard let origin = self.originBox.current else { return }
        let startSeconds = MeetingLiveTimeConversion.sessionSeconds(pts: start, origin: origin)
        let endSeconds = MeetingLiveTimeConversion.sessionSeconds(pts: end, origin: origin)
        let speaker = Self.speaker(for: kind)

        let updated: MeetingLiveTranscriptSnapshot = self.stateLock.withLock {
            if speaker == .you {
                if self.microphoneCaptureMethod == .voiceProcessing {
                    DebugLogger.shared.info(
                        "[live/ECHO] skipped (voiceProcessing) mic utterance [\(String(format: "%.2f", startSeconds))] text=\(text)",
                        source: "MeetingLive"
                    )
                } else {
                    let recentThem = MeetingLiveEchoFilter.recentThemText(
                        from: self.recentThemUtterances,
                        before: startSeconds,
                        windowSeconds: Self.echoWindowSeconds
                    )
                    if MeetingLiveEchoFilter.shouldSuppress(micText: text, recentThemText: recentThem) {
                        DebugLogger.shared.info(
                            "[live/ECHO] SUPPRESSED mic utterance [\(String(format: "%.2f", startSeconds))] text=\(text)",
                            source: "MeetingLive"
                        )
                        self.snapshot = self.snapshot.settingPartial(nil, for: .you).markingFinalized(id)
                        return self.snapshot
                    }
                    DebugLogger.shared.info(
                        "[live/ECHO] kept mic utterance [\(String(format: "%.2f", startSeconds))] text=\(text)",
                        source: "MeetingLive"
                    )
                }
            } else {
                let record = MeetingLiveUtterance(id: id, speaker: .them, text: text, start: startSeconds, end: endSeconds)
                self.recentThemUtterances.append(record)
                self.recentThemUtterances.removeAll { $0.end < startSeconds - Self.echoWindowSeconds }
            }
            let utterance = MeetingLiveUtterance(id: id, speaker: speaker, text: text, start: startSeconds, end: endSeconds)
            self.snapshot = self.snapshot.inserting(utterance).settingPartial(nil, for: speaker)
            return self.snapshot
        }
        self.onUpdate(updated)
    }

    private func handleDegraded(kind: MeetingAudioTrackKind, reason: String) {
        DebugLogger.shared.info("[live] DEGRADED kind=\(kind) reason=\(reason)", source: "MeetingLive")
        self.publish { $0.settingAvailability(.degraded(reason: reason)) }
    }

    private func handleReady(kind: MeetingAudioTrackKind) {
        self.publish { snapshot in
            guard case .unavailable = snapshot.availability else { return snapshot }
            return snapshot.settingAvailability(.available)
        }
    }

    private static func speaker(for kind: MeetingAudioTrackKind) -> MeetingLiveSpeaker {
        kind == .microphone ? .you : .them
    }
    #endif

    private func publish(_ transform: (MeetingLiveTranscriptSnapshot) -> MeetingLiveTranscriptSnapshot) {
        let updated: MeetingLiveTranscriptSnapshot = self.stateLock.withLock {
            self.snapshot = transform(self.snapshot)
            return self.snapshot
        }
        self.onUpdate(updated)
    }
}
