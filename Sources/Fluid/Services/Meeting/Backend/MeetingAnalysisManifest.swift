import Foundation

// Stage C2a of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§3, §4) and
// `MEETING_TRANSCRIPTION_BACKEND_ARCHITECTURE_PLAN.md` §5.1: the immutable analysis manifest.
//
// The manifest is the single source-to-analysis-to-presentation mapper for the new backend. It is
// built from a frozen `MeetingBackendPlan` before any model work, and every fact in it is either
// copied from that frozen request or *actually observed* on disk. Nothing here guesses: a universal
// AAC priming delay is never assumed, an unmeasured clock fit stays unknown, and audio that could
// not be read, verified or admitted becomes an explicit typed gap instead of silence that looks
// like coverage.
//
// A planned chunk is represented by one or more non-overlapping *pieces* whose recorded
// presentation intervals union to exactly the chunk's recorded interval. A capture-era boundary
// inside a chunk therefore splits it: the safe part stays an analysable span and the unsafe part
// becomes an inadmissible gap. Nothing is discarded wholesale, and nothing unsafe is laundered.
//
// This slice contains the types, the canonical admission rule, the observation boundary, the
// builder and the fail-closed validator. It writes nothing durable, creates no product speaker ID
// and applies no echo policy — those are later Stage C work.

nonisolated enum MeetingAnalysisManifestSchema {
    static let currentVersion = 1

    /// Affine round-trip slack. The manifest computes each piece's transform exactly, so this only
    /// absorbs floating-point error — it is not a licence to disagree with the mapping.
    static let mappingToleranceSeconds: Double = 1e-6

    /// Default bound for the measured decoded-length-versus-recorded-PTS fit residual. A span whose
    /// residual exceeds its bound is `timingUncertain` (architecture plan §5.1).
    static let defaultResidualBoundSeconds: Double = 0.050

    /// Two consecutive planned chunks whose recorded intervals are farther apart than this are not
    /// contiguous, and the later one begins a new analysis epoch.
    static let chunkContiguityToleranceSeconds: Double = 0.001
}

// MARK: - Intervals

/// Half-open seconds interval. Every interval in the manifest is finite and strictly positive;
/// there is no "empty interval means unknown" encoding anywhere in this file.
nonisolated struct MeetingAnalysisInterval: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval {
        self.end - self.start
    }

    var isValid: Bool {
        MeetingEvidenceInterval.isValid(start: self.start, end: self.end)
    }

    func contains(
        _ other: Self,
        toleranceSeconds: Double = MeetingAnalysisManifestSchema.mappingToleranceSeconds
    ) -> Bool {
        other.start >= self.start - toleranceSeconds && other.end <= self.end + toleranceSeconds
    }
}

// MARK: - Codec priming

nonisolated enum MeetingCodecPrimingUnknownReason: String, Codable, CaseIterable {
    /// The decoder exposed no priming/trim information for this file. The common case for the
    /// AAC chunks FluidVoice writes: `AVAudioFile` reports a decoded length, not an encoder delay.
    case decoderDidNotReport
    /// The observation deliberately did not inspect priming.
    case notInspected
}

/// Codec delay/priming as an explicit known-or-unknown value. There is no third state, and
/// `unknown` is never silently treated as zero frames.
nonisolated enum MeetingCodecPriming: Codable, Equatable {
    /// Only for a value a decoder actually reported. A measured zero is a real measurement.
    case measuredFrames(Int)
    case unknown(MeetingCodecPrimingUnknownReason)
    /// Linear PCM has no codec delay. This is deliberately distinct from a measured AAC value:
    /// it records that priming is not applicable to the authoritative capture asset.
    case notApplicable(MeetingAudioEncoding)

    var measuredFrames: Int? {
        switch self {
        case let .measuredFrames(frames): return frames
        case .unknown, .notApplicable: return nil
        }
    }

    var isKnown: Bool {
        switch self {
        case .measuredFrames: return true
        case .notApplicable(.linearPCMFloat32CAFV1): return true
        case .unknown, .notApplicable: return false
        }
    }
}

// Keep the synthesized legacy shape (`{"unknown":"..."}` / `{"measuredFrames":N}`)
// readable while adding the explicit PCM representation. New writes use the same keyed shape.
nonisolated extension MeetingCodecPriming {
    private enum CodingKeys: String, CodingKey { case measuredFrames, unknown, notApplicable }
    private enum AssociatedValueKeys: String, CodingKey { case _0 }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.measuredFrames) {
            if let value = try? container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .measuredFrames) {
                self = .measuredFrames(try value.decode(Int.self, forKey: ._0))
            } else {
                // Be liberal for any interim build that emitted a direct scalar.
                self = .measuredFrames(try container.decode(Int.self, forKey: .measuredFrames))
            }
        } else if container.contains(.unknown) {
            if let value = try? container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .unknown) {
                self = .unknown(try value.decode(MeetingCodecPrimingUnknownReason.self, forKey: ._0))
            } else {
                self = .unknown(try container.decode(MeetingCodecPrimingUnknownReason.self, forKey: .unknown))
            }
        } else if container.contains(.notApplicable) {
            if let value = try? container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .notApplicable) {
                self = .notApplicable(try value.decode(MeetingAudioEncoding.self, forKey: ._0))
            } else {
                self = .notApplicable(try container.decode(MeetingAudioEncoding.self, forKey: .notApplicable))
            }
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .measuredFrames,
                in: container,
                debugDescription: "Invalid codec priming representation."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .measuredFrames(value):
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .measuredFrames)
            try nested.encode(value, forKey: ._0)
        case let .unknown(value):
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .unknown)
            try nested.encode(value, forKey: ._0)
        case let .notApplicable(value):
            var nested = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .notApplicable)
            try nested.encode(value, forKey: ._0)
        }
    }
}

// MARK: - Observed audio facts

/// What a decoder actually reported for one chunk file. None of these values are derived from the
/// recorded session manifest, from AAC frame arithmetic or from the chunk's nominal duration.
nonisolated struct MeetingChunkDecodedFacts: Codable, Equatable {
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int64
    /// `frameCount / sampleRate` as observed. Recorded rather than recomputed downstream so a
    /// reader never has to reconstruct it from a different rate.
    let durationSeconds: Double
    let codecPriming: MeetingCodecPriming
    /// Free-form description of the decoder's processing format, for provenance only.
    let processingFormatDescription: String

    /// Seconds of measured codec priming. `nil` when priming was never measured — never zero.
    var primingSeconds: Double? {
        guard let frames = self.codecPriming.measuredFrames, self.sampleRate > 0 else { return nil }
        return Double(frames) / self.sampleRate
    }

    /// Decoded seconds that are not codec priming.
    var usableDurationSeconds: Double {
        self.durationSeconds - (self.primingSeconds ?? 0)
    }
}

/// Identity of the bytes that were actually present when the manifest was built. A stored digest
/// alone does not prove the file is still intact, so the observation re-verifies both.
nonisolated struct MeetingChunkObservedAudio: Codable, Equatable {
    let byteCount: Int64
    let sha256: String
    let decoded: MeetingChunkDecodedFacts
}

// MARK: - Capture era identity

/// The capture era a piece's audio belongs to, after persisted mixed-domain era starts have been
/// normalized through the existing pipeline semantics (`microphoneEras(for:origin:)`).
nonisolated struct MeetingCaptureEraIdentity: Codable, Equatable {
    let index: Int
    /// The recorded capture method. `nil` only for an application-audio track whose session
    /// manifest never recorded one — an absent fact, not an assumed `screenCaptureKit`.
    let method: MeetingAudioTrackCaptureMethod?
    let deviceUID: String?
    let deviceName: String?
    /// Origin-relative era start. `nil` is the first era, which the pipeline pins open at the
    /// beginning of the track (`-infinity`); the manifest never stores a non-finite bound.
    let normalizedStartSeconds: Double?
    /// Microphone echo protection as recorded. `nil` for application audio, where the concept does
    /// not apply — deliberately not `unprotected`, which would assert something false.
    let echoProtection: MeetingMicrophoneEchoProtection?
    let aecProvenance: MeetingAECProvenance?
    /// The era's own recorded clock-drift fit, the sole input to this manifest's de-drift decision.
    let clockDrift: MeetingClockDriftRecord?

    /// Era equality for epoch purposes: the facts that change what the microphone input *is*.
    /// Display name, elected role, settled configuration and drift records are metadata; a change
    /// in them alone does not split an epoch (implementation plan §3).
    func isSameInput(as other: Self) -> Bool {
        self.method == other.method
            && self.deviceUID == other.deviceUID
            && self.echoProtection == other.echoProtection
    }
}

/// Normalization of a track's persisted capture eras, and the de-drift decision derived from them.
/// Microphone eras go through the existing pipeline helper so the manifest cannot disagree with the
/// legacy path about which era an interval belongs to.
nonisolated enum MeetingAnalysisCaptureEras {
    /// Origin-relative era starts. Index 0 is `-infinity`: the pipeline pins the first era open at
    /// the beginning of the track. An application-audio track has exactly one open era.
    static func normalizedStarts(for track: MeetingAudioTrack, origin: Double) -> [Double] {
        switch track.kind {
        case .applicationAudio:
            return [-.infinity]
        case .microphone:
            return MeetingProcessingPipeline.microphoneEras(for: track, origin: origin).map(\.startSeconds)
        }
    }

    static func identities(for track: MeetingAudioTrack, origin: Double) -> [MeetingCaptureEraIdentity] {
        switch track.kind {
        case .applicationAudio:
            // Application audio carries no microphone era metadata at all; recording anything but
            // the track's own capture method here would be invention.
            return [MeetingCaptureEraIdentity(
                index: 0,
                method: track.captureMethod,
                deviceUID: nil,
                deviceName: nil,
                normalizedStartSeconds: nil,
                echoProtection: nil,
                aecProvenance: nil,
                clockDrift: nil
            )]
        case .microphone:
            return MeetingProcessingPipeline.microphoneEras(for: track, origin: origin)
                .enumerated()
                .map { index, era in
                    MeetingCaptureEraIdentity(
                        index: index,
                        method: era.method,
                        deviceUID: era.deviceUID,
                        deviceName: era.deviceName,
                        normalizedStartSeconds: era.startSeconds.isFinite ? era.startSeconds : nil,
                        echoProtection: era.echoProtection,
                        aecProvenance: era.aecProvenance,
                        clockDrift: era.clockDrift
                    )
                }
        }
    }

    /// Index of the era containing `presentationSeconds`, using the pipeline's own rule.
    static func index(containing presentationSeconds: Double, starts: [Double]) -> Int {
        var index = 0
        for (offset, start) in starts.enumerated() where start <= presentationSeconds {
            index = offset
        }
        return index
    }

    static func endSeconds(afterIndex index: Int, starts: [Double]) -> Double {
        starts.indices.contains(index + 1) ? starts[index + 1] : .infinity
    }

    /// The anchor the existing de-drift correction pivots around. Era 0's containment boundary is a
    /// `-infinity` sentinel, so it anchors at the track's own first recorded PTS — exactly what
    /// `MeetingProcessingPipeline` computes as `era0AnchorRelative`.
    static func anchorSeconds(
        for identity: MeetingCaptureEraIdentity,
        track: MeetingAudioTrack,
        origin: Double
    ) -> Double {
        if let start = identity.normalizedStartSeconds { return start }
        return (track.chunks.map(\.presentationStart.seconds).min() ?? origin) - origin
    }

    /// The affine rate `MeetingMicrophoneDeDrift.correct` would apply inside this era, or `nil`
    /// when that helper would decline. The guards are the existing ones, not new policy.
    static func deDriftFactor(for identity: MeetingCaptureEraIdentity) -> Double? {
        guard identity.method == .voiceProcessing,
              let drift = identity.clockDrift,
              drift.eligible,
              drift.elapsedValidHostSeconds > 0
        else { return nil }
        let fraction = drift.cumulativeAbsorbedSeconds / drift.elapsedValidHostSeconds
        guard abs(drift.cumulativeAbsorbedSeconds) > MeetingMicrophoneDeDrift.materialityThresholdSeconds,
              abs(fraction) * 1_000_000 < MeetingMicrophoneDeDrift.maxAbsolutePPM,
              (1 + fraction).isFinite,
              1 + fraction > 0
        else { return nil }
        return 1 + fraction
    }

    /// The de-drift application this manifest owns for one era. Exactly one of these values is
    /// representable per span, which is what makes a second correction downstream a contradiction.
    static func deDrift(
        for identity: MeetingCaptureEraIdentity,
        anchorSeconds: Double
    ) -> MeetingDeDriftApplication {
        if let factor = deDriftFactor(for: identity) {
            return .appliedOnce(factor: factor, eraStartSeconds: anchorSeconds)
        }
        if identity.method == .voiceProcessing, identity.clockDrift != nil {
            return .ineligible(.driftRecordDeclined)
        }
        return .notApplicable
    }
}

