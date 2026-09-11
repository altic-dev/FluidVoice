import Accelerate
import AudioToolbox
@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os

// MARK: - PTS clock

/// Anchor-and-count acquisition PTS. INVARIANT: emitted PTS is sample-count truth — corrections
/// adjust only the divergence reference, never `anchorPTS`, so they are a no-op on output and
/// double as a drift meter (~one per 3.2 s at the mic's measured ~6.7 ppm).
nonisolated struct MeetingMicrophonePTSClock {
    enum Outcome: Equatable {
        /// `resynced` is true when this valid stamp follows a post-cap dropped run.
        case emitted(pts: CMTime, synthesized: Bool, anchorCorrected: Bool, resynced: Bool)
        /// Cap exceeded: don't emit — the writer must see the gap, not a flawless silent track.
        case droppedPostCap
    }

    /// Genuine steps only: drift moves 0.64 ns/window, jitter stays in the µs.
    static let divergenceStepThresholdSeconds: Double = 0.010

    private(set) var cumulativeAbsorbedCorrectionSeconds: Double = 0
    private(set) var maxAbsDivergenceSeconds: Double = 0
    private(set) var divergenceStepEventCount = 0
    private(set) var maxDivergenceStepSeconds: Double = 0
    private(set) var resyncClampCount = 0
    private(set) var firstValidHostSeconds: Double?
    private(set) var lastValidHostSeconds: Double?
    private var lastDivergenceSeconds: Double = 0
    private var lastEmittedEnd: CMTime = .invalid

    /// Deliberately equal to the writer's 0.5 s gap threshold (`MeetingAudioChunkWriter.swift:181`).
    static let synthesisCapSeconds: Double = 0.5

    static let timescale: CMTimeScale = 48_000

    private let sampleRate: Double
    private let timebase: mach_timebase_info_data_t

    private var anchorHostSeconds: Double?
    private var anchorPTS: CMTime = .zero
    private var framesSinceAnchor: Int64 = 0
    private var synthesizedRunFrames: Int64 = 0 // integer frames: summed Doubles drift the cap
    private var isDroppingInvalidRun = false

    init(sampleRate: Double = Double(Self.timescale), timebase: mach_timebase_info_data_t = Self.machTimebase()) {
        self.sampleRate = sampleRate
        self.timebase = timebase
    }

    private static func machTimebase() -> mach_timebase_info_data_t {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }

    private func seconds(hostTime: UInt64) -> Double {
        guard self.timebase.denom > 0 else { return Double(hostTime) / 1_000_000_000 }
        return Double(hostTime) * Double(self.timebase.numer) / Double(self.timebase.denom) / 1_000_000_000
    }

    private func currentPTS() -> CMTime {
        CMTimeAdd(self.anchorPTS, CMTime(value: self.framesSinceAnchor, timescale: Self.timescale))
    }

    private mutating func resetAnchor(hostSeconds: Double) {
        self.anchorHostSeconds = hostSeconds
        self.anchorPTS = CMTime(seconds: hostSeconds, preferredTimescale: Self.timescale)
        self.framesSinceAnchor = 0
    }

    // hostTime nil iff isHostTimeValid false; 0 is a legitimate mach tick, not a sentinel
    mutating func stamp(hostTime: UInt64?, frameCount: Int) -> Outcome {
        guard let hostTime else {
            return self.stampInvalid(frameCount: frameCount)
        }
        return self.stampValid(hostTime: hostTime, frameCount: frameCount)
    }

    private mutating func stampInvalid(frameCount: Int) -> Outcome {
        guard self.anchorHostSeconds != nil else { // no anchor: epoch-0 PTS would poison origins
            return .droppedPostCap
        }
        if self.isDroppingInvalidRun {
            return .droppedPostCap
        }
        let pts = self.currentPTS()
        self.framesSinceAnchor += Int64(frameCount)
        self.synthesizedRunFrames += Int64(frameCount)
        if Double(self.synthesizedRunFrames) / self.sampleRate > Self.synthesisCapSeconds {
            self.isDroppingInvalidRun = true
            return .droppedPostCap
        }
        self.noteEmitted(pts: pts, frameCount: frameCount)
        return .emitted(pts: pts, synthesized: true, anchorCorrected: false, resynced: false)
    }

    private mutating func stampValid(hostTime: UInt64, frameCount: Int) -> Outcome {
        let actualSeconds = self.seconds(hostTime: hostTime)
        let wasDropping = self.isDroppingInvalidRun
        self.isDroppingInvalidRun = false
        self.synthesizedRunFrames = 0
        if self.firstValidHostSeconds == nil { self.firstValidHostSeconds = actualSeconds }
        self.lastValidHostSeconds = actualSeconds

        if self.anchorHostSeconds == nil || wasDropping {
            // A backlogged invalid burst can synthesize more timeline than elapsed host time;
            // anchoring behind emitted audio would trip the writer's backwards check.
            var resyncSeconds = actualSeconds
            if self.lastEmittedEnd.isValid, self.lastEmittedEnd.seconds > resyncSeconds {
                resyncSeconds = self.lastEmittedEnd.seconds
                self.resyncClampCount += 1
            }
            self.resetAnchor(hostSeconds: resyncSeconds)
            self.lastDivergenceSeconds = 0
            let pts = self.currentPTS()
            self.framesSinceAnchor += Int64(frameCount)
            self.noteEmitted(pts: pts, frameCount: frameCount)
            return .emitted(pts: pts, synthesized: false, anchorCorrected: wasDropping, resynced: wasDropping)
        }

        let expectedSeconds = self.anchorHostSeconds! + Double(self.framesSinceAnchor) / self.sampleRate
        let divergence = actualSeconds - expectedSeconds
        self.maxAbsDivergenceSeconds = max(self.maxAbsDivergenceSeconds, abs(divergence))
        let step = abs(divergence - self.lastDivergenceSeconds)
        if step > Self.divergenceStepThresholdSeconds {
            self.divergenceStepEventCount += 1
            self.maxDivergenceStepSeconds = max(self.maxDivergenceStepSeconds, step)
        }
        self.lastDivergenceSeconds = divergence
        let pts = self.currentPTS()
        self.framesSinceAnchor += Int64(frameCount)
        self.noteEmitted(pts: pts, frameCount: frameCount)

        var corrected = false
        if abs(divergence) > 1.0 / self.sampleRate {
            // += divergence; using the post-increment count latches one window off (97% bug).
            self.anchorHostSeconds! += divergence
            self.cumulativeAbsorbedCorrectionSeconds += divergence
            self.lastDivergenceSeconds = 0
            corrected = true
        }
        return .emitted(pts: pts, synthesized: false, anchorCorrected: corrected, resynced: false)
    }

    private mutating func noteEmitted(pts: CMTime, frameCount: Int) {
        self.lastEmittedEnd = CMTimeAdd(pts, CMTime(value: Int64(frameCount), timescale: Self.timescale))
    }

    mutating func requestTimelineReset() {
        self.anchorHostSeconds = nil
        self.isDroppingInvalidRun = false
        self.synthesizedRunFrames = 0
        self.lastDivergenceSeconds = 0
    }
}

// MARK: - CMSampleBuffer synthesis (free function, no AVAudioEngine dependency)

/// Owns a fresh copy of the bytes — never wraps the source's storage — because `writer.enqueue`
/// consumes asynchronously and the sample outlives the tap callback.
nonisolated func meetingMicrophoneSynthesizeSampleBuffer(
    from buffer: AVAudioPCMBuffer,
    presentationTime: CMTime
) -> CMSampleBuffer? {
    guard buffer.frameLength > 0, let channelData = buffer.floatChannelData else { return nil }

    var asbd = buffer.format.streamDescription.pointee
    var formatDescription: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else { return nil }

    let frameCount = Int(buffer.frameLength)
    let byteCount = frameCount * MemoryLayout<Float>.size

    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &blockBuffer
    )
    guard blockStatus == noErr, let blockBuffer else { return nil }

    let copyStatus = CMBlockBufferReplaceDataBytes(
        with: channelData[0],
        blockBuffer: blockBuffer,
        offsetIntoDestination: 0,
        dataLength: byteCount
    )
    guard copyStatus == noErr else { return nil }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate.rounded())),
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: frameCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr else { return nil }
    return sampleBuffer
}

// MARK: - Binding

/// Verified outcome of binding the AUHAL input unit to a specific CoreAudio device (plan §6).
nonisolated enum MeetingMicrophoneBindingOutcome: Equatable, Sendable {
    case boundVerified(AudioObjectID)
    /// Bind failed but the default input already IS the requested device (Bluetooth/aggregate).
    case defaultMatchesRequested
    case unavailable(reason: String)
}

