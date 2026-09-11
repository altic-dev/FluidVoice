import CryptoKit
import Foundation

/// Versioned, offline-only contracts for reference-aware microphone attribution.
///
/// These types deliberately contain no transcript text, audio samples, embeddings, labels,
/// window titles, or paths.  They are a value seam for candidate engines; defining the seam does
/// not enable an engine or change capture, ASR, export, or speaker-profile behaviour.
nonisolated enum MeetingReferenceAttributionSchema {
    static let protocolVersion = 1
    static let sidecarVersion = 1
}

nonisolated enum MeetingReferenceAttributionOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case likelyPlaybackOnly
    case acceptedNearEndSpeech
    case mixedOrUncertain
    case unscored
    case scopeLimited
}

/// A typed reason is intentionally more specific than an outcome.  In particular, missing data
/// is never represented by `silence`, `noSpeech`, or a playback-only outcome.
nonisolated enum MeetingReferenceAttributionReasonCode: String, Codable, CaseIterable, Hashable, Sendable {
    case referenceAbsent
    case referenceGap
    case referenceScopeLimited
    case referenceCompletenessUnobservable
    case captureGap
    case captureTimingSynthesized
    case delayUnresolved
    case clockDriftUnstable
    case engineUnavailable
    case invalidInput
    case nonFiniteInput
    case unsupportedFormat
    case lowExcitation
    case insufficientCoverage
    case unconverged
    case pathReset
    case resetRequired
    case overBudget
    case cancelled
    case dependencyUnavailable
    case corruptSidecar
    case staleEpoch
    case duplicateFrame
    case nonMonotonicFrame
    case mixedEvidence
    case residualSpeechDetected
    case playbackAttributed
    case silenceMeasured
    case noSpeechMeasured
    case unknownSpeechState
    case noFallback
    case fallbackToOriginal
}

nonisolated enum MeetingReferenceAttributionSpeechState: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case silence
    case noSpeech
    case nearEndSpeech
    case playbackSpeech
    case mixedSpeech
}

nonisolated enum MeetingReferenceAttributionResidualVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case originalMicrophone
    case linearResidual
    case suppressedResidual
}

nonisolated enum MeetingReferenceAttributionReferenceScope: String, Codable, CaseIterable, Hashable, Sendable {
    case selectedWindow
    case selectedApplication
    case authorizedSystemMix
    case unknown
}

nonisolated enum MeetingReferenceAttributionFallback: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case originalMicrophone
}

nonisolated private enum MeetingReferenceAttributionCanonical {
    // Malformed programmatic values remain visibly invalid rather than becoming plausible evidence.
    static let fallbackLogicalIdentifier = "invalid/"
    static let fallbackOpaqueHash = "invalid"
    static let fallbackConfigurationHash = "invalid"

    static func hash<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A hash of empty data would look valid while silently erasing provenance when encoding
        // fails (for example, because a corrupt payload contains a non-finite number). Keep an
        // explicit sentinel; sidecar decoding separately rejects corrupt payloads.
        guard let data = try? encoder.encode(value) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    static func isLogicalIdentifier(_ value: String) -> Bool {
        let value = normalized(value)
        guard !value.isEmpty, value != ".", value != "..",
              !value.hasPrefix("~"), !value.contains("/"), !value.contains("\\"),
              !value.contains("://") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    static func logicalIdentifier(_ value: String) -> String {
        let normalized = normalized(value)
        return isLogicalIdentifier(normalized) ? normalized : Self.fallbackLogicalIdentifier
    }

    static func isOpaqueHash(_ value: String) -> Bool {
        let value = normalized(value)
        guard !value.isEmpty, value != "invalid", !value.contains("/"), !value.contains("\\") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
    }

    static func opaqueHash(_ value: String) -> String {
        let normalized = normalized(value)
        return isOpaqueHash(normalized) ? normalized : Self.fallbackOpaqueHash
    }

    static func isConfigurationHash(_ value: String) -> Bool {
        let value = normalized(value)
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    static func configurationHash(_ value: String) -> String {
        let normalized = normalized(value)
        return isConfigurationHash(normalized) ? normalized : Self.fallbackConfigurationHash
    }

    static func string(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        // Logical identities may not smuggle local paths or URLs into a sidecar.
        guard isLogicalIdentifier(normalized) else { return Self.fallbackLogicalIdentifier }
        return normalized
    }

    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    static func nonNegative(_ value: Double?) -> Double? {
        guard let value = finite(value), value >= 0 else { return nil }
        return value
    }

    static func fraction(_ value: Double?) -> Double? {
        guard let value = finite(value), (0...1).contains(value) else { return nil }
        return value
    }

    static func nonNegativeInt(_ value: Int) -> Int { max(0, value) }
}

/// A named source revision/artifact digest.  `name` is a logical identifier, never a file path.
nonisolated struct MeetingReferenceAttributionSourceHash: Codable, Equatable, Sendable {
    let name: String
    let hash: String

    init(name: String, hash: String) {
        self.name = MeetingReferenceAttributionCanonical.logicalIdentifier(name)
        self.hash = MeetingReferenceAttributionCanonical.opaqueHash(hash)
    }

    private enum CodingKeys: String, CodingKey { case name, hash }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let hash = try container.decode(String.self, forKey: .hash)
        guard MeetingReferenceAttributionCanonical.isLogicalIdentifier(name),
              MeetingReferenceAttributionCanonical.isOpaqueHash(hash) else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: container,
                                                   debugDescription: "Invalid source hash identity")
        }
        self.name = MeetingReferenceAttributionCanonical.normalized(name)
        self.hash = MeetingReferenceAttributionCanonical.normalized(hash)
    }
}

