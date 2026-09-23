import Foundation

// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the local composite backend.
// Parakeet TDT v2 produces word-timed ASR; Nemotron-3 produces per-epoch speaker activity. The
// backend owns orchestration — per-epoch materialization, unit construction, slot assignment and
// exactly-tiling coverage receipts — while the host-injected runtime owns the two model
// capabilities. It never touches the filesystem outside the frozen request's session directory,
// never equates speaker slots across tracks or epochs, and never invents timing: clamping happens
// only at physical epoch bounds, and text without word timings becomes one epoch-covering
// utterance rather than fabricated words.

@MainActor
final class MeetingParakeetNemotronBackend: MeetingTranscriptionBackend {
    static let descriptor = MeetingBackendDescriptor(
        id: .parakeetNemotron,
        version: "4",
        execution: .local,
        supportedLanguageCodes: ["en"],
        supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
        supportedFinalPrecisions: [.word, .utterance],
        resultContract: .canonicalEvidence,
        knownLimits: [
            "Nemotron-3 has 8 speaker slots per analysis epoch; a ninth voice is not reliably announced or separated.",
            "Speaker slots are epoch-scoped; conservative local voice matching can reconnect identities across epochs of the same track.",
            "English only; the fixed Parakeet TDT v2 meeting policy rejects other requested options.",
            "When ASR returns text without usable word timings, one utterance covering the epoch is emitted instead of fabricated words.",
            "Local Nemotron model must be installed before planning. Voice matching downloads its local embedding model on first use.",
        ],
        analysisSampleRate: 16_000
    )

    var descriptor: MeetingBackendDescriptor {
        Self.descriptor
    }

    private let runtimeFactory: MeetingParakeetNemotronRuntimeFactory
    private let modelLocator: any MeetingNemotronModelLocating
    private let materializer: any MeetingEpochAudioMaterializing
    private var plannedArtifact: (attemptID: UUID, artifact: MeetingNemotronModelArtifact)?

    init(
        runtimeFactory: @escaping MeetingParakeetNemotronRuntimeFactory,
        modelLocator: any MeetingNemotronModelLocating = MeetingNemotronModelLocator(),
        materializer: any MeetingEpochAudioMaterializing = MeetingEpochAudioMaterializer()
    ) {
        self.runtimeFactory = runtimeFactory
        self.modelLocator = modelLocator
        self.materializer = materializer
    }

