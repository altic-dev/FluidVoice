import AVFoundation
import CoreMedia
import Foundation
#if arch(arm64)
@preconcurrency import CoreML
import FluidAudio
import os

/// Only public dependency operations are represented. A completed reset does NOT prove that
/// decoder state reset succeeded (the dependency currently suppresses internal reset errors).
nonisolated protocol MeetingLiveRecognizer: Sendable {
    func prepareModels() async throws
    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws
    func processBufferedAudio() async throws
    func reset() async
    func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async
    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) async
}

extension StreamingEouAsrManager: MeetingLiveRecognizer {
    func prepareModels() async throws { try await self.loadModelsFromHuggingFace() }
}

/// Numeric wrapper observations, not speech truth, token counts, or a recovery verdict.
/// No audio, transcript, embedding, route identifiers or user identifiers are retained here.
nonisolated struct MeetingLiveDiagnosticSnapshot: Sendable {
    var convertedBuffers = 0
    var conversionFailures = 0
    var appendStarts = 0
    var appendCompletions = 0
    var processStarts = 0
    var processCompletions = 0
    var appendOrProcessErrors = 0
    var partialCallbacks = 0
    var eouCallbacks = 0
    var resetInvocations = 0
    var recognizerResetReturned = 0
    var wrapperGeneration = 0
    var maxProcessSeconds: Double = 0
    var firstPartialAfterResetSeconds: Double?
    var feedSeconds: Double = 0
}

