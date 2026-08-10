import AudioToolbox
@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

final nonisolated class MeetingAudioChunkWriter: @unchecked Sendable {
    typealias EventHandler = @Sendable (MeetingCaptureEvent) -> Void

    private final class SampleBox: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer

        init(_ sampleBuffer: CMSampleBuffer) {
            self.sampleBuffer = sampleBuffer
        }
    }

    private enum Lifecycle: Equatable {
        case accepting
        case stopping
        case stopped
    }

    private struct ActiveChunk: @unchecked Sendable {
        var sequence: Int
        var partialURL: URL
        var finalURL: URL
        var relativeFinalPath: String
        var writer: AVAssetWriter
        var input: AVAssetWriterInput
        var start: CMTime
        var end: CMTime
        var discontinuities: [MeetingAudioDiscontinuity]
    }

    private enum FinalizationResult: @unchecked Sendable {
        case finalized(MeetingAudioChunk)
        case failed(MeetingAudioChunk, String)
    }

    private let queue: DispatchQueue
    private let finalizationQueue: DispatchQueue
    private let finalizationGroup = DispatchGroup()
    private let finalizationSlots = DispatchSemaphore(value: 2)
    private let pendingSlots = DispatchSemaphore(value: 24)
    private let stateLock = NSLock()
    private let sessionDirectory: URL
    private let trackDirectory: URL
    private let manifestURL: URL
    private let chunkDuration: TimeInterval
    private let eventHandler: EventHandler
    private let encoder: JSONEncoder

    private var track: MeetingAudioTrack
    private var activeChunk: ActiveChunk?
    private var lifecycle: Lifecycle = .accepting
    private var stopWaiters: [CheckedContinuation<MeetingAudioTrack, Never>] = []
    private var stoppedTrack: MeetingAudioTrack?
    private var nextChunkSequence = 0
    private var pendingDroppedSampleCount = 0
    private var dropReportScheduled = false
    private var lastHealthEmission = Date.distantPast
    private var lastLevelMeasurement = Date.distantPast
    private var silenceAccumulatedSeconds: Double = 0

    /// Peak amplitude (0...1) below which a buffer counts as silent for watchdog purposes.
    private static let silenceAmplitudeThreshold: Float = 0.0001

    init(
        track: MeetingAudioTrack,
        sessionDirectory: URL,
        chunkDuration: TimeInterval,
        eventHandler: @escaping EventHandler
    ) throws {
        self.track = track
        self.sessionDirectory = sessionDirectory
        self.trackDirectory = sessionDirectory
            .appendingPathComponent("tracks", isDirectory: true)
            .appendingPathComponent(track.kind.rawValue, isDirectory: true)
        self.manifestURL = self.trackDirectory.appendingPathComponent("track.json")
        self.chunkDuration = max(60, chunkDuration)
        self.eventHandler = eventHandler
        self.queue = DispatchQueue(
            label: "com.fluidvoice.meeting.writer.\(track.kind.rawValue)",
            qos: .userInitiated
        )
        self.finalizationQueue = DispatchQueue(
            label: "com.fluidvoice.meeting.writer.\(track.kind.rawValue).finalization",
            qos: .utility
        )

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

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        self.stateLock.lock()
        guard self.lifecycle == .accepting else {
            self.stateLock.unlock()
            return
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
            return
        }

        let sampleBox = SampleBox(sampleBuffer)
        self.queue.async { [weak self, sampleBox] in
            defer { self?.pendingSlots.signal() }
            self?.consume(sampleBox.sampleBuffer)
        }
        self.stateLock.unlock()
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

    func snapshot() async -> MeetingAudioTrack {
        await withCheckedContinuation { continuation in
            self.queue.async { [self] in
                continuation.resume(returning: self.track)
            }
        }
    }

    private func consume(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            self.recordDroppedSample(detail: "Capture delivered an invalid audio sample.")
            return
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid, presentationTime.isNumeric else {
            self.recordDroppedSample(detail: "Capture delivered audio without a valid presentation timestamp.")
            return
        }

        if let activeChunk = self.activeChunk {
            let elapsed = CMTimeGetSeconds(presentationTime - activeChunk.start)
            let backwards = presentationTime < activeChunk.end
            let gap = CMTimeGetSeconds(presentationTime - activeChunk.end)
            if elapsed >= self.chunkDuration || backwards || gap > 0.5 {
                if backwards || gap > 0.5 {
                    self.silenceAccumulatedSeconds = 0
                    let kind: MeetingInterruptionKind = backwards ? .clockDiscontinuity : .sourceLost
                    self.activeChunk?.discontinuities.append(MeetingAudioDiscontinuity(
                        kind: kind,
                        presentationTime: Self.mediaTime(presentationTime),
                        gapSeconds: backwards ? nil : gap,
                        detail: backwards ? "Presentation timestamp moved backwards." : "Unexpected audio gap."
                    ))
                }
                self.scheduleActiveChunkFinalization()
            }
        }

        do {
            if self.activeChunk == nil {
                try self.beginChunk(with: sampleBuffer, at: presentationTime)
            }
            guard var activeChunk = self.activeChunk else { return }
            guard activeChunk.input.isReadyForMoreMediaData else {
                self.recordDroppedSample(detail: "Audio encoder backpressure caused a dropped sample.")
                return
            }
            guard activeChunk.input.append(sampleBuffer) else {
                throw MeetingCaptureError.writerFailed(
                    activeChunk.writer.error?.localizedDescription ?? "The audio encoder rejected a sample."
                )
            }

            let duration = Self.sampleDuration(sampleBuffer)
            activeChunk.end = presentationTime + duration
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
            self.track.health.status = .degraded
            self.track.health.detail = error.localizedDescription
            self.eventHandler(.interrupted(
                kind: .writerFailure,
                trackID: self.track.id,
                detail: error.localizedDescription
            ))
        }
    }

    private func beginChunk(with sampleBuffer: CMSampleBuffer, at start: CMTime) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0
        else {
            throw MeetingCaptureError.unsupportedAudioFormat
        }

        let channelCount = min(2, max(1, Int(asbd.mChannelsPerFrame)))
        let bitRate = channelCount == 1 ? 64_000 : 96_000
        let sequence = self.nextChunkSequence
        self.nextChunkSequence += 1
        let stem = String(format: "%06d", sequence)
        let partialURL = self.trackDirectory.appendingPathComponent("\(stem).partial.m4a")
        let finalURL = self.trackDirectory.appendingPathComponent("\(stem).m4a")
        try? FileManager.default.removeItem(at: partialURL)

        let writer = try AVAssetWriter(outputURL: partialURL, fileType: .m4a)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate,
        ]
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw MeetingCaptureError.unsupportedAudioFormat }
        writer.add(input)
        guard writer.startWriting() else {
            throw MeetingCaptureError.writerFailed(
                writer.error?.localizedDescription ?? "The audio writer could not start."
            )
        }
        writer.startSession(atSourceTime: start)

        self.track.format = MeetingAudioFormat(
            codec: "aac-lc",
            sampleRate: asbd.mSampleRate,
            channelCount: channelCount,
            bitRate: bitRate
        )
        let relativePath = finalURL.path.replacingOccurrences(
            of: self.sessionDirectory.path + "/",
            with: ""
        )
        self.activeChunk = ActiveChunk(
            sequence: sequence,
            partialURL: partialURL,
            finalURL: finalURL,
            relativeFinalPath: relativePath,
            writer: writer,
            input: input,
            start: start,
            end: start,
            discontinuities: []
        )
    }

    private func scheduleActiveChunkFinalization() {
        guard let activeChunk = self.activeChunk else { return }
        self.activeChunk = nil
        activeChunk.input.markAsFinished()

        guard self.finalizationSlots.wait(timeout: .now()) == .success else {
            activeChunk.writer.cancelWriting()
            self.applyFinalization(.failed(
                Self.failedChunk(from: activeChunk),
                "Audio chunk finalization was saturated; the chunk was closed without blocking capture."
            ))
            return
        }

        self.finalizationGroup.enter()
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
        case let .finalized(chunk):
            self.track.chunks.append(chunk)
            try? self.persistTrackManifest()
            if let format = self.track.format {
                self.eventHandler(.chunkFinalized(trackID: self.track.id, chunk: chunk, format: format))
            }
        case let .failed(chunk, detail):
            self.track.chunks.append(chunk)
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
        let completion = DispatchSemaphore(value: 0)
        activeChunk.writer.finishWriting { completion.signal() }
        guard completion.wait(timeout: .now() + 4) == .success else {
            activeChunk.writer.cancelWriting()
            return .failed(
                self.failedChunk(from: activeChunk),
                "Timed out while finalizing the audio chunk."
            )
        }
        guard activeChunk.writer.status == .completed else {
            return .failed(
                self.failedChunk(from: activeChunk),
                activeChunk.writer.error?.localizedDescription ?? "The audio chunk could not be finalized."
            )
        }

        do {
            try? FileManager.default.removeItem(at: activeChunk.finalURL)
            try FileManager.default.moveItem(at: activeChunk.partialURL, to: activeChunk.finalURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: activeChunk.finalURL.path
            )
            let values = try activeChunk.finalURL.resourceValues(forKeys: [.fileSizeKey])
            return try .finalized(MeetingAudioChunk(
                id: UUID(),
                sequence: activeChunk.sequence,
                relativeFilePath: activeChunk.relativeFinalPath,
                presentationStart: self.mediaTime(activeChunk.start),
                presentationEnd: self.mediaTime(activeChunk.end),
                discontinuities: activeChunk.discontinuities,
                sha256: self.sha256(of: activeChunk.finalURL),
                byteCount: Int64(values.fileSize ?? 0),
                finalizationState: .finalized
            ))
        } catch {
            return .failed(self.failedChunk(from: activeChunk), error.localizedDescription)
        }
    }

    private nonisolated static func failedChunk(from activeChunk: ActiveChunk) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: activeChunk.sequence,
            relativeFilePath: activeChunk.relativeFinalPath,
            presentationStart: self.mediaTime(activeChunk.start),
            presentationEnd: self.mediaTime(activeChunk.end),
            discontinuities: activeChunk.discontinuities,
            sha256: "",
            byteCount: 0,
            finalizationState: .failed
        )
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

    private func persistTrackManifest() throws {
        let data = try self.encoder.encode(self.track)
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
