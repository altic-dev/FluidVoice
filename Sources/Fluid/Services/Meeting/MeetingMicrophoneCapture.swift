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

// MARK: - Capture events

nonisolated enum MeetingMicrophoneCaptureEvent: Sendable {
    case configurationChanged
    case defaultInputChanged
    case overload
    case engineStopped
}

nonisolated enum MeetingMicrophoneCaptureError: Error, Sendable {
    case alreadyStarted
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
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void
    ) {
        self.statsBox = statsBox
        self.canonicalFormat = canonicalFormat
        self.onSample = onSample
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
    private var tapState: MeetingMicrophoneTapState?
    private var isRunning = false
    private var settled: MeetingMicrophoneSettledConfig?
    private var configObserver: NSObjectProtocol?
    private var defaultInputListenerToken: AudioObjectPropertyListenerBlock?
    private var overloadListenerToken: AudioObjectPropertyListenerBlock?
    private var overloadListenerDeviceID: AudioObjectID?

    func start(
        microphone: MeetingMicrophoneIdentity,
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void,
        onEvent: @escaping @Sendable (MeetingMicrophoneCaptureEvent) -> Void = { _ in }
    ) async throws -> MeetingMicrophoneBindingOutcome {
        guard !self.isRunning else { throw MeetingMicrophoneCaptureError.alreadyStarted }
        let currentGeneration = self.generationBox.advance()

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return self.fail(microphone: microphone, reason: "Microphone permission is not granted.")
        }

        // Missing UID means the name match already wasn't unique; retrying it is vacuous.
        guard let requestedUID = microphone.coreAudioUID, !requestedUID.isEmpty,
              let requestedDeviceID = AudioDevice.listInputDevices().first(where: { $0.uid == requestedUID })?.id
        else {
            return self.fail(microphone: microphone, reason: "No CoreAudio device UID for '\(microphone.displayName)'.")
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // VPIO replaces the I/O unit: enable before any format read or device bind.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            return self.fail(microphone: microphone, reason: "Voice processing could not be enabled: \(error.localizedDescription)")
        }
        var ducking = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
        ducking.enableAdvancedDucking = false
        ducking.duckingLevel = .min
        input.voiceProcessingOtherAudioDuckingConfiguration = ducking

        guard let audioUnit = input.audioUnit else {
            return self.fail(microphone: microphone, reason: "AVAudioEngine.inputNode has no backing AudioUnit.")
        }

        // TODO(probe): bind order is a Phase-1 measurement; this hard-codes one attempt.
        let bindStatus = Self.bindInputDevice(audioUnit, to: requestedDeviceID)

        // Tap before start(): added afterwards it sits on an inactive node — measured as
        // 10 minutes of zero callbacks with healthy telemetry.
        let preStartFormat = input.outputFormat(forBus: 0)
        guard preStartFormat.sampleRate > 0, preStartFormat.channelCount > 0 else {
            return self.fail(microphone: microphone, reason: "Input format invalid before start (\(preStartFormat)).")
        }
        let tapState = MeetingMicrophoneTapState(statsBox: self.statsBox, canonicalFormat: Self.canonicalFormat, onSample: onSample)
        self.tapState = tapState
        let generationBox = self.generationBox
        input.installTap(onBus: 0, bufferSize: 4_800, format: preStartFormat) { buffer, time in
            guard generationBox.isCurrent(currentGeneration) else { return }
            tapState.handle(buffer: buffer, time: time)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return self.fail(microphone: microphone, reason: "AVAudioEngine failed to start: \(error.localizedDescription)")
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
            return self.fail(microphone: microphone, reason: reason)
        }

        guard let sourceFormat = await self.validatedInputFormat(input: input) else {
            input.removeTap(onBus: 0)
            engine.stop()
            return self.fail(microphone: microphone, reason: "Input format never became valid (persistent 0 Hz).")
        }
        if sourceFormat != preStartFormat {
            // Post-start renegotiation (HAL settling): reattach at the settled format.
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4_800, format: sourceFormat) { buffer, time in
                guard generationBox.isCurrent(currentGeneration) else { return }
                tapState.handle(buffer: buffer, time: time)
            }
        }

        self.engine = engine
        self.isRunning = true
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
        self.registerEventObservers(engine: engine, outcome: outcome, requestedDeviceID: requestedDeviceID, onEvent: onEvent)
        return outcome
    }

    func stop() async {
        guard self.isRunning else { return }
        self.isRunning = false
        self.tearDownEventObservers() // first: stop-time churn must not poison a stats snapshot
        self.generationBox.advance()

        if let engine = self.engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil
        self.tapState = nil
    }

    func statistics() -> Stats {
        self.statsBox.snapshot()
    }

    func settledConfiguration() -> MeetingMicrophoneSettledConfig? {
        self.settled
    }

    private func fail(microphone: MeetingMicrophoneIdentity, reason: String) -> MeetingMicrophoneBindingOutcome {
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
            try? await Task.sleep(nanoseconds: Self.formatRetryDelayNanoseconds)
            format = input.outputFormat(forBus: 0)
        }
        return format
    }

    private func registerEventObservers(
        engine: AVAudioEngine,
        outcome: MeetingMicrophoneBindingOutcome,
        requestedDeviceID: AudioObjectID,
        onEvent: @escaping @Sendable (MeetingMicrophoneCaptureEvent) -> Void
    ) {
        let statsBox = self.statsBox
        // queue: nil — see ASRService.registerEngineConfigurationChangeObserver for why synchronous
        // delivery is load-bearing (avoids a deadlock against the engine's own serial queue).
        self.configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak tapState = self.tapState] _ in
            statsBox.mutate { $0.configurationChangeEvents += 1 }
            tapState?.requestTimelineReset()
            onEvent(.configurationChanged)
        }

        if case .defaultMatchesRequested = outcome {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let token: AudioObjectPropertyListenerBlock = { _, _ in
                statsBox.mutate { $0.defaultInputChangeEvents += 1 }
                onEvent(.defaultInputChanged)
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, token) == noErr {
                self.defaultInputListenerToken = token
            }
        }

        if case .boundVerified = outcome {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDeviceProcessorOverload,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let token: AudioObjectPropertyListenerBlock = { _, _ in
                statsBox.mutate { $0.overloadCount += 1 }
                onEvent(.overload)
            }
            if AudioObjectAddPropertyListenerBlock(requestedDeviceID, &address, DispatchQueue.main, token) == noErr {
                self.overloadListenerToken = token
                self.overloadListenerDeviceID = requestedDeviceID
            }
        }
    }

    private func tearDownEventObservers() {
        if let configObserver = self.configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let token = self.defaultInputListenerToken {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, token)
            self.defaultInputListenerToken = nil
        }
        if let token = self.overloadListenerToken, let deviceID = self.overloadListenerDeviceID {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDeviceProcessorOverload,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, token)
            self.overloadListenerToken = nil
            self.overloadListenerDeviceID = nil
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
}