/// Explicit engine provenance.  Hashes are opaque strings so this contract can represent a git
/// revision, source digest, static artifact digest, or a dependency lock digest without guessing
/// its spelling.  Callers must provide logical names, not absolute paths.
nonisolated struct MeetingReferenceAttributionEngineIdentity: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let engineID: String
    let engineVersion: String
    let sourceHashes: [MeetingReferenceAttributionSourceHash]
    let buildHash: String?
    let configurationHash: String

    init(
        engineID: String,
        engineVersion: String,
        sourceHashes: [MeetingReferenceAttributionSourceHash] = [],
        buildHash: String? = nil,
        configurationHash: String
    ) {
        self.schemaVersion = MeetingReferenceAttributionSchema.protocolVersion
        self.engineID = MeetingReferenceAttributionCanonical.logicalIdentifier(engineID)
        self.engineVersion = MeetingReferenceAttributionCanonical.logicalIdentifier(engineVersion)
        self.sourceHashes = sourceHashes.sorted {
            $0.name == $1.name ? $0.hash < $1.hash : $0.name < $1.name
        }
        self.buildHash = buildHash.map(MeetingReferenceAttributionCanonical.opaqueHash)
        self.configurationHash = MeetingReferenceAttributionCanonical.configurationHash(configurationHash)
    }

    init(
        engineID: String,
        engineVersion: String,
        sourceHashes: [String: String],
        buildHash: String? = nil,
        configurationHash: String
    ) {
        self.init(engineID: engineID, engineVersion: engineVersion,
                  sourceHashes: sourceHashes.map { .init(name: $0.key, hash: $0.value) },
                  buildHash: buildHash, configurationHash: configurationHash)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, engineID, engineVersion, sourceHashes, buildHash, configurationHash
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let engineID = try container.decode(String.self, forKey: .engineID)
        let engineVersion = try container.decode(String.self, forKey: .engineVersion)
        let sourceHashes = try container.decode([MeetingReferenceAttributionSourceHash].self, forKey: .sourceHashes)
        let buildHash = try container.decodeIfPresent(String.self, forKey: .buildHash)
        let configurationHash = try container.decode(String.self, forKey: .configurationHash)
        guard schemaVersion == MeetingReferenceAttributionSchema.protocolVersion,
              MeetingReferenceAttributionCanonical.isLogicalIdentifier(engineID),
              MeetingReferenceAttributionCanonical.isLogicalIdentifier(engineVersion),
              sourceHashes.map(\.name).count == Set(sourceHashes.map(\.name)).count,
              buildHash == nil || MeetingReferenceAttributionCanonical.isOpaqueHash(buildHash!),
              MeetingReferenceAttributionCanonical.isConfigurationHash(configurationHash) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "Invalid engine provenance")
        }
        self.schemaVersion = schemaVersion
        self.engineID = MeetingReferenceAttributionCanonical.normalized(engineID)
        self.engineVersion = MeetingReferenceAttributionCanonical.normalized(engineVersion)
        self.sourceHashes = sourceHashes.sorted { $0.name == $1.name ? $0.hash < $1.hash : $0.name < $1.name }
        self.buildHash = buildHash.map(MeetingReferenceAttributionCanonical.normalized)
        self.configurationHash = MeetingReferenceAttributionCanonical.normalized(configurationHash)
    }

    init(
        engineID: String,
        engineVersion: String,
        sourceHashes: [MeetingReferenceAttributionSourceHash] = [],
        buildHash: String? = nil,
        configuration: MeetingReferenceAttributionConfiguration
    ) {
        self.init(engineID: engineID, engineVersion: engineVersion,
                  sourceHashes: sourceHashes, buildHash: buildHash,
                  configurationHash: configuration.configurationHash)
    }

    /// Stable across source-hash insertion order and JSON encoder formatting.
    var stableIdentity: String { MeetingReferenceAttributionCanonical.hash(self) }
    var identityHash: String { stableIdentity }
}

/// Configuration for an offline fixed-frame engine.  Invalid floating-point values are omitted
/// as `nil`, preserving unknown rather than turning bad input into measured silence.
nonisolated struct MeetingReferenceAttributionConfiguration: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sampleRateHz: Int
    let frameDurationMilliseconds: Int
    let hopDurationMilliseconds: Int
    let maximumProcessingMillisecondsPerFrame: Double?
    let maximumMemoryBytes: Int?
    let candidateID: String

    init(
        sampleRateHz: Int = 16_000,
        frameDurationMilliseconds: Int = 10,
        hopDurationMilliseconds: Int = 10,
        maximumProcessingMillisecondsPerFrame: Double? = 100,
        maximumMemoryBytes: Int? = nil,
        candidateID: String = "unselected"
    ) {
        self.schemaVersion = MeetingReferenceAttributionSchema.protocolVersion
        self.sampleRateHz = sampleRateHz > 0 ? sampleRateHz : 16_000
        self.frameDurationMilliseconds = frameDurationMilliseconds > 0 ? frameDurationMilliseconds : 10
        self.hopDurationMilliseconds = hopDurationMilliseconds > 0 ? hopDurationMilliseconds : 10
        self.maximumProcessingMillisecondsPerFrame = MeetingReferenceAttributionCanonical.nonNegative(maximumProcessingMillisecondsPerFrame)
        self.maximumMemoryBytes = maximumMemoryBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.candidateID = MeetingReferenceAttributionCanonical.string(candidateID)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sampleRateHz, frameDurationMilliseconds, hopDurationMilliseconds,
             maximumProcessingMillisecondsPerFrame, maximumMemoryBytes, candidateID
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let sampleRateHz = try container.decode(Int.self, forKey: .sampleRateHz)
        let frameDuration = try container.decode(Int.self, forKey: .frameDurationMilliseconds)
        let hopDuration = try container.decode(Int.self, forKey: .hopDurationMilliseconds)
        let maximumProcessing = try container.decodeIfPresent(Double.self, forKey: .maximumProcessingMillisecondsPerFrame)
        let maximumMemory = try container.decodeIfPresent(Int.self, forKey: .maximumMemoryBytes)
        let candidateID = try container.decode(String.self, forKey: .candidateID)
        guard schemaVersion == MeetingReferenceAttributionSchema.protocolVersion,
              sampleRateHz > 0, frameDuration > 0, hopDuration > 0,
              maximumProcessing == nil || (maximumProcessing!.isFinite && maximumProcessing! >= 0),
              maximumMemory == nil || maximumMemory! >= 0,
              MeetingReferenceAttributionCanonical.isLogicalIdentifier(candidateID) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "Invalid attribution configuration")
        }
        self.init(sampleRateHz: sampleRateHz, frameDurationMilliseconds: frameDuration,
                  hopDurationMilliseconds: hopDuration,
                  maximumProcessingMillisecondsPerFrame: maximumProcessing,
                  maximumMemoryBytes: maximumMemory, candidateID: candidateID)
    }

    var stableIdentity: String { MeetingReferenceAttributionCanonical.hash(self) }
    var configurationHash: String { stableIdentity }
}

/// A frame input is intentionally not Codable: it may carry PCM to an offline implementation, but
/// PCM never crosses into a Codable result or sidecar.  Every frame is fixed-width by the caller.
nonisolated struct MeetingReferenceAttributionPCMFrame: Sendable {
    let samples: [Float]
    let valid: [Bool]

    init(samples: [Float], valid: [Bool]) {
        self.samples = samples
        self.valid = valid
    }

    var hasValidShape: Bool {
        samples.count == valid.count && !samples.isEmpty
    }

    var containsOnlyFiniteSamples: Bool { samples.allSatisfy(\.isFinite) }
}