extension MeetingMicrophoneBindingOutcome: Codable {
    private enum CodingKeys: String, CodingKey { case kind, deviceID, reason }
    private enum Kind: String, Codable { case boundVerified, defaultMatchesRequested, unavailable }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .boundVerified:
            self = .boundVerified(try container.decode(AudioObjectID.self, forKey: .deviceID))
        case .defaultMatchesRequested:
            self = .defaultMatchesRequested
        case .unavailable:
            self = .unavailable(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boundVerified(deviceID):
            try container.encode(Kind.boundVerified, forKey: .kind)
            try container.encode(deviceID, forKey: .deviceID)
        case .defaultMatchesRequested:
            try container.encode(Kind.defaultMatchesRequested, forKey: .kind)
        case let .unavailable(reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// Pure decision table, unit-testable headless.
nonisolated enum MeetingMicrophoneBindDecision {
    static func outcome(
        bindStatus: OSStatus,
        readBackDeviceID: AudioObjectID?,
        requestedDeviceID: AudioObjectID,
        defaultInputUID: String?,
        requestedUID: String
    ) -> MeetingMicrophoneBindingOutcome {
        if bindStatus == noErr, let readBackDeviceID, readBackDeviceID == requestedDeviceID {
            return .boundVerified(readBackDeviceID)
        }
        // VP-enable can replace the I/O unit; only post-start read-back proves the binding.
        if !requestedUID.isEmpty, defaultInputUID == requestedUID {
            return .defaultMatchesRequested
        }
        if let readBackDeviceID, readBackDeviceID != requestedDeviceID {
            return .unavailable(reason: "Bound device \(readBackDeviceID) does not match requested device \(requestedDeviceID).")
        }
        if bindStatus == -10_851 {
            return .unavailable(reason: "Binding failed for an aggregate/Bluetooth-style device (OSStatus -10851).")
        }
        return .unavailable(reason: "Could not verify device binding (bindStatus=\(bindStatus)).")
    }
}

// MARK: - Settled configuration

/// What the session actually got, not what it asked for; `Codable` for §7 provenance at rest.
nonisolated struct MeetingMicrophoneSettledConfig: Codable, Equatable, Sendable {
    var requestedMicrophone: MeetingMicrophoneIdentity
    var bindingOutcome: MeetingMicrophoneBindingOutcome
    /// TODO(probe): hard-code the measured winner; the alternate order is probe-only, never shipped.
    var bindingOrder: String
    var settledInputDeviceUID: String?
    var settledOutputDeviceUID: String?
    var sourceSampleRate: Double
    var sourceChannelCount: Int
    var voiceProcessingEnabled: Bool
    /// Mono is a recorded decision: SCStream's config is stereo but its mic output observed mono.
    var outputChannelDecision: String
}

// MARK: - Voice-processing read-back probe

/// One exact `AudioUnitGetProperty` result. A failed read never carries a stale value.
nonisolated struct MeetingAudioUnitUInt32Readback: Codable, Equatable, Sendable {
    var propertyID: UInt32
    var scope: UInt32
    var element: UInt32
    var status: OSStatus
    var value: UInt32?

    init(
        propertyID: UInt32,
        scope: UInt32,
        element: UInt32,
        status: OSStatus,
        value: UInt32?
    ) {
        self.propertyID = propertyID
        self.scope = scope
        self.element = element
        self.status = status
        self.value = status == noErr ? value : nil
    }

    var succeeded: Bool { self.status == noErr }
}

nonisolated struct MeetingAudioUnitDuckingReadback: Codable, Equatable, Sendable {
    var propertyID: UInt32
    var scope: UInt32
    var element: UInt32
    var status: OSStatus
    var advancedDuckingEnabled: Bool?
    var duckingLevelRawValue: UInt32?

    init(
        propertyID: UInt32,
        scope: UInt32,
        element: UInt32,
        status: OSStatus,
        advancedDuckingEnabled: Bool?,
        duckingLevelRawValue: UInt32?
    ) {
        self.propertyID = propertyID
        self.scope = scope
        self.element = element
        self.status = status
        self.advancedDuckingEnabled = status == noErr ? advancedDuckingEnabled : nil
        self.duckingLevelRawValue = status == noErr ? duckingLevelRawValue : nil
    }
}

nonisolated struct MeetingAudioFormatProbeReadback: Codable, Equatable, Sendable {
    var sampleRate: Double
    var channelCount: UInt32
    var commonFormatRawValue: UInt
    var interleaved: Bool

    init(_ format: AVAudioFormat) {
        self.sampleRate = format.sampleRate
        self.channelCount = format.channelCount
        self.commonFormatRawValue = format.commonFormat.rawValue
        self.interleaved = format.isInterleaved
    }
}

nonisolated struct MeetingAudioTimeProbeReadback: Codable, Equatable, Sendable {
    var hostTime: UInt64?
    var sampleTime: Int64?
    var sampleRate: Double?

    init(_ time: AVAudioTime?) {
        self.hostTime = time?.isHostTimeValid == true ? time?.hostTime : nil
        self.sampleTime = time?.isSampleTimeValid == true ? time?.sampleTime : nil
        self.sampleRate = time?.isSampleTimeValid == true ? time?.sampleRate : nil
    }
}

/// Read-only evidence from the already-running VPIO graph. This is probe output, not runtime
/// provenance: the values are intentionally kept out of `MeetingMicrophoneSettledConfig` until
/// the hardware matrix establishes which properties are stable and decision-relevant.
nonisolated struct MeetingVoiceProcessingProbeSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var engineRunning: Bool
    var nodeVoiceProcessingEnabled: Bool
    var nodeVoiceProcessingBypassed: Bool
    var nodeVoiceProcessingAGCEnabled: Bool
    var nodeVoiceProcessingInputMuted: Bool
    var nodeAdvancedDuckingEnabled: Bool
    var nodeDuckingLevelRawValue: Int
    var inputPresentationLatencySeconds: Double
    var outputPresentationLatencySeconds: Double
    var inputNodeInputFormat: MeetingAudioFormatProbeReadback
    var inputNodeOutputFormat: MeetingAudioFormatProbeReadback
    var outputNodeInputFormat: MeetingAudioFormatProbeReadback
    var outputNodeOutputFormat: MeetingAudioFormatProbeReadback
    var inputNodeLastRenderTime: MeetingAudioTimeProbeReadback
    var outputNodeLastRenderTime: MeetingAudioTimeProbeReadback
    var inputNodeOutputConnectionCount: Int
    var inputCurrentDevice: MeetingAudioUnitUInt32Readback
    var outputCurrentDevice: MeetingAudioUnitUInt32Readback
    var bypassVoiceProcessing: MeetingAudioUnitUInt32Readback
    var voiceProcessingAGCEnabled: MeetingAudioUnitUInt32Readback
    var voiceProcessingOutputMuted: MeetingAudioUnitUInt32Readback
    var otherAudioDucking: MeetingAudioUnitDuckingReadback
}

nonisolated enum MeetingVoiceProcessingProbeError: Error, Sendable {
    case disabled
    case captureNotRunning
    case invalidPlaybackFormat
    case playbackTimedOut
}

#if DEBUG
/// Bridges player completion and task cancellation without ever resuming a checked continuation
/// twice. Cancellation resumes the task immediately; the actor's deferred cleanup then owns every
/// engine mutation.
private final nonisolated class MeetingVPIOAcousticPlaybackContinuation: @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    nonisolated func install(_ continuation: CheckedContinuation<Void, Error>) {
        let shouldCancel: Bool
        self.lock.lock()
        shouldCancel = self.cancelled
        if !shouldCancel { self.continuation = continuation }
        self.lock.unlock()
        if shouldCancel { continuation.resume(throwing: CancellationError()) }
    }

    nonisolated func finish() {
        self.resume { $0.resume() }
    }

    nonisolated func cancel() {
        self.lock.lock()
        self.cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    nonisolated func timeout() {
        self.resume { $0.resume(throwing: MeetingVoiceProcessingProbeError.playbackTimedOut) }
    }

    private nonisolated func resume(_ body: (CheckedContinuation<Void, Error>) -> Void) {
        self.lock.lock()
        let continuation = self.continuation
        let wasCancelled = self.cancelled
        self.continuation = nil
        self.lock.unlock()
        if wasCancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let continuation {
            body(continuation)
        }
    }
}

/// Numeric-only mixer tap accumulator. It records no audio; the sample values are reduced as they
/// arrive so the render confirmation can be emitted without retaining the reference waveform.
final nonisolated class MeetingVPIOAcousticRenderTapCollector: @unchecked Sendable {
    private nonisolated struct State: Sendable {
        var sampleRate = 0.0
        var channelCount = 0
        var frameCount = 0
        var invalidHostTimeCount = 0
        var sumSquares = 0.0
        var peak = 0.0
        var renderStartHostSeconds: Double?
    }

    private nonisolated let lock = OSAllocatedUnfairLock(initialState: State())

    nonisolated func ingest(buffer: AVAudioPCMBuffer, time: AVAudioTime?) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let channelsCount = max(1, Int(buffer.format.channelCount))
        let rate = buffer.format.sampleRate
        let hostStart = time?.isHostTimeValid == true ? MeetingVPIOAcousticHostClock.seconds(time!.hostTime) : nil
        var sumSquares = 0.0
        var peak = 0.0
        var firstActivityHostSeconds: Double?
        for index in 0..<frames {
            var value = 0.0
            for channel in 0..<channelsCount { value += Double(channels[channel][index]) }
            value /= Double(channelsCount)
            sumSquares += value * value
            peak = max(peak, abs(value))
            if firstActivityHostSeconds == nil, abs(value) > 1e-5, let hostStart {
                firstActivityHostSeconds = hostStart + Double(index) / max(rate, 1)
            }
        }
        let reducedSumSquares = sumSquares
        let reducedPeak = peak
        let reducedFirstActivityHostSeconds = firstActivityHostSeconds
        self.lock.withLock { state in
            state.sampleRate = rate
            state.channelCount = channelsCount
            state.frameCount += frames
            if hostStart == nil { state.invalidHostTimeCount += 1 }
            state.sumSquares += reducedSumSquares
            state.peak = max(state.peak, reducedPeak)
            if state.renderStartHostSeconds == nil {
                state.renderStartHostSeconds = reducedFirstActivityHostSeconds
            }
        }
    }

    nonisolated func report(
        scheduledFrameCount: Int,
        sampleRate: Double,
        volume: Float,
        outputPreflight: MeetingVPIOAcousticOutputPreflight
    ) -> MeetingVPIOAcousticRenderConfirmation {
        let state = self.lock.withLock { $0 }
        let renderRMS = state.frameCount > 0 ? sqrt(state.sumSquares / Double(state.frameCount)) : 0
        var reasons: [MeetingVPIOAcousticReason] = []
        if state.frameCount == 0 || state.peak <= 1e-5 { reasons.append(.renderReadbackSilent) }
        if state.renderStartHostSeconds == nil { reasons.append(.renderStartUnresolved) }
        if state.invalidHostTimeCount > 0 { reasons.append(.renderTimingInvalid) }
        reasons.append(contentsOf: outputPreflight.reasons)
        return MeetingVPIOAcousticRenderConfirmation(
            scheduledFrameCount: scheduledFrameCount,
            sampleRate: sampleRate,
            volume: Double(volume),
            mixerSampleRate: state.sampleRate,
            mixerChannelCount: state.channelCount,
            tapFrameCount: state.frameCount,
            tapRMS: renderRMS,
            tapPeak: state.peak,
            tapInvalidHostTimeCount: state.invalidHostTimeCount,
            renderStartHostSeconds: state.renderStartHostSeconds,
            playerDerivedStartHostSeconds: nil,
            playerRenderedFrameCount: nil,
            renderStartResolved: state.renderStartHostSeconds != nil,
            outputConnectionCount: outputPreflight.outputConnectionCount,
            outputDeviceID: outputPreflight.outputDeviceID,
            defaultOutputDeviceID: outputPreflight.defaultOutputDeviceID,
            outputRouteConfirmed: outputPreflight.outputRouteConfirmed,
            systemVolume: outputPreflight.systemVolume,
            outputVolumeReadable: outputPreflight.outputVolumeReadable,
            combinedPeak: outputPreflight.combinedPeak,
            reasons: {
                var seen = Set<MeetingVPIOAcousticReason>()
                return reasons.filter { seen.insert($0).inserted }.sorted { $0.rawValue < $1.rawValue }
            }()
        )
    }
}
#endif

// MARK: - Capture events

nonisolated enum MeetingMicrophoneCaptureEvent: Sendable {
    case configurationChanged
    case defaultInputChanged
    case overload
    case engineStopped
}

nonisolated enum MeetingMicrophoneCaptureError: Error, Sendable {
    case alreadyStarted
    case lifecycleInterrupted
}

/// Core Audio invokes property listeners on a shared serial delivery queue. Listener callbacks
/// must return before meeting policy performs any HAL reads or capture transitions.
nonisolated enum MeetingMicrophoneEventExecution {
    private static let queue = DispatchQueue(
        label: "com.fluidvoice.meeting-microphone-events",
        qos: .userInitiated
    )

    static func afterHALCallback(_ work: @escaping @Sendable () -> Void) {
        AudioTopologyListenerExecution.deliveryQueue.async {
            Self.queue.async(execute: work)
        }
    }
}

// MARK: - Stats

/// Lock-guarded, never actor-isolated: the audio thread needs priority donation.
final class MeetingMicrophoneCaptureStats: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var buffersEmitted = 0
        var validHostTimeCount = 0
        var synthesizedCount = 0
        var anchorCorrectionCount = 0
        var resyncCount = 0
        var droppedPostCapCount = 0
        var conversionFailures = 0
        var sequenceContinuityViolations = 0
        var overloadCount = 0
        var configurationChangeEvents = 0
        var defaultInputChangeEvents = 0
        var tapCallbackMaxDurationSeconds: Double = 0
        var tapCallbackP99DurationSeconds: Double = 0
        var cumulativeAbsorbedCorrectionSeconds: Double = 0
        var maxAbsDivergenceSeconds: Double = 0
        var divergenceStepEventCount = 0
        var maxDivergenceStepSeconds: Double = 0
        var resyncClampCount = 0
        var firstValidHostSeconds: Double?
        var lastValidHostSeconds: Double?