// MARK: - Canonical admission

nonisolated enum MeetingCanonicalAdmissionDecision: String, Codable, CaseIterable {
    case admissible
    case inadmissible
}

/// Why the canonical backend may or may not use a piece's audio. Rationales are separate tokens per
/// protection state so an inadmissible interval can never be reported as a generic "unknown".
nonisolated enum MeetingCanonicalAdmissionRationale: String, Codable, CaseIterable {
    /// Application audio carries no microphone echo-protection requirement at all.
    case applicationAudio
    /// In-room microphone audio does not require echo protection (implementation plan §3).
    case inRoomMicrophone
    case onlineMicrophoneVoiceProcessed
    case onlineMicrophoneAcousticallyClosed
    case onlineMicrophoneSoftwareEchoCancelled
    case onlineMicrophoneUnprotected
    /// Legacy-era audio stays usable only through the existing explicit legacy compatibility
    /// policy. The canonical backend has no such policy, so it is inadmissible here.
    case onlineMicrophoneLegacyUnclassified
    /// A microphone piece arrived with no recorded protection state at all.
    case onlineMicrophoneProtectionMissing

    var decision: MeetingCanonicalAdmissionDecision {
        switch self {
        case .applicationAudio,
             .inRoomMicrophone,
             .onlineMicrophoneVoiceProcessed,
             .onlineMicrophoneAcousticallyClosed,
             .onlineMicrophoneSoftwareEchoCancelled:
            return .admissible
        case .onlineMicrophoneUnprotected,
             .onlineMicrophoneLegacyUnclassified,
             .onlineMicrophoneProtectionMissing:
            return .inadmissible
        }
    }
}

/// The canonical-backend admission rule, fail-closed and total. It is deliberately stricter than
/// `MeetingMicrophoneEchoProtection.admitsTranscript`, which still admits `legacyUnclassified` for
/// the legacy adapter. Keeping both visible is the point: this slice must not relabel legacy audio
/// as positively verified.
nonisolated enum MeetingCanonicalAdmission {
    static func rationale(
        captureMode: MeetingCaptureMode,
        trackKind: MeetingAudioTrackKind,
        echoProtection: MeetingMicrophoneEchoProtection?
    ) -> MeetingCanonicalAdmissionRationale {
        guard trackKind == .microphone else { return .applicationAudio }
        if captureMode == .inRoom { return .inRoomMicrophone }
        switch echoProtection {
        case .voiceProcessed: return .onlineMicrophoneVoiceProcessed
        case .acousticallyClosed: return .onlineMicrophoneAcousticallyClosed
        case .softwareEchoCancelled: return .onlineMicrophoneSoftwareEchoCancelled
        case .unprotected: return .onlineMicrophoneUnprotected
        case .legacyUnclassified: return .onlineMicrophoneLegacyUnclassified
        case .none: return .onlineMicrophoneProtectionMissing
        }
    }
}

/// Admission provenance for one span or inadmissible gap: the decision, the rule that produced it
/// and the inputs that rule read.
nonisolated struct MeetingSpanAdmission: Codable, Equatable {
    let decision: MeetingCanonicalAdmissionDecision
    let rationale: MeetingCanonicalAdmissionRationale
    let captureMode: MeetingCaptureMode
    let trackKind: MeetingAudioTrackKind
    let echoProtection: MeetingMicrophoneEchoProtection?

    init(
        captureMode: MeetingCaptureMode,
        trackKind: MeetingAudioTrackKind,
        echoProtection: MeetingMicrophoneEchoProtection?
    ) {
        let rationale = MeetingCanonicalAdmission.rationale(
            captureMode: captureMode,
            trackKind: trackKind,
            echoProtection: echoProtection
        )
        self.decision = rationale.decision
        self.rationale = rationale
        self.captureMode = captureMode
        self.trackKind = trackKind
        self.echoProtection = echoProtection
    }
}

// MARK: - Timing

nonisolated enum MeetingSpanTimingCertainty: String, Codable, CaseIterable {
    case certain
    /// The measured fit residual is missing or out of bounds, or the codec priming this span's
    /// offset depends on was never measured. The architecture plan requires such a span's words to
    /// stay explicit and ambiguous rather than confidently assigned.
    case timingUncertain
}

/// Whether the existing microphone de-drift correction was applied to this span, and with what
/// factor. The manifest is the only owner of that correction for the new backend, so exactly one
/// application is representable and a second one downstream would be a visible contradiction.
nonisolated enum MeetingDeDriftApplication: Codable, Equatable {
    /// No drift correction is defined for this input (application audio, or a non-VPIO era).
    case notApplicable
    /// A drift record exists but the existing eligibility/materiality rules declined it.
    case ineligible(MeetingDeDriftIneligibilityReason)
    /// Applied exactly once, here. `factor` is the existing `1 + cumulative/elapsed` rate.
    case appliedOnce(factor: Double, eraStartSeconds: Double)

    var appliedFactor: Double? {
        switch self {
        case let .appliedOnce(factor, _): return factor
        case .notApplicable, .ineligible: return nil
        }
    }
}

nonisolated enum MeetingDeDriftIneligibilityReason: String, Codable, CaseIterable {
    /// The era's own `MeetingClockDriftRecord` is absent, ineligible or immaterial.
    case driftRecordDeclined
}

/// Piecewise-affine analysis-to-presentation transform for one span, plus the evidence behind it.
/// `presentation(a) = a * rateRatio + offsetSeconds` over the span's analysis interval.
nonisolated struct MeetingAnalysisTimeTransform: Codable, Equatable {
    /// The owning track's recorded host-clock anchor. Copied from the frozen request, never
    /// recomputed and never derived from file timestamps.
    let hostClockAnchor: UInt64
    let rateRatio: Double
    let offsetSeconds: Double
    /// Observed decoded rate ÷ the backend's analysis rate. `nil` when the analysis rate is not
    /// known to this build — unknown, not 1.
    let sampleRateConversionRatio: Double?
    /// Seconds of codec priming removed from analysis time. Non-`nil` only when priming was truly
    /// measured; an unknown priming never becomes a silent zero-second compensation.
    let codecPrimingCompensationSeconds: Double?
    /// Analysis time is per track, gap-removed and monotonic; presentation time retains the gaps.
    let analysisRemovesGaps: Bool

    func presentationTime(forAnalysisTime analysisTime: TimeInterval) -> TimeInterval {
        analysisTime * self.rateRatio + self.offsetSeconds
    }
}

nonisolated struct MeetingSpanTimingMetadata: Codable, Equatable {
    let certainty: MeetingSpanTimingCertainty
    /// Measured residual between the mapped decoded length of this span's chunk and that chunk's
    /// recorded presentation duration. `nil` means no fit was measured — explicitly unknown,
    /// never zero.
    let fitResidualSeconds: Double?
    let residualBoundSeconds: Double
    let deDrift: MeetingDeDriftApplication

    /// The only certainty rule: a measured residual inside the bound *and* a measured codec
    /// priming. An unknown priming leaves the span's offset uncertain by an unmeasured encoder
    /// delay, which is exactly the universal-AAC-delay guess the plan forbids.
    static func certainty(
        fitResidualSeconds: Double?,
        residualBoundSeconds: Double,
        codecPriming: MeetingCodecPriming
    ) -> MeetingSpanTimingCertainty {
        guard codecPriming.isKnown,
              let fitResidualSeconds,
              fitResidualSeconds.isFinite,
              abs(fitResidualSeconds) <= residualBoundSeconds
        else { return .timingUncertain }
        return .certain
    }
}

// MARK: - Discontinuity

nonisolated struct MeetingSpanDiscontinuityBoundary: Codable, Equatable {
    let kind: MeetingInterruptionKind
    /// Origin-relative seconds. `nil` when the recorded discontinuity carried no presentation
    /// time; the boundary is still reported, with its position unknown.
    let presentationSeconds: Double?
    let gapSeconds: Double?
    let detail: String?
}

nonisolated struct MeetingSpanDiscontinuityFacts: Codable, Equatable {
    /// Discontinuities recorded on this piece's chunk, copied from the session manifest. Every
    /// piece of a chunk carries the same copy; only the chunk's first piece may use them as an
    /// epoch boundary, because that is where the chunk actually begins.
    let boundaries: [MeetingSpanDiscontinuityBoundary]
    /// The previous planned chunk on this track ends before this one starts by more than the
    /// contiguity tolerance.
    let precededByChunkTimeGap: Bool
    /// Measured size of that gap. `nil` when there is no preceding planned chunk.
    let precedingGapSeconds: Double?

    static let contiguous = Self(
        boundaries: [],
        precededByChunkTimeGap: false,
        precedingGapSeconds: nil
    )

    /// Copies a chunk's recorded discontinuities into origin-relative form.
    static func make(
        chunk: MeetingAudioChunk,
        previousChunk: MeetingAudioChunk?,
        origin: Double
    ) -> Self {
        let precedingGap = previousChunk.map {
            (chunk.presentationStart.seconds - origin) - ($0.presentationEnd.seconds - origin)
        }
        return Self(
            boundaries: chunk.discontinuities.map { discontinuity in
                MeetingSpanDiscontinuityBoundary(
                    kind: discontinuity.kind,
                    presentationSeconds: discontinuity.presentationTime.map { $0.seconds - origin },
                    gapSeconds: discontinuity.gapSeconds,
                    detail: discontinuity.detail
                )
            },
            precededByChunkTimeGap: (precedingGap ?? 0)
                > MeetingAnalysisManifestSchema.chunkContiguityToleranceSeconds,
            precedingGapSeconds: precedingGap
        )
    }
}