nonisolated struct MeetingReferenceAttributionFrame: Sendable {
    let frameIndex: Int
    let epoch: UInt64
    let startSeconds: Double
    let durationSeconds: Double
    let microphone: MeetingReferenceAttributionPCMFrame
    let reference: MeetingReferenceAttributionPCMFrame?
    let referenceScope: MeetingReferenceAttributionReferenceScope

    init(
        frameIndex: Int,
        epoch: UInt64,
        startSeconds: Double,
        durationSeconds: Double,
        microphone: MeetingReferenceAttributionPCMFrame,
        reference: MeetingReferenceAttributionPCMFrame?,
        referenceScope: MeetingReferenceAttributionReferenceScope = .unknown
    ) {
        self.frameIndex = frameIndex
        self.epoch = epoch
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.microphone = microphone
        self.reference = reference
        self.referenceScope = referenceScope
    }

    var endSeconds: Double { startSeconds + durationSeconds }
    var hasValidTiming: Bool {
        startSeconds.isFinite && startSeconds >= 0 && durationSeconds.isFinite && durationSeconds > 0
            && endSeconds.isFinite
    }

    /// Validation is explicit because PCM frames are intentionally not Codable. A caller may still
    /// construct an invalid frame to produce a typed fail-open result, but an engine must not
    /// process it as measured audio.
    var validationReasons: [MeetingReferenceAttributionReasonCode] {
        var reasons = [MeetingReferenceAttributionReasonCode]()
        if frameIndex < 0 || !hasValidTiming { reasons.append(.invalidInput) }
        if !microphone.hasValidShape || !microphone.containsOnlyFiniteSamples {
            reasons.append(.invalidInput)
            if !microphone.containsOnlyFiniteSamples { reasons.append(.nonFiniteInput) }
        }
        if let reference {
            if !reference.hasValidShape || !reference.containsOnlyFiniteSamples {
                reasons.append(.invalidInput)
                if !reference.containsOnlyFiniteSamples { reasons.append(.nonFiniteInput) }
            }
        }
        return Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
    }

    var isValid: Bool { validationReasons.isEmpty }

    func validate() throws {
        guard isValid else {
            throw MeetingReferenceAttributionFrameValidationError(reasons: validationReasons)
        }
    }
}

nonisolated struct MeetingReferenceAttributionFrameValidationError: Error, Equatable, Sendable {
    let reasons: [MeetingReferenceAttributionReasonCode]
}

nonisolated struct MeetingReferenceAttributionEpoch: Codable, Equatable, Sendable {
    let epoch: UInt64
    let resetReason: MeetingReferenceAttributionReasonCode?

    init(epoch: UInt64, resetReason: MeetingReferenceAttributionReasonCode? = nil) {
        self.epoch = epoch
        self.resetReason = resetReason
    }

    private enum CodingKeys: String, CodingKey { case epoch, resetReason }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.epoch = try container.decode(UInt64.self, forKey: .epoch)
        self.resetReason = try container.decodeIfPresent(MeetingReferenceAttributionReasonCode.self, forKey: .resetReason)
    }
}

/// Numeric candidate/quality metrics.  Nil means unavailable/unknown; zero is a real measured
/// value.  This distinction is important for coverage accounting and fail-open behavior.
nonisolated struct MeetingReferenceAttributionMetrics: Codable, Equatable, Sendable {
    let delaySeconds: Double?
    let delayJitterSeconds: Double?
    let convergence: Double?
    let resetCount: Int
    let erlDB: Double?
    let erleDB: Double?
    let candidateScore: Double?
    let controlMargin: Double?
    let originalEnergy: Double?
    let residualEnergy: Double?
    let residualToOriginalEnergyRatio: Double?
    let processingMilliseconds: Double?
    let peakMemoryBytes: Int?

    init(
        delaySeconds: Double? = nil,
        delayJitterSeconds: Double? = nil,
        convergence: Double? = nil,
        resetCount: Int = 0,
        erlDB: Double? = nil,
        erleDB: Double? = nil,
        candidateScore: Double? = nil,
        controlMargin: Double? = nil,
        originalEnergy: Double? = nil,
        residualEnergy: Double? = nil,
        residualToOriginalEnergyRatio: Double? = nil,
        processingMilliseconds: Double? = nil,
        peakMemoryBytes: Int? = nil
    ) {
        self.delaySeconds = MeetingReferenceAttributionCanonical.finite(delaySeconds)
        self.delayJitterSeconds = MeetingReferenceAttributionCanonical.nonNegative(delayJitterSeconds)
        self.convergence = MeetingReferenceAttributionCanonical.fraction(convergence)
        self.resetCount = MeetingReferenceAttributionCanonical.nonNegativeInt(resetCount)
        self.erlDB = MeetingReferenceAttributionCanonical.finite(erlDB)
        self.erleDB = MeetingReferenceAttributionCanonical.finite(erleDB)
        self.candidateScore = MeetingReferenceAttributionCanonical.fraction(candidateScore)
        self.controlMargin = MeetingReferenceAttributionCanonical.finite(controlMargin)
        self.originalEnergy = MeetingReferenceAttributionCanonical.nonNegative(originalEnergy)
        self.residualEnergy = MeetingReferenceAttributionCanonical.nonNegative(residualEnergy)
        self.residualToOriginalEnergyRatio = MeetingReferenceAttributionCanonical.nonNegative(residualToOriginalEnergyRatio)
        self.processingMilliseconds = MeetingReferenceAttributionCanonical.nonNegative(processingMilliseconds)
        self.peakMemoryBytes = peakMemoryBytes.flatMap { $0 >= 0 ? $0 : nil }
    }

    private enum CodingKeys: String, CodingKey {
        case delaySeconds, delayJitterSeconds, convergence, resetCount, erlDB, erleDB,
             candidateScore, controlMargin, originalEnergy, residualEnergy,
             residualToOriginalEnergyRatio, processingMilliseconds, peakMemoryBytes
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let delay = try container.decodeIfPresent(Double.self, forKey: .delaySeconds)
        let delayJitter = try container.decodeIfPresent(Double.self, forKey: .delayJitterSeconds)
        let convergence = try container.decodeIfPresent(Double.self, forKey: .convergence)
        let resetCount = try container.decode(Int.self, forKey: .resetCount)
        let erl = try container.decodeIfPresent(Double.self, forKey: .erlDB)
        let erle = try container.decodeIfPresent(Double.self, forKey: .erleDB)
        let candidateScore = try container.decodeIfPresent(Double.self, forKey: .candidateScore)
        let controlMargin = try container.decodeIfPresent(Double.self, forKey: .controlMargin)
        let originalEnergy = try container.decodeIfPresent(Double.self, forKey: .originalEnergy)
        let residualEnergy = try container.decodeIfPresent(Double.self, forKey: .residualEnergy)
        let ratio = try container.decodeIfPresent(Double.self, forKey: .residualToOriginalEnergyRatio)
        let processing = try container.decodeIfPresent(Double.self, forKey: .processingMilliseconds)
        let peakMemory = try container.decodeIfPresent(Int.self, forKey: .peakMemoryBytes)
        let finite = [delay, delayJitter, convergence, erl, erle, candidateScore, controlMargin,
                      originalEnergy, residualEnergy, ratio, processing].compactMap { $0 }
        guard resetCount >= 0, finite.allSatisfy(\.isFinite),
              delayJitter == nil || delayJitter! >= 0,
              convergence == nil || (0...1).contains(convergence!),
              candidateScore == nil || (0...1).contains(candidateScore!),
              originalEnergy == nil || originalEnergy! >= 0,
              residualEnergy == nil || residualEnergy! >= 0,
              ratio == nil || ratio! >= 0,
              processing == nil || processing! >= 0,
              peakMemory == nil || peakMemory! >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .resetCount, in: container,
                                                   debugDescription: "Invalid attribution metric")
        }
        self.init(delaySeconds: delay, delayJitterSeconds: delayJitter, convergence: convergence,
                  resetCount: resetCount, erlDB: erl, erleDB: erle, candidateScore: candidateScore,
                  controlMargin: controlMargin, originalEnergy: originalEnergy,
                  residualEnergy: residualEnergy, residualToOriginalEnergyRatio: ratio,
                  processingMilliseconds: processing, peakMemoryBytes: peakMemory)
    }

    static let unavailable = Self()

    var residualEnergyRatio: Double? { residualToOriginalEnergyRatio }
    var echoReturnLossDB: Double? { erlDB }
    var echoReturnLossEnhancementDB: Double? { erleDB }
}

