import Foundation

// Canonical final-output contract from `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` §2: timed
// text units (word *or* utterance), each with a stable source ID, exact analysis-span references,
// precision, an anonymous speaker assignment or an explicit ambiguity, and provenance.
//
// Stage C2b1: a unit's bounds are per-track *analysis* time — the gap-removed stream the manifest
// defines — and its provenance is the exact list of manifest analysis spans its audio came from.
// The assembler maps those bounds to presentation time through the referenced spans, exactly once;
// no presentation timestamps exist here to disagree with that mapping.
//
// Validation is split in two on purpose. `validated(against:)` / `validatedForAssembly` prove
// *scope*: every reference names something the frozen plan and manifest actually contain, so a
// violation is a hard error. Timing and provenance *values* are instead classified by
// `quarantineReason(in:)`: a unit with impossible bounds or unverifiable span coverage is not
// thrown away by preflight but quarantined, so the assembler can record exactly one sidecar
// disposition for every input unit (plan §4).
//
// Nothing here creates product speaker IDs, applies echo or admission policy, or writes anything
// durable — that is the assembler's job. Nothing here invents a timestamp or a confidence value
// either: a backend that returns only utterances stays an utterance backend, and absent confidence
// stays `nil`.

/// Version of the encoded canonical-evidence representation. Decoding is fail-closed: an
/// unknown or absent version is an error, never a guess. Version 2 moves text units from
/// session-relative seconds plus chunk references to analysis-time bounds plus exact span IDs;
/// version-1 payloads are rejected, not reinterpreted.
nonisolated enum MeetingBackendEvidenceSchema {
    static let currentVersion = 2
}

nonisolated enum MeetingEvidenceInterval {
    static func isValid(start: TimeInterval, end: TimeInterval) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start
    }
}

nonisolated enum MeetingTextUnitPrecision: String, Codable {
    case word
    case utterance
}

/// Analysis epoch, scoped to its track. A new epoch starts for missing audio, a real clock
/// discontinuity, a microphone device replacement or an inadmissible microphone interval, so
/// timing is never mapped across one. Speaker identity crosses an epoch only through an explicit
/// link. Encoding the track here is what makes the token-scoping check below meaningful.
nonisolated struct MeetingAnalysisEpochID: Hashable, Codable, CustomStringConvertible {
    let trackID: MeetingAudioTrackID
    let ordinal: Int
    /// Changes when this epoch's model evidence is replayed under the same attempt. Product
    /// speaker IDs include it, so recomputed slot labels can never inherit an earlier alias merely
    /// because the track and ordinal stayed the same.
    let generation: Int

    init(trackID: MeetingAudioTrackID, ordinal: Int, generation: Int = 0) {
        self.trackID = trackID
        self.ordinal = ordinal
        self.generation = generation
    }

    var description: String {
        "\(self.trackID.uuidString)#\(self.ordinal)@\(self.generation)"
    }
}

nonisolated struct MeetingAnalysisEpochGenerationKey: Hashable {
    let trackID: MeetingAudioTrackID
    let ordinal: Int
}

/// Anonymous, backend-local speaker slot. Never a `SessionSpeakerID`: only the assembler creates
/// product speaker IDs, and never by slot equality across tracks or epochs.
nonisolated struct MeetingBackendSpeakerToken: Hashable, Codable {
    let analysisEpochID: MeetingAnalysisEpochID
    let label: String
}

nonisolated enum MeetingBackendSpeakerAssignment: Equatable {
    case assigned(MeetingBackendSpeakerToken)
    /// Two or more candidate slots the backend could not separate. Ambiguity is reported, never
    /// resolved by picking one.
    case ambiguous([MeetingBackendSpeakerToken])
    /// The backend produced text but no speaker evidence at all.
    case unassigned

    var tokens: [MeetingBackendSpeakerToken] {
        switch self {
        case let .assigned(token): return [token]
        case let .ambiguous(tokens): return tokens
        case .unassigned: return []
        }
    }
}