// MARK: - Chunk identity

/// Everything about a planned chunk that the manifest must agree with the frozen request on. A
/// piece that mis-states any of it is refused: it would describe a different file.
nonisolated struct MeetingAnalysisChunkIdentity: Codable, Equatable, Hashable {
    let trackID: MeetingAudioTrackID
    let chunkID: MeetingAudioChunkID
    let sequence: Int
    /// Session-directory-relative, exactly as recorded.
    let relativeFilePath: String
    let storedByteCount: Int64
    let storedSHA256: String

    /// The authoritative bytes used for analysis. For legacy chunks these equal the stored chunk
    /// fields; for an activated PCM-first chunk they point at the ready capture-analysis asset.
    let analysisEncoding: MeetingAudioEncoding?

    init(trackID: MeetingAudioTrackID, chunk: MeetingAudioChunk) {
        self.trackID = trackID
        self.chunkID = chunk.id
        self.sequence = chunk.sequence
        if let asset = chunk.captureAnalysisAsset,
           asset.presence == .ready,
           asset.role == .captureAnalysis,
           asset.encoding == .linearPCMFloat32CAFV1 {
            self.relativeFilePath = asset.relativeFilePath
            self.storedByteCount = asset.byteCount
            self.storedSHA256 = asset.sha256 ?? ""
            self.analysisEncoding = asset.encoding
        } else {
            self.relativeFilePath = chunk.relativeFilePath
            self.storedByteCount = chunk.byteCount
            self.storedSHA256 = chunk.sha256
            // A schema-bearing chunk without a ready PCM asset is never allowed to silently
            // fall back to AAC. Keep a legacy chunk (which has no schema) distinguishable from a
            // malformed PCM-first chunk so the materializer can refuse the latter.
            self.analysisEncoding = chunk.audioSchemaVersion == nil
                ? nil
                : .legacyAACUnknownPrimingV1
        }
    }

    var key: MeetingAnalysisChunkKey {
        MeetingAnalysisChunkKey(trackID: self.trackID, chunkID: self.chunkID)
    }
}

/// Chunk scope is keyed by track *and* chunk. A chunk UUID alone is not a scope key: two tracks may
/// legally carry the same identifier in a hand-built or corrupted manifest, and coverage accounting
/// keyed only by UUID would let one track's span satisfy another track's planned chunk.
nonisolated struct MeetingAnalysisChunkKey: Hashable, CustomStringConvertible {
    let trackID: MeetingAudioTrackID
    let chunkID: MeetingAudioChunkID

    var description: String {
        "\(self.trackID.uuidString)/\(self.chunkID.uuidString)"
    }
}

// MARK: - Spans, gaps and epochs

nonisolated enum MeetingAnalysisEpochResetReason: String, Codable, CaseIterable {
    case trackStart
    case missingOrUnreadableAudio
    case chunkDiscontinuity
    case microphoneDeviceChanged
    case inadmissibleCaptureEra
}

nonisolated struct MeetingAnalysisEpochRecord: Codable, Equatable, Identifiable {
    let id: MeetingAnalysisEpochID
    let resetReason: MeetingAnalysisEpochResetReason
    /// Spans in analysis order. An epoch with no spans is not representable: it would describe
    /// model state that never existed.
    let spanIDs: [String]
    let analysisInterval: MeetingAnalysisInterval
}

/// Why a piece of a planned chunk has no validated analysis span. Every reason is a fact the
/// builder established — a file it could not find, bytes that changed, a decoder that refused, or
/// audio the canonical admission rule rejects.
nonisolated enum MeetingAnalysisGapReason: String, Codable, CaseIterable {
    case chunkFileMissing
    /// The chunk path left the session directory, or a path component was a symlink.
    case chunkPathRejected
    case chunkByteCountChanged
    case chunkHashChanged
    case chunkUnreadable
    /// Zero stored bytes, or zero decoded frames.
    case chunkEmpty
    /// A decoder reported a non-positive sample rate, so no duration can be derived from it.
    case chunkSampleRateUnusable
    case chunkAnalysisAssetInvalid
    /// Defensive: a chunk that is not finalized is not planned work.
    case chunkNotFinalized
    /// The chunk's recorded presentation bounds are not a positive interval, so it maps nowhere.
    case chunkHasNoRecordedInterval
    /// The decoder returned less audio than the chunk's recorded interval claims, so this trailing
    /// piece has no samples behind it at all.
    case decodedAudioExhausted
    case inadmissibleCaptureEra

    var epochResetReason: MeetingAnalysisEpochResetReason {
        switch self {
        case .inadmissibleCaptureEra:
            return .inadmissibleCaptureEra
        case .chunkFileMissing,
             .chunkPathRejected,
             .chunkByteCountChanged,
             .chunkHashChanged,
             .chunkUnreadable,
             .chunkEmpty,
             .chunkSampleRateUnusable,
             .chunkAnalysisAssetInvalid,
             .chunkNotFinalized,
             .chunkHasNoRecordedInterval,
             .decodedAudioExhausted:
            return .missingOrUnreadableAudio
        }
    }

    /// Only an admission refusal carries admission provenance; everything else would be asserting a
    /// protection judgement it never made.
    var carriesAdmission: Bool {
        self == .inadmissibleCaptureEra
    }
}

nonisolated struct MeetingAnalysisGap: Codable, Equatable, Identifiable {
    let id: String
    let chunk: MeetingAnalysisChunkIdentity
    /// Position of this piece inside its chunk's cover, from 0.
    let pieceIndex: Int
    let reason: MeetingAnalysisGapReason
    /// This piece's slice of the chunk's recorded, origin-relative presentation interval. `nil`
    /// only when the chunk's own recorded bounds are not a positive interval — the validator
    /// re-checks that against the frozen request.
    let recordedInterval: MeetingAnalysisInterval?
    /// Present exactly for `inadmissibleCaptureEra`, carrying the era that excluded this piece.
    let captureEra: MeetingCaptureEraIdentity?
    /// Present exactly for `inadmissibleCaptureEra`, carrying the rule inputs that excluded it.
    let admission: MeetingSpanAdmission?
    let detail: String?

    var trackID: MeetingAudioTrackID {
        self.chunk.trackID
    }

    var chunkID: MeetingAudioChunkID {
        self.chunk.chunkID
    }

    /// Stable across rebuilds of the same attempt: derived from identity and piece position, not
    /// from iteration order.
    static func stableID(attemptID: UUID, chunk: MeetingAnalysisChunkIdentity, pieceIndex: Int) -> String {
        "gap:\(attemptID.uuidString):\(chunk.trackID.uuidString):\(chunk.chunkID.uuidString):\(pieceIndex)"
    }
}

/// One validated, admissible, actually-decoded piece of one planned chunk.
nonisolated struct MeetingAnalysisSpan: Codable, Equatable, Identifiable {
    let id: String
    let chunk: MeetingAnalysisChunkIdentity
    /// Position of this piece inside its chunk's cover, from 0.
    let pieceIndex: Int
    let trackKind: MeetingAudioTrackKind
    let analysisEpochID: MeetingAnalysisEpochID
    /// This piece's slice of the chunk's recorded, origin-relative presentation interval. Coverage
    /// accounting is done in this domain, so drift correction can never create or destroy coverage.
    let recordedInterval: MeetingAnalysisInterval
    /// Valid region inside the source file, in seconds from that file's own start.
    let sourceLocalInterval: MeetingAnalysisInterval
    /// Position in the track's gap-removed analysis stream.
    let analysisInterval: MeetingAnalysisInterval
    /// Position in meeting presentation time, origin-relative, after de-drift.
    let presentationInterval: MeetingAnalysisInterval
    let presentationMapping: MeetingAnalysisTimeTransform
    let captureEra: MeetingCaptureEraIdentity
    let admission: MeetingSpanAdmission
    /// Byte count, digest and decoded format as actually observed on disk.
    let observed: MeetingChunkObservedAudio
    let discontinuity: MeetingSpanDiscontinuityFacts
    let timing: MeetingSpanTimingMetadata

    var trackID: MeetingAudioTrackID {
        self.chunk.trackID
    }

    var chunkID: MeetingAudioChunkID {
        self.chunk.chunkID
    }

    var storedByteCount: Int64 {
        self.chunk.storedByteCount
    }

    var storedSHA256: String {
        self.chunk.storedSHA256
    }

    /// Stable across rebuilds of the same attempt: derived from identity and piece position, not
    /// from iteration order.
    static func stableID(attemptID: UUID, chunk: MeetingAnalysisChunkIdentity, pieceIndex: Int) -> String {
        "span:\(attemptID.uuidString):\(chunk.trackID.uuidString):\(chunk.chunkID.uuidString):\(pieceIndex)"
    }
}

/// One piece of a planned chunk's cover, in chunk order. Spans and gaps are stored separately so a
/// reader never has to filter, but coverage and epoch rules see a single ordered sequence.
nonisolated enum MeetingAnalysisPiece: Equatable {
    case span(MeetingAnalysisSpan)
    case gap(MeetingAnalysisGap)

    var chunk: MeetingAnalysisChunkIdentity {
        switch self {
        case let .span(span): return span.chunk
        case let .gap(gap): return gap.chunk
        }
    }

    var pieceIndex: Int {
        switch self {
        case let .span(span): return span.pieceIndex
        case let .gap(gap): return gap.pieceIndex
        }
    }

    var recordedInterval: MeetingAnalysisInterval? {
        switch self {
        case let .span(span): return span.recordedInterval
        case let .gap(gap): return gap.recordedInterval
        }
    }

    var id: String {
        switch self {
        case let .span(span): return span.id
        case let .gap(gap): return gap.id
        }
    }
}

nonisolated struct MeetingAnalysisTrackManifest: Codable, Equatable, Identifiable {
    let id: MeetingAudioTrackID
    let kind: MeetingAudioTrackKind
    /// Analysis order, which is also (chunk sequence, piece index) order.
    let spans: [MeetingAnalysisSpan]
    /// (chunk sequence, piece index) order.
    let gaps: [MeetingAnalysisGap]
    let epochs: [MeetingAnalysisEpochRecord]

    /// Explicit inadmissible coverage, as the plan requires it to be visible rather than implied
    /// by absence.
    var inadmissibleGaps: [MeetingAnalysisGap] {
        self.gaps.filter { $0.reason == .inadmissibleCaptureEra }
    }

    /// Every piece of every planned chunk in one ordered sequence.
    var orderedPieces: [MeetingAnalysisPiece] {
        let pieces = self.spans.map(MeetingAnalysisPiece.span) + self.gaps.map(MeetingAnalysisPiece.gap)
        return pieces.sorted { left, right in
            if left.chunk.sequence != right.chunk.sequence {
                return left.chunk.sequence < right.chunk.sequence
            }
            return left.pieceIndex < right.pieceIndex
        }
    }
}