nonisolated struct MeetingReferenceAttributionFrameResult: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let frameIndex: Int
    let epoch: UInt64
    let startSeconds: Double
    let durationSeconds: Double
    let outcome: MeetingReferenceAttributionOutcome
    let speechState: MeetingReferenceAttributionSpeechState
    let residualVariant: MeetingReferenceAttributionResidualVariant?
    let reasons: [MeetingReferenceAttributionReasonCode]
    let metrics: MeetingReferenceAttributionMetrics
    let fallback: MeetingReferenceAttributionFallback

    init(
        frameIndex: Int,
        epoch: UInt64,
        startSeconds: Double,
        durationSeconds: Double,
        outcome: MeetingReferenceAttributionOutcome,
        speechState: MeetingReferenceAttributionSpeechState = .unknown,
        residualVariant: MeetingReferenceAttributionResidualVariant? = nil,
        reasons: [MeetingReferenceAttributionReasonCode] = [],
        metrics: MeetingReferenceAttributionMetrics = .unavailable,
        fallback: MeetingReferenceAttributionFallback = .originalMicrophone
    ) {
        var finalOutcome = outcome
        var finalReasons = Set(reasons)
        if speechState == .unknown,
           outcome == .likelyPlaybackOnly || outcome == .acceptedNearEndSpeech {
            finalOutcome = .unscored
            finalReasons.insert(.unknownSpeechState)
        }
        // Playback-only is an exclusion decision.  Conflicting positive near-end or mixed
        // speech evidence must degrade to an explicitly uncertain result rather than remain
        // eligible for suppression or profile exclusion as playback-only.
        if outcome == .likelyPlaybackOnly,
           speechState == .nearEndSpeech || speechState == .mixedSpeech {
            finalOutcome = .mixedOrUncertain
            finalReasons.insert(.mixedEvidence)
        }
        let validTiming = frameIndex >= 0 && startSeconds.isFinite && startSeconds >= 0
            && durationSeconds.isFinite && durationSeconds > 0
            && (startSeconds + durationSeconds).isFinite
        if outcome == .acceptedNearEndSpeech && speechState != .nearEndSpeech {
            finalOutcome = .unscored
            finalReasons.insert(.invalidInput)
        }
        if !validTiming {
            finalOutcome = .unscored
            finalReasons.insert(.invalidInput)
        }
        if outcome == .scopeLimited { finalReasons.insert(.referenceScopeLimited) }
        if finalOutcome == .unscored {
            finalReasons.insert(.fallbackToOriginal)
        } else {
            finalReasons.remove(.fallbackToOriginal)
            finalReasons.remove(.unknownSpeechState)
        }
        self.schemaVersion = MeetingReferenceAttributionSchema.sidecarVersion
        self.frameIndex = max(0, frameIndex)
        self.epoch = epoch
        // Invalid timing is represented by one canonical, decodable fail-open shape. In
        // particular, finite-but-overflowing start + duration must not retain a huge duration.
        self.startSeconds = validTiming
            ? startSeconds
            : (startSeconds.isFinite && startSeconds >= 0 ? startSeconds : 0)
        self.durationSeconds = validTiming ? durationSeconds : 0
        self.outcome = finalOutcome
        self.speechState = finalOutcome == .unscored ? .unknown : speechState
        self.residualVariant = finalOutcome == .unscored ? nil : residualVariant
        self.reasons = Array(finalReasons).sorted { $0.rawValue < $1.rawValue }
        self.metrics = metrics
        // A scored result cannot silently carry the legacy/original fallback marker. Normalize a
        // caller that omitted the argument to `.none`; unscored results always remain recoverable.
        self.fallback = finalOutcome == .unscored
            ? .originalMicrophone
            : (fallback == .originalMicrophone ? .none : fallback)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, frameIndex, epoch, startSeconds, durationSeconds, outcome,
             speechState, residualVariant, reasons, metrics, fallback
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let frameIndex = try container.decode(Int.self, forKey: .frameIndex)
        let epoch = try container.decode(UInt64.self, forKey: .epoch)
        let startSeconds = try container.decode(Double.self, forKey: .startSeconds)
        let durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        let outcome = try container.decode(MeetingReferenceAttributionOutcome.self, forKey: .outcome)
        let speechState = try container.decode(MeetingReferenceAttributionSpeechState.self, forKey: .speechState)
        let residualVariant = try container.decodeIfPresent(MeetingReferenceAttributionResidualVariant.self, forKey: .residualVariant)
        let reasons = try container.decode([MeetingReferenceAttributionReasonCode].self, forKey: .reasons)
        let metrics = try container.decode(MeetingReferenceAttributionMetrics.self, forKey: .metrics)
        let fallback = try container.decode(MeetingReferenceAttributionFallback.self, forKey: .fallback)

        let standardTiming = frameIndex >= 0 && startSeconds.isFinite && startSeconds >= 0
            && durationSeconds.isFinite && durationSeconds > 0
            && (startSeconds + durationSeconds).isFinite
        let invalidFailOpenTiming = outcome == .unscored && frameIndex >= 0
            && startSeconds.isFinite && startSeconds >= 0 && durationSeconds == 0
            && reasons.contains(.invalidInput)
        guard schemaVersion == MeetingReferenceAttributionSchema.sidecarVersion,
              standardTiming || invalidFailOpenTiming else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "Invalid frame schema or timing")
        }
        guard Set(reasons).count == reasons.count else {
            throw DecodingError.dataCorruptedError(forKey: .reasons, in: container,
                                                   debugDescription: "Duplicate frame reason")
        }
        guard reasons == reasons.sorted(by: { $0.rawValue < $1.rawValue }) else {
            throw DecodingError.dataCorruptedError(forKey: .reasons, in: container,
                                                   debugDescription: "Non-canonical frame reason ordering")
        }
        let knownSpeechState = speechState != .unknown
        guard (outcome != .likelyPlaybackOnly && outcome != .acceptedNearEndSpeech) || knownSpeechState else {
            throw DecodingError.dataCorruptedError(forKey: .speechState, in: container,
                                                   debugDescription: "Scored outcome requires known speech state")
        }
        if outcome == .acceptedNearEndSpeech && speechState != .nearEndSpeech {
            throw DecodingError.dataCorruptedError(forKey: .speechState, in: container,
                                                   debugDescription: "Accepted speech outcome requires near-end state")
        }
        if outcome == .likelyPlaybackOnly
            && (speechState == .nearEndSpeech || speechState == .mixedSpeech) {
            throw DecodingError.dataCorruptedError(forKey: .speechState, in: container,
                                                   debugDescription: "Playback-only outcome conflicts with speech evidence")
        }
        guard outcome == .unscored || !reasons.contains(.unknownSpeechState) else {
            throw DecodingError.dataCorruptedError(forKey: .reasons, in: container,
                                                   debugDescription: "Scored frame cannot carry unknown speech reason")
        }
        if outcome == .scopeLimited && !reasons.contains(.referenceScopeLimited) {
            throw DecodingError.dataCorruptedError(forKey: .reasons, in: container,
                                                   debugDescription: "Scope-limited outcome requires scope reason")
        }
        if outcome == .unscored {
            guard speechState == .unknown else {
                throw DecodingError.dataCorruptedError(forKey: .speechState, in: container,
                                                       debugDescription: "Unscored frame must have unknown speech state")
            }
            guard fallback == .originalMicrophone, reasons.contains(.fallbackToOriginal) else {
                throw DecodingError.dataCorruptedError(forKey: .fallback, in: container,
                                                       debugDescription: "Unscored frame must fall back to original microphone")
            }
            guard residualVariant == nil else {
                throw DecodingError.dataCorruptedError(forKey: .residualVariant, in: container,
                                                       debugDescription: "Unscored frame cannot expose residual variant")
            }
        } else if fallback == .originalMicrophone {
            throw DecodingError.dataCorruptedError(forKey: .fallback, in: container,
                                                   debugDescription: "Scored frame cannot use original fallback")
        }
        self.schemaVersion = schemaVersion
        self.frameIndex = frameIndex
        self.epoch = epoch
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.outcome = outcome
        self.speechState = speechState
        self.residualVariant = residualVariant
        self.reasons = reasons
        self.metrics = metrics
        self.fallback = fallback
    }

    static func failOpen(
        frame: MeetingReferenceAttributionFrame,
        reason: MeetingReferenceAttributionReasonCode
    ) -> Self {
        Self(frameIndex: frame.frameIndex, epoch: frame.epoch,
             startSeconds: frame.startSeconds, durationSeconds: frame.durationSeconds,
             outcome: .unscored, speechState: .unknown, residualVariant: nil,
             reasons: [reason, .unknownSpeechState, .fallbackToOriginal],
             metrics: .unavailable, fallback: .originalMicrophone)
    }

    var endSeconds: Double { startSeconds + durationSeconds }
    var isKnownSpeechState: Bool { speechState != .unknown }
}

