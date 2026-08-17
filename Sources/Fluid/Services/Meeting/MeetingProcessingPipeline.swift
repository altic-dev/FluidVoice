@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

@MainActor
protocol MeetingProcessingControlling: AnyObject {
    func process(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult
}

actor MeetingProcessingSerializationGate {
    static let shared = MeetingProcessingSerializationGate()

    private var isLeased = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var cancelledWaiterIDs: Set<UUID> = []
    // Pending = created but not parked: lets cancelWaiter tell "not yet registered" (tombstone)
    // from "already resumed by release()" (no-op), so tombstones can't accumulate forever.
    private var pendingWaiterIDs: Set<UUID> = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !self.isLeased {
            self.isLeased = true
            return
        }
        let id = UUID()
        self.pendingWaiterIDs.insert(id)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.register(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        guard !self.waiters.isEmpty else {
            self.isLeased = false
            return
        }
        self.waiters.removeFirst().continuation.resume()
    }

    private func register(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        self.pendingWaiterIDs.remove(id)
        if self.cancelledWaiterIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.waiters.append((id, continuation))
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = self.waiters.firstIndex(where: { $0.id == id }) {
            self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if self.pendingWaiterIDs.contains(id) {
            self.cancelledWaiterIDs.insert(id)
        }
    }
}

/// Keeps only one normalized centroid per session speaker. Matching is
/// conservative and one-to-one within each writer chunk to avoid false merges.
nonisolated struct MeetingSpeakerEmbeddingIndex: Sendable {
    nonisolated struct Prototype: Equatable, Sendable {
        var speakerID: SessionSpeakerID
        var embedding: [Float]
        var observationCount: Int
        var averageQuality: Float
    }

    let maximumCosineDistance: Float
    let ambiguityMargin: Float
    private(set) var prototypes: [SessionSpeakerID: Prototype] = [:]

    init(maximumCosineDistance: Float = 0.35, ambiguityMargin: Float = 0.08) {
        self.maximumCosineDistance = maximumCosineDistance
        self.ambiguityMargin = ambiguityMargin
    }

    func bestMatch(
        for embedding: [Float],
        excluding excludedSpeakerIDs: Set<SessionSpeakerID> = []
    ) -> SessionSpeakerID? {
        guard let normalized = Self.normalized(embedding) else { return nil }
        let candidates = self.prototypes.values.compactMap { prototype -> (SessionSpeakerID, Float)? in
            guard !excludedSpeakerIDs.contains(prototype.speakerID),
                  prototype.embedding.count == normalized.count,
                  let distance = Self.cosineDistance(normalized, prototype.embedding)
            else { return nil }
            return (prototype.speakerID, distance)
        }.sorted {
            if $0.1 == $1.1 { return $0.0.uuidString < $1.0.uuidString }
            return $0.1 < $1.1
        }
        guard let closest = candidates.first,
              closest.1 <= self.maximumCosineDistance
        else { return nil }
        if candidates.count > 1, candidates[1].1 - closest.1 < self.ambiguityMargin {
            return nil
        }
        return closest.0
    }

    mutating func observe(
        speakerID: SessionSpeakerID,
        embedding: [Float],
        quality: Float
    ) {
        guard let normalized = Self.normalized(embedding) else { return }
        guard let existing = self.prototypes[speakerID],
              existing.embedding.count == normalized.count
        else {
            self.prototypes[speakerID] = Prototype(
                speakerID: speakerID,
                embedding: normalized,
                observationCount: 1,
                averageQuality: max(0, min(1, quality))
            )
            return
        }

        let nextCount = existing.observationCount + 1
        let retainedCount = min(existing.observationCount, 31)
        let divisor = Float(retainedCount + 1)
        let combined = zip(existing.embedding, normalized).map {
            ($0 * Float(retainedCount) + $1) / divisor
        }
        guard let updatedEmbedding = Self.normalized(combined) else { return }
        let boundedQuality = max(0, min(1, quality))
        let averageQuality = (
            existing.averageQuality * Float(existing.observationCount) + boundedQuality
        ) / Float(nextCount)
        self.prototypes[speakerID] = Prototype(
            speakerID: speakerID,
            embedding: updatedEmbedding,
            observationCount: nextCount,
            averageQuality: averageQuality
        )
    }

    func prototype(for speakerID: SessionSpeakerID) -> Prototype? {
        self.prototypes[speakerID]
    }

    var speakerIDs: Set<SessionSpeakerID> {
        Set(self.prototypes.keys)
    }

    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for (left, right) in zip(lhs, rhs) {
            guard left.isFinite, right.isFinite else { return nil }
            dot += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return nil }
        return 1 - max(-1, min(1, dot / sqrt(lhsNorm * rhsNorm)))
    }

    // swiftlint:disable:next discouraged_optional_collection
    private static func normalized(_ embedding: [Float]) -> [Float]? {
        guard let distance = cosineDistance(embedding, embedding), distance.isFinite else { return nil }
        let magnitude = sqrt(embedding.reduce(Float.zero) { $0 + $1 * $1 })
        guard magnitude > 0, magnitude.isFinite else { return nil }
        return embedding.map { $0 / magnitude }
    }
}

nonisolated enum MeetingTurnSelection {
    /// Drops empty-text turns; nil when all were empty (caller falls back to whole-chunk).
    static func keepingNonEmpty<T>(
        _ turns: [(index: Int, turn: T, text: String)]
    ) -> [(index: Int, turn: T, text: String)]? {
        let nonEmpty = turns.filter { !$0.text.isEmpty }
        return nonEmpty.isEmpty ? nil : nonEmpty
    }
}

/// Separates near-field speech (the user, inches from a personal mic) from far-field sound the same
/// mic also hears — a TV across the room, the laptop speakers. Both are real speech, so a VAD passes
/// both; only level separates them. Measured on a real session: user 0.0287 RMS (-30.8 dBFS) against
/// room audio at 0.0023 (-52.4 dBFS).
///
/// The reference is the track's own loud end rather than an absolute dBFS value, so the rule travels
/// across microphones and gain settings. It degrades safely: when a track holds nothing but distant
/// audio the reference anchors on that audio and nothing is gated.
nonisolated enum MeetingNearFieldGate {
    /// Far enough below the user's own voice to clear room audio, with room to spare for their
    /// quieter moments — the measured gap is 22 dB.
    static let rejectionDepthDB: Double = 15
    /// Nothing this quiet is intelligible near-field speech on any hardware; a backstop for tracks
    /// whose loud end is itself noise.
    static let absoluteFloorRMS: Double = 0.0015
    /// Below this the reference is not a reliable picture of how loud the user gets.
    static let minimumReferenceSeconds: TimeInterval = 3

    /// Duration-weighted 75th percentile of turn loudness: robust to a handful of loud transients
    /// without being dragged down by long stretches of quiet.
    static func referenceRMS(turns: [(rms: Double, duration: TimeInterval)]) -> Double? {
        let usable = turns.filter { $0.rms > 0 && $0.duration > 0 }
        guard usable.reduce(0, { $0 + $1.duration }) >= Self.minimumReferenceSeconds else { return nil }
        let sorted = usable.sorted { $0.rms < $1.rms }
        let total = sorted.reduce(0) { $0 + $1.duration }
        var accumulated: TimeInterval = 0
        for entry in sorted {
            accumulated += entry.duration
            if accumulated >= total * 0.75 { return entry.rms }
        }
        return sorted.last?.rms
    }

    static func isNearField(rms: Double, reference: Double?) -> Bool {
        guard rms >= Self.absoluteFloorRMS else { return false }
        guard let reference, reference > 0 else { return true }
        return rms >= reference * pow(10, -Self.rejectionDepthDB / 20)
    }
}

nonisolated enum MeetingLocalSpeakerEvidenceSelector {
    static func candidate(
        evidenceDurationByCluster: [SessionSpeakerID: TimeInterval],
        prototypeSpeakerIDs: Set<SessionSpeakerID>
    ) -> SessionSpeakerID? {
        let ranked = evidenceDurationByCluster
            .filter { $0.value >= 1 && prototypeSpeakerIDs.contains($0.key) }
            .sorted {
                if $0.value == $1.value { return $0.key.uuidString < $1.key.uuidString }
                return $0.value > $1.value
            }
        guard let strongest = ranked.first else { return nil }
        guard ranked.count > 1 else { return strongest.key }
        let runnerUpDuration = ranked[1].value
        guard strongest.value >= max(runnerUpDuration * 1.75, runnerUpDuration + 2) else {
            return nil
        }
        return strongest.key
    }
}

@MainActor
private final class MeetingProviderLanguagePin {
    private enum Desired {
        case none
        case apple(String)
        case cohere(SettingsStore.CohereLanguage)
        case nemotron(SettingsStore.NemotronLanguage)
    }

    private enum Restoration {
        case none
        case apple(String)
        case cohere(SettingsStore.CohereLanguage)
        case nemotron(SettingsStore.NemotronLanguage)
    }

    let languageCode: String
    private let settings: SettingsStore
    private let desired: Desired
    private let restoration: Restoration

    init?(languageCode: String, model: SettingsStore.SpeechModel, settings: SettingsStore) {
        guard let route = VoiceEngineLanguageCatalog.routes(
            forLanguageID: languageCode,
            availableModels: [model]
        ).first else { return nil }
        self.languageCode = route.language.id
        self.settings = settings
        switch route.binding {
        case .automatic, .whisper:
            self.desired = .none
            self.restoration = .none
        case let .appleSpeech(localeIdentifier):
            self.desired = .apple(localeIdentifier)
            self.restoration = .apple(settings.selectedAppleSpeechLocaleIdentifier)
        case let .cohere(language):
            self.desired = .cohere(language)
            self.restoration = .cohere(settings.selectedCohereLanguage)
        case let .nemotron(language):
            self.desired = .nemotron(language)
            self.restoration = .nemotron(settings.selectedNemotronLanguage)
        }
        self.apply()
    }

