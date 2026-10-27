import Foundation

/// The source clocks intentionally remain distinct until the synchronizer derives a
/// session timeline.  This type is offline-only: it accepts completed in-memory PCM
/// fixtures and performs no callback, file, or engine work.
public nonisolated enum MeetingSynchronizerTimeline: String, Sendable {
    case microphoneSource
    case referencePTS
    case sessionMonotonic
}

public nonisolated enum MeetingReferenceScope: String, Sendable {
    case selectedWindow
    case selectedApplication
    case authorizedFullMix
}

public nonisolated enum MeetingReferenceCompleteness: String, Sendable {
    case measuredComplete
    case unobservable
}

/// These are the only reasons by which a synchronizer result is unknown.  In
/// particular, an absent/masked sample is never represented as measured silence.
public nonisolated enum MeetingSynchronizerUnknownReason: String, CaseIterable, Hashable, Sendable {
    case referenceAbsent
    case referenceGap
    case referenceScopeLimited
    case referenceCompletenessUnobservable
    case captureGap
    case captureTimingSynthesized
    case delayUnresolved
    case clockDriftUnstable
    case engineUnavailable
}

public nonisolated struct MeetingMicrophonePCMFrame: Equatable, Sendable {
    public let sequenceNumber: Int
    public let sampleTime: Int64
    public let hostTime: Double?
    public let sampleRate: Double
    public let channelCount: Int
    public let samples: [Float]
    public let routeIdentifier: String
    public let discontinuity: Bool

    public init(
        sequenceNumber: Int,
        sampleTime: Int64,
        hostTime: Double?,
        sampleRate: Double,
        channelCount: Int = 1,
        samples: [Float],
        routeIdentifier: String = "default",
        discontinuity: Bool = false
    ) {
        self.sequenceNumber = sequenceNumber
        self.sampleTime = sampleTime
        self.hostTime = hostTime
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
        self.routeIdentifier = routeIdentifier
        self.discontinuity = discontinuity
    }
}

public nonisolated struct MeetingReferencePCMFrame: Equatable, Sendable {
    public let sequenceNumber: Int
    /// PTS in the reference's own clock. It is deliberately not assumed to be host time.
    public let presentationTime: Double
    public let sampleRate: Double
    public let channelCount: Int
    public let samples: [Float]
    public let discontinuity: Bool

    public init(
        sequenceNumber: Int,
        presentationTime: Double,
        sampleRate: Double,
        channelCount: Int = 1,
        samples: [Float],
        discontinuity: Bool = false
    ) {
        self.sequenceNumber = sequenceNumber
        self.presentationTime = presentationTime
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
        self.discontinuity = discontinuity
    }
}

// Keep the subsystem-qualified name distinct from other capture and analysis contracts.
// swiftlint:disable:next type_name
public nonisolated struct MeetingSynchronizerConverterConfiguration: Equatable, Sendable {
    public let version: String
    /// Algorithmic delay is removed from the converted timeline, not hidden in the samples.
    public let algorithmicDelaySeconds: Double

    public init(version: String = "linear-v1", algorithmicDelaySeconds: Double = 0) {
        self.version = version
        self.algorithmicDelaySeconds = algorithmicDelaySeconds
    }
}

// Keep the subsystem-qualified name distinct from other capture and analysis contracts.
// swiftlint:disable:next type_name
public nonisolated struct MeetingReferenceSynchronizerConfiguration: Equatable, Sendable {
    public static let defaultFrameDuration: Double = 0.010
    public let analysisSampleRate: Double
    public let frameDuration: Double
    public let microphoneConverter: MeetingSynchronizerConverterConfiguration
    public let referenceConverter: MeetingSynchronizerConverterConfiguration
    /// Positive values place the reference later on the session timeline. The reported
    /// lag sign is `microphoneTime - referenceTime`: positive means microphone lags.
    public let referenceToMicrophoneOffsetSeconds: Double
    /// Reference time is scaled by `1 + clockDriftPPM / 1e6`; this is an explicit fixture
    /// model, not silent time stretching of either captured stream.
    public let referenceClockDriftPPM: Double
    public let maximumClockDriftPPM: Double
    public let referenceScope: MeetingReferenceScope
    public let referenceCompleteness: MeetingReferenceCompleteness
    public let codecPrimingSamples: Int
    public let codecRemainderSamples: Int
    public let editListOffsetSeconds: Double
    public let maximumInputFrameCount: Int
    public let maximumInputSampleCount: Int
    public let maximumOutputFrameCount: Int
    public let engineAvailable: Bool

    public init(
        analysisSampleRate: Double = 16_000,
        frameDuration: Double = MeetingReferenceSynchronizerConfiguration.defaultFrameDuration,
        microphoneConverter: MeetingSynchronizerConverterConfiguration = .init(),
        referenceConverter: MeetingSynchronizerConverterConfiguration = .init(),
        referenceToMicrophoneOffsetSeconds: Double = 0,
        referenceClockDriftPPM: Double = 0,
        maximumClockDriftPPM: Double = 100,
        referenceScope: MeetingReferenceScope = .selectedApplication,
        referenceCompleteness: MeetingReferenceCompleteness = .unobservable,
        codecPrimingSamples: Int = 0,
        codecRemainderSamples: Int = 0,
        editListOffsetSeconds: Double = 0,
        maximumInputFrameCount: Int = 16_384,
        maximumInputSampleCount: Int = 16_000 * 60 * 60,
        maximumOutputFrameCount: Int = 16_000 * 60 * 60 / 160,
        engineAvailable: Bool = true
    ) {
        self.analysisSampleRate = analysisSampleRate
        self.frameDuration = frameDuration
        self.microphoneConverter = microphoneConverter
        self.referenceConverter = referenceConverter
        self.referenceToMicrophoneOffsetSeconds = referenceToMicrophoneOffsetSeconds
        self.referenceClockDriftPPM = referenceClockDriftPPM
        self.maximumClockDriftPPM = maximumClockDriftPPM
        self.referenceScope = referenceScope
        self.referenceCompleteness = referenceCompleteness
        self.codecPrimingSamples = codecPrimingSamples
        self.codecRemainderSamples = codecRemainderSamples
        self.editListOffsetSeconds = editListOffsetSeconds
        self.maximumInputFrameCount = maximumInputFrameCount
        self.maximumInputSampleCount = maximumInputSampleCount
        self.maximumOutputFrameCount = maximumOutputFrameCount
        self.engineAvailable = engineAvailable
    }
}

