import Foundation

// Stage C2a assembler of the analysis manifest. It reads a frozen `MeetingBackendPlan`, observes
// every planned chunk through an injected boundary, and produces the immutable
// `MeetingAnalysisManifest` the rest of Stage C will map evidence through.
//
// What it will not do is as important as what it does:
//
// - it never invents audio: a chunk it cannot find, verify or decode becomes a typed gap;
// - it never mixes application and microphone audio, and never shares analysis time between them;
// - it applies the existing VPIO de-drift correction exactly once, per capture era, and records
//   that it did — so a second correction downstream would contradict a stored fact;
// - it splits a chunk at capture-era boundaries instead of judging the whole chunk by one era, so
//   the safe part of a chunk stays analysable and only the unsafe part becomes an explicit gap;
// - it returns nothing that does not pass `validated(against:)`, so a bug here surfaces as a
//   refusal rather than as a manifest the rest of the stage would trust.
//
// Nothing here writes a file, creates a product speaker ID, or applies echo policy.

nonisolated struct MeetingAnalysisManifestBuilder {
    let plan: MeetingBackendPlan
    let observer: any MeetingChunkAudioObserving
    /// The backend's real resampler rate, when this build knows it. `nil` leaves every span's
    /// sample-rate conversion ratio explicitly unknown rather than implying 1.
    let analysisSampleRate: Double?
    let residualBoundSeconds: Double
    /// Generation overrides supplied by retry/checkpoint orchestration. Completed epochs retain
    /// their generation; a replayed epoch receives a larger one and therefore new speaker IDs.
    let epochGenerations: [MeetingAnalysisEpochGenerationKey: Int]

    init(
        plan: MeetingBackendPlan,
        observer: any MeetingChunkAudioObserving,
        analysisSampleRate: Double? = nil,
        residualBoundSeconds: Double = MeetingAnalysisManifestSchema.defaultResidualBoundSeconds,
        epochGenerations: [MeetingAnalysisEpochGenerationKey: Int] = [:]
    ) {
        self.plan = plan
        self.observer = observer
        self.analysisSampleRate = analysisSampleRate
        self.residualBoundSeconds = residualBoundSeconds
        self.epochGenerations = epochGenerations
    }

    /// Builds and validates. The returned manifest has already been checked against the frozen
    /// plan, so a caller never has to decide whether to trust it.
    func build() throws -> MeetingAnalysisManifest {
        let projection = MeetingAnalysisPlanProjection(plan: self.plan)
        let session = self.plan.request.session
        // Recorded track order, filtered to planned tracks: application and microphone streams stay
        // separate manifests with separate analysis timelines and separate epoch spaces.
        let tracks = try session.audioTracks
            .filter { self.plan.trackKindsByID[$0.id] != nil }
            .map { try self.buildTrack($0, projection: projection) }

        let manifest = MeetingAnalysisManifest(
            backendID: self.plan.backendID,
            backendVersion: self.plan.backendVersion,
            attemptID: self.plan.attemptID,
            sessionID: session.id,
            captureMode: session.mode,
            presentationOriginSeconds: projection.origin,
            analysisSampleRate: self.analysisSampleRate,
            residualBoundSeconds: self.residualBoundSeconds,
            tracks: tracks
        )
        return try manifest.validated(against: self.plan)
    }

    // MARK: - Per-track assembly

    /// Mutable state while walking one track's planned chunks in sequence order.
    private struct TrackAccumulator {
        var spans: [MeetingAnalysisSpan] = []
        var gaps: [MeetingAnalysisGap] = []
        var epochReasons: [MeetingAnalysisEpochID: MeetingAnalysisEpochResetReason] = [:]
        var epochOrder: [MeetingAnalysisEpochID] = []
        var analysisCursor: TimeInterval = 0
        var currentEpochID: MeetingAnalysisEpochID?
        var previousSpan: MeetingAnalysisSpan?
        var pendingGapReasons: Set<MeetingAnalysisEpochResetReason> = []
    }

    private func buildTrack(
        _ track: MeetingAudioTrack,
        projection: MeetingAnalysisPlanProjection
    ) throws -> MeetingAnalysisTrackManifest {
        var accumulator = TrackAccumulator()
        let plannedChunks = projection.plannedChunksByTrack[track.id] ?? []

        for (offset, chunk) in plannedChunks.enumerated() {
            try Task.checkCancellation()
            let identity = MeetingAnalysisChunkIdentity(trackID: track.id, chunk: chunk)
            let discontinuity = MeetingSpanDiscontinuityFacts.make(
                chunk: chunk,
                previousChunk: offset > 0 ? plannedChunks[offset - 1] : nil,
                origin: projection.origin
            )
            self.appendChunk(
                chunk,
                identity: identity,
                discontinuity: discontinuity,
                track: track,
                projection: projection,
                into: &accumulator
            )
            try Task.checkCancellation()
        }

        let epochs = accumulator.epochOrder.map { epochID in
            let members = accumulator.spans.filter { $0.analysisEpochID == epochID }
            return MeetingAnalysisEpochRecord(
                id: epochID,
                resetReason: accumulator.epochReasons[epochID] ?? .trackStart,
                spanIDs: members.map(\.id),
                analysisInterval: MeetingAnalysisInterval(
                    start: members.map(\.analysisInterval.start).min() ?? 0,
                    end: members.map(\.analysisInterval.end).max() ?? 0
                )
            )
        }
        return MeetingAnalysisTrackManifest(
            id: track.id,
            kind: track.kind,
            spans: accumulator.spans,
            gaps: accumulator.gaps,
            epochs: epochs
        )
    }

    // MARK: - Per-chunk assembly

    private func appendChunk(
        _ chunk: MeetingAudioChunk,
        identity: MeetingAnalysisChunkIdentity,
        discontinuity: MeetingSpanDiscontinuityFacts,
        track: MeetingAudioTrack,
        projection: MeetingAnalysisPlanProjection,
        into accumulator: inout TrackAccumulator
    ) {
        let recorded = projection.recordedInterval(of: chunk)

        guard chunk.finalizationState == .finalized else {
            // Defensive: planning excludes these, so reaching here means the plan and the session
            // disagree. Refusing the audio is the only safe reading.
            self.appendGap(
                identity: identity,
                pieceIndex: 0,
                reason: .chunkNotFinalized,
                recordedInterval: recorded,
                era: nil,
                detail: chunk.finalizationState.rawValue,
                into: &accumulator
            )
            return
        }
        guard let recorded else {
            self.appendGap(
                identity: identity,
                pieceIndex: 0,
                reason: .chunkHasNoRecordedInterval,
                recordedInterval: nil,
                era: nil,
                detail: "Recorded presentation bounds are not a positive interval.",
                into: &accumulator
            )
            return
        }

        let observation = self.observer.observe(chunk: chunk, trackID: track.id)
        guard case let .observed(observed) = observation else {
            guard case let .failed(failure, detail) = observation else { return }
            // One unreadable file is one hole, whatever eras it would have crossed.
            self.appendGap(
                identity: identity,
                pieceIndex: 0,
                reason: failure.gapReason,
                recordedInterval: recorded,
                era: nil,
                detail: detail,
                into: &accumulator
            )
            return
        }

        var nextPieceIndex = 0
        for piece in self.eraPieces(
            of: recorded,
            chunk: chunk,
            track: track,
            projection: projection
        ) {
            nextPieceIndex += self.appendPiece(
                piece,
                pieceIndex: nextPieceIndex,
                identity: identity,
                chunkInterval: recorded,
                observed: observed,
                discontinuity: discontinuity,
                track: track,
                projection: projection,
                into: &accumulator
            )
        }
    }

    /// Splits a chunk's recorded interval at every capture-era start that falls strictly inside it.
    /// The result tiles the interval exactly, so a mid-chunk era change costs only the part of the
    /// chunk that actually belongs to the other era.
    private func eraPieces(
        of recorded: MeetingAnalysisInterval,
        chunk: MeetingAudioChunk,
        track: MeetingAudioTrack,
        projection: MeetingAnalysisPlanProjection
    ) -> [MeetingAnalysisInterval] {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        let starts = projection.eraStartsByTrack[track.id] ?? [-.infinity]
        let discontinuityStarts = chunk.discontinuities.compactMap {
            $0.presentationTime.map { $0.seconds - projection.origin }
        }
        let candidates = (starts + discontinuityStarts)
            .filter { $0.isFinite && $0 > recorded.start + tolerance && $0 < recorded.end - tolerance }
            .sorted()
        var inner: [Double] = []
        for candidate in candidates where inner.last.map({ abs($0 - candidate) > tolerance }) ?? true {
            inner.append(candidate)
        }
        let bounds = [recorded.start] + inner + [recorded.end]
        return (0..<(bounds.count - 1)).map {
            MeetingAnalysisInterval(start: bounds[$0], end: bounds[$0 + 1])
        }
    }

    private func appendPiece(
        _ piece: MeetingAnalysisInterval,
        pieceIndex: Int,
        identity: MeetingAnalysisChunkIdentity,
        chunkInterval: MeetingAnalysisInterval,
        observed: MeetingChunkObservedAudio,
        discontinuity: MeetingSpanDiscontinuityFacts,
        track: MeetingAudioTrack,
        projection: MeetingAnalysisPlanProjection,
        into accumulator: inout TrackAccumulator
    ) -> Int {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        guard let era = projection.eraIdentity(forTrack: track.id, containing: piece.start) else {
            self.appendGap(
                identity: identity,
                pieceIndex: pieceIndex,
                reason: .chunkUnreadable,
                recordedInterval: piece,
                era: nil,
                detail: "The session records no capture era covering this interval.",
                into: &accumulator
            )
            return 1
        }
        let admission = MeetingSpanAdmission(
            captureMode: self.plan.request.session.mode,
            trackKind: track.kind,
            echoProtection: era.echoProtection
        )
        guard admission.decision == .admissible else {
            self.appendGap(
                identity: identity,
                pieceIndex: pieceIndex,
                reason: .inadmissibleCaptureEra,
                recordedInterval: piece,
                era: era,
                detail: admission.rationale.rawValue,
                into: &accumulator
            )
            return 1
        }

        // Source-local time: the recorded piece translated past any measured priming. If the
        // decoder ends partway through this recorded piece, preserve only the backed prefix as a
        // span and account for the remainder as an explicit gap; never let a shorter source region
        // claim coverage of a longer recorded interval.
        let decoded = observed.decoded
        let priming = decoded.primingSeconds ?? 0
        let availableRecordedEnd = chunkInterval.start + max(0, decoded.durationSeconds - priming)
        let spanRecordedEnd = min(piece.end, availableRecordedEnd)
        let spanPiece = MeetingAnalysisInterval(start: piece.start, end: spanRecordedEnd)
        let sourceStart = priming + (spanPiece.start - chunkInterval.start)
        let sourceEnd = priming + (spanPiece.end - chunkInterval.start)
        guard sourceEnd - sourceStart > tolerance, sourceStart >= 0 else {
            self.appendGap(
                identity: identity,
                pieceIndex: pieceIndex,
                reason: .decodedAudioExhausted,
                recordedInterval: piece,
                era: nil,
                detail: String(
                    format: "Decoder reported %.6fs of audio for a piece starting at %.6fs.",
                    decoded.durationSeconds,
                    sourceStart
                ),
                into: &accumulator
            )
            return 1
        }

        let anchor = projection.anchorSeconds(forTrack: track.id, era: era)
        let deDrift = MeetingAnalysisCaptureEras.deDrift(for: era, anchorSeconds: anchor)
        let rateRatio = deDrift.appliedFactor ?? 1
        let analysisStart = accumulator.analysisCursor
        let analysisDuration = sourceEnd - sourceStart
        let presentationStart = anchor + (spanPiece.start - anchor) * rateRatio
        let presentationEnd = presentationStart + analysisDuration * rateRatio

        // The fit residual is a measurement of this chunk, not a declaration: the decoded audio it
        // really holds, mapped through this era's correction, against the duration the recorder
        // claimed for it.
        let residual = decoded.usableDurationSeconds * rateRatio - chunkInterval.duration
        let timing = MeetingSpanTimingMetadata(
            certainty: MeetingSpanTimingMetadata.certainty(
                fitResidualSeconds: residual,
                residualBoundSeconds: self.residualBoundSeconds,
                codecPriming: decoded.codecPriming
            ),
            fitResidualSeconds: residual,
            residualBoundSeconds: self.residualBoundSeconds,
            deDrift: deDrift
        )

        let epochID = self.epochID(
            for: era,
            pieceIndex: pieceIndex,
            recordedStart: spanPiece.start,
            discontinuity: discontinuity,
            track: track,
            into: &accumulator
        )
        let span = MeetingAnalysisSpan(
            id: MeetingAnalysisSpan.stableID(
                attemptID: self.plan.attemptID, chunk: identity, pieceIndex: pieceIndex
            ),
            chunk: identity,
            pieceIndex: pieceIndex,
            trackKind: track.kind,
            analysisEpochID: epochID,
            recordedInterval: spanPiece,
            sourceLocalInterval: MeetingAnalysisInterval(start: sourceStart, end: sourceEnd),
            analysisInterval: MeetingAnalysisInterval(
                start: analysisStart, end: analysisStart + analysisDuration
            ),
            presentationInterval: MeetingAnalysisInterval(
                start: presentationStart, end: presentationEnd
            ),
            presentationMapping: MeetingAnalysisTimeTransform(
                hostClockAnchor: track.timebase.startedHostTime,
                rateRatio: rateRatio,
                offsetSeconds: presentationStart - analysisStart * rateRatio,
                sampleRateConversionRatio: self.analysisSampleRate.map { decoded.sampleRate / $0 },
                codecPrimingCompensationSeconds: decoded.primingSeconds,
                analysisRemovesGaps: true
            ),
            captureEra: era,
            admission: admission,
            observed: observed,
            discontinuity: discontinuity,
            timing: timing
        )
        accumulator.spans.append(span)
        accumulator.analysisCursor = analysisStart + analysisDuration
        accumulator.previousSpan = span
        accumulator.pendingGapReasons.removeAll()
        guard spanRecordedEnd < piece.end - tolerance else { return 1 }
        self.appendGap(
            identity: identity,
            pieceIndex: pieceIndex + 1,
            reason: .decodedAudioExhausted,
            recordedInterval: MeetingAnalysisInterval(start: spanRecordedEnd, end: piece.end),
            era: nil,
            detail: String(
                format: "Decoder audio ended at recorded time %.6fs before this piece ended at %.6fs.",
                spanRecordedEnd,
                piece.end
            ),
            into: &accumulator
        )
        return 2
    }

    private func appendGap(
        identity: MeetingAnalysisChunkIdentity,
        pieceIndex: Int,
        reason: MeetingAnalysisGapReason,
        recordedInterval: MeetingAnalysisInterval?,
        era: MeetingCaptureEraIdentity?,
        detail: String?,
        into accumulator: inout TrackAccumulator
    ) {
        let carriesAdmission = reason.carriesAdmission
        accumulator.gaps.append(MeetingAnalysisGap(
            id: MeetingAnalysisGap.stableID(
                attemptID: self.plan.attemptID, chunk: identity, pieceIndex: pieceIndex
            ),
            chunk: identity,
            pieceIndex: pieceIndex,
            reason: reason,
            recordedInterval: recordedInterval,
            captureEra: carriesAdmission ? era : nil,
            admission: carriesAdmission ? era.map {
                MeetingSpanAdmission(
                    captureMode: self.plan.request.session.mode,
                    trackKind: self.plan.trackKindsByID[identity.trackID] ?? .microphone,
                    echoProtection: $0.echoProtection
                )
            } : nil,
            detail: detail
        ))
        accumulator.pendingGapReasons.insert(reason.epochResetReason)
    }

    // MARK: - Epochs

    /// A new epoch starts only where something really broke the input: a typed gap, a recorded
    /// chunk discontinuity or time gap, or a change of microphone. Otherwise the epoch continues,
    /// so diarizer state is not thrown away for a metadata edit.
    private func epochID(
        for era: MeetingCaptureEraIdentity,
        pieceIndex: Int,
        recordedStart: TimeInterval,
        discontinuity: MeetingSpanDiscontinuityFacts,
        track: MeetingAudioTrack,
        into accumulator: inout TrackAccumulator
    ) -> MeetingAnalysisEpochID {
        guard let previousSpan = accumulator.previousSpan,
              let currentEpochID = accumulator.currentEpochID
        else {
            let epochID = self.epochID(trackID: track.id, ordinal: 0)
            accumulator.currentEpochID = epochID
            accumulator.epochReasons[epochID] = .trackStart
            accumulator.epochOrder.append(epochID)
            return epochID
        }
        let causes = MeetingAnalysisManifest.epochResetCauses(
            previousEra: previousSpan.captureEra,
            era: era,
            pieceIndex: pieceIndex,
            recordedStart: recordedStart,
            discontinuity: discontinuity,
            pendingGapReasons: accumulator.pendingGapReasons
        )
        guard let reason = MeetingAnalysisManifest.preferredEpochResetReason(among: causes) else {
            return currentEpochID
        }
        let epochID = self.epochID(trackID: track.id, ordinal: currentEpochID.ordinal + 1)
        accumulator.currentEpochID = epochID
        accumulator.epochReasons[epochID] = reason
        accumulator.epochOrder.append(epochID)
        return epochID
    }

    private func epochID(trackID: MeetingAudioTrackID, ordinal: Int) -> MeetingAnalysisEpochID {
        let key = MeetingAnalysisEpochGenerationKey(trackID: trackID, ordinal: ordinal)
        return MeetingAnalysisEpochID(
            trackID: trackID,
            ordinal: ordinal,
            generation: self.epochGenerations[key] ?? 0
        )
    }
}