    func apply() {
        switch self.desired {
        case .none: break
        case let .apple(identifier): self.settings.selectedAppleSpeechLocaleIdentifier = identifier
        case let .cohere(language): self.settings.selectedCohereLanguage = language
        case let .nemotron(language): self.settings.selectedNemotronLanguage = language
        }
    }

    func restore() {
        switch self.restoration {
        case .none:
            break
        case let .apple(identifier):
            self.settings.selectedAppleSpeechLocaleIdentifier = identifier
        case let .cohere(language):
            self.settings.selectedCohereLanguage = language
        case let .nemotron(language):
            self.settings.selectedNemotronLanguage = language
        }
    }
}

@MainActor
final class MeetingProcessingPipeline: MeetingProcessingControlling {
    /// Bump whenever classification rules change so a resumed run can't mix rules mid-session.
    static let pipelineVersion = 6
    /// Per-turn engines starve on short turns, and an all-empty chunk collapses to unlabeled.
    static let perTurnTurnMergeGapSeconds = 5.0

    /// Gap alone produced ~59s turns, too coarse to attribute. Bound the length as well.
    static let meetingTurnMaxSeconds = 30.0


    nonisolated static func turnMergeGapSeconds(supportsWordTimings: Bool) -> TimeInterval {
        supportsWordTimings ? Self.meetingTurnMergeGapSeconds : Self.perTurnTurnMergeGapSeconds
    }

    /// Claiming the whole chunk marks every concurrent mic turn as overlapping remote, erasing
    /// the clean-speech evidence that identifies "You".
    nonisolated static func isEmptyTurnFallback(_ error: Error) -> Bool {
        if case LabeledPassError.emptyTurn = error { return true }
        return false
    }

    /// On speakers nearly everything overlaps, so overlap cannot identify the mic's owner.
    /// What can: speech that is not the far end coming back.
    nonisolated static func localSpeakerEvidence(
        from turns: [(
            clusterID: SessionSpeakerID, start: TimeInterval, end: TimeInterval,
            overlapsRemote: Bool, echoScored: Bool, isEcho: Bool
        )]
    ) -> [SessionSpeakerID: TimeInterval] {
        var supporting: [SessionSpeakerID: TimeInterval] = [:]
        var echoed: [SessionSpeakerID: TimeInterval] = [:]
        for turn in turns {
            let duration = max(0, turn.end - turn.start)
            if turn.isEcho {
                echoed[turn.clusterID, default: 0] += duration
                continue
            }
            guard !turn.overlapsRemote || turn.echoScored else { continue }
            supporting[turn.clusterID, default: 0] += duration
        }
        return supporting.filter { $0.value > (echoed[$0.key] ?? 0) }
    }

    /// Reads `isLikelyEcho` (text-only), never `effectiveEcho`: signal evidence must not
    /// influence which cluster gets elected "You".
    nonisolated static func selectLocalCluster(
        from turns: [StagedMicrophoneTurn],
        prototypeSpeakerIDs: Set<SessionSpeakerID>
    ) -> SessionSpeakerID? {
        MeetingLocalSpeakerEvidenceSelector.candidate(
            evidenceDurationByCluster: Self.localSpeakerEvidence(
                from: turns.map {
                    (
                        clusterID: $0.clusterID, start: $0.start, end: $0.end,
                        overlapsRemote: $0.overlapsRemote, echoScored: $0.echoScored,
                        isEcho: $0.isLikelyEcho
                    )
                }
            ),
            prototypeSpeakerIDs: prototypeSpeakerIDs
        )
    }

    /// Why "You" was or was not elected. Without this the only visible symptom is an entire
    /// microphone track collapsing to "Microphone / Unknown", which has several distinct causes.
    nonisolated static func logLocalSpeakerElection(
        turns: [StagedMicrophoneTurn],
        prototypeSpeakerIDs: Set<SessionSpeakerID>,
        index: MeetingSpeakerEmbeddingIndex?,
        role: MeetingMicrophoneRole,
        elected: SessionSpeakerID?
    ) {
        var supporting: [SessionSpeakerID: TimeInterval] = [:]
        var echoed: [SessionSpeakerID: TimeInterval] = [:]
        var skipped: [SessionSpeakerID: TimeInterval] = [:]
        for turn in turns {
            let duration = max(0, turn.end - turn.start)
            if turn.isLikelyEcho {
                echoed[turn.clusterID, default: 0] += duration
            } else if turn.overlapsRemote, !turn.echoScored {
                skipped[turn.clusterID, default: 0] += duration
            } else {
                supporting[turn.clusterID, default: 0] += duration
            }
        }
        let clusters = Set(supporting.keys).union(echoed.keys).union(skipped.keys)
        let rows = clusters
            .map { id -> String in
                let s = supporting[id] ?? 0, e = echoed[id] ?? 0, k = skipped[id] ?? 0
                let proto = prototypeSpeakerIDs.contains(id) ? "yes" : "NO"
                return String(
                    format: "%@ supporting=%.1fs echoed=%.1fs unscoredOverlap=%.1fs prototype=%@ netEvidence=%@",
                    id.uuidString.prefix(8).description, s, e, k, proto, s > e ? "counts" : "DROPPED"
                )
            }
            .sorted()
        // Pairwise prototype distance across the clusters that survived the echo filter: two
        // fragments of one voice are what blocks the winner-margin rule from electing "You".
        var distances: [String] = []
        if let index {
            let survivors = clusters.filter { (supporting[$0] ?? 0) > (echoed[$0] ?? 0) }.sorted {
                $0.uuidString < $1.uuidString
            }
            for (offset, left) in survivors.enumerated() {
                for right in survivors.dropFirst(offset + 1) {
                    guard let a = index.prototypes[left]?.embedding,
                          let b = index.prototypes[right]?.embedding,
                          let distance = MeetingSpeakerEmbeddingIndex.cosineDistance(a, b)
                    else { continue }
                    distances.append(String(
                        format: "%@↔%@ cosineDistance=%.3f (mergeThreshold=%.2f) %@",
                        left.uuidString.prefix(8).description, right.uuidString.prefix(8).description,
                        distance, index.maximumCosineDistance,
                        distance <= index.maximumCosineDistance ? "SAME VOICE" : "different"
                    ))
                }
            }
        }
        DebugLogger.shared.info(
            "Local speaker election (role=\(role), elected=\(elected?.uuidString.prefix(8).description ?? "none")):\n  "
                + rows.joined(separator: "\n  ")
                + (distances.isEmpty ? "" : "\n  " + distances.joined(separator: "\n  ")),
            source: "MeetingProcessingPipeline"
        )
    }

    /// Drops turns the microphone only heard at a distance. They are not echo — a TV or another
    /// room never matches the far end's words — so nothing downstream can catch them, and left in
    /// they form a rival cluster that outweighs the user and blocks the "You" election entirely.
    nonisolated static func rejectingFarField(_ turns: [StagedMicrophoneTurn]) -> [StagedMicrophoneTurn] {
        let measured = turns.filter { $0.rms > 0 }
        guard !measured.isEmpty else { return turns }
        let reference = MeetingNearFieldGate.referenceRMS(
            turns: measured.map { (rms: $0.rms, duration: max(0, $0.end - $0.start)) }
        )
        var kept: [StagedMicrophoneTurn] = []
        var rejected: [StagedMicrophoneTurn] = []
        for turn in turns {
            // An unmeasured turn is kept: absence of a measurement is not evidence of distance.
            if turn.rms <= 0 || MeetingNearFieldGate.isNearField(rms: turn.rms, reference: reference) {
                kept.append(turn)
            } else {
                rejected.append(turn)
            }
        }
        guard !rejected.isEmpty else { return turns }
        let rejectedSeconds = rejected.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        DebugLogger.shared.info(
            String(
                format: "Near-field gate: dropped %d of %d microphone turns (%.1fs) below reference %.5f RMS − %.0f dB",
                rejected.count, turns.count, rejectedSeconds, reference ?? 0, MeetingNearFieldGate.rejectionDepthDB
            ),
            source: "MeetingProcessingPipeline"
        )
        return kept
    }

    /// Reads the chunk once and measures each turn's RMS. Failure degrades to zeros, which the gate
    /// treats as unmeasured rather than as silence.
    nonisolated static func turnLoudness(
        fileURL: URL,
        turns: [(start: TimeInterval, end: TimeInterval)]
    ) -> [Double] {
        guard let samples = try? Self.readSamples(fileURL: fileURL, startSeconds: 0, endSeconds: nil),
              !samples.isEmpty
        else { return Array(repeating: 0, count: turns.count) }
        let sampleRate = 16_000.0
        return turns.map { turn in
            let first = max(0, Int(turn.start * sampleRate))
            let last = min(samples.count, Int(turn.end * sampleRate))
            guard last > first else { return 0 }
            let sum = samples[first..<last].reduce(0.0) { $0 + Double($1) * Double($1) }
            return (sum / Double(last - first)).squareRoot()
        }
    }

    nonisolated static func remoteFallbackIntervals(
        diarizedTurns: [(start: TimeInterval, end: TimeInterval)],
        chunkOffset: TimeInterval,
        chunkDuration: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        guard !diarizedTurns.isEmpty else {
            return [(start: chunkOffset, end: chunkOffset + chunkDuration)]
        }
        return diarizedTurns.map { (start: chunkOffset + $0.start, end: chunkOffset + $0.end) }
    }