// MARK: - Opt-in hardware probe

/// Real-hardware Phase 1 gate (plan §9), foreground only; env FLUIDVOICE_MIC_PHASE1[_DEVICE].
enum MeetingMicrophonePhase1Probe {
    struct Result: Sendable {
        var minutes: Double
        var outcome: MeetingMicrophoneBindingOutcome
        var settled: MeetingMicrophoneSettledConfig?
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
            microphone = try MeetingCaptureSourceCatalog.defaultMicrophone(preferredCoreAudioUID: overrideUID)
        } else {
            microphone = try MeetingCaptureSourceCatalog.defaultMicrophone()
        }

        var writerBackpressureEvents = 0
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
            if case .interrupted(.writerBackpressure, _, _) = event { writerBackpressureEvents += 1 }
        }

        var deliveredSourceFormat = "(none delivered)"
        let capturedFormat = OSAllocatedUnfairLock<String?>(initialState: nil)
        let tapTelemetry = OSAllocatedUnfairLock<(nilCopies: Int, peak: Float)>(initialState: (0, 0))

        let capture = MeetingMicrophoneCapture()
        let outcome = try await capture.start(microphone: microphone) { sampleBuffer in
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
            {
                capturedFormat.withLock { $0 = "\(asbd.mSampleRate)Hz \(asbd.mChannelsPerFrame)ch" }
            }
            let copied = MeetingLiveSampleCopy.copy(sampleBuffer)
            var bufferPeak: Float = 0
            if let channel = copied?.buffer.floatChannelData?[0], let frames = copied.map({ Int($0.buffer.frameLength) }) {
                vDSP_maxmgv(channel, 1, &bufferPeak, vDSP_Length(frames))
            }
            tapTelemetry.withLock {
                if copied == nil { $0.nilCopies += 1 }
                $0.peak = max($0.peak, bufferPeak)
            }
            writer.enqueue(sampleBuffer)
        }

        try await Task.sleep(nanoseconds: UInt64(minutes * 60 * 1_000_000_000))
        await capture.stop()
        let finishedTrack = await writer.stop()
        deliveredSourceFormat = capturedFormat.withLock { $0 } ?? deliveredSourceFormat
        let telemetry = tapTelemetry.withLock { $0 }

        return Result(
            minutes: minutes,
            outcome: outcome,
            settled: await capture.settledConfiguration(),
            stats: await capture.statistics(),
            writerDiscontinuities: finishedTrack.chunks.reduce(0) { $0 + $1.discontinuities.count },
            writerRotationCount: finishedTrack.chunks.count,
            writerBackpressureEvents: writerBackpressureEvents,
            finalHealthStatus: finishedTrack.health.status,
            liveCopyNilCount: telemetry.nilCopies,
            deliveredSourceFormat: deliveredSourceFormat,
            peakAmplitude: telemetry.peak
        )
    }
}
