import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Stage 0.5 is an offline evidence gate.  It is deliberately independent from capture,
/// transcription, and any echo-canceller implementation.  The input structs may contain PCM
/// while an evaluation is running, but the returned report never contains PCM, text, paths, or
/// user identities.
public enum MeetingSignalDomainGateOutcome: String, Codable, Sendable {
    case proceedToCandidate
    case rejected
    case unscored
}

public enum MeetingSignalDomainGateReason: String, Codable, CaseIterable, Sendable {
    case invalidManifest
    case missingConsent
    case unsupportedTopology
    case unsupportedRoute
    case nonLossless
    case unsupportedCodec
    case sourceHashMismatch
    case metadataOnly
    case invalidTiming
    case insufficientCoverage
    case excessiveDrift
    case delayNonCausal
    case delayOutsideSearchRange
    case lowExcitation
    case unstablePath
    case clipping
    case linearPathUnlearnable
    case referenceScopeLimited
    case referenceCompletenessUnobservable
    case noEligibleSessions
    case invalidThresholds
    case duplicateOrdinal
    case inconsistentGeometry
    case missingArrivalMetadata
    case gapDetected
    case overlappingBlocks
    case driftUnscored
    case linearPathUnscored
    case delayUnresolved
    case insufficientTimingObservations
    case analysisResourceLimitExceeded
}

public enum MeetingSignalDomainGateTopology: String, Codable, CaseIterable, Sendable {
    case pairedScreenCaptureKit
    case vpio
    case synthetic
    case metadataOnly
    case unknown
}

public enum MeetingSignalDomainGateRoute: String, Codable, CaseIterable, Sendable {
    case builtInSpeakerMicrophone
    case externalDevice
    case unknown
}

public enum MeetingSignalDomainGateReferenceScope: String, Codable, CaseIterable, Sendable {
    case selectedApplication
    case selectedWindow
    case authorizedFullMix
    case unknown
}

/// The checked-in manifest is metadata-only.  Paths are relative to the caller-provided private
/// corpus root and are never copied into a report.
public struct MeetingSignalDomainGateManifest: Codable, Equatable, Sendable {
    public struct Artifact: Codable, Equatable, Sendable {
        public let role: String
        public let relativePath: String
        public let sha256: String
        public let codec: String
        public let lossless: Bool
        public let sampleRateHz: Double
        public let channelCount: Int
        public let durationSeconds: Double
        public let developmentOnly: Bool

        public init(role: String, relativePath: String, sha256: String, codec: String,
                    lossless: Bool, sampleRateHz: Double, channelCount: Int,
                    durationSeconds: Double, developmentOnly: Bool = true) {
            self.role = role
            self.relativePath = relativePath
            self.sha256 = sha256
            self.codec = codec
            self.lossless = lossless
            self.sampleRateHz = sampleRateHz
            self.channelCount = channelCount
            self.durationSeconds = durationSeconds
            self.developmentOnly = developmentOnly
        }
    }

    public struct TimingBlock: Codable, Equatable, Sendable {
        public let presentationSeconds: Double
        public let durationSeconds: Double
        public let frameCount: Int
        public let arrivalSeconds: Double?

        public init(presentationSeconds: Double, durationSeconds: Double, frameCount: Int,
                    arrivalSeconds: Double?) {
            self.presentationSeconds = presentationSeconds; self.durationSeconds = durationSeconds
            self.frameCount = frameCount; self.arrivalSeconds = arrivalSeconds
        }
    }

    public struct Session: Codable, Equatable, Sendable {
        public let ordinal: Int
        public let render: Artifact
        public let capture: Artifact
        public let renderTiming: [TimingBlock]
        public let captureTiming: [TimingBlock]

        public init(ordinal: Int, render: Artifact, capture: Artifact,
                    renderTiming: [TimingBlock], captureTiming: [TimingBlock]) {
            self.ordinal = ordinal; self.render = render; self.capture = capture
            self.renderTiming = renderTiming; self.captureTiming = captureTiming
        }
    }

    public let schemaVersion: Int
    public let topology: MeetingSignalDomainGateTopology
    public let route: MeetingSignalDomainGateRoute
    public let referenceScope: MeetingSignalDomainGateReferenceScope
    public let referenceCompletenessMeasured: Bool
    public let consentConfirmed: Bool
    public let artifacts: [Artifact]
    public let sessions: [Session]
    public let provenanceRelativePath: String?
    public let provenanceSha256: String?

    public init(schemaVersion: Int = 1, topology: MeetingSignalDomainGateTopology,
                route: MeetingSignalDomainGateRoute,
                referenceScope: MeetingSignalDomainGateReferenceScope,
                referenceCompletenessMeasured: Bool,
                consentConfirmed: Bool, artifacts: [Artifact],
                sessions: [Session] = [], provenanceRelativePath: String? = nil,
                provenanceSha256: String? = nil) {
        self.schemaVersion = schemaVersion
        self.topology = topology
        self.route = route
        self.referenceScope = referenceScope
        self.referenceCompletenessMeasured = referenceCompletenessMeasured
        self.consentConfirmed = consentConfirmed
        self.artifacts = artifacts
        self.sessions = sessions
        self.provenanceRelativePath = provenanceRelativePath
        self.provenanceSha256 = provenanceSha256
    }

    public func validationReasons() -> [MeetingSignalDomainGateReason] {
        var reasons: [MeetingSignalDomainGateReason] = []
        if (provenanceRelativePath == nil) != (provenanceSha256 == nil) {
            reasons.append(.invalidManifest)
        }
        if let path = provenanceRelativePath,
           (!Self.isSafeRelativePath(path) || provenanceSha256?.count != 64
            || provenanceSha256 != provenanceSha256?.lowercased()
            || !(provenanceSha256 ?? "").unicodeScalars.allSatisfy(Self.isHex)) {
            reasons.append(.invalidManifest)
        }
        if schemaVersion != 1 { reasons.append(.invalidManifest) }
        if !consentConfirmed { reasons.append(.missingConsent) }
        if topology != .pairedScreenCaptureKit { reasons.append(.unsupportedTopology) }
        if route != .builtInSpeakerMicrophone { reasons.append(.unsupportedRoute) }
        if referenceScope == .unknown { reasons.append(.referenceScopeLimited) }
        if !referenceCompletenessMeasured { reasons.append(.referenceCompletenessUnobservable) }
        if !sessions.isEmpty {
            if !artifacts.isEmpty { reasons.append(.invalidManifest) }
            var sessionOrdinals = Set<Int>()
            for session in sessions {
                if session.ordinal < 0 || !sessionOrdinals.insert(session.ordinal).inserted { reasons.append(.invalidManifest) }
                if session.render.role.lowercased() != "render" || session.capture.role.lowercased() != "capture" {
                    reasons.append(.invalidManifest)
                }
                if session.render.relativePath == session.capture.relativePath { reasons.append(.invalidManifest) }
                if session.render.codec.lowercased() != session.capture.codec.lowercased()
                    || session.render.channelCount != session.capture.channelCount
                    || abs(session.render.sampleRateHz - session.capture.sampleRateHz) > 1e-6 {
                    reasons.append(.inconsistentGeometry)
                }
                for artifact in [session.render, session.capture] {
                    if !Self.isSafeRelativePath(artifact.relativePath) || artifact.sha256.count != 64
                        || artifact.sha256 != artifact.sha256.lowercased()
                        || !artifact.sha256.unicodeScalars.allSatisfy(Self.isHex)
                        || !artifact.lossless || !Self.losslessCodecs.contains(artifact.codec.lowercased())
                        || !artifact.sampleRateHz.isFinite || artifact.sampleRateHz <= 0
                        || artifact.channelCount <= 0 || !artifact.durationSeconds.isFinite
                        || !artifact.developmentOnly
                        || artifact.durationSeconds <= 0 { reasons.append(.invalidManifest) }
                    if !artifact.lossless { reasons.append(.nonLossless) }
                    if !Self.losslessCodecs.contains(artifact.codec.lowercased()) { reasons.append(.unsupportedCodec) }
                }
                reasons.append(contentsOf: Self.timingReasons(session.renderTiming, artifact: session.render))
                reasons.append(contentsOf: Self.timingReasons(session.captureTiming, artifact: session.capture))
            }
            return Self.unique(reasons)
        }
        guard artifacts.count == 2 else { return reasons + [.invalidManifest] }
        let roles = Set(artifacts.map { $0.role.lowercased() })
        if roles != Set(["render", "capture"]) { reasons.append(.invalidManifest) }
        if Set(artifacts.map(\.relativePath)).count != artifacts.count { reasons.append(.invalidManifest) }
        if artifacts.count == 2,
           abs(artifacts[0].sampleRateHz - artifacts[1].sampleRateHz) > 1e-6
            || artifacts[0].channelCount != artifacts[1].channelCount
            || artifacts[0].codec.lowercased() != artifacts[1].codec.lowercased() {
            reasons.append(.inconsistentGeometry)
        }
        for artifact in artifacts {
            if !Self.isSafeRelativePath(artifact.relativePath) || artifact.sha256.count != 64
                || artifact.sha256 != artifact.sha256.lowercased()
                || !artifact.sha256.unicodeScalars.allSatisfy(Self.isHex) {
                reasons.append(.invalidManifest)
            }
            if !artifact.lossless { reasons.append(.nonLossless) }
            let codec = artifact.codec.lowercased()
            if !Self.losslessCodecs.contains(codec) { reasons.append(.unsupportedCodec) }
            if !artifact.sampleRateHz.isFinite || artifact.sampleRateHz <= 0
                || artifact.channelCount <= 0 || !artifact.durationSeconds.isFinite
                || !artifact.developmentOnly
                || artifact.durationSeconds <= 0 { reasons.append(.invalidManifest) }
        }
        return Self.unique(reasons)
    }