nonisolated extension MeetingBackendSpeakerAssignment: Codable {
    /// Stable keyed encoding; the raw-value `Kind` decode already throws on an unknown case,
    /// so a payload can never decode into a speaker assignment the backend never made.
    private enum CodingKeys: String, CodingKey {
        case kind
        case token
        case candidates
    }

    private enum Kind: String, Codable {
        case assigned
        case ambiguous
        case unassigned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .assigned:
            guard container.contains(.token), !container.contains(.candidates) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "An assigned speaker requires exactly one token payload."
                )
            }
            self = try .assigned(container.decode(MeetingBackendSpeakerToken.self, forKey: .token))
        case .ambiguous:
            guard container.contains(.candidates), !container.contains(.token) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "An ambiguous speaker requires only a candidates payload."
                )
            }
            self = try .ambiguous(container.decode([MeetingBackendSpeakerToken].self, forKey: .candidates))
        case .unassigned:
            guard !container.contains(.token), !container.contains(.candidates) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "An unassigned speaker cannot carry token payloads."
                )
            }
            self = .unassigned
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .assigned(token):
            try container.encode(Kind.assigned, forKey: .kind)
            try container.encode(token, forKey: .token)
        case let .ambiguous(tokens):
            try container.encode(Kind.ambiguous, forKey: .kind)
            try container.encode(tokens, forKey: .candidates)
        case .unassigned:
            try container.encode(Kind.unassigned, forKey: .kind)
        }
    }
}

/// One final timed text unit. `analysisStart`/`analysisEnd` are seconds in the unit's track's
/// gap-removed analysis stream — the domain `MeetingAnalysisSpan.analysisInterval` defines — and
/// `analysisSpanIDs` is the exact, contiguous set of manifest spans the unit's audio came from.
nonisolated struct MeetingFinalTextUnit: Equatable, Identifiable {
    /// Stable within an attempt and, for resumed ASR chunks, across retries of that attempt.
    let id: String
    let trackID: MeetingAudioTrackID
    let analysisEpochID: MeetingAnalysisEpochID
    let precision: MeetingTextUnitPrecision
    let text: String
    let analysisStart: TimeInterval
    let analysisEnd: TimeInterval
    let speaker: MeetingBackendSpeakerAssignment
    /// Exact manifest analysis spans backing this unit. Contiguous within the unit's epoch, never
    /// bridging a missing or inadmissible span; validation proves the references exist, and the
    /// quarantine classification proves their union really covers the unit's bounds.
    let analysisSpanIDs: [String]
    /// Whatever the backend actually reported. `nil` when it reports none — never substituted.
    let confidence: Double?

    init(
        id: String,
        trackID: MeetingAudioTrackID,
        analysisEpochID: MeetingAnalysisEpochID,
        precision: MeetingTextUnitPrecision,
        text: String,
        analysisStart: TimeInterval,
        analysisEnd: TimeInterval,
        speaker: MeetingBackendSpeakerAssignment,
        analysisSpanIDs: [String],
        confidence: Double? = nil
    ) {
        self.id = id
        self.trackID = trackID
        self.analysisEpochID = analysisEpochID
        self.precision = precision
        self.text = text
        self.analysisStart = analysisStart
        self.analysisEnd = analysisEnd
        self.speaker = speaker
        self.analysisSpanIDs = analysisSpanIDs
        self.confidence = confidence
    }
}

/// Optional supporting evidence, in the same per-track analysis-time domain as the text units.
/// Its absence is not a defect, and its presence does not by itself assign any text.
nonisolated struct MeetingBackendSpeakerActivity: Equatable {
    let token: MeetingBackendSpeakerToken
    let start: TimeInterval
    let end: TimeInterval
}