public nonisolated struct MeetingSynchronizedFrame: Equatable, Sendable {
    public let index: Int
    public let sessionStartTime: Double
    public let sessionEndTime: Double
    public let epochID: Int
    public let renderSamples: [Float]
    public let captureSamples: [Float]
    public let renderValidMask: [Bool]
    public let captureValidMask: [Bool]
    public let unknownReasons: [MeetingSynchronizerUnknownReason]
    public let adaptationFrozen: Bool
    public let resynchronizationBoundary: Bool
    /// Configured/mapped alignment (`captureTime - referenceTime`), not an observed
    /// acoustic delay. A positive value means the mapped capture timeline lags the
    /// mapped reference timeline; callers must retain `.delayUnresolved` unless a
    /// separate shared-clock calibration has been established.
    public let lagSeconds: Double?
    public let timelines: MeetingSynchronizerFrameTimelines

    public init(
        index: Int,
        sessionStartTime: Double,
        sessionEndTime: Double,
        epochID: Int,
        renderSamples: [Float],
        captureSamples: [Float],
        renderValidMask: [Bool],
        captureValidMask: [Bool],
        unknownReasons: [MeetingSynchronizerUnknownReason],
        adaptationFrozen: Bool,
        resynchronizationBoundary: Bool,
        lagSeconds: Double?,
        timelines: MeetingSynchronizerFrameTimelines? = nil
    ) {
        self.index = index
        self.sessionStartTime = sessionStartTime
        self.sessionEndTime = sessionEndTime
        self.epochID = epochID
        self.renderSamples = renderSamples
        self.captureSamples = captureSamples
        self.renderValidMask = renderValidMask
        self.captureValidMask = captureValidMask
        self.unknownReasons = unknownReasons
        self.adaptationFrozen = adaptationFrozen
        self.resynchronizationBoundary = resynchronizationBoundary
        self.lagSeconds = lagSeconds
        self.timelines = timelines ?? MeetingSynchronizerFrameTimelines(
            microphoneSourceTime: nil, referencePTSTime: nil, sessionMonotonicTime: sessionStartTime
        )
    }
}

public nonisolated struct MeetingSynchronizerDiagnostics: Equatable, Sendable {
    public let inputFrameCount: Int
    public let droppedFrameCount: Int
    public let epochCount: Int
    public let synthesizedMicrophoneFrameCount: Int
    public let duplicateOrLateFrameCount: Int
    public let nonFiniteSampleCount: Int
    public let boundedResourceFailure: Bool
    public let converterVersions: [String]
    public let converterDelays: [Double]
    public let referenceClockDriftPPM: Double?
}

/// The three clock domains are carried with every emitted pair. Values are seconds in
/// their respective domains; `sessionMonotonicTime` is the only timeline consumers may
/// use for pairing. A nil source value means that domain had no valid sample in the pair.
public nonisolated struct MeetingSynchronizerFrameTimelines: Equatable, Sendable {
    /// Sample-count time from the microphone source (seconds, in its own domain).
    public let microphoneSourceTime: Double?
    /// The original reference PTS domain (seconds); codec priming is reflected by the
    /// first valid sample's position, but edit-list/offset/drift are not folded into it.
    public let referencePTSTime: Double?
    public let sessionMonotonicTime: Double
    /// Original microphone sample-count and host-time coordinates, carried independently.
    public let microphoneSampleTime: Int64?
    public let microphoneHostTime: Double?

    public init(microphoneSourceTime: Double?, referencePTSTime: Double?, sessionMonotonicTime: Double) {
        self.init(
            microphoneSourceTime: microphoneSourceTime,
            microphoneSampleTime: nil,
            microphoneHostTime: nil,
            referencePTSTime: referencePTSTime,
            sessionMonotonicTime: sessionMonotonicTime
        )
    }

    public init(
        microphoneSourceTime: Double?, microphoneSampleTime: Int64?, microphoneHostTime: Double?,
        referencePTSTime: Double?, sessionMonotonicTime: Double
    ) {
        self.microphoneSourceTime = microphoneSourceTime
        self.microphoneSampleTime = microphoneSampleTime
        self.microphoneHostTime = microphoneHostTime
        self.referencePTSTime = referencePTSTime
        self.sessionMonotonicTime = sessionMonotonicTime
    }
}

public nonisolated struct MeetingSynchronizationResult: Equatable, Sendable {
    public let frames: [MeetingSynchronizedFrame]
    public let failedOpen: Bool
    public let failureReason: MeetingSynchronizerUnknownReason?
    public let diagnostics: MeetingSynchronizerDiagnostics

    public init(
        frames: [MeetingSynchronizedFrame],
        failedOpen: Bool,
        failureReason: MeetingSynchronizerUnknownReason?,
        diagnostics: MeetingSynchronizerDiagnostics
    ) {
        self.frames = frames
        self.failedOpen = failedOpen
        self.failureReason = failureReason
        self.diagnostics = diagnostics
    }
}

