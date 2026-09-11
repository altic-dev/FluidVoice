#if DEBUG

import Foundation
import CoreMedia

/// Phase 0 C2 is deliberately diagnostic-only.  The collector receives metadata from the two
/// outputs of one ScreenCaptureKit stream, but never receives (or retains) PCM, transcript text,
/// identities, titles, paths, or URLs.  It does not establish a shared clock, acoustic latency,
/// echo cancellation, or a product-quality reference.
nonisolated enum MeetingSCKPairedDiagnosticGate {
    static let environmentKey = "FLUIDVOICE_C2_DIAGNOSTICS"
    static let hardwareEnvironmentKey = "FLUIDVOICE_C2_HARDWARE"
    static let targetBundleIDEnvironmentKey = "FLUIDVOICE_C2_TARGET_BUNDLE_ID"
    static let autorunEnvironmentKey = "FLUIDVOICE_C2_AUTORUN"

    static func enabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[Self.environmentKey] == "1"
    }

    static func hardwareEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard self.enabled(environment: environment), environment[Self.hardwareEnvironmentKey] == "1" else {
            return false
        }
        return !(environment[Self.targetBundleIDEnvironmentKey] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func autorunEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        self.hardwareEnabled(environment: environment)
            && environment[Self.autorunEnvironmentKey] == "1"
    }
}

nonisolated enum MeetingSCKPairedOutput: String, Codable, CaseIterable, Sendable {
    case applicationAudio = "audio"
    case microphone
}

/// Provenance is intentionally reduced to a scope enum and a positive selection assertion.  No
/// application identity, window title, URL, or other user data is carried into C2 diagnostics.
nonisolated enum MeetingSCKPairedDiagnosticScope: String, Codable, CaseIterable, Sendable {
    case selectedApplicationWindow
    case selectedApplicationDisplay
}

nonisolated struct MeetingSCKPairedDiagnosticProvenance: Codable, Equatable, Sendable {
    let scope: MeetingSCKPairedDiagnosticScope
    let applicationSelectionConfirmed: Bool
    let captureMethod: String

    init(
        scope: MeetingSCKPairedDiagnosticScope,
        applicationSelectionConfirmed: Bool,
        captureMethod: String = "screenCaptureKit"
    ) {
        self.scope = scope
        self.applicationSelectionConfirmed = applicationSelectionConfirmed
        self.captureMethod = captureMethod
    }

    var isValid: Bool {
        self.applicationSelectionConfirmed && self.captureMethod == "screenCaptureKit"
    }
}

/// Metadata copied synchronously at a ScreenCaptureKit callback boundary.  This type intentionally
/// has no buffer or sample payload.  `arrivalSeconds` should come from a monotonic clock sampled by
/// the callback owner; it is only used to describe delivery jitter.
nonisolated struct MeetingSCKPairedDiagnosticSample: Sendable {
    let output: MeetingSCKPairedOutput
    let presentationSeconds: Double?
    let durationSeconds: Double?
    let frameCount: Int
    let sampleRateHz: Double
    let channelCount: Int
    let arrivalSeconds: Double?

    init(
        output: MeetingSCKPairedOutput,
        presentationSeconds: Double?,
        durationSeconds: Double?,
        frameCount: Int,
        sampleRateHz: Double,
        channelCount: Int,
        arrivalSeconds: Double? = nil
    ) {
        self.output = output
        self.presentationSeconds = presentationSeconds
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.arrivalSeconds = arrivalSeconds
    }
}

nonisolated struct MeetingSCKPairedDiagnosticConfiguration: Equatable, Sendable {
    static let defaultMaximumSamples = 20_000
    let maximumSamples: Int

    init(maximumSamples: Int = Self.defaultMaximumSamples) {
        self.maximumSamples = max(1, maximumSamples)
    }
}