    /// Conversational pauses run to a few seconds; 1.0s fragmented turns and starved the ASR.
    static let meetingTurnMergeGapSeconds = 3.0

    private enum LabeledPassError: Error {
        case emptyTurn
    }

    private struct TimelineInterval {
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Internal (not private) so tests can exercise `effectiveEcho` and local-speaker selection
    /// directly against the pure helpers below.
    struct StagedMicrophoneTurn {
        var chunkID: MeetingAudioChunkID
        var index: Int
        var clusterID: SessionSpeakerID
        var clusterLabel: String
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var overlapsRemote: Bool
        /// Loudness of this turn's microphone audio, for the near-field gate. Zero when unmeasured.
        var rms: Double = 0
        /// Text-only, from `MeetingEchoDetector`. `localSpeakerEvidence` must keep reading this
        /// field, never `effectiveEcho` — signal evidence must not influence local-speaker
        /// election, or a misclassification could elect the far-end cluster as "You".
        var isLikelyEcho = false
        /// False when nothing scoreable overlapped: absence of a verdict is not evidence.
        var echoScored = false
        var signalVerdict: TurnEchoVerdict = .unknown
        /// What the UI and exporter hide. Text and signal each get to say "echo", because they fail
        /// independently: ASR garbles bleed differently from the far end's own transcript, defeating
        /// text matching, while the signal reads it plainly (measured median 0.91 explained). Either
        /// one is then vetoed by evidence of genuine local speech in the same turn.
        ///
        /// `isLikelyEcho` stays text-only and remains the sole input to the local-speaker election —
        /// signal evidence must never reach it, or a misclassification could elect the far-end
        /// cluster as "You" through the 1.75x winner rule.
        var effectiveEcho: Bool {
            (self.isLikelyEcho || self.signalVerdict == .echo) && self.signalVerdict != .containsLocalSpeech
        }
    }

    // MARK: - Echo signal veto

    nonisolated struct ReferenceSpan: Equatable {
        var chunk: MeetingAudioChunk
        var localRange: Range<TimeInterval>
        var outputOffset: TimeInterval
    }

    /// Session time -> each app chunk's own decoded coordinates, keyed off `presentationStart`.
    /// The two writers rotate independently and diverge permanently after a discontinuity on
    /// either track, so app chunk N never lines up with mic chunk N.
    nonisolated static func referenceSpans(
        micSessionRange: (start: TimeInterval, end: TimeInterval),
        appChunks: [MeetingAudioChunk],
        origin: TimeInterval
    ) -> [ReferenceSpan] {
        appChunks.compactMap { chunk in
            let chunkStart = chunk.presentationStart.seconds - origin
            let chunkEnd = chunk.presentationEnd.seconds - origin
            let overlapStart = max(chunkStart, micSessionRange.start)
            let overlapEnd = min(chunkEnd, micSessionRange.end)
            guard overlapEnd > overlapStart else { return nil }
            return ReferenceSpan(
                chunk: chunk,
                localRange: (overlapStart - chunkStart)..<(overlapEnd - chunkStart),
                outputOffset: overlapStart - micSessionRange.start
            )
        }
    }

    /// Concatenates the decoded slices for a mic chunk's time range, zero-filling any gap
    /// (missing chunk, failed chunk, or a hole between chunks). Zero-fill is self-masking: a
    /// zero-filled block has no reference energy, so the scorer's own floor already forces
    /// those frames to NaN — no separate validity mask is needed.
    nonisolated static func gatherReferenceAudio(
        micSessionRange: (start: TimeInterval, end: TimeInterval),
        appChunks: [MeetingAudioChunk],
        origin: TimeInterval,
        sessionDirectory: URL,
        sampleRate: Double
    ) -> [Float] {
        let totalSamples = max(0, Int(((micSessionRange.end - micSessionRange.start) * sampleRate).rounded()))
        guard totalSamples > 0 else { return [] }
        var output = [Float](repeating: 0, count: totalSamples)
        for span in Self.referenceSpans(micSessionRange: micSessionRange, appChunks: appChunks, origin: origin) {
            guard let samples = try? Self.readSamples(
                fileURL: span.chunk.fileURL(relativeTo: sessionDirectory),
                startSeconds: span.localRange.lowerBound,
                endSeconds: span.localRange.upperBound
            ) else { continue }
            let outStart = Int((span.outputOffset * sampleRate).rounded())
            for (offset, sample) in samples.enumerated() {
                let index = outStart + offset
                guard index >= 0, index < output.count else { break }
                output[index] = sample
            }
        }
        return output
    }

    /// Guard interval around each recorded discontinuity on either track, excluded from both
    /// delay estimation and scoring so a clock jump isn't read as correlated (or decorrelated) audio.
    nonisolated static func discontinuityGuardIntervals(
        micChunk: MeetingAudioChunk,
        overlappingAppChunks: [MeetingAudioChunk],
        origin: TimeInterval,
        guardSeconds: TimeInterval
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        (micChunk.discontinuities + overlappingAppChunks.flatMap(\.discontinuities)).compactMap { discontinuity in
            guard let presentationTime = discontinuity.presentationTime else { return nil }
            let time = presentationTime.seconds - origin
            return (time - guardSeconds, time + guardSeconds)
        }
    }

    nonisolated static func zeroingGuardedSamples(
        _ samples: [Float],
        chunkOffset: TimeInterval,
        sampleRate: Double,
        guardIntervals: [(start: TimeInterval, end: TimeInterval)]
    ) -> [Float] {
        guard !guardIntervals.isEmpty else { return samples }
        var result = samples
        for interval in guardIntervals {
            let startIndex = max(0, Int(((interval.start - chunkOffset) * sampleRate).rounded()))
            let endIndex = min(samples.count, Int(((interval.end - chunkOffset) * sampleRate).rounded()))
            guard startIndex < endIndex else { continue }
            for index in startIndex..<endIndex { result[index] = 0 }
        }
        return result
    }

    /// Post-hoc NaN mask rather than zeroing the scorer's inputs: zeroing would corrupt the
    /// block-level fit for the valid frames sharing a block with a guarded one.
    nonisolated static func maskingGuardedFrames(
        _ scores: EchoFrameScores,
        chunkOffset: TimeInterval,
        sampleRate: Double,
        guardIntervals: [(start: TimeInterval, end: TimeInterval)]
    ) -> EchoFrameScores {
        guard !guardIntervals.isEmpty else { return scores }
        let frameSeconds = Double(MeetingEchoSignalScorer.frameLength) / sampleRate
        var fractions = scores.fractions
        for index in fractions.indices {
            let frameStart = chunkOffset + Double(index) * scores.hopSeconds
            let frameEnd = frameStart + frameSeconds
            if guardIntervals.contains(where: { max($0.start, frameStart) < min($0.end, frameEnd) }) {
                fractions[index] = .nan
            }
        }
        return EchoFrameScores(fractions: fractions, hopSeconds: scores.hopSeconds)
    }

    /// Frames whose window overlaps the turn's span; the result is contiguous because frame
    /// time is monotonic in index.
    nonisolated static func turnVerdict(
        _ scores: EchoFrameScores,
        chunkOffset: TimeInterval,
        turnStart: TimeInterval,
        turnEnd: TimeInterval,
        sampleRate: Double
    ) -> TurnEchoVerdict {
        let frameSeconds = Double(MeetingEchoSignalScorer.frameLength) / sampleRate
        let overlapping = scores.fractions.indices.filter { index in
            let frameStart = chunkOffset + Double(index) * scores.hopSeconds
            let frameEnd = frameStart + frameSeconds
            return frameEnd > turnStart && frameStart < turnEnd
        }
        guard !overlapping.isEmpty else { return .unknown }
        let subset = EchoFrameScores(fractions: overlapping.map { scores.fractions[$0] }, hopSeconds: scores.hopSeconds)
        let result = MeetingEchoSignalScorer.verdict(subset)
        Self.logTurnFrameStats(subset, turnStart: turnStart, turnEnd: turnEnd, verdict: result)
        return result
    }

    /// Frame-level picture behind a turn's verdict. The rescue rule uses an absolute low-run
    /// threshold, so long turns need their run length read as a share of the turn, not in seconds.
    nonisolated static func logTurnFrameStats(
        _ scores: EchoFrameScores,
        turnStart: TimeInterval,
        turnEnd: TimeInterval,
        verdict: TurnEchoVerdict
    ) {
        let scoreable = scores.fractions.filter { !$0.isNaN }
        guard !scoreable.isEmpty else { return }
        let sorted = scoreable.sorted()
        let median = sorted[sorted.count / 2]
        var longestLowRun = 0
        var currentRun = 0
        for value in scores.fractions {
            if !value.isNaN, value < MeetingEchoSignalScorer.localSpeechFractionThreshold {
                currentRun += 1
                longestLowRun = max(longestLowRun, currentRun)
            } else if !value.isNaN {
                currentRun = 0
            }
        }
        let turnSeconds = max(0.001, turnEnd - turnStart)
        let lowRunSeconds = Double(longestLowRun) * scores.hopSeconds
        DebugLogger.shared.info(
            String(
                format: "[echoframes] turn=[%.1f-%.1f] %.1fs median=%.2f scoreable=%.0f%% lowRun=%.2fs (%.1f%% of turn) verdict=%@",
                turnStart, turnEnd, turnSeconds, median,
                100 * Double(scoreable.count) / Double(scores.fractions.count),
                lowRunSeconds, 100 * lowRunSeconds / turnSeconds, String(describing: verdict)
            ),
            source: "MeetingProcessingPipeline"
        )
    }