/// Deterministic first-slice synchronizer. The implementation is intentionally a pure
/// function over bounded arrays so fixtures can be replayed byte-for-byte in tests.
public nonisolated struct MeetingReferenceSynchronizer: Sendable {
    public let configuration: MeetingReferenceSynchronizerConfiguration

    public init(configuration: MeetingReferenceSynchronizerConfiguration = .init()) {
        self.configuration = configuration
    }

    public static func lagSeconds(microphoneTime: Double, referenceTime: Double) -> Double {
        microphoneTime - referenceTime
    }

    public func synchronize(
        microphone: [MeetingMicrophonePCMFrame],
        reference: [MeetingReferencePCMFrame]
    ) -> MeetingSynchronizationResult {
        var totalFrames = 0
        var inputArithmeticOverflow = false
        let (frameSum, frameOverflow) = microphone.count.addingReportingOverflow(reference.count)
        totalFrames = frameOverflow ? Int.max : frameSum
        inputArithmeticOverflow = frameOverflow
        var totalSamples = 0
        for sampleCount in microphone.map(\.samples.count) + reference.map(\.samples.count) {
            let (sum, overflow) = totalSamples.addingReportingOverflow(max(0, sampleCount))
            totalSamples = overflow ? Int.max : sum
            inputArithmeticOverflow = inputArithmeticOverflow || overflow
        }
        let invalidBudgets = self.configuration.maximumInputFrameCount <= 0
            || self.configuration.maximumInputSampleCount <= 0
            || self.configuration.maximumOutputFrameCount <= 0
        let overBudget = !self.configuration.engineAvailable || invalidBudgets || inputArithmeticOverflow
            || microphone.count > self.configuration.maximumInputFrameCount
            || reference.count > self.configuration.maximumInputFrameCount
            || totalFrames > self.configuration.maximumInputFrameCount
            || totalSamples > self.configuration.maximumInputSampleCount
        let converterVersions = [configuration.microphoneConverter.version, self.configuration.referenceConverter.version]
        let converterDelays = [configuration.microphoneConverter.algorithmicDelaySeconds, self.configuration.referenceConverter.algorithmicDelaySeconds]
        let emptyDiagnostics = MeetingSynchronizerDiagnostics(
            inputFrameCount: totalFrames,
            droppedFrameCount: 0,
            epochCount: 0,
            synthesizedMicrophoneFrameCount: 0,
            duplicateOrLateFrameCount: 0,
            nonFiniteSampleCount: 0,
            boundedResourceFailure: overBudget,
            converterVersions: converterVersions,
            converterDelays: converterDelays,
            referenceClockDriftPPM: finite(configuration.referenceClockDriftPPM) ? self.configuration.referenceClockDriftPPM : nil
        )
        guard !overBudget else {
            return MeetingSynchronizationResult(frames: [], failedOpen: true, failureReason: .engineUnavailable, diagnostics: emptyDiagnostics)
        }
        guard self.finite(self.configuration.maximumClockDriftPPM), self.configuration.maximumClockDriftPPM >= 0,
              self.finite(self.configuration.referenceClockDriftPPM),
              abs(self.configuration.referenceClockDriftPPM) <= self.configuration.maximumClockDriftPPM
        else {
            return MeetingSynchronizationResult(frames: [], failedOpen: true, failureReason: .clockDriftUnstable, diagnostics: emptyDiagnostics)
        }
        let referenceTimelineScale = 1 + self.configuration.referenceClockDriftPPM / 1_000_000
        guard self.finite(referenceTimelineScale), referenceTimelineScale > 0 else {
            return MeetingSynchronizationResult(frames: [], failedOpen: true, failureReason: .clockDriftUnstable, diagnostics: emptyDiagnostics)
        }
        guard self.finite(self.configuration.analysisSampleRate), self.configuration.analysisSampleRate > 0,
              self.finite(self.configuration.frameDuration), self.configuration.frameDuration > 0,
              self.finite(self.configuration.microphoneConverter.algorithmicDelaySeconds),
              self.finite(self.configuration.referenceConverter.algorithmicDelaySeconds),
              self.finite(self.configuration.referenceToMicrophoneOffsetSeconds),
              self.finite(self.configuration.editListOffsetSeconds),
              self.configuration.codecPrimingSamples >= 0, self.configuration.codecRemainderSamples >= 0
        else {
            return MeetingSynchronizationResult(frames: [], failedOpen: true, failureReason: .engineUnavailable, diagnostics: emptyDiagnostics)
        }

        var dropped = 0
        var duplicateOrLate = 0
        var nonFinite = 0
        let micTrack = self.buildMicrophoneTrack(microphone, dropped: &dropped, duplicateOrLate: &duplicateOrLate, nonFinite: &nonFinite)
        let refTrack = self.buildReferenceTrack(reference, dropped: &dropped, duplicateOrLate: &duplicateOrLate, nonFinite: &nonFinite)
        let tracks = [micTrack, refTrack]
        guard let firstTime = tracks.compactMap(\.firstTime).min(),
              let lastTime = tracks.compactMap(\.lastTime).max(), lastTime > firstTime
        else {
            let diagnostics = MeetingSynchronizerDiagnostics(
                inputFrameCount: totalFrames,
                droppedFrameCount: dropped,
                epochCount: 0,
                synthesizedMicrophoneFrameCount: micTrack.synthesizedFrameCount,
                duplicateOrLateFrameCount: duplicateOrLate,
                nonFiniteSampleCount: nonFinite,
                boundedResourceFailure: false,
                converterVersions: converterVersions,
                converterDelays: converterDelays,
                referenceClockDriftPPM: self.configuration.referenceClockDriftPPM
            )
            return MeetingSynchronizationResult(frames: [], failedOpen: false, failureReason: nil, diagnostics: diagnostics)
        }

        let frameProduct = self.configuration.analysisSampleRate * self.configuration.frameDuration
        guard self.finite(frameProduct), frameProduct > 0, frameProduct < Double(Int.max) else {
            return MeetingSynchronizationResult(frames: [], failedOpen: true, failureReason: .engineUnavailable, diagnostics: emptyDiagnostics)
        }
        let frameSizeDouble = frameProduct.rounded()
        guard frameSizeDouble >= 1, frameSizeDouble < Double(Int.max) else {
            return MeetingSynchronizationResult(frames: [], failedOpen: true, failureReason: .engineUnavailable, diagnostics: emptyDiagnostics)
        }
        let frameSize = Int(frameSizeDouble)
        let spanSamples = (lastTime - firstTime) * self.configuration.analysisSampleRate
        guard self.finite(spanSamples), spanSamples > 0 else {
            return MeetingSynchronizationResult(frames: [], failedOpen: true, failureReason: .engineUnavailable, diagnostics: emptyDiagnostics)
        }
        let frameCountDouble = ceil(spanSamples / Double(frameSize) - 1e-10)
        guard self.finite(frameCountDouble), frameCountDouble >= 1,
              frameCountDouble <= Double(self.configuration.maximumOutputFrameCount),
              frameCountDouble < Double(Int.max)
        else {
            let diagnostics = MeetingSynchronizerDiagnostics(
                inputFrameCount: totalFrames,
                droppedFrameCount: dropped,
                epochCount: 0,
                synthesizedMicrophoneFrameCount: micTrack.synthesizedFrameCount,
                duplicateOrLateFrameCount: duplicateOrLate,
                nonFiniteSampleCount: nonFinite,
                boundedResourceFailure: true,
                converterVersions: converterVersions,
                converterDelays: converterDelays,
                referenceClockDriftPPM: self.configuration.referenceClockDriftPPM
            )
            return MeetingSynchronizationResult(frames: [], failedOpen: true, failureReason: .engineUnavailable, diagnostics: diagnostics)
        }
        let frameCount = Int(frameCountDouble)
        guard frameCount <= Int.max / frameSize else {
            let diagnostics = MeetingSynchronizerDiagnostics(
                inputFrameCount: totalFrames,
                droppedFrameCount: dropped,
                epochCount: 0,
                synthesizedMicrophoneFrameCount: micTrack.synthesizedFrameCount,
                duplicateOrLateFrameCount: duplicateOrLate,
                nonFiniteSampleCount: nonFinite,
                boundedResourceFailure: true,
                converterVersions: converterVersions,
                converterDelays: converterDelays,
                referenceClockDriftPPM: self.configuration.referenceClockDriftPPM
            )
            return MeetingSynchronizationResult(frames: [], failedOpen: true, failureReason: .engineUnavailable, diagnostics: diagnostics)
        }
        let outputCount = frameCount * frameSize
        let outputDuration = Double(outputCount) / self.configuration.analysisSampleRate
        guard outputDuration.isFinite, (firstTime + outputDuration).isFinite else {
            let diagnostics = MeetingSynchronizerDiagnostics(
                inputFrameCount: totalFrames,
                droppedFrameCount: dropped,
                epochCount: 0,
                synthesizedMicrophoneFrameCount: micTrack.synthesizedFrameCount,
                duplicateOrLateFrameCount: duplicateOrLate,
                nonFiniteSampleCount: nonFinite,
                boundedResourceFailure: true,
                converterVersions: converterVersions,
                converterDelays: converterDelays,
                referenceClockDriftPPM: self.configuration.referenceClockDriftPPM
            )
            return MeetingSynchronizationResult(frames: [], failedOpen: true, failureReason: .engineUnavailable, diagnostics: diagnostics)
        }
        let micGrid = self.makeGrid(track: micTrack, origin: firstTime, frameSize: frameSize, outputCount: outputCount)
        let refGrid = self.makeGrid(track: refTrack, origin: firstTime, frameSize: frameSize, outputCount: outputCount)
        let epochEvents = self.deduplicatedEpochEvents(micTrack.epochEvents + refTrack.epochEvents)
        let resyncEvents = Set((micTrack.resynchronizationEvents + refTrack.resynchronizationEvents).map {
            // Round to the nearest fixed frame index so binary floating-point representation of
            // a 10 ms boundary cannot pin an event to the preceding frame.
            self.safeRoundedInt(($0 - firstTime) / (Double(frameSize) / self.configuration.analysisSampleRate))
        }.compactMap { $0 })
        var output: [MeetingSynchronizedFrame] = []
        output.reserveCapacity(frameCount)
        for frameIndex in 0..<frameCount {
            let start = firstTime + Double(frameIndex * frameSize) / self.configuration.analysisSampleRate
            let end = start + Double(frameSize) / self.configuration.analysisSampleRate
            let range = frameIndex * frameSize..<(frameIndex + 1) * frameSize
            let micValues = Array(micGrid.samples[range])
            let refValues = Array(refGrid.samples[range])
            let micMask = Array(micGrid.valid[range])
            let refMask = Array(refGrid.valid[range])
            var reasons: [MeetingSynchronizerUnknownReason] = []
            if reference.isEmpty { reasons.append(.referenceAbsent) } else if refTrack.hasInternalGap(in: start..<end) { reasons.append(.referenceGap) }
            if !micMask.contains(true) { reasons.append(.captureGap) } else if micTrack.hasInternalGap(in: start..<end) { reasons.append(.captureGap) }
            if micTrack.hasSynthesized(in: start..<end) { reasons.append(.captureTimingSynthesized) }
            if !reference.isEmpty {
                if self.configuration.referenceScope != .authorizedFullMix { reasons.append(.referenceScopeLimited) }
                if self.configuration.referenceCompleteness == .unobservable { reasons.append(.referenceCompletenessUnobservable) }
                // This offline fixture has no shared-clock/acoustic calibration. Its
                // configured alignment remains useful for deterministic tests, but is
                // never presented as a measured delay.
                reasons.append(.delayUnresolved)
            }
            if !refMask.contains(true) && !reference.isEmpty { reasons.append(.referenceGap) }
            if abs(self.configuration.referenceClockDriftPPM) > self.configuration.maximumClockDriftPPM * 0.75 { reasons.append(.clockDriftUnstable) }
            if !micMask.contains(true) || (!reference.isEmpty && !refMask.contains(true)) { reasons.append(.delayUnresolved) }
            reasons = self.orderedUnique(reasons)
            let anySynth = micTrack.hasSynthesized(in: start..<end)
            let epoch = epochEvents.filter { $0 <= start + 1e-9 }.count
            let micSourceTime = micGrid.sourceTimes[range].compactMap { $0 }.first
            let referenceSourceTime = refGrid.sourceTimes[range].compactMap { $0 }.first
            let microphoneSampleTime = micGrid.microphoneSampleTimes[range].compactMap { $0 }.first
            let microphoneHostTime = micGrid.microphoneHostTimes[range].compactMap { $0 }.first
            let resynchronizationBoundary = resyncEvents.contains(frameIndex)
            #if DEBUG
            let coverageIncomplete = !micMask.allSatisfy { $0 } || !refMask.allSatisfy { $0 }
            let adaptationFrozen = anySynth || coverageIncomplete || resynchronizationBoundary
            #else
            // The Stage 0.5 adapter behavior is deliberately absent from Release until a
            // later production integration phase is separately reviewed and authorized.
            let adaptationFrozen = anySynth
            #endif
            let lag: Double? = {
                guard !anySynth else { return nil }
                guard micSourceTime != nil, referenceSourceTime != nil else { return nil }
                // Use each track's mapped first-valid start. This retains codec priming and
                // absolute reference PTS along with converter, edit-list, drift, and path
                // offsets, while avoiding a false lag caused by independently selecting the
                // first covered sample in a partially overlapping output frame.
                guard let micStart = micTrack.firstTime, let referenceStart = refTrack.firstTime else {
                    return nil
                }
                return micStart - referenceStart
            }()
            output.append(MeetingSynchronizedFrame(
                index: frameIndex,
                sessionStartTime: start - firstTime,
                sessionEndTime: end - firstTime,
                epochID: epoch,
                renderSamples: refValues,
                captureSamples: micValues,
                renderValidMask: refMask,
                captureValidMask: micMask,
                unknownReasons: reasons,
                adaptationFrozen: adaptationFrozen,
                resynchronizationBoundary: resynchronizationBoundary,
                lagSeconds: lag,
                timelines: MeetingSynchronizerFrameTimelines(
                    microphoneSourceTime: micSourceTime,
                    microphoneSampleTime: microphoneSampleTime,
                    microphoneHostTime: microphoneHostTime,
                    referencePTSTime: referenceSourceTime,
                    sessionMonotonicTime: start - firstTime
                )
            ))
        }
        let diagnostics = MeetingSynchronizerDiagnostics(
            inputFrameCount: totalFrames,
            droppedFrameCount: dropped,
            epochCount: max(1, epochEvents.count + 1),
            synthesizedMicrophoneFrameCount: micTrack.synthesizedFrameCount,
            duplicateOrLateFrameCount: duplicateOrLate,
            nonFiniteSampleCount: nonFinite,
            boundedResourceFailure: false,
            converterVersions: converterVersions,
            converterDelays: converterDelays,
            referenceClockDriftPPM: self.configuration.referenceClockDriftPPM
        )
        return MeetingSynchronizationResult(frames: output, failedOpen: false, failureReason: nil, diagnostics: diagnostics)
    }

    // MARK: - Track normalization

    private nonisolated struct TrackGrid {
        var segments: [TimedSegment]
        var sourceOrigin: Double?
        var firstTime: Double?
        var lastTime: Double?
        var epochEvents: [Double]
        var resynchronizationEvents: [Double]
        var gapRanges: [Range<Double>]
        var synthesizedFrameCount: Int

        func hasInternalGap(in range: Range<Double>) -> Bool {
            #if DEBUG
            // Treat ranges that only meet at a boundary as disjoint. Callback PTS and
            // fixed analysis-hop arithmetic can differ by a few binary floating-point
            // ulps; without the epsilon, the first fully covered hop after a gap can be
            // mislabeled as still containing that gap.
            self.gapRanges.contains {
                $0.lowerBound < range.upperBound - 1e-9
                    && $0.upperBound > range.lowerBound + 1e-9
            }
            #else
            return self.gapRanges.contains {
                $0.lowerBound < range.upperBound && $0.upperBound > range.lowerBound
            }
            #endif
        }

        func hasSynthesized(in range: Range<Double>) -> Bool {
            #if DEBUG
            self.segments.contains { segment in
                segment.synthesized && segment.start < range.upperBound - 1e-9
                    && segment.start + Double(segment.values.count) / segment.sessionSampleRate
                    > range.lowerBound + 1e-9
            }
            #else
            return self.segments.contains { segment in
                segment.synthesized && segment.start < range.upperBound
                    && segment.start + Double(segment.values.count) / segment.sessionSampleRate
                    > range.lowerBound
            }
            #endif
        }
    }

    private nonisolated struct TimedSegment {
        let start: Double
        let sourceStart: Double
        /// Untransformed source-clock coordinate used for per-frame provenance.
        let sourceTimelineStart: Double
        let sourceSampleTime: Int64?
        let hostTime: Double?
        let sourceSampleRate: Double
        let sessionSampleRate: Double
        let timelineScale: Double
        let values: [Float]
        let synthesized: Bool
    }

    private nonisolated struct Grid {
        var samples: [Float]
        var valid: [Bool]
        var sourceTimes: [Double?]
        var microphoneSampleTimes: [Int64?]
        var microphoneHostTimes: [Double?]
    }

    private func buildMicrophoneTrack(_ frames: [MeetingMicrophonePCMFrame], dropped: inout Int, duplicateOrLate: inout Int, nonFinite: inout Int) -> TrackGrid {
        var seen = Set<Int>()
        var epochEvents: [Double] = []
        var gaps: [Range<Double>] = []
        var resynchronizationEvents: [Double] = []
        var synthCount = 0
        var previousSequence: Int?
        var previousSampleTime: Int64?
        var previousHost: Double?
        var previousRate: Double?
        var previousRoute: String?
        var hadSynthesized = false
        // Keep this existing grouped state result intact during integration.
        // swiftlint:disable:next large_tuple
        var normalized: [(frame: MeetingMicrophonePCMFrame, start: Double, sourceStart: Double, sourceSampleTime: Int64, hostTime: Double?, values: [Float], synthesized: Bool)] = []
        var firstValidSample: Int64?
        for frame in frames {
            let isLate = seen.contains(frame.sequenceNumber)
                || (previousSequence.map { frame.sequenceNumber <= $0 } ?? false)
            guard !isLate else {
                duplicateOrLate += 1; dropped += 1
                continue
            }
            seen.insert(frame.sequenceNumber)
            let nominalStart: Double = {
                guard let firstValidSample, finite(frame.sampleRate), frame.sampleRate > 0 else { return 0 }
                guard let delta = safeSampleDelta(frame.sampleTime, firstValidSample) else { return 0 }
                return delta / frame.sampleRate
            }()
            let sequenceGapDetected = previousSequence.map { frame.sequenceNumber > $0 + 1 } ?? false
            guard frame.channelCount > 0, self.finite(frame.sampleRate), frame.sampleRate > 0 else {
                dropped += 1
                if normalized.last != nil {
                    let gapStart = normalized.last.map { $0.start + Double($0.values.count) / $0.frame.sampleRate } ?? nominalStart
                    let gapDuration = frame.sampleRate.isFinite && frame.sampleRate > 0
                        ? Double(max(1, frame.samples.count / max(frame.channelCount, 1))) / frame.sampleRate
                        : self.configuration.frameDuration
                    self.appendEpochEvent(gapStart, to: &epochEvents)
                    self.appendGap(gapStart..<gapStart + gapDuration, to: &gaps)
                }
                previousSequence = frame.sequenceNumber
                continue
            }
            if frame.samples.isEmpty {
                dropped += 1
                // An empty pre-origin block cannot establish a measured source origin.
                // Once a valid block exists, its finite timestamp locates one configured
                // hop of unknown coverage without creating a second reset marker.
                if let firstValidSample {
                    let start = self.safeSampleDelta(frame.sampleTime, firstValidSample).map {
                        $0 / frame.sampleRate - self.configuration.microphoneConverter.algorithmicDelaySeconds
                    }
                    if let start, start.isFinite, normalized.last != nil {
                        let duration = normalized.last.map { Double($0.values.count) / $0.frame.sampleRate }
                            ?? self.configuration.frameDuration
                        self.appendGap(start..<start + max(duration, self.configuration.frameDuration), to: &gaps)
                        self.appendEpochEvent(start, to: &epochEvents)
                    }
                }
                if normalized.last != nil { previousSampleTime = frame.sampleTime }
                previousSequence = frame.sequenceNumber
                continue
            }
            guard frame.samples.count % frame.channelCount == 0 else {
                dropped += 1
                // A pre-origin malformed block cannot establish a measured source
                // origin. Once the track is anchored, its finite timing locates the
                // midstream missing interval without using malformed audio as coverage.
                if normalized.last != nil {
                    self.appendEpochEvent(nominalStart, to: &epochEvents)
                    self.appendGap(nominalStart..<(nominalStart + Double(frame.samples.count) / Double(frame.channelCount) / frame.sampleRate), to: &gaps)
                }
                if normalized.last != nil { previousSampleTime = frame.sampleTime }
                previousSequence = frame.sequenceNumber
                continue
            }
            let finiteSamples = frame.samples.allSatisfy { $0.isFinite }
            if !finiteSamples {
                nonFinite += frame.samples.filter { !$0.isFinite }.count; dropped += 1
                let gapStart = normalized.last.map { $0.start + Double($0.values.count) / $0.frame.sampleRate } ?? nominalStart
                let gapDuration = Double(frame.samples.count / frame.channelCount) / frame.sampleRate
                if normalized.last != nil {
                    self.appendGap(gapStart..<gapStart + gapDuration, to: &gaps)
                    self.appendEpochEvent(gapStart, to: &epochEvents)
                }
                if normalized.last != nil { previousSampleTime = frame.sampleTime }
                previousSequence = frame.sequenceNumber
                continue
            }
            // A forward sequence number does not make a frame usable when its source
            // sample time moves backwards (or repeats). Drop it before it can create an
            // overlapping segment or manufacture a second epoch/gap. The sequence
            // cursor is still consumed, while continuity remains anchored to the last
            // accepted sample time.
            if let previousSampleTime, frame.sampleTime <= previousSampleTime {
                dropped += 1
                duplicateOrLate += 1
                previousSequence = frame.sequenceNumber
                continue
            }
            if firstValidSample == nil { firstValidSample = frame.sampleTime }
            guard let sampleDelta = safeSampleDelta(frame.sampleTime, firstValidSample ?? frame.sampleTime) else {
                dropped += 1
                duplicateOrLate += 1
                previousSequence = frame.sequenceNumber
                continue
            }
            let nominalStartFromOrigin = sampleDelta / frame.sampleRate
            let sourceStart = nominalStartFromOrigin - self.configuration.microphoneConverter.algorithmicDelaySeconds
            guard sourceStart.isFinite else {
                dropped += 1
                duplicateOrLate += 1
                previousSequence = frame.sequenceNumber
                continue
            }
            if let previousEnd = normalized.last.map({ $0.start + Double($0.values.count) / $0.frame.sampleRate }),
               sourceStart < previousEnd - 1e-9
            {
                dropped += 1
                duplicateOrLate += 1
                previousSequence = frame.sequenceNumber
                continue
            }
            if sequenceGapDetected {
                let previousEnd = normalized.last.map { $0.start + Double($0.values.count) / $0.frame.sampleRate }
                if let previousEnd, sourceStart > previousEnd + 1e-9 {
                    self.appendGap(previousEnd..<sourceStart, to: &gaps)
                }
                self.appendEpochEvent(sourceStart, to: &epochEvents)
                resynchronizationEvents.append(sourceStart)
            }
            let expected = previousSampleTime.flatMap { self.safeInt64Delta(frame.sampleTime, $0) }
            // A rejected pre-origin frame may supply a timing cursor, but with no
            // accepted segment there is no prior payload length to compare against.
            let expectedSamples: Int64? = normalized.last.map { Int64($0.values.count) }
            if !sequenceGapDetected,
               let expected, expected < 0 || (expectedSamples.map { expected != $0 } ?? false) || frame.discontinuity
               || (previousRate.map { frame.sampleRate != $0 } ?? false)
               || (previousRoute.map { frame.routeIdentifier != $0 } ?? false)
               || (previousHost.flatMap { previous in frame.hostTime.map { $0 <= previous } } ?? false)
            {
                self.appendEpochEvent(sourceStart, to: &epochEvents)
                // Any microphone timing/route discontinuity requires the AEC-facing
                // consumer to reset before it can use samples in the new epoch. This is
                // independent of whether the discontinuity also contains a coverage gap.
                #if DEBUG
                resynchronizationEvents.append(sourceStart)
                #endif
                let previousEnd = normalized.last.map { $0.start + Double($0.values.count) / $0.frame.sampleRate } ?? sourceStart
                if sourceStart > previousEnd { self.appendGap(previousEnd..<sourceStart, to: &gaps) }
            }
            let validHost = frame.hostTime.map(self.finite) ?? false
            let synthesized = !validHost
            if validHost && hadSynthesized {
                resynchronizationEvents.append(sourceStart)
                self.appendEpochEvent(sourceStart, to: &epochEvents)
                hadSynthesized = false
            }
            if synthesized { synthCount += 1; hadSynthesized = true }
            if !synthesized, let host = frame.hostTime { previousHost = host }
            previousSampleTime = frame.sampleTime
            previousSequence = frame.sequenceNumber
            previousRate = frame.sampleRate
            previousRoute = frame.routeIdentifier
            normalized.append((
                frame,
                sourceStart,
                Double(frame.sampleTime) / frame.sampleRate,
                frame.sampleTime,
                frame.hostTime,
                self.downmix(frame.samples, channels: frame.channelCount),
                synthesized
            ))
        }
        let segments = normalized.map { TimedSegment(
            start: $0.start,
            sourceStart: $0.sourceStart,
            sourceTimelineStart: Double($0.frame.sampleTime) / $0.frame.sampleRate,
            sourceSampleTime: $0.sourceSampleTime,
            hostTime: $0.hostTime,
            sourceSampleRate: $0.frame.sampleRate,
            sessionSampleRate: $0.frame.sampleRate,
            timelineScale: 1,
            values: $0.values,
            synthesized: $0.synthesized
        ) }
        return self.makeTrackGrid(
            segments: segments,
            sourceOrigin: normalized.first?.sourceStart,
            firstTime: normalized.map { $0.start }.min(),
            epochEvents: epochEvents,
            resynchronizationEvents: resynchronizationEvents,
            gaps: gaps,
            synthesizedFrameCount: synthCount
        )
    }

    private func buildReferenceTrack(_ frames: [MeetingReferencePCMFrame], dropped: inout Int, duplicateOrLate: inout Int, nonFinite: inout Int) -> TrackGrid {
        var seen = Set<Int>()
        // Keep this existing grouped state result intact during integration.
        // swiftlint:disable:next large_tuple
        var normalized: [(frame: MeetingReferencePCMFrame, start: Double, sourceStart: Double, sourceSampleTime: Int64?, hostTime: Double?, values: [Float], synthesized: Bool)] = []
        var previousPTS: Double?
        var previousSequence: Int?
        var previousRate: Double?
        var referenceAnchorPTS: Double?
        var previousRejectedEnd: Double?
        var primingRemaining = self.configuration.codecPrimingSamples
        var epochEvents: [Double] = []
        var resyncEvents: [Double] = []
        var gaps: [Range<Double>] = []
        for frame in frames {
            let isLate = seen.contains(frame.sequenceNumber)
                || (previousSequence.map { frame.sequenceNumber <= $0 } ?? false)
            guard !isLate else {
                duplicateOrLate += 1; dropped += 1
                continue
            }
            seen.insert(frame.sequenceNumber)
            let sequenceGapDetected = previousSequence.map { frame.sequenceNumber > $0 + 1 } ?? false
            guard frame.channelCount > 0, self.finite(frame.sampleRate), frame.sampleRate > 0,
                  self.finite(frame.presentationTime)
            else {
                dropped += 1
                if normalized.last != nil || referenceAnchorPTS != nil {
                    let gapStart = previousRejectedEnd ?? normalized.last.map {
                        $0.start + self.referenceSessionDuration(Double($0.values.count) / $0.frame.sampleRate)
                    } ?? (frame.presentationTime.isFinite
                        ? self.referenceSessionTime(sourceTime: frame.presentationTime - (referenceAnchorPTS ?? frame.presentationTime))
                        : 0)
                    let gapDuration = frame.sampleRate.isFinite && frame.sampleRate > 0
                        ? self.referenceSessionDuration(Double(max(1, frame.samples.count / max(frame.channelCount, 1))) / frame.sampleRate)
                        : self.configuration.frameDuration
                    self.appendEpochEvent(gapStart, to: &epochEvents)
                    self.appendGap(gapStart..<gapStart + gapDuration, to: &gaps)
                    if referenceAnchorPTS != nil { previousRejectedEnd = gapStart + gapDuration }
                }
                if normalized.last != nil || referenceAnchorPTS != nil { previousPTS = frame.presentationTime }
                previousSequence = frame.sequenceNumber
                continue
            }
            if frame.samples.isEmpty {
                dropped += 1
                if let anchor = referenceAnchorPTS {
                    let start = self.referenceSessionTime(sourceTime: frame.presentationTime - anchor)
                    if start.isFinite, normalized.last != nil {
                        let duration = normalized.last.map {
                            self.referenceSessionDuration(Double($0.values.count) / $0.frame.sampleRate)
                        } ?? self.configuration.frameDuration
                        self.appendEpochEvent(start, to: &epochEvents)
                        self.appendGap(start..<start + max(duration, self.configuration.frameDuration), to: &gaps)
                        previousRejectedEnd = start + max(duration, self.configuration.frameDuration)
                    }
                }
                if normalized.last != nil || referenceAnchorPTS != nil { previousPTS = frame.presentationTime }
                previousSequence = frame.sequenceNumber
                continue
            }
            guard frame.samples.count % frame.channelCount == 0 else {
                dropped += 1
                let malformedStart = self.referenceSessionTime(
                    sourceTime: frame.presentationTime - (referenceAnchorPTS ?? frame.presentationTime)
                )
                if normalized.last != nil || referenceAnchorPTS != nil {
                    self.appendEpochEvent(malformedStart, to: &epochEvents)
                    let duration = self.referenceSessionDuration(Double(frame.samples.count) / Double(frame.channelCount) / frame.sampleRate)
                    self.appendGap(malformedStart..<malformedStart + duration, to: &gaps)
                    if referenceAnchorPTS != nil { previousRejectedEnd = malformedStart + duration }
                }
                if normalized.last != nil || referenceAnchorPTS != nil { previousPTS = frame.presentationTime }
                previousSequence = frame.sequenceNumber
                continue
            }
            guard frame.samples.allSatisfy(\.isFinite) else {
                nonFinite += frame.samples.filter { !$0.isFinite }.count; dropped += 1
                let invalidStart = self.referenceSessionTime(
                    sourceTime: frame.presentationTime - (referenceAnchorPTS ?? frame.presentationTime)
                )
                let duration = self.referenceSessionDuration(Double(frame.samples.count) / Double(frame.channelCount) / frame.sampleRate)
                if normalized.last != nil || referenceAnchorPTS != nil {
                    self.appendGap(invalidStart..<invalidStart + duration, to: &gaps)
                    self.appendEpochEvent(invalidStart, to: &epochEvents)
                    if referenceAnchorPTS != nil { previousRejectedEnd = invalidStart + duration }
                }
                if normalized.last != nil || referenceAnchorPTS != nil { previousPTS = frame.presentationTime }
                previousSequence = frame.sequenceNumber
                continue
            }
            // A later-arriving frame with a repeated or backwards PTS cannot be placed
            // deterministically without overlapping accepted reference audio. Drop it
            // and consume its sequence number; the next accepted frame remains compared
            // with the last accepted PTS so any real forward hole is still represented.
            if let previousPTS, frame.presentationTime <= previousPTS {
                dropped += 1
                duplicateOrLate += 1
                previousSequence = frame.sequenceNumber
                continue
            }
            var values = self.downmix(frame.samples, channels: frame.channelCount)
            if referenceAnchorPTS == nil { referenceAnchorPTS = frame.presentationTime }
            let leading = min(primingRemaining, values.count)
            let candidateSourceStart = frame.presentationTime - (referenceAnchorPTS ?? frame.presentationTime)
                + Double(leading) / frame.sampleRate
            let candidateStart = self.referenceSessionTime(sourceTime: candidateSourceStart)
            guard candidateStart.isFinite else {
                dropped += 1
                duplicateOrLate += 1
                previousSequence = frame.sequenceNumber
                continue
            }
            if let previousEnd = previousRejectedEnd ?? normalized.last.map({
                $0.start + referenceSessionDuration(Double($0.values.count) / $0.frame.sampleRate)
            }), candidateStart < previousEnd - 1e-9 {
                dropped += 1
                duplicateOrLate += 1
                previousSequence = frame.sequenceNumber
                continue
            }
            if leading > 0 { values.removeFirst(leading) }
            primingRemaining -= leading
            let sourceStart = frame.presentationTime - (referenceAnchorPTS ?? frame.presentationTime)
                + Double(leading) / frame.sampleRate
            let start = self.referenceSessionTime(sourceTime: sourceStart)
            if sequenceGapDetected {
                let previousEnd = previousRejectedEnd ?? normalized.last.map {
                    $0.start + self.referenceSessionDuration(Double($0.values.count) / $0.frame.sampleRate)
                }
                if let previousEnd, start > previousEnd + 1e-9 {
                    self.appendGap(previousEnd..<start, to: &gaps)
                }
                self.appendEpochEvent(start, to: &epochEvents)
                // A sequence boundary is a reset marker even when sample-time coverage is
                // contiguous; it must not turn the valid current frame into a gap.
                // (The actual missing interval, when any, is recorded above.)
                // Keep this separate from measured drift or timing synthesis.
                resyncEvents.append(start)
            }
            // A discontinuity on the first accepted reference frame is metadata for
            // the stream's initial state, not a transition from an earlier epoch.
            if previousPTS != nil {
                let previousEnd = previousRejectedEnd ?? normalized.last.map {
                    $0.start + self.referenceSessionDuration(Double($0.values.count) / $0.frame.sampleRate)
                } ?? start
                if !sequenceGapDetected && (frame.discontinuity || (previousRate.map { frame.sampleRate != $0 } ?? false)) {
                    self.appendEpochEvent(start, to: &epochEvents)
                    #if DEBUG
                    resyncEvents.append(start)
                    #endif
                }
                // A reset marker and a measured positive timing hole are independent:
                // a route/rate/discontinuity transition can be contiguous (the common
                // case) or can also contain a real missing interval. Preserve the
                // latter instead of hiding it behind the epoch marker.
                if !sequenceGapDetected && start > previousEnd + 1e-9 {
                    self.appendEpochEvent(start, to: &epochEvents)
                    self.appendGap(previousEnd..<start, to: &gaps)
                    #if DEBUG
                    resyncEvents.append(start)
                    #endif
                }
            }
            previousPTS = frame.presentationTime
            previousSequence = frame.sequenceNumber
            previousRate = frame.sampleRate
            // Keep the original PTS (including the retained post-priming position) for
            // provenance; `start` remains the anchored/transformed session coordinate.
            normalized.append((
                frame,
                start,
                frame.presentationTime + Double(leading) / frame.sampleRate,
                nil,
                nil,
                values,
                false
            ))
            previousRejectedEnd = nil
        }
        if self.configuration.codecRemainderSamples > 0, let last = normalized.indices.last {
            let trim = min(configuration.codecRemainderSamples, normalized[last].values.count)
            if trim > 0 { normalized[last].values.removeLast(trim) }
        }
        let segments = normalized.map { TimedSegment(
            start: $0.start,
            sourceStart: $0.sourceStart,
            sourceTimelineStart: $0.sourceStart,
            sourceSampleTime: $0.sourceSampleTime,
            hostTime: $0.hostTime,
            sourceSampleRate: $0.frame.sampleRate,
            sessionSampleRate: $0.frame.sampleRate / self.referenceTimelineScale,
            timelineScale: self.referenceTimelineScale,
            values: $0.values,
            synthesized: false
        ) }
        return self.makeTrackGrid(
            segments: segments,
            sourceOrigin: normalized.first?.sourceStart,
            firstTime: normalized.map { $0.start }.min(),
            epochEvents: epochEvents,
            resynchronizationEvents: resyncEvents,
            gaps: gaps,
            synthesizedFrameCount: 0
        )
    }

    private func makeTrackGrid(
        segments: [TimedSegment], sourceOrigin: Double?, firstTime: Double?, epochEvents: [Double], resynchronizationEvents: [Double], gaps: [Range<Double>], synthesizedFrameCount: Int
    ) -> TrackGrid {
        let first = firstTime
        let last = segments.map { $0.start + Double($0.values.count) / $0.sessionSampleRate }.max()
        return TrackGrid(
            segments: segments,
            sourceOrigin: sourceOrigin,
            firstTime: first,
            lastTime: last,
            epochEvents: epochEvents,
            resynchronizationEvents: resynchronizationEvents,
            gapRanges: gaps,
            synthesizedFrameCount: synthesizedFrameCount
        )
    }

    private func makeGrid(track: TrackGrid, origin: Double, frameSize: Int, outputCount: Int) -> Grid {
        guard track.firstTime != nil, track.lastTime != nil, outputCount > 0 else {
            return Grid(
                samples: [Float](repeating: 0, count: outputCount),
                valid: [Bool](repeating: false, count: outputCount),
                sourceTimes: [Double?](repeating: nil, count: outputCount),
                microphoneSampleTimes: [Int64?](repeating: nil, count: outputCount),
                microphoneHostTimes: [Double?](repeating: nil, count: outputCount)
            )
        }
        // The caller has already bounded `outputCount` after checking all span
        // arithmetic. Do not derive a second allocation length from untrusted clock
        // deltas here; segments outside the requested output window are clipped.
        var samples = [Float](repeating: 0, count: outputCount)
        var valid = [Bool](repeating: false, count: outputCount)
        var sourceTimes = [Double?](repeating: nil, count: outputCount)
        var microphoneSampleTimes = [Int64?](repeating: nil, count: outputCount)
        var microphoneHostTimes = [Double?](repeating: nil, count: outputCount)
        for segment in track.segments {
            let relativeIndex = (segment.start - origin) * self.configuration.analysisSampleRate
            guard let roundedIndex = safeRoundedInt(relativeIndex) else { continue }
            let startIndex = max(0, roundedIndex)
            let segmentEnd = segment.start + Double(segment.values.count) / segment.sessionSampleRate
            let relativeEndIndex = (segmentEnd - origin) * self.configuration.analysisSampleRate
            guard let roundedEndIndex = safeRoundedInt(relativeEndIndex) else { continue }
            let (targetCount, targetOverflow) = roundedEndIndex.subtractingReportingOverflow(roundedIndex)
            guard !targetOverflow, targetCount > 0 else { continue }
            let converted = self.resample(
                segment.values,
                fromRate: segment.sessionSampleRate,
                toRate: self.configuration.analysisSampleRate,
                maximumCount: outputCount,
                targetCount: targetCount
            )
            for (offset, value) in converted.enumerated() {
                let (index, indexOverflow) = startIndex.addingReportingOverflow(offset)
                guard !indexOverflow else { break }
                guard index >= 0, index < samples.count else { continue }
                // A duplicate overlap is a gap/epoch condition; first-arrival order is stable.
                if !valid[index] {
                    samples[index] = value
                    valid[index] = value.isFinite
                    let sourceOffsetSamples = Double(offset) * segment.sourceSampleRate
                        / self.configuration.analysisSampleRate / segment.timelineScale
                    sourceTimes[index] = segment.sourceTimelineStart + sourceOffsetSamples / segment.sourceSampleRate
                    microphoneSampleTimes[index] = segment.sourceSampleTime.flatMap {
                        let offset = sourceOffsetSamples.rounded()
                        guard offset.isFinite, offset > Double(Int64.min), offset < Double(Int64.max) else { return nil }
                        let offsetInt = Int64(offset)
                        let (sum, overflow) = $0.addingReportingOverflow(offsetInt)
                        return overflow ? nil : sum
                    }
                    microphoneHostTimes[index] = segment.hostTime.map { $0 + sourceOffsetSamples / segment.sourceSampleRate }
                }
            }
        }
        _ = frameSize
        return Grid(
            samples: samples,
            valid: valid,
            sourceTimes: sourceTimes,
            microphoneSampleTimes: microphoneSampleTimes,
            microphoneHostTimes: microphoneHostTimes
        )
    }

    private func resample(
        _ values: [Float],
        fromRate: Double,
        toRate: Double,
        maximumCount: Int,
        targetCount: Int? = nil
    ) -> [Float] {
        guard !values.isEmpty, self.finite(fromRate), fromRate > 0, self.finite(toRate), toRate > 0 else { return [] }
        guard maximumCount > 0 else { return [] }
        let count: Int
        if let targetCount {
            guard targetCount > 0 else { return [] }
            count = min(maximumCount, targetCount)
        } else {
            let countDouble = (Double(values.count) * toRate / fromRate).rounded()
            guard countDouble.isFinite, countDouble >= 1, countDouble < Double(Int.max) else { return [] }
            count = min(maximumCount, Int(countDouble))
        }
        if count == values.count { return values }
        return (0..<count).map { index in
            let position = Double(index) * fromRate / toRate
            let lower = min(values.count - 1, Int(position.rounded(.down)))
            let upper = min(values.count - 1, lower + 1)
            let fraction = Float(position - Double(lower))
            return values[lower] + (values[upper] - values[lower]) * fraction
        }
    }

    /// Maps a reference-domain PTS into session time. Every caller uses this helper for
    /// both segment starts and epoch/gap events, so edit-list and converter transforms cannot
    /// silently diverge from the frame grid.
    private func referenceSessionTime(sourceTime: Double) -> Double {
        let scale = self.referenceTimelineScale
        return sourceTime * scale + self.configuration.editListOffsetSeconds * scale
            - self.configuration.referenceConverter.algorithmicDelaySeconds
            + self.configuration.referenceToMicrophoneOffsetSeconds
    }

    private func referenceSessionDuration(_ sourceDuration: Double) -> Double {
        sourceDuration * self.referenceTimelineScale
    }

    private var referenceTimelineScale: Double {
        1 + self.configuration.referenceClockDriftPPM / 1_000_000
    }

    private func downmix(_ samples: [Float], channels: Int) -> [Float] {
        guard channels > 0 else { return [] }
        let count = samples.count / channels
        // Deterministic first-slice policy: arithmetic mean of interleaved channels. This is
        // not a calibrated perceptual downmix; channel-layout metadata and a measured error
        // budget remain deferred to the multichannel fixture phase.
        return (0..<count).map { index in
            let base = index * channels
            // Accumulate in Double so finite Float samples (for example, two
            // `.greatestFiniteMagnitude` channels) cannot overflow to infinity
            // during the mean and silently become an invalid grid sample.
            let sum = samples[base..<base + channels].reduce(0.0) { partial, sample in
                partial + Double(sample)
            }
            return Float(sum / Double(channels))
        }
    }

    private func orderedUnique(_ reasons: [MeetingSynchronizerUnknownReason]) -> [MeetingSynchronizerUnknownReason] {
        let order = MeetingSynchronizerUnknownReason.allCases
        return order.filter { reasons.contains($0) }
    }

    /// Epoch markers from the two source tracks can describe the same reset boundary.
    /// Merge them in session-time order so a shared microphone/reference reset advances
    /// the output epoch exactly once, independent of which track was visited first.
    private func deduplicatedEpochEvents(_ events: [Double]) -> [Double] {
        events.filter { $0.isFinite }.sorted().reduce(into: [Double]()) { result, event in
            guard !result.contains(where: { abs($0 - event) <= 1e-9 }) else { return }
            result.append(event)
        }
    }

    private func appendEpochEvent(_ time: Double, to events: inout [Double]) {
        guard time.isFinite else { return }
        guard !events.contains(where: { abs($0 - time) <= 1e-9 }) else { return }
        events.append(time)
    }

    private func appendGap(_ range: Range<Double>, to gaps: inout [Range<Double>]) {
        guard range.lowerBound.isFinite, range.upperBound.isFinite,
              range.upperBound > range.lowerBound + 1e-9 else { return }
        guard !gaps.contains(where: {
            abs($0.lowerBound - range.lowerBound) <= 1e-9
                && abs($0.upperBound - range.upperBound) <= 1e-9
        }) else { return }
        gaps.append(range)
    }

    private func safeSampleDelta(_ lhs: Int64, _ rhs: Int64) -> Double? {
        let (delta, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else { return nil }
        let value = Double(delta)
        return value.isFinite ? value : nil
    }

    private func safeInt64Delta(_ lhs: Int64, _ rhs: Int64) -> Int64? {
        let (delta, overflow) = lhs.subtractingReportingOverflow(rhs)
        return overflow ? nil : delta
    }

    private func safeRoundedInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard rounded > Double(Int.min), rounded < Double(Int.max) else { return nil }
        return Int(rounded)
    }

    private func finite(_ value: Double) -> Bool { value.isFinite }
}