        /// The Phase 1 gate's headline number: ≥99% valid hostTime over the run.
        var validHostTimeFraction: Double {
            let total = self.validHostTimeCount + self.synthesizedCount
            guard total > 0 else { return 1 }
            return Double(self.validHostTimeCount) / Double(total)
        }
    }

    private struct State {
        var snapshot = Snapshot()
        var callbackDurations: [Double] = []
    }

    private static let maxTrackedDurations = 4_096

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func mutate(_ body: (inout Snapshot) -> Void) {
        self.lock.withLock { state in body(&state.snapshot) }
    }

    func recordCallbackDuration(_ seconds: Double) {
        self.lock.withLock { state in
            state.snapshot.tapCallbackMaxDurationSeconds = max(state.snapshot.tapCallbackMaxDurationSeconds, seconds)
            state.callbackDurations.append(seconds)
            if state.callbackDurations.count > Self.maxTrackedDurations {
                state.callbackDurations.removeFirst(state.callbackDurations.count - Self.maxTrackedDurations)
            }
        }
    }

    func snapshot() -> Snapshot {
        self.lock.withLock { state in
            var snapshot = state.snapshot
            if !state.callbackDurations.isEmpty {
                let sorted = state.callbackDurations.sorted()
                let index = min(sorted.count - 1, Int(Double(sorted.count) * 0.99))
                snapshot.tapCallbackP99DurationSeconds = sorted[index]
            }
            return snapshot
        }
    }
}

/// Invalidated on `stop()` so an in-flight tap callback no-ops instead of touching torn-down state.
private final class MeetingMicrophoneGenerationBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    @discardableResult
    func advance() -> UInt64 {
        self.lock.withLock { generation in
            generation += 1
            return generation
        }
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        self.lock.withLock { $0 == generation }
    }
}

// MARK: - Tap state (audio thread only, never hops to the actor)

private final class MeetingMicrophoneTapState: @unchecked Sendable {
    /// Tap delivers ~10.7 ms buffers; emitting each would 10x the writer's tuned 24-slot budget.
    private static let accumulationFrameThreshold = 4_800 // 100 ms @ 48 kHz

    private let statsBox: MeetingMicrophoneCaptureStats
    private let canonicalFormat: AVAudioFormat
    private let onSample: @Sendable (CMSampleBuffer) -> Void
    private let onSampleMetadata: @Sendable (CMSampleBuffer, Bool, Bool) -> Void

    private var clock = MeetingMicrophonePTSClock()
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var accumulated: [Float] = []
    private var windowHostTime: UInt64?
    private var windowHostTimeValid = false
    private var lastExpectedSampleTime: AVAudioFramePosition?

    init(
        statsBox: MeetingMicrophoneCaptureStats,
        canonicalFormat: AVAudioFormat,
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
        onSampleMetadata: @escaping @Sendable (CMSampleBuffer, Bool, Bool) -> Void = { _, _, _ in }
    ) {
        self.statsBox = statsBox
        self.canonicalFormat = canonicalFormat
        self.onSample = onSample
        self.onSampleMetadata = onSampleMetadata
    }

    func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let start = DispatchTime.now()
        defer { self.statsBox.recordCallbackDuration(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000) }

        self.consumePendingResetIfNeeded()
        self.checkSequenceContinuity(time: time, frameCount: Int(buffer.frameLength))

        let converted = self.convertToMono(buffer)
        guard let mono = converted, !mono.isEmpty else {
            if converted == nil { self.statsBox.mutate { $0.conversionFailures += 1 } }
            return
        }

        if self.accumulated.isEmpty {
            self.windowHostTimeValid = time.isHostTimeValid
            self.windowHostTime = time.isHostTimeValid ? time.hostTime : nil
        }
        self.accumulated.append(contentsOf: mono)

