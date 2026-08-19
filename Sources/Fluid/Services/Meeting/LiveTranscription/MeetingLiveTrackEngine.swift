import AVFoundation
import CoreMedia
import Foundation
#if arch(arm64)
@preconcurrency import CoreML
import FluidAudio
import os

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
    /// The recognizer buffers a full chunk before it can decode it, so the speech behind the first
    /// token started at least one chunk before the audio we were feeding when that token arrived.
    private static let decoderLookback = CMTime(value: CMTimeValue(chunkSize.durationMs), timescale: 1000)
    private let manager: StreamingEouAsrManager
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var utteranceStartPTS: CMTime?
    private var utteranceTurnID: UUID?
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

    init(kind: MeetingAudioTrackKind) {
        self.kind = kind
        self.manager = StreamingEouAsrManager(chunkSize: Self.chunkSize)
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
                try await manager.loadModelsFromHuggingFace()
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
        await self.manager.reset()
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
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await self.manager.appendAudio(silence)
            try await self.manager.processBufferedAudio()
        } catch {
            self.diag("warmup failed (continuing): \(error)")
        }
        await self.manager.reset()
        self.diag(String(format: "warmup complete in %.2fs", ProcessInfo.processInfo.systemUptime - started))
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
            self.diag("convert FAILED (sr=\(sample.buffer.format.sampleRate) ch=\(sample.buffer.format.channelCount))")
            return
        }
        self.currentFeedPTS = sample.pts
        self.lastConsumedPTS = sample.pts + sample.duration
        self.diagSamplesConsumed += 1
        self.diagSecondsConsumed += sample.duration.seconds
        self.logFlowIfDue()
        do {
            try await self.manager.appendAudio(converted)
            try await self.manager.processBufferedAudio()
        } catch {
            self.diag("appendAudio/process error: \(error)")
            self.onDegraded?(self.kind, "Live captions hit an error and resynced.")
            await self.resetUtterance()
        }
    }

    /// Once every 5s of wall clock: proves audio is still reaching the recognizer, and how long the
    /// current utterance has been open without an endpoint.
    private func logFlowIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
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
    }

    /// The recognizer only emits tokens once it has decoded speech, so the first partial — not the
    /// first audio buffer — marks where this utterance actually begins. Anchoring on audio instead
    /// swallowed every second of preceding silence into the utterance's span.
    private func handlePartial(_ text: String) {
        if self.utteranceStartPTS == nil {
            guard let feed = self.currentFeedPTS else { return }
            let backdated = feed - Self.decoderLookback
            // Backdating must not reach behind the utterance that just closed, or consecutive turns
            // render as overlapping spans.
            self.utteranceStartPTS = self.lastUtteranceEndPTS.map { max(backdated, $0) } ?? backdated
            self.utteranceTurnID = UUID()
        }
        guard let start = self.utteranceStartPTS, let turnID = self.utteranceTurnID else { return }
        let end = self.lastConsumedPTS ?? start
        self.diagPartials += 1
        if self.diagPartials % 10 == 1 {
            self.diag("partial #\(self.diagPartials) chars=\(text.count) tail=…\(String(text.suffix(60)))")
        }
        self.onPartial?(self.kind, turnID, text, start, end)
    }

    private func handleEOU(_ text: String) async {
        let start = self.utteranceStartPTS
        let end = self.lastConsumedPTS ?? start
        let turnID = self.utteranceTurnID
        let now = ProcessInfo.processInfo.systemUptime
        let gap = self.diagLastEouUptime.map { now - $0 }
        self.diagLastEouUptime = now
        self.utteranceStartPTS = nil
        self.utteranceTurnID = nil
        await self.manager.reset()
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
        self.lastConsumedPTS = nil
        await self.manager.reset()
    }

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