nonisolated struct MeetingReferenceAttributionWouldChangeCounts: Codable, Equatable, Sendable {
    let words: Int
    let segments: Int
    let profileObservations: Int
    let unknownIntervals: Int
    let legacyDisagreements: Int

    init(words: Int = 0, segments: Int = 0, profileObservations: Int = 0,
         unknownIntervals: Int = 0, legacyDisagreements: Int = 0) {
        self.words = MeetingReferenceAttributionCanonical.nonNegativeInt(words)
        self.segments = MeetingReferenceAttributionCanonical.nonNegativeInt(segments)
        self.profileObservations = MeetingReferenceAttributionCanonical.nonNegativeInt(profileObservations)
        self.unknownIntervals = MeetingReferenceAttributionCanonical.nonNegativeInt(unknownIntervals)
        self.legacyDisagreements = MeetingReferenceAttributionCanonical.nonNegativeInt(legacyDisagreements)
    }

    static let zero = Self()

    private enum CodingKeys: String, CodingKey {
        case words, segments, profileObservations, unknownIntervals, legacyDisagreements
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try [
            container.decode(Int.self, forKey: .words),
            container.decode(Int.self, forKey: .segments),
            container.decode(Int.self, forKey: .profileObservations),
            container.decode(Int.self, forKey: .unknownIntervals),
            container.decode(Int.self, forKey: .legacyDisagreements)
        ]
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorruptedError(forKey: .words, in: container,
                                                   debugDescription: "Negative would-change count")
        }
        self.init(words: values[0], segments: values[1], profileObservations: values[2],
                  unknownIntervals: values[3], legacyDisagreements: values[4])
    }
}