/// Drives one `StreamingEouAsrManager` for one capture track. Two instances are required — the
/// manager holds a single decoder and endpointing state, so interleaving two audio sources would
/// corrupt both transcripts.
///
/// Audio arrives via the nonisolated `offer(_:)`, called synchronously from the capture-tee copy
/// (never from the SCStream callback itself). A polling drain loop pulls off the bounded queue and
/// does all FluidAudio work on this actor, off the capture path entirely.
actor MeetingLiveTrackEngine {
    typealias PartialHandler = @Sendable (MeetingAudioTrackKind, UUID, String, CMTime, CMTime) -> Void
    typealias UtteranceHandler = @Sendable (MeetingAudioTrackKind, UUID, String, CMTime, CMTime) -> Void
    typealias DegradedHandler = @Sendable (MeetingAudioTrackKind, String) -> Void
    typealias ReadyHandler = @Sendable (MeetingAudioTrackKind) -> Void

    private let kind: MeetingAudioTrackKind
    /// Sized to ride out first-inference CoreML warmup without dropping audio: at the ~10.7ms
    /// microphone buffers observed in practice this holds ~5.5s, and app-audio buffers twice that.
    /// A 24-slot queue held only ~0.25s and shed 5s of meeting-opening audio during warmup.
    nonisolated let queue = MeetingLiveBoundedQueue<MeetingLiveSampleCopy.Sample>(capacity: 512)
    private static let chunkSize: StreamingChunkSize = .ms160
    private static let maxOpenUtteranceSeconds: Double = 20
    private static let partialStallSeconds: Double = 2.5
    /// The recognizer buffers a full chunk before it can decode it, so the speech behind the first
    /// token started at least one chunk before the audio we were feeding when that token arrived.
    private static let decoderLookback = CMTime(value: CMTimeValue(chunkSize.durationMs), timescale: 1000)
    private let manager: any MeetingLiveRecognizer
    private let uptime: @Sendable () -> Double
    private let diagnosticsEnabled: Bool
    private var diagnosticSnapshot = MeetingLiveDiagnosticSnapshot()
    private var diagnosticResetUptime: Double?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var utteranceStartPTS: CMTime?
    private var utteranceTurnID: UUID?
    private var lastPartialText = ""
    private var lastPartialUptime: Double?
    private var lastConsumedPTS: CMTime?
    private var currentFeedPTS: CMTime?
    private var lastUtteranceEndPTS: CMTime?
    private var pendingResync = false
    private var drainTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var isModelReady = false

    private var diagSamplesConsumed = 0
    private var diagSecondsConsumed: Double = 0
    private var diagDrops = 0
    private var diagPartials = 0
    private var diagUtterances = 0
    private var diagLastFlowLog: Double = 0
    private var diagLastEouUptime: Double?

    private var diagLabel: String { self.kind == .microphone ? "MIC" : "APP" }

    private func diag(_ message: String) {
        DebugLogger.shared.info("[live/\(self.diagLabel)] \(message)", source: "MeetingLive")
    }

    private var onPartial: PartialHandler?
    private var onUtterance: UtteranceHandler?
    private var onDegraded: DegradedHandler?
    private var onReady: ReadyHandler?

    init(
        kind: MeetingAudioTrackKind,
        recognizer: (any MeetingLiveRecognizer)? = nil,
        uptime: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        diagnosticsEnabled: Bool? = nil
    ) {
        self.kind = kind
        self.manager = recognizer ?? StreamingEouAsrManager(chunkSize: Self.chunkSize)
        self.uptime = uptime
        #if DEBUG
        self.diagnosticsEnabled = diagnosticsEnabled
            ?? (ProcessInfo.processInfo.environment["FLUIDVOICE_MEETING_LIVE_DIAGNOSTICS"] == "1")
        #else
        self.diagnosticsEnabled = false
        #endif
    }

    func configure(
        onPartial: @escaping PartialHandler,
        onUtterance: @escaping UtteranceHandler,
        onDegraded: @escaping DegradedHandler,
        onReady: @escaping ReadyHandler
    ) {
        self.onPartial = onPartial
        self.onUtterance = onUtterance
        self.onDegraded = onDegraded
        self.onReady = onReady
    }

    func start() async {
        guard self.drainTask == nil else { return }
        let manager = self.manager
        let kind = self.kind
        // Wired synchronously before load/drain start so no decode result can race ahead of it.
        await self.installCallbacks()
        self.loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                // Shares FluidAudio's default cache dir, so a Parakeet Flash download for
                // dictation already satisfies this — first-run cost is paid at most once.
                try await manager.prepareModels()
                guard !Task.isCancelled else { return }
                await self.warmUp()
                guard !Task.isCancelled else { return }
                await self.markReady()
            } catch {
                guard !Task.isCancelled else { return }
                await self.markLoadFailed(kind: kind, error: error)
            }
        }
        self.drainTask = Task { [weak self] in await self?.drainLoop() }
    }

    func stop() async {
        self.loadTask?.cancel()
        self.drainTask?.cancel()
        await self.drainTask?.value
        self.drainTask = nil
        await self.resetRecognizer()
    }

    /// Fast, synchronous, non-blocking hand-off from the capture tee. On saturation the queue drops
    /// the oldest sample, which makes the in-flight utterance untrustworthy — reset and degrade.
    nonisolated func offer(_ sample: MeetingLiveSampleCopy.Sample) {
        let dropped = self.queue.enqueue(sample)
        if dropped {
            Task { await self.noteDrop() }
        }
    }

    private func installCallbacks() async {
        await self.manager.setEouCallback { [weak self] transcript in
            Task { await self?.handleEOU(transcript) }
        }
        await self.manager.setPartialTranscriptCallback { [weak self] transcript in
            Task { await self?.handlePartial(transcript) }
        }
    }

    /// First CoreML inference on these models costs seconds. Paying it here on silence — before
    /// `isModelReady` opens the drain loop — keeps the warmup stall from backing up real capture
    /// audio, which previously overflowed the queue and shed the first ~5s of every meeting.
    private func warmUp() async {
        let frames = AVAudioFrameCount(self.targetFormat.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: frames) else { return }
        silence.frameLength = frames
        if let channel = silence.floatChannelData?[0] {
            channel.update(repeating: 0, count: Int(frames))
        }
        let started = self.uptime()
        do {
            try await self.manager.appendAudio(silence)
            try await self.manager.processBufferedAudio()
        } catch {
            self.diag("warmup failed (continuing): \(error)")
        }
        await self.resetRecognizer()
        self.diag(String(format: "warmup complete in %.2fs", self.uptime() - started))
    }

    private func markReady() {
        self.isModelReady = true
        self.diag("model ready")
        self.onReady?(self.kind)
    }

    private func markLoadFailed(kind: MeetingAudioTrackKind, error: Error) {
        self.diag("model load FAILED: \(error)")
        self.onDegraded?(kind, "Live captions could not load: \(error.localizedDescription)")
    }

    private func drainLoop() async {
        while !Task.isCancelled {
            guard self.isModelReady else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let samples = self.queue.drainAll()
            guard !samples.isEmpty else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            await self.applyPendingResyncIfNeeded()
            for sample in samples where !Task.isCancelled {
                await self.consume(sample)
            }
        }
    }

    private func consume(_ sample: MeetingLiveSampleCopy.Sample) async {
        guard let converted = self.convert(sample.buffer) else {
            if self.diagnosticsEnabled { self.diagnosticSnapshot.conversionFailures += 1 }
            self.diag("convert FAILED (sr=\(sample.buffer.format.sampleRate) ch=\(sample.buffer.format.channelCount))")
            return
        }
        self.currentFeedPTS = sample.pts
        self.lastConsumedPTS = sample.pts + sample.duration
        self.diagSamplesConsumed += 1
        self.diagSecondsConsumed += sample.duration.seconds
        if self.diagnosticsEnabled {
            self.diagnosticSnapshot.convertedBuffers += 1
            self.diagnosticSnapshot.feedSeconds += sample.duration.seconds
        }
        self.logFlowIfDue()
        do {
            if self.diagnosticsEnabled { self.diagnosticSnapshot.appendStarts += 1 }
            try await self.manager.appendAudio(converted)
            if self.diagnosticsEnabled {
                self.diagnosticSnapshot.appendCompletions += 1
                self.diagnosticSnapshot.processStarts += 1
            }
            let processStarted = self.diagnosticsEnabled ? self.uptime() : 0
            try await self.manager.processBufferedAudio()
            if self.diagnosticsEnabled {
                self.diagnosticSnapshot.processCompletions += 1
                self.diagnosticSnapshot.maxProcessSeconds = max(
                    self.diagnosticSnapshot.maxProcessSeconds, self.uptime() - processStarted
                )
            }
            await self.rotateLongUtteranceIfNeeded()
        } catch {
            if self.diagnosticsEnabled { self.diagnosticSnapshot.appendOrProcessErrors += 1 }
            self.diag("appendAudio/process error: \(error)")
            self.onDegraded?(self.kind, "Live captions hit an error and resynced.")
            await self.resetUtterance()
        }
    }

    /// The decoder's own endpointing is unreliable in the field: it can stop emitting partials
    /// mid-utterance (observed after as little as 10s / ~120 chars) and never fire EOU, freezing
    /// captions on stale text. Two fallbacks close the turn: the decoder has gone quiet for a few
    /// seconds (a pause or a stall — either way the turn is over), or the utterance hit the hard
    /// duration ceiling. Both finalize the current partial and reset for a fresh turn.
    private func rotateLongUtteranceIfNeeded() async {
        guard let start = self.utteranceStartPTS,
              let end = self.lastConsumedPTS,
              let turnID = self.utteranceTurnID
        else { return }
        let openSeconds = end.seconds - start.seconds
        let quietSeconds = self.lastPartialUptime.map { self.uptime() - $0 }
        let hitCeiling = openSeconds > Self.maxOpenUtteranceSeconds
        let decoderQuiet = (quietSeconds ?? 0) > Self.partialStallSeconds && !self.lastPartialText.isEmpty
        guard hitCeiling || decoderQuiet else { return }
        let text = self.lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.utteranceStartPTS = nil
        self.utteranceTurnID = nil
        self.lastPartialText = ""
        self.lastPartialUptime = nil
        await self.resetRecognizer()
        guard !text.isEmpty else { return }
        self.lastUtteranceEndPTS = end
        self.diagUtterances += 1
        self.diag(String(
            format: "forced EOU (%@) span=[%.2f–%.2f] chars=%d",
            hitCeiling ? "open>\(Int(Self.maxOpenUtteranceSeconds))s" : String(format: "quiet %.1fs", quietSeconds ?? 0),
            start.seconds, end.seconds, text.count
        ))
        self.onUtterance?(self.kind, turnID, text, start, end)
    }

    /// Once every 5s of wall clock: proves audio is still reaching the recognizer, and how long the
    /// current utterance has been open without an endpoint.
    private func logFlowIfDue() {
        let now = self.uptime()
        guard now - self.diagLastFlowLog >= 5 else { return }
        self.diagLastFlowLog = now
        let openFor = self.utteranceStartPTS.map { start in
            (self.lastConsumedPTS ?? start).seconds - start.seconds
        } ?? 0
        let sinceEou = self.diagLastEouUptime.map { now - $0 }
        self.diag(String(
            format: "flow chunks=%d audio=%.1fs openUtterance=%.1fs partials=%d utterances=%d drops=%d sinceEOU=%@",
            self.diagSamplesConsumed, self.diagSecondsConsumed, openFor,
            self.diagPartials, self.diagUtterances, self.diagDrops,
            sinceEou.map { String(format: "%.1fs", $0) } ?? "never"
        ))
        if self.diagnosticsEnabled {
            let snapshot = self.diagnosticSnapshot
            // Wrapper counters only: no audio, transcript, names, or identity evidence.
            // Actor-local logging is not an independent hung-executor watchdog.
            self.diag("p0 converted=\(snapshot.convertedBuffers) conversionFailures=\(snapshot.conversionFailures) append=\(snapshot.appendCompletions)/\(snapshot.appendStarts) process=\(snapshot.processCompletions)/\(snapshot.processStarts) errors=\(snapshot.appendOrProcessErrors) partialCallbacks=\(snapshot.partialCallbacks) eouCallbacks=\(snapshot.eouCallbacks) resetReturns=\(snapshot.recognizerResetReturned)/\(snapshot.resetInvocations) resetOrdinal=\(snapshot.wrapperGeneration) maxProcessSeconds=\(snapshot.maxProcessSeconds)")
        }
    }

    /// The recognizer only emits tokens once it has decoded speech, so the first partial — not the
    /// first audio buffer — marks where this utterance actually begins. Anchoring on audio instead
    /// swallowed every second of preceding silence into the utterance's span.
    private func handlePartial(_ text: String) {
        if self.diagnosticsEnabled {
            self.diagnosticSnapshot.partialCallbacks += 1
            if self.diagnosticSnapshot.firstPartialAfterResetSeconds == nil,
               let reset = self.diagnosticResetUptime {
                self.diagnosticSnapshot.firstPartialAfterResetSeconds = self.uptime() - reset
            }
        }
        if self.utteranceStartPTS == nil {
            guard let feed = self.currentFeedPTS else { return }
            let backdated = feed - Self.decoderLookback
            // Backdating must not reach behind the utterance that just closed, or consecutive turns
            // render as overlapping spans.
            self.utteranceStartPTS = self.lastUtteranceEndPTS.map { max(backdated, $0) } ?? backdated
            self.utteranceTurnID = UUID()
        }
        guard let start = self.utteranceStartPTS, let turnID = self.utteranceTurnID else { return }
        self.lastPartialText = text
        self.lastPartialUptime = self.uptime()
        let end = self.lastConsumedPTS ?? start
        self.diagPartials += 1
        if self.diagPartials % 10 == 1 {
            self.diag("partial #\(self.diagPartials) chars=\(text.count) tail=…\(String(text.suffix(60)))")
        }
        self.onPartial?(self.kind, turnID, text, start, end)
    }

    private func handleEOU(_ text: String) async {
        if self.diagnosticsEnabled { self.diagnosticSnapshot.eouCallbacks += 1 }
        let start = self.utteranceStartPTS
        let end = self.lastConsumedPTS ?? start
        let turnID = self.utteranceTurnID
        let now = self.uptime()
        let gap = self.diagLastEouUptime.map { now - $0 }
        self.diagLastEouUptime = now
        self.utteranceStartPTS = nil
        self.utteranceTurnID = nil
        self.lastPartialText = ""
        self.lastPartialUptime = nil
        await self.resetRecognizer()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let start, let end, let turnID else {
            self.diag("EOU fired but no start PTS — dropped (chars=\(text.count))")
            return
        }
        self.lastUtteranceEndPTS = end
        self.diagUtterances += 1
        self.diag(String(
            format: "EOU #%d span=[%.2f–%.2f] (%.1fs) sinceLastEOU=%@ text=%@",
            self.diagUtterances, start.seconds, end.seconds, end.seconds - start.seconds,
            gap.map { String(format: "%.1fs", $0) } ?? "first",
            trimmed
        ))
        self.onUtterance?(self.kind, turnID, trimmed, start, end)
    }

    /// A saturated queue sheds many samples in a burst. Recording one pending resync instead of
    /// resetting per sample keeps a 250-sample burst from issuing 250 decoder resets and 250
    /// degraded notifications; the drain loop performs exactly one resync before it next consumes.
    private func noteDrop() {
        self.diagDrops += 1
        self.pendingResync = true
    }

    private func applyPendingResyncIfNeeded() async {
        guard self.pendingResync else { return }
        self.pendingResync = false
        self.diag("queue saturated — resyncing after \(self.diagDrops) dropped samples")
        await self.resetUtterance()
        self.onDegraded?(self.kind, "Live captions dropped audio and resynced.")
    }

    private func resetUtterance() async {
        self.utteranceStartPTS = nil
        self.utteranceTurnID = nil
        self.lastPartialText = ""
        self.lastPartialUptime = nil
        self.lastConsumedPTS = nil
        await self.resetRecognizer()
    }

    private func resetRecognizer() async {
        if self.diagnosticsEnabled {
            self.diagnosticSnapshot.resetInvocations += 1
            self.diagnosticSnapshot.wrapperGeneration += 1
            self.diagnosticSnapshot.firstPartialAfterResetSeconds = nil
            self.diagnosticResetUptime = nil
        }
        await self.manager.reset()
        if self.diagnosticsEnabled {
            self.diagnosticSnapshot.recognizerResetReturned += 1
            self.diagnosticResetUptime = self.uptime()
        }
    }

    #if DEBUG
    /// Deterministic P0 seam: bypasses capture/model loading, but exercises production conversion,
    /// append/process and existing rotation policy. It deliberately does not add recovery policy.
    func diagnosticConsume(_ sample: MeetingLiveSampleCopy.Sample) async { await self.consume(sample) }
    func diagnosticPartial(_ text: String) { self.handlePartial(text) }
    func diagnosticSnapshotValue() -> MeetingLiveDiagnosticSnapshot { self.diagnosticSnapshot }
    #endif

    /// Persistent converter reused across calls; FluidAudio's own `appendAudio` takes a fast path
    /// once the buffer already matches its 16kHz mono target, so this is the only resample per chunk.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        if format.sampleRate == self.targetFormat.sampleRate,
           format.channelCount == self.targetFormat.channelCount,
           format.commonFormat == self.targetFormat.commonFormat
        {
            return buffer
        }
        if self.converter == nil || self.converterSourceFormat != format {
            self.converterSourceFormat = format
            self.converter = AVAudioConverter(from: format, to: self.targetFormat)
        }
        guard let converter = self.converter else { return nil }

        let ratio = self.targetFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return nil }

        let provided = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let wasProvided = provided.withLock { state -> Bool in
                if state { return true }
                state = true
                return false
            }
            if wasProvided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { return nil }
        return output
    }
}
#endif