    /// A capture epoch ends at any discontinuity on either track; a rolling delay consensus must
    /// never survive one — measured drift (~6.4 ppm, ~23ms/hour) makes a stale offset wrong on
    /// the far side of a jump.
    nonisolated static func epochBoundaries(
        micChunks: [MeetingAudioChunk],
        appChunks: [MeetingAudioChunk],
        origin: TimeInterval
    ) -> [TimeInterval] {
        (micChunks + appChunks).flatMap { chunk in
            chunk.discontinuities.compactMap { $0.presentationTime.map { $0.seconds - origin } }
        }.sorted()
    }

    private struct EchoDelayEpochState {
        var boundaries: [TimeInterval]
        var boundaryIndex = 0
        var acceptedDelays: [TimeInterval] = []

        mutating func advance(toChunkEnd chunkEnd: TimeInterval) {
            while self.boundaryIndex < self.boundaries.count, self.boundaries[self.boundaryIndex] <= chunkEnd {
                self.acceptedDelays.removeAll()
                self.boundaryIndex += 1
            }
        }
    }

    /// No confident per-chunk estimate and no consensus yet (e.g. the first chunks of a quiet
    /// meeting) leaves the verdict `.unknown` for that chunk — acceptable, since `.unknown`
    /// never vetoes.
    nonisolated static func resolvedDelay(
        estimate: DelayEstimate?,
        acceptedDelaysInEpoch: [TimeInterval]
    ) -> TimeInterval? {
        if let estimate, estimate.confidence >= MeetingEchoSignalScorer.minimumDelayConfidence {
            return estimate.seconds
        }
        guard !acceptedDelaysInEpoch.isEmpty else { return nil }
        return MeetingEchoSignalScorer.median(acceptedDelaysInEpoch)
    }

    nonisolated struct EchoScoringOutcome {
        var verdicts: [Int: TurnEchoVerdict]
        var acceptedDelaySeconds: TimeInterval?
    }

    /// Every failure here (missing/corrupt reference audio, decode errors, bad timing math, ...)
    /// degrades to `.unknown` rather than propagating: a sick application-audio track must never
    /// take down an otherwise-healthy microphone chunk.
    nonisolated static func computeEchoVerdicts(
        micChunk: MeetingAudioChunk,
        micChunkURL: URL,
        chunkOffset: TimeInterval,
        chunkDuration: TimeInterval,
        turns: [(index: Int, start: TimeInterval, end: TimeInterval)],
        applicationTrack: MeetingAudioTrack,
        origin: TimeInterval,
        sessionDirectory: URL,
        acceptedDelaysInEpoch: [TimeInterval]
    ) throws -> EchoScoringOutcome {
        let sampleRate = 16_000.0
        let micSamples = try Self.readSamples(fileURL: micChunkURL, startSeconds: 0, endSeconds: nil)
        guard !micSamples.isEmpty else { return EchoScoringOutcome(verdicts: [:], acceptedDelaySeconds: nil) }

        let micSessionRange = (start: chunkOffset, end: chunkOffset + chunkDuration)
        let referenceSamples = Self.gatherReferenceAudio(
            micSessionRange: micSessionRange,
            appChunks: applicationTrack.chunks,
            origin: origin,
            sessionDirectory: sessionDirectory,
            sampleRate: sampleRate
        )

        let overlappingAppChunks = applicationTrack.chunks.filter { appChunk in
            let start = appChunk.presentationStart.seconds - origin
            let end = appChunk.presentationEnd.seconds - origin
            return end > micSessionRange.start && start < micSessionRange.end
        }
        let guardIntervals = Self.discontinuityGuardIntervals(
            micChunk: micChunk,
            overlappingAppChunks: overlappingAppChunks,
            origin: origin,
            guardSeconds: MeetingEchoSignalScorer.blockSeconds
        )

        let guardedMic = Self.zeroingGuardedSamples(micSamples, chunkOffset: chunkOffset, sampleRate: sampleRate, guardIntervals: guardIntervals)
        let guardedReference = Self.zeroingGuardedSamples(referenceSamples, chunkOffset: chunkOffset, sampleRate: sampleRate, guardIntervals: guardIntervals)
        let estimate = MeetingEchoSignalScorer.estimateDelay(
            mic: guardedMic, reference: guardedReference, sampleRate: sampleRate, maxLagSeconds: 0.5
        )
        guard let delaySeconds = Self.resolvedDelay(estimate: estimate, acceptedDelaysInEpoch: acceptedDelaysInEpoch) else {
            return EchoScoringOutcome(verdicts: [:], acceptedDelaySeconds: nil)
        }
        let acceptedDelaySeconds = (estimate?.confidence ?? 0) >= MeetingEchoSignalScorer.minimumDelayConfidence
            ? estimate?.seconds
            : nil

        let rawScores = MeetingEchoSignalScorer.explainedFractions(
            mic: micSamples, reference: referenceSamples, sampleRate: sampleRate, delaySeconds: delaySeconds
        )
        let scores = Self.maskingGuardedFrames(rawScores, chunkOffset: chunkOffset, sampleRate: sampleRate, guardIntervals: guardIntervals)

        var verdicts: [Int: TurnEchoVerdict] = [:]
        for turn in turns {
            verdicts[turn.index] = Self.turnVerdict(
                scores, chunkOffset: chunkOffset, turnStart: turn.start, turnEnd: turn.end, sampleRate: sampleRate
            )
        }
        return EchoScoringOutcome(verdicts: verdicts, acceptedDelaySeconds: acceptedDelaySeconds)
    }

    private struct Accumulator {
        var speakers: [MeetingSessionSpeaker] = []
        var segments: [MeetingTranscriptSegment] = []
        var speakerIDByKey: [String: SessionSpeakerID] = [:]
        var embeddingIndexByTrack: [MeetingAudioTrackKind: MeetingSpeakerEmbeddingIndex] = [:]
        var nextRemoteSpeaker = 1
        var nextMicrophoneSpeaker = 1

        mutating func speaker(
            key: String,
            displayName: @autoclosure () -> String,
            trackKind: MeetingAudioTrackKind,
            isLocalUser: Bool,
            clusterID: String?
        ) -> SessionSpeakerID {
            if let existing = self.speakerIDByKey[key] { return existing }
            let id = MeetingProcessingPipeline.stableUUID("speaker:\(key)")
            self.speakerIDByKey[key] = id
            self.speakers.append(MeetingSessionSpeaker(
                id: id,
                displayName: displayName(),
                diarizationClusterID: clusterID,
                trackKind: trackKind,
                isLocalUser: isLocalUser,
                identityCandidates: []
            ))
            return id
        }

        mutating func resolveCluster(
            trackKind: MeetingAudioTrackKind,
            newClusterKey: String,
            profile: SpeakerDiarizationService.SpeakerProfile?,
            excluding: Set<SessionSpeakerID>
        ) -> (speakerID: SessionSpeakerID, matchedExisting: Bool) {
            var index = self.embeddingIndexByTrack[trackKind] ?? MeetingSpeakerEmbeddingIndex()
            let existing = profile.flatMap {
                index.bestMatch(for: $0.embedding, excluding: excluding)
            }
            let speakerID = existing ?? MeetingProcessingPipeline.stableUUID("speaker:\(newClusterKey)")
            if let profile {
                index.observe(
                    speakerID: speakerID,
                    embedding: profile.embedding,
                    quality: profile.averageQuality
                )
            }
            self.embeddingIndexByTrack[trackKind] = index
            return (speakerID, existing != nil)
        }

        mutating func addResolvedSpeaker(
            id: SessionSpeakerID,
            key: String,
            displayName: String,
            clusterID: String?,
            trackKind: MeetingAudioTrackKind,
            isLocalUser: Bool
        ) {
            let prototype = self.embeddingIndexByTrack[trackKind]?.prototype(for: id)
            if let existingIndex = self.speakers.firstIndex(where: { $0.id == id }) {
                self.speakers[existingIndex].diarizationEmbedding = prototype?.embedding
                self.speakers[existingIndex].diarizationEmbeddingObservationCount = prototype?.observationCount
                self.speakers[existingIndex].diarizationQuality = prototype?.averageQuality
                return
            }
            self.speakerIDByKey[key] = id
            self.speakers.append(MeetingSessionSpeaker(
                id: id,
                displayName: displayName,
                diarizationClusterID: clusterID,
                diarizationEmbedding: prototype?.embedding,
                diarizationEmbeddingObservationCount: prototype?.observationCount,
                diarizationQuality: prototype?.averageQuality,
                trackKind: trackKind,
                isLocalUser: isLocalUser,
                identityCandidates: []
            ))
        }
    }

    private struct ProcessingContext {
        let origin: TimeInterval
        let sessionDirectory: URL
        let provider: any TranscriptionProvider
        let languageCode: String
        let asrService: ASRService
        let languagePin: MeetingProviderLanguagePin
    }

    private let asrServiceProvider: @MainActor () -> ASRService
    private let serializationGate: MeetingProcessingSerializationGate

    init(
        asrServiceProvider: @escaping @MainActor () -> ASRService,
        serializationGate: MeetingProcessingSerializationGate = .shared
    ) {
        self.asrServiceProvider = asrServiceProvider
        self.serializationGate = serializationGate
    }

    func process(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        guard session.languageCode == "en" else {
            throw MeetingProcessingError.unsupportedLanguage
        }
        guard session.audioTracks.contains(where: { !$0.chunks.isEmpty }) else {
            throw MeetingProcessingError.noRecoverableAudio
        }

        try await self.serializationGate.acquire()
        do {
            let result = try await self.processWithLease(
                session: session,
                sessionDirectory: sessionDirectory,
                progress: progress
            )
            await self.serializationGate.release()
            return result
        } catch {
            await self.serializationGate.release()
            throw error
        }
    }