/// Duration-weighted coverage.  Counts are informational; percentages are derived from durations
/// so a 10 ms frame and a 30 ms frame cannot accidentally receive equal weight.
nonisolated struct MeetingReferenceAttributionCoverage: Codable, Equatable, Sendable {
    let totalDurationSeconds: Double
    let scoredDurationSeconds: Double
    let likelyPlaybackOnlyDurationSeconds: Double
    let acceptedNearEndSpeechDurationSeconds: Double
    let mixedOrUncertainDurationSeconds: Double
    let scopeLimitedDurationSeconds: Double
    let unscoredDurationSeconds: Double
    let frameCount: Int

    private init(uncheckedZero: Void) {
        self.totalDurationSeconds = 0
        self.scoredDurationSeconds = 0
        self.likelyPlaybackOnlyDurationSeconds = 0
        self.acceptedNearEndSpeechDurationSeconds = 0
        self.mixedOrUncertainDurationSeconds = 0
        self.scopeLimitedDurationSeconds = 0
        self.unscoredDurationSeconds = 0
        self.frameCount = 0
    }

    static let zero = Self(uncheckedZero: ())

    init?(
        totalDurationSeconds: Double,
        scoredDurationSeconds: Double,
        likelyPlaybackOnlyDurationSeconds: Double,
        acceptedNearEndSpeechDurationSeconds: Double,
        mixedOrUncertainDurationSeconds: Double,
        scopeLimitedDurationSeconds: Double,
        unscoredDurationSeconds: Double,
        frameCount: Int
    ) {
        let values = [totalDurationSeconds, scoredDurationSeconds,
                      likelyPlaybackOnlyDurationSeconds, acceptedNearEndSpeechDurationSeconds,
                      mixedOrUncertainDurationSeconds, scopeLimitedDurationSeconds,
                      unscoredDurationSeconds]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), frameCount >= 0,
              abs(scoredDurationSeconds - (likelyPlaybackOnlyDurationSeconds
                + acceptedNearEndSpeechDurationSeconds + mixedOrUncertainDurationSeconds)) <= 1e-9,
              scoredDurationSeconds + unscoredDurationSeconds <= totalDurationSeconds + 1e-9,
              abs((likelyPlaybackOnlyDurationSeconds + acceptedNearEndSpeechDurationSeconds
                + mixedOrUncertainDurationSeconds + scopeLimitedDurationSeconds
                + unscoredDurationSeconds) - totalDurationSeconds) <= 1e-9 else { return nil }
        self.totalDurationSeconds = totalDurationSeconds
        self.scoredDurationSeconds = scoredDurationSeconds
        self.likelyPlaybackOnlyDurationSeconds = likelyPlaybackOnlyDurationSeconds
        self.acceptedNearEndSpeechDurationSeconds = acceptedNearEndSpeechDurationSeconds
        self.mixedOrUncertainDurationSeconds = mixedOrUncertainDurationSeconds
        self.scopeLimitedDurationSeconds = scopeLimitedDurationSeconds
        self.unscoredDurationSeconds = unscoredDurationSeconds
        self.frameCount = frameCount
    }

    var scoredFraction: Double { totalDurationSeconds > 0 ? scoredDurationSeconds / totalDurationSeconds : 0 }
    var unscoredFraction: Double { totalDurationSeconds > 0 ? unscoredDurationSeconds / totalDurationSeconds : 0 }

    private enum CodingKeys: String, CodingKey {
        case totalDurationSeconds, scoredDurationSeconds, likelyPlaybackOnlyDurationSeconds,
             acceptedNearEndSpeechDurationSeconds, mixedOrUncertainDurationSeconds,
             scopeLimitedDurationSeconds, unscoredDurationSeconds, frameCount
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let total = try container.decode(Double.self, forKey: .totalDurationSeconds)
        let scored = try container.decode(Double.self, forKey: .scoredDurationSeconds)
        let playback = try container.decode(Double.self, forKey: .likelyPlaybackOnlyDurationSeconds)
        let nearEnd = try container.decode(Double.self, forKey: .acceptedNearEndSpeechDurationSeconds)
        let mixed = try container.decode(Double.self, forKey: .mixedOrUncertainDurationSeconds)
        let scope = try container.decode(Double.self, forKey: .scopeLimitedDurationSeconds)
        let unscored = try container.decode(Double.self, forKey: .unscoredDurationSeconds)
        let frameCount = try container.decode(Int.self, forKey: .frameCount)
        guard let value = Self(totalDurationSeconds: total, scoredDurationSeconds: scored,
                               likelyPlaybackOnlyDurationSeconds: playback,
                               acceptedNearEndSpeechDurationSeconds: nearEnd,
                               mixedOrUncertainDurationSeconds: mixed,
                               scopeLimitedDurationSeconds: scope,
                               unscoredDurationSeconds: unscored, frameCount: frameCount) else {
            throw DecodingError.dataCorruptedError(forKey: .totalDurationSeconds, in: container,
                                                   debugDescription: "Invalid attribution coverage")
        }
        self = value
    }
}

nonisolated struct MeetingReferenceAttributionResourceCost: Codable, Equatable, Sendable {
    let processingMilliseconds: Double?
    let peakMemoryBytes: Int?
    let derivedSidecarBytes: Int?
    let overBudget: Bool
    let fallback: MeetingReferenceAttributionFallback

    init(processingMilliseconds: Double? = nil, peakMemoryBytes: Int? = nil,
         derivedSidecarBytes: Int? = nil, overBudget: Bool = false,
         fallback: MeetingReferenceAttributionFallback = .none) {
        self.processingMilliseconds = MeetingReferenceAttributionCanonical.nonNegative(processingMilliseconds)
        self.peakMemoryBytes = peakMemoryBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.derivedSidecarBytes = derivedSidecarBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.overBudget = overBudget
        self.fallback = overBudget ? .originalMicrophone : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case processingMilliseconds, peakMemoryBytes, derivedSidecarBytes, overBudget, fallback
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let processing = try container.decodeIfPresent(Double.self, forKey: .processingMilliseconds)
        let memory = try container.decodeIfPresent(Int.self, forKey: .peakMemoryBytes)
        let sidecar = try container.decodeIfPresent(Int.self, forKey: .derivedSidecarBytes)
        let overBudget = try container.decode(Bool.self, forKey: .overBudget)
        let fallback = try container.decode(MeetingReferenceAttributionFallback.self, forKey: .fallback)
        guard processing == nil || (processing!.isFinite && processing! >= 0),
              memory == nil || memory! >= 0,
              sidecar == nil || sidecar! >= 0,
              !overBudget || fallback == .originalMicrophone else {
            throw DecodingError.dataCorruptedError(forKey: .overBudget, in: container,
                                                   debugDescription: "Invalid attribution resource cost")
        }
        self.init(processingMilliseconds: processing, peakMemoryBytes: memory,
                  derivedSidecarBytes: sidecar, overBudget: overBudget, fallback: fallback)
    }
}

nonisolated private struct MeetingReferenceAttributionOutcomeCountEntry: Codable {
    let outcome: MeetingReferenceAttributionOutcome
    let count: Int
}

nonisolated private struct MeetingReferenceAttributionReasonCountEntry: Codable {
    let reason: MeetingReferenceAttributionReasonCode
    let count: Int
}