nonisolated struct MeetingSCKPairedTrackReport: Codable, Equatable, Sendable {
    let sampleCount: Int
    let validTimestampCount: Int
    let invalidTimestampCount: Int
    let deliveredDurationSeconds: Double
    let firstPresentationSeconds: Double?
    let lastPresentationEndSeconds: Double?
    let timestampSpanSeconds: Double?
    let coverageFraction: Double?
    let gapCount: Int
    let gapDurationSeconds: Double
    let overlapCount: Int
    let backwardsTimestampCount: Int
    let formatChangeCount: Int
    let firstSampleRateHz: Double?
    let firstChannelCount: Int?
    let jitterObservationCount: Int
    let meanAbsoluteJitterSeconds: Double?
    let maxAbsoluteJitterSeconds: Double?
    let malformedMetadataCount: Int

    fileprivate init(state: MeetingSCKPairedTrackState) {
        self.sampleCount = state.sampleCount
        self.validTimestampCount = state.validTimestampCount
        self.invalidTimestampCount = state.invalidTimestampCount
        self.deliveredDurationSeconds = state.deliveredDurationSeconds
        self.firstPresentationSeconds = state.firstPresentationSeconds
        self.lastPresentationEndSeconds = state.lastPresentationEndSeconds
        if let first = state.firstPresentationSeconds, let end = state.lastPresentationEndSeconds {
            self.timestampSpanSeconds = max(0, end - first)
        } else {
            self.timestampSpanSeconds = nil
        }
        if let span = self.timestampSpanSeconds, span > 0 {
            self.coverageFraction = min(1, max(0, state.deliveredDurationSeconds / span))
        } else {
            self.coverageFraction = nil
        }
        self.gapCount = state.gapCount
        self.gapDurationSeconds = state.gapDurationSeconds
        self.overlapCount = state.overlapCount
        self.backwardsTimestampCount = state.backwardsTimestampCount
        self.formatChangeCount = state.formatChangeCount
        self.firstSampleRateHz = state.firstSampleRateHz
        self.firstChannelCount = state.firstChannelCount
        self.jitterObservationCount = state.jitterObservationCount
        self.meanAbsoluteJitterSeconds = state.jitterObservationCount > 0
            ? state.jitterAbsoluteSum / Double(state.jitterObservationCount) : nil
        self.maxAbsoluteJitterSeconds = state.maxAbsoluteJitterSeconds
        self.malformedMetadataCount = state.malformedMetadataCount
    }
}

nonisolated struct MeetingSCKPairedCrossTrackReport: Codable, Equatable, Sendable {
    /// This is microphone PTS minus application PTS.  It is a timestamp-origin offset, not an
    /// acoustic or processing latency measurement.
    let firstPresentationOffsetSeconds: Double?
    let lastPresentationOffsetSeconds: Double?
    /// Difference between the two observed PTS spans, expressed in parts per million. This is a
    /// delivery-window diagnostic, not a clock-drift estimate; independent PTS epochs and unequal
    /// start/stop boundaries make oscillator drift unidentifiable here.
    let relativeTimestampSpanDifferencePPM: Double?
    let timestampRelationship: String
    let acousticDelaySeconds: Double?
    let sharedClockEstablished: Bool
    let aecEvaluated: Bool

    fileprivate init(application: MeetingSCKPairedTrackReport, microphone: MeetingSCKPairedTrackReport) {
        if let app = application.firstPresentationSeconds, let mic = microphone.firstPresentationSeconds {
            self.firstPresentationOffsetSeconds = mic - app
        } else {
            self.firstPresentationOffsetSeconds = nil
        }
        if let app = application.lastPresentationEndSeconds, let mic = microphone.lastPresentationEndSeconds {
            self.lastPresentationOffsetSeconds = mic - app
        } else {
            self.lastPresentationOffsetSeconds = nil
        }
        if let appSpan = application.timestampSpanSeconds, let micSpan = microphone.timestampSpanSeconds,
           appSpan > 0, micSpan.isFinite {
            self.relativeTimestampSpanDifferencePPM = (micSpan / appSpan - 1) * 1_000_000
        } else {
            self.relativeTimestampSpanDifferencePPM = nil
        }
        self.timestampRelationship = "independent PTS origins; delivery-window span difference; clock drift not identifiable"
        self.acousticDelaySeconds = nil
        self.sharedClockEstablished = false
        self.aecEvaluated = false
    }
}