    private func processWithLease(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        let asrService = self.asrServiceProvider()
        guard !asrService.isRunning else { throw MeetingProcessingError.dictationActive }

        let selectedModel = SettingsStore.shared.selectedSpeechModel
        guard let languagePin = MeetingProviderLanguagePin(
            languageCode: session.languageCode,
            model: selectedModel,
            settings: .shared
        ) else {
            throw MeetingProcessingError.providerDoesNotSupportLanguage(session.languageCode)
        }
        defer { languagePin.restore() }

        progress(.saving)
        try await asrService.ensureAsrReady()
        let provider = asrService.fileTranscriptionProvider
        guard provider.isReady else { throw MeetingProcessingError.modelUnavailable }

        var attempt = MeetingProcessingAttempt(
            id: session.processingAttempts.last(where: { $0.completedAt == nil })?.id ?? UUID(),
            startedAt: Date(),
            completedAt: nil,
            stage: .identifyingSpeakers,
            pipelineVersion: Self.pipelineVersion,
            asrProvider: provider.name,
            asrModel: selectedModel.rawValue,
            languageCode: languagePin.languageCode,
            diarizationModel: SpeakerDiarizationService.isSupported ? "FluidAudio-offline-v1" : nil,
            lastCompletedTrackID: nil,
            errorCode: nil
        )
        progress(.identifyingSpeakers)

        let origin = session.audioTracks
            .flatMap(\.chunks)
            .map(\.presentationStart.seconds)
            .min() ?? 0
        var accumulator = Accumulator()
        var remoteSpeech: [TimelineInterval] = []
        let expectedFingerprints = MeetingProcessingCheckpoint.fingerprints(for: session.audioTracks)

        let context = ProcessingContext(
            origin: origin,
            sessionDirectory: sessionDirectory,
            provider: provider,
            languageCode: languagePin.languageCode,
            asrService: asrService,
            languagePin: languagePin
        )

        var applicationSkippedChunkIDs: [MeetingAudioChunkID] = []
        var resumedFromCheckpoint = false
        if let applicationTrack = session.audioTracks.first(where: { $0.kind == .applicationAudio }) {
            if let checkpoint = Self.loadCheckpoint(sessionDirectory: sessionDirectory),
               checkpoint.isValid(
                   session: session,
                   pipelineVersion: Self.pipelineVersion,
                   provider: provider.name,
                   model: selectedModel.rawValue,
                   language: languagePin.languageCode,
                   completedTrackID: applicationTrack.id,
                   expectedFingerprints: expectedFingerprints
               )
            {
                accumulator.speakers = checkpoint.speakers
                accumulator.segments = checkpoint.segments
                accumulator.speakerIDByKey = checkpoint.speakerIDByKey
                accumulator.nextRemoteSpeaker = checkpoint.nextRemoteSpeaker
                accumulator.nextMicrophoneSpeaker = checkpoint.nextMicrophoneSpeaker
                remoteSpeech = checkpoint.remoteSpeech.map { TimelineInterval(start: $0.start, end: $0.end) }
                attempt.lastCompletedTrackID = checkpoint.completedTrackID
                resumedFromCheckpoint = true
                DebugLogger.shared.log(
                    "Meeting processing resuming from checkpoint after application track",
                    source: "MeetingProcessingPipeline"
                )
            } else {
                Self.deleteCheckpoint(sessionDirectory: sessionDirectory)
            }

            if !resumedFromCheckpoint {
                try await self.processApplicationTrack(
                    applicationTrack,
                    context: context,
                    accumulator: &accumulator,
                    remoteSpeech: &remoteSpeech,
                    skippedChunkIDs: &applicationSkippedChunkIDs
                )
                attempt.lastCompletedTrackID = applicationTrack.id
                if applicationSkippedChunkIDs.isEmpty {
                    Self.writeCheckpoint(
                        MeetingProcessingCheckpoint(
                            version: MeetingProcessingCheckpoint.currentVersion,
                            sessionID: session.id,
                            pipelineVersion: Self.pipelineVersion,
                            asrProvider: provider.name,
                            asrModel: selectedModel.rawValue,
                            languageCode: languagePin.languageCode,
                            completedTrackID: applicationTrack.id,
                            trackFingerprints: expectedFingerprints,
                            speakers: accumulator.speakers,
                            segments: accumulator.segments,
                            remoteSpeech: remoteSpeech.map { MeetingProcessingCheckpoint.SpeechInterval(start: $0.start, end: $0.end) },
                            speakerIDByKey: accumulator.speakerIDByKey,
                            nextRemoteSpeaker: accumulator.nextRemoteSpeaker,
                            nextMicrophoneSpeaker: accumulator.nextMicrophoneSpeaker
                        ),
                        sessionDirectory: sessionDirectory
                    )
                }
            }
        }

        progress(.transcribing)
        var microphoneSkippedChunkIDs: [MeetingAudioChunkID] = []
        if let microphoneTrack = session.audioTracks.first(where: { $0.kind == .microphone }) {
            try await self.processMicrophoneTrack(
                microphoneTrack,
                session: session,
                context: context,
                remoteSpeech: remoteSpeech,
                accumulator: &accumulator,
                skippedChunkIDs: &microphoneSkippedChunkIDs
            )
            attempt.lastCompletedTrackID = microphoneTrack.id
        }

        let skippedChunkIDs = applicationSkippedChunkIDs + microphoneSkippedChunkIDs
        let totalFinalizedChunkCount = session.audioTracks.reduce(0) {
            $0 + $1.chunks.filter { $0.finalizationState == .finalized }.count
        }
        guard skippedChunkIDs.count < totalFinalizedChunkCount else {
            throw MeetingProcessingError.noRecoverableAudio
        }

        progress(.finalizing)
        accumulator.segments.sort {
            if $0.start == $1.start { return $0.sourceTrackID.uuidString < $1.sourceTrackID.uuidString }
            return $0.start < $1.start
        }
        guard !accumulator.segments.isEmpty else { throw MeetingProcessingError.noSpeech }
        attempt.stage = .completed
        attempt.completedAt = Date()
        progress(.completed)
        return MeetingProcessingResult(
            speakers: accumulator.speakers,
            segments: accumulator.segments,
            attempt: attempt,
            skippedChunkIDs: skippedChunkIDs
        )
    }

    private static let checkpointEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let checkpointDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func checkpointURL(sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
    }

    private static func loadCheckpoint(sessionDirectory: URL) -> MeetingProcessingCheckpoint? {
        guard let data = try? Data(contentsOf: Self.checkpointURL(sessionDirectory: sessionDirectory)) else { return nil }
        return try? Self.checkpointDecoder.decode(MeetingProcessingCheckpoint.self, from: data)
    }

    private static func writeCheckpoint(_ checkpoint: MeetingProcessingCheckpoint, sessionDirectory: URL) {
        let url = Self.checkpointURL(sessionDirectory: sessionDirectory)
        do {
            let data = try Self.checkpointEncoder.encode(checkpoint)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            DebugLogger.shared.warning("Meeting checkpoint write failed: \(error)", source: "MeetingProcessingPipeline")
        }
    }

    private static func deleteCheckpoint(sessionDirectory: URL) {
        try? FileManager.default.removeItem(at: Self.checkpointURL(sessionDirectory: sessionDirectory))
    }

    private func processApplicationTrack(
        _ track: MeetingAudioTrack,
        context: ProcessingContext,
        accumulator: inout Accumulator,
        remoteSpeech: inout [TimelineInterval],
        skippedChunkIDs: inout [MeetingAudioChunkID]
    ) async throws {
        let diarizer = SpeakerDiarizationService()
        for chunk in track.chunks where chunk.finalizationState == .finalized {
            // Snapshot so a mid-chunk partial mutation (e.g. some turns transcribed before an
            // unreadable read) never leaks into the accumulated result for a skipped chunk.
            let accumulatorSnapshot = accumulator
            let remoteSpeechSnapshot = remoteSpeech
            do {
                try await self.processApplicationChunk(
                    chunk,
                    track: track,
                    diarizer: diarizer,
                    context: context,
                    accumulator: &accumulator,
                    remoteSpeech: &remoteSpeech
                )
            } catch {
                if error is CancellationError { throw error }
                guard case MeetingProcessingError.audioUnreadable = error else { throw error }
                accumulator = accumulatorSnapshot
                remoteSpeech = remoteSpeechSnapshot
                skippedChunkIDs.append(chunk.id)
            }
        }
    }