        if self.accumulated.count >= Self.accumulationFrameThreshold {
            self.flush()
        }
    }

    private func flush() {
        let frameCount = self.accumulated.count
        let outcome = self.clock.stamp(hostTime: self.windowHostTimeValid ? self.windowHostTime : nil, frameCount: frameCount)
        let samples = self.accumulated
        self.accumulated.removeAll(keepingCapacity: true)
        self.windowHostTime = nil
        self.windowHostTimeValid = false

        guard case let .emitted(pts, synthesized, anchorCorrected, resynced) = outcome else {
            self.statsBox.mutate { $0.droppedPostCapCount += 1 }
            return
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: self.canonicalFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            self.statsBox.mutate { $0.conversionFailures += 1 }
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        samples.withUnsafeBufferPointer { source in
            pcmBuffer.floatChannelData?[0].update(from: source.baseAddress!, count: frameCount)
        }

        guard let sampleBuffer = meetingMicrophoneSynthesizeSampleBuffer(from: pcmBuffer, presentationTime: pts) else {
            self.statsBox.mutate { $0.conversionFailures += 1 }
            return
        }

        let clock = self.clock
        self.statsBox.mutate { stats in
            stats.buffersEmitted += 1
            if synthesized { stats.synthesizedCount += 1 } else { stats.validHostTimeCount += 1 }
            if anchorCorrected { stats.anchorCorrectionCount += 1 }
            if resynced { stats.resyncCount += 1 }
            stats.cumulativeAbsorbedCorrectionSeconds = clock.cumulativeAbsorbedCorrectionSeconds
            stats.maxAbsDivergenceSeconds = clock.maxAbsDivergenceSeconds
            stats.divergenceStepEventCount = clock.divergenceStepEventCount
            stats.maxDivergenceStepSeconds = clock.maxDivergenceStepSeconds
            stats.resyncClampCount = clock.resyncClampCount
            stats.firstValidHostSeconds = clock.firstValidHostSeconds
            stats.lastValidHostSeconds = clock.lastValidHostSeconds
        }
        self.onSampleMetadata(sampleBuffer, synthesized, resynced)
        self.onSample(sampleBuffer)
    }

    /// Set off the tap thread; consumed at the next callback so the clock re-anchors.
    func requestTimelineReset() {
        self.pendingTimelineReset.withLock { $0 = true }
    }

    private let pendingTimelineReset = OSAllocatedUnfairLock(initialState: false)

    private func consumePendingResetIfNeeded() {
        let pending = self.pendingTimelineReset.withLock { flag -> Bool in
            defer { flag = false }
            return flag
        }
        if pending {
            self.clock.requestTimelineReset()
            self.accumulated.removeAll(keepingCapacity: true)
            self.windowHostTime = nil
            self.windowHostTimeValid = false
            self.lastExpectedSampleTime = nil
            self.converter = nil
            self.converterSourceFormat = nil
        }
    }

    /// Resample first, then downmix explicitly — converter channel mapping may drop, not mix.
    private func convertToMono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let sourceFormat = buffer.format
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else { return nil }

        if sourceFormat.sampleRate == self.canonicalFormat.sampleRate, sourceFormat.commonFormat == .pcmFormatFloat32 {
            return Self.downmixToMono(buffer)
        }

        if self.converter == nil || self.converterSourceFormat != sourceFormat {
            guard let intermediateFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: self.canonicalFormat.sampleRate,
                channels: sourceFormat.channelCount,
                interleaved: false
            ), let converter = AVAudioConverter(from: sourceFormat, to: intermediateFormat) else {
                return nil
            }
            self.converter = converter
            self.converterSourceFormat = sourceFormat
        }
        guard let converter = self.converter else { return nil }

        let ratio = self.canonicalFormat.sampleRate / sourceFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: estimatedFrames) else { return nil }

        var conversionError: NSError?
        var consumed = false
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil else { return nil }
        return Self.downmixToMono(output)
    }

    private static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channels {
            vDSP_vadd(channelData[channel], 1, mono, 1, &mono, 1, vDSP_Length(frameCount))
        }
        var divisor = Float(channels)
        vDSP_vsdiv(mono, 1, &divisor, &mono, 1, vDSP_Length(frameCount))
        return mono
    }

    /// Doubles as the dropped-HAL-buffer detector via `sampleTime` deltas (plan rev #22).
    private func checkSequenceContinuity(time: AVAudioTime, frameCount: Int) {
        guard time.isSampleTimeValid else { return }
        if let expected = self.lastExpectedSampleTime, time.sampleTime != expected {
            self.statsBox.mutate { $0.sequenceContinuityViolations += 1 }
        }
        self.lastExpectedSampleTime = time.sampleTime + AVAudioFramePosition(frameCount)
    }
}

// MARK: - Capture actor

/// Lifecycle only — the hot path (tap callback) never hops into the actor (plan step 7).
actor MeetingMicrophoneCapture {
    typealias Stats = MeetingMicrophoneCaptureStats.Snapshot

    private static let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
    )!
    private static let formatRetryLimit = 5
    private static let formatRetryDelayNanoseconds: UInt64 = 100_000_000
    private static let bindingOrderDescription =
        "voiceProcessingEnabled -> bindCurrentDevice -> prepare -> start (TODO(probe): hard-code the measured winner)"

    private let statsBox = MeetingMicrophoneCaptureStats()
    private let generationBox = MeetingMicrophoneGenerationBox()

    private var engine: AVAudioEngine?
    private var probePlayerNode: AVAudioPlayerNode?
    private var tapState: MeetingMicrophoneTapState?
    private var isRunning = false
    /// Non-nil from the instant a start reserves the actor until that generation is stopped or fails.
    /// This closes actor-reentrancy holes while `start()` awaits format settling/listener installation.
    private var activeGeneration: UInt64?
    private var settled: MeetingMicrophoneSettledConfig?
    private var configObserver: NSObjectProtocol?
    private var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
    private var overloadListenerToken: AudioObjectPropertyListenerBlock?
    private var overloadListenerDeviceID: AudioObjectID?

    func start(
        microphone: MeetingMicrophoneIdentity,
        authorizationPreflighted: Bool = false,
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
        onSampleMetadata: @escaping @Sendable (CMSampleBuffer, Bool, Bool) -> Void = { _, _, _ in },
        onEvent: @escaping @Sendable (MeetingMicrophoneCaptureEvent) -> Void = { _ in }
    ) async throws -> MeetingMicrophoneBindingOutcome {
        guard self.activeGeneration == nil else { throw MeetingMicrophoneCaptureError.alreadyStarted }
        let currentGeneration = self.generationBox.advance()
        self.activeGeneration = currentGeneration

        #if DEBUG
            var diagnosticsPhaseEnded = false
            AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingMicrophone, queueRole: .actorControl, phase: .handoff, generation: currentGeneration)
            AudioTopologyDiagnostics.record(.avfAuthorizationBegin, owner: .meetingMicrophone, queueRole: .actorControl, phase: .catalog, generation: currentGeneration)
            defer {
                if diagnosticsPhaseEnded == false {
                    AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingMicrophone, queueRole: .actorControl, phase: .handoff, status: -1, generation: currentGeneration)
                }
            }
        #endif
        let authorizationStatus: AVAuthorizationStatus = authorizationPreflighted
            ? .authorized
            : AVCaptureDevice.authorizationStatus(for: .audio)
        #if DEBUG
            AudioTopologyDiagnostics.record(.avfAuthorizationEnd, owner: .meetingMicrophone, queueRole: .actorControl, phase: .catalog, status: Int32(authorizationStatus.rawValue), generation: currentGeneration)
        #endif
        guard authorizationStatus == .authorized else {
            return self.fail(microphone: microphone, reason: "Microphone permission is not granted.", generation: currentGeneration)
        }

        // Missing UID means the name match already wasn't unique; retrying it is vacuous.
        guard let requestedUID = microphone.coreAudioUID, !requestedUID.isEmpty,
              let requestedDeviceID = AudioDevice.listInputDevices().first(where: { $0.uid == requestedUID })?.id
        else {
            return self.fail(microphone: microphone, reason: "No CoreAudio device UID for '\(microphone.displayName)'.", generation: currentGeneration)
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // VPIO replaces the I/O unit: enable before any format read or device bind.
        #if DEBUG
            AudioTopologyDiagnostics.record(.vpioEnableBegin, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .vpio, generation: currentGeneration)
        #endif
        do {
            try input.setVoiceProcessingEnabled(true)
            #if DEBUG
                AudioTopologyDiagnostics.record(.vpioEnableEnd, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .vpio, status: noErr, generation: currentGeneration)
            #endif
        } catch {
            #if DEBUG
                AudioTopologyDiagnostics.record(.vpioEnableEnd, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .vpio, status: -1, generation: currentGeneration)
            #endif
            return self.fail(microphone: microphone, reason: "Voice processing could not be enabled: \(error.localizedDescription)", generation: currentGeneration)
        }
        var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
        ducking.enableAdvancedDucking = false
        ducking.duckingLevel = .min
        input.voiceProcessingOtherAudioDuckingConfiguration = ducking

        guard let audioUnit = input.audioUnit else {
            return self.fail(microphone: microphone, reason: "AVAudioEngine.inputNode has no backing AudioUnit.", generation: currentGeneration)
        }

        // TODO(probe): bind order is a Phase-1 measurement; this hard-codes one attempt.
        #if DEBUG
            AudioTopologyDiagnostics.record(.audioUnitBindBegin, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .vpio, generation: currentGeneration)
        #endif
        let bindStatus = Self.bindInputDevice(audioUnit, to: requestedDeviceID)
        #if DEBUG
            AudioTopologyDiagnostics.record(.audioUnitBindEnd, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .vpio, status: bindStatus, generation: currentGeneration)
        #endif

        // Tap before start(): added afterwards it sits on an inactive node — measured as
        // 10 minutes of zero callbacks with healthy telemetry.
        let preStartFormat = input.outputFormat(forBus: 0)
        guard preStartFormat.sampleRate > 0, preStartFormat.channelCount > 0 else {
            return self.fail(microphone: microphone, reason: "Input format invalid before start (\(preStartFormat)).", generation: currentGeneration)
        }
        let tapState = MeetingMicrophoneTapState(
            statsBox: self.statsBox,
            canonicalFormat: Self.canonicalFormat,
            onSample: onSample,
            onSampleMetadata: onSampleMetadata
        )
        self.tapState = tapState
        let generationBox = self.generationBox
        input.installTap(onBus: 0, bufferSize: 4_800, format: preStartFormat) { buffer, time in
            guard generationBox.isCurrent(currentGeneration) else { return }
            tapState.handle(buffer: buffer, time: time)
        }

        #if DEBUG
            AudioTopologyDiagnostics.record(.enginePrepareBegin, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .engine, generation: currentGeneration)
        #endif
        engine.prepare()
        #if DEBUG
            AudioTopologyDiagnostics.record(.enginePrepareEnd, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .engine, status: noErr, generation: currentGeneration)
        #endif
        #if DEBUG
            AudioTopologyDiagnostics.record(.engineStartBegin, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .engine, generation: currentGeneration)
        #endif
        do {
            try engine.start()
            #if DEBUG
                AudioTopologyDiagnostics.record(.engineStartEnd, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .engine, status: noErr, generation: currentGeneration)
            #endif
        } catch {
            #if DEBUG
                AudioTopologyDiagnostics.record(.engineStartEnd, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .engine, status: -1, generation: currentGeneration)
            #endif
            input.removeTap(onBus: 0)
            return self.fail(microphone: microphone, reason: "AVAudioEngine failed to start: \(error.localizedDescription)", generation: currentGeneration)
        }

        let outcome = MeetingMicrophoneBindDecision.outcome(
            bindStatus: bindStatus,
            readBackDeviceID: Self.readBackBoundDevice(audioUnit),
            requestedDeviceID: requestedDeviceID,
            defaultInputUID: AudioDevice.getDefaultInputDevice()?.uid,
            requestedUID: requestedUID
        )
        if case let .unavailable(reason) = outcome {
            input.removeTap(onBus: 0)
            engine.stop()
            return self.fail(microphone: microphone, reason: reason, generation: currentGeneration)
        }

        // Publish the generation-owned resources before the first suspension so `stop()` can
        // atomically detach and terminate this exact engine if it interleaves with startup.
        self.engine = engine
        self.isRunning = true
        guard let sourceFormat = await self.validatedInputFormat(input: input) else {
            guard self.ownsGeneration(currentGeneration, engine: engine) else {
                throw MeetingMicrophoneCaptureError.lifecycleInterrupted
            }
            if Task.isCancelled {
                await self.abortStartGeneration(currentGeneration, engine: engine)
                throw MeetingMicrophoneCaptureError.lifecycleInterrupted
            }
            input.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
            self.tapState = nil
            self.isRunning = false
            return self.fail(microphone: microphone, reason: "Input format never became valid (persistent 0 Hz).", generation: currentGeneration)
        }
        guard !Task.isCancelled, self.ownsGeneration(currentGeneration, engine: engine) else {
            if self.ownsGeneration(currentGeneration, engine: engine) {
                await self.abortStartGeneration(currentGeneration, engine: engine)
            }
            throw MeetingMicrophoneCaptureError.lifecycleInterrupted
        }
        if sourceFormat != preStartFormat {
            // Post-start renegotiation (HAL settling): reattach at the settled format.
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4_800, format: sourceFormat) { buffer, time in
                guard generationBox.isCurrent(currentGeneration) else { return }
                tapState.handle(buffer: buffer, time: time)
            }
        }

        self.settled = MeetingMicrophoneSettledConfig(
            requestedMicrophone: microphone,
            bindingOutcome: outcome,
            bindingOrder: Self.bindingOrderDescription,
            settledInputDeviceUID: requestedUID,
            settledOutputDeviceUID: AudioDevice.getDefaultOutputDevice()?.uid,
            sourceSampleRate: sourceFormat.sampleRate,
            sourceChannelCount: Int(sourceFormat.channelCount),
            voiceProcessingEnabled: true,
            outputChannelDecision: "mono (explicit downmix); observed ch=1 on today's SCStream mic, not derived from SCStream's stereo capture config"
        )
        await self.registerEventObservers(
            engine: engine,
            outcome: outcome,
            requestedDeviceID: requestedDeviceID,
            generation: currentGeneration,
            onEvent: onEvent
        )
        guard !Task.isCancelled, self.ownsGeneration(currentGeneration, engine: engine) else {
            if self.ownsGeneration(currentGeneration, engine: engine) {
                await self.abortStartGeneration(currentGeneration, engine: engine)
            }
            throw MeetingMicrophoneCaptureError.lifecycleInterrupted
        }
        #if DEBUG
            AudioTopologyDiagnostics.record(.readiness, owner: .meetingMicrophone, objectID: requestedDeviceID, queueRole: .actorControl, phase: .engine, status: noErr, generation: currentGeneration)
            AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingMicrophone, queueRole: .actorControl, phase: .handoff, status: noErr, generation: currentGeneration)
            diagnosticsPhaseEnded = true
        #endif
        return outcome
    }

    func stop() async {
        await self.stop(teardownVoiceProcessingUnit: true)
    }

    /// DEBUG diagnostic teardown that leaves the VPIO unit to process-boundary cleanup. This is
    /// used only by isolated acoustic probes because explicit unit replacement can crash on some
    /// macOS 26 audio stacks after a live output read-back.