// MARK: - Manifest

nonisolated struct MeetingAnalysisManifest: Equatable {
    let schemaVersion: Int
    let backendID: MeetingBackendID
    let backendVersion: String
    let attemptID: UUID
    let sessionID: MeetingSessionID
    let captureMode: MeetingCaptureMode
    /// The presentation origin every interval here is relative to, computed with the existing
    /// pipeline semantics (the minimum chunk presentation start across the session's tracks).
    let presentationOriginSeconds: Double
    /// Analysis sample rate the spans were mapped for. `nil` when this build does not know it;
    /// the composite backend supplies its real resampler rate in Stage E.
    let analysisSampleRate: Double?
    /// The single residual bound every span in this manifest was judged against.
    let residualBoundSeconds: Double
    /// One entry per planned track, including a planned track with no finalized chunks.
    let tracks: [MeetingAnalysisTrackManifest]

    init(
        backendID: MeetingBackendID,
        backendVersion: String,
        attemptID: UUID,
        sessionID: MeetingSessionID,
        captureMode: MeetingCaptureMode,
        presentationOriginSeconds: Double,
        analysisSampleRate: Double?,
        residualBoundSeconds: Double = MeetingAnalysisManifestSchema.defaultResidualBoundSeconds,
        tracks: [MeetingAnalysisTrackManifest]
    ) {
        self.schemaVersion = MeetingAnalysisManifestSchema.currentVersion
        self.backendID = backendID
        self.backendVersion = backendVersion
        self.attemptID = attemptID
        self.sessionID = sessionID
        self.captureMode = captureMode
        self.presentationOriginSeconds = presentationOriginSeconds
        self.analysisSampleRate = analysisSampleRate
        self.residualBoundSeconds = residualBoundSeconds
        self.tracks = tracks
    }

    func track(_ trackID: MeetingAudioTrackID) -> MeetingAnalysisTrackManifest? {
        self.tracks.first(where: { $0.id == trackID })
    }

    var allSpans: [MeetingAnalysisSpan] {
        self.tracks.flatMap(\.spans)
    }

    var allGaps: [MeetingAnalysisGap] {
        self.tracks.flatMap(\.gaps)
    }

    /// The presentation origin the existing pipeline would use for this session: the minimum
    /// recorded chunk start across every track. Not just planned chunks — the legacy path folds in
    /// provisional ones too, and disagreeing would shift every timestamp the product shows.
    static func presentationOrigin(of session: MeetingSession) -> Double {
        session.audioTracks
            .flatMap(\.chunks)
            .map(\.presentationStart.seconds)
            .min() ?? 0
    }
}

nonisolated extension MeetingAnalysisManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case backendID
        case backendVersion
        case attemptID
        case sessionID
        case captureMode
        case presentationOriginSeconds
        case analysisSampleRate
        case residualBoundSeconds
        case tracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == MeetingAnalysisManifestSchema.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported meeting analysis manifest schema version \(version)."
            )
        }
        try self.init(
            backendID: container.decode(MeetingBackendID.self, forKey: .backendID),
            backendVersion: container.decode(String.self, forKey: .backendVersion),
            attemptID: container.decode(UUID.self, forKey: .attemptID),
            sessionID: container.decode(MeetingSessionID.self, forKey: .sessionID),
            captureMode: container.decode(MeetingCaptureMode.self, forKey: .captureMode),
            presentationOriginSeconds: container.decode(Double.self, forKey: .presentationOriginSeconds),
            analysisSampleRate: container.decodeIfPresent(Double.self, forKey: .analysisSampleRate),
            residualBoundSeconds: container.decode(Double.self, forKey: .residualBoundSeconds),
            tracks: container.decode([MeetingAnalysisTrackManifest].self, forKey: .tracks)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.schemaVersion, forKey: .schemaVersion)
        try container.encode(self.backendID, forKey: .backendID)
        try container.encode(self.backendVersion, forKey: .backendVersion)
        try container.encode(self.attemptID, forKey: .attemptID)
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.captureMode, forKey: .captureMode)
        try container.encode(self.presentationOriginSeconds, forKey: .presentationOriginSeconds)
        try container.encodeIfPresent(self.analysisSampleRate, forKey: .analysisSampleRate)
        try container.encode(self.residualBoundSeconds, forKey: .residualBoundSeconds)
        try container.encode(self.tracks, forKey: .tracks)
    }
}

// MARK: - Errors

