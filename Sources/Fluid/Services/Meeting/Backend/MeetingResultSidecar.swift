import Foundation

// Stage C of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§4): the versioned, self-contained
// durable result record. It carries backend/attempt lineage, the full final text units, exactly
// one final disposition per unit, and one coverage receipt per admissible analysis span.
//
// Self-contained means values only: no stage-file paths, scratch references or session-directory
// URLs ever appear here, so a retained sidecar can never dangle after checkpoint cleanup.
//
// Schema version 3 (C2b2): text units carry analysis-time bounds plus exact analysis-span IDs,
// coverage receipts are per admissible manifest span, and the complete validated analysis manifest
// is embedded so those IDs and mappings remain self-contained after checkpoint cleanup. Every
// receipt status is a *backend* account of work — processed (including no speech), failed,
// skipped or provider-truncated; inadmissible audio is a manifest gap, not a receipt, because the
// backend never receives it. Text never implies coverage: a span full of words but missing its
// receipt fails reconciliation in the assembler, and a processed receipt with no words is simply
// a span with no speech.

nonisolated enum MeetingResultSidecarSchema {
    static let currentVersion = 3
}

/// The disposition set from plan §4. Raw values are stable contract tokens; decoding is
/// fail-closed through the raw-value enum, so an unknown disposition never becomes visible text.
nonisolated enum MeetingTextUnitFinalDisposition: String, Codable, CaseIterable {
    case emitted
    case ambiguousUnassigned
    case outsideActivity
    case echoSuppressed
    case inadmissible
    /// Timing or provenance quarantine: invalid bounds, or span references that do not provably
    /// cover the unit. The `reasonCode` carries the specific `MeetingUnitQuarantineReason`.
    case rejectedInvalidTiming
}

/// Stable reasons used by non-quarantine dispositions. Quarantine reasons use
/// `MeetingUnitQuarantineReason` directly so arbitrary strings can never authorize exclusion.
nonisolated enum MeetingUnitDispositionReason: String, Codable, CaseIterable {
    case ambiguousSpeaker
    case timingUncertain
    case outsideSpeakerActivity
    case crossTrackEcho
    case inadmissibleCaptureEra
}

nonisolated struct MeetingTextUnitDispositionRecord: Codable, Equatable {
    let unitID: String
    let disposition: MeetingTextUnitFinalDisposition
    /// Diagnostic token only (for example a quarantine or coverage reason); never load-bearing
    /// for inclusion.
    let reasonCode: String?

    init(unitID: String, disposition: MeetingTextUnitFinalDisposition, reasonCode: String? = nil) {
        self.unitID = unitID
        self.disposition = disposition
        self.reasonCode = reasonCode
    }
}

/// Plan §4 span status over one admissible analysis span: processed (including spans with no
/// speech), failed, skipped, or truncated by the provider. A receipt reports that the span was
/// accounted for; it cannot prove the ASR model recognized every spoken word inside it.
nonisolated enum MeetingSpanCoverageStatus: String, Codable, CaseIterable {
    case processed
    case failed
    case skipped
    case providerTruncated
}

/// A backend coverage receipt for one admissible manifest analysis span. Receipts for a span must
/// tile the span's analysis interval exactly once; the assembler reconciles them against the
/// manifest and throws on any missing, duplicate, unknown or out-of-bounds receipt.
nonisolated struct MeetingSpanCoverageReceipt: Codable, Equatable, Identifiable {
    let id: String
    /// The exact `MeetingAnalysisSpan.id` this receipt accounts for.
    let spanID: String
    /// Analysis-time sub-interval of the span, same domain as `MeetingFinalTextUnit` bounds.
    let analysisStart: TimeInterval
    let analysisEnd: TimeInterval
    let status: MeetingSpanCoverageStatus
    /// Diagnostic token only, for example a failure or truncation detail.
    let reasonCode: String?

    init(
        id: String,
        spanID: String,
        analysisStart: TimeInterval,
        analysisEnd: TimeInterval,
        status: MeetingSpanCoverageStatus,
        reasonCode: String? = nil
    ) {
        self.id = id
        self.spanID = spanID
        self.analysisStart = analysisStart
        self.analysisEnd = analysisEnd
        self.status = status
        self.reasonCode = reasonCode
    }
}