nonisolated struct MeetingFinalTranscriptEvidence: Equatable {
    let backendID: MeetingBackendID
    let attemptID: UUID
    let units: [MeetingFinalTextUnit]
    let speakerActivity: [MeetingBackendSpeakerActivity]
    let voiceProfiles: [MeetingSpeakerVoiceProfile]
    /// The diarizer kept one state per track across epoch resets, so an equal slot label in two
    /// epochs of the same track is the same voice.
    let speakerSlotsContinueAcrossEpochs: Bool

    init(
        backendID: MeetingBackendID,
        attemptID: UUID,
        units: [MeetingFinalTextUnit],
        speakerActivity: [MeetingBackendSpeakerActivity] = [],
        voiceProfiles: [MeetingSpeakerVoiceProfile] = [],
        speakerSlotsContinueAcrossEpochs: Bool = false
    ) {
        self.backendID = backendID
        self.attemptID = attemptID
        self.units = units
        self.speakerActivity = speakerActivity
        self.voiceProfiles = voiceProfiles
        self.speakerSlotsContinueAcrossEpochs = speakerSlotsContinueAcrossEpochs
    }
}

nonisolated extension MeetingFinalTextUnit: Codable {}
nonisolated extension MeetingBackendSpeakerActivity: Codable {}

nonisolated extension MeetingFinalTranscriptEvidence: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case backendID
        case attemptID
        case units
        case speakerActivity
        case voiceProfiles
        case speakerSlotsContinueAcrossEpochs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == MeetingBackendEvidenceSchema.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported meeting evidence schema version \(version)."
            )
        }
        try self.init(
            backendID: container.decode(MeetingBackendID.self, forKey: .backendID),
            attemptID: container.decode(UUID.self, forKey: .attemptID),
            units: container.decode([MeetingFinalTextUnit].self, forKey: .units),
            speakerActivity: container.decode([MeetingBackendSpeakerActivity].self, forKey: .speakerActivity),
            voiceProfiles: container.decodeIfPresent([MeetingSpeakerVoiceProfile].self, forKey: .voiceProfiles) ?? [],
            speakerSlotsContinueAcrossEpochs: container.decodeIfPresent(
                Bool.self, forKey: .speakerSlotsContinueAcrossEpochs
            ) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(MeetingBackendEvidenceSchema.currentVersion, forKey: .schemaVersion)
        try container.encode(self.backendID, forKey: .backendID)
        try container.encode(self.attemptID, forKey: .attemptID)
        try container.encode(self.units, forKey: .units)
        try container.encode(self.speakerActivity, forKey: .speakerActivity)
        if !self.voiceProfiles.isEmpty { try container.encode(self.voiceProfiles, forKey: .voiceProfiles) }
        if self.speakerSlotsContinueAcrossEpochs {
            try container.encode(true, forKey: .speakerSlotsContinueAcrossEpochs)
        }
    }
}

