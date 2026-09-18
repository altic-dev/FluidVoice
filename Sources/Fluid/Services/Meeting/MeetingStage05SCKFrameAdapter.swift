#if DEBUG

import CoreAudio
import CoreMedia
import Foundation

/// One extracted Stage 0.5 callback block. Callback presentation time, callback arrival
/// time, and per-queue sequence order are distinct facts: this type carries the first two
/// and the adapter assigns the third.
nonisolated struct MeetingStage05AdapterFrame: Equatable, Sendable {
    let presentationSeconds: Double
    let durationSeconds: Double
    let frameCount: Int
    let sampleRateHz: Double
    let arrivalSeconds: Double?
    let samples: [Float]
    let discontinuity: Bool

    init(
        presentationSeconds: Double,
        durationSeconds: Double,
        frameCount: Int,
        sampleRateHz: Double,
        arrivalSeconds: Double?,
        samples: [Float],
        discontinuity: Bool = false
    ) {
        self.presentationSeconds = presentationSeconds
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
        self.sampleRateHz = sampleRateHz
        self.arrivalSeconds = arrivalSeconds
        self.samples = samples
        self.discontinuity = discontinuity
    }
}

nonisolated enum MeetingStage05AdapterRejection: String, Equatable, Sendable {
    case nonFiniteTiming
    case negativeTiming
    case invalidGeometry
    case durationMismatch
    case unsupportedFormat
    case unsupportedSampleRate
    case nonFiniteSamples
    case blockLimit
    case frameLimit
}

nonisolated struct MeetingStage05AdapterTrackDiagnostics: Equatable, Sendable {
    var acceptedCallbackCount = 0
    var rejectedCallbackCount = 0
    var gapCount = 0
    var overlapCount = 0
    var backwardCount = 0
    var discontinuityCount = 0
    var formatChangeCount = 0
}

nonisolated struct MeetingStage05AdapterDrain: Equatable, Sendable {
    let microphone: [MeetingMicrophonePCMFrame]
    let reference: [MeetingReferencePCMFrame]
    let microphoneDiagnostics: MeetingStage05AdapterTrackDiagnostics
    let renderDiagnostics: MeetingStage05AdapterTrackDiagnostics
}

/// DEBUG-only bridge from bounded ScreenCaptureKit callback buffers into the offline
/// `MeetingReferenceSynchronizer`. The adapter validates and places callbacks; the
/// synchronizer remains the sole owner of clock mapping, masks, and first-arrival-wins
/// rejection. Overlapping or late blocks are preserved as synchronizer inputs and counted
/// here as diagnostics; nothing is flattened or invented.
final class MeetingStage05SCKFrameAdapter: @unchecked Sendable {
    static let supportedSampleRateHz = 48_000.0
    static let maximumBlocksPerTrack = 2_000
    static let maximumFramesPerTrack = 960_000
    /// Harness-private sample attachment a controller may set to forward an explicit
    /// discontinuity. ScreenCaptureKit audio callbacks carry no standard discontinuity
    /// attachment, so unmarked discontinuities are detected from the PTS timeline.
    static let discontinuityAttachmentKey = "Stage05Discontinuity"

    let routeIdentifier: String
    private let lock = NSLock()
    private var renderFrames: [MeetingReferencePCMFrame] = []
    private var microphoneFrames: [MeetingMicrophonePCMFrame] = []
    private var renderCursor = Cursor()
    private var microphoneCursor = Cursor()

    /// The route identifier is injected by the caller; the adapter never infers or logs a
    /// device identity.
    init(routeIdentifier: String) {
        self.routeIdentifier = routeIdentifier
    }

    private struct Cursor {
        /// Sequence is callback arrival order, not accepted-frame order. A rejected
        /// callback consumes its slot so the next accepted frame exposes the missing
        /// callback to the synchronizer instead of silently closing the sequence.
        var nextSequence = 0
        var acceptedFrames = 0
        var lastPresentationSeconds: Double?
        var lastEndSeconds: Double?
        var diagnostics = MeetingStage05AdapterTrackDiagnostics()
    }

    enum Extraction: Equatable {
        case frame(MeetingStage05AdapterFrame)
        case failure(MeetingStage05AdapterRejection)
    }

    // MARK: Validation

