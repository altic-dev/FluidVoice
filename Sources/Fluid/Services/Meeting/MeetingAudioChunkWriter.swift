import AudioToolbox
@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

final nonisolated class MeetingAudioChunkWriter: @unchecked Sendable {
    typealias EventHandler = @Sendable (MeetingCaptureEvent) -> Void

    private final class SampleBox: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer
        let producerEpoch: UInt64

        init(_ sampleBuffer: CMSampleBuffer, producerEpoch: UInt64) {
            self.sampleBuffer = sampleBuffer
            self.producerEpoch = producerEpoch
        }
    }

    private enum Lifecycle: Equatable {
        case accepting
        case stopping
        case stopped
    }

    enum SequencedCommandError: Error {
        case writerNotAccepting
        case queueFull
    }

    private struct ActiveChunk: @unchecked Sendable {
        var id: MeetingAudioChunkID
        var sequence: Int
        var relativeFinalPath: String
        var sink: MeetingAudioChunkSink
        var start: CMTime
        var end: CMTime
        var discontinuities: [MeetingAudioDiscontinuity]
        /// Captured at `beginChunk` — `self.track.format` may already be the NEXT chunk's by finalize.
        var format: MeetingAudioFormat
        var sourceFormatDescription: CMFormatDescription
        var formatContract: MeetingPCMFormatContract
        var producerEpoch: UInt64
        var framesWritten: Int64
        var lastCheckpointFrames: Int64
    }

    private enum FinalizationResult: @unchecked Sendable {
        case finalized(MeetingAudioChunk, MeetingAudioFormat)
        case failed(MeetingAudioChunk, String)
    }

    private let queue: DispatchQueue
    private let finalizationQueue: DispatchQueue
    private let finalizationGroup = DispatchGroup()
    private let finalizationSlots = DispatchSemaphore(value: 2)
    private let pendingSlots: DispatchSemaphore
    private let stateLock = NSLock()
    private let sessionDirectory: URL
    private let trackDirectory: URL
    private let manifestURL: URL
    private let chunkDuration: TimeInterval
    private let eventHandler: EventHandler
    private let encoder: JSONEncoder
    private let ledger: MeetingAudioChunkLedgerStore

    let trackID: MeetingAudioTrackID

    private var track: MeetingAudioTrack
    private var activeChunk: ActiveChunk?
    /// Set synchronously when a chunk closes, since `track.chunks.last` can be stale (finalization is async).
    private var lastFinalizedEnd: CMTime?
    /// Monotonically identifies the producer that owns callback order. Samples from retired
    /// producers are rejected instead of being retimed as duplicate audio.
    private var currentProducerEpoch: UInt64?
    /// Canonical mapping from the current producer's own clock onto the meeting timeline. A new
    /// epoch (or a backward reset inside one) establishes this offset exactly once; every later
    /// sample of that epoch is then shifted by the same delta, so a producer that restarts at zero
    /// stays internally contiguous instead of being clamped sample-by-sample onto one instant.
    private var canonicalTimelineOffset: CMTime = .zero
    /// The epoch `canonicalTimelineOffset` was established for. Purely diagnostic bookkeeping that
    /// makes the "offset belongs to one producer epoch" invariant explicit.
    private var canonicalTimelineOffsetEpoch: UInt64?
    private var lifecycle: Lifecycle = .accepting
    private var stopWaiters: [CheckedContinuation<MeetingAudioTrack, Never>] = []
    private var stoppedTrack: MeetingAudioTrack?
    private var nextChunkSequence = 0
    private var pendingDroppedSampleCount = 0
    private var dropReportScheduled = false
    /// At most one bounded overflow command may bypass `pendingSlots`, solely to publish a
    /// conservative in-memory safety era before a terminal stop.
    private var emergencySafetyCommandPending = false
    private var lastHealthEmission = Date.distantPast
    private var lastLevelMeasurement = Date.distantPast
    private var silenceAccumulatedSeconds: Double = 0

    /// Peak amplitude (0...1) below which a buffer counts as silent for watchdog purposes.
    private static let silenceAmplitudeThreshold: Float = 0.0001

    init(
        track: MeetingAudioTrack,
        sessionDirectory: URL,
        chunkDuration: TimeInterval,
        eventHandler: @escaping EventHandler,
        // PCM persistence is intentionally synchronous on the serialized writer queue. Keep the
        // queue bounded, but allow roughly 1.3 seconds of capture jitter at a 48 kHz/10 ms tap
        // cadence while the filesystem drains a burst.
        pendingSlotLimit: Int = 128
    ) throws {
        self.trackID = track.id
        self.track = track
        self.sessionDirectory = sessionDirectory
        self.trackDirectory = sessionDirectory
            .appendingPathComponent("tracks", isDirectory: true)
            .appendingPathComponent(track.kind.rawValue, isDirectory: true)
        self.manifestURL = self.trackDirectory.appendingPathComponent("track.json")
        self.chunkDuration = max(60, chunkDuration)
        self.eventHandler = eventHandler
        self.ledger = MeetingAudioChunkLedgerStore(sessionDirectory: sessionDirectory)
        self.queue = DispatchQueue(
            label: "com.fluidvoice.meeting.writer.\(track.kind.rawValue)",
            qos: .userInitiated
        )
        self.finalizationQueue = DispatchQueue(
            label: "com.fluidvoice.meeting.writer.\(track.kind.rawValue).pcm-finalization",
            qos: .utility
        )
        self.pendingSlots = DispatchSemaphore(value: max(0, pendingSlotLimit))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        try FileManager.default.createDirectory(
            at: self.trackDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try self.persistTrackManifest()
    }

    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer, producerEpoch: UInt64 = 0) -> Bool {
        self.stateLock.lock()
        guard self.lifecycle == .accepting else {
            self.stateLock.unlock()
            return false
        }

        guard self.pendingSlots.wait(timeout: .now()) == .success else {
            self.pendingDroppedSampleCount += 1
            let shouldScheduleReport = !self.dropReportScheduled
            self.dropReportScheduled = true
            self.stateLock.unlock()
            if shouldScheduleReport {
                self.queue.async { [weak self] in
                    self?.drainDroppedSampleReport()
                }
            }
            return false
        }

        let sampleBox = SampleBox(sampleBuffer, producerEpoch: producerEpoch)
        self.queue.async { [weak self, sampleBox] in
            defer { self?.pendingSlots.signal() }
            self?.consume(sampleBox.sampleBuffer, producerEpoch: sampleBox.producerEpoch)
        }
        self.stateLock.unlock()
        return true
    }

    /// Runs a safety-era mutation, durable manifest write, and sample consume as one writer-queue
    /// command. Callers may open live admission only from the success completion. On a fail-closed
    /// persistence error the conservative candidate remains the in-memory track and the sample is
    /// not consumed.
    func enqueue(
        _ sampleBuffer: CMSampleBuffer,
        producerEpoch: UInt64 = 0,
        afterPersistingMetadata mutate: @escaping @Sendable (inout MeetingAudioTrack) -> Void,
        failClosed: Bool,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.stateLock.lock()
        guard self.lifecycle == .accepting else {
            self.stateLock.unlock()
            completion(.failure(SequencedCommandError.writerNotAccepting))
            return
        }
        guard self.pendingSlots.wait(timeout: .now()) == .success else {
            self.failOverflowedSequencedCommand(failClosed: failClosed, mutate: mutate, completion: completion)
            return
        }

        let sampleBox = SampleBox(sampleBuffer, producerEpoch: producerEpoch)
        self.queue.async { [self, sampleBox] in
            defer { self.pendingSlots.signal() }
            var candidate = self.track
            mutate(&candidate)
            do {
                try self.persistTrackManifest(candidate)
                self.track = candidate
                self.consume(sampleBox.sampleBuffer, producerEpoch: sampleBox.producerEpoch)
                completion(.success(()))
            } catch {
                if failClosed { self.track = candidate }
                completion(.failure(error))
            }
        }
        self.stateLock.unlock()
    }

    /// Enqueues a durable metadata-only command in the same bounded order as audio samples.
    /// This is used for safety transitions that must cut the writer timeline before a later
    /// callback is allowed to enqueue raw microphone audio.
    func enqueueMetadata(
        failClosed: Bool,
        mutate: @escaping @Sendable (inout MeetingAudioTrack) -> Void,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.stateLock.lock()
        guard self.lifecycle == .accepting else {
            self.stateLock.unlock()
            completion(.failure(SequencedCommandError.writerNotAccepting))
            return
        }
        guard self.pendingSlots.wait(timeout: .now()) == .success else {
            self.failOverflowedSequencedCommand(failClosed: failClosed, mutate: mutate, completion: completion)
            return
        }

        self.queue.async { [self] in
            defer { self.pendingSlots.signal() }
            var candidate = self.track
            mutate(&candidate)
            do {
                try self.persistTrackManifest(candidate)
                self.track = candidate
                completion(.success(()))
            } catch {
                if failClosed { self.track = candidate }
                completion(.failure(error))
            }
        }
        self.stateLock.unlock()
    }

    /// Full-queue path for sequenced commands. Must be called with `stateLock` held; returns with
    /// it released. A fail-closed command gets one bounded slot-bypassing emergency run so the
    /// conservative era still reaches the in-memory track (and best-effort the manifest).
    private func failOverflowedSequencedCommand(
        failClosed: Bool,
        mutate: @escaping @Sendable (inout MeetingAudioTrack) -> Void,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.pendingDroppedSampleCount += 1
        let shouldScheduleReport = !self.dropReportScheduled
        self.dropReportScheduled = true
        let enqueueEmergency = failClosed && !self.emergencySafetyCommandPending
        if enqueueEmergency { self.emergencySafetyCommandPending = true }
        self.stateLock.unlock()
        if shouldScheduleReport {
            self.queue.async { [weak self] in self?.drainDroppedSampleReport() }
        }
        if enqueueEmergency {
            self.queue.async { [self] in
                var candidate = self.track
                mutate(&candidate)
                self.track = candidate
                try? self.persistTrackManifest(candidate)
                self.stateLock.withLock { self.emergencySafetyCommandPending = false }
                completion(.failure(SequencedCommandError.queueFull))
            }
        } else {
            completion(.failure(SequencedCommandError.queueFull))
        }
    }

    func stop() async -> MeetingAudioTrack {
        await withCheckedContinuation { continuation in
            self.stateLock.lock()
            switch self.lifecycle {
            case .accepting:
                self.lifecycle = .stopping
                self.stopWaiters.append(continuation)
                self.queue.async { [self] in
                    self.scheduleActiveChunkFinalization()
                    self.finalizationGroup.notify(queue: self.queue) { [self] in
                        self.completeStop()
                    }
                }
                self.stateLock.unlock()
            case .stopping:
                self.stopWaiters.append(continuation)
                self.stateLock.unlock()
            case .stopped:
                let stoppedTrack = self.stoppedTrack ?? self.track
                self.stateLock.unlock()
                continuation.resume(returning: stoppedTrack)
            }
        }
    }

    /// Unlike the `try?` writes elsewhere here, a persist failure propagates to the caller.
    /// Transactional: mutates a copy, persists it, publishes to `self.track` only on success.
    func updateTrackMetadata(_ mutate: @escaping (inout MeetingAudioTrack) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async { [self] in
                var candidate = self.track
                mutate(&candidate)
                do {
                    try self.persistTrackManifest(candidate)
                    self.track = candidate
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Safety metadata must fail closed even when its manifest write fails. Publishing the
    /// conservative candidate in memory ensures the track returned by `stop()` cannot resurrect
    /// the prior optimistic era; the caller must still terminate capture after the thrown error.
    func updateTrackMetadataFailClosed(_ mutate: @escaping (inout MeetingAudioTrack) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async { [self] in
                var candidate = self.track
                mutate(&candidate)
                do {
                    try self.persistTrackManifest(candidate)
                    self.track = candidate
                    continuation.resume()
                } catch {
                    self.track = candidate
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Splice point for a capture-side swap: finalizes the active chunk, returns its `presentationEnd`. No-op unless `.accepting`.
    func beginSplice() async -> MeetingMediaTime? {
        await withCheckedContinuation { (continuation: CheckedContinuation<MeetingMediaTime?, Never>) in
            self.queue.async { [self] in
                self.stateLock.lock()
                let accepting = self.lifecycle == .accepting
                self.stateLock.unlock()
                guard accepting else {
                    continuation.resume(returning: self.track.chunks.last?.presentationEnd)
                    return
                }
                guard let activeChunk = self.activeChunk else {
                    continuation.resume(returning: self.track.chunks.last?.presentationEnd)
                    return
                }
                let boundary = Self.mediaTime(activeChunk.end)
                self.scheduleActiveChunkFinalization()
                self.finalizationGroup.notify(queue: self.queue) {
                    continuation.resume(returning: boundary)
                }
            }
        }
    }

    func snapshot() async -> MeetingAudioTrack {
        await withCheckedContinuation { continuation in
            self.queue.async { [self] in
                continuation.resume(returning: self.track)
            }
        }
    }

    private func consume(_ sourceSampleBuffer: CMSampleBuffer, producerEpoch: UInt64) {
        guard CMSampleBufferIsValid(sourceSampleBuffer), CMSampleBufferDataIsReady(sourceSampleBuffer) else {
            self.recordDroppedSample(detail: "Capture delivered an invalid audio sample.")
            return
        }
        let sourcePresentationTime = CMSampleBufferGetPresentationTimeStamp(sourceSampleBuffer)
        guard sourcePresentationTime.isValid, sourcePresentationTime.isNumeric else {
            self.recordDroppedSample(detail: "Capture delivered audio without a valid presentation timestamp.")
            return
        }

        if let currentProducerEpoch = self.currentProducerEpoch, producerEpoch < currentProducerEpoch {
            self.recordDroppedSample(detail: "Capture delivered audio from a retired producer epoch.")
            return
        }

        let duration = Self.sampleDuration(sourceSampleBuffer)
        let previousEnd = self.activeChunk?.end ?? self.lastFinalizedEnd
        let epochChanged = self.currentProducerEpoch.map { producerEpoch > $0 } ?? false
        self.currentProducerEpoch = max(self.currentProducerEpoch ?? producerEpoch, producerEpoch)

        // A new producer brings its own clock origin; its canonical mapping is derived below from
        // the first sample it delivers rather than inherited from the retired producer.
        if epochChanged {
            self.canonicalTimelineOffset = .zero
            self.canonicalTimelineOffsetEpoch = nil
        }

        var presentationTime = sourcePresentationTime + self.canonicalTimelineOffset
        var backwardReset = false
        if let previousEnd, presentationTime < previousEnd {
            // Establish (or re-establish) the mapping once, then keep applying it. Anchoring the
            // offset instead of clamping each sample preserves the producer's internal spacing.
            self.canonicalTimelineOffset = previousEnd - sourcePresentationTime
            self.canonicalTimelineOffsetEpoch = producerEpoch
            presentationTime = previousEnd
            backwardReset = true
        } else if self.canonicalTimelineOffsetEpoch == nil {
            self.canonicalTimelineOffsetEpoch = producerEpoch
        }

        var boundaryDiscontinuity: MeetingAudioDiscontinuity?
        if previousEnd != nil, epochChanged || backwardReset {
            boundaryDiscontinuity = MeetingAudioDiscontinuity(
                kind: .clockDiscontinuity,
                presentationTime: Self.mediaTime(sourcePresentationTime),
                gapSeconds: nil,
                detail: epochChanged
                    ? "Capture producer epoch changed."
                    : "Presentation timestamp moved backwards."
            )
        }

        let sampleBuffer: CMSampleBuffer
        if presentationTime != sourcePresentationTime {
            guard let retimed = Self.retimedCopy(sourceSampleBuffer, presentationTime: presentationTime) else {
                self.recordDroppedSample(detail: "Capture audio could not be normalized onto the meeting timeline.")
                return
            }
            sampleBuffer = retimed
        } else {
            sampleBuffer = sourceSampleBuffer
        }

        if let activeChunk = self.activeChunk {
            let elapsed = CMTimeGetSeconds(presentationTime - activeChunk.start)
            let gap = CMTimeGetSeconds(presentationTime - activeChunk.end)
            // Compared on the canonical timeline: once the epoch's offset is established, later
            // samples are contiguous here even though their raw stamps are far behind `end`.
            let clockBoundary = epochChanged || backwardReset
            if elapsed >= self.chunkDuration || clockBoundary || gap > 0.5 {
                if clockBoundary || gap > 0.5 {
                    self.silenceAccumulatedSeconds = 0
                    self.activeChunk?.discontinuities.append(boundaryDiscontinuity ?? MeetingAudioDiscontinuity(
                        kind: .sourceLost,
                        presentationTime: Self.mediaTime(sourcePresentationTime),
                        gapSeconds: gap,
                        detail: "Unexpected audio gap."
                    ))
                    boundaryDiscontinuity = nil
                }
                self.scheduleActiveChunkFinalization()
            }
        }

        do {
            if self.activeChunk == nil {
                try self.beginChunk(
                    with: sampleBuffer,
                    at: presentationTime,
                    producerEpoch: producerEpoch,
                    discontinuities: boundaryDiscontinuity.map { [$0] } ?? []
                )
            } else if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let incomingContract = try? MeetingPCMFormatContract(formatDescription: formatDescription),
                      incomingContract != self.activeChunk?.formatContract
            {
                self.scheduleActiveChunkFinalization()
                try self.beginChunk(
                    with: sampleBuffer,
                    at: presentationTime,
                    producerEpoch: producerEpoch,
                    discontinuities: [],
                    contract: incomingContract
                )
            }
            guard var activeChunk = self.activeChunk else { return }
            let receipt = try activeChunk.sink.append(sampleBuffer)
            guard receipt.framesAccepted == receipt.framesWritten,
                  receipt.framesAccepted == Int64(CMSampleBufferGetNumSamples(sampleBuffer)) else {
                throw MeetingCaptureError.writerFailed("PCM sink reported a short write.")
            }

            activeChunk.end = presentationTime + duration
            activeChunk.framesWritten += receipt.framesWritten
            if activeChunk.framesWritten - activeChunk.lastCheckpointFrames >= Int64((activeChunk.format.sampleRate).rounded()) {
                try self.writeCheckpoint(for: &activeChunk)
            }
            self.activeChunk = activeChunk
            self.track.health.status = .healthy
            self.track.health.lastPresentationTime = Self.mediaTime(presentationTime)
            let now = Date()
            self.track.health.lastSampleAt = now

            let peak = Self.peakAmplitude(sampleBuffer)
            if let peak {
                self.silenceAccumulatedSeconds = peak < Self.silenceAmplitudeThreshold
                    ? self.silenceAccumulatedSeconds + max(0, CMTimeGetSeconds(duration))
                    : 0
            }
            self.track.health.silentForSeconds = self.silenceAccumulatedSeconds

            if now.timeIntervalSince(self.lastLevelMeasurement) >= 0.1 {
                self.lastLevelMeasurement = now
                self.track.health.level = Self.normalizedLevel(fromPeak: peak ?? 0)
            }
            self.track.health.detail = nil
            self.emitHealthIfNeeded()
        } catch {
            // A sink failure poisons the current container. Retire it immediately so the next
            // callback can establish a fresh chunk instead of retrying the same invalid sink and
            // emitting an error storm for every subsequent buffer.
            var retiredChunk = false
            if let failedChunk = self.activeChunk {
                retiredChunk = true
                self.activeChunk = nil
                self.lastFinalizedEnd = failedChunk.end
                failedChunk.sink.cancel()
                self.applyFinalization(.failed(
                    Self.failedChunk(from: failedChunk),
                    "PCM chunk write failed: \(error.localizedDescription)"
                ))
            }
            if !retiredChunk {
                self.track.health.status = .degraded
                self.track.health.detail = error.localizedDescription
                self.eventHandler(.interrupted(
                    kind: .writerFailure,
                    trackID: self.track.id,
                    detail: error.localizedDescription
                ))
            }
        }
    }

    private func beginChunk(
        with sampleBuffer: CMSampleBuffer,
        at start: CMTime,
        producerEpoch: UInt64,
        discontinuities: [MeetingAudioDiscontinuity],
        contract: MeetingPCMFormatContract? = nil
    ) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0
        else {
            throw MeetingCaptureError.unsupportedAudioFormat
        }

        let formatContract = try contract ?? MeetingPCMFormatContract(formatDescription: formatDescription)

        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              asbd.mFramesPerPacket == 1
        else { throw MeetingCaptureError.unsupportedAudioFormat }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let sequence = self.nextChunkSequence
        self.nextChunkSequence += 1
        let stem = String(format: "%06d", sequence)
        let format = MeetingAudioFormat(
            codec: "lpcm-f32",
            sampleRate: asbd.mSampleRate,
            channelCount: channelCount,
            bitRate: nil
        )
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: self.sessionDirectory)
        let relativePath = "tracks/\(self.track.kind.rawValue)/\(stem).caf"
        let clientFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        try sink.begin(relativeFilePath: relativePath, format: clientFormat, contract: formatContract)
        let id = UUID()
        do {
            try self.ledger.writeIntent(MeetingAudioChunkLedgerIntent(
                chunkID: id,
                sequence: sequence,
                canonicalStart: Self.mediaTime(start),
                producerEpoch: producerEpoch,
                sourceFormat: format,
                partialRelativeFilePath: sink.partialRelativeFilePath ?? relativePath,
                createdAt: Date()
            ))
        } catch {
            sink.cancel()
            throw error
        }
        self.track.format = format
        self.activeChunk = ActiveChunk(
            id: id,
            sequence: sequence,
            relativeFinalPath: relativePath,
            sink: sink,
            start: start,
            end: start,
            discontinuities: discontinuities,
            format: format,
            sourceFormatDescription: formatDescription,
            formatContract: formatContract,
            producerEpoch: producerEpoch,
            framesWritten: 0,
            lastCheckpointFrames: 0
        )
    }

    private func scheduleActiveChunkFinalization() {
        guard var activeChunk = self.activeChunk else { return }
        self.activeChunk = nil
        self.lastFinalizedEnd = activeChunk.end
        do {
            try self.writeCheckpoint(for: &activeChunk)
        } catch {
            activeChunk.sink.cancel()
            self.applyFinalization(.failed(
                Self.failedChunk(from: activeChunk),
                "PCM chunk checkpoint failed: \(error.localizedDescription)"
            ))
            return
        }

        guard self.finalizationSlots.wait(timeout: .now()) == .success else {
            activeChunk.sink.cancel()
            self.applyFinalization(.failed(
                Self.failedChunk(from: activeChunk),
                "Audio chunk finalization was saturated; the chunk was closed without blocking capture."
            ))
            return
        }

        self.finalizationGroup.enter()
        // The active chunk has been removed from the writer queue, so ownership of this sink can
        // transfer to the finalization queue with no concurrent append/cancel calls. Reopen, hash
        // and fsync are intentionally off the capture queue: a 60-second Float32 CAF is large
        // enough to overflow the bounded producer queue if finalization blocks it.
        self.finalizationQueue.async { [self, activeChunk] in
            let result = Self.finalize(activeChunk)
            self.queue.async { [self] in
                self.applyFinalization(result)
                self.finalizationSlots.signal()
                self.finalizationGroup.leave()
            }
        }
    }

    private func applyFinalization(_ result: FinalizationResult) {
        switch result {
        case let .finalized(chunk, format):
            self.track.chunks.append(chunk)
            do {
                try self.ledger.writeTerminal(MeetingAudioChunkLedgerTerminal(
                    chunkID: chunk.id,
                    status: .ready,
                    updatedAt: Date(),
                    detail: nil
                ), for: chunk.id)
            } catch {
                // A PCM file that finalized without a durable ready terminal is not publishable.
                // Keep the chunk fail-closed and surface the ledger failure to the capture owner.
                try? FileManager.default.removeItem(at: self.sessionDirectory.appendingPathComponent(chunk.relativeFilePath))
                if let index = self.track.chunks.firstIndex(where: { $0.id == chunk.id }) {
                    self.track.chunks[index].finalizationState = .failed
                    self.track.chunks[index].captureAnalysisAsset?.presence = .failed
                }
                self.track.health.status = .degraded
                self.track.health.detail = "PCM chunk ledger terminal failed: \(error.localizedDescription)"
                self.eventHandler(.interrupted(kind: .writerFailure, trackID: self.track.id, detail: self.track.health.detail ?? "PCM chunk ledger terminal failed."))
                try? self.persistTrackManifest()
                return
            }
            try? self.persistTrackManifest()
            self.eventHandler(.chunkFinalized(trackID: self.track.id, chunk: chunk, format: format))
        case let .failed(chunk, detail):
            self.track.chunks.append(chunk)
            try? self.ledger.writeTerminal(MeetingAudioChunkLedgerTerminal(
                chunkID: chunk.id,
                status: .failed,
                updatedAt: Date(),
                detail: detail
            ), for: chunk.id)
            self.track.health.status = .degraded
            self.track.health.detail = detail
            try? self.persistTrackManifest()
            self.eventHandler(.interrupted(kind: .writerFailure, trackID: self.track.id, detail: detail))
        }
    }

    private func completeStop() {
        self.track.chunks.sort { $0.sequence < $1.sequence }
        self.track.health.status = self.track.chunks.contains(where: { $0.finalizationState == .finalized })
            ? .stopped
            : .unavailable
        if self.track.health.status == .stopped {
            self.track.health.detail = nil
        }
        try? self.persistTrackManifest()

        self.stateLock.lock()
        self.lifecycle = .stopped
        self.stoppedTrack = self.track
        let waiters = self.stopWaiters
        self.stopWaiters = []
        self.stateLock.unlock()
        waiters.forEach { $0.resume(returning: self.track) }
    }

    private nonisolated static func finalize(_ activeChunk: ActiveChunk) -> FinalizationResult {
        guard activeChunk.end >= activeChunk.start else {
            return .failed(
                self.failedChunk(from: activeChunk),
                "Audio chunk timing was not monotonic."
            )
        }
        switch activeChunk.sink.finalize() {
        case let .success(finalization):
            let asset = MeetingAudioAsset(
                role: .captureAnalysis,
                encoding: .linearPCMFloat32CAFV1,
                presence: .ready,
                relativeFilePath: finalization.relativeFilePath,
                byteCount: finalization.byteCount,
                sha256: finalization.sha256,
                sampleRate: finalization.sampleRate,
                channelCount: finalization.channelCount,
                frameCount: finalization.frameCount
            )
            return .finalized(MeetingAudioChunk(
                id: activeChunk.id,
                sequence: activeChunk.sequence,
                relativeFilePath: finalization.relativeFilePath,
                presentationStart: self.mediaTime(activeChunk.start),
                presentationEnd: self.mediaTime(activeChunk.end),
                discontinuities: activeChunk.discontinuities,
                sha256: finalization.sha256,
                byteCount: finalization.byteCount,
                finalizationState: .finalized,
                audioSchemaVersion: 2,
                captureAnalysisAsset: asset,
                playbackArchiveAsset: nil
            ), activeChunk.format)
        case let .failure(error):
            return .failed(self.failedChunk(from: activeChunk), "PCM chunk finalization failed: \(error)")
        }
    }

    private nonisolated static func failedChunk(from activeChunk: ActiveChunk) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: activeChunk.id,
            sequence: activeChunk.sequence,
            relativeFilePath: activeChunk.relativeFinalPath,
            presentationStart: self.mediaTime(activeChunk.start),
            presentationEnd: self.mediaTime(max(activeChunk.end, activeChunk.start)),
            discontinuities: activeChunk.discontinuities,
            sha256: "",
            byteCount: 0,
            finalizationState: .failed,
            audioSchemaVersion: 2,
            captureAnalysisAsset: MeetingAudioAsset(
                role: .captureAnalysis,
                encoding: .linearPCMFloat32CAFV1,
                presence: .failed,
                relativeFilePath: activeChunk.relativeFinalPath,
                byteCount: 0
            ),
            playbackArchiveAsset: nil
        )
    }

    private func writeCheckpoint(for activeChunk: inout ActiveChunk) throws {
        guard activeChunk.framesWritten > 0 else { return }
        try self.ledger.writeCheckpoint(MeetingAudioChunkLedgerCheckpoint(
            chunkID: activeChunk.id,
            expectedFrames: activeChunk.framesWritten,
            writtenFrames: activeChunk.framesWritten,
            lastCanonicalPTS: Self.mediaTime(activeChunk.end),
            updatedAt: Date()
        ), for: activeChunk.id)
        activeChunk.lastCheckpointFrames = activeChunk.framesWritten
    }

    private func recordDroppedSample(detail: String) {
        self.track.health.status = .degraded
        self.track.health.droppedSampleCount += 1
        self.track.health.detail = detail
        self.eventHandler(.interrupted(kind: .writerBackpressure, trackID: self.track.id, detail: detail))
        self.emitHealthIfNeeded(force: true)
    }

    private func drainDroppedSampleReport() {
        self.stateLock.lock()
        let droppedCount = self.pendingDroppedSampleCount
        self.pendingDroppedSampleCount = 0
        self.dropReportScheduled = false
        self.stateLock.unlock()
        guard droppedCount > 0 else { return }
        self.track.health.status = .degraded
        self.track.health.droppedSampleCount += droppedCount
        let detail = "Audio writer queue dropped \(droppedCount) samples while saturated."
        self.track.health.detail = detail
        self.eventHandler(.interrupted(kind: .writerBackpressure, trackID: self.track.id, detail: detail))
        self.emitHealthIfNeeded(force: true)
    }

    private func emitHealthIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(self.lastHealthEmission) >= 0.25 else { return }
        self.lastHealthEmission = now
        self.eventHandler(.trackHealth(trackID: self.track.id, health: self.track.health))
    }

    private func persistTrackManifest(_ track: MeetingAudioTrack? = nil) throws {
        let data = try self.encoder.encode(track ?? self.track)
        try data.write(to: self.manifestURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: self.manifestURL.path
        )
    }

    private static func mediaTime(_ time: CMTime) -> MeetingMediaTime {
        MeetingMediaTime(value: time.value, timescale: time.timescale)
    }

    private static func sampleDuration(_ sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.isNumeric, duration > .zero {
            return duration
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mSampleRate > 0
        else { return CMTime(value: 1, timescale: 48_000) }
        return CMTime(
            value: CMTimeValue(CMSampleBufferGetNumSamples(sampleBuffer)),
            timescale: CMTimeScale(asbd.mSampleRate.rounded())
        )
    }

    /// Retimes every timing entry by one delta so PCM duration/order are preserved while writer
    /// metadata and encoded timestamps share the same monotonic meeting timeline.
    private static func retimedCopy(
        _ sampleBuffer: CMSampleBuffer,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        var timingCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        ) == noErr, timingCount > 0 else { return nil }

        var timings = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingCount
        )
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: timingCount,
            arrayToFill: &timings,
            entriesNeededOut: &timingCount
        ) == noErr else { return nil }

        let original = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let delta = presentationTime - original
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + delta
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + delta
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingCount,
            sampleTimingArray: &timings,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedLevel(fromPeak peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10f(min(1, peak))
        return max(0, min(1, (decibels + 60) / 60))
    }

    private static func peakAmplitude(_ sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else { return nil }

        var requiredSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, requiredSize > 0 else { return nil }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }
        let audioBufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }

        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let stride = max(1, sampleCount / 512)
            var index = 0
            while index < sampleCount {
                peak = max(peak, abs(samples[index]))
                index += stride
            }
        }
        return peak
    }
}