nonisolated enum MeetingBackendEvidenceError: LocalizedError, Equatable {
    case backendMismatch(expected: MeetingBackendID, actual: MeetingBackendID)
    case attemptMismatch(expected: UUID, actual: UUID)
    case emptyUnitID
    case duplicateUnitID(String)
    case emptyText(unitID: String)
    case unsupportedPrecision(unitID: String, precision: MeetingTextUnitPrecision)
    case unknownSourceTrack(unitID: String)
    case missingAnalysisSpans(unitID: String)
    case duplicateAnalysisSpanID(unitID: String)
    case unknownAnalysisSpan(unitID: String)
    case unknownAnalysisEpoch(unitID: String)
    case analysisEpochOutOfScope(unitID: String)
    case invalidAnalysisEpochOrdinal(unitID: String)
    case invalidAnalysisEpochGeneration(unitID: String)
    case speakerTokenOutOfScope(unitID: String)
    case emptySpeakerTokenLabel(unitID: String)
    case invalidAmbiguity(unitID: String)
    case invalidActivityTiming(index: Int)
    case activityTokenOutOfScope(index: Int)
    case activityEpochUnknown(index: Int)
    case invalidActivityEpochOrdinal(index: Int)
    case invalidActivityEpochGeneration(index: Int)
    case emptyActivityTokenLabel(index: Int)
    case activityOutsideEpoch(index: Int)

    var errorDescription: String? {
        switch self {
        case let .backendMismatch(expected, actual):
            return "Evidence came from backend \"\(actual)\" but the plan selected \"\(expected)\"."
        case let .attemptMismatch(expected, actual):
            return "Evidence carries attempt \(actual) but the plan is attempt \(expected)."
        case .emptyUnitID:
            return "A final text unit has an empty identifier."
        case let .duplicateUnitID(id):
            return "Final text unit identifier \"\(id)\" appears more than once."
        case let .emptyText(unitID):
            return "Final text unit \"\(unitID)\" has no text."
        case let .unsupportedPrecision(unitID, precision):
            return "Final text unit \"\(unitID)\" declares \(precision.rawValue) precision, "
                + "which this backend did not declare support for."
        case let .unknownSourceTrack(unitID):
            return "Final text unit \"\(unitID)\" references a track that was not planned."
        case let .missingAnalysisSpans(unitID):
            return "Final text unit \"\(unitID)\" references no analysis span."
        case let .duplicateAnalysisSpanID(unitID):
            return "Final text unit \"\(unitID)\" repeats an analysis span identifier."
        case let .unknownAnalysisSpan(unitID):
            return "Final text unit \"\(unitID)\" references an analysis span the manifest does not record."
        case let .unknownAnalysisEpoch(unitID):
            return "Final text unit \"\(unitID)\" uses an analysis epoch the manifest does not record."
        case let .analysisEpochOutOfScope(unitID):
            return "Final text unit \"\(unitID)\" uses an analysis epoch from another track."
        case let .invalidAnalysisEpochOrdinal(unitID):
            return "Final text unit \"\(unitID)\" uses a negative analysis epoch ordinal."
        case let .invalidAnalysisEpochGeneration(unitID):
            return "Final text unit \"\(unitID)\" uses a negative analysis epoch generation."
        case let .speakerTokenOutOfScope(unitID):
            return "Final text unit \"\(unitID)\" uses a speaker token from another track or epoch."
        case let .emptySpeakerTokenLabel(unitID):
            return "Final text unit \"\(unitID)\" uses an empty speaker-token label."
        case let .invalidAmbiguity(unitID):
            return "Final text unit \"\(unitID)\" reports ambiguity without two distinct candidates."
        case let .invalidActivityTiming(index):
            return "Speaker activity interval \(index) has non-finite or non-positive timing."
        case let .activityTokenOutOfScope(index):
            return "Speaker activity interval \(index) uses a token from an unplanned track."
        case let .activityEpochUnknown(index):
            return "Speaker activity interval \(index) uses an epoch the manifest does not record."
        case let .invalidActivityEpochOrdinal(index):
            return "Speaker activity interval \(index) uses a negative analysis epoch ordinal."
        case let .invalidActivityEpochGeneration(index):
            return "Speaker activity interval \(index) uses a negative analysis epoch generation."
        case let .emptyActivityTokenLabel(index):
            return "Speaker activity interval \(index) uses an empty speaker-token label."
        case let .activityOutsideEpoch(index):
            return "Speaker activity interval \(index) lies outside its analysis epoch."
        }
    }
}

