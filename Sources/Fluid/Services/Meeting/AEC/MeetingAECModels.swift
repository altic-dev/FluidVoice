@preconcurrency import AVFoundation
import CoreMedia
import Foundation

nonisolated enum MeetingAECInputKind: String, Sendable {
    case render
    case capture
}

/// A runtime-local identity. The owner still verifies `SCStream` object identity before creating
/// this value; the token lets the pure joiner reject cross-stream data without retaining SCK.
nonisolated struct MeetingAECStreamToken: Hashable, Sendable {
    let generation: UInt64
    let identity: UInt64
}

nonisolated enum MeetingAECFailure: String, Error, Equatable, Sendable {
    case invalidSampleBuffer
    case invalidTimestamp
    case invalidDuration
    case unsupportedFormat
    case unsupportedSampleRate
    case formatChanged
    case nonFiniteSamples
    case streamChanged
    case timestampEpochChanged
    case timestampGap
    case timestampOverlap
    case timestampMovedBackward
    case clockResidualExceeded
    case renderLate
    case callbackBlockLimit
    case retainedSampleLimit
    case writerQueueFull
    case bridgeInitialization
    case bridgeProcessing
    case bridgeNonFiniteOutput
    case outputSynthesis
    case metadataPersistence
    case stopped
}

nonisolated struct MeetingAECPCMFormat: Equatable, Sendable {
    let channelCount: Int
    let interleaved: Bool

    static let monoPlanar = Self(channelCount: 1, interleaved: false)
}

nonisolated struct MeetingAECPCMBlock: Equatable, Sendable {
    let kind: MeetingAECInputKind
    let stream: MeetingAECStreamToken
    let presentationTime: CMTime
    let duration: CMTime
    let samples: [Float]
    let sourceFormat: MeetingAECPCMFormat

    init(
        kind: MeetingAECInputKind,
        stream: MeetingAECStreamToken,
        presentationTime: CMTime,
        duration: CMTime,
        samples: [Float],
        sourceFormat: MeetingAECPCMFormat = .monoPlanar
    ) {
        self.kind = kind
        self.stream = stream
        self.presentationTime = presentationTime
        self.duration = duration
        self.samples = samples
        self.sourceFormat = sourceFormat
    }

    var endTime: CMTime {
        CMTimeAdd(self.presentationTime, CMTime(value: CMTimeValue(self.samples.count), timescale: 48_000))
    }
}

nonisolated struct MeetingAECFrame: Equatable, Sendable {
    static let sampleCount = 480
    static let sampleRateHz = 48_000

    let presentationTime: CMTime
    let samples: [Float]

    init(presentationTime: CMTime, samples: [Float]) {
        precondition(samples.count == Self.sampleCount)
        self.presentationTime = presentationTime
        self.samples = samples
    }

    var duration: CMTime {
        CMTime(value: CMTimeValue(Self.sampleCount), timescale: CMTimeScale(Self.sampleRateHz))
    }
}

nonisolated struct MeetingAECJoinedFrame: Equatable, Sendable {
    let render: MeetingAECFrame
    let capture: MeetingAECFrame
    /// True only after all 96,000 samples per source have been covered exactly once and all
    /// fixed-anchor/common-grid checks have continued to pass.
    let clockAttested: Bool
    let pairedFrameCount: Int
}

nonisolated struct MeetingAECBypassSlice: Equatable, Sendable {
    let presentationTime: CMTime
    let samples: [Float]
}

nonisolated enum MeetingAECJoinerEmission: Equatable, Sendable {
    case paired(MeetingAECJoinedFrame)
    case bypass(MeetingAECBypassSlice, MeetingAECFailure)
    case reset(MeetingAECFailure)
}

nonisolated struct MeetingAECBridgeStatistics: Equatable, Sendable {
    var renderFrames: UInt64
    var captureFrames: UInt64
    var resets: UInt64
    var estimatedDelayMilliseconds: Int?
    var residualEchoLikelihood: Float?
}

nonisolated struct MeetingAECDiagnostics: Equatable, Sendable {
    var acceptedRenderBlocks = 0
    var acceptedCaptureBlocks = 0
    var pairedFrames = 0
    var bypassFrames = 0
    var resets = 0
    var retainedRenderBlocks = 0
    var retainedCaptureBlocks = 0
    var retainedRenderSamples = 0
    var retainedCaptureSamples = 0
    var lastFailure: MeetingAECFailure?
}

nonisolated enum MeetingAECConstants {
    static let sampleRateHz = 48_000
    static let frameSamples = 480
    static let attestationSamples = 96_000
    static let attestationFrames = 200
    static let maximumBlocksPerInput = 64
    static let maximumSamplesPerInput = 24_000
    static let maximumCaptureWaitSamples = 4_800
    static let maximumClockResidualSamples: Int64 = 1

    static let provenance = MeetingAECProvenance(
        upstreamRevision: "d9bd07ba5f614156021df666ba4052ac73cf7953",
        bridgeConfigurationID: "webrtc-aec3-48k-mono-cxx20-no-protobuf-no-log-v1",
        sampleRateHz: sampleRateHz,
        frameDurationMilliseconds: 10
    )
}