#if DEBUG
    func stopForPhase1Probe() async {
        await self.stop(teardownVoiceProcessingUnit: false)
    }
#endif

    private func stop(teardownVoiceProcessingUnit: Bool) async {
        guard self.activeGeneration != nil else { return }
        self.isRunning = false
        let stopGeneration = self.generationBox.advance()
        self.activeGeneration = nil

        // Snapshot and detach every generation-owned reference before the first await. A new start
        // may legally enter while listener removal is suspended and must remain completely isolated.
        let oldEngine = self.engine
        let oldProbePlayerNode = self.probePlayerNode
        let oldConfigObserver = self.configObserver
        let oldDefaultInputListenerToken = self.defaultInputListenerToken
        let oldOverloadListenerToken = self.overloadListenerToken
        let oldOverloadListenerDeviceID = self.overloadListenerDeviceID
        self.engine = nil
        self.probePlayerNode = nil
        self.tapState = nil
        self.configObserver = nil
        self.defaultInputListenerToken = nil
        self.overloadListenerToken = nil
        self.overloadListenerDeviceID = nil

        if let oldConfigObserver {
            NotificationCenter.default.removeObserver(oldConfigObserver)
        }
        if let oldEngine {
            oldProbePlayerNode?.stop()
            if let oldProbePlayerNode {
                // A probe player can still be attached while its playback continuation is
                // unwinding. Remove it from the graph before stopping the old engine so a new
                // generation cannot inherit a stale render connection.
                oldEngine.disconnectNodeOutput(oldProbePlayerNode)
                oldEngine.detach(oldProbePlayerNode)
            }
            oldEngine.inputNode.removeTap(onBus: 0)
            #if DEBUG
                AudioTopologyDiagnostics.record(.engineStopBegin, owner: .meetingMicrophone, queueRole: .actorControl, phase: .engine, generation: stopGeneration)
            #endif
            oldEngine.stop()
            // Explicitly tear down the VPIO Audio Unit. Relying on AVAudioEngine
            // deallocation leaves device ownership to ARC timing and can overlap a
            // subsequent AVCaptureSession construction during route recovery.
            if teardownVoiceProcessingUnit {
                try? oldEngine.inputNode.setVoiceProcessingEnabled(false)
            }
            #if DEBUG
                AudioTopologyDiagnostics.record(.engineStopEnd, owner: .meetingMicrophone, queueRole: .actorControl, phase: .engine, status: noErr, generation: stopGeneration)
            #endif
        }
        await Self.removeEventObservers(
            defaultInputToken: oldDefaultInputListenerToken,
            overloadToken: oldOverloadListenerToken,
            overloadDeviceID: oldOverloadListenerDeviceID,
            generation: stopGeneration
        )
    }

    /// Fire-and-forget, bounded teardown. `onComplete(false)` means the supervision window elapsed first.
    nonisolated func stopDetachedSupervised(seconds: Double, onComplete: @escaping @Sendable (Bool) -> Void) {
        Task {
            let completed = await MeetingSupervisedTimeout.run(seconds: seconds) {
                await self.stop()
                return true
            }
            onComplete(completed == true)
        }
    }

    func statistics() -> Stats {
        self.statsBox.snapshot()
    }

    func settledConfiguration() -> MeetingMicrophoneSettledConfig? {
        self.settled
    }

    /// Snapshot VPIO state only while the generation is live. Returning `nil` after teardown
    /// prevents a deceptively successful read from an Audio Unit that no longer owns a device.
    func voiceProcessingProbeReadback() -> MeetingVoiceProcessingProbeSnapshot? {
        guard self.isRunning, let engine = self.engine else { return nil }
        let input = engine.inputNode
        let output = engine.outputNode
        guard let audioUnit = input.audioUnit else { return nil }

        let ducking = input.voiceProcessingOtherAudioDuckingConfiguration
        return MeetingVoiceProcessingProbeSnapshot(
            schemaVersion: MeetingVoiceProcessingProbeSnapshot.currentSchemaVersion,
            engineRunning: engine.isRunning,
            nodeVoiceProcessingEnabled: input.isVoiceProcessingEnabled,
            nodeVoiceProcessingBypassed: input.isVoiceProcessingBypassed,
            nodeVoiceProcessingAGCEnabled: input.isVoiceProcessingAGCEnabled,
            nodeVoiceProcessingInputMuted: input.isVoiceProcessingInputMuted,
            nodeAdvancedDuckingEnabled: ducking.enableAdvancedDucking.boolValue,
            nodeDuckingLevelRawValue: ducking.duckingLevel.rawValue,
            inputPresentationLatencySeconds: input.presentationLatency,
            outputPresentationLatencySeconds: output.presentationLatency,
            inputNodeInputFormat: MeetingAudioFormatProbeReadback(input.inputFormat(forBus: 0)),
            inputNodeOutputFormat: MeetingAudioFormatProbeReadback(input.outputFormat(forBus: 0)),
            outputNodeInputFormat: MeetingAudioFormatProbeReadback(output.inputFormat(forBus: 0)),
            outputNodeOutputFormat: MeetingAudioFormatProbeReadback(output.outputFormat(forBus: 0)),
            inputNodeLastRenderTime: MeetingAudioTimeProbeReadback(input.lastRenderTime),
            outputNodeLastRenderTime: MeetingAudioTimeProbeReadback(output.lastRenderTime),
            inputNodeOutputConnectionCount: engine.outputConnectionPoints(for: input, outputBus: 0).count,
            inputCurrentDevice: Self.readUInt32(
                audioUnit,
                propertyID: kAudioOutputUnitProperty_CurrentDevice,
                scope: kAudioUnitScope_Global,
                element: Self.inputElement
            ),
            outputCurrentDevice: Self.readUInt32(
                audioUnit,
                propertyID: kAudioOutputUnitProperty_CurrentDevice,
                scope: kAudioUnitScope_Global,
                element: Self.outputElement
            ),
            bypassVoiceProcessing: Self.readUInt32(
                audioUnit,
                propertyID: kAUVoiceIOProperty_BypassVoiceProcessing,
                scope: kAudioUnitScope_Global,
                element: 0
            ),
            voiceProcessingAGCEnabled: Self.readUInt32(
                audioUnit,
                propertyID: kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                scope: kAudioUnitScope_Global,
                element: 0
            ),
            voiceProcessingOutputMuted: Self.readUInt32(
                audioUnit,
                propertyID: kAUVoiceIOProperty_MuteOutput,
                scope: kAudioUnitScope_Global,
                element: 0
            ),
            otherAudioDucking: Self.readDuckingConfiguration(
                audioUnit,
                propertyID: kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                scope: kAudioUnitScope_Global,
                element: 0
            )
        )
    }