    private static let losslessCodecs: Set<String> = ["pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "lpcm"]
    nonisolated private static func isHex(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
    }
    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func timingReasons(_ blocks: [TimingBlock], artifact: Artifact) -> [MeetingSignalDomainGateReason] {
        guard artifact.sampleRateHz.isFinite, artifact.sampleRateHz > 0,
              artifact.durationSeconds.isFinite, artifact.durationSeconds > 0 else {
            return [.invalidTiming]
        }
        guard !blocks.isEmpty else { return [.metadataOnly] }
        var reasons: [MeetingSignalDomainGateReason] = []
        var totalFrames = 0
        var previous: TimingBlock?
        let sampleTolerance = 1 / artifact.sampleRateHz
        for block in blocks {
            guard block.presentationSeconds.isFinite, block.durationSeconds.isFinite,
                  block.durationSeconds > 0, block.frameCount > 0,
                  block.arrivalSeconds == nil || block.arrivalSeconds!.isFinite else {
                reasons.append(.invalidTiming); continue
            }
            let blockRate = Double(block.frameCount) / block.durationSeconds
            if abs(blockRate - artifact.sampleRateHz) > max(1e-6, artifact.sampleRateHz * 1e-6) {
                reasons.append(.inconsistentGeometry)
            }
            totalFrames += block.frameCount
            if let previous {
                let difference = block.presentationSeconds - (previous.presentationSeconds + previous.durationSeconds)
                if difference > sampleTolerance { reasons.append(.gapDetected) }
                if difference < -sampleTolerance { reasons.append(.overlappingBlocks) }
                if let arrival = block.arrivalSeconds, let previousArrival = previous.arrivalSeconds,
                   arrival < previousArrival { reasons.append(.invalidTiming) }
            }
            previous = block
        }
        if abs(Double(totalFrames) / artifact.sampleRateHz - artifact.durationSeconds) > sampleTolerance {
            reasons.append(.invalidTiming)
        }
        return Self.unique(reasons)
    }
    private static func unique(_ reasons: [MeetingSignalDomainGateReason]) -> [MeetingSignalDomainGateReason] {
        var seen = Set<MeetingSignalDomainGateReason>()
        return reasons.filter { seen.insert($0).inserted }
    }
}

public struct MeetingSignalDomainGateThresholds: Codable, Equatable, Sendable {
    public let minimumValidCoverageFraction: Double
    public let maximumDriftPPM: Double
    public let maximumUncorrectedOffsetSeconds: Double
    public let maximumRenderLeadSeconds: Double
    public let maximumSearchDelaySeconds: Double
    public let safetyMarginSeconds: Double
    public let minimumBandCoherence: Double
    public let minimumExcitationRMS: Double
    public let maximumClippingFraction: Double
    public let maximumHeldOutLinearResidualFraction: Double
    public let maximumIneligibleSessionFraction: Double
    public let minimumExposureSeconds: Double
    public let requireDeliveryJitter: Bool
    public let minimumPathStabilityFraction: Double
    public let minimumDelayObservationCount: Int
    public let minimumTimingBlockCount: Int
    public let maximumPCMSamples: Int

    public init(minimumValidCoverageFraction: Double = 0.99, maximumDriftPPM: Double = 100,
                maximumUncorrectedOffsetSeconds: Double = 0.020, maximumRenderLeadSeconds: Double = 0.100,
                maximumSearchDelaySeconds: Double = 0.500, safetyMarginSeconds: Double = 0.020,
                minimumBandCoherence: Double = 0.10, minimumExcitationRMS: Double = 0.001,
                maximumClippingFraction: Double = 0.010, maximumHeldOutLinearResidualFraction: Double = 0.75,
                maximumIneligibleSessionFraction: Double = 0.25, minimumExposureSeconds: Double = 1.0,
                requireDeliveryJitter: Bool = true, minimumPathStabilityFraction: Double = 0.5,
                minimumDelayObservationCount: Int = 3, minimumTimingBlockCount: Int = 3,
                maximumPCMSamples: Int = 1_000_000) {
        self.minimumValidCoverageFraction = minimumValidCoverageFraction
        self.maximumDriftPPM = maximumDriftPPM
        self.maximumUncorrectedOffsetSeconds = maximumUncorrectedOffsetSeconds
        self.maximumRenderLeadSeconds = maximumRenderLeadSeconds
        self.maximumSearchDelaySeconds = maximumSearchDelaySeconds
        self.safetyMarginSeconds = safetyMarginSeconds
        self.minimumBandCoherence = minimumBandCoherence
        self.minimumExcitationRMS = minimumExcitationRMS
        self.maximumClippingFraction = maximumClippingFraction
        self.maximumHeldOutLinearResidualFraction = maximumHeldOutLinearResidualFraction
        self.maximumIneligibleSessionFraction = maximumIneligibleSessionFraction
        self.minimumExposureSeconds = minimumExposureSeconds
        self.requireDeliveryJitter = requireDeliveryJitter
        self.minimumPathStabilityFraction = minimumPathStabilityFraction
        self.minimumDelayObservationCount = minimumDelayObservationCount
        self.minimumTimingBlockCount = minimumTimingBlockCount
        self.maximumPCMSamples = maximumPCMSamples
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case minimumValidCoverageFraction, maximumDriftPPM, maximumUncorrectedOffsetSeconds,
             maximumRenderLeadSeconds, maximumSearchDelaySeconds, safetyMarginSeconds,
             minimumBandCoherence, minimumExcitationRMS, maximumClippingFraction,
             maximumHeldOutLinearResidualFraction, maximumIneligibleSessionFraction,
             minimumExposureSeconds, requireDeliveryJitter, minimumPathStabilityFraction,
             minimumDelayObservationCount, minimumTimingBlockCount, maximumPCMSamples
    }
    private struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int?
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: DynamicKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard dynamic.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown threshold key"))
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(minimumValidCoverageFraction: try c.decodeIfPresent(Double.self, forKey: .minimumValidCoverageFraction) ?? 0.99,
                  maximumDriftPPM: try c.decodeIfPresent(Double.self, forKey: .maximumDriftPPM) ?? 100,
                  maximumUncorrectedOffsetSeconds: try c.decodeIfPresent(Double.self, forKey: .maximumUncorrectedOffsetSeconds) ?? 0.020,
                  maximumRenderLeadSeconds: try c.decodeIfPresent(Double.self, forKey: .maximumRenderLeadSeconds) ?? 0.100,
                  maximumSearchDelaySeconds: try c.decodeIfPresent(Double.self, forKey: .maximumSearchDelaySeconds) ?? 0.500,
                  safetyMarginSeconds: try c.decodeIfPresent(Double.self, forKey: .safetyMarginSeconds) ?? 0.020,
                  minimumBandCoherence: try c.decodeIfPresent(Double.self, forKey: .minimumBandCoherence) ?? 0.10,
                  minimumExcitationRMS: try c.decodeIfPresent(Double.self, forKey: .minimumExcitationRMS) ?? 0.001,
                  maximumClippingFraction: try c.decodeIfPresent(Double.self, forKey: .maximumClippingFraction) ?? 0.010,
                  maximumHeldOutLinearResidualFraction: try c.decodeIfPresent(Double.self, forKey: .maximumHeldOutLinearResidualFraction) ?? 0.75,
                  maximumIneligibleSessionFraction: try c.decodeIfPresent(Double.self, forKey: .maximumIneligibleSessionFraction) ?? 0.25,
                  minimumExposureSeconds: try c.decodeIfPresent(Double.self, forKey: .minimumExposureSeconds) ?? 1.0,
                  requireDeliveryJitter: try c.decodeIfPresent(Bool.self, forKey: .requireDeliveryJitter) ?? true,
                  minimumPathStabilityFraction: try c.decodeIfPresent(Double.self, forKey: .minimumPathStabilityFraction) ?? 0.5,
                  minimumDelayObservationCount: try c.decodeIfPresent(Int.self, forKey: .minimumDelayObservationCount) ?? 3,
                  minimumTimingBlockCount: try c.decodeIfPresent(Int.self, forKey: .minimumTimingBlockCount) ?? 3,
                  maximumPCMSamples: try c.decodeIfPresent(Int.self, forKey: .maximumPCMSamples) ?? 1_000_000)
    }