    func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
        guard self.descriptor.supportedLanguageCodes.contains(request.session.languageCode) else {
            throw MeetingBackendError.unsupportedLanguage(
                backend: self.descriptor.id,
                languageCode: request.session.languageCode
            )
        }
        // The fixed meeting Parakeet v2 policy rejects unsupported requested options explicitly
        // (plan §5): no coercion of another model or feature into this backend.
        _ = try MeetingProviderOptions.resolve(request.configuration)
        // Model readiness is a precondition of planning; execute performs no downloads.
        let artifact = try self.modelLocator.locate()
        let plan = MeetingBackendPlan(request: request, descriptor: self.descriptor)
        guard !plan.trackKindsByID.isEmpty else {
            throw MeetingBackendError.unsupportedTrackTopology(backend: self.descriptor.id)
        }
        self.plannedArtifact = (request.attemptID, artifact)
        return plan
    }

    func execute(
        plan: MeetingBackendPlan,
        manifest: MeetingAnalysisManifest?,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingBackendOutcome {
        guard let manifest else {
            throw MeetingBackendError.outcomeContractMismatch(
                backend: self.descriptor.id,
                declared: .canonicalEvidence
            )
        }
        let validatedManifest = try manifest.validated(against: plan)
        guard let plannedArtifact = self.plannedArtifact,
              plannedArtifact.attemptID == plan.attemptID
        else {
            throw MeetingBackendError.planDisagreesWithRequest(
                backend: self.descriptor.id,
                defect: .attemptIdentity
            )
        }
        let artifact = try self.modelLocator.recheck(plannedArtifact.artifact)
        self.plannedArtifact = nil
        // The host hands out the runtime only for the exact frozen request.
        let runtime = try self.runtimeFactory(plan.request)
        let materializer = self.materializer
        let request = plan.request
        let work = Task.detached(priority: .userInitiated) {
            try await Self.runAttempt(
                request: request,
                manifest: validatedManifest,
                runtime: runtime,
                artifact: artifact,
                materializer: materializer,
                progress: progress
            )
        }
        let bundle = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        return .canonicalEvidence(bundle)
    }

    // MARK: - Orchestration (background context)

    /// One epoch's work item: its manifest spans in analysis order.
    /// Silence placed between a track's epochs when they are diarized as one stream.
    private nonisolated static let epochJoinSilenceSeconds = 0.5

    private nonisolated struct EpochWork: Sendable {
        let track: MeetingAnalysisTrackManifest
        let epoch: MeetingAnalysisEpochRecord
        let spans: [MeetingAnalysisSpan]
    }

    /// Per-attempt cache for the PCM-first path. The cache is intentionally scoped to this
    /// detached attempt and bounded by the materializer's conservative sample limit; a future
    /// production implementation should replace it with a hashed immutable disk working store.
    private final nonisolated class MaterializationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MeetingAnalysisEpochID: MeetingMaterializedEpoch] = [:]
        private var totalSampleCount = 0

        func value(for epochID: MeetingAnalysisEpochID) -> MeetingMaterializedEpoch? {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.values[epochID]
        }

        func insert(_ value: MeetingMaterializedEpoch, spanID: String) throws {
            self.lock.lock(); defer { self.lock.unlock() }
            let replacing = self.values[value.epochID]?.samples.count ?? 0
            let proposed = self.totalSampleCount - replacing + value.samples.count
            guard proposed <= MeetingEpochAudioMaterializer.conservativeSampleLimit else {
                throw MeetingEpochMaterializationError.sampleLimitExceeded(
                    spanID: spanID,
                    sampleCount: proposed
                )
            }
            self.values[value.epochID] = value
            self.totalSampleCount = proposed
        }
    }

    private nonisolated static func runAttempt(
        request: MeetingBackendRequest,
        manifest: MeetingAnalysisManifest,
        runtime: any MeetingParakeetNemotronRunning,
        artifact: MeetingNemotronModelArtifact,
        materializer: any MeetingEpochAudioMaterializing,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingCanonicalResultBundle {
        let epochWork: [EpochWork] = manifest.tracks.flatMap { track in
            let spansByID = Dictionary(
                track.spans.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            return track.epochs.map { epoch in
                EpochWork(
                    track: track,
                    epoch: epoch,
                    spans: epoch.spanIDs.compactMap { spansByID[$0] }
                )
            }
        }

        let pcmMaterializations = MaterializationCache()

        // Phase A: Nemotron diarization, one continuous state per track, then drained. A track's
        // epochs are diarized in order as one stream, so a voice keeps its slot across a reset;
        // each epoch still maps its own segments back through its own spans.
        await progress(.identifyingSpeakers)
        let phaseA = try await runtime.withNemotronDiarization(artifact: artifact) { factory in
            var result = MeetingNemotronPhaseResult()
            for track in manifest.tracks {
                var pieces: [(work: EpochWork, materialized: MeetingMaterializedEpoch, offset: Int)] = []
                var trackSamples: [Float] = []
                for work in epochWork where work.track.id == track.id {
                    try Task.checkCancellation()
                    let materialized: MeetingMaterializedEpoch
                    do {
                        materialized = try await Self.materialize(
                            work: work,
                            manifest: manifest,
                            request: request,
                            materializer: materializer,
                            cache: pcmMaterializations
                        )
                    } catch let error as CancellationError {
                        throw error
                    } catch let error as MeetingEpochMaterializationError where error.isSampleLimitExceeded {
                        throw error
                    } catch {
                        result.failures[work.epoch.id] = "epochMaterializationFailed"
                        continue
                    }
                    if !trackSamples.isEmpty {
                        // Silence keeps a turn from running across the reset boundary.
                        trackSamples += [Float](repeating: 0, count: Int(Self.epochJoinSilenceSeconds * materialized.sampleRate))
                    }
                    pieces.append((work, materialized, trackSamples.count))
                    trackSamples += materialized.samples
                }
                guard let first = pieces.first else { continue }
                try Task.checkCancellation()
                do {
                    let diarizer = try await factory.makeDiarizer(epoch: first.work.epoch.id)
                    let segments = try await diarizer.diarize(samples: trackSamples)
                    for piece in pieces {
                        let pieceStart = Double(piece.offset) / piece.materialized.sampleRate
                        let pieceEnd = pieceStart + piece.materialized.durationSeconds
                        for segment in segments {
                            let localStart = max(segment.start, pieceStart) - pieceStart
                            let localEnd = min(segment.end, pieceEnd) - pieceStart
                            guard localEnd > localStart,
                                  let start = Self.analysisTime(
                                      forMaterializedSeconds: localStart,
                                      boundary: .start,
                                      materialized: piece.materialized,
                                      spans: piece.work.spans
                                  ), let end = Self.analysisTime(
                                      forMaterializedSeconds: localEnd,
                                      boundary: .end,
                                      materialized: piece.materialized,
                                      spans: piece.work.spans
                                  )
                            else { continue }
                            guard end > start else { continue }
                            result.activity.append(MeetingBackendSpeakerActivity(
                                token: MeetingBackendSpeakerToken(
                                    analysisEpochID: piece.work.epoch.id,
                                    label: "slot-\(segment.slotIndex)"
                                ),
                                start: start,
                                end: end
                            ))
                        }
                    }
                } catch let error as CancellationError {
                    throw error
                } catch {
                    for piece in pieces {
                        result.failures[piece.work.epoch.id] = "diarizationFailed"
                    }
                    continue
                }
            }
            return result
        }
        try Task.checkCancellation()

        // Phase B: Parakeet ASR inside the attempt's single prepared-meeting scope. Epochs that
        // failed phase A are excluded from ASR as well: an epoch is one unit of work.
        await progress(.transcribing)
        let phaseB = try await runtime.withPreparedASR(
            attemptID: request.attemptID,
            configuration: request.configuration
        ) { asr in
            var result = MeetingParakeetPhaseResult()
            for work in epochWork where phaseA.failures[work.epoch.id] == nil {
                try Task.checkCancellation()
                let materialized: MeetingMaterializedEpoch
                do {
                    materialized = try await Self.materialize(
                        work: work,
                        manifest: manifest,
                        request: request,
                        materializer: materializer,
                        cache: pcmMaterializations
                    )
                } catch let error as CancellationError {
                    throw error
                } catch let error as MeetingEpochMaterializationError where error.isSampleLimitExceeded {
                    throw error
                } catch {
                    result.failures[work.epoch.id] = "epochMaterializationFailed"
                    continue
                }
                try Task.checkCancellation()
                do {
                    let output = try await asr.transcribeWithTimings(materialized.samples)
                    result.outputs.append(MeetingParakeetEpochOutput(
                        epochID: work.epoch.id,
                        text: output.result.text,
                        words: output.words,
                        sampleRate: materialized.sampleRate,
                        sampleCount: materialized.samples.count,
                        spanSamples: materialized.spanSamples
                    ))
                } catch let error as CancellationError {
                    throw error
                } catch {
                    result.failures[work.epoch.id] = "asrFailed"
                    continue
                }
            }
            return result
        }
        try Task.checkCancellation()

        return try self.assembleBundle(
            request: request,
            manifest: manifest,
            epochWork: epochWork,
            phaseA: phaseA,
            phaseB: phaseB
        )
    }

    private nonisolated static func materialize(
        work: EpochWork,
        manifest: MeetingAnalysisManifest,
        request: MeetingBackendRequest,
        materializer: any MeetingEpochAudioMaterializing,
        cache: MaterializationCache
    ) async throws -> MeetingMaterializedEpoch {
        let isPCMFirst = !work.spans.isEmpty && work.spans.allSatisfy {
            $0.chunk.analysisEncoding == .linearPCMFloat32CAFV1
        }
        if isPCMFirst, let cached = cache.value(for: work.epoch.id) {
            return cached
        }
        let materialized = try await materializer.materialize(
            epoch: work.epoch,
            track: work.track,
            manifest: manifest,
            sessionDirectory: request.sessionDirectory
        )
        try Task.checkCancellation()
        guard materialized.samples.count <= MeetingEpochAudioMaterializer.conservativeSampleLimit else {
            throw MeetingEpochMaterializationError.sampleLimitExceeded(
                spanID: work.spans.last?.id ?? "unknown",
                sampleCount: materialized.samples.count
            )
        }
        if isPCMFirst {
            try cache.insert(materialized, spanID: work.spans.last?.id ?? "unknown")
        }
        return materialized
    }

    // MARK: - Units, assignment and receipts

    /// Pure assembly of the final bundle: units from provider word timings clamped only at
    /// physical epoch bounds, slot assignment from overlapping epoch activity, and exactly one
    /// tiling receipt per admissible span. Failed epochs emit no units and mark every span failed;
    /// other epochs continue (plan §4).
    private nonisolated static func assembleBundle(
        request: MeetingBackendRequest,
        manifest: MeetingAnalysisManifest,
        epochWork: [EpochWork],
        phaseA: MeetingNemotronPhaseResult,
        phaseB: MeetingParakeetPhaseResult
    ) throws -> MeetingCanonicalResultBundle {
        let outputsByEpoch = Dictionary(
            phaseB.outputs.map { ($0.epochID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activityByEpoch = Dictionary(grouping: phaseA.activity, by: { $0.token.analysisEpochID })
        var failures = phaseA.failures
        failures.merge(phaseB.failures) { first, _ in first }

        var units: [MeetingFinalTextUnit] = []
        var receipts: [MeetingSpanCoverageReceipt] = []

        for work in epochWork {
            try Task.checkCancellation()
            if let reason = failures[work.epoch.id] {
                for span in work.spans {
                    receipts.append(Self.receipt(for: span, status: .failed, reasonCode: reason))
                }
                continue
            }
            for span in work.spans {
                receipts.append(Self.receipt(for: span, status: .processed))
            }
            guard let output = outputsByEpoch[work.epoch.id] else { continue }
            let epochActivity = activityByEpoch[work.epoch.id] ?? []
            units.append(contentsOf: Self.units(
                for: output,
                work: work,
                activity: epochActivity,
                attemptID: request.attemptID
            ))
        }

        return MeetingCanonicalResultBundle(
            evidence: MeetingFinalTranscriptEvidence(
                backendID: .parakeetNemotron,
                attemptID: request.attemptID,
                units: units,
                speakerActivity: phaseA.activity.filter { failures[$0.token.analysisEpochID] == nil },
                speakerSlotsContinueAcrossEpochs: true
            ),
            coverageReceipts: receipts
        )
    }

    private nonisolated static func receipt(
        for span: MeetingAnalysisSpan,
        status: MeetingSpanCoverageStatus,
        reasonCode: String? = nil
    ) -> MeetingSpanCoverageReceipt {
        MeetingSpanCoverageReceipt(
            id: "receipt:\(span.id)",
            spanID: span.id,
            analysisStart: span.analysisInterval.start,
            analysisEnd: span.analysisInterval.end,
            status: status,
            reasonCode: reasonCode
        )
    }

    /// Word-timed units for one successful epoch. Provider times are seconds into the epoch's
    /// materialized buffer, so analysis time is the epoch start plus the provider time, clamped
    /// only to the epoch's physical bounds. Words with unusable timings are dropped, never
    /// repaired; text with no usable word timings at all becomes one epoch-covering utterance.
    private nonisolated static func units(
        for output: MeetingParakeetEpochOutput,
        work: EpochWork,
        activity: [MeetingBackendSpeakerActivity],
        attemptID: UUID
    ) -> [MeetingFinalTextUnit] {
        let epochStart = work.epoch.analysisInterval.start
        let physicalEnd = Self.analysisTime(
            forMaterializedSeconds: Double(output.sampleCount) / output.sampleRate,
            boundary: .end,
            sampleRate: output.sampleRate,
            sampleCount: output.sampleCount,
            spanSamples: output.spanSamples,
            spans: work.spans
        ) ?? epochStart
        guard physicalEnd > epochStart else { return [] }

        var wordUnits: [MeetingFinalTextUnit] = []
        var previousAssignedWord: (token: MeetingBackendSpeakerToken, end: TimeInterval)?
        let sortedWords = output.words.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
        for (index, word) in sortedWords {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  word.start.isFinite, word.end.isFinite, word.end > word.start
            else { continue }
            guard let start = Self.analysisTime(
                forMaterializedSeconds: word.start,
                boundary: .start,
                sampleRate: output.sampleRate,
                sampleCount: output.sampleCount,
                spanSamples: output.spanSamples,
                spans: work.spans
            ), let end = Self.analysisTime(
                forMaterializedSeconds: word.end,
                boundary: .end,
                sampleRate: output.sampleRate,
                sampleCount: output.sampleCount,
                spanSamples: output.spanSamples,
                spans: work.spans
            ) else { continue }
            guard end > start else { continue }
            guard let spanIDs = Self.intersectingSpanIDs(start: start, end: end, spans: work.spans)
            else { continue }
            let coverageAssignment = Self.assignment(
                start: start,
                end: end,
                activity: activity,
                allowDominance: true
            )
            let speaker = Self.handoffAssignment(
                coverageAssignment,
                start: start,
                end: end,
                activity: activity,
                previousAssignedWord: previousAssignedWord
            )
            wordUnits.append(MeetingFinalTextUnit(
                id: "unit:\(attemptID.uuidString):\(work.epoch.id):\(index)",
                trackID: work.track.id,
                analysisEpochID: work.epoch.id,
                precision: .word,
                text: text,
                analysisStart: start,
                analysisEnd: end,
                speaker: speaker,
                analysisSpanIDs: spanIDs,
                confidence: nil
            ))
            if case let .assigned(token) = speaker {
                previousAssignedWord = (token, end)
            } else {
                // An uncertain word is a hard context break; never chain a later guess through it.
                previousAssignedWord = nil
            }
        }
        if !wordUnits.isEmpty { return wordUnits }

        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let spanIDs = work.spans.map(\.id)
        guard !spanIDs.isEmpty else { return [] }
        return [MeetingFinalTextUnit(
            id: "unit:\(attemptID.uuidString):\(work.epoch.id):utterance",
            trackID: work.track.id,
            analysisEpochID: work.epoch.id,
            precision: .utterance,
            text: text,
            analysisStart: epochStart,
            analysisEnd: physicalEnd,
            speaker: Self.assignment(start: epochStart, end: physicalEnd, activity: activity, allowDominance: false),
            analysisSpanIDs: spanIDs,
            confidence: nil
        )]
    }

    /// The contiguous run of the epoch's spans intersecting the unit's analysis interval.
    /// Contiguity is structural: the epoch's spans tile its analysis interval with no holes.
    private nonisolated static func intersectingSpanIDs(
        start: TimeInterval,
        end: TimeInterval,
        spans: [MeetingAnalysisSpan]
        // nil means unavailable; an empty result means available with no values.
        // swiftlint:disable:next discouraged_optional_collection
    ) -> [String]? {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        let ids = spans.filter {
            min($0.analysisInterval.end, end) - max($0.analysisInterval.start, start) > tolerance
        }.map(\.id)
        return ids.isEmpty ? nil : ids
    }

    private nonisolated enum MaterializedBoundary {
        case start
        case end
    }

    private nonisolated static func analysisTime(
        forMaterializedSeconds seconds: TimeInterval,
        boundary: MaterializedBoundary,
        materialized: MeetingMaterializedEpoch,
        spans: [MeetingAnalysisSpan]
    ) -> TimeInterval? {
        self.analysisTime(
            forMaterializedSeconds: seconds,
            boundary: boundary,
            sampleRate: materialized.sampleRate,
            sampleCount: materialized.samples.count,
            spanSamples: materialized.spanSamples,
            spans: spans
        )
    }

    /// Maps model/provider time through the actual resampled per-span sample ranges. This avoids
    /// accumulating a frame-rounding error at every source-file boundary and then pretending the
    /// concatenated buffer is an exact one-to-one copy of manifest analysis seconds.
    private nonisolated static func analysisTime(
        forMaterializedSeconds seconds: TimeInterval,
        boundary: MaterializedBoundary,
        sampleRate: Double,
        sampleCount: Int,
        spanSamples: [MeetingMaterializedSpanSamples],
        spans: [MeetingAnalysisSpan]
    ) -> TimeInterval? {
        guard seconds.isFinite, sampleRate.isFinite, sampleRate > 0, sampleCount > 0 else { return nil }
        let position = min(max(seconds * sampleRate, 0), Double(sampleCount))
        let probe: Double
        switch boundary {
        case .start:
            probe = min(position, Double(sampleCount).nextDown)
        case .end:
            probe = max(0, position == 0 ? 0 : position.nextDown)
        }
        let mappingsByID = Dictionary(
            spanSamples.map { ($0.spanID, $0.sampleRange) },
            uniquingKeysWith: { first, _ in first }
        )
        let spansByID = Dictionary(spans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let mapping = spanSamples.first(where: {
            Double($0.sampleRange.lowerBound) <= probe && probe < Double($0.sampleRange.upperBound)
        }), let range = mappingsByID[mapping.spanID], let span = spansByID[mapping.spanID], !range.isEmpty
        else { return nil }
        let fraction = min(max(
            (position - Double(range.lowerBound)) / Double(range.count),
            0
        ), 1)
        return span.analysisInterval.start + fraction * span.analysisInterval.duration
    }

    /// Nemotron emits diarization decisions on this cadence (plan §4); a boundary sliver shorter
    /// than one output hop is model noise, not evidence of a second speaker.
    private nonisolated static let nemotronCadenceMaximumFloorSeconds: TimeInterval = 0.08
    private nonisolated static let handoffMaximumWordDurationSeconds: TimeInterval = 0.8
    private nonisolated static let handoffMaximumPreviousWordGapSeconds: TimeInterval = 0.8

    /// Conservative initial product policy for multi-candidate words, isolated here so the ratios
    /// are named and covered at exact boundaries instead of living as unexplained literals.
    private nonisolated enum SpeakerDominancePolicy {
        static let minimumLeaderCoverageFraction: Double = 0.5
        static let maximumRunnerUpCoverageFraction: Double = 0.2
        static let minimumLeaderToRunnerUpRatio: Double = 2.0
    }

    /// The cadence floor scaled down for short words, so an 80ms boundary hop can never be
    /// discarded outright from a 150ms word: never more than 20% of the unit's own duration.
    private nonisolated static func boundaryNoiseThresholdSeconds(duration: TimeInterval) -> TimeInterval {
        min(self.nemotronCadenceMaximumFloorSeconds, 0.2 * duration)
    }

    /// Clips each activity interval to the unit and unions same-token intervals before measuring
    /// coverage, so duplicate or fragmented diarizer segments for one slot never double-count.
    private nonisolated static func coverageSeconds(
        start: TimeInterval,
        end: TimeInterval,
        activity: [MeetingBackendSpeakerActivity]
    ) -> [MeetingBackendSpeakerToken: TimeInterval] {
        var intervalsByToken: [MeetingBackendSpeakerToken: [(start: TimeInterval, end: TimeInterval)]] = [:]
        for entry in activity {
            let clippedStart = max(entry.start, start)
            let clippedEnd = min(entry.end, end)
            guard clippedEnd > clippedStart else { continue }
            intervalsByToken[entry.token, default: []].append((clippedStart, clippedEnd))
        }
        var coverage: [MeetingBackendSpeakerToken: TimeInterval] = [:]
        for (token, intervals) in intervalsByToken {
            coverage[token] = Self.unionDurationSeconds(intervals)
        }
        return coverage
    }

    private nonisolated static func unionDurationSeconds(
        _ intervals: [(start: TimeInterval, end: TimeInterval)]
    ) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var runStart = sorted.first?.start else { return 0 }
        var runEnd = sorted[0].end
        var total: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.start > runEnd {
                total += runEnd - runStart
                runStart = interval.start
                runEnd = interval.end
            } else {
                runEnd = max(runEnd, interval.end)
            }
        }
        total += runEnd - runStart
        return total
    }

    /// Coverage-based slot attribution (plan §4 "Backend-specific overlap dominance"): a candidate
    /// must clear the scaled cadence-noise floor to count at all; a sole surviving candidate
    /// assigns; multiple candidates assign only under a conservative dominance margin, and remain
    /// ambiguous otherwise. `allowDominance` is `false` for the whole-epoch utterance fallback,
    /// which has no word-level precision to justify picking a winner among real candidates.
    nonisolated static func assignment(
        start: TimeInterval,
        end: TimeInterval,
        activity: [MeetingBackendSpeakerActivity],
        allowDominance: Bool
    ) -> MeetingBackendSpeakerAssignment {
        let duration = end - start
        let threshold = Self.boundaryNoiseThresholdSeconds(duration: duration)
        let coverage = Self.coverageSeconds(start: start, end: end, activity: activity)
        let aboveThreshold = coverage.filter { $0.value > threshold }
        let ranked = aboveThreshold.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.label < rhs.key.label
        }

        switch ranked.count {
        case 0:
            return .unassigned
        case 1:
            return .assigned(ranked[0].key)
        default:
            let leader = ranked[0]
            let runnerUp = ranked[1]
            let leaderFraction = duration > 0 ? leader.value / duration : 0
            let runnerUpFraction = duration > 0 ? runnerUp.value / duration : 0
            let decision: MeetingBackendSpeakerAssignment
            if allowDominance,
               leaderFraction >= SpeakerDominancePolicy.minimumLeaderCoverageFraction,
               runnerUpFraction <= SpeakerDominancePolicy.maximumRunnerUpCoverageFraction,
               leader.value >= runnerUp.value * SpeakerDominancePolicy.minimumLeaderToRunnerUpRatio
            {
                decision = .assigned(leader.key)
            } else {
                decision = .ambiguous(ranked.map(\.key).sorted { $0.label < $1.label })
            }
            #if DEBUG
            Self.logMultiCandidateDecision(
                duration: duration,
                candidateCoverageSeconds: ranked.map(\.value),
                decision: decision
            )
            #endif
            return decision
        }
    }

    /// Deliberately simple second pass for short turn-boundary words. The user chose the more
    /// readable handoff behavior despite its known risk for genuine interruption/backchannel
    /// speech. Coverage remains the first-pass authority; this only resolves an otherwise
    /// ambiguous two-slot result with immediate assigned-word context.
    nonisolated static func handoffAssignment(
        _ coverageAssignment: MeetingBackendSpeakerAssignment,
        start: TimeInterval,
        end: TimeInterval,
        activity: [MeetingBackendSpeakerActivity],
        previousAssignedWord: (token: MeetingBackendSpeakerToken, end: TimeInterval)?
    ) -> MeetingBackendSpeakerAssignment {
        guard case let .ambiguous(candidates) = coverageAssignment,
              candidates.count == 2,
              let previousAssignedWord,
              candidates.contains(previousAssignedWord.token)
        else { return coverageAssignment }

        let duration = end - start
        let gap = start - previousAssignedWord.end
        guard duration.isFinite,
              duration > 0,
              duration <= Self.handoffMaximumWordDurationSeconds,
              gap.isFinite,
              gap >= -Self.nemotronCadenceMaximumFloorSeconds,
              gap <= Self.handoffMaximumPreviousWordGapSeconds
        else { return coverageAssignment }

        guard let other = candidates.first(where: { $0 != previousAssignedWord.token }) else {
            return coverageAssignment
        }
        let otherOnsets = activity.compactMap { entry -> TimeInterval? in
            guard entry.token == other,
                  min(entry.end, end) - max(entry.start, start)
                  > MeetingAnalysisManifestSchema.mappingToleranceSeconds
            else { return nil }
            return entry.start
        }
        guard let otherOnset = otherOnsets.min() else { return coverageAssignment }
        let onsetDelta = otherOnset - start
        let resolved: MeetingBackendSpeakerAssignment = abs(onsetDelta)
            <= Self.nemotronCadenceMaximumFloorSeconds
            ? .assigned(other)
            : .assigned(previousAssignedWord.token)

        #if DEBUG
        Self.logHandoffDecision(
            duration: duration,
            previousWordGap: gap,
            otherOnsetDelta: onsetDelta,
            assignedEntrant: abs(onsetDelta) <= Self.nemotronCadenceMaximumFloorSeconds
        )
        #endif
        return resolved
    }

    #if DEBUG
    /// Structured, DEBUG-only measurement of a multi-candidate word decision. Deliberately carries
    /// only durations, coverage seconds and the resulting decision kind — never transcript text,
    /// unit/word identity, file paths, or participant identity.
    private nonisolated static func logMultiCandidateDecision(
        duration: TimeInterval,
        candidateCoverageSeconds: [TimeInterval],
        decision: MeetingBackendSpeakerAssignment
    ) {
        let decisionLabel: String
        switch decision {
        case .assigned: decisionLabel = "dominant"
        case .ambiguous: decisionLabel = "ambiguous"
        case .unassigned: decisionLabel = "unassigned"
        }
        let overlaps = candidateCoverageSeconds
            .map { String(format: "%.3f", $0) }
            .joined(separator: ",")
        DebugLogger.shared.info(
            String(
                format: "[speakerCoverage] duration=%.3fs candidates=%d overlaps=[%@] decision=%@",
                duration,
                candidateCoverageSeconds.count,
                overlaps,
                decisionLabel
            ),
            source: "MeetingParakeetNemotronBackend"
        )
    }

    private nonisolated static func logHandoffDecision(
        duration: TimeInterval,
        previousWordGap: TimeInterval,
        otherOnsetDelta: TimeInterval,
        assignedEntrant: Bool
    ) {
        DebugLogger.shared.info(
            String(
                format: "[speakerHandoff] duration=%.3fs previousGap=%.3fs otherOnsetDelta=%.3fs decision=%@",
                duration,
                previousWordGap,
                otherOnsetDelta,
                assignedEntrant ? "entrant" : "incumbent"
            ),
            source: "MeetingParakeetNemotronBackend"
        )
    }
    #endif
}