#if DEBUG
    /// Read-only safety check for the local Trial B render. The system volume is never changed;
    /// unsupported or unexpectedly loud routes are reported as numeric refusal reasons.
    func acousticOutputPreflight(samplePeak: Double, volume: Float) -> MeetingVPIOAcousticOutputPreflight {
        guard self.isRunning, let engine = self.engine else {
            return MeetingVPIOAcousticOutputPreflight(
                outputConnectionCount: 0,
                outputDeviceID: nil,
                defaultOutputDeviceID: nil,
                outputRouteConfirmed: false,
                systemVolume: nil,
                outputVolumeReadable: false,
                combinedPeak: nil,
                reasons: [.captureNotRunning, .outputRouteUnavailable]
            )
        }

        let mixer = engine.mainMixerNode
        let outputConnectionCount = engine.outputConnectionPoints(for: mixer, outputBus: 0).count
        let snapshot = self.voiceProcessingProbeReadback()
        let outputDeviceID = snapshot?.outputCurrentDevice.value
        let defaultOutputDeviceID = AudioDevice.getDefaultOutputDevice()?.id
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let routeSnapshot = MeetingCaptureEngine.currentOutputRouteSnapshot()
        let routePolicyConfirmed = MeetingCapturePathDecider.outputRouteDeclineReason(routeSnapshot) == nil
        let routeConfirmed = engine.isRunning
            && outputConnectionCount > 0
            && outputFormat.sampleRate.isFinite
            && outputFormat.sampleRate > 0
            && outputFormat.channelCount > 0
            && outputDeviceID == defaultOutputDeviceID
            && outputDeviceID.map { $0 != kAudioObjectUnknown } == true
            && outputDeviceID.map(Self.isProbeOutputDeviceAlive) == true
            && routeSnapshot.deviceExists
            && routeSnapshot.isBuiltIn
            && !routeSnapshot.isBluetooth
            && !routeSnapshot.isHeadphonesDataSource
            && !routeSnapshot.terminalTypes.contains(kAudioStreamTerminalTypeHeadphones)
            && routePolicyConfirmed

        var reasons: [MeetingVPIOAcousticReason] = []
        if routeConfirmed == false { reasons.append(.outputRouteUnavailable) }

        let outputVolume = outputDeviceID.flatMap(Self.readProbeOutputVolume)
        let outputVolumeReadable = outputVolume.map { $0.isFinite && (0...1).contains($0) } == true
        if outputVolumeReadable == false { reasons.append(.outputVolumeUnreadable) }

        let safeDigitalPeak = samplePeak.isFinite && samplePeak >= 0 ? samplePeak : 0
        let safePlayerVolume = volume.isFinite ? min(max(Double(volume), 0), Double(MeetingVPIOAcousticStimulus.maximumRenderVolume)) : 0
        let combinedPeak = outputVolume.map { safeDigitalPeak * safePlayerVolume * Double($0) }
        if let outputVolume,
           Double(outputVolume) <= 0 || Double(outputVolume) > MeetingVPIOAcousticGate.maximumSystemVolume {
            reasons.append(.outputLevelUnsafe)
        }
        if let combinedPeak, combinedPeak > MeetingVPIOAcousticGate.maximumCombinedPeak {
            reasons.append(.outputLevelUnsafe)
        }

        return MeetingVPIOAcousticOutputPreflight(
            outputConnectionCount: outputConnectionCount,
            outputDeviceID: outputDeviceID,
            defaultOutputDeviceID: defaultOutputDeviceID,
            outputRouteConfirmed: routeConfirmed,
            systemVolume: outputVolume.map(Double.init),
            outputVolumeReadable: outputVolumeReadable,
            combinedPeak: combinedPeak,
            reasons: reasons.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private static func isProbeOutputDeviceAlive(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    private static func readProbeOutputVolume(_ deviceID: AudioObjectID) -> Float32? {
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyVolumeScalar,
        ]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
            if status == noErr, volume.isFinite, (0...1).contains(volume) { return volume }
        }
        return nil
    }
#endif

    /// Probe-only mutation. The environment gate prevents production callers from changing VPIO
    /// processing state through this diagnostic surface.
#if DEBUG
    func setVoiceProcessingBypassedForProbe(_ bypassed: Bool) -> Bool? {
        guard MeetingVPIOAcousticGate.isEnabled else {
            return nil
        }
        guard self.isRunning, let input = self.engine?.inputNode else { return nil }
        input.isVoiceProcessingBypassed = bypassed
        return input.isVoiceProcessingBypassed
    }

    /// Probe-only AGC mutation.  The getter is public on supported AVFAudio releases; if a
    /// platform rejects the setter, the caller records the read-back and continues the trial as
    /// an unsupported variant rather than changing production defaults.
    func setVoiceProcessingAGCEnabledForProbe(_ enabled: Bool) -> Bool? {
        guard MeetingVPIOAcousticGate.isEnabled else { return nil }
        guard self.isRunning, let input = self.engine?.inputNode else { return nil }
        input.isVoiceProcessingAGCEnabled = enabled
        return input.isVoiceProcessingAGCEnabled
    }
#else
    func setVoiceProcessingBypassedForProbe(_ bypassed: Bool) -> Bool? { nil }
    func setVoiceProcessingAGCEnabledForProbe(_ enabled: Bool) -> Bool? { nil }
#endif

    /// Render known local PCM through this same VPIO engine. This is Trial B only; it cannot route
    /// another application's audio and is never reachable without the acoustic-probe environment.
#if DEBUG
    func playVoiceProcessingProbePCM(
        _ samples: [Float],
        sampleRate: Double,
        volume: Float
    ) async throws -> MeetingVPIOAcousticRenderConfirmation {
        guard MeetingVPIOAcousticGate.isEnabled else {
            throw MeetingVoiceProcessingProbeError.disabled
        }
        guard self.isRunning, let engine = self.engine else {
            throw MeetingVoiceProcessingProbeError.captureNotRunning
        }
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 0 else {
            throw MeetingVoiceProcessingProbeError.invalidPlaybackFormat
        }

        var samplePeak = 0.0
        var hasNonFiniteSample = false
        for sample in samples {
            let value = Double(sample)
            if value.isFinite {
                samplePeak = max(samplePeak, abs(value))
            } else {
                hasNonFiniteSample = true
            }
        }

        let safeVolume = min(
            max(volume.isFinite ? volume : 0, 0),
            MeetingVPIOAcousticStimulus.maximumRenderVolume
        )
        var outputPreflight = await self.acousticOutputPreflight(
            samplePeak: samplePeak,
            volume: safeVolume
        )
        if hasNonFiniteSample || samplePeak > Double(MeetingVPIOAcousticStimulus.safetyPeakLimit) || samplePeak <= 0 {
            outputPreflight.reasons.append(.stimulusOutsideSafetyBounds)
        }
        let tapCollector = MeetingVPIOAcousticRenderTapCollector()
        guard outputPreflight.isSafe else {
            return tapCollector.report(
                scheduledFrameCount: samples.count,
                sampleRate: sampleRate,
                volume: safeVolume,
                outputPreflight: outputPreflight
            )
        }
        guard let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else {
            throw MeetingVoiceProcessingProbeError.invalidPlaybackFormat
        }
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        let mixer = engine.mainMixerNode
        var tapInstalled = false
        var playerAttached = false
        var playerConnected = false
        var player: AVAudioPlayerNode?
        defer {
            player?.stop()
            if let player {
                if playerConnected { engine.disconnectNodeOutput(player) }
                if playerAttached { engine.detach(player) }
                if self.probePlayerNode === player { self.probePlayerNode = nil }
            }
            if tapInstalled { mixer.removeTap(onBus: 0) }
        }
        mixer.installTap(onBus: 0, bufferSize: 4_800, format: nil) { buffer, time in
            tapCollector.ingest(buffer: buffer, time: time)
        }
        tapInstalled = true
        let newPlayer = AVAudioPlayerNode()
        player = newPlayer
        self.probePlayerNode = newPlayer
        engine.attach(newPlayer)
        playerAttached = true
        engine.connect(newPlayer, to: mixer, format: format)
        playerConnected = true
        newPlayer.volume = safeVolume

        let playbackContinuation = MeetingVPIOAcousticPlaybackContinuation()
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            playbackContinuation.timeout()
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                playbackContinuation.install(continuation)
                guard !Task.isCancelled else {
                    playbackContinuation.cancel()
                    return
                }
                newPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                    playbackContinuation.finish()
                }
                newPlayer.play()
            }
        }, onCancel: {
            playbackContinuation.cancel()
        })

        // Read the output topology while the player is still attached. Detaching first can make a
        // successful render appear disconnected and destroys the evidence needed by the report.
        let outputConnectionCount = engine.outputConnectionPoints(for: mixer, outputBus: 0).count
        outputPreflight.outputConnectionCount = outputConnectionCount
        if outputConnectionCount <= 0, outputPreflight.reasons.contains(.outputRouteUnavailable) == false {
            outputPreflight.outputRouteConfirmed = false
            outputPreflight.reasons.append(.outputRouteUnavailable)
        }
        if tapInstalled {
            mixer.removeTap(onBus: 0)
            tapInstalled = false
        }
        let report = tapCollector.report(
            scheduledFrameCount: samples.count,
            sampleRate: sampleRate,
            volume: safeVolume,
            outputPreflight: outputPreflight
        )
        return report
    }