nonisolated struct MeetingResultSidecar: Equatable {
    let schemaVersion: Int
    let backendID: MeetingBackendID
    let backendVersion: String
    let attemptID: UUID
    /// The complete validated source→analysis→presentation mapping that gives every span ID in
    /// `units` and `coverageReceipts` durable meaning. It contains values only—no scratch paths—so
    /// the result remains self-contained after checkpoints and stage files are removed.
    let analysisManifest: MeetingAnalysisManifest
    let units: [MeetingFinalTextUnit]
    let dispositions: [MeetingTextUnitDispositionRecord]
    let coverageReceipts: [MeetingSpanCoverageReceipt]
    let speakerIdentityLinks: [MeetingSpeakerIdentityLink]

    init(
        backendID: MeetingBackendID,
        backendVersion: String,
        attemptID: UUID,
        analysisManifest: MeetingAnalysisManifest,
        units: [MeetingFinalTextUnit],
        dispositions: [MeetingTextUnitDispositionRecord],
        coverageReceipts: [MeetingSpanCoverageReceipt],
        speakerIdentityLinks: [MeetingSpeakerIdentityLink] = []
    ) {
        self.schemaVersion = MeetingResultSidecarSchema.currentVersion
        self.backendID = backendID
        self.backendVersion = backendVersion
        self.attemptID = attemptID
        self.analysisManifest = analysisManifest
        self.units = units
        self.dispositions = dispositions
        self.coverageReceipts = coverageReceipts
        self.speakerIdentityLinks = speakerIdentityLinks
    }
}

nonisolated extension MeetingResultSidecar: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case backendID
        case backendVersion
        case attemptID
        case analysisManifest
        case units
        case dispositions
        case coverageReceipts
        case speakerIdentityLinks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == MeetingResultSidecarSchema.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported meeting result sidecar schema version \(version)."
            )
        }
        try self.init(
            backendID: container.decode(MeetingBackendID.self, forKey: .backendID),
            backendVersion: container.decode(String.self, forKey: .backendVersion),
            attemptID: container.decode(UUID.self, forKey: .attemptID),
            analysisManifest: container.decode(MeetingAnalysisManifest.self, forKey: .analysisManifest),
            units: container.decode([MeetingFinalTextUnit].self, forKey: .units),
            dispositions: container.decode([MeetingTextUnitDispositionRecord].self, forKey: .dispositions),
            coverageReceipts: container.decode([MeetingSpanCoverageReceipt].self, forKey: .coverageReceipts),
            speakerIdentityLinks: container.decodeIfPresent([MeetingSpeakerIdentityLink].self, forKey: .speakerIdentityLinks) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.schemaVersion, forKey: .schemaVersion)
        try container.encode(self.backendID, forKey: .backendID)
        try container.encode(self.backendVersion, forKey: .backendVersion)
        try container.encode(self.attemptID, forKey: .attemptID)
        try container.encode(self.analysisManifest, forKey: .analysisManifest)
        try container.encode(self.units, forKey: .units)
        try container.encode(self.dispositions, forKey: .dispositions)
        try container.encode(self.coverageReceipts, forKey: .coverageReceipts)
        if !self.speakerIdentityLinks.isEmpty { try container.encode(self.speakerIdentityLinks, forKey: .speakerIdentityLinks) }
    }
}