nonisolated enum MeetingAnalysisManifestError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case backendMismatch(expected: MeetingBackendID, actual: MeetingBackendID)
    case backendVersionMismatch(expected: String, actual: String)
    case attemptMismatch(expected: UUID, actual: UUID)
    case sessionMismatch(expected: MeetingSessionID, actual: MeetingSessionID)
    case captureModeMismatch(expected: MeetingCaptureMode, actual: MeetingCaptureMode)
    case presentationOriginMismatch(expected: Double, actual: Double)
    case invalidAnalysisSampleRate
    case invalidResidualBound
    case duplicateTrack(MeetingAudioTrackID)
    case trackOutOfScope(MeetingAudioTrackID)
    case trackKindMismatch(MeetingAudioTrackID)
    case missingPlannedTrack(MeetingAudioTrackID)
    case unstableSpanID(expected: String, actual: String)
    case duplicateSpanID(String)
    case unstableGapID(expected: String, actual: String)
    case duplicateGapID(String)
    case pieceOrderInvalid(trackID: MeetingAudioTrackID)
    case chunkOutOfScope(MeetingAnalysisChunkKey)
    case chunkIdentityDisagreesWithPlan(MeetingAnalysisChunkKey)
    case plannedChunkUncovered(MeetingAnalysisChunkKey)
    case chunkPieceIndicesInvalid(MeetingAnalysisChunkKey)
    case chunkPieceCoverageInvalid(MeetingAnalysisChunkKey)
    case spanTrackCrossing(spanID: String)
    case gapTrackCrossing(gapID: String)
    case invalidRecordedInterval(pieceID: String)
    case recordedIntervalCrossesCaptureEra(pieceID: String)
    case invalidSourceLocalInterval(spanID: String)
    case invalidAnalysisInterval(spanID: String)
    case invalidPresentationInterval(spanID: String)
    case observedIdentityDisagreesWithStored(spanID: String)
    case invalidDecodedFacts(spanID: String)
    case decodedDurationInconsistent(spanID: String)
    case primingFramesExceedDecodedFrames(spanID: String)
    case sourceLocalIntervalDisagreesWithRecordedPiece(spanID: String)
    case analysisDurationDisagreesWithSource(spanID: String)
    case analysisTimeNotGapRemoved(trackID: MeetingAudioTrackID)
    case invalidTransform(spanID: String)
    case transformDisagreesWithIntervals(spanID: String)
    case hostClockAnchorMismatch(spanID: String)
    case primingCompensationMismatch(spanID: String)
    case sampleRateConversionRatioMismatch(spanID: String)
    case analysisMustRemoveGaps(spanID: String)
    case captureEraDisagreesWithPlan(pieceID: String)
    case admissionRuleMismatch(spanID: String)
    case inadmissibleSpan(spanID: String)
    case discontinuityDisagreesWithPlan(spanID: String)
    case residualDisagreesWithObservation(spanID: String)
    case invalidTimingCertainty(spanID: String)
    case spanResidualBoundMismatch(spanID: String)
    case deDriftDisagreesWithPlan(spanID: String)
    case driftFactorDisagreesWithTransform(spanID: String)
    case presentationMappingDisagreesWithPlan(spanID: String)
    case gapReasonInconsistent(gapID: String)
    case gapAdmissionInconsistent(gapID: String)
    case spanEpochTrackCrossing(spanID: String)
    case invalidEpochOrdinal(spanID: String)
    case invalidEpochGeneration(MeetingAnalysisEpochID)
    case unknownSpanEpoch(spanID: String)
    case duplicateEpoch(MeetingAnalysisEpochID)
    case epochTrackCrossing(MeetingAnalysisEpochID)
    case nonContiguousEpochOrdinals(trackID: MeetingAudioTrackID)
    case emptyEpoch(MeetingAnalysisEpochID)
    case epochSpanMembershipMismatch(MeetingAnalysisEpochID)
    case epochIntervalMismatch(MeetingAnalysisEpochID)
    case invalidEpochResetReason(MeetingAnalysisEpochID)
    case unjustifiedEpochBoundary(spanID: String)
    case missingEpochBoundary(spanID: String)
    case nonMonotonicAnalysisTime(trackID: MeetingAudioTrackID)
    case nonMonotonicPresentationTime(trackID: MeetingAudioTrackID)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "Unsupported meeting analysis manifest schema version \(version)."
        case let .backendMismatch(expected, actual):
            return "Analysis manifest names backend \"\(actual)\" but the plan selected \"\(expected)\"."
        case let .backendVersionMismatch(expected, actual):
            return "Analysis manifest names backend version \"\(actual)\"; the plan froze \"\(expected)\"."
        case let .attemptMismatch(expected, actual):
            return "Analysis manifest carries attempt \(actual) but the plan is attempt \(expected)."
        case let .sessionMismatch(expected, actual):
            return "Analysis manifest carries session \(actual) but the plan is session \(expected)."
        case let .captureModeMismatch(expected, actual):
            return "Analysis manifest declares \(actual.rawValue) capture; the session is \(expected.rawValue)."
        case let .presentationOriginMismatch(expected, actual):
            return "Analysis manifest uses presentation origin \(actual); the frozen session's is \(expected)."
        case .invalidAnalysisSampleRate:
            return "Analysis manifest declares a non-finite or non-positive analysis sample rate."
        case .invalidResidualBound:
            return "Analysis manifest declares a non-finite or non-positive residual bound."
        case let .duplicateTrack(trackID):
            return "Analysis manifest lists track \(trackID) more than once."
        case let .trackOutOfScope(trackID):
            return "Analysis manifest covers track \(trackID), which was never planned."
        case let .trackKindMismatch(trackID):
            return "Analysis manifest declares the wrong kind for track \(trackID)."
        case let .missingPlannedTrack(trackID):
            return "Analysis manifest omits planned track \(trackID)."
        case let .unstableSpanID(expected, actual):
            return "Analysis span identifier \"\(actual)\" is not its stable identity \"\(expected)\"."
        case let .duplicateSpanID(id):
            return "Analysis span identifier \"\(id)\" appears more than once."
        case let .unstableGapID(expected, actual):
            return "Analysis gap identifier \"\(actual)\" is not its stable identity \"\(expected)\"."
        case let .duplicateGapID(id):
            return "Analysis gap identifier \"\(id)\" appears more than once."
        case let .pieceOrderInvalid(trackID):
            return "Track \(trackID) lists spans or gaps out of chunk-sequence order."
        case let .chunkOutOfScope(key):
            return "Analysis manifest references chunk \(key), which was not planned."
        case let .chunkIdentityDisagreesWithPlan(key):
            return "Analysis manifest states a sequence, path, byte count or digest for chunk "
                + "\(key) that the frozen request does not."
        case let .plannedChunkUncovered(key):
            return "Planned chunk \(key) has neither an analysis span nor a gap."
        case let .chunkPieceIndicesInvalid(key):
            return "Planned chunk \(key) has duplicate or non-contiguous piece indices."
        case let .chunkPieceCoverageInvalid(key):
            return "Planned chunk \(key)'s pieces do not exactly cover its recorded interval."
        case let .spanTrackCrossing(spanID):
            return "Analysis span \"\(spanID)\" is filed under a different track than it names."
        case let .gapTrackCrossing(gapID):
            return "Analysis gap \"\(gapID)\" is filed under a different track than it names."
        case let .invalidRecordedInterval(pieceID):
            return "Analysis piece \"\(pieceID)\" has a non-finite or non-positive recorded interval."
        case let .recordedIntervalCrossesCaptureEra(pieceID):
            return "Analysis piece \"\(pieceID)\" spans more than one capture era."
        case let .invalidSourceLocalInterval(spanID):
            return "Analysis span \"\(spanID)\" has a non-finite or non-positive source interval."
        case let .invalidAnalysisInterval(spanID):
            return "Analysis span \"\(spanID)\" has a non-finite or non-positive analysis interval."
        case let .invalidPresentationInterval(spanID):
            return "Analysis span \"\(spanID)\" has a non-finite or non-positive presentation interval."
        case let .observedIdentityDisagreesWithStored(spanID):
            return "Analysis span \"\(spanID)\" records observed bytes that differ from the stored manifest."
        case let .invalidDecodedFacts(spanID):
            return "Analysis span \"\(spanID)\" has non-positive decoded rate, channels, frames or duration."
        case let .decodedDurationInconsistent(spanID):
            return "Analysis span \"\(spanID)\" records a decoded duration that is not frames ÷ sample rate."
        case let .primingFramesExceedDecodedFrames(spanID):
            return "Analysis span \"\(spanID)\" reports more priming frames than decoded frames."
        case let .sourceLocalIntervalDisagreesWithRecordedPiece(spanID):
            return "Analysis span \"\(spanID)\" reads a source region its recorded piece does not map to."
        case let .analysisDurationDisagreesWithSource(spanID):
            return "Analysis span \"\(spanID)\" has an analysis duration unequal to its valid source duration."
        case let .analysisTimeNotGapRemoved(trackID):
            return "Track \(trackID)'s analysis stream is not the gap-removed concatenation of its spans."
        case let .invalidTransform(spanID):
            return "Analysis span \"\(spanID)\" has a non-finite or non-positive time transform."
        case let .transformDisagreesWithIntervals(spanID):
            return "Analysis span \"\(spanID)\" does not round-trip between analysis and presentation time."
        case let .hostClockAnchorMismatch(spanID):
            return "Analysis span \"\(spanID)\" records a host-clock anchor its track never had."
        case let .primingCompensationMismatch(spanID):
            return "Analysis span \"\(spanID)\" compensates priming that was not measured, or by the wrong amount."
        case let .sampleRateConversionRatioMismatch(spanID):
            return "Analysis span \"\(spanID)\" records a sample-rate conversion ratio its rates do not give."
        case let .analysisMustRemoveGaps(spanID):
            return "Analysis span \"\(spanID)\" declares an analysis stream that retains gaps."
        case let .captureEraDisagreesWithPlan(pieceID):
            return "Analysis piece \"\(pieceID)\" records a capture era the frozen session does not have."
        case let .admissionRuleMismatch(spanID):
            return "Analysis span \"\(spanID)\" records an admission decision the canonical rule did not make."
        case let .inadmissibleSpan(spanID):
            return "Analysis span \"\(spanID)\" is inadmissible; inadmissible audio must be a gap."
        case let .discontinuityDisagreesWithPlan(spanID):
            return "Analysis span \"\(spanID)\" records discontinuities its chunk does not."
        case let .residualDisagreesWithObservation(spanID):
            return "Analysis span \"\(spanID)\" records a fit residual its observed audio does not give."
        case let .invalidTimingCertainty(spanID):
            return "Analysis span \"\(spanID)\" declares a timing certainty its evidence does not support."
        case let .spanResidualBoundMismatch(spanID):
            return "Analysis span \"\(spanID)\" uses a residual bound other than the manifest's."
        case let .deDriftDisagreesWithPlan(spanID):
            return "Analysis span \"\(spanID)\" records a de-drift decision its capture era does not give."
        case let .driftFactorDisagreesWithTransform(spanID):
            return "Analysis span \"\(spanID)\" records a drift factor its transform does not use."
        case let .presentationMappingDisagreesWithPlan(spanID):
            return "Analysis span \"\(spanID)\" maps to a presentation interval its recorded piece does not."
        case let .gapReasonInconsistent(gapID):
            return "Analysis gap \"\(gapID)\" has a reason inconsistent with the interval it covers."
        case let .gapAdmissionInconsistent(gapID):
            return "Analysis gap \"\(gapID)\" has admission provenance inconsistent with its reason."
        case let .spanEpochTrackCrossing(spanID):
            return "Analysis span \"\(spanID)\" uses an analysis epoch from another track."
        case let .invalidEpochOrdinal(spanID):
            return "Analysis span \"\(spanID)\" uses a negative analysis epoch ordinal."
        case let .invalidEpochGeneration(epochID):
            return "Analysis epoch \(epochID) uses a negative evidence generation."
        case let .unknownSpanEpoch(spanID):
            return "Analysis span \"\(spanID)\" references an epoch the manifest does not record."
        case let .duplicateEpoch(epochID):
            return "Analysis epoch \(epochID) is recorded more than once."
        case let .epochTrackCrossing(epochID):
            return "Analysis epoch \(epochID) is filed under another track."
        case let .nonContiguousEpochOrdinals(trackID):
            return "Track \(trackID) has non-contiguous analysis epoch ordinals."
        case let .emptyEpoch(epochID):
            return "Analysis epoch \(epochID) contains no spans."
        case let .epochSpanMembershipMismatch(epochID):
            return "Analysis epoch \(epochID) lists spans other than the ones assigned to it."
        case let .epochIntervalMismatch(epochID):
            return "Analysis epoch \(epochID) declares an interval its spans do not cover."
        case let .invalidEpochResetReason(epochID):
            return "Analysis epoch \(epochID) declares a reset reason its position cannot have."
        case let .unjustifiedEpochBoundary(spanID):
            return "Analysis span \"\(spanID)\" starts a new epoch with no gap, discontinuity or device change before it."
        case let .missingEpochBoundary(spanID):
            return "Analysis span \"\(spanID)\" continues an epoch across a gap, discontinuity or device change."
        case let .nonMonotonicAnalysisTime(trackID):
            return "Track \(trackID) has overlapping or out-of-order analysis intervals."
        case let .nonMonotonicPresentationTime(trackID):
            return "Track \(trackID) has overlapping or out-of-order presentation intervals."
        }
    }
}

// MARK: - Plan projection

/// Everything the validator and the builder both need to read out of the frozen plan, derived once
/// and read-only. Both sides go through this so the manifest is checked against the *request*, not
/// against whatever the builder happened to remember.
nonisolated struct MeetingAnalysisPlanProjection {
    let origin: Double
    let tracksByID: [MeetingAudioTrackID: MeetingAudioTrack]
    let chunksByKey: [MeetingAnalysisChunkKey: MeetingAudioChunk]
    /// Planned chunks per track, in recorded sequence order.
    let plannedChunksByTrack: [MeetingAudioTrackID: [MeetingAudioChunk]]
    let eraIdentitiesByTrack: [MeetingAudioTrackID: [MeetingCaptureEraIdentity]]
    let eraStartsByTrack: [MeetingAudioTrackID: [Double]]

    init(plan: MeetingBackendPlan) {
        let session = plan.request.session
        let origin = MeetingAnalysisManifest.presentationOrigin(of: session)
        self.origin = origin

        var tracksByID: [MeetingAudioTrackID: MeetingAudioTrack] = [:]
        var chunksByKey: [MeetingAnalysisChunkKey: MeetingAudioChunk] = [:]
        var plannedChunksByTrack: [MeetingAudioTrackID: [MeetingAudioChunk]] = [:]
        var eraIdentitiesByTrack: [MeetingAudioTrackID: [MeetingCaptureEraIdentity]] = [:]
        var eraStartsByTrack: [MeetingAudioTrackID: [Double]] = [:]

        for track in session.audioTracks {
            tracksByID[track.id] = track
            guard let plannedIDs = plan.chunkIDsByTrackID[track.id] else { continue }
            let planned = track.chunks
                .filter { plannedIDs.contains($0.id) }
                .sorted { $0.sequence < $1.sequence }
            plannedChunksByTrack[track.id] = planned
            for chunk in planned {
                chunksByKey[MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id)] = chunk
            }
            eraIdentitiesByTrack[track.id] = MeetingAnalysisCaptureEras.identities(for: track, origin: origin)
            eraStartsByTrack[track.id] = MeetingAnalysisCaptureEras.normalizedStarts(for: track, origin: origin)
        }

        self.tracksByID = tracksByID
        self.chunksByKey = chunksByKey
        self.plannedChunksByTrack = plannedChunksByTrack
        self.eraIdentitiesByTrack = eraIdentitiesByTrack
        self.eraStartsByTrack = eraStartsByTrack
    }

    /// Origin-relative recorded presentation interval of a planned chunk. `nil` when the recorded
    /// bounds are not a positive interval — the only case where a piece may omit its interval.
    func recordedInterval(of chunk: MeetingAudioChunk) -> MeetingAnalysisInterval? {
        let interval = MeetingAnalysisInterval(
            start: chunk.presentationStart.seconds - self.origin,
            end: chunk.presentationEnd.seconds - self.origin
        )
        return interval.isValid ? interval : nil
    }

    func eraIdentity(forTrack trackID: MeetingAudioTrackID, containing seconds: Double) -> MeetingCaptureEraIdentity? {
        guard let starts = self.eraStartsByTrack[trackID],
              let identities = self.eraIdentitiesByTrack[trackID],
              !identities.isEmpty
        else { return nil }
        let index = MeetingAnalysisCaptureEras.index(containing: seconds, starts: starts)
        return identities.indices.contains(index) ? identities[index] : nil
    }

    func eraEndSeconds(forTrack trackID: MeetingAudioTrackID, index: Int) -> Double {
        guard let starts = self.eraStartsByTrack[trackID] else { return .infinity }
        return MeetingAnalysisCaptureEras.endSeconds(afterIndex: index, starts: starts)
    }

    func anchorSeconds(forTrack trackID: MeetingAudioTrackID, era: MeetingCaptureEraIdentity) -> Double {
        guard let track = self.tracksByID[trackID] else { return 0 }
        return MeetingAnalysisCaptureEras.anchorSeconds(for: era, track: track, origin: self.origin)
    }
}