    private func processApplicationChunk(
        _ chunk: MeetingAudioChunk,
        track: MeetingAudioTrack,
        diarizer: SpeakerDiarizationService,
        context: ProcessingContext,
        accumulator: inout Accumulator,
        remoteSpeech: inout [TimelineInterval]
    ) async throws {
        let url = chunk.fileURL(relativeTo: context.sessionDirectory)
        let chunkOffset = chunk.presentationStart.seconds - context.origin
        // Preflight readability once, provider-independent, so a garbage file is skipped
        // uniformly instead of only surfacing via a post-transcription duration read.
        let chunkDuration = try await Task.detached(priority: .userInitiated) {
            try Self.audioDuration(url)
        }.value
        var diarizedSpans: [(start: TimeInterval, end: TimeInterval)] = []
        if SpeakerDiarizationService.isSupported {
            do {
                let diarization = try await diarizer.diarizeWithProfiles(
                    fileURL: url,
                    maxGapSeconds: Self.turnMergeGapSeconds(supportsWordTimings: context.provider.supportsWordTimings),
                    maxTurnSeconds: Self.meetingTurnMaxSeconds
                )
                let turns = diarization.turns
                diarizedSpans = turns.map { (start: $0.startSeconds, end: $0.endSeconds) }
                if !turns.isEmpty {
                    let allTurns = try await self.transcribeTurns(turns, chunkID: chunk.id, trackKind: .applicationAudio, fileURL: url, context: context)
                    guard let transcribedTurns = MeetingTurnSelection.keepingNonEmpty(allTurns) else {
                        throw LabeledPassError.emptyTurn
                    }
                    if transcribedTurns.count < allTurns.count {
                        DebugLogger.shared.log(
                            "Meeting remote transcription chunk \(chunk.id): skipped \(allTurns.count - transcribedTurns.count) of \(allTurns.count) silent turns",
                            source: "MeetingProcessingPipeline"
                        )
                    }
                    // Filtered turns only: a silent turn must not mark a mic turn overlapsRemote.
                    remoteSpeech.append(contentsOf: transcribedTurns.map { _, turn, _ in
                        TimelineInterval(
                            start: chunkOffset + turn.startSeconds,
                            end: chunkOffset + turn.endSeconds
                        )
                    })
                    var speakerIDByLabel: [String: SessionSpeakerID] = [:]
                    var usedSpeakerIDs = Set<SessionSpeakerID>()
                    for (_, turn, _) in transcribedTurns where speakerIDByLabel[turn.speakerLabel] == nil {
                        let resolved = accumulator.resolveCluster(
                            trackKind: .applicationAudio,
                            newClusterKey: "remote:\(chunk.id.uuidString):\(turn.speakerLabel)",
                            profile: diarization.profilesByLabel[turn.speakerLabel],
                            excluding: usedSpeakerIDs
                        )
                        let displayName: String
                        if resolved.matchedExisting {
                            displayName = "Speaker"
                        } else {
                            displayName = "Speaker \(accumulator.nextRemoteSpeaker)"
                            accumulator.nextRemoteSpeaker += 1
                        }
                        accumulator.addResolvedSpeaker(
                            id: resolved.speakerID,
                            key: "remote-cluster:\(resolved.speakerID.uuidString)",
                            displayName: displayName,
                            clusterID: turn.speakerLabel,
                            trackKind: .applicationAudio,
                            isLocalUser: false
                        )
                        speakerIDByLabel[turn.speakerLabel] = resolved.speakerID
                        usedSpeakerIDs.insert(resolved.speakerID)
                    }
                    for (index, turn, text) in transcribedTurns {
                        let absoluteStart = chunkOffset + turn.startSeconds
                        let absoluteEnd = chunkOffset + turn.endSeconds
                        guard let speakerID = speakerIDByLabel[turn.speakerLabel] else { continue }
                        accumulator.segments.append(Self.segment(
                            key: "remote:\(chunk.id.uuidString):\(index)",
                            trackID: track.id,
                            speakerID: speakerID,
                            start: absoluteStart,
                            end: absoluteEnd,
                            text: text,
                            overlap: .none
                        ))
                    }
                    return
                }
            } catch {
                if error is CancellationError { throw error }
                if case MeetingProcessingError.audioUnreadable = error { throw error }
                let reason = Self.isEmptyTurnFallback(error) ? "every turn transcribed empty" : "diarization failed"
                DebugLogger.shared.warning(
                    "Meeting remote chunk \(chunk.id) fell back to an unlabeled transcript (\(reason)): \(error)",
                    source: "MeetingProcessingPipeline"
                )
            }
        }
        if let fallback = try await self.transcribeWholeChunk(
            url,
            provider: context.provider,
            languageCode: context.languageCode,
            asrService: context.asrService,
            languagePin: context.languagePin
        ) {
            let key = "meeting-audio"
            let speakerID = accumulator.speaker(
                key: key,
                displayName: "Meeting audio",
                trackKind: .applicationAudio,
                isLocalUser: false,
                clusterID: nil
            )
            remoteSpeech.append(contentsOf: Self.remoteFallbackIntervals(
                diarizedTurns: diarizedSpans,
                chunkOffset: chunkOffset,
                chunkDuration: chunkDuration
            ).map { TimelineInterval(start: $0.start, end: $0.end) })
            accumulator.segments.append(Self.segment(
                key: "remote-fallback:\(chunk.id.uuidString)",
                trackID: track.id,
                speakerID: speakerID,
                start: chunkOffset,
                end: chunkOffset + chunkDuration,
                text: fallback,
                overlap: .none
            ))
        }
    }

    private func processMicrophoneTrack(
        _ track: MeetingAudioTrack,
        session: MeetingSession,
        context: ProcessingContext,
        remoteSpeech: [TimelineInterval],
        accumulator: inout Accumulator,
        skippedChunkIDs: inout [MeetingAudioChunkID]
    ) async throws {
        let diarizer = SpeakerDiarizationService()
        let applicationTrack = session.audioTracks.first(where: { $0.kind == .applicationAudio })
        var epochState = EchoDelayEpochState(
            boundaries: Self.epochBoundaries(
                micChunks: track.chunks,
                appChunks: applicationTrack?.chunks ?? [],
                origin: context.origin
            )
        )
        var stagedTurns: [StagedMicrophoneTurn] = []
        for chunk in track.chunks where chunk.finalizationState == .finalized {
            let accumulatorSnapshot = accumulator
            let stagedTurnsSnapshot = stagedTurns
            do {
                try await self.processMicrophoneChunk(
                    chunk,
                    track: track,
                    diarizer: diarizer,
                    context: context,
                    remoteSpeech: remoteSpeech,
                    applicationTrack: applicationTrack,
                    epochState: &epochState,
                    accumulator: &accumulator,
                    stagedTurns: &stagedTurns
                )
            } catch {
                if error is CancellationError { throw error }
                guard case MeetingProcessingError.audioUnreadable = error else { throw error }
                accumulator = accumulatorSnapshot
                stagedTurns = stagedTurnsSnapshot
                skippedChunkIDs.append(chunk.id)
            }
        }

        self.finishMicrophoneTrack(
            track,
            session: session,
            stagedTurns: stagedTurns,
            accumulator: &accumulator
        )
    }

    private func processMicrophoneChunk(
        _ chunk: MeetingAudioChunk,
        track: MeetingAudioTrack,
        diarizer: SpeakerDiarizationService,
        context: ProcessingContext,
        remoteSpeech: [TimelineInterval],
        applicationTrack: MeetingAudioTrack?,
        epochState: inout EchoDelayEpochState,
        accumulator: inout Accumulator,
        stagedTurns: inout [StagedMicrophoneTurn]
    ) async throws {
        let url = chunk.fileURL(relativeTo: context.sessionDirectory)
        let chunkOffset = chunk.presentationStart.seconds - context.origin
        let chunkDuration = try await Task.detached(priority: .userInitiated) {
            try Self.audioDuration(url)
        }.value
        epochState.advance(toChunkEnd: chunkOffset + chunkDuration)
        if SpeakerDiarizationService.isSupported {
            do {
                let diarization = try await diarizer.diarizeWithProfiles(
                    fileURL: url,
                    maxGapSeconds: Self.turnMergeGapSeconds(supportsWordTimings: context.provider.supportsWordTimings),
                    maxTurnSeconds: Self.meetingTurnMaxSeconds
                )
                let turns = diarization.turns
                if !turns.isEmpty {
                    let allTurns = try await self.transcribeTurns(turns, chunkID: chunk.id, trackKind: .microphone, fileURL: url, context: context)
                    guard let transcribedTurns = MeetingTurnSelection.keepingNonEmpty(allTurns) else {
                        throw LabeledPassError.emptyTurn
                    }
                    if transcribedTurns.count < allTurns.count {
                        DebugLogger.shared.log(
                            "Meeting microphone transcription chunk \(chunk.id): skipped \(allTurns.count - transcribedTurns.count) of \(allTurns.count) silent turns",
                            source: "MeetingProcessingPipeline"
                        )
                    }
                    var clusterIDByLabel: [String: SessionSpeakerID] = [:]
                    var usedClusterIDs = Set<SessionSpeakerID>()
                    for (_, turn, _) in transcribedTurns where clusterIDByLabel[turn.speakerLabel] == nil {
                        let resolved = accumulator.resolveCluster(
                            trackKind: .microphone,
                            newClusterKey: "microphone:\(chunk.id.uuidString):\(turn.speakerLabel)",
                            profile: diarization.profilesByLabel[turn.speakerLabel],
                            excluding: usedClusterIDs
                        )
                        clusterIDByLabel[turn.speakerLabel] = resolved.speakerID
                        usedClusterIDs.insert(resolved.speakerID)
                    }

                    var signalVerdictByIndex: [Int: TurnEchoVerdict] = [:]
                    if let applicationTrack {
                        let turnRanges = transcribedTurns.map {
                            (index: $0.index, start: chunkOffset + $0.turn.startSeconds, end: chunkOffset + $0.turn.endSeconds)
                        }
                        let acceptedDelaysInEpoch = epochState.acceptedDelays
                        do {
                            let outcome = try await Task.detached(priority: .userInitiated) {
                                try Self.computeEchoVerdicts(
                                    micChunk: chunk,
                                    micChunkURL: url,
                                    chunkOffset: chunkOffset,
                                    chunkDuration: chunkDuration,
                                    turns: turnRanges,
                                    applicationTrack: applicationTrack,
                                    origin: context.origin,
                                    sessionDirectory: context.sessionDirectory,
                                    acceptedDelaysInEpoch: acceptedDelaysInEpoch
                                )
                            }.value
                            signalVerdictByIndex = outcome.verdicts
                            if let acceptedDelaySeconds = outcome.acceptedDelaySeconds {
                                epochState.acceptedDelays.append(acceptedDelaySeconds)
                            }
                        } catch {
                            if error is CancellationError { throw error }
                            DebugLogger.shared.warning(
                                "Meeting echo signal scoring chunk \(chunk.id) failed; leaving turns unscored: \(error)",
                                source: "MeetingProcessingPipeline"
                            )
                        }
                    }

                    let turnLoudness = Self.turnLoudness(
                        fileURL: url,
                        turns: transcribedTurns.map { (start: $0.turn.startSeconds, end: $0.turn.endSeconds) }
                    )
                    for (offset, element) in transcribedTurns.enumerated() {
                        let (index, turn, text) = element
                        // De-drift applies ONLY here — echo verdicts below keep consuming raw chunkOffset.
                        let start = MeetingMicrophoneDeDrift.correct(chunkOffset + turn.startSeconds, track: track, origin: context.origin)
                        let end = MeetingMicrophoneDeDrift.correct(chunkOffset + turn.endSeconds, track: track, origin: context.origin)
                        let overlapsRemote = remoteSpeech.contains {
                            min(end, $0.end) - max(start, $0.start) > 0.15
                        }
                        guard let clusterID = clusterIDByLabel[turn.speakerLabel] else { continue }
                        stagedTurns.append(StagedMicrophoneTurn(
                            chunkID: chunk.id,
                            index: index,
                            clusterID: clusterID,
                            clusterLabel: turn.speakerLabel,
                            start: start,
                            end: end,
                            text: text,
                            overlapsRemote: overlapsRemote,
                            rms: turnLoudness.indices.contains(offset) ? turnLoudness[offset] : 0,
                            signalVerdict: signalVerdictByIndex[index] ?? .unknown
                        ))
                    }
                    return
                }
            } catch {
                if error is CancellationError { throw error }
                if case MeetingProcessingError.audioUnreadable = error { throw error }
                // Diarization worked and every turn still came back empty: the microphone holds no
                // intelligible speech here. Re-transcribing the whole chunk only coaxes the
                // recognizer into hallucinating over near-silence, and that text lands unattributed
                // and unscoreable — measured at 0.31 text containment and no signal verdict at all.
                if Self.isEmptyTurnFallback(error) {
                    DebugLogger.shared.warning(
                        "Meeting microphone chunk \(chunk.id): no intelligible speech, emitting nothing",
                        source: "MeetingProcessingPipeline"
                    )
                    return
                }
                DebugLogger.shared.warning(
                    "Meeting microphone chunk \(chunk.id) fell back to an unlabeled transcript (diarization failed): \(error)",
                    source: "MeetingProcessingPipeline"
                )
            }
        }
        if let fallback = try await self.transcribeWholeChunk(
            url,
            provider: context.provider,
            languageCode: context.languageCode,
            asrService: context.asrService,
            languagePin: context.languagePin
        ) {
            let duration = chunkDuration
            let speakerID = accumulator.speaker(
                key: "microphone-unknown",
                displayName: "Microphone / Unknown",
                trackKind: .microphone,
                isLocalUser: false,
                clusterID: nil
            )
            accumulator.segments.append(Self.segment(
                key: "microphone-fallback:\(chunk.id.uuidString)",
                trackID: track.id,
                speakerID: speakerID,
                start: chunkOffset,
                end: chunkOffset + duration,
                text: fallback,
                overlap: .ambiguous
            ))
        }
    }