nonisolated extension MeetingFinalTranscriptEvidence {
    /// Scope validation against the frozen plan: identity, uniqueness, declared precisions, and
    /// reference *shape*. A failure here means the evidence talks about something that was never
    /// planned, so it throws. Timing and provenance *values* are deliberately not judged here —
    /// they are quarantined per unit by `quarantineReason(in:)` so assembly can ledger every unit.
    @discardableResult
    func validated(against plan: MeetingBackendPlan) throws -> Self {
        guard self.backendID == plan.backendID else {
            throw MeetingBackendEvidenceError.backendMismatch(expected: plan.backendID, actual: self.backendID)
        }
        guard self.attemptID == plan.attemptID else {
            throw MeetingBackendEvidenceError.attemptMismatch(expected: plan.attemptID, actual: self.attemptID)
        }

        var seenUnitIDs = Set<String>()
        for unit in self.units {
            guard !unit.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingBackendEvidenceError.emptyUnitID
            }
            guard seenUnitIDs.insert(unit.id).inserted else {
                throw MeetingBackendEvidenceError.duplicateUnitID(unit.id)
            }
            guard !unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingBackendEvidenceError.emptyText(unitID: unit.id)
            }
            guard plan.declaredFinalPrecisions.contains(unit.precision) else {
                throw MeetingBackendEvidenceError.unsupportedPrecision(unitID: unit.id, precision: unit.precision)
            }
            guard plan.trackKindsByID[unit.trackID] != nil else {
                throw MeetingBackendEvidenceError.unknownSourceTrack(unitID: unit.id)
            }
            guard !unit.analysisSpanIDs.isEmpty else {
                throw MeetingBackendEvidenceError.missingAnalysisSpans(unitID: unit.id)
            }
            guard Set(unit.analysisSpanIDs).count == unit.analysisSpanIDs.count else {
                throw MeetingBackendEvidenceError.duplicateAnalysisSpanID(unitID: unit.id)
            }
            guard unit.analysisEpochID.trackID == unit.trackID else {
                throw MeetingBackendEvidenceError.analysisEpochOutOfScope(unitID: unit.id)
            }
            guard unit.analysisEpochID.ordinal >= 0 else {
                throw MeetingBackendEvidenceError.invalidAnalysisEpochOrdinal(unitID: unit.id)
            }
            guard unit.analysisEpochID.generation >= 0 else {
                throw MeetingBackendEvidenceError.invalidAnalysisEpochGeneration(unitID: unit.id)
            }
            guard unit.speaker.tokens.allSatisfy({ $0.analysisEpochID == unit.analysisEpochID }) else {
                throw MeetingBackendEvidenceError.speakerTokenOutOfScope(unitID: unit.id)
            }
            guard unit.speaker.tokens.allSatisfy({
                !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw MeetingBackendEvidenceError.emptySpeakerTokenLabel(unitID: unit.id)
            }
            if case let .ambiguous(candidates) = unit.speaker, Set(candidates).count < 2 {
                throw MeetingBackendEvidenceError.invalidAmbiguity(unitID: unit.id)
            }
        }

        for (index, activity) in self.speakerActivity.enumerated() {
            guard MeetingEvidenceInterval.isValid(start: activity.start, end: activity.end) else {
                throw MeetingBackendEvidenceError.invalidActivityTiming(index: index)
            }
            guard plan.trackKindsByID[activity.token.analysisEpochID.trackID] != nil else {
                throw MeetingBackendEvidenceError.activityTokenOutOfScope(index: index)
            }
            guard activity.token.analysisEpochID.ordinal >= 0 else {
                throw MeetingBackendEvidenceError.invalidActivityEpochOrdinal(index: index)
            }
            guard activity.token.analysisEpochID.generation >= 0 else {
                throw MeetingBackendEvidenceError.invalidActivityEpochGeneration(index: index)
            }
            guard !activity.token.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingBackendEvidenceError.emptyActivityTokenLabel(index: index)
            }
        }

        return self
    }

    /// Assembly scope validation: everything `validated(against:)` proves, plus proof that every
    /// epoch and span the evidence names actually exists in the validated manifest. Anything the
    /// manifest does not record is a scope violation, never a quarantinable timing defect.
    @discardableResult
    func validatedForAssembly(
        against plan: MeetingBackendPlan,
        manifest: MeetingAnalysisManifest
    ) throws -> Self {
        try self.validated(against: plan)
        for unit in self.units {
            guard let track = manifest.track(unit.trackID) else {
                throw MeetingBackendEvidenceError.unknownSourceTrack(unitID: unit.id)
            }
            guard track.epochs.contains(where: { $0.id == unit.analysisEpochID }) else {
                throw MeetingBackendEvidenceError.unknownAnalysisEpoch(unitID: unit.id)
            }
            let spanIDs = Set(track.spans.map(\.id))
            guard unit.analysisSpanIDs.allSatisfy(spanIDs.contains) else {
                throw MeetingBackendEvidenceError.unknownAnalysisSpan(unitID: unit.id)
            }
        }
        for (index, activity) in self.speakerActivity.enumerated() {
            guard let track = manifest.track(activity.token.analysisEpochID.trackID) else {
                throw MeetingBackendEvidenceError.activityTokenOutOfScope(index: index)
            }
            guard let epoch = track.epochs.first(where: {
                $0.id == activity.token.analysisEpochID
            }) else {
                throw MeetingBackendEvidenceError.activityEpochUnknown(index: index)
            }
            let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
            guard activity.start >= epoch.analysisInterval.start - tolerance,
                  activity.end <= epoch.analysisInterval.end + tolerance
            else {
                throw MeetingBackendEvidenceError.activityOutsideEpoch(index: index)
            }
        }
        return self
    }
}