#else
    func playVoiceProcessingProbePCM(
        _ samples: [Float],
        sampleRate: Double,
        volume: Float
    ) async throws {
        throw MeetingVoiceProcessingProbeError.disabled
    }
#endif

    private func ownsGeneration(_ generation: UInt64, engine: AVAudioEngine) -> Bool {
        self.activeGeneration == generation
            && self.generationBox.isCurrent(generation)
            && self.engine === engine
            && self.isRunning
    }

    /// Abort only the generation that published this engine. This is used by cancellation and
    /// post-publication startup failures; calling the general stop path here could accidentally
    /// tear down a newer generation after actor reentrancy.
    private func abortStartGeneration(_ generation: UInt64, engine: AVAudioEngine) async {
        guard self.activeGeneration == generation,
              self.generationBox.isCurrent(generation),
              self.engine === engine
        else { return }

        self.isRunning = false
        _ = self.generationBox.advance()
        self.activeGeneration = nil
        let oldConfigObserver = self.configObserver
        let oldDefaultInputListenerToken = self.defaultInputListenerToken
        let oldOverloadListenerToken = self.overloadListenerToken
        let oldOverloadListenerDeviceID = self.overloadListenerDeviceID
        self.engine = nil
        self.probePlayerNode = nil
        self.tapState = nil
        self.configObserver = nil
        self.defaultInputListenerToken = nil
        self.overloadListenerToken = nil
        self.overloadListenerDeviceID = nil

        if let oldConfigObserver { NotificationCenter.default.removeObserver(oldConfigObserver) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        await Self.removeEventObservers(
            defaultInputToken: oldDefaultInputListenerToken,
            overloadToken: oldOverloadListenerToken,
            overloadDeviceID: oldOverloadListenerDeviceID,
            generation: generation
        )
    }

    private func fail(
        microphone: MeetingMicrophoneIdentity,
        reason: String,
        generation: UInt64
    ) -> MeetingMicrophoneBindingOutcome {
        if self.activeGeneration == generation, self.generationBox.isCurrent(generation) {
            self.activeGeneration = nil
            self.isRunning = false
            self.engine = nil
            self.tapState = nil
        }
        let outcome = MeetingMicrophoneBindingOutcome.unavailable(reason: reason)
        self.settled = MeetingMicrophoneSettledConfig(
            requestedMicrophone: microphone,
            bindingOutcome: outcome,
            bindingOrder: Self.bindingOrderDescription,
            settledInputDeviceUID: nil,
            settledOutputDeviceUID: AudioDevice.getDefaultOutputDevice()?.uid,
            sourceSampleRate: 0,
            sourceChannelCount: 0,
            voiceProcessingEnabled: false,
            outputChannelDecision: "mono (explicit downmix)"
        )
        return outcome
    }

    /// Mirrors `ASRService.swift:2797-2827`: the HAL can report 0 Hz even after `start()` returns.
    private func validatedInputFormat(input: AVAudioInputNode) async -> AVAudioFormat? {
        var format = input.outputFormat(forBus: 0)
        var attempt = 0
        while format.sampleRate == 0 || format.channelCount == 0 {
            attempt += 1
            if attempt > Self.formatRetryLimit { return nil }
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: Self.formatRetryDelayNanoseconds)
            if Task.isCancelled { return nil }
            format = input.outputFormat(forBus: 0)
        }
        return format
    }

    private func registerEventObservers(
        engine: AVAudioEngine,
        outcome: MeetingMicrophoneBindingOutcome,
        requestedDeviceID: AudioObjectID,
        generation: UInt64,
        onEvent: @escaping @Sendable (MeetingMicrophoneCaptureEvent) -> Void
    ) async {
        let statsBox = self.statsBox
        let generationBox = self.generationBox
        // queue: nil — see ASRService.registerEngineConfigurationChangeObserver for why synchronous
        // delivery is load-bearing (avoids a deadlock against the engine's own serial queue).
        self.configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak tapState = self.tapState] _ in
            guard generationBox.isCurrent(generation) else { return }
            statsBox.mutate { $0.configurationChangeEvents += 1 }
            tapState?.requestTimelineReset()
            onEvent(.configurationChanged)
        }

        if case .defaultMatchesRequested = outcome {
            let address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let token: AudioObjectPropertyListenerBlock = { _, _ in
                #if DEBUG
                    AudioTopologyDiagnostics.record(.callbackBegin, owner: .meetingMicrophone, objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .callbackCurrent, generation: generation)
                    defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .meetingMicrophone, objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .callbackCurrent, generation: generation) }
                #endif
                MeetingMicrophoneEventExecution.afterHALCallback {
                    guard generationBox.isCurrent(generation) else { return }
                    statsBox.mutate { $0.defaultInputChangeEvents += 1 }
                    onEvent(.defaultInputChanged)
                }
            }
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .meetingMicrophone, objectID: AudioObjectID(kAudioObjectSystemObject), selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .actorControl, phase: .listener)
            #endif
            let status = await AudioTopologyListenerExecution.add(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: address,
                token: token
            )
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .meetingMicrophone, objectID: AudioObjectID(kAudioObjectSystemObject), selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .actorControl, phase: .listener, status: status)
            #endif
            if status == noErr, self.isRunning, self.generationBox.isCurrent(generation) {
                self.defaultInputListenerToken = token
            } else if status == noErr {
                _ = await AudioTopologyListenerExecution.remove(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    address: address,
                    token: token
                )
            }
        }

        if case .boundVerified = outcome, self.isRunning, self.generationBox.isCurrent(generation) {
            let address = AudioObjectPropertyAddress(
                mSelector: kAudioDeviceProcessorOverload,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let token: AudioObjectPropertyListenerBlock = { _, _ in
                #if DEBUG
                    AudioTopologyDiagnostics.record(.callbackBegin, owner: .meetingMicrophone, objectID: requestedDeviceID, selector: kAudioDeviceProcessorOverload, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .callbackCurrent, generation: generation)
                    defer { AudioTopologyDiagnostics.record(.callbackEnd, owner: .meetingMicrophone, objectID: requestedDeviceID, selector: kAudioDeviceProcessorOverload, scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain, queueRole: .callbackCurrent, generation: generation) }
                #endif
                MeetingMicrophoneEventExecution.afterHALCallback {
                    guard generationBox.isCurrent(generation) else { return }
                    statsBox.mutate { $0.overloadCount += 1 }
                    onEvent(.overload)
                }
            }
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerAddBegin, owner: .meetingMicrophone, objectID: requestedDeviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .actorControl, phase: .listener)
            #endif
            let status = await AudioTopologyListenerExecution.add(
                objectID: requestedDeviceID,
                address: address,
                token: token
            )
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerAddEnd, owner: .meetingMicrophone, objectID: requestedDeviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .actorControl, phase: .listener, status: status)
            #endif
            if status == noErr, self.isRunning, self.generationBox.isCurrent(generation) {
                self.overloadListenerToken = token
                self.overloadListenerDeviceID = requestedDeviceID
            } else if status == noErr {
                _ = await AudioTopologyListenerExecution.remove(
                    objectID: requestedDeviceID,
                    address: address,
                    token: token
                )
            }
        }
    }

    private static func removeEventObservers(
        defaultInputToken: AudioObjectPropertyListenerBlock?,
        overloadToken: AudioObjectPropertyListenerBlock?,
        overloadDeviceID: AudioObjectID?,
        generation: UInt64
    ) async {
        if let token = defaultInputToken {
            let address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .meetingMicrophone, objectID: AudioObjectID(kAudioObjectSystemObject), selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .actorControl, phase: .listener)
            #endif
            let status = await AudioTopologyListenerExecution.remove(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: address,
                token: token
            )
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .meetingMicrophone, objectID: AudioObjectID(kAudioObjectSystemObject), selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .actorControl, phase: .listener, status: status)
            #endif
        }
        if let token = overloadToken, let deviceID = overloadDeviceID {
            let address = AudioObjectPropertyAddress(
                mSelector: kAudioDeviceProcessorOverload,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveBegin, owner: .meetingMicrophone, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .actorControl, phase: .listener)
            #endif
            let status = await AudioTopologyListenerExecution.remove(
                objectID: deviceID,
                address: address,
                token: token
            )
            #if DEBUG
                AudioTopologyDiagnostics.record(.listenerRemoveEnd, owner: .meetingMicrophone, objectID: deviceID, selector: address.mSelector, scope: address.mScope, element: address.mElement, queueRole: .actorControl, phase: .listener, status: status)
            #endif
        }
    }

    /// Element 1 is the input side; element 0 would set/read the OUTPUT device (measured: read-back
    /// returned the AirPods output against a requested built-in mic).
    private static let inputElement: AudioUnitElement = 1
    private static let outputElement: AudioUnitElement = 0

    private static func bindInputDevice(_ audioUnit: AudioUnit, to deviceID: AudioObjectID) -> OSStatus {
        var mutableDeviceID = deviceID
        return AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            Self.inputElement,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
    }

    private static func readBackBoundDevice(_ audioUnit: AudioUnit) -> AudioObjectID? {
        Self.currentDevice(audioUnit, element: Self.inputElement)
    }

    static func currentDevice(_ audioUnit: AudioUnit, element: AudioUnitElement) -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            element,
            &deviceID,
            &size
        )
        return status == noErr ? deviceID : nil
    }

    private static func readUInt32(
        _ audioUnit: AudioUnit,
        propertyID: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement
    ) -> MeetingAudioUnitUInt32Readback {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(audioUnit, propertyID, scope, element, &value, &size)
        return MeetingAudioUnitUInt32Readback(
            propertyID: propertyID,
            scope: scope,
            element: element,
            status: status,
            value: value
        )
    }

    private static func readDuckingConfiguration(
        _ audioUnit: AudioUnit,
        propertyID: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement
    ) -> MeetingAudioUnitDuckingReadback {
        var value = AUVoiceIOOtherAudioDuckingConfiguration()
        var size = UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size)
        let status = AudioUnitGetProperty(audioUnit, propertyID, scope, element, &value, &size)
        return MeetingAudioUnitDuckingReadback(
            propertyID: propertyID,
            scope: scope,
            element: element,
            status: status,
            advancedDuckingEnabled: value.mEnableAdvancedDucking.boolValue,
            duckingLevelRawValue: UInt32(value.mDuckingLevel.rawValue)
        )
    }
}