    private func finishMicrophoneTrack(
        _ track: MeetingAudioTrack,
        session: MeetingSession,
        stagedTurns allStagedTurns: [StagedMicrophoneTurn],
        accumulator: inout Accumulator
    ) {
        // Session-wide, never per chunk: a chunk holding only distant audio would otherwise take
        // that audio as its own reference and gate nothing.
        let stagedTurns = session.selectedMicrophone.role == .personal
            ? Self.rejectingFarField(allStagedTurns)
            : allStagedTurns

        if session.mode == .inRoom {
            for turn in stagedTurns {
                let isNewSpeaker = !accumulator.speakers.contains { $0.id == turn.clusterID }
                if isNewSpeaker {
                    let displayName = "Room Speaker \(accumulator.nextMicrophoneSpeaker)"
                    accumulator.nextMicrophoneSpeaker += 1
                    accumulator.addResolvedSpeaker(
                        id: turn.clusterID,
                        key: "room-cluster:\(turn.clusterID.uuidString)",
                        displayName: displayName,
                        clusterID: turn.clusterLabel,
                        trackKind: .microphone,
                        isLocalUser: false
                    )
                } else {
                    accumulator.addResolvedSpeaker(
                        id: turn.clusterID,
                        key: "room-cluster:\(turn.clusterID.uuidString)",
                        displayName: "Room Speaker",
                        clusterID: turn.clusterLabel,
                        trackKind: .microphone,
                        isLocalUser: false
                    )
                }
                accumulator.segments.append(Self.segment(
                    key: "microphone:\(turn.chunkID.uuidString):\(turn.index)",
                    trackID: track.id,
                    speakerID: turn.clusterID,
                    start: turn.start,
                    end: turn.end,
                    text: turn.text,
                    overlap: .none
                ))
            }
            return
        }

        let applicationTrackID = session.audioTracks.first(where: { $0.kind == .applicationAudio })?.id
        // The 60s remote whole-chunk fallback is too coarse to score against; exclude its speaker.
        let fallbackSpeakerID = accumulator.speakerIDByKey["meeting-audio"]
        var classifiedTurns = stagedTurns
        if let applicationTrackID {
            for index in classifiedTurns.indices where classifiedTurns[index].overlapsRemote {
                let turn = classifiedTurns[index]
                let remoteText = Self.echoCandidateText(
                    segments: accumulator.segments,
                    speakerIDToExclude: fallbackSpeakerID,
                    applicationTrackID: applicationTrackID,
                    window: (turn.start, turn.end)
                )
                guard !remoteText.isEmpty else { continue }
                classifiedTurns[index].echoScored = true
                classifiedTurns[index].isLikelyEcho = MeetingEchoDetector.isLikelyEcho(
                    micText: turn.text,
                    remoteText: remoteText
                )
            }
        }

        let prototypeSpeakerIDs = accumulator.embeddingIndexByTrack[.microphone]?.speakerIDs ?? []
        let localClusterID = session.selectedMicrophone.role == .personal
            ? Self.selectLocalCluster(from: classifiedTurns, prototypeSpeakerIDs: prototypeSpeakerIDs)
            : nil
        Self.logLocalSpeakerElection(
            turns: classifiedTurns,
            prototypeSpeakerIDs: prototypeSpeakerIDs,
            index: accumulator.embeddingIndexByTrack[.microphone],
            role: session.selectedMicrophone.role,
            elected: localClusterID
        )
        if let localClusterID,
           let evidenceTurn = classifiedTurns.first(where: { $0.clusterID == localClusterID })
        {
            accumulator.addResolvedSpeaker(
                id: localClusterID,
                key: "local-user",
                displayName: "You",
                clusterID: evidenceTurn.clusterLabel,
                trackKind: .microphone,
                isLocalUser: true
            )
        }
        let unknownSpeakerID = accumulator.speaker(
            key: "microphone-unknown",
            displayName: "Microphone / Unknown",
            trackKind: .microphone,
            isLocalUser: false,
            clusterID: nil
        )
        for turn in classifiedTurns {
            let isLocalCluster = turn.clusterID == localClusterID
            let isCleanLocalTurn = isLocalCluster && !turn.effectiveEcho
            accumulator.segments.append(Self.segment(
                key: "microphone:\(turn.chunkID.uuidString):\(turn.index)",
                trackID: track.id,
                speakerID: isCleanLocalTurn ? localClusterID : unknownSpeakerID,
                start: turn.start,
                end: turn.end,
                text: turn.text,
                overlap: turn.overlapsRemote ? .overlapsOtherTrack : .none,
                isLikelyEcho: isLocalCluster ? false : turn.effectiveEcho
            ))
        }
    }

    /// Each word lands in at most one turn: max overlap wins, ties to the lower index.
    nonisolated static func assignWords(
        _ words: [ASRWordTiming],
        toTurns turns: [(index: Int, start: TimeInterval, end: TimeInterval)],
        nearestTolerance: TimeInterval = 0.5
    ) -> (byTurn: [Int: String], unassigned: Int) {
        var accumulated: [Int: [String]] = [:]
        var unassignedCount = 0

        for word in words {
            // Half-open [start, end): a boundary instant scores 0 on both sides, never doubles.
            let overlaps = turns.map { turn in
                (index: turn.index, overlap: max(0, min(word.end, turn.end) - max(word.start, turn.start)))
            }
            if let maxOverlap = overlaps.map(\.overlap).max(), maxOverlap > 0,
               let winner = overlaps.filter({ $0.overlap == maxOverlap }).min(by: { $0.index < $1.index })
            {
                accumulated[winner.index, default: []].append(word.text)
                continue
            }

            let distances = turns.map { turn -> (index: Int, distance: TimeInterval) in
                let distance: TimeInterval
                if word.end <= turn.start {
                    distance = turn.start - word.end
                } else if word.start >= turn.end {
                    distance = word.start - turn.end
                } else {
                    distance = 0
                }
                return (turn.index, distance)
            }
            if let nearest = distances.min(by: { $0.distance < $1.distance || ($0.distance == $1.distance && $0.index < $1.index) }),
               nearest.distance <= nearestTolerance
            {
                accumulated[nearest.index, default: []].append(word.text)
            } else {
                unassignedCount += 1
            }
        }

        return (accumulated.mapValues { $0.joined(separator: " ") }, unassignedCount)
    }

    /// Above this share of unplaceable words the timings are not trustworthy enough to keep.
    static let maxUnassignedWordFraction = 0.25