/// Why one input unit can never be mapped or emitted: a timing or provenance *value* defect found
/// after scope validation. These are disposition reasons, not errors — plan §4 quarantines such
/// units from normal output and forbids interval arithmetic on their bounds.
nonisolated enum MeetingUnitQuarantineReason: String, Codable, CaseIterable {
    /// Non-finite, negative or non-positive analysis-time bounds.
    case invalidTiming
    /// Confidence outside 0...1. Absent confidence is never a defect.
    case invalidConfidence
    /// The referenced spans belong to a different analysis epoch than the unit declares.
    case analysisEpochMismatch
    /// The referenced spans are not a contiguous run inside the unit's epoch, so the unit would
    /// bridge a missing or inadmissible span.
    case spansNotContiguousWithinEpoch
    /// The unit's analysis bounds are not covered by the union of the spans it references.
    case spansDoNotCoverUnitInterval
    /// The referenced spans are valid, but their transforms map the unit to non-finite,
    /// negative, or non-positive presentation bounds.
    case presentationMappingInvalid
}

nonisolated extension MeetingFinalTextUnit {
    /// The timing/provenance quarantine classification for this unit, or `nil` when its bounds
    /// and span provenance are sound. Requires scope validation to have passed: unknown span or
    /// epoch references are errors there, never reasons here.
    func quarantineReason(in manifest: MeetingAnalysisManifest) -> MeetingUnitQuarantineReason? {
        guard MeetingEvidenceInterval.isValid(start: self.analysisStart, end: self.analysisEnd) else {
            return .invalidTiming
        }
        if let confidence = self.confidence,
           !confidence.isFinite || confidence < 0 || confidence > 1
        {
            return .invalidConfidence
        }
        guard let track = manifest.track(self.trackID) else { return nil }
        let spansByID = Dictionary(track.spans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let referenced = self.analysisSpanIDs.compactMap { spansByID[$0] }
        guard referenced.count == self.analysisSpanIDs.count,
              referenced.allSatisfy({ $0.analysisEpochID == self.analysisEpochID })
        else { return .analysisEpochMismatch }

        // The span set must be one contiguous run inside its epoch's analysis-ordered span list:
        // that is what proves the unit never bridges a missing or inadmissible span, since the
        // manifest removes exactly those from analysis time and breaks the epoch across them.
        guard let epoch = track.epochs.first(where: { $0.id == self.analysisEpochID }),
              let firstIndex = epoch.spanIDs.firstIndex(of: self.analysisSpanIDs[0]),
              firstIndex + self.analysisSpanIDs.count <= epoch.spanIDs.count,
              Array(epoch.spanIDs[firstIndex..<(firstIndex + self.analysisSpanIDs.count)]) == self.analysisSpanIDs
        else { return .spansNotContiguousWithinEpoch }

        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        guard self.analysisStart >= referenced[0].analysisInterval.start - tolerance,
              self.analysisStart < referenced[0].analysisInterval.end - tolerance,
              self.analysisEnd <= referenced[referenced.count - 1].analysisInterval.end + tolerance,
              self.analysisEnd > referenced[referenced.count - 1].analysisInterval.start + tolerance
        else { return .spansDoNotCoverUnitInterval }
        let presentationStart = referenced[0].presentationMapping
            .presentationTime(forAnalysisTime: self.analysisStart)
        let presentationEnd = referenced[referenced.count - 1].presentationMapping
            .presentationTime(forAnalysisTime: self.analysisEnd)
        guard MeetingEvidenceInterval.isValid(start: presentationStart, end: presentationEnd) else {
            return .presentationMappingInvalid
        }
        return nil
    }
}