    static func validate(
        _ frame: MeetingStage05AdapterFrame,
        acceptedFrames: Int
    ) -> MeetingStage05AdapterRejection? {
        guard frame.presentationSeconds.isFinite, frame.durationSeconds.isFinite,
              frame.durationSeconds > 0, frame.sampleRateHz.isFinite, frame.sampleRateHz > 0,
              frame.arrivalSeconds.map({ $0.isFinite }) ?? true else { return .nonFiniteTiming }
        guard frame.presentationSeconds >= 0,
              frame.arrivalSeconds.map({ $0 >= 0 }) ?? true else { return .negativeTiming }
        guard frame.frameCount > 0, frame.samples.count == frame.frameCount,
              frame.frameCount <= maximumFramesPerTrack else { return .invalidGeometry }
        let nominalDuration = Double(frame.frameCount) / frame.sampleRateHz
        guard abs(frame.durationSeconds - nominalDuration) <= 1.5 / frame.sampleRateHz else {
            return .durationMismatch
        }
        guard frame.sampleRateHz == supportedSampleRateHz else { return .unsupportedSampleRate }
        guard frame.samples.allSatisfy({ $0.isFinite }) else { return .nonFiniteSamples }
        guard acceptedFrames + frame.frameCount <= maximumFramesPerTrack else { return .frameLimit }
        return nil
    }

    // MARK: Constructed-frame seam (offline tests and pre-extracted callbacks)

    @discardableResult
    func appendRenderFrame(_ frame: MeetingStage05AdapterFrame) -> MeetingStage05AdapterRejection? {
        lock.lock(); defer { lock.unlock() }
        guard let sequence = reserveSequence(cursor: &renderCursor) else { return .blockLimit }
        if let rejection = Self.validate(frame, acceptedFrames: renderCursor.acceptedFrames) {
            recordRejection(rejection, cursor: &renderCursor)
            return rejection
        }
        detect(frame, cursor: &renderCursor)
        renderFrames.append(MeetingReferencePCMFrame(
            sequenceNumber: sequence,
            presentationTime: frame.presentationSeconds,
            sampleRate: frame.sampleRateHz,
            samples: frame.samples,
            discontinuity: frame.discontinuity))
        advance(frame, cursor: &renderCursor)
        return nil
    }

    @discardableResult
    func appendMicrophoneFrame(_ frame: MeetingStage05AdapterFrame) -> MeetingStage05AdapterRejection? {
        lock.lock(); defer { lock.unlock() }
        guard let sequence = reserveSequence(cursor: &microphoneCursor) else { return .blockLimit }
        if let rejection = Self.validate(frame, acceptedFrames: microphoneCursor.acceptedFrames) {
            recordRejection(rejection, cursor: &microphoneCursor)
            return rejection
        }
        // PTS converted to the sample-rate timescale; never cumulative samples written.
        let scaled = frame.presentationSeconds * frame.sampleRateHz
        let roundedScaled = scaled.rounded()
        guard roundedScaled.isFinite,
              roundedScaled >= Double(Int64.min),
              roundedScaled < Double(Int64.max) else {
            recordRejection(.nonFiniteTiming, cursor: &microphoneCursor)
            return .nonFiniteTiming
        }
        detect(frame, cursor: &microphoneCursor)
        microphoneFrames.append(MeetingMicrophonePCMFrame(
            sequenceNumber: sequence,
            sampleTime: Int64(roundedScaled),
            hostTime: frame.arrivalSeconds,
            sampleRate: frame.sampleRateHz,
            samples: frame.samples,
            routeIdentifier: routeIdentifier,
            discontinuity: frame.discontinuity))
        advance(frame, cursor: &microphoneCursor)
        return nil
    }

    // MARK: Live CMSampleBuffer entry points

    @discardableResult
    func appendRender(_ sampleBuffer: CMSampleBuffer, arrivalSeconds: Double) -> MeetingStage05AdapterRejection? {
        switch Self.extract(sampleBuffer, arrivalSeconds: arrivalSeconds) {
        case .frame(let frame): return appendRenderFrame(frame)
        case .failure(let rejection):
            lock.lock(); defer { lock.unlock() }
            guard reserveSequence(cursor: &renderCursor) != nil else { return .blockLimit }
            recordRejection(rejection, cursor: &renderCursor)
            return rejection
        }
    }