nonisolated enum MeetingResultSidecarError: LocalizedError, Equatable {
    case invalidSpeakerIdentityLinks
    case emptyBackendID
    case emptyBackendVersion
    case emptyUnitID
    case manifestLineageMismatch
    case unitReferencesUnknownManifestSpan(unitID: String)
    case receiptReferencesUnknownManifestSpan(receiptID: String)
    case duplicateDisposition(unitID: String)
    case missingDisposition(unitID: String)
    case dispositionForUnknownUnit(unitID: String)
    /// An ambiguous-unassigned unit must either carry real ambiguity candidates or name why a
    /// resolved-looking unit is unassigned (for example `timingUncertain`): plan §4 reports
    /// ambiguity, it never invents it and never silently drops it.
    case ambiguousDispositionWithoutCandidates(unitID: String)
    case emittedDispositionWithAmbiguity(unitID: String)
    case duplicateUnitID(String)
    case emptyUnitText(unitID: String)
    case invalidAmbiguity(unitID: String)
    case speakerTokenOutOfScope(unitID: String)
    case emptySpeakerTokenLabel(unitID: String)
    case invalidAnalysisEpochOrdinal(unitID: String)
    case invalidAnalysisEpochGeneration(unitID: String)
    case invalidConfidence(unitID: String)
    case missingUnitAnalysisSpans(unitID: String)
    case duplicateUnitAnalysisSpanID(unitID: String)
    case invalidTimingNotRejected(unitID: String)
    case rejectedInvalidTimingForValidUnit(unitID: String)
    case invalidDispositionReason(unitID: String)
    case emptyCoverageReceiptID
    case duplicateCoverageReceiptID(String)
    case emptyCoverageReceiptSpanID(receiptID: String)
    case invalidCoverageInterval(receiptID: String)

    var errorDescription: String? {
        switch self {
        case .invalidSpeakerIdentityLinks:
            return "Speaker identity links must join visible speakers across epochs of the same track without collisions."
        case .emptyBackendID:
            return "The result sidecar has no backend identifier."
        case .emptyBackendVersion:
            return "The result sidecar has no backend version."
        case .emptyUnitID:
            return "A result sidecar text unit has an empty identifier."
        case .manifestLineageMismatch:
            return "The result sidecar's analysis manifest does not match its backend or attempt lineage."
        case let .unitReferencesUnknownManifestSpan(unitID):
            return "Text unit \"\(unitID)\" references a span absent from the embedded analysis manifest."
        case let .receiptReferencesUnknownManifestSpan(receiptID):
            return "Coverage receipt \"\(receiptID)\" references a span absent from the embedded analysis manifest."
        case let .duplicateUnitID(id):
            return "Text unit identifier \"\(id)\" appears more than once in the sidecar."
        case let .emptyUnitText(unitID):
            return "Text unit \"\(unitID)\" has no text."
        case let .invalidAmbiguity(unitID):
            return "Text unit \"\(unitID)\" does not contain two distinct ambiguity candidates."
        case let .speakerTokenOutOfScope(unitID):
            return "Text unit \"\(unitID)\" carries a speaker token from another track or epoch."
        case let .emptySpeakerTokenLabel(unitID):
            return "Text unit \"\(unitID)\" carries an empty speaker-token label."
        case let .invalidAnalysisEpochOrdinal(unitID):
            return "Text unit \"\(unitID)\" uses a negative analysis epoch ordinal."
        case let .invalidAnalysisEpochGeneration(unitID):
            return "Text unit \"\(unitID)\" uses a negative analysis epoch generation."
        case let .invalidConfidence(unitID):
            return "Text unit \"\(unitID)\" has a confidence outside 0...1."
        case let .missingUnitAnalysisSpans(unitID):
            return "Text unit \"\(unitID)\" references no analysis span."
        case let .duplicateUnitAnalysisSpanID(unitID):
            return "Text unit \"\(unitID)\" repeats an analysis span identifier."
        case let .invalidTimingNotRejected(unitID):
            return "Text unit \"\(unitID)\" has invalid timing without the rejected-invalid-timing disposition."
        case let .rejectedInvalidTimingForValidUnit(unitID):
            return "Text unit \"\(unitID)\" has valid timing but is rejected without a quarantine reason."
        case let .invalidDispositionReason(unitID):
            return "Text unit \"\(unitID)\" has a missing or invalid final-disposition reason."
        case let .duplicateDisposition(unitID):
            return "Text unit \"\(unitID)\" has more than one final disposition."
        case let .missingDisposition(unitID):
            return "Text unit \"\(unitID)\" has no final disposition."
        case let .dispositionForUnknownUnit(unitID):
            return "A final disposition references unknown text unit \"\(unitID)\"."
        case let .ambiguousDispositionWithoutCandidates(unitID):
            return "Text unit \"\(unitID)\" is ambiguous-unassigned without candidates or a reason."
        case let .emittedDispositionWithAmbiguity(unitID):
            return "Text unit \"\(unitID)\" is emitted despite an ambiguous speaker assignment."
        case .emptyCoverageReceiptID:
            return "A coverage receipt has an empty identifier."
        case let .duplicateCoverageReceiptID(id):
            return "Coverage receipt identifier \"\(id)\" appears more than once."
        case let .emptyCoverageReceiptSpanID(receiptID):
            return "Coverage receipt \"\(receiptID)\" names no analysis span."
        case let .invalidCoverageInterval(receiptID):
            return "Coverage receipt \"\(receiptID)\" has non-finite or non-positive bounds."
        }
    }
}