// MARK: - Opt-in hardware probe

/// Real-hardware Phase 1 gate (plan §9), foreground only; env FLUIDVOICE_MIC_PHASE1[_DEVICE].
enum MeetingMicrophonePhase1Probe {
    struct Result: Sendable {
        var minutes: Double
        var outcome: MeetingMicrophoneBindingOutcome
        var settled: MeetingMicrophoneSettledConfig?
        var voiceProcessingReadback: MeetingVoiceProcessingProbeSnapshot?
#if DEBUG
        var acousticTrialB: MeetingVPIOAcousticTrialBReport?
#endif
        var stats: MeetingMicrophoneCaptureStats.Snapshot
        var writerDiscontinuities: Int
        var writerRotationCount: Int
        var writerBackpressureEvents: Int
        var finalHealthStatus: MeetingTrackHealthStatus
        var liveCopyNilCount: Int
        var deliveredSourceFormat: String
        var peakAmplitude: Float
    }

    static func run(sessionDirectory: URL) async throws -> Result? {
        guard let minutesString = ProcessInfo.processInfo.environment["FLUIDVOICE_MIC_PHASE1"],
              let minutes = Double(minutesString), minutes > 0
        else { return nil }

        let microphone: MeetingMicrophoneIdentity
        if let overrideUID = ProcessInfo.processInfo.environment["FLUIDVOICE_MIC_PHASE1_DEVICE"] {
            microphone = try await MeetingCaptureSourceCatalog.defaultMicrophone(preferredCoreAudioUID: overrideUID)
        } else {
            microphone = try await MeetingCaptureSourceCatalog.defaultMicrophone()
        }

        let writerBackpressureEventsBox = OSAllocatedUnfairLock(initialState: 0)
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: microphone.captureDeviceID,
            sourceDisplayName: microphone.displayName,
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: mach_absolute_time(),
                machTimebaseNumerator: {
                    var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info.numer
                }(),
                machTimebaseDenominator: {
                    var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info.denom
                }(),
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: []
        )
        let writer = try MeetingAudioChunkWriter(
            track: track,
            sessionDirectory: sessionDirectory,
            chunkDuration: MeetingCaptureConfiguration.defaultChunkDuration
        ) { event in
            if case .interrupted(.writerBackpressure, _, _) = event {
                writerBackpressureEventsBox.withLock { $0 += 1 }
            }
        }

        var deliveredSourceFormat = "(none delivered)"
        let capturedFormat = OSAllocatedUnfairLock<String?>(initialState: nil)
        let tapTelemetry = OSAllocatedUnfairLock<(nilCopies: Int, peak: Float)>(initialState: (0, 0))
#if DEBUG
        let acousticCollector = MeetingVPIOAcousticCaptureCollector()
#endif

        let capture = MeetingMicrophoneCapture()
        let outcome: MeetingMicrophoneBindingOutcome
        do {
            outcome = try await capture.start(
                microphone: microphone,
                onSample: { sampleBuffer in
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
            {
                capturedFormat.withLock { $0 = "\(asbd.mSampleRate)Hz \(asbd.mChannelsPerFrame)ch" }
            }
            let copied = MeetingLiveSampleCopy.copy(sampleBuffer)
            let bufferPeak: Float = copied.flatMap { sample -> Float? in
                guard let channel = sample.buffer.floatChannelData?[0] else { return nil }
                var peak: Float = 0
                vDSP_maxmgv(channel, 1, &peak, vDSP_Length(sample.buffer.frameLength))
                return peak
            } ?? 0
            tapTelemetry.withLock {
                if copied == nil { $0.nilCopies += 1 }
                $0.peak = max($0.peak, bufferPeak)
            }
            writer.enqueue(sampleBuffer)
                },
                onSampleMetadata: { sampleBuffer, synthesized, resynced in
#if DEBUG
                    acousticCollector.ingest(sampleBuffer, synthesized: synthesized, resynced: resynced)
                #else
                    _ = (sampleBuffer, synthesized, resynced)
                #endif
                }
            )
        } catch {
            _ = await writer.stop()
            throw error
        }

#if DEBUG
        let acousticTrialB = await MeetingVPIOAcousticTrialB.run(
            capture: capture, collector: acousticCollector, sampleRate: 48_000
        )
#endif

        do {
            try await Task.sleep(nanoseconds: UInt64(minutes * 60 * 1_000_000_000))
        } catch {
            // Cancellation after the engine was published must stop this exact generation and
            // close the writer before the probe task exits; otherwise callbacks can outlive the
            // diagnostic and retain a live input route.
#if DEBUG
            await capture.stopForPhase1Probe()
#else
            await capture.stop()
#endif
            _ = await writer.stop()
            throw error
        }
        let voiceProcessingReadback = await capture.voiceProcessingProbeReadback()
        // The app-hosted diagnostic process exits after this one test. Avoid the explicit VPIO
        // replacement during teardown here: on macOS 26.6 that replacement crashes inside
        // AVAudioIONode after a live output-node read-back. Normal product teardown is unchanged.
#if DEBUG
        await capture.stopForPhase1Probe()
#else
        await capture.stop()
#endif
        let finishedTrack = await writer.stop()
        deliveredSourceFormat = capturedFormat.withLock { $0 } ?? deliveredSourceFormat
        let telemetry = tapTelemetry.withLock { $0 }

#if DEBUG
        return Result(
            minutes: minutes,
            outcome: outcome,
            settled: await capture.settledConfiguration(),
            voiceProcessingReadback: voiceProcessingReadback,
            acousticTrialB: acousticTrialB,
            stats: await capture.statistics(),
            writerDiscontinuities: finishedTrack.chunks.reduce(0) { $0 + $1.discontinuities.count },
            writerRotationCount: finishedTrack.chunks.count,
            writerBackpressureEvents: writerBackpressureEventsBox.withLock { $0 },
            finalHealthStatus: finishedTrack.health.status,
            liveCopyNilCount: telemetry.nilCopies,
            deliveredSourceFormat: deliveredSourceFormat,
            peakAmplitude: telemetry.peak
        )
#else
        return Result(
            minutes: minutes,
            outcome: outcome,
            settled: await capture.settledConfiguration(),
            voiceProcessingReadback: voiceProcessingReadback,
            stats: await capture.statistics(),
            writerDiscontinuities: finishedTrack.chunks.reduce(0) { $0 + $1.discontinuities.count },
            writerRotationCount: finishedTrack.chunks.count,
            writerBackpressureEvents: writerBackpressureEventsBox.withLock { $0 },
            finalHealthStatus: finishedTrack.health.status,
            liveCopyNilCount: telemetry.nilCopies,
            deliveredSourceFormat: deliveredSourceFormat,
            peakAmplitude: telemetry.peak
        )
#endif
    }
}