// MARK: - Validation

nonisolated extension MeetingAnalysisManifest {
    /// Fail-closed structural validation against the frozen plan. Everything it proves is a
    /// property of the manifest measured against the request the host froze: identity and scope
    /// agreement, chunk identity, exactly-once piece coverage of every planned chunk's recorded
    /// interval, finite positive bounds, source/analysis/presentation round-trip, the capture eras
    /// the session actually recorded, copied discontinuities, measured residuals, the canonical
    /// admission rule, exactly one de-drift application, and epoch resets that something really
    /// caused.
    ///
    /// It cannot prove the audio was transcribed, that a decoder's priming report is correct, or
    /// that an admissible era really was acoustically safe. Those are not structural facts.
    @discardableResult
    func validated(against plan: MeetingBackendPlan) throws -> Self {
        let projection = MeetingAnalysisPlanProjection(plan: plan)
        try self.validateHeader(plan: plan, projection: projection)

        var seenTrackIDs = Set<MeetingAudioTrackID>()
        var seenSpanIDs = Set<String>()
        var seenGapIDs = Set<String>()

        for track in self.tracks {
            guard seenTrackIDs.insert(track.id).inserted else {
                throw MeetingAnalysisManifestError.duplicateTrack(track.id)
            }
            guard let plannedKind = plan.trackKindsByID[track.id] else {
                throw MeetingAnalysisManifestError.trackOutOfScope(track.id)
            }
            guard plannedKind == track.kind else {
                throw MeetingAnalysisManifestError.trackKindMismatch(track.id)
            }

            for span in track.spans {
                guard seenSpanIDs.insert(span.id).inserted else {
                    throw MeetingAnalysisManifestError.duplicateSpanID(span.id)
                }
                try self.validateSpan(span, track: track, projection: projection)
            }
            for gap in track.gaps {
                guard seenGapIDs.insert(gap.id).inserted else {
                    throw MeetingAnalysisManifestError.duplicateGapID(gap.id)
                }
                try self.validateGap(gap, track: track, projection: projection)
            }

            try self.validatePieceCoverage(of: track, projection: projection)
            try self.validateEpochRecords(of: track)
            try self.validateAnalysisTimeline(of: track)
            try self.validateEpochBoundaries(of: track)
        }

        for trackID in plan.trackKindsByID.keys where !seenTrackIDs.contains(trackID) {
            throw MeetingAnalysisManifestError.missingPlannedTrack(trackID)
        }
        return self
    }

    private func validateHeader(
        plan: MeetingBackendPlan,
        projection: MeetingAnalysisPlanProjection
    ) throws {
        guard self.schemaVersion == MeetingAnalysisManifestSchema.currentVersion else {
            throw MeetingAnalysisManifestError.unsupportedSchemaVersion(self.schemaVersion)
        }
        guard self.backendID == plan.backendID else {
            throw MeetingAnalysisManifestError.backendMismatch(
                expected: plan.backendID, actual: self.backendID
            )
        }
        guard self.backendVersion == plan.backendVersion else {
            throw MeetingAnalysisManifestError.backendVersionMismatch(
                expected: plan.backendVersion, actual: self.backendVersion
            )
        }
        guard self.attemptID == plan.attemptID else {
            throw MeetingAnalysisManifestError.attemptMismatch(
                expected: plan.attemptID, actual: self.attemptID
            )
        }
        guard self.sessionID == plan.request.session.id else {
            throw MeetingAnalysisManifestError.sessionMismatch(
                expected: plan.request.session.id, actual: self.sessionID
            )
        }
        guard self.captureMode == plan.request.session.mode else {
            throw MeetingAnalysisManifestError.captureModeMismatch(
                expected: plan.request.session.mode, actual: self.captureMode
            )
        }
        // The origin is not a free parameter: every interval here is relative to it, so a manifest
        // that picks its own would silently move every timestamp the product shows.
        guard self.presentationOriginSeconds.isFinite,
              self.presentationOriginSeconds == projection.origin
        else {
            throw MeetingAnalysisManifestError.presentationOriginMismatch(
                expected: projection.origin, actual: self.presentationOriginSeconds
            )
        }
        if let analysisSampleRate = self.analysisSampleRate {
            guard analysisSampleRate.isFinite, analysisSampleRate > 0 else {
                throw MeetingAnalysisManifestError.invalidAnalysisSampleRate
            }
        }
        guard self.residualBoundSeconds.isFinite, self.residualBoundSeconds > 0 else {
            throw MeetingAnalysisManifestError.invalidResidualBound
        }
    }

    // MARK: Spans

    private func validateSpan(
        _ span: MeetingAnalysisSpan,
        track: MeetingAnalysisTrackManifest,
        projection: MeetingAnalysisPlanProjection
    ) throws {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        guard span.chunk.trackID == track.id, span.trackKind == track.kind else {
            throw MeetingAnalysisManifestError.spanTrackCrossing(spanID: span.id)
        }
        let expectedID = MeetingAnalysisSpan.stableID(
            attemptID: self.attemptID, chunk: span.chunk, pieceIndex: span.pieceIndex
        )
        guard span.id == expectedID else {
            throw MeetingAnalysisManifestError.unstableSpanID(expected: expectedID, actual: span.id)
        }
        let (chunk, recordedChunkInterval) = try self.plannedChunk(for: span.chunk, projection: projection)
        guard let recordedChunkInterval else {
            // A chunk with no positive recorded interval can only be a gap.
            throw MeetingAnalysisManifestError.invalidRecordedInterval(pieceID: span.id)
        }
        guard span.recordedInterval.isValid,
              recordedChunkInterval.contains(span.recordedInterval)
        else {
            throw MeetingAnalysisManifestError.invalidRecordedInterval(pieceID: span.id)
        }
        guard span.sourceLocalInterval.isValid else {
            throw MeetingAnalysisManifestError.invalidSourceLocalInterval(spanID: span.id)
        }
        guard span.analysisInterval.isValid else {
            throw MeetingAnalysisManifestError.invalidAnalysisInterval(spanID: span.id)
        }
        guard span.presentationInterval.isValid else {
            throw MeetingAnalysisManifestError.invalidPresentationInterval(spanID: span.id)
        }

        // Observed identity must match the frozen request's stored identity exactly. The stored
        // digest is already bound to the plan by `plannedChunk(for:projection:)` above.
        guard span.observed.byteCount == span.chunk.storedByteCount,
              span.observed.sha256 == span.chunk.storedSHA256
        else {
            throw MeetingAnalysisManifestError.observedIdentityDisagreesWithStored(spanID: span.id)
        }

        let decoded = span.observed.decoded
        guard decoded.sampleRate.isFinite, decoded.sampleRate > 0,
              decoded.channelCount > 0,
              decoded.frameCount > 0,
              decoded.durationSeconds.isFinite, decoded.durationSeconds > 0
        else {
            throw MeetingAnalysisManifestError.invalidDecodedFacts(spanID: span.id)
        }
        guard abs(decoded.durationSeconds - Double(decoded.frameCount) / decoded.sampleRate) <= tolerance else {
            throw MeetingAnalysisManifestError.decodedDurationInconsistent(spanID: span.id)
        }
        if let primingFrames = decoded.codecPriming.measuredFrames {
            guard primingFrames >= 0, Int64(primingFrames) < decoded.frameCount else {
                throw MeetingAnalysisManifestError.primingFramesExceedDecodedFrames(spanID: span.id)
            }
        }

        let era = try self.validatedEra(
            of: span.captureEra,
            pieceID: span.id,
            recordedInterval: span.recordedInterval,
            track: track,
            projection: projection
        )
        let admission = MeetingSpanAdmission(
            captureMode: self.captureMode,
            trackKind: span.trackKind,
            echoProtection: era.echoProtection
        )
        guard span.admission == admission else {
            throw MeetingAnalysisManifestError.admissionRuleMismatch(spanID: span.id)
        }
        guard span.admission.decision == .admissible else {
            throw MeetingAnalysisManifestError.inadmissibleSpan(spanID: span.id)
        }

        try self.validateSourceMapping(span, chunkInterval: recordedChunkInterval)
        try self.validateTransform(span, era: era, track: track, projection: projection)
        try self.validateTiming(span, chunkInterval: recordedChunkInterval, era: era, projection: projection)

        let expectedDiscontinuity = MeetingSpanDiscontinuityFacts.make(
            chunk: chunk,
            previousChunk: self.previousPlannedChunk(before: chunk, track: track.id, projection: projection),
            origin: projection.origin
        )
        guard span.discontinuity == expectedDiscontinuity else {
            throw MeetingAnalysisManifestError.discontinuityDisagreesWithPlan(spanID: span.id)
        }

        guard span.analysisEpochID.trackID == track.id else {
            throw MeetingAnalysisManifestError.spanEpochTrackCrossing(spanID: span.id)
        }
        guard span.analysisEpochID.ordinal >= 0 else {
            throw MeetingAnalysisManifestError.invalidEpochOrdinal(spanID: span.id)
        }
        guard span.analysisEpochID.generation >= 0 else {
            throw MeetingAnalysisManifestError.invalidEpochGeneration(span.analysisEpochID)
        }
        guard track.epochs.contains(where: { $0.id == span.analysisEpochID }) else {
            throw MeetingAnalysisManifestError.unknownSpanEpoch(spanID: span.id)
        }
    }

    /// The valid source region is the recorded piece translated into file-local time, past any
    /// measured priming, truncated only where the decoder actually ran out of audio.
    private func validateSourceMapping(
        _ span: MeetingAnalysisSpan,
        chunkInterval: MeetingAnalysisInterval
    ) throws {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        let decoded = span.observed.decoded
        let priming = decoded.primingSeconds ?? 0
        let expectedStart = priming + (span.recordedInterval.start - chunkInterval.start)
        let expectedEnd = min(
            priming + (span.recordedInterval.end - chunkInterval.start),
            decoded.durationSeconds
        )
        guard abs(span.sourceLocalInterval.start - expectedStart) <= tolerance,
              abs(span.sourceLocalInterval.end - expectedEnd) <= tolerance
        else {
            throw MeetingAnalysisManifestError.sourceLocalIntervalDisagreesWithRecordedPiece(spanID: span.id)
        }
        // No fabricated samples: the valid source region must be inside audio a decoder reported.
        guard span.sourceLocalInterval.end <= decoded.durationSeconds + tolerance else {
            throw MeetingAnalysisManifestError.sourceLocalIntervalDisagreesWithRecordedPiece(spanID: span.id)
        }
        // Analysis time is the concatenation of valid source regions, so its duration is theirs.
        guard abs(span.analysisInterval.duration - span.sourceLocalInterval.duration) <= tolerance else {
            throw MeetingAnalysisManifestError.analysisDurationDisagreesWithSource(spanID: span.id)
        }
    }

    private func validateTransform(
        _ span: MeetingAnalysisSpan,
        era: MeetingCaptureEraIdentity,
        track: MeetingAnalysisTrackManifest,
        projection: MeetingAnalysisPlanProjection
    ) throws {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        let transform = span.presentationMapping
        guard transform.rateRatio.isFinite, transform.rateRatio > 0,
              transform.offsetSeconds.isFinite
        else {
            throw MeetingAnalysisManifestError.invalidTransform(spanID: span.id)
        }
        guard transform.analysisRemovesGaps else {
            throw MeetingAnalysisManifestError.analysisMustRemoveGaps(spanID: span.id)
        }
        guard let sessionTrack = projection.tracksByID[track.id],
              transform.hostClockAnchor == sessionTrack.timebase.startedHostTime
        else {
            throw MeetingAnalysisManifestError.hostClockAnchorMismatch(spanID: span.id)
        }

        let decoded = span.observed.decoded
        switch (self.analysisSampleRate, transform.sampleRateConversionRatio) {
        case let (.some(analysisRate), .some(ratio)):
            guard ratio.isFinite, ratio > 0,
                  abs(ratio - decoded.sampleRate / analysisRate) <= tolerance
            else {
                throw MeetingAnalysisManifestError.sampleRateConversionRatioMismatch(spanID: span.id)
            }
        case (.none, .none):
            break
        case (.some, .none), (.none, .some):
            // An unknown analysis rate has no ratio, and a known one always has exactly one.
            throw MeetingAnalysisManifestError.sampleRateConversionRatioMismatch(spanID: span.id)
        }

        switch (decoded.primingSeconds, transform.codecPrimingCompensationSeconds) {
        case let (.some(measured), .some(compensation)):
            guard compensation.isFinite, abs(compensation - measured) <= tolerance else {
                throw MeetingAnalysisManifestError.primingCompensationMismatch(spanID: span.id)
            }
        case (.none, .none):
            break
        case (.some, .none), (.none, .some):
            // Unknown priming is never a silent zero-second compensation, and measured priming is
            // never silently left uncompensated.
            throw MeetingAnalysisManifestError.primingCompensationMismatch(spanID: span.id)
        }

        // Affine round-trip: the declared transform must actually produce the declared interval.
        let mappedStart = transform.presentationTime(forAnalysisTime: span.analysisInterval.start)
        let mappedEnd = transform.presentationTime(forAnalysisTime: span.analysisInterval.end)
        let affineTolerance = max(
            tolerance,
            tolerance * max(abs(span.analysisInterval.end), 1) * max(transform.rateRatio, 1)
        )
        guard abs(mappedStart - span.presentationInterval.start) <= affineTolerance,
              abs(mappedEnd - span.presentationInterval.end) <= affineTolerance
        else {
            throw MeetingAnalysisManifestError.transformDisagreesWithIntervals(spanID: span.id)
        }

        // And the presentation interval must be where this era's de-drift actually puts the
        // recorded piece — not somewhere a self-consistent but invented transform reaches.
        let anchor = projection.anchorSeconds(forTrack: track.id, era: era)
        let expectedStart = anchor + (span.recordedInterval.start - anchor) * transform.rateRatio
        let expectedEnd = expectedStart + span.analysisInterval.duration * transform.rateRatio
        let slack = max(affineTolerance, tolerance * max(abs(anchor), 1) * max(transform.rateRatio, 1))
        guard abs(span.presentationInterval.start - expectedStart) <= slack,
              abs(span.presentationInterval.end - expectedEnd) <= slack
        else {
            throw MeetingAnalysisManifestError.presentationMappingDisagreesWithPlan(spanID: span.id)
        }
    }

    private func validateTiming(
        _ span: MeetingAnalysisSpan,
        chunkInterval: MeetingAnalysisInterval,
        era: MeetingCaptureEraIdentity,
        projection: MeetingAnalysisPlanProjection
    ) throws {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        guard span.timing.residualBoundSeconds == self.residualBoundSeconds else {
            throw MeetingAnalysisManifestError.spanResidualBoundMismatch(spanID: span.id)
        }

        // Exactly one owner of the de-drift correction: the decision must be the one this era's
        // own recorded drift fit produces, and the transform must use exactly that rate.
        let anchor = projection.anchorSeconds(forTrack: span.chunk.trackID, era: era)
        let expectedDeDrift = MeetingAnalysisCaptureEras.deDrift(for: era, anchorSeconds: anchor)
        guard span.timing.deDrift == expectedDeDrift else {
            throw MeetingAnalysisManifestError.deDriftDisagreesWithPlan(spanID: span.id)
        }
        let expectedRate = expectedDeDrift.appliedFactor ?? 1
        guard abs(span.presentationMapping.rateRatio - expectedRate) <= tolerance else {
            throw MeetingAnalysisManifestError.driftFactorDisagreesWithTransform(spanID: span.id)
        }

        // The residual is a measurement, not a declaration: mapped decoded length minus the
        // chunk's recorded presentation duration.
        let decoded = span.observed.decoded
        let expectedResidual = decoded.usableDurationSeconds * expectedRate - chunkInterval.duration
        guard let residual = span.timing.fitResidualSeconds,
              residual.isFinite,
              abs(residual - expectedResidual) <= tolerance
        else {
            throw MeetingAnalysisManifestError.residualDisagreesWithObservation(spanID: span.id)
        }
        let expectedCertainty = MeetingSpanTimingMetadata.certainty(
            fitResidualSeconds: residual,
            residualBoundSeconds: span.timing.residualBoundSeconds,
            codecPriming: decoded.codecPriming
        )
        guard span.timing.certainty == expectedCertainty else {
            throw MeetingAnalysisManifestError.invalidTimingCertainty(spanID: span.id)
        }
    }

    // MARK: Gaps

    private func validateGap(
        _ gap: MeetingAnalysisGap,
        track: MeetingAnalysisTrackManifest,
        projection: MeetingAnalysisPlanProjection
    ) throws {
        guard gap.chunk.trackID == track.id else {
            throw MeetingAnalysisManifestError.gapTrackCrossing(gapID: gap.id)
        }
        let expectedID = MeetingAnalysisGap.stableID(
            attemptID: self.attemptID, chunk: gap.chunk, pieceIndex: gap.pieceIndex
        )
        guard gap.id == expectedID else {
            throw MeetingAnalysisManifestError.unstableGapID(expected: expectedID, actual: gap.id)
        }
        let (_, recordedChunkInterval) = try self.plannedChunk(for: gap.chunk, projection: projection)

        switch (gap.recordedInterval, recordedChunkInterval) {
        case let (.some(interval), .some(chunkInterval)):
            guard interval.isValid, chunkInterval.contains(interval) else {
                throw MeetingAnalysisManifestError.invalidRecordedInterval(pieceID: gap.id)
            }
            guard gap.reason != .chunkHasNoRecordedInterval else {
                throw MeetingAnalysisManifestError.gapReasonInconsistent(gapID: gap.id)
            }
        case (.some, .none):
            throw MeetingAnalysisManifestError.invalidRecordedInterval(pieceID: gap.id)
        case (.none, .some):
            // A positive recorded interval may never be hidden behind a missing piece interval.
            throw MeetingAnalysisManifestError.invalidRecordedInterval(pieceID: gap.id)
        case (.none, .none):
            guard gap.reason == .chunkHasNoRecordedInterval else {
                throw MeetingAnalysisManifestError.gapReasonInconsistent(gapID: gap.id)
            }
        }

        if gap.reason.carriesAdmission {
            guard let interval = gap.recordedInterval,
                  let eraIdentity = gap.captureEra
            else {
                throw MeetingAnalysisManifestError.gapAdmissionInconsistent(gapID: gap.id)
            }
            let era = try self.validatedEra(
                of: eraIdentity,
                pieceID: gap.id,
                recordedInterval: interval,
                track: track,
                projection: projection
            )
            let expected = MeetingSpanAdmission(
                captureMode: self.captureMode,
                trackKind: track.kind,
                echoProtection: era.echoProtection
            )
            guard gap.admission == expected, expected.decision == .inadmissible else {
                throw MeetingAnalysisManifestError.gapAdmissionInconsistent(gapID: gap.id)
            }
        } else {
            guard gap.admission == nil, gap.captureEra == nil else {
                throw MeetingAnalysisManifestError.gapAdmissionInconsistent(gapID: gap.id)
            }
        }
    }

    // MARK: Shared piece checks

    private func plannedChunk(
        for identity: MeetingAnalysisChunkIdentity,
        projection: MeetingAnalysisPlanProjection
    ) throws -> (MeetingAudioChunk, MeetingAnalysisInterval?) {
        guard let chunk = projection.chunksByKey[identity.key] else {
            throw MeetingAnalysisManifestError.chunkOutOfScope(identity.key)
        }
        guard identity == MeetingAnalysisChunkIdentity(trackID: identity.trackID, chunk: chunk) else {
            throw MeetingAnalysisManifestError.chunkIdentityDisagreesWithPlan(identity.key)
        }
        return (chunk, projection.recordedInterval(of: chunk))
    }

    /// A piece's era must be the era the frozen session recorded for that interval, and the piece
    /// must lie wholly inside it — that is what makes splitting at era boundaries load-bearing.
    private func validatedEra(
        of identity: MeetingCaptureEraIdentity,
        pieceID: String,
        recordedInterval: MeetingAnalysisInterval,
        track: MeetingAnalysisTrackManifest,
        projection: MeetingAnalysisPlanProjection
    ) throws -> MeetingCaptureEraIdentity {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        guard let expected = projection.eraIdentity(
            forTrack: track.id, containing: recordedInterval.start
        ), expected == identity else {
            throw MeetingAnalysisManifestError.captureEraDisagreesWithPlan(pieceID: pieceID)
        }
        let eraEnd = projection.eraEndSeconds(forTrack: track.id, index: identity.index)
        guard recordedInterval.end <= eraEnd + tolerance else {
            throw MeetingAnalysisManifestError.recordedIntervalCrossesCaptureEra(pieceID: pieceID)
        }
        return expected
    }

    private func previousPlannedChunk(
        before chunk: MeetingAudioChunk,
        track trackID: MeetingAudioTrackID,
        projection: MeetingAnalysisPlanProjection
    ) -> MeetingAudioChunk? {
        guard let planned = projection.plannedChunksByTrack[trackID],
              let index = planned.firstIndex(where: { $0.id == chunk.id }),
              index > 0
        else { return nil }
        return planned[index - 1]
    }

    // MARK: Coverage

    /// Exactly-once coverage, in both directions: every planned chunk is covered by pieces that
    /// tile its recorded interval with no hole and no overlap, and nothing outside the plan is
    /// covered at all.
    private func validatePieceCoverage(
        of track: MeetingAnalysisTrackManifest,
        projection: MeetingAnalysisPlanProjection
    ) throws {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        let ordered = track.orderedPieces
        guard track.spans.map(\.id) == ordered.compactMap({ piece -> String? in
            if case .span = piece { return piece.id }
            return nil
        }), track.gaps.map(\.id) == ordered.compactMap({ piece -> String? in
            if case .gap = piece { return piece.id }
            return nil
        }) else {
            throw MeetingAnalysisManifestError.pieceOrderInvalid(trackID: track.id)
        }

        var piecesByChunk: [MeetingAnalysisChunkKey: [MeetingAnalysisPiece]] = [:]
        for piece in ordered {
            piecesByChunk[piece.chunk.key, default: []].append(piece)
        }

        let planned = projection.plannedChunksByTrack[track.id] ?? []
        for (key, pieces) in piecesByChunk {
            guard planned.contains(where: { $0.id == key.chunkID }), key.trackID == track.id else {
                throw MeetingAnalysisManifestError.chunkOutOfScope(key)
            }
            guard pieces.map(\.pieceIndex) == Array(0..<pieces.count) else {
                throw MeetingAnalysisManifestError.chunkPieceIndicesInvalid(key)
            }
        }

        for chunk in planned {
            let key = MeetingAnalysisChunkKey(trackID: track.id, chunkID: chunk.id)
            guard let pieces = piecesByChunk[key], !pieces.isEmpty else {
                throw MeetingAnalysisManifestError.plannedChunkUncovered(key)
            }
            guard let recorded = projection.recordedInterval(of: chunk) else {
                // No positive interval to tile: one gap accounts for the whole chunk, and it is the
                // only shape in which a piece may omit its interval.
                guard pieces.count == 1, pieces[0].recordedInterval == nil else {
                    throw MeetingAnalysisManifestError.chunkPieceCoverageInvalid(key)
                }
                continue
            }
            var cursor = recorded.start
            for piece in pieces {
                guard let interval = piece.recordedInterval,
                      abs(interval.start - cursor) <= tolerance,
                      interval.end > interval.start
                else {
                    throw MeetingAnalysisManifestError.chunkPieceCoverageInvalid(key)
                }
                cursor = interval.end
            }
            guard abs(cursor - recorded.end) <= tolerance else {
                throw MeetingAnalysisManifestError.chunkPieceCoverageInvalid(key)
            }
        }
    }

    // MARK: Epochs

    private func validateEpochRecords(of track: MeetingAnalysisTrackManifest) throws {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        var seenEpochIDs = Set<MeetingAnalysisEpochID>()
        for epoch in track.epochs {
            guard seenEpochIDs.insert(epoch.id).inserted else {
                throw MeetingAnalysisManifestError.duplicateEpoch(epoch.id)
            }
            guard epoch.id.trackID == track.id else {
                throw MeetingAnalysisManifestError.epochTrackCrossing(epoch.id)
            }
            guard epoch.id.generation >= 0 else {
                throw MeetingAnalysisManifestError.invalidEpochGeneration(epoch.id)
            }
            let members = track.spans.filter { $0.analysisEpochID == epoch.id }
            guard !members.isEmpty, !epoch.spanIDs.isEmpty else {
                throw MeetingAnalysisManifestError.emptyEpoch(epoch.id)
            }
            guard members.map(\.id) == epoch.spanIDs else {
                throw MeetingAnalysisManifestError.epochSpanMembershipMismatch(epoch.id)
            }
            guard let first = members.map(\.analysisInterval.start).min(),
                  let last = members.map(\.analysisInterval.end).max(),
                  abs(epoch.analysisInterval.start - first) <= tolerance,
                  abs(epoch.analysisInterval.end - last) <= tolerance,
                  epoch.analysisInterval.isValid
            else {
                throw MeetingAnalysisManifestError.epochIntervalMismatch(epoch.id)
            }
            // Only the first epoch may be a plain track start; every later one states what broke.
            if epoch.id.ordinal > 0, epoch.resetReason == .trackStart {
                throw MeetingAnalysisManifestError.invalidEpochResetReason(epoch.id)
            }
            if epoch.id.ordinal == 0, epoch.resetReason != .trackStart {
                throw MeetingAnalysisManifestError.invalidEpochResetReason(epoch.id)
            }
        }
        let ordinals = track.epochs.map(\.id.ordinal)
        guard ordinals == Array(0..<ordinals.count) else {
            throw MeetingAnalysisManifestError.nonContiguousEpochOrdinals(trackID: track.id)
        }
    }

    /// An epoch boundary is a claim that model state could not be carried across it. This walks the
    /// track's pieces and proves the claim both ways: every boundary has a cause, and every cause
    /// produced a boundary.
    private func validateEpochBoundaries(of track: MeetingAnalysisTrackManifest) throws {
        let reasonsByEpoch = Dictionary(
            track.epochs.map { ($0.id, $0.resetReason) },
            uniquingKeysWith: { first, _ in first }
        )
        var previousSpan: MeetingAnalysisSpan?
        var pendingGapReasons: Set<MeetingAnalysisEpochResetReason> = []

        for piece in track.orderedPieces {
            switch piece {
            case let .gap(gap):
                pendingGapReasons.insert(gap.reason.epochResetReason)
            case let .span(span):
                guard let resetReason = reasonsByEpoch[span.analysisEpochID] else {
                    throw MeetingAnalysisManifestError.unknownSpanEpoch(spanID: span.id)
                }
                defer {
                    pendingGapReasons.removeAll()
                    previousSpan = span
                }
                guard let previous = previousSpan else {
                    // The first analysable audio on a track always opens epoch 0.
                    guard span.analysisEpochID.ordinal == 0, resetReason == .trackStart else {
                        throw MeetingAnalysisManifestError.invalidEpochResetReason(span.analysisEpochID)
                    }
                    continue
                }
                let causes = Self.epochResetCauses(
                    previousSpan: previous,
                    span: span,
                    pendingGapReasons: pendingGapReasons
                )
                if span.analysisEpochID == previous.analysisEpochID {
                    guard causes.isEmpty else {
                        throw MeetingAnalysisManifestError.missingEpochBoundary(spanID: span.id)
                    }
                } else {
                    guard span.analysisEpochID.ordinal == previous.analysisEpochID.ordinal + 1 else {
                        throw MeetingAnalysisManifestError.invalidEpochOrdinal(spanID: span.id)
                    }
                    guard !causes.isEmpty else {
                        throw MeetingAnalysisManifestError.unjustifiedEpochBoundary(spanID: span.id)
                    }
                    guard causes.contains(resetReason) else {
                        throw MeetingAnalysisManifestError.invalidEpochResetReason(span.analysisEpochID)
                    }
                }
            }
        }
    }

    /// Everything that could legitimately break the analysis epoch immediately before `span`.
    /// Empty means the audio ran on continuously and admissibly, so the epoch must continue.
    static func epochResetCauses(
        previousSpan: MeetingAnalysisSpan,
        span: MeetingAnalysisSpan,
        pendingGapReasons: Set<MeetingAnalysisEpochResetReason>
    ) -> Set<MeetingAnalysisEpochResetReason> {
        self.epochResetCauses(
            previousEra: previousSpan.captureEra,
            era: span.captureEra,
            pieceIndex: span.pieceIndex,
            recordedStart: span.recordedInterval.start,
            discontinuity: span.discontinuity,
            pendingGapReasons: pendingGapReasons
        )
    }

    /// The rule itself, in terms the builder can evaluate before it has an epoch to assign.
    /// Metadata-only era changes — display name, elected role, settled configuration, drift record —
    /// deliberately do not appear here: implementation plan §3 keeps the epoch running when the
    /// input itself is unchanged and admissible.
    static func epochResetCauses(
        previousEra: MeetingCaptureEraIdentity,
        era: MeetingCaptureEraIdentity,
        pieceIndex: Int,
        recordedStart: TimeInterval,
        discontinuity: MeetingSpanDiscontinuityFacts,
        pendingGapReasons: Set<MeetingAnalysisEpochResetReason>
    ) -> Set<MeetingAnalysisEpochResetReason> {
        var causes = pendingGapReasons
        if !previousEra.isSameInput(as: era) {
            causes.insert(.microphoneDeviceChanged)
        }
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        let hasTimedBoundaryHere = discontinuity.boundaries.contains {
            $0.presentationSeconds.map { abs($0 - recordedStart) <= tolerance } ?? false
        }
        let hasUnpositionedBoundaryAtChunkStart = pieceIndex == 0
            && discontinuity.boundaries.contains(where: { $0.presentationSeconds == nil })
        if hasTimedBoundaryHere
            || hasUnpositionedBoundaryAtChunkStart
            || (pieceIndex == 0 && discontinuity.precededByChunkTimeGap)
        {
            causes.insert(.chunkDiscontinuity)
        }
        return causes
    }

    /// Deterministic choice among equally valid causes, so a rebuild of the same attempt produces
    /// the same reset reason. Safety-relevant causes are named ahead of mechanical ones.
    static func preferredEpochResetReason(
        among causes: Set<MeetingAnalysisEpochResetReason>
    ) -> MeetingAnalysisEpochResetReason? {
        [
            .inadmissibleCaptureEra,
            .missingOrUnreadableAudio,
            .microphoneDeviceChanged,
            .chunkDiscontinuity,
        ].first(where: causes.contains)
    }

    // MARK: Timeline

    /// Analysis time is per track: it starts at zero, concatenates its spans with no gaps at all,
    /// and never runs backwards.
    ///
    /// Presentation time keeps the gaps and must stay ordered *within one capture era*. Across an
    /// era boundary the de-drift correction re-anchors, and the existing per-era correction can
    /// legitimately place the end of one era after the recorded start of the next — that is a
    /// property of the recording, not of this manifest, so it is not laundered into an ordering
    /// claim the audio does not support.
    private func validateAnalysisTimeline(of track: MeetingAnalysisTrackManifest) throws {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        var expectedAnalysisStart: TimeInterval = 0
        var previous: MeetingAnalysisSpan?
        for span in track.spans {
            guard abs(span.analysisInterval.start - expectedAnalysisStart) <= tolerance else {
                throw MeetingAnalysisManifestError.analysisTimeNotGapRemoved(trackID: track.id)
            }
            if let previous {
                if previous.captureEra.index == span.captureEra.index,
                   span.presentationInterval.start < previous.presentationInterval.end - tolerance
                {
                    throw MeetingAnalysisManifestError.nonMonotonicPresentationTime(trackID: track.id)
                }
                if span.analysisEpochID.ordinal < previous.analysisEpochID.ordinal {
                    throw MeetingAnalysisManifestError.nonMonotonicAnalysisTime(trackID: track.id)
                }
                if span.recordedInterval.start < previous.recordedInterval.end - tolerance {
                    throw MeetingAnalysisManifestError.nonMonotonicPresentationTime(trackID: track.id)
                }
            }
            expectedAnalysisStart = span.analysisInterval.end
            previous = span
        }
    }
}