    @discardableResult
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer, arrivalSeconds: Double) -> MeetingStage05AdapterRejection? {
        switch Self.extract(sampleBuffer, arrivalSeconds: arrivalSeconds) {
        case .frame(let frame): return appendMicrophoneFrame(frame)
        case .failure(let rejection):
            lock.lock(); defer { lock.unlock() }
            guard reserveSequence(cursor: &microphoneCursor) != nil else { return .blockLimit }
            recordRejection(rejection, cursor: &microphoneCursor)
            return rejection
        }
    }

    /// Extracts native packed mono Float32 PCM without writing files. Format rejections are
    /// reported here; timing and payload validation happen in `validate`.
    static func extract(_ sampleBuffer: CMSampleBuffer, arrivalSeconds: Double) -> Extraction {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return .failure(.invalidGeometry) }
        guard let nativeFormat = MeetingStage05NativePCMFormat.from(asbd) else {
            return .failure(.unsupportedFormat)
        }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0, count <= maximumFramesPerTrack else { return .failure(.invalidGeometry) }
        let byteCount = count * nativeFormat.bytesPerFrame
        var requiredSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &requiredSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil) == noErr, requiredSize > 0 else { return .failure(.invalidGeometry) }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: requiredSize, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retained) == noErr else { return .failure(.invalidGeometry) }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count == 1, buffers[0].mNumberChannels == 1,
              buffers[0].mDataByteSize == UInt32(byteCount), let pointer = buffers[0].mData
        else { return .failure(.invalidGeometry) }
        let samples = UnsafeRawBufferPointer(start: pointer, count: byteCount)
            .bindMemory(to: UInt32.self).map { Float(bitPattern: UInt32(littleEndian: $0)) }
        return .frame(MeetingStage05AdapterFrame(
            presentationSeconds: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
            durationSeconds: CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer)),
            frameCount: count,
            sampleRateHz: asbd.mSampleRate,
            arrivalSeconds: arrivalSeconds,
            samples: samples,
            discontinuity: hasDiscontinuityAttachment(sampleBuffer)))
    }

    static func hasDiscontinuityAttachment(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [NSDictionary],
              let first = attachments.first else { return false }
        return (first[discontinuityAttachmentKey] as? Bool) == true
    }

    // MARK: Drain and synchronize

    /// Returns the bounded per-track inputs and diagnostics. Call only after both callback
    /// queues have been drained; this method performs no queue work itself.
    func drain() -> MeetingStage05AdapterDrain {
        lock.lock(); defer { lock.unlock() }
        return MeetingStage05AdapterDrain(
            microphone: microphoneFrames,
            reference: renderFrames,
            microphoneDiagnostics: microphoneCursor.diagnostics,
            renderDiagnostics: renderCursor.diagnostics)
    }

    /// Runs the pure synchronizer over the drained callbacks. No clock drift is estimated
    /// from callback PTS; the caller-owned configuration is passed through unchanged.
    func synchronize(
        configuration: MeetingReferenceSynchronizerConfiguration = .init()
    ) -> (MeetingStage05AdapterDrain, MeetingSynchronizationResult) {
        let drained = drain()
        return (drained, MeetingReferenceSynchronizer(configuration: configuration)
            .synchronize(microphone: drained.microphone, reference: drained.reference))
    }

    // MARK: Per-callback observation

    private func reserveSequence(cursor: inout Cursor) -> Int? {
        guard cursor.nextSequence < Self.maximumBlocksPerTrack else {
            recordRejection(.blockLimit, cursor: &cursor)
            return nil
        }
        let reserved = cursor.nextSequence
        cursor.nextSequence += 1
        return reserved
    }

    private func recordRejection(_ rejection: MeetingStage05AdapterRejection, cursor: inout Cursor) {
        cursor.diagnostics.rejectedCallbackCount += 1
        if rejection == .unsupportedFormat || rejection == .unsupportedSampleRate {
            cursor.diagnostics.formatChangeCount += 1
        }
    }

    private func detect(_ frame: MeetingStage05AdapterFrame, cursor: inout Cursor) {
        if let lastPTS = cursor.lastPresentationSeconds, let lastEnd = cursor.lastEndSeconds {
            let oneSample = 1 / frame.sampleRateHz - 1e-9
            if frame.presentationSeconds - lastEnd >= oneSample { cursor.diagnostics.gapCount += 1 }
            if lastEnd - frame.presentationSeconds >= oneSample { cursor.diagnostics.overlapCount += 1 }
            if frame.presentationSeconds <= lastPTS { cursor.diagnostics.backwardCount += 1 }
        }
        if frame.discontinuity { cursor.diagnostics.discontinuityCount += 1 }
    }

    private func advance(_ frame: MeetingStage05AdapterFrame, cursor: inout Cursor) {
        cursor.diagnostics.acceptedCallbackCount += 1
        cursor.acceptedFrames += frame.frameCount
        cursor.lastPresentationSeconds = frame.presentationSeconds
        cursor.lastEndSeconds = frame.presentationSeconds + Double(frame.frameCount) / frame.sampleRateHz
    }
}

#endif