nonisolated extension MeetingResultSidecar {
    /// Structural validation of the ledger invariants from plan §4: every recognized text unit
    /// has exactly one final disposition, dispositions reference only known units, a unit with
    /// unusable bounds is always quarantined (and a quarantined unit with sound bounds names the
    /// provenance reason), and ambiguity is reported, never silently resolved. Value checks that a
    /// quarantined unit cannot pass — timing, confidence — apply only to units the ledger claims
    /// were usable. What this cannot prove without the manifest is span coverage: reconciliation
    /// of units and receipts against the manifest's spans is the assembler's job.
    @discardableResult
    func validated() throws -> Self {
        let visibleIDs = Set(self.dispositions.filter { $0.disposition == .emitted }.map(\.unitID))
        let visibleTokens = Set(self.units.compactMap { unit -> MeetingBackendSpeakerToken? in
            guard visibleIDs.contains(unit.id), case let .assigned(token) = unit.speaker else { return nil }
            return token
        })
        guard MeetingSpeakerVoiceMatcher.validLinks(self.speakerIdentityLinks, allowedTokens: visibleTokens) else {
            throw MeetingResultSidecarError.invalidSpeakerIdentityLinks
        }
        guard !self.backendID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingResultSidecarError.emptyBackendID
        }
        guard !self.backendVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingResultSidecarError.emptyBackendVersion
        }
        guard self.analysisManifest.backendID == self.backendID,
              self.analysisManifest.backendVersion == self.backendVersion,
              self.analysisManifest.attemptID == self.attemptID
        else {
            throw MeetingResultSidecarError.manifestLineageMismatch
        }
        let manifestSpansByID = Dictionary(
            self.analysisManifest.allSpans.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var seenUnitIDs = Set<String>()
        for unit in self.units {
            guard !unit.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingResultSidecarError.emptyUnitID
            }
            guard seenUnitIDs.insert(unit.id).inserted else {
                throw MeetingResultSidecarError.duplicateUnitID(unit.id)
            }
            guard !unit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingResultSidecarError.emptyUnitText(unitID: unit.id)
            }
            guard !unit.analysisSpanIDs.isEmpty else {
                throw MeetingResultSidecarError.missingUnitAnalysisSpans(unitID: unit.id)
            }
            guard Set(unit.analysisSpanIDs).count == unit.analysisSpanIDs.count else {
                throw MeetingResultSidecarError.duplicateUnitAnalysisSpanID(unitID: unit.id)
            }
            guard unit.analysisSpanIDs.allSatisfy({ spanID in
                guard let span = manifestSpansByID[spanID] else { return false }
                return span.trackID == unit.trackID
            }) else {
                throw MeetingResultSidecarError.unitReferencesUnknownManifestSpan(unitID: unit.id)
            }
            guard unit.analysisEpochID.ordinal >= 0 else {
                throw MeetingResultSidecarError.invalidAnalysisEpochOrdinal(unitID: unit.id)
            }
            guard unit.analysisEpochID.generation >= 0 else {
                throw MeetingResultSidecarError.invalidAnalysisEpochGeneration(unitID: unit.id)
            }
            guard unit.speaker.tokens.allSatisfy({ $0.analysisEpochID == unit.analysisEpochID }) else {
                throw MeetingResultSidecarError.speakerTokenOutOfScope(unitID: unit.id)
            }
            guard unit.speaker.tokens.allSatisfy({
                !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw MeetingResultSidecarError.emptySpeakerTokenLabel(unitID: unit.id)
            }
            if case let .ambiguous(candidates) = unit.speaker,
               Set(candidates).count < 2
            {
                throw MeetingResultSidecarError.invalidAmbiguity(unitID: unit.id)
            }
        }
        let unitsByID = Dictionary(self.units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var dispositionedIDs = Set<String>()
        for record in self.dispositions {
            guard dispositionedIDs.insert(record.unitID).inserted else {
                throw MeetingResultSidecarError.duplicateDisposition(unitID: record.unitID)
            }
            guard let unit = unitsByID[record.unitID] else {
                throw MeetingResultSidecarError.dispositionForUnknownUnit(unitID: record.unitID)
            }
            let isAmbiguous: Bool
            if case .ambiguous = unit.speaker { isAmbiguous = true } else { isAmbiguous = false }
            let hasValidTiming = MeetingEvidenceInterval.isValid(
                start: unit.analysisStart, end: unit.analysisEnd
            )
            let hasValidConfidence = unit.confidence.map {
                $0.isFinite && $0 >= 0 && $0 <= 1
            } ?? true
            if record.disposition == .rejectedInvalidTiming {
                guard let reasonCode = record.reasonCode,
                      let reason = MeetingUnitQuarantineReason(rawValue: reasonCode)
                else {
                    if hasValidTiming {
                        throw MeetingResultSidecarError.rejectedInvalidTimingForValidUnit(
                            unitID: record.unitID
                        )
                    }
                    throw MeetingResultSidecarError.invalidDispositionReason(unitID: record.unitID)
                }
                let expectedLocallyVisibleReason: MeetingUnitQuarantineReason? = if !hasValidTiming {
                    .invalidTiming
                } else if !hasValidConfidence {
                    .invalidConfidence
                } else {
                    nil
                }
                if let expectedLocallyVisibleReason {
                    guard reason == expectedLocallyVisibleReason else {
                        throw MeetingResultSidecarError.invalidDispositionReason(unitID: record.unitID)
                    }
                } else {
                    guard [
                        MeetingUnitQuarantineReason.analysisEpochMismatch,
                        .spansNotContiguousWithinEpoch,
                        .spansDoNotCoverUnitInterval,
                        .presentationMappingInvalid,
                    ].contains(reason) else {
                        throw MeetingResultSidecarError.invalidDispositionReason(unitID: record.unitID)
                    }
                }
            } else {
                guard hasValidTiming else {
                    throw MeetingResultSidecarError.invalidTimingNotRejected(unitID: record.unitID)
                }
                if !hasValidConfidence {
                    throw MeetingResultSidecarError.invalidConfidence(unitID: unit.id)
                }
            }
            switch record.disposition {
            case .ambiguousUnassigned:
                let allowedReason: Bool
                if isAmbiguous {
                    allowedReason = record.reasonCode == nil
                        || record.reasonCode == MeetingUnitDispositionReason.ambiguousSpeaker.rawValue
                } else {
                    allowedReason = record.reasonCode == MeetingUnitDispositionReason.timingUncertain.rawValue
                }
                guard allowedReason else {
                    throw MeetingResultSidecarError.ambiguousDispositionWithoutCandidates(unitID: record.unitID)
                }
            case .emitted:
                guard !isAmbiguous else {
                    throw MeetingResultSidecarError.emittedDispositionWithAmbiguity(unitID: record.unitID)
                }
                guard record.reasonCode == nil else {
                    throw MeetingResultSidecarError.invalidDispositionReason(unitID: record.unitID)
                }
            case .outsideActivity:
                guard record.reasonCode == MeetingUnitDispositionReason.outsideSpeakerActivity.rawValue else {
                    throw MeetingResultSidecarError.invalidDispositionReason(unitID: record.unitID)
                }
            case .echoSuppressed:
                guard record.reasonCode == MeetingUnitDispositionReason.crossTrackEcho.rawValue else {
                    throw MeetingResultSidecarError.invalidDispositionReason(unitID: record.unitID)
                }
            case .inadmissible:
                guard record.reasonCode == MeetingUnitDispositionReason.inadmissibleCaptureEra.rawValue else {
                    throw MeetingResultSidecarError.invalidDispositionReason(unitID: record.unitID)
                }
            case .rejectedInvalidTiming:
                break
            }
        }
        for unit in self.units where !dispositionedIDs.contains(unit.id) {
            throw MeetingResultSidecarError.missingDisposition(unitID: unit.id)
        }

        var seenReceiptIDs = Set<String>()
        for receipt in self.coverageReceipts {
            guard !receipt.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingResultSidecarError.emptyCoverageReceiptID
            }
            guard seenReceiptIDs.insert(receipt.id).inserted else {
                throw MeetingResultSidecarError.duplicateCoverageReceiptID(receipt.id)
            }
            guard !receipt.spanID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingResultSidecarError.emptyCoverageReceiptSpanID(receiptID: receipt.id)
            }
            guard manifestSpansByID[receipt.spanID] != nil else {
                throw MeetingResultSidecarError.receiptReferencesUnknownManifestSpan(
                    receiptID: receipt.id
                )
            }
            guard MeetingEvidenceInterval.isValid(start: receipt.analysisStart, end: receipt.analysisEnd) else {
                throw MeetingResultSidecarError.invalidCoverageInterval(receiptID: receipt.id)
            }
        }

        return self
    }
}