    /// Words outside every turn attach to the nearest turn within this window. Zero on the
    /// microphone, where bleed would otherwise be credited to the user as their own words.
    nonisolated static func wordAttachmentTolerance(for trackKind: MeetingAudioTrackKind) -> TimeInterval {
        trackKind == .microphone ? 0 : 0.5
    }

    /// The chunk-level catch classifies on these; swallowing one would mislabel the chunk.
    nonisolated static func alignmentErrorMustPropagate(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case MeetingProcessingError.audioUnreadable = error { return true }
        return false
    }

    nonisolated static func tooManyWordsUnassigned(unassigned: Int, totalWords: Int) -> Bool {
        totalWords > 0 && Double(unassigned) > Double(totalWords) * Self.maxUnassignedWordFraction
    }

    private func transcribeTurnsWordAligned(
        _ turns: [SpeakerDiarizationService.SpeakerTurn],
        chunkID: MeetingAudioChunkID,
        trackKind: MeetingAudioTrackKind,
        fileURL: URL,
        context: ProcessingContext
    ) async throws -> [(index: Int, turn: SpeakerDiarizationService.SpeakerTurn, text: String)]? {
        let samples = try await Task.detached(priority: .userInitiated) {
            try Self.readSamples(fileURL: fileURL, startSeconds: 0, endSeconds: nil)
        }.value
        guard samples.count >= 16_000 else { return nil }

        context.languagePin.apply()
        let outcome = try await context.asrService.transcribeMeetingSamplesWithTimings(
            samples,
            provider: context.provider
        )
        guard !outcome.words.isEmpty else { return nil }

        let assignment = Self.assignWords(
            outcome.words,
            toTurns: turns.enumerated().map { (index: $0.offset, start: $0.element.startSeconds, end: $0.element.endSeconds) },
            nearestTolerance: Self.wordAttachmentTolerance(for: trackKind)
        )
        guard !Self.tooManyWordsUnassigned(unassigned: assignment.unassigned, totalWords: outcome.words.count) else {
            DebugLogger.shared.warning(
                "Meeting word alignment chunk \(chunkID): \(assignment.unassigned)/\(outcome.words.count) words unassigned, falling back to per-turn",
                source: "MeetingProcessingPipeline"
            )
            return nil
        }
        if assignment.unassigned > 0 {
            DebugLogger.shared.warning(
                "Meeting word alignment chunk \(chunkID): dropped \(assignment.unassigned) of \(outcome.words.count) unplaceable word(s)",
                source: "MeetingProcessingPipeline"
            )
        }
        return turns.enumerated().map { index, turn in
            (index, turn, assignment.byTurn[index] ?? "")
        }
    }

    private func transcribeTurns(
        _ turns: [SpeakerDiarizationService.SpeakerTurn],
        chunkID: MeetingAudioChunkID,
        trackKind: MeetingAudioTrackKind,
        fileURL: URL,
        context: ProcessingContext
    ) async throws -> [(index: Int, turn: SpeakerDiarizationService.SpeakerTurn, text: String)] {
        if !context.provider.supportsWordTimings {
            DebugLogger.shared.log(
                "Meeting chunk \(chunkID): provider \(context.provider.name) exposes no word timings; transcribing per turn",
                source: "MeetingProcessingPipeline"
            )
        } else {
            do {
                if let aligned = try await self.transcribeTurnsWordAligned(
                    turns,
                    chunkID: chunkID,
                    trackKind: trackKind,
                    fileURL: fileURL,
                    context: context
                ) {
                    return aligned
                }
            } catch {
                if Self.alignmentErrorMustPropagate(error) { throw error }
                DebugLogger.shared.warning(
                    "Meeting word alignment chunk \(chunkID) failed; falling back to per-turn: \(error)",
                    source: "MeetingProcessingPipeline"
                )
            }
        }
        var allTurns: [(index: Int, turn: SpeakerDiarizationService.SpeakerTurn, text: String)] = []
        for (index, turn) in turns.enumerated() {
            let text = try await self.transcribeTurn(
                turn,
                fileURL: fileURL,
                provider: context.provider,
                languageCode: context.languageCode,
                asrService: context.asrService,
                languagePin: context.languagePin
            )
            allTurns.append((index, turn, text))
        }
        return allTurns
    }

    private func transcribeTurn(
        _ turn: SpeakerDiarizationService.SpeakerTurn,
        fileURL: URL,
        provider: any TranscriptionProvider,
        languageCode: String,
        asrService: ASRService,
        languagePin: MeetingProviderLanguagePin
    ) async throws -> String {
        var samples = try await Task.detached(priority: .userInitiated) {
            try Self.readSamples(
                fileURL: fileURL,
                startSeconds: turn.startSeconds,
                endSeconds: turn.endSeconds
            )
        }.value
        let minimumSamples = 17_600
        if samples.count < minimumSamples {
            samples.append(contentsOf: repeatElement(0, count: minimumSamples - samples.count))
        }
        let result = try await self.transcribeSamples(
            samples,
            provider: provider,
            languageCode: languageCode,
            asrService: asrService,
            languagePin: languagePin
        )
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeWholeChunk(
        _ fileURL: URL,
        provider: any TranscriptionProvider,
        languageCode: String,
        asrService: ASRService,
        languagePin: MeetingProviderLanguagePin
    ) async throws -> String? {
        let result: ASRTranscriptionResult
        if provider.prefersNativeFileTranscription {
            languagePin.apply()
            result = try await asrService.transcribeMeetingFile(at: fileURL, provider: provider)
        } else {
            let samples = try await Task.detached(priority: .userInitiated) {
                try Self.readSamples(fileURL: fileURL, startSeconds: 0, endSeconds: nil)
            }.value
            guard samples.count >= 16_000 else { return nil }
            result = try await self.transcribeSamples(
                samples,
                provider: provider,
                languageCode: languageCode,
                asrService: asrService,
                languagePin: languagePin
            )
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func transcribeSamples(
        _ samples: [Float],
        provider: any TranscriptionProvider,
        languageCode: String,
        asrService: ASRService,
        languagePin: MeetingProviderLanguagePin
    ) async throws -> ASRTranscriptionResult {
        languagePin.apply()
        return try await asrService.transcribeMeetingSamples(
            samples,
            provider: provider,
            languageCode: languageCode
        )
    }

    /// Internal (not private) so tests can exercise unreadable-file classification directly.
    nonisolated static func readSamples(
        fileURL: URL,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval?
    ) throws -> [Float] {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw MeetingProcessingError.audioUnreadable
        }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { throw MeetingProcessingError.audioUnreadable }
        let fileDuration = Double(audioFile.length) / sampleRate
        let start = max(0, min(startSeconds, fileDuration))
        let end = max(start, min(endSeconds ?? fileDuration, fileDuration))
        let startFrame = AVAudioFramePosition((start * sampleRate).rounded(.down))
        let frameCount = AVAudioFrameCount(((end - start) * sampleRate).rounded(.up))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: audioFile.processingFormat,
                  frameCapacity: frameCount
              )
        else { return [] }
        audioFile.framePosition = startFrame
        do {
            try audioFile.read(into: buffer, frameCount: frameCount)
        } catch {
            throw MeetingProcessingError.audioUnreadable
        }
        return try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)
    }

    private nonisolated static func audioDuration(_ url: URL) throws -> TimeInterval {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MeetingProcessingError.audioUnreadable
        }
        guard file.processingFormat.sampleRate > 0 else { throw MeetingProcessingError.audioUnreadable }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Overlapping application-track text, minus the coarse whole-chunk fallback speaker.
    nonisolated static func echoCandidateText(
        segments: [MeetingTranscriptSegment],
        speakerIDToExclude: SessionSpeakerID?,
        applicationTrackID: MeetingAudioTrackID,
        window: (start: TimeInterval, end: TimeInterval)
    ) -> String {
        segments
            .filter { segment in
                segment.sourceTrackID == applicationTrackID
                    && (speakerIDToExclude == nil || segment.speakerID != speakerIDToExclude)
                    && min(window.end, segment.end.seconds) - max(window.start, segment.start.seconds) > 0.15
            }
            .map(\.text)
            .joined(separator: " ")
    }

    private static func segment(
        key: String,
        trackID: MeetingAudioTrackID,
        speakerID: SessionSpeakerID?,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        overlap: MeetingTranscriptOverlap,
        isLikelyEcho: Bool = false
    ) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: self.stableUUID("segment:\(key)"),
            start: self.mediaTime(start),
            end: self.mediaTime(max(start, end)),
            sourceTrackID: trackID,
            speakerID: speakerID,
            text: text,
            revision: 0,
            status: .final,
            overlap: overlap,
            completeness: .complete,
            isLikelyEcho: isLikelyEcho
        )
    }

    private static func mediaTime(_ seconds: TimeInterval) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64((max(0, seconds) * 1000).rounded()), timescale: 1000)
    }

    private nonisolated static func stableUUID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

nonisolated enum MeetingProcessingError: LocalizedError {
    case unsupportedLanguage
    case noRecoverableAudio
    case dictationActive
    case modelUnavailable
    case providerDoesNotSupportLanguage(String)
    case audioUnreadable
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage:
            return "Meeting transcription currently supports English only."
        case .noRecoverableAudio:
            return "No finalized meeting audio is available to transcribe."
        case .dictationActive:
            return "Finish the active dictation before transcribing this meeting."
        case .modelUnavailable:
            return "The selected speech model is not ready."
        case let .providerDoesNotSupportLanguage(languageCode):
            return "The selected speech model cannot transcribe meeting language \(languageCode)."
        case .audioUnreadable:
            return "A finalized meeting audio chunk could not be read."
        case .noSpeech:
            return "No speech was detected in the saved meeting audio."
        }
    }
}