    public var isValid: Bool {
        minimumValidCoverageFraction.isFinite && (0...1).contains(minimumValidCoverageFraction)
            && maximumDriftPPM.isFinite && maximumDriftPPM >= 0
            && maximumUncorrectedOffsetSeconds.isFinite && maximumUncorrectedOffsetSeconds >= 0
            && maximumRenderLeadSeconds.isFinite && maximumRenderLeadSeconds >= 0
            && maximumSearchDelaySeconds.isFinite && maximumSearchDelaySeconds > 0
            && safetyMarginSeconds.isFinite && safetyMarginSeconds >= 0
            && safetyMarginSeconds < maximumSearchDelaySeconds
            && minimumBandCoherence.isFinite && (0...1).contains(minimumBandCoherence)
            && minimumExcitationRMS.isFinite && minimumExcitationRMS >= 0
            && maximumClippingFraction.isFinite && (0...1).contains(maximumClippingFraction)
            && maximumHeldOutLinearResidualFraction.isFinite && (0...1).contains(maximumHeldOutLinearResidualFraction)
            && maximumIneligibleSessionFraction.isFinite && (0...1).contains(maximumIneligibleSessionFraction)
            && minimumExposureSeconds.isFinite && minimumExposureSeconds > 0
            && minimumPathStabilityFraction.isFinite && (0...1).contains(minimumPathStabilityFraction)
            && minimumDelayObservationCount >= 3 && minimumTimingBlockCount >= 2
            && (1_000...1_000_000).contains(maximumPCMSamples)
    }
}

public struct MeetingSignalDomainGateTrackBlock: Sendable {
    public let presentationSeconds: Double
    public let durationSeconds: Double
    public let arrivalSeconds: Double?
    public let samples: [Float]

    public init(presentationSeconds: Double, durationSeconds: Double,
                arrivalSeconds: Double? = nil, samples: [Float]) {
        self.presentationSeconds = presentationSeconds
        self.durationSeconds = durationSeconds
        self.arrivalSeconds = arrivalSeconds
        self.samples = samples
    }
}

public struct MeetingSignalDomainGateSession: Sendable {
    public let ordinal: Int
    public let topology: MeetingSignalDomainGateTopology
    public let route: MeetingSignalDomainGateRoute
    public let referenceScope: MeetingSignalDomainGateReferenceScope
    public let referenceCompletenessMeasured: Bool
    public let consentConfirmed: Bool
    public let renderCodec: String
    public let captureCodec: String
    public let renderLossless: Bool
    public let captureLossless: Bool
    public let renderBlocks: [MeetingSignalDomainGateTrackBlock]
    public let captureBlocks: [MeetingSignalDomainGateTrackBlock]

    public init(ordinal: Int, topology: MeetingSignalDomainGateTopology = .pairedScreenCaptureKit,
                route: MeetingSignalDomainGateRoute = .builtInSpeakerMicrophone,
                referenceScope: MeetingSignalDomainGateReferenceScope = .selectedApplication,
                referenceCompletenessMeasured: Bool = true, consentConfirmed: Bool = true,
                renderCodec: String = "pcm_s16le", captureCodec: String = "pcm_s16le",
                renderLossless: Bool = true, captureLossless: Bool = true,
                renderBlocks: [MeetingSignalDomainGateTrackBlock],
                captureBlocks: [MeetingSignalDomainGateTrackBlock]) {
        self.ordinal = ordinal; self.topology = topology; self.route = route
        self.referenceScope = referenceScope; self.referenceCompletenessMeasured = referenceCompletenessMeasured
        self.consentConfirmed = consentConfirmed; self.renderCodec = renderCodec; self.captureCodec = captureCodec
        self.renderLossless = renderLossless; self.captureLossless = captureLossless
        self.renderBlocks = renderBlocks; self.captureBlocks = captureBlocks
    }
}

public struct MeetingSignalDomainGateSessionMetrics: Codable, Equatable, Sendable {
    public let sessionOrdinal: Int
    public let exposureSeconds: Double
    public let validCoverageFraction: Double?
    public let deliveryJitterP50Seconds: Double?
    public let deliveryJitterP95Seconds: Double?
    public let deliveryJitterP99Seconds: Double?
    public let driftPPM: Double?
    public let driftP50PPM: Double?
    public let driftP95PPM: Double?
    public let driftP99PPM: Double?
    public let signedDelayP50Seconds: Double?
    public let signedDelayP95Seconds: Double?
    public let signedDelayP99Seconds: Double?
    public let bandCoherence: [Double]
    public let bandPower: [Double]
    public let pathStabilityFraction: Double?
    public let clippingFraction: Double?
    public let heldOutLinearResidualFraction: Double?
    public let delayObservationCount: Int
}

public struct MeetingSignalDomainGateExcludedSession: Codable, Equatable, Sendable {
    public let ordinal: Int
    public let reasons: [MeetingSignalDomainGateReason]
}

public struct MeetingSignalDomainGateReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let outcome: MeetingSignalDomainGateOutcome
    public let topology: MeetingSignalDomainGateTopology
    public let route: MeetingSignalDomainGateRoute
    public let minimumExposureSeconds: Double
    public let maximumIneligibleSessionFraction: Double
    public let thresholdSnapshot: MeetingSignalDomainGateThresholds
    public let sessionCount: Int
    public let eligibleSessionCount: Int
    public let excludedSessions: [MeetingSignalDomainGateExcludedSession]
    public let metrics: [MeetingSignalDomainGateSessionMetrics]
    public let reasonCounts: [String: Int]
    public let rawPCMRetained: Bool
    public let transcriptRetained: Bool
    public let pathsRetained: Bool

    public init(outcome: MeetingSignalDomainGateOutcome, topology: MeetingSignalDomainGateTopology,
                route: MeetingSignalDomainGateRoute, sessionCount: Int, eligibleSessionCount: Int,
                excludedSessions: [MeetingSignalDomainGateExcludedSession],
                metrics: [MeetingSignalDomainGateSessionMetrics], reasonCounts: [String: Int],
                thresholds: MeetingSignalDomainGateThresholds = .init()) {
        self.schemaVersion = 1; self.outcome = outcome; self.topology = topology; self.route = route
        self.minimumExposureSeconds = thresholds.minimumExposureSeconds
        self.maximumIneligibleSessionFraction = thresholds.maximumIneligibleSessionFraction
        self.thresholdSnapshot = thresholds
        self.sessionCount = max(0, sessionCount); self.eligibleSessionCount = max(0, eligibleSessionCount)
        self.excludedSessions = excludedSessions; self.metrics = metrics; self.reasonCounts = reasonCounts
        self.rawPCMRetained = false; self.transcriptRetained = false; self.pathsRetained = false
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// A small, deterministic signal-domain analyzer.  It is a gate, not an AEC and does not mutate
/// either source track.  Correlation uses bounded lag and fixed windows so a report is repeatable.
public enum MeetingSignalDomainGate {
    public enum ManifestError: Error, Equatable, Sendable {
        case unreadableManifest
        case invalidManifest
        case unsafeRelativePath
        case missingArtifact
        case hashMismatch
    }

    /// Loads only the JSON manifest and verifies its declared artifact files.  Callers own the
    /// private corpus root; this method never returns a URL or includes one in an evaluation
    /// report.  Audio decoding remains the caller's responsibility so this gate cannot become a
    /// capture or ASR path accidentally.
    public static func loadManifest(from root: URL) throws -> MeetingSignalDomainGateManifest {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: root.path)) == nil else {
            throw ManifestError.unsafeRelativePath
        }
        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL) else { throw ManifestError.unreadableManifest }
        guard let manifest = try? JSONDecoder().decode(MeetingSignalDomainGateManifest.self, from: data),
              manifest.validationReasons().isEmpty else { throw ManifestError.invalidManifest }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let declaredArtifacts = manifest.artifacts + manifest.sessions.flatMap { [$0.render, $0.capture] }
        for artifact in declaredArtifacts {
            guard Self.isSafeRelativePath(artifact.relativePath) else { throw ManifestError.unsafeRelativePath }
            let candidate = canonicalRoot.appendingPathComponent(artifact.relativePath, isDirectory: false)
            var cursor = canonicalRoot
            for component in artifact.relativePath.split(separator: "/") {
                cursor.appendPathComponent(String(component))
                if FileManager.default.fileExists(atPath: cursor.path),
                   (try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path)) != nil {
                    throw ManifestError.unsafeRelativePath
                }
            }
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            let rootComponents = canonicalRoot.pathComponents
            guard resolved.pathComponents.count > rootComponents.count,
                  Array(resolved.pathComponents.prefix(rootComponents.count)) == rootComponents,
                  FileManager.default.fileExists(atPath: resolved.path) else { throw ManifestError.missingArtifact }
            guard let hash = try? sha256(of: resolved), hash == artifact.sha256.lowercased() else { throw ManifestError.hashMismatch }
        }
        if let provenancePath = manifest.provenanceRelativePath, let expected = manifest.provenanceSha256,
           Self.isSafeRelativePath(provenancePath), expected.count == 64 {
            var provenanceCursor = canonicalRoot
            for component in provenancePath.split(separator: "/") {
                provenanceCursor.appendPathComponent(String(component))
                if FileManager.default.fileExists(atPath: provenanceCursor.path),
                   (try? FileManager.default.destinationOfSymbolicLink(atPath: provenanceCursor.path)) != nil {
                    throw ManifestError.unsafeRelativePath
                }
            }
            let url = canonicalRoot.appendingPathComponent(
                provenancePath, isDirectory: false
            ).standardizedFileURL.resolvingSymlinksInPath()
            let rootComponents = canonicalRoot.pathComponents
            guard url.pathComponents.count > rootComponents.count,
                  Array(url.pathComponents.prefix(rootComponents.count)) == rootComponents,
                  FileManager.default.fileExists(atPath: url.path),
                  (try? sha256(of: url)) == expected else {
                throw ManifestError.hashMismatch
            }
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Provenance.expectedKeys,
                  let provenance = try? JSONDecoder().decode(Provenance.self, from: data),
                  let session = manifest.sessions.first,
                  session.render.codec.lowercased() == "pcm_f32le",
                  session.capture.codec.lowercased() == "pcm_f32le",
                  session.render.channelCount == 1, session.capture.channelCount == 1,
                  session.render.sampleRateHz == 48_000, session.capture.sampleRateHz == 48_000,
                  provenance.renderSHA256 == session.render.sha256,
                  provenance.captureSHA256 == session.capture.sha256,
                  Provenance.isDigest(provenance.fixtureSHA256),
                  Provenance.isDigest(provenance.captureExecutableSHA256),
                  Provenance.isDigest(provenance.inputUIDSHA256),
                  Provenance.isDigest(provenance.outputUIDSHA256),
                  provenance.runOrdinal == session.ordinal,
                  provenance.targetProcessID > 0,
                  provenance.initialOutputVolume.isFinite,
                  provenance.finalOutputVolume.isFinite,
                  provenance.initialOutputVolume > 0, provenance.initialOutputVolume <= 0.25,
                  abs(provenance.finalOutputVolume - provenance.initialOutputVolume) <= 0.0001,
                  provenance.renderPeak.isFinite, provenance.renderPeak > 0,
                  provenance.renderPeak <= 0.15,
                  provenance.capturePeak.isFinite, provenance.capturePeak <= 1,
                  provenance.renderBlockCount == session.renderTiming.count,
                  provenance.captureBlockCount == session.captureTiming.count,
                  provenance.renderFrameCount == session.renderTiming.reduce(0, { $0 + $1.frameCount }),
                  provenance.captureFrameCount == session.captureTiming.reduce(0, { $0 + $1.frameCount }),
                  provenance.captureConfiguration == "SCStream:48kHz:mono:native-f32le:audio+microphone",
                  provenance.route == "builtInSpeakerMicrophone" else {
                throw ManifestError.invalidManifest
            }
        }
        return manifest
    }

    private struct Provenance: Codable {
        let renderSHA256: String; let captureSHA256: String; let fixtureSHA256: String
        let captureExecutableSHA256: String
        let inputUIDSHA256: String; let outputUIDSHA256: String
        let runOrdinal: Int; let targetProcessID: Int32
        let initialOutputVolume: Float32; let finalOutputVolume: Float32
        let renderPeak: Float; let capturePeak: Float
        let renderBlockCount: Int; let captureBlockCount: Int
        let renderFrameCount: Int; let captureFrameCount: Int
        let osBuildIdentity: String; let appBuildIdentity: String
        let captureConfiguration: String; let route: String

        static let expectedKeys: Set<String> = [
            "renderSHA256", "captureSHA256", "fixtureSHA256", "captureExecutableSHA256",
            "inputUIDSHA256", "outputUIDSHA256", "runOrdinal", "targetProcessID",
            "initialOutputVolume", "finalOutputVolume", "renderPeak", "capturePeak",
            "renderBlockCount", "captureBlockCount", "renderFrameCount", "captureFrameCount",
            "osBuildIdentity", "appBuildIdentity", "captureConfiguration", "route",
        ]

        static func isDigest(_ value: String) -> Bool {
            value.count == 64 && value == value.lowercased()
                && value.unicodeScalars.allSatisfy {
                    (48...57).contains($0.value) || (97...102).contains($0.value)
                }
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func sha256(of url: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }

    public static func evaluate(manifest: MeetingSignalDomainGateManifest,
                                sessions: [MeetingSignalDomainGateSession],
                                thresholds: MeetingSignalDomainGateThresholds = .init(),
                                renderLeadSeconds: Double = 0) -> MeetingSignalDomainGateReport {
        var manifestReasons = manifest.validationReasons()
        if !manifest.sessions.isEmpty {
            let declaredOrdinals = manifest.sessions.map(\.ordinal).sorted()
            let suppliedOrdinals = sessions.map(\.ordinal).sorted()
            if declaredOrdinals != suppliedOrdinals { manifestReasons.append(.invalidManifest) }
        }
        if !thresholds.isValid { manifestReasons.append(.invalidThresholds) }
        if !renderLeadSeconds.isFinite || renderLeadSeconds < 0 || renderLeadSeconds > thresholds.maximumRenderLeadSeconds {
            manifestReasons.append(.invalidTiming)
        }
        var excluded: [MeetingSignalDomainGateExcludedSession] = []
        var metrics: [MeetingSignalDomainGateSessionMetrics] = []
        var counts: [String: Int] = [:]
        func add(_ reasons: [MeetingSignalDomainGateReason]) {
            for reason in Set(reasons) { counts[reason.rawValue, default: 0] += 1 }
        }
        if !manifestReasons.isEmpty { add(manifestReasons) }
        var ordinals = Set<Int>()
        for session in sessions {
            if !ordinals.insert(session.ordinal).inserted {
                let reason: MeetingSignalDomainGateReason = .duplicateOrdinal
                excluded.append(.init(ordinal: session.ordinal, reasons: [reason])); add([reason]); continue
            }
            let reasons = validate(session: session, thresholds: thresholds, renderLeadSeconds: renderLeadSeconds)
            if !reasons.isEmpty {
                excluded.append(.init(ordinal: session.ordinal, reasons: reasons)); add(reasons); continue
            }
            if let measurement = measure(session: session, thresholds: thresholds, renderLeadSeconds: renderLeadSeconds) {
                if measurement.reasons.isEmpty {
                    metrics.append(measurement.metrics)
                } else {
                    excluded.append(.init(ordinal: session.ordinal, reasons: measurement.reasons)); add(measurement.reasons)
                }
            } else {
                // A well-formed lossless pair can still fail to produce a bounded,
                // evidence-bearing correlation (for example, unexcited or unrelated
                // tracks). Keep that distinct from malformed timing.
                let reason: MeetingSignalDomainGateReason = .delayUnresolved
                excluded.append(.init(ordinal: session.ordinal, reasons: [reason])); add([reason])
            }
        }
        let eligible = metrics.count
        let outcome: MeetingSignalDomainGateOutcome = {
            guard manifestReasons.isEmpty else { return .rejected }
            let rejectionReasons: Set<MeetingSignalDomainGateReason> = [
                .invalidManifest, .missingConsent, .sourceHashMismatch, .invalidTiming,
                .duplicateOrdinal, .inconsistentGeometry, .gapDetected, .overlappingBlocks,
                .excessiveDrift, .delayNonCausal, .delayOutsideSearchRange, .unstablePath,
                .clipping, .linearPathUnlearnable
            ]
            if excluded.contains(where: { !Set($0.reasons).isDisjoint(with: rejectionReasons) }) {
                return .rejected
            }
            guard eligible > 0 else { return .unscored }
            let ineligibleFraction = Double(excluded.count) / Double(max(1, sessions.count))
            guard ineligibleFraction <= thresholds.maximumIneligibleSessionFraction else { return .unscored }
            return .proceedToCandidate
        }()
        if eligible == 0 { counts[MeetingSignalDomainGateReason.noEligibleSessions.rawValue, default: 0] += 1 }
        return .init(outcome: outcome, topology: manifest.topology, route: manifest.route,
                     sessionCount: sessions.count, eligibleSessionCount: eligible,
                     excludedSessions: excluded, metrics: metrics, reasonCounts: counts, thresholds: thresholds)
    }

    private static func validate(session: MeetingSignalDomainGateSession,
                                 thresholds: MeetingSignalDomainGateThresholds,
                                 renderLeadSeconds: Double) -> [MeetingSignalDomainGateReason] {
        var reasons: [MeetingSignalDomainGateReason] = []
        if session.topology != .pairedScreenCaptureKit { reasons.append(.unsupportedTopology) }
        if session.route != .builtInSpeakerMicrophone { reasons.append(.unsupportedRoute) }
        if !session.consentConfirmed { reasons.append(.missingConsent) }
        if !session.renderLossless || !session.captureLossless { reasons.append(.nonLossless) }
        for codec in [session.renderCodec.lowercased(), session.captureCodec.lowercased()] where !["pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "lpcm"].contains(codec) { reasons.append(.unsupportedCodec) }
        if session.renderBlocks.isEmpty || session.captureBlocks.isEmpty { reasons.append(.metadataOnly) }
        if thresholds.requireDeliveryJitter
            && (session.renderBlocks.contains(where: { $0.arrivalSeconds == nil })
                || session.captureBlocks.contains(where: { $0.arrivalSeconds == nil })) {
            reasons.append(.missingArrivalMetadata)
        }
        if thresholds.requireDeliveryJitter
            && (session.renderBlocks.count < thresholds.minimumTimingBlockCount
                || session.captureBlocks.count < thresholds.minimumTimingBlockCount) {
            reasons.append(.insufficientTimingObservations)
        }
        if session.referenceScope == .unknown { reasons.append(.referenceScopeLimited) }
        if !session.referenceCompletenessMeasured { reasons.append(.referenceCompletenessUnobservable) }
        if renderLeadSeconds > thresholds.maximumRenderLeadSeconds { reasons.append(.invalidTiming) }
        let all = session.renderBlocks + session.captureBlocks
        if all.contains(where: { !$0.presentationSeconds.isFinite || !$0.durationSeconds.isFinite || $0.durationSeconds <= 0 || $0.samples.isEmpty || $0.samples.contains(where: { !$0.isFinite }) }) { reasons.append(.invalidTiming) }
        if session.renderBlocks.reduce(0, { $0 + $1.samples.count }) > thresholds.maximumPCMSamples
            || session.captureBlocks.reduce(0, { $0 + $1.samples.count }) > thresholds.maximumPCMSamples {
            reasons.append(.analysisResourceLimitExceeded)
        }
        if !chronologyIsMonotonic(session.renderBlocks) || !chronologyIsMonotonic(session.captureBlocks) { reasons.append(.invalidTiming) }
        // An empty track is metadata-only, not malformed geometry.  Keep that case explicitly
        // unscored so callers can distinguish absent PCM from a present but inconsistent pair.
        let hasBothTracks = !session.renderBlocks.isEmpty && !session.captureBlocks.isEmpty
        if hasBothTracks && (!geometryIsConsistent(session.renderBlocks) || !geometryIsConsistent(session.captureBlocks)) {
            reasons.append(.inconsistentGeometry)
        }
        let renderContinuity = continuity(of: session.renderBlocks)
        let captureContinuity = continuity(of: session.captureBlocks)
        if renderContinuity.hasGap || captureContinuity.hasGap { reasons.append(.gapDetected) }
        if renderContinuity.hasOverlap || captureContinuity.hasOverlap { reasons.append(.overlappingBlocks) }
        if let renderRate = inferredRate(session.renderBlocks), let captureRate = inferredRate(session.captureBlocks),
           abs(renderRate - captureRate) > max(1e-6, renderRate * 1e-6) { reasons.append(.inconsistentGeometry) }
        if hasBothTracks,
           let exposure = [session.renderBlocks, session.captureBlocks].map({ $0.reduce(0) { $0 + $1.durationSeconds } }).min(),
           exposure < thresholds.minimumExposureSeconds {
            reasons.append(.insufficientCoverage)
        }
        return unique(reasons)
    }

    private static func measure(session: MeetingSignalDomainGateSession,
                                thresholds: MeetingSignalDomainGateThresholds,
                                renderLeadSeconds: Double) -> (metrics: MeetingSignalDomainGateSessionMetrics, reasons: [MeetingSignalDomainGateReason])? {
        let render = session.renderBlocks.flatMap(\.samples); let capture = session.captureBlocks.flatMap(\.samples)
        guard !render.isEmpty, !capture.isEmpty else { return nil }
        let coverage = min(coverage(of: session.renderBlocks), coverage(of: session.captureBlocks))
        var reasons: [MeetingSignalDomainGateReason] = []
        if coverage < thresholds.minimumValidCoverageFraction { reasons.append(.insufficientCoverage) }
        let exposure = min(session.renderBlocks.reduce(0) { $0 + $1.durationSeconds }, session.captureBlocks.reduce(0) { $0 + $1.durationSeconds })
        if exposure < thresholds.minimumExposureSeconds { reasons.append(.insufficientCoverage) }
        let sampleRate = inferRate(session.renderBlocks)
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let delayObservations = delaySamples(render: render, capture: capture, sampleRate: sampleRate,
                                             maxSeconds: thresholds.maximumSearchDelaySeconds)
        guard !delayObservations.isEmpty else { return nil }
        let delays = delayObservations.map(\.seconds)
        guard let renderOrigin = session.renderBlocks.first?.presentationSeconds,
              let captureOrigin = session.captureBlocks.first?.presentationSeconds else { return nil }
        // The correlation is performed over contiguous track samples, then brought back to the
        // common timeline using the declared PTS-origin offset. This prevents independent PTS
        // origins from silently disappearing into sample zero.
        let ptsOriginOffset = captureOrigin - renderOrigin
        let signed = delays.map { $0 + ptsOriginOffset + renderLeadSeconds }
        let driftSamples = windowedDriftPPM(delayObservations)
        let drift = percentileOptional(driftSamples, 0.50)
        // Delivery jitter is a within-track property. Do not manufacture a cross-track
        // observation by joining the render and capture arrays at an arbitrary boundary.
        let jitter = jitterValues(session.renderBlocks) + jitterValues(session.captureBlocks)
        let medianLagSamples = Int((percentile(delays, 0.50) * sampleRate).rounded())
        let aligned = align(render: render, capture: capture, lag: medianLagSamples)
        let bandMeasurements = bandMeasures(render: aligned.render, capture: aligned.capture, sampleRate: sampleRate)
        let coherence = bandMeasurements.coherence
        let bandPower = bandMeasurements.power
        let rms = sqrt(render.reduce(0) { $0 + Double($1) * Double($1) } / Double(render.count))
        let clipping = Double((render + capture).filter { abs($0) >= 0.999 }.count) / Double(render.count + capture.count)
        let firResidual = heldOutLinearResidualFraction(render: aligned.render,
                                                        capture: aligned.capture,
                                                        sampleRate: sampleRate)
        let stability = pathStability(delays)
        let badDelay = percentile(signed, 0.99) > thresholds.maximumSearchDelaySeconds - thresholds.safetyMarginSeconds
            || percentile(signed, 0.01) < -thresholds.safetyMarginSeconds
        if delayObservations.count < thresholds.minimumDelayObservationCount { reasons.append(.delayUnresolved) }
        if driftSamples.isEmpty { reasons.append(.driftUnscored) }
        if driftSamples.contains(where: { abs($0) > thresholds.maximumDriftPPM }) { reasons.append(.excessiveDrift) }
        if let firstDelay = delays.first, delays.contains(where: { abs($0 - firstDelay) > thresholds.maximumUncorrectedOffsetSeconds }) { reasons.append(.excessiveDrift) }
        if badDelay {
            if percentile(signed, 0.01) < -thresholds.safetyMarginSeconds {
                reasons.append(.delayNonCausal)
            } else if percentile(signed, 0.99) > thresholds.maximumSearchDelaySeconds - thresholds.safetyMarginSeconds {
                reasons.append(.delayOutsideSearchRange)
            }
        }
        if rms < thresholds.minimumExcitationRMS { reasons.append(.lowExcitation) }
        if coherence.contains(where: { $0 < thresholds.minimumBandCoherence }) { reasons.append(.lowExcitation) }
        if clipping > thresholds.maximumClippingFraction { reasons.append(.clipping) }
        if let firResidual {
            if firResidual > thresholds.maximumHeldOutLinearResidualFraction { reasons.append(.linearPathUnlearnable) }
        } else {
            reasons.append(.linearPathUnscored)
        }
        if (stability ?? 0) < thresholds.minimumPathStabilityFraction { reasons.append(.unstablePath) }
        let value = MeetingSignalDomainGateSessionMetrics(sessionOrdinal: session.ordinal, exposureSeconds: exposure, validCoverageFraction: coverage, deliveryJitterP50Seconds: percentileOptional(jitter, 0.50), deliveryJitterP95Seconds: percentileOptional(jitter, 0.95), deliveryJitterP99Seconds: percentileOptional(jitter, 0.99), driftPPM: drift, driftP50PPM: percentileOptional(driftSamples, 0.50), driftP95PPM: percentileOptional(driftSamples, 0.95), driftP99PPM: percentileOptional(driftSamples, 0.99), signedDelayP50Seconds: percentileOptional(signed, 0.50), signedDelayP95Seconds: percentileOptional(signed, 0.95), signedDelayP99Seconds: percentileOptional(signed, 0.99), bandCoherence: coherence, bandPower: bandPower, pathStabilityFraction: stability, clippingFraction: clipping, heldOutLinearResidualFraction: firResidual, delayObservationCount: delayObservations.count)
        return (value, unique(reasons))
    }

    private static func coverage(of blocks: [MeetingSignalDomainGateTrackBlock]) -> Double {
        guard let first = blocks.first?.presentationSeconds, let last = blocks.last,
              first.isFinite, last.presentationSeconds.isFinite else { return 0 }
        let span = last.presentationSeconds + last.durationSeconds - first
        guard span > 0 else { return 0 }
        return min(1, blocks.reduce(0) { $0 + $1.durationSeconds } / span)
    }
    private static func chronologyIsMonotonic(_ blocks: [MeetingSignalDomainGateTrackBlock]) -> Bool {
        guard blocks.allSatisfy({ $0.arrivalSeconds == nil || $0.arrivalSeconds!.isFinite }) else { return false }
        for pair in zip(blocks.dropFirst(), blocks) {
            let rate = inferredRate(blocks) ?? 1
            let tolerance = max(1e-9, 1 / rate)
            if pair.0.presentationSeconds - pair.1.presentationSeconds < -tolerance { return false }
            if let currentArrival = pair.0.arrivalSeconds, let previousArrival = pair.1.arrivalSeconds,
               currentArrival < previousArrival { return false }
        }
        return true
    }
    private struct BlockContinuityFlags { var hasGap = false; var hasOverlap = false }
    private static func continuity(of blocks: [MeetingSignalDomainGateTrackBlock]) -> BlockContinuityFlags {
        var flags = BlockContinuityFlags()
        for pair in zip(blocks.dropFirst(), blocks) {
            let delta = pair.0.presentationSeconds - pair.1.presentationSeconds
            let tolerance = max(1e-9, 1 / (inferredRate(blocks) ?? 1))
            if delta - pair.1.durationSeconds > tolerance { flags.hasGap = true }
            if delta - pair.1.durationSeconds < -tolerance { flags.hasOverlap = true }
        }
        return flags
    }
    private static func inferredRate(_ blocks: [MeetingSignalDomainGateTrackBlock]) -> Double? {
        guard let first = blocks.first, first.durationSeconds > 0 else { return nil }
        let rate = Double(first.samples.count) / first.durationSeconds
        return rate.isFinite && rate > 0 ? rate : nil
    }
    private static func geometryIsConsistent(_ blocks: [MeetingSignalDomainGateTrackBlock]) -> Bool {
        guard let expected = inferredRate(blocks) else { return false }
        return blocks.allSatisfy { block in
            guard block.durationSeconds > 0 else { return false }
            let rate = Double(block.samples.count) / block.durationSeconds
            return rate.isFinite && abs(rate - expected) <= max(1e-6, expected * 1e-6)
        }
    }
    private static func inferRate(_ blocks: [MeetingSignalDomainGateTrackBlock]) -> Double {
        inferredRate(blocks) ?? .nan
    }
    private static func jitterValues(_ blocks: [MeetingSignalDomainGateTrackBlock]) -> [Double] {
        guard blocks.count > 1 else { return [] }; var values: [Double] = []
        for pair in zip(blocks.dropFirst(), blocks) { if let a = pair.0.arrivalSeconds, let b = pair.1.arrivalSeconds, a.isFinite, b.isFinite { values.append(abs((a - b) - pair.1.durationSeconds)) } }
        return values
    }
    private static func delaySamples(render: [Float], capture: [Float], sampleRate: Double, maxSeconds: Double) -> [(time: Double, seconds: Double)] {
        // Use anti-aliased 1 kHz windows distributed across the complete bounded exposure.
        // Decimation depends on source rate, not recording length, so longer recordings retain
        // the same delay resolution instead of becoming progressively less measurable.
        let n = min(render.count, capture.count); guard n > 8 else { return [] }
        let decimation = max(1, Int(floor(sampleRate / 1_000)))
        let reducedRender = antiAliasedDownsample(Array(render.prefix(n)), factor: decimation)
        let reducedCapture = antiAliasedDownsample(Array(capture.prefix(n)), factor: decimation)
        let reducedRate = sampleRate / Double(decimation)
        let maxLag = Int(ceil(maxSeconds * reducedRate))
        let window = max(256, maxLag * 2 + 64, Int(ceil(0.5 * reducedRate)))
        guard maxLag > 0, reducedRender.count >= window, reducedCapture.count >= window else { return [] }
        let available = min(reducedRender.count, reducedCapture.count) - window
        let observationCount = min(16, max(1, available / max(1, window / 2) + 1))
        let starts = Array(Set((0..<observationCount).map {
            Int((Double($0) * Double(available) / Double(max(1, observationCount - 1))).rounded())
        })).sorted()
        var result: [(time: Double, seconds: Double)] = []
        var priorLag: Int?
        let localRadius = max(4, Int(ceil(0.05 * reducedRate)))
        for (ordinal, start) in starts.enumerated() {
            let renderWindow = Array(reducedRender[start..<(start + window)])
            let captureWindow = Array(reducedCapture[start..<(start + window)])
            let renderMean = renderWindow.reduce(0.0) { $0 + Double($1) } / Double(window)
            let captureMean = captureWindow.reduce(0.0) { $0 + Double($1) } / Double(window)
            let centeredRender = renderWindow.map { Double($0) - renderMean }
            let centeredCapture = captureWindow.map { Double($0) - captureMean }
            let lower: Int
            let upper: Int
            if priorLag == nil || ordinal.isMultiple(of: 4) {
                lower = -maxLag; upper = maxLag
            } else {
                lower = max(-maxLag, priorLag! - localRadius)
                upper = min(maxLag, priorLag! + localRadius)
            }
            var bestLag = 0; var best = -Double.infinity
            for lag in lower...upper {
                let overlapStart = max(0, -lag)
                let overlapEnd = min(window, window - lag)
                guard overlapEnd - overlapStart >= window / 2 else { continue }
                var dot = 0.0, er = 0.0, ec = 0.0
                for i in overlapStart..<overlapEnd {
                    let j = i + lag, a = centeredRender[i], b = centeredCapture[j]
                    dot += a * b; er += a * a; ec += b * b
                }
                let score = er > 0 && ec > 0 ? abs(dot / sqrt(er * ec)) : -Double.infinity
                if score > best { best = score; bestLag = lag }
            }
            if best.isFinite && best > 0.05 {
                result.append((Double(start + window / 2) / reducedRate, Double(bestLag) / reducedRate))
                priorLag = bestLag
            }
        }
        return result
    }

    /// Box-average before decimation so the bounded delay tracker does not silently alias
    /// high-frequency render content. Full-rate path metrics remain untouched.
    private static func antiAliasedDownsample(_ samples: [Float], factor: Int) -> [Float] {
        guard factor > 1 else { return samples }
        var result: [Float] = []; result.reserveCapacity((samples.count + factor - 1) / factor)
        for start in stride(from: 0, to: samples.count, by: factor) {
            let end = min(start + factor, samples.count)
            let sum = samples[start..<end].reduce(0.0) { $0 + Double($1) }
            result.append(Float(sum / Double(end - start)))
        }
        return result
    }

    /// Returns equal-length full-rate pairs for the measured lag. A positive lag means
    /// render[i] ~= capture[i + lag], matching the correlation convention above.
    private static func align(render: [Float], capture: [Float], lag: Int) -> (render: [Float], capture: [Float]) {
        let n = min(render.count, capture.count)
        guard n > 0 else { return ([], []) }
        if lag >= 0 {
            let offset = min(lag, n - 1)
            return (Array(render[..<(n - offset)]), Array(capture[offset..<n]))
        }
        let offset = min(-lag, n - 1)
        return (Array(render[offset..<n]), Array(capture[..<(n - offset)]))
    }
    private static func windowedDriftPPM(_ observations: [(time: Double, seconds: Double)]) -> [Double] {
        guard observations.count > 1 else { return [] }
        return zip(observations.dropFirst(), observations).compactMap { current, previous in
            let dt = current.time - previous.time
            guard dt.isFinite, dt > 0 else { return nil }
            return (current.seconds - previous.seconds) / dt * 1_000_000
        }
    }
    private static func bandMeasures(render: [Float], capture: [Float], sampleRate: Double) -> (coherence: [Double], power: [Double]) {
        let n = min(render.count, capture.count); guard n > 4 else { return ([0, 0, 0], [0, 0, 0]) }
        let window = 4_096
        let bands: [[Double]] = [[250, 500], [750, 1_000, 1_500], [2_500, 4_000, 6_000]]
        return bands.map { frequencies in
            var frequencyCoherences: [Double] = [], frequencyPowers: [Double] = []
            for frequency in frequencies where frequency < sampleRate / 2 {
                var crossReal = 0.0, crossImag = 0.0, renderPower = 0.0, capturePower = 0.0
                for start in stride(from: 0, through: max(0, n - 8), by: window) {
                    let end = min(start + window, n)
                    let renderMean = render[start..<end].reduce(0) { $0 + Double($1) } / Double(end - start)
                    let captureMean = capture[start..<end].reduce(0) { $0 + Double($1) } / Double(end - start)
                    let theta = 2 * Double.pi * frequency / sampleRate
                    let stepCos = cos(theta), stepSin = sin(theta)
                    var cosValue = 1.0, sinValue = 0.0
                    var xr = 0.0, xi = 0.0, yr = 0.0, yi = 0.0
                    for index in start..<end {
                        let x = Double(render[index]) - renderMean, y = Double(capture[index]) - captureMean
                        xr += x * cosValue; xi -= x * sinValue
                        yr += y * cosValue; yi -= y * sinValue
                        let nextCos = cosValue * stepCos - sinValue * stepSin
                        sinValue = sinValue * stepCos + cosValue * stepSin
                        cosValue = nextCos
                    }
                    crossReal += xr * yr + xi * yi
                    crossImag += xi * yr - xr * yi
                    renderPower += xr * xr + xi * xi
                    capturePower += yr * yr + yi * yi
                }
                let denominator = renderPower * capturePower
                if denominator > 0 {
                    frequencyCoherences.append(min(1, max(0, (crossReal * crossReal + crossImag * crossImag) / denominator)))
                    frequencyPowers.append(renderPower / Double(max(1, n * n)))
                }
            }
            return (frequencyCoherences.isEmpty ? 0 : frequencyCoherences.reduce(0, +) / Double(frequencyCoherences.count),
                    frequencyPowers.isEmpty ? 0 : frequencyPowers.reduce(0, +) / Double(frequencyPowers.count))
        }.reduce(into: ([Double](), [Double]())) { result, value in result.0.append(value.0); result.1.append(value.1) }
    }
    /// Fits a bounded 64 ms NLMS path on an early window and scores a disjoint late window.
    /// A high residual means this bounded linear model did not generalize; it does not prove
    /// nonlinear preprocessing. Work is bounded at a 4 kHz analysis rate and 256 taps.
    private static func heldOutLinearResidualFraction(render: [Float], capture: [Float],
                                                      sampleRate: Double) -> Double? {
        let sourceCount = min(render.count, capture.count)
        guard sourceCount >= 512, sampleRate.isFinite, sampleRate > 0 else { return nil }
        let factor = max(1, Int(floor(sampleRate / 4_000)))
        let x = antiAliasedDownsample(Array(render.prefix(sourceCount)), factor: factor)
        let y = antiAliasedDownsample(Array(capture.prefix(sourceCount)), factor: factor)
        let reducedRate = sampleRate / Double(factor)
        let tapCount = min(256, max(16, Int(ceil(0.064 * reducedRate))))
        let count = min(x.count, y.count), split = count * 3 / 4
        guard split > tapCount + 64, count - split > 64 else { return nil }
        let trainStart = max(tapCount - 1, split - min(split, Int(4 * reducedRate)))
        var coefficients = Array(repeating: 0.0, count: tapCount)
        for index in trainStart..<split {
            var prediction = 0.0, norm = 1e-8
            for tap in 0..<tapCount {
                let value = Double(x[index - tap])
                prediction += coefficients[tap] * value; norm += value * value
            }
            let scale = 0.5 * (Double(y[index]) - prediction) / norm
            for tap in 0..<tapCount { coefficients[tap] += scale * Double(x[index - tap]) }
        }
        let testStart = max(split, count - Int(4 * reducedRate))
        var errorEnergy = 0.0, targetEnergy = 0.0, observations = 0
        for index in max(testStart, tapCount - 1)..<count {
            var prediction = 0.0
            for tap in 0..<tapCount { prediction += coefficients[tap] * Double(x[index - tap]) }
            let target = Double(y[index]), error = target - prediction
            errorEnergy += error * error; targetEnergy += target * target; observations += 1
        }
        guard observations > 64, targetEnergy > 1e-12 else { return nil }
        return min(1, max(0, errorEnergy / targetEnergy))
    }
    private static func pathStability(_ values: [Double]) -> Double? { guard !values.isEmpty else { return nil }; let median = percentile(values, 0.5); let tolerance = max(1e-4, abs(median) * 0.10); return Double(values.filter { abs($0 - median) <= tolerance }.count) / Double(values.count) }
    private static func percentile(_ values: [Double], _ p: Double) -> Double { let sorted = values.sorted(); guard let first = sorted.first else { return .nan }; if sorted.count == 1 { return first }; let index = min(Double(sorted.count - 1), max(0, p * Double(sorted.count - 1))); let low = Int(index.rounded(.down)); let high = Int(index.rounded(.up)); return sorted[low] + (sorted[high] - sorted[low]) * (index - Double(low)) }
    private static func percentileOptional(_ values: [Double], _ p: Double) -> Double? { values.isEmpty ? nil : percentile(values, p) }
    private static func unique(_ reasons: [MeetingSignalDomainGateReason]) -> [MeetingSignalDomainGateReason] { var seen = Set<MeetingSignalDomainGateReason>(); return reasons.filter { seen.insert($0).inserted } }
}

/// Executable representation of the single-owner delay rule.  A future engine wrapper can adopt
/// this contract without changing its semantics; until then it is useful in offline tests and
/// cannot alter capture behavior.
public struct MeetingAECDelayContract: Codable, Equatable, Sendable {
    public let renderLeadSeconds: Double
    public let boundedEngineHintSeconds: Double?
    public let adaptiveDelayOwner: String
    public let renderBeforeCapture: Bool

    public init(renderLeadSeconds: Double, boundedEngineHintSeconds: Double? = nil,
                adaptiveDelayOwner: String = "candidateEngine", renderBeforeCapture: Bool = true) {
        self.renderLeadSeconds = renderLeadSeconds; self.boundedEngineHintSeconds = boundedEngineHintSeconds
        self.adaptiveDelayOwner = adaptiveDelayOwner; self.renderBeforeCapture = renderBeforeCapture
    }

    public var isValid: Bool {
        renderLeadSeconds.isFinite && renderLeadSeconds >= 0 && renderLeadSeconds <= 0.100
            && (boundedEngineHintSeconds == nil || (boundedEngineHintSeconds!.isFinite && boundedEngineHintSeconds! >= 0 && boundedEngineHintSeconds! <= 0.500))
            && adaptiveDelayOwner == "candidateEngine" && renderBeforeCapture
    }

    /// Checks the ordering invariant a future adapter must prove in an executable test. There
    /// must be exactly one render and one capture event per frame, with render first; a
    /// synchronizer or caller cannot become a second adaptive delay owner.
    public func validates(events: [MeetingAECDelayContractEvent]) -> Bool {
        guard isValid, !events.isEmpty else { return false }
        let ordered = events.sorted { $0.frameIndex == $1.frameIndex ? $0.kind == .render && $1.kind == .capture : $0.frameIndex < $1.frameIndex }
        guard ordered == events else { return false }
        var byFrame: [Int: [MeetingAECDelayContractEventKind]] = [:]
        for event in events {
            guard event.frameIndex >= 0 else { return false }
            byFrame[event.frameIndex, default: []].append(event.kind)
        }
        guard let maximumFrame = byFrame.keys.max(), Set(byFrame.keys) == Set(0...maximumFrame) else { return false }
        return byFrame.values.allSatisfy { kinds in
            kinds.count == 2 && kinds[0] == .render && kinds[1] == .capture
        }
    }

    /// Validates the synchronizer output seam: fixed frame indices, non-regressing epochs,
    /// equal masks/geometry, and a nonnegative frozen lead. The synchronizer remains the sole
    /// owner of clock/epoch mapping; adaptive acoustic delay is still reserved for the candidate.
    public func validates(synchronizedResult: MeetingSynchronizationResult) -> Bool {
        guard isValid, !synchronizedResult.frames.isEmpty else { return false }
        var previousEpoch = 0
        for (expectedIndex, frame) in synchronizedResult.frames.enumerated() {
            guard frame.index == expectedIndex, frame.epochID >= previousEpoch,
                  frame.renderSamples.count == frame.captureSamples.count,
                  frame.renderValidMask.count == frame.renderSamples.count,
                  frame.captureValidMask.count == frame.captureSamples.count else { return false }
            previousEpoch = frame.epochID
        }
        return true
    }
}

public enum MeetingAECDelayContractEventKind: String, Codable, Sendable {
    case render
    case capture
}

public struct MeetingAECDelayContractEvent: Codable, Equatable, Sendable {
    public let frameIndex: Int
    public let kind: MeetingAECDelayContractEventKind

    public init(frameIndex: Int, kind: MeetingAECDelayContractEventKind) {
        self.frameIndex = frameIndex
        self.kind = kind
    }
}
