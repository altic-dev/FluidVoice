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
    func finish() async throws -> String
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
    var textPauses = 0
    var textResumptions = 0
    var lastResetReason: String?
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
    private var comparisonProbe: MeetingAudioComparisonProbe?

    func attachComparisonProbe(_ probe: MeetingAudioComparisonProbe) {
        self.comparisonProbe = probe
        probe.recordEvent("recognizer-probe-attached", track: self.kind)
    }

    /// Sized to ride out first-inference CoreML warmup without dropping audio: at the ~10.7ms
    /// microphone buffers observed in practice this holds ~5.5s, and app-audio buffers twice that.
    /// A 24-slot queue held only ~0.25s and shed 5s of meeting-opening audio during warmup.
    nonisolated let queue = MeetingLiveBoundedQueue<MeetingLiveSampleCopy.Sample>(capacity: 512)
    private static let chunkSize: StreamingChunkSize = .ms160
    private static let partialStallSeconds: Double = 120
    private static let pauseObservationSeconds: Double = 5
    /// The recognizer buffers a full chunk before it can decode it, so the speech behind the first
    /// token started at least one chunk before the audio we were feeding when that token arrived.
    private static let decoderLookback = CMTime(value: CMTimeValue(chunkSize.durationMs), timescale: 1000)
    private let manager: any MeetingLiveRecognizer
    private enum RecognizerCallback: Sendable {
        case partial(String)
        case end(String)
    }

    private let recognizerCallbacks = MeetingLiveBoundedQueue<RecognizerCallback>(capacity: 64)
    private let uptime: @Sendable () -> Double
    private let diagnosticsEnabled: Bool
    private var diagnosticSnapshot = MeetingLiveDiagnosticSnapshot()
    private var diagnosticResetUptime: Double?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        // Fixed Float32 PCM format with positive sample rate and channels is valid by construction.
        // swiftlint:disable:next force_unwrapping
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
    // Each engine belongs to one meeting. Stop is terminal, including suspended startup.
    private var hasStarted = false
    private var isStopped = false

    private var diagSamplesConsumed = 0
    private var diagSecondsConsumed: Double = 0
    private var diagDrops = 0
    private var diagPartials = 0
    private var diagUtterances = 0
    private var diagLastFlowLog: Double = 0
    private var diagLastEouUptime: Double?
    private var firstFeedUptime: Double?
    private var lastTextUpdateUptime: Double?
    private var textPauseReported = false
    private var lastInputRMS: Double = 0
    private var inputEnergySinceFlow: Double = 0
    private var inputSamplesSinceFlow = 0
    private var peakInputRMSSinceFlow: Double = 0
    private var modelProcessCompletions = 0

    private enum ResetReason: String {
        case startupWarmup, stopped, modelEndOfUtterance, noTextTimeout
        case processingError, audioQueueOverflow, callbackQueueOverflow
    }

    private var diagLabel: String { self.kind == .microphone ? "MIC" : "APP" }

    private func diag(_ message: @autoclosure () -> String) {
        guard self.diagnosticsEnabled else { return }
        DebugLogger.shared.info("[live/\(self.diagLabel)] \(message())", source: "MeetingLive")
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
        guard !self.isStopped else { return }
        self.onPartial = onPartial
        self.onUtterance = onUtterance
        self.onDegraded = onDegraded
        self.onReady = onReady
    }

    func start() async {
        guard !self.hasStarted, !self.isStopped else { return }
        self.hasStarted = true
        let manager = self.manager
        let kind = self.kind
        // Wired synchronously before load/drain start so no decode result can race ahead of it.
        await self.installCallbacks()
        guard !self.isStopped else { return }
        self.loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                // Shares FluidAudio's default cache dir, so a Parakeet Flash download for
                // dictation already satisfies this — first-run cost is paid at most once.
                try await MeetingModelPreparationQueue.shared.run {
                    try await manager.prepareModels()
                }
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
        self.comparisonProbe?.recordEvent("recognizer-stop", track: self.kind)
        self.isStopped = true
        self.onPartial = nil
        self.onUtterance = nil
        self.onReady = nil
        self.onDegraded = nil
        self.loadTask?.cancel()
        self.drainTask?.cancel()
        await self.loadTask?.value
        self.loadTask = nil
        self.isModelReady = false
        await self.drainTask?.value
        self.drainTask = nil
        await self.resetRecognizer(reason: .stopped)
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
        let callbacks = self.recognizerCallbacks
        await self.manager.setEouCallback { transcript in
            callbacks.enqueue(.end(transcript))
        }
        await self.manager.setPartialTranscriptCallback { transcript in
            callbacks.enqueue(.partial(transcript))
        }
    }

    /// Model callbacks can arrive while inference is suspended. Apply them only after the
    /// decode call returns, so an endpoint cannot reset the decoder during that same inference.
    private func applyRecognizerCallbacks() async {
        let dropped = self.recognizerCallbacks.takeDroppedCount()
        if dropped > 0 {
            self.comparisonProbe?.recordEvent("recognizer-callbacks-dropped", track: self.kind, detail: String(dropped))
            await self.resetUtterance(reason: .callbackQueueOverflow)
            self.onDegraded?(self.kind, "Live captions missed model updates and resynced.")
            return
        }
        for callback in self.recognizerCallbacks.drainAll() {
            guard !self.isStopped else { return }
            switch callback {
            case let .partial(text): self.handlePartial(text)
            case let .end(text):
                await self.handleEOU(text)
                return
            }
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
            DebugLogger.shared.warning("Live captions warmup failed (continuing): \(error)", source: "MeetingLive")
        }
        await self.resetRecognizer(reason: .startupWarmup)
        self.diag(String(format: "warmup complete in %.2fs", self.uptime() - started))
    }

    private func markReady() {
        guard !self.isStopped else { return }
        self.isModelReady = true
        self.diag("model ready")
        self.onReady?(self.kind)
    }

    private func markLoadFailed(kind: MeetingAudioTrackKind, error: Error) {
        guard !self.isStopped else { return }
        DebugLogger.shared.warning("Live captions model load failed: \(error)", source: "MeetingLive")
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
            self.comparisonProbe?.recordEvent("recognizer-conversion-failed", track: self.kind, pts: sample.pts.seconds)
            if self.diagnosticsEnabled { self.diagnosticSnapshot.conversionFailures += 1 }
            self.diag("convert FAILED (sr=\(sample.buffer.format.sampleRate) ch=\(sample.buffer.format.channelCount))")
            return
        }
        if let comparisonProbe, comparisonProbe.isRecordingDiagnostics,
           let input = meetingMicrophoneSynthesizeSampleBuffer(from: converted, presentationTime: sample.pts)
        {
            comparisonProbe.offer(input, stage: self.kind == .microphone ? .microphoneRecognizerInput : .browserRecognizerInput)
        }
        self.currentFeedPTS = sample.pts
        if self.firstFeedUptime == nil { self.firstFeedUptime = self.uptime() }
        if self.comparisonProbe?.isRecordingDiagnostics == true || self.diagnosticsEnabled,
           let channel = converted.floatChannelData?[0], converted.frameLength > 0
        {
            let samples = UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
            let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            self.lastInputRMS = sqrt(energy / Double(samples.count))
            self.inputEnergySinceFlow += energy
            self.inputSamplesSinceFlow += samples.count
            self.peakInputRMSSinceFlow = max(self.peakInputRMSSinceFlow, self.lastInputRMS)
        }
        self.lastConsumedPTS = sample.pts + sample.duration
        self.diagSamplesConsumed += 1
        self.diagSecondsConsumed += sample.duration.seconds
        if self.diagnosticsEnabled {
            self.diagnosticSnapshot.convertedBuffers += 1
            self.diagnosticSnapshot.feedSeconds += sample.duration.seconds
        }
        do {
            if self.diagnosticsEnabled { self.diagnosticSnapshot.appendStarts += 1 }
            self.comparisonProbe?.recordEvent("recognizer-append-start", track: self.kind, pts: sample.pts.seconds)
            try await self.manager.appendAudio(converted)
            self.comparisonProbe?.recordEvent("recognizer-append-complete", track: self.kind, pts: sample.pts.seconds)
            if self.diagnosticsEnabled {
                self.diagnosticSnapshot.appendCompletions += 1
                self.diagnosticSnapshot.processStarts += 1
            }
            let processStarted = self.diagnosticsEnabled ? self.uptime() : 0
            self.comparisonProbe?.recordEvent("recognizer-decode-start", track: self.kind, pts: sample.pts.seconds)
            try await self.manager.processBufferedAudio()
            self.modelProcessCompletions += 1
            self.comparisonProbe?.recordEvent("recognizer-decode-complete", track: self.kind, pts: sample.pts.seconds)
            await self.applyRecognizerCallbacks()
            self.logFlowIfDue()
            if self.diagnosticsEnabled {
                self.diagnosticSnapshot.processCompletions += 1
                self.diagnosticSnapshot.maxProcessSeconds = max(
                    self.diagnosticSnapshot.maxProcessSeconds, self.uptime() - processStarted
                )
            }
            await self.rotateLongUtteranceIfNeeded()
        } catch {
            if self.diagnosticsEnabled { self.diagnosticSnapshot.appendOrProcessErrors += 1 }
            self.comparisonProbe?.recordEvent("recognizer-processing-failed", track: self.kind, pts: sample.pts.seconds, detail: error.localizedDescription)
            DebugLogger.shared.warning("Live captions audio processing failed: \(error)", source: "MeetingLive")
            self.onDegraded?(self.kind, "Live captions hit an error and resynced.")
            await self.resetUtterance(reason: .processingError)
        }
    }

    /// A gap in text is not proof the model is stuck. Let the model finish phrases naturally;
    /// recover only after two minutes without a partial, never merely because a phrase is long.
    private func rotateLongUtteranceIfNeeded() async {
        guard let start = self.utteranceStartPTS,
              let end = self.lastConsumedPTS,
              let turnID = self.utteranceTurnID
        else { return }
        let quietSeconds = self.lastPartialUptime.map { self.uptime() - $0 }
        guard (quietSeconds ?? 0) >= Self.partialStallSeconds, !self.lastPartialText.isEmpty else { return }
        self.comparisonProbe?.recordEvent("forced-recognizer-endpoint", track: self.kind, pts: end.seconds, detail: "no partial update for \(Self.partialStallSeconds) seconds")
        var text = self.lastPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.comparisonProbe?.recordEvent("recognizer-flush-start", track: self.kind, pts: end.seconds)
        do {
            let finished = try await self.manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            if !finished.isEmpty { text = finished }
            self.comparisonProbe?.recordEvent("recognizer-flush-complete", track: self.kind, pts: end.seconds, text: text)
        } catch {
            self.comparisonProbe?.recordEvent("recognizer-flush-failed", track: self.kind, detail: error.localizedDescription)
            self.onDegraded?(self.kind, "Live captions could not finish a phrase and resynced.")
        }
        self.utteranceStartPTS = nil
        self.utteranceTurnID = nil
        self.lastPartialText = ""
        self.lastPartialUptime = nil
        await self.resetRecognizer(reason: .noTextTimeout)
        guard !self.isStopped, !text.isEmpty else { return }
        self.lastUtteranceEndPTS = end
        self.diagUtterances += 1
        self.diag(String(
            format: "forced EOU (%@) span=[%.2f–%.2f] chars=%d",
            String(format: "quiet %.1fs", quietSeconds ?? 0),
            start.seconds,
            end.seconds,
            text.count
        ))
        self.onUtterance?(self.kind, turnID, text, start, end)
    }

    /// Once every 5s of wall clock: proves audio is still reaching the recognizer, and how long the
    /// current utterance has been open without an endpoint.
    private func logFlowIfDue() {
        guard self.diagnosticsEnabled || self.comparisonProbe?.isRecordingDiagnostics == true else { return }
        let now = self.uptime()
        guard now - self.diagLastFlowLog >= 5 else { return }
        self.diagLastFlowLog = now
        let textGap = now - (self.lastTextUpdateUptime ?? self.firstFeedUptime ?? now)
        let windowRMS = sqrt(self.inputEnergySinceFlow / Double(max(1, self.inputSamplesSinceFlow)))
        let detail = "feedBuffers=\(self.diagSamplesConsumed) audioSeconds=\(self.diagSecondsConsumed) "
            + "decodeCompletions=\(self.modelProcessCompletions) textGapSeconds=\(textGap) "
            + "partialUpdates=\(self.diagPartials) queueDepth=\(self.queue.count) "
            + "inputRMS=\(self.lastInputRMS) windowRMS=\(windowRMS) peakBufferRMS=\(self.peakInputRMSSinceFlow) "
            + "everProducedText=\(self.lastTextUpdateUptime != nil)"
        self.inputEnergySinceFlow = 0
        self.inputSamplesSinceFlow = 0
        self.peakInputRMSSinceFlow = 0
        self.comparisonProbe?.recordEvent("model-flow", track: self.kind, pts: self.lastConsumedPTS?.seconds, detail: detail)
        if textGap >= Self.pauseObservationSeconds, !self.textPauseReported {
            self.textPauseReported = true
            let producedText = self.lastTextUpdateUptime != nil
            if self.diagnosticsEnabled, producedText { self.diagnosticSnapshot.textPauses += 1 }
            let step = producedText ? "model-text-pause" : "model-waiting-for-first-text"
            self.comparisonProbe?.recordEvent(step, track: self.kind, pts: self.lastConsumedPTS?.seconds, detail: detail)
            self.diag("\(step); not a stuck-model verdict: \(detail)")
        }
        let openFor = self.utteranceStartPTS.map { start in
            (self.lastConsumedPTS ?? start).seconds - start.seconds
        } ?? 0
        let sinceEou = self.diagLastEouUptime.map { now - $0 }
        self.diag(String(
            format: "flow chunks=%d audio=%.1fs openUtterance=%.1fs partials=%d utterances=%d drops=%d sinceEOU=%@",
            self.diagSamplesConsumed,
            self.diagSecondsConsumed,
            openFor,
            self.diagPartials,
            self.diagUtterances,
            self.diagDrops,
            sinceEou.map { String(format: "%.1fs", $0) } ?? "never"
        ))
        if self.diagnosticsEnabled {
            let snapshot = self.diagnosticSnapshot
            // Wrapper counters only: no audio, transcript, names, or identity evidence.
            // Actor-local logging is not an independent hung-executor watchdog.
            // Keep the complete diagnostic output string intact.
            // swiftlint:disable:next line_length
            self.diag("p0 converted=\(snapshot.convertedBuffers) conversionFailures=\(snapshot.conversionFailures) append=\(snapshot.appendCompletions)/\(snapshot.appendStarts) process=\(snapshot.processCompletions)/\(snapshot.processStarts) errors=\(snapshot.appendOrProcessErrors) partialCallbacks=\(snapshot.partialCallbacks) eouCallbacks=\(snapshot.eouCallbacks) resetReturns=\(snapshot.recognizerResetReturned)/\(snapshot.resetInvocations) resetOrdinal=\(snapshot.wrapperGeneration) maxProcessSeconds=\(snapshot.maxProcessSeconds)")
        }
    }

    /// The recognizer only emits tokens once it has decoded speech, so the first partial — not the
    /// first audio buffer — marks where this utterance actually begins. Anchoring on audio instead
    /// swallowed every second of preceding silence into the utterance's span.
    private func handlePartial(_ text: String) {
        guard !self.isStopped else { return }
        let now = self.uptime()
        let firstText = self.lastTextUpdateUptime == nil
        if self.textPauseReported || firstText {
            let gap = now - (self.lastTextUpdateUptime ?? self.firstFeedUptime ?? now)
            let step = firstText ? "model-first-text" : "model-text-resumed"
            self.comparisonProbe?.recordEvent(step, track: self.kind, pts: self.currentFeedPTS?.seconds, detail: "textGapSeconds=\(gap) decodeCompletions=\(self.modelProcessCompletions)")
            self.diag("\(step) after \(gap)s; decodeCompletions=\(self.modelProcessCompletions)")
            if self.diagnosticsEnabled, !firstText { self.diagnosticSnapshot.textResumptions += 1 }
        }
        self.textPauseReported = false
        self.lastTextUpdateUptime = now
        if self.diagnosticsEnabled {
            self.diagnosticSnapshot.partialCallbacks += 1
            if self.diagnosticSnapshot.firstPartialAfterResetSeconds == nil,
               let reset = self.diagnosticResetUptime
            {
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
            self.diag("partial #\(self.diagPartials) chars=\(text.count)")
        }
        self.onPartial?(self.kind, turnID, text, start, end)
    }

    private func handleEOU(_ text: String) async {
        guard !self.isStopped else { return }
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
        await self.resetRecognizer(reason: .modelEndOfUtterance)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.isStopped, !trimmed.isEmpty else { return }
        guard let start, let end, let turnID else {
            self.diag("EOU fired but no start PTS — dropped (chars=\(text.count))")
            return
        }
        self.lastUtteranceEndPTS = end
        self.diagUtterances += 1
        self.diag(String(
            format: "EOU #%d span=[%.2f–%.2f] (%.1fs) sinceLastEOU=%@ chars=%d",
            self.diagUtterances,
            start.seconds,
            end.seconds,
            end.seconds - start.seconds,
            gap.map { String(format: "%.1fs", $0) } ?? "first",
            trimmed.count
        ))
        self.onUtterance?(self.kind, turnID, trimmed, start, end)
    }

    /// A saturated queue sheds many samples in a burst. Recording one pending resync instead of
    /// resetting per sample keeps a 250-sample burst from issuing 250 decoder resets and 250
    /// degraded notifications; the drain loop performs exactly one resync before it next consumes.
    private func noteDrop() {
        self.comparisonProbe?.recordEvent("recognizer-queue-dropped-buffer", track: self.kind)
        self.diagDrops += 1
        self.pendingResync = true
    }

    private func applyPendingResyncIfNeeded() async {
        guard self.pendingResync else { return }
        self.pendingResync = false
        self.diag("queue saturated — resyncing after \(self.diagDrops) dropped samples")
        await self.resetUtterance(reason: .audioQueueOverflow)
        self.onDegraded?(self.kind, "Live captions dropped audio and resynced.")
    }

    private func resetUtterance(reason: ResetReason) async {
        self.utteranceStartPTS = nil
        self.utteranceTurnID = nil
        self.lastPartialText = ""
        self.lastPartialUptime = nil
        self.lastConsumedPTS = nil
        await self.resetRecognizer(reason: reason)
    }

    private func resetRecognizer(reason: ResetReason) async {
        self.comparisonProbe?.recordEvent("recognizer-reset", track: self.kind, detail: reason.rawValue)
        self.diag("reset reason=\(reason.rawValue)")
        if self.diagnosticsEnabled {
            self.diagnosticSnapshot.resetInvocations += 1
            self.diagnosticSnapshot.lastResetReason = reason.rawValue
            self.diagnosticSnapshot.wrapperGeneration += 1
            self.diagnosticSnapshot.firstPartialAfterResetSeconds = nil
            self.diagnosticResetUptime = nil
        }
        await self.manager.reset()
        _ = self.recognizerCallbacks.drainAll()
        if self.diagnosticsEnabled {
            self.diagnosticSnapshot.recognizerResetReturned += 1
            self.diagnosticResetUptime = self.uptime()
        }
    }

    #if DEBUG
    /// Deterministic P0 seam: bypasses capture/model loading, but exercises production conversion,
    /// append/process and existing rotation policy. It deliberately does not add recovery policy.
    func diagnosticConsume(_ sample: MeetingLiveSampleCopy.Sample) async { await self.consume(sample) }
    func diagnosticInstallCallbacks() async { await self.installCallbacks() }
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