/// Aggregate result constructed from fixed-frame results.  Invalid/nonfinite frame timing is
/// excluded from measured coverage and represented in `reasonCounts`, never as silence.
nonisolated struct MeetingReferenceAttributionAggregate: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let coverage: MeetingReferenceAttributionCoverage
    let outcomeCounts: [MeetingReferenceAttributionOutcome: Int]
    let reasonCounts: [MeetingReferenceAttributionReasonCode: Int]
    let wouldChange: MeetingReferenceAttributionWouldChangeCounts
    let metrics: MeetingReferenceAttributionMetrics
    let resourceCost: MeetingReferenceAttributionResourceCost

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, coverage, outcomeCounts, reasonCounts, wouldChange, metrics, resourceCost
    }

    init(
        frameResults: [MeetingReferenceAttributionFrameResult],
        wouldChange: MeetingReferenceAttributionWouldChangeCounts = .zero,
        metrics: MeetingReferenceAttributionMetrics = .unavailable,
        resourceCost: MeetingReferenceAttributionResourceCost = .init()
    ) {
        var durations = [MeetingReferenceAttributionOutcome: Double](
            uniqueKeysWithValues: MeetingReferenceAttributionOutcome.allCases.map { ($0, 0) })
        var outcomeCounts = [MeetingReferenceAttributionOutcome: Int](
            uniqueKeysWithValues: MeetingReferenceAttributionOutcome.allCases.map { ($0, 0) })
        var reasonCounts = [MeetingReferenceAttributionReasonCode: Int]()
        var total = 0.0
        var seenFrames = Set<String>()
        var validFrameCount = 0
        for result in frameResults {
            let frameKey = "\(result.epoch):\(result.frameIndex)"
            guard seenFrames.insert(frameKey).inserted else {
                reasonCounts[.duplicateFrame, default: 0] += 1
                continue
            }
            let duration = result.durationSeconds.isFinite && result.durationSeconds > 0 ? result.durationSeconds : 0
            guard duration > 0 else {
                reasonCounts[.invalidInput, default: 0] += 1
                continue
            }
            let nextTotal = total + duration
            let bucket = durations[result.outcome, default: 0]
            let nextBucket = bucket + duration
            guard nextTotal.isFinite, nextBucket.isFinite else {
                reasonCounts[.invalidInput, default: 0] += 1
                continue
            }
            validFrameCount += 1
            total = nextTotal
            durations[result.outcome] = nextBucket
            outcomeCounts[result.outcome, default: 0] += 1
            for reason in result.reasons { reasonCounts[reason, default: 0] += 1 }
        }
        let scored = durations[.likelyPlaybackOnly, default: 0]
            + durations[.acceptedNearEndSpeech, default: 0]
            + durations[.mixedOrUncertain, default: 0]
        let coverage = MeetingReferenceAttributionCoverage(
            totalDurationSeconds: total,
            scoredDurationSeconds: scored,
            likelyPlaybackOnlyDurationSeconds: durations[.likelyPlaybackOnly, default: 0],
            acceptedNearEndSpeechDurationSeconds: durations[.acceptedNearEndSpeech, default: 0],
            mixedOrUncertainDurationSeconds: durations[.mixedOrUncertain, default: 0],
            scopeLimitedDurationSeconds: durations[.scopeLimited, default: 0],
            unscoredDurationSeconds: durations[.unscored, default: 0],
            frameCount: validFrameCount
        ) ?? .zero
        self.schemaVersion = MeetingReferenceAttributionSchema.sidecarVersion
        self.coverage = coverage
        self.outcomeCounts = outcomeCounts
        self.reasonCounts = reasonCounts
        self.wouldChange = wouldChange
        self.metrics = metrics
        self.resourceCost = resourceCost
    }

    /// Count dictionaries use sorted arrays rather than Dictionary's alternating-key encoding.
    /// This makes the sidecar representation explicit and stable across insertion order.
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == MeetingReferenceAttributionSchema.sidecarVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "Unsupported attribution aggregate schema")
        }
        let outcomes = try container.decode([MeetingReferenceAttributionOutcomeCountEntry].self,
                                            forKey: .outcomeCounts)
        let reasons = try container.decode([MeetingReferenceAttributionReasonCountEntry].self,
                                           forKey: .reasonCounts)
        var outcomeCounts = [MeetingReferenceAttributionOutcome: Int]()
        for entry in outcomes {
            guard entry.count >= 0, outcomeCounts.updateValue(entry.count, forKey: entry.outcome) == nil else {
                throw DecodingError.dataCorruptedError(forKey: .outcomeCounts, in: container,
                                                       debugDescription: "Duplicate or negative outcome count")
            }
        }
        var reasonCounts = [MeetingReferenceAttributionReasonCode: Int]()
        for entry in reasons {
            guard entry.count >= 0, reasonCounts.updateValue(entry.count, forKey: entry.reason) == nil else {
                throw DecodingError.dataCorruptedError(forKey: .reasonCounts, in: container,
                                                       debugDescription: "Duplicate or negative reason count")
            }
        }
        self.schemaVersion = version
        self.coverage = try container.decode(MeetingReferenceAttributionCoverage.self, forKey: .coverage)
        self.outcomeCounts = outcomeCounts
        self.reasonCounts = reasonCounts
        self.wouldChange = try container.decode(MeetingReferenceAttributionWouldChangeCounts.self, forKey: .wouldChange)
        self.metrics = try container.decode(MeetingReferenceAttributionMetrics.self, forKey: .metrics)
        self.resourceCost = try container.decode(MeetingReferenceAttributionResourceCost.self, forKey: .resourceCost)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(coverage, forKey: .coverage)
        let outcomes = outcomeCounts.keys.sorted { $0.rawValue < $1.rawValue }.map {
            MeetingReferenceAttributionOutcomeCountEntry(outcome: $0, count: outcomeCounts[$0] ?? 0)
        }
        let reasons = reasonCounts.keys.sorted { $0.rawValue < $1.rawValue }.map {
            MeetingReferenceAttributionReasonCountEntry(reason: $0, count: reasonCounts[$0] ?? 0)
        }
        try container.encode(outcomes, forKey: .outcomeCounts)
        try container.encode(reasons, forKey: .reasonCounts)
        try container.encode(wouldChange, forKey: .wouldChange)
        try container.encode(metrics, forKey: .metrics)
        try container.encode(resourceCost, forKey: .resourceCost)
    }
}