nonisolated struct MeetingSCKPairedDiagnosticReport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let enabled: Bool
    let boundedMaximumSamples: Int
    let acceptedSampleCount: Int
    let droppedAfterBoundCount: Int
    let application: MeetingSCKPairedTrackReport
    let microphone: MeetingSCKPairedTrackReport
    let crossTrack: MeetingSCKPairedCrossTrackReport
    let provenance: MeetingSCKPairedDiagnosticProvenance?
    let rejectedProvenanceCount: Int
    let rawPCMRetained: Bool
    let transcriptRetained: Bool
    let failOpen: Bool
    let reasons: [String]

    fileprivate init(
        enabled: Bool,
        configuration: MeetingSCKPairedDiagnosticConfiguration,
        acceptedSampleCount: Int,
        droppedAfterBoundCount: Int,
        application: MeetingSCKPairedTrackReport,
        microphone: MeetingSCKPairedTrackReport,
        provenance: MeetingSCKPairedDiagnosticProvenance?,
        rejectedProvenanceCount: Int
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.enabled = enabled
        self.boundedMaximumSamples = configuration.maximumSamples
        self.acceptedSampleCount = acceptedSampleCount
        self.droppedAfterBoundCount = droppedAfterBoundCount
        self.application = application
        self.microphone = microphone
        self.crossTrack = MeetingSCKPairedCrossTrackReport(application: application, microphone: microphone)
        self.provenance = provenance
        self.rejectedProvenanceCount = rejectedProvenanceCount
        self.rawPCMRetained = false
        self.transcriptRetained = false
        self.failOpen = true
        self.reasons = [
            "diagnostic-only",
            "no raw PCM or transcript retention",
            "shared clock not established",
            "acoustic delay and AEC not evaluated"
        ]
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Thread-safe, bounded metadata collector suitable for a callback adapter.  It is intentionally
/// Metadata is copied synchronously at the SCK callback boundary. The collector never retains a
/// CMSampleBuffer, PCM, transcript, or source identity. It remains inert unless the explicit gate is
/// enabled.
final nonisolated class MeetingSCKPairedDiagnosticCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: MeetingSCKPairedDiagnosticConfiguration
    private let isEnabled: Bool
    private var acceptedSampleCount = 0
    private var droppedAfterBoundCount = 0
    private var provenance: MeetingSCKPairedDiagnosticProvenance?
    private var rejectedProvenanceCount = 0
    private var applicationState = MeetingSCKPairedTrackState()
    private var microphoneState = MeetingSCKPairedTrackState()

    init(
        configuration: MeetingSCKPairedDiagnosticConfiguration = .init(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.configuration = configuration
        self.isEnabled = MeetingSCKPairedDiagnosticGate.enabled(environment: environment)
    }

    var enabled: Bool { self.isEnabled }

    func record(_ sample: MeetingSCKPairedDiagnosticSample) {
        guard self.isEnabled else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.recordLocked(sample)
    }

    /// Records a metadata-only callback after requiring stable, explicit selected-app provenance.
    /// A provenance change is rejected rather than silently combining unrelated capture scopes.
    @discardableResult
    func record(
        _ sample: MeetingSCKPairedDiagnosticSample,
        provenance: MeetingSCKPairedDiagnosticProvenance
    ) -> Bool {
        guard self.isEnabled else { return false }
        self.lock.lock()
        defer { self.lock.unlock() }
        guard provenance.isValid else {
            self.rejectedProvenanceCount += 1
            return false
        }
        if let existing = self.provenance, existing != provenance {
            self.rejectedProvenanceCount += 1
            return false
        }
        self.provenance = provenance
        self.recordLocked(sample)
        return true
    }

    /// Extracts only numeric timing and format metadata while the callback is active. The sample
    /// buffer is not passed to, retained by, or stored in the collector.
    @discardableResult
    func record(
        sampleBuffer: CMSampleBuffer,
        output: MeetingSCKPairedOutput,
        provenance: MeetingSCKPairedDiagnosticProvenance
    ) -> Bool {
        guard self.isEnabled else { return false }
        return self.record(
            Self.metadata(from: sampleBuffer, output: output),
            provenance: provenance
        )
    }

    private func recordLocked(_ sample: MeetingSCKPairedDiagnosticSample) {
        guard self.acceptedSampleCount < self.configuration.maximumSamples else {
            self.droppedAfterBoundCount += 1
            return
        }
        self.acceptedSampleCount += 1
        switch sample.output {
        case .applicationAudio: self.applicationState.record(sample)
        case .microphone: self.microphoneState.record(sample)
        }
    }

    func report() -> MeetingSCKPairedDiagnosticReport {
        self.lock.lock()
        defer { self.lock.unlock() }
        return MeetingSCKPairedDiagnosticReport(
            enabled: self.isEnabled,
            configuration: self.configuration,
            acceptedSampleCount: self.acceptedSampleCount,
            droppedAfterBoundCount: self.droppedAfterBoundCount,
            application: MeetingSCKPairedTrackReport(state: self.applicationState),
            microphone: MeetingSCKPairedTrackReport(state: self.microphoneState),
            provenance: self.provenance,
            rejectedProvenanceCount: self.rejectedProvenanceCount
        )
    }

    private static func metadata(
        from sampleBuffer: CMSampleBuffer,
        output: MeetingSCKPairedOutput
    ) -> MeetingSCKPairedDiagnosticSample {
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        let streamDescription = formatDescription.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        let pts = Self.finiteSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let duration = Self.finiteSeconds(CMSampleBufferGetDuration(sampleBuffer))
        return MeetingSCKPairedDiagnosticSample(
            output: output,
            presentationSeconds: pts,
            durationSeconds: duration,
            frameCount: CMSampleBufferGetNumSamples(sampleBuffer),
            sampleRateHz: streamDescription?.mSampleRate ?? .nan,
            channelCount: Int(streamDescription?.mChannelsPerFrame ?? 0),
            arrivalSeconds: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func finiteSeconds(_ time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? seconds : nil
    }
}

/// Deterministic, non-live harness for unit tests and local metadata fixtures.  The fixture is
/// consumed synchronously and is not retained; callers must still provide metadata only.
nonisolated enum MeetingSCKPairedDiagnosticHarness {
    static func run(
        _ samples: [MeetingSCKPairedDiagnosticSample],
        configuration: MeetingSCKPairedDiagnosticConfiguration = .init(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MeetingSCKPairedDiagnosticReport {
        let collector = MeetingSCKPairedDiagnosticCollector(configuration: configuration, environment: environment)
        for sample in samples { collector.record(sample) }
        return collector.report()
    }
}

nonisolated private struct MeetingSCKPairedTrackState {
    var sampleCount = 0
    var validTimestampCount = 0
    var invalidTimestampCount = 0
    var deliveredDurationSeconds = 0.0
    var firstPresentationSeconds: Double?
    var lastPresentationEndSeconds: Double?
    var previousPresentationSeconds: Double?
    var previousDurationSeconds: Double?
    var previousSampleRateHz: Double?
    var previousArrivalSeconds: Double?
    var gapCount = 0
    var gapDurationSeconds = 0.0
    var overlapCount = 0
    var backwardsTimestampCount = 0
    var formatChangeCount = 0
    var firstSampleRateHz: Double?
    var firstChannelCount: Int?
    var jitterObservationCount = 0
    var jitterAbsoluteSum = 0.0
    var maxAbsoluteJitterSeconds: Double?
    var malformedMetadataCount = 0

    mutating func record(_ sample: MeetingSCKPairedDiagnosticSample) {
        self.sampleCount += 1
        let validFormat = sample.sampleRateHz.isFinite && sample.sampleRateHz > 0
            && sample.channelCount > 0 && sample.frameCount > 0
        let validDuration = sample.durationSeconds.map { $0.isFinite && $0 > 0 } ?? false
        let validPTS = sample.presentationSeconds.map(\.isFinite) ?? false
        let validFrameGeometry: Bool = {
            guard validFormat, validDuration else { return false }
            let frameDuration = Double(sample.frameCount) / sample.sampleRateHz
            let tolerance = max(1.5 / sample.sampleRateHz, 0.001)
            return frameDuration.isFinite && abs(frameDuration - sample.durationSeconds!) <= tolerance
        }()
        let validEnd: Bool = {
            guard validPTS, validDuration else { return false }
            return (sample.presentationSeconds! + sample.durationSeconds!).isFinite
        }()
        guard validFormat && validDuration && validPTS && validFrameGeometry && validEnd else {
            self.invalidTimestampCount += validPTS ? 0 : 1
            self.malformedMetadataCount += 1
            return
        }

        let pts = sample.presentationSeconds!
        let duration = sample.durationSeconds!
        self.validTimestampCount += 1
        self.deliveredDurationSeconds += duration
        if self.firstSampleRateHz == nil {
            self.firstSampleRateHz = sample.sampleRateHz
            self.firstChannelCount = sample.channelCount
        } else if self.firstSampleRateHz != sample.sampleRateHz || self.firstChannelCount != sample.channelCount {
            self.formatChangeCount += 1
        }

        if let previousPTS = self.previousPresentationSeconds,
           let previousDuration = self.previousDurationSeconds {
            let delta = pts - previousPTS
            // CMTime-to-Double conversion can perturb an otherwise contiguous boundary by a few
            // nanoseconds. Half a sample is a conservative representational tolerance: it ignores
            // sub-sample arithmetic noise while still exposing a genuine one-sample gap/overlap.
            let samplePeriod = max(1.0 / sample.sampleRateHz, 1.0 / (self.previousSampleRateHz ?? sample.sampleRateHz))
            let continuityTolerance = max(1e-9, 0.5 * samplePeriod)
            let deltaError = delta - previousDuration
            if delta < -continuityTolerance {
                self.backwardsTimestampCount += 1
            } else if deltaError > continuityTolerance {
                self.gapCount += 1
                self.gapDurationSeconds += deltaError
            } else if deltaError < -continuityTolerance {
                self.overlapCount += 1
            }
        }
        if let arrival = sample.arrivalSeconds, arrival.isFinite,
           let previousArrival = self.previousArrivalSeconds,
           let previousDuration = self.previousDurationSeconds {
            let deliveryDelta = arrival - previousArrival
            if deliveryDelta.isFinite && deliveryDelta >= 0 {
                let jitter = abs(deliveryDelta - previousDuration)
                self.jitterObservationCount += 1
                self.jitterAbsoluteSum += jitter
                self.maxAbsoluteJitterSeconds = max(self.maxAbsoluteJitterSeconds ?? 0, jitter)
            }
        }
        self.firstPresentationSeconds = self.firstPresentationSeconds ?? pts
        self.lastPresentationEndSeconds = max(self.lastPresentationEndSeconds ?? pts, pts + duration)
        self.previousPresentationSeconds = pts
        self.previousDurationSeconds = duration
        self.previousSampleRateHz = sample.sampleRateHz
        self.previousArrivalSeconds = sample.arrivalSeconds?.isFinite == true ? sample.arrivalSeconds : nil
    }
}

#endif