/// Numeric-only, deterministic sidecar.  `sidecarHash` hashes the complete Codable payload and is
/// therefore stable for the same engine/configuration/results, independent of dictionary order.
nonisolated struct MeetingReferenceAttributionSidecar: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let engineIdentity: MeetingReferenceAttributionEngineIdentity
    let configuration: MeetingReferenceAttributionConfiguration
    let epochs: [MeetingReferenceAttributionEpoch]
    let frameResults: [MeetingReferenceAttributionFrameResult]
    let aggregate: MeetingReferenceAttributionAggregate

    nonisolated enum ValidationError: Error, Equatable, Sendable {
        case invalid(String)
    }

    init(
        engineIdentity: MeetingReferenceAttributionEngineIdentity,
        configuration: MeetingReferenceAttributionConfiguration,
        epochs: [MeetingReferenceAttributionEpoch] = [],
        frameResults: [MeetingReferenceAttributionFrameResult],
        aggregate: MeetingReferenceAttributionAggregate? = nil
    ) {
        self.schemaVersion = MeetingReferenceAttributionSchema.sidecarVersion
        self.engineIdentity = engineIdentity
        self.configuration = configuration
        let sortedFrames = frameResults.sorted {
            $0.epoch == $1.epoch ? $0.frameIndex < $1.frameIndex : $0.epoch < $1.epoch
        }
        self.frameResults = sortedFrames
        let frameEpochs = Set(sortedFrames.map(\.epoch)).sorted()
        // Preserve caller-supplied epoch evidence verbatim. Duplicate or incomplete epochs are
        // invalid evidence, but remain representable for validation instead of trapping or being
        // silently repaired. An omitted list gets the convenience defaults for valid construction.
        self.epochs = epochs.isEmpty
            ? frameEpochs.map { .init(epoch: $0) }
            : epochs.sorted { $0.epoch < $1.epoch }
        self.aggregate = aggregate ?? MeetingReferenceAttributionAggregate(frameResults: sortedFrames)
    }

    var sidecarHash: String { MeetingReferenceAttributionCanonical.hash(self) }

    /// Structural validation is exposed for programmatic construction; decoding throws the same
    /// errors so a corrupt sidecar cannot be treated as measured evidence.
    var validationError: ValidationError? {
        let resultEpochs = Set(frameResults.map(\.epoch))
        let epochValues = epochs.map(\.epoch)
        let canonicalFrames = frameResults.sorted {
            $0.epoch == $1.epoch ? $0.frameIndex < $1.frameIndex : $0.epoch < $1.epoch
        }
        guard frameResults.map({ "\($0.epoch):\($0.frameIndex)" })
                == canonicalFrames.map({ "\($0.epoch):\($0.frameIndex)" }) else {
            return .invalid("non-canonical frame ordering")
        }
        var frameKeys = Set<String>()
        for frame in frameResults {
            guard frameKeys.insert("\(frame.epoch):\(frame.frameIndex)").inserted else {
                return .invalid("duplicate epoch/frame key")
            }
        }
        guard epochValues == epochValues.sorted() else {
            return .invalid("non-canonical epoch ordering")
        }
        guard Set(epochValues).count == epochValues.count else { return .invalid("duplicate epoch") }
        guard Set(epochValues) == resultEpochs else { return .invalid("incomplete epoch/frame keys") }
        // Epochs are reset markers, not permission to move backwards in the session timeline.
        // Validate the canonical global order so a later epoch cannot overlap an earlier one.
        guard zip(frameResults, frameResults.dropFirst()).allSatisfy({ previous, next in
            next.startSeconds + 1e-9 >= previous.endSeconds
        }) else { return .invalid("non-monotonic frame timing") }
        guard MeetingReferenceAttributionCanonical.isLogicalIdentifier(engineIdentity.engineID),
              MeetingReferenceAttributionCanonical.isLogicalIdentifier(engineIdentity.engineVersion),
              engineIdentity.sourceHashes.allSatisfy({
                  MeetingReferenceAttributionCanonical.isLogicalIdentifier($0.name)
                    && MeetingReferenceAttributionCanonical.isOpaqueHash($0.hash)
              }),
              Set(engineIdentity.sourceHashes.map(\.name)).count == engineIdentity.sourceHashes.count,
              engineIdentity.buildHash == nil
                || MeetingReferenceAttributionCanonical.isOpaqueHash(engineIdentity.buildHash!),
              MeetingReferenceAttributionCanonical.isLogicalIdentifier(configuration.candidateID),
              configuration.sampleRateHz > 0,
              configuration.frameDurationMilliseconds > 0,
              configuration.hopDurationMilliseconds > 0,
              configuration.maximumProcessingMillisecondsPerFrame == nil
                || (configuration.maximumProcessingMillisecondsPerFrame!.isFinite
                    && configuration.maximumProcessingMillisecondsPerFrame! >= 0),
              configuration.maximumMemoryBytes == nil || configuration.maximumMemoryBytes! >= 0,
              engineIdentity.configurationHash == configuration.configurationHash else {
            return .invalid("engine/configuration hash mismatch")
        }
        guard MeetingReferenceAttributionCanonical.isConfigurationHash(engineIdentity.configurationHash),
              MeetingReferenceAttributionCanonical.isConfigurationHash(configuration.configurationHash) else {
            return .invalid("invalid engine/configuration provenance hash")
        }
        let expected = MeetingReferenceAttributionAggregate(
            frameResults: frameResults,
            wouldChange: aggregate.wouldChange,
            metrics: aggregate.metrics,
            resourceCost: aggregate.resourceCost
        )
        guard expected == aggregate else { return .invalid("aggregate mismatch") }
        return nil
    }

    var isValid: Bool { validationError == nil }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, engineIdentity, configuration, epochs, frameResults, aggregate
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let engineIdentity = try container.decode(MeetingReferenceAttributionEngineIdentity.self, forKey: .engineIdentity)
        let configuration = try container.decode(MeetingReferenceAttributionConfiguration.self, forKey: .configuration)
        let epochs = try container.decode([MeetingReferenceAttributionEpoch].self, forKey: .epochs)
        let frameResults = try container.decode([MeetingReferenceAttributionFrameResult].self, forKey: .frameResults)
        let aggregate = try container.decode(MeetingReferenceAttributionAggregate.self, forKey: .aggregate)
        guard schemaVersion == MeetingReferenceAttributionSchema.sidecarVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "Unsupported attribution sidecar schema")
        }
        self.schemaVersion = schemaVersion
        self.engineIdentity = engineIdentity
        self.configuration = configuration
        self.epochs = epochs
        self.frameResults = frameResults
        self.aggregate = aggregate
        if let validationError {
            throw DecodingError.dataCorruptedError(forKey: .aggregate, in: container,
                                                   debugDescription: "Invalid attribution sidecar: \(validationError)")
        }
    }
}

/// Common offline seam.  Implementations receive one fixed frame at a time and return metadata
/// only.  No implementation is installed or called by this contract file.
nonisolated protocol MeetingReferenceAttributionEngine: Sendable {
    var identity: MeetingReferenceAttributionEngineIdentity { get }
    var configuration: MeetingReferenceAttributionConfiguration { get }

    mutating func reset(to epoch: MeetingReferenceAttributionEpoch)
    mutating func process(_ frame: MeetingReferenceAttributionFrame) -> MeetingReferenceAttributionFrameResult
    mutating func finish() -> MeetingReferenceAttributionSidecar
}

nonisolated extension MeetingReferenceAttributionEngine {
    mutating func process(frame: MeetingReferenceAttributionFrame) -> MeetingReferenceAttributionFrameResult {
        process(frame)
    }
}
