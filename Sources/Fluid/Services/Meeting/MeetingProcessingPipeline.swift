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

nonisolated enum MeetingLocalSpeakerEvidenceSelector {
    static func candidate(
        cleanDurationByCluster: [SessionSpeakerID: TimeInterval],
        prototypeSpeakerIDs: Set<SessionSpeakerID>
    ) -> SessionSpeakerID? {
        let ranked = cleanDurationByCluster
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
    static let pipelineVersion = 3
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

    private struct StagedMicrophoneTurn {
        var chunkID: MeetingAudioChunkID
        var index: Int
        var clusterID: SessionSpeakerID
        var clusterLabel: String
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var overlapsRemote: Bool
        var isLikelyEcho = false
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
        var stagedTurns: [StagedMicrophoneTurn] = []
        var cleanDurationByCluster: [SessionSpeakerID: TimeInterval] = [:]
        for chunk in track.chunks where chunk.finalizationState == .finalized {
            let accumulatorSnapshot = accumulator
            let stagedTurnsSnapshot = stagedTurns
            let cleanDurationByClusterSnapshot = cleanDurationByCluster
            do {
                try await self.processMicrophoneChunk(
                    chunk,
                    track: track,
                    diarizer: diarizer,
                    context: context,
                    remoteSpeech: remoteSpeech,
                    accumulator: &accumulator,
                    stagedTurns: &stagedTurns,
                    cleanDurationByCluster: &cleanDurationByCluster
                )
            } catch {
                if error is CancellationError { throw error }
                guard case MeetingProcessingError.audioUnreadable = error else { throw error }
                accumulator = accumulatorSnapshot
                stagedTurns = stagedTurnsSnapshot
                cleanDurationByCluster = cleanDurationByClusterSnapshot
                skippedChunkIDs.append(chunk.id)
            }
        }

        self.finishMicrophoneTrack(
            track,
            session: session,
            stagedTurns: stagedTurns,
            cleanDurationByCluster: cleanDurationByCluster,
            accumulator: &accumulator
        )
    }

    private func processMicrophoneChunk(
        _ chunk: MeetingAudioChunk,
        track: MeetingAudioTrack,
        diarizer: SpeakerDiarizationService,
        context: ProcessingContext,
        remoteSpeech: [TimelineInterval],
        accumulator: inout Accumulator,
        stagedTurns: inout [StagedMicrophoneTurn],
        cleanDurationByCluster: inout [SessionSpeakerID: TimeInterval]
    ) async throws {
        let url = chunk.fileURL(relativeTo: context.sessionDirectory)
        let chunkOffset = chunk.presentationStart.seconds - context.origin
        let chunkDuration = try await Task.detached(priority: .userInitiated) {
            try Self.audioDuration(url)
        }.value
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
                    for (index, turn, text) in transcribedTurns {
                        let start = chunkOffset + turn.startSeconds
                        let end = chunkOffset + turn.endSeconds
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
                            overlapsRemote: overlapsRemote
                        ))
                        if !overlapsRemote {
                            cleanDurationByCluster[clusterID, default: 0] += max(0, end - start)
                        }
                    }
                    return
                }
            } catch {
                if error is CancellationError { throw error }
                if case MeetingProcessingError.audioUnreadable = error { throw error }
                let reason = Self.isEmptyTurnFallback(error) ? "every turn transcribed empty" : "diarization failed"
                DebugLogger.shared.warning(
                    "Meeting microphone chunk \(chunk.id) fell back to an unlabeled transcript (\(reason)): \(error)",
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
        stagedTurns: [StagedMicrophoneTurn],
        cleanDurationByCluster: [SessionSpeakerID: TimeInterval],
        accumulator: inout Accumulator
    ) {
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

        let localClusterID = session.selectedMicrophone.role == .personal
            ? MeetingLocalSpeakerEvidenceSelector.candidate(
                cleanDurationByCluster: cleanDurationByCluster,
                prototypeSpeakerIDs: accumulator.embeddingIndexByTrack[.microphone]?.speakerIDs ?? []
            )
            : nil
        if let localClusterID,
           let evidenceTurn = stagedTurns.first(where: { $0.clusterID == localClusterID })
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
        let applicationTrackID = session.audioTracks.first(where: { $0.kind == .applicationAudio })?.id
        // The 60s remote whole-chunk fallback is too coarse to score against; exclude its speaker.
        let fallbackSpeakerID = accumulator.speakerIDByKey["meeting-audio"]
        var classifiedTurns = stagedTurns
        if let applicationTrackID {
            for index in classifiedTurns.indices where classifiedTurns[index].overlapsRemote {
                let turn = classifiedTurns[index]
                guard turn.clusterID != localClusterID else { continue }
                let remoteText = Self.echoCandidateText(
                    segments: accumulator.segments,
                    speakerIDToExclude: fallbackSpeakerID,
                    applicationTrackID: applicationTrackID,
                    window: (turn.start, turn.end)
                )
                classifiedTurns[index].isLikelyEcho = MeetingEchoDetector.isLikelyEcho(
                    micText: turn.text,
                    remoteText: remoteText
                )
            }
        }
        for turn in classifiedTurns {
            let isCleanLocalTurn = turn.clusterID == localClusterID && !turn.overlapsRemote
            accumulator.segments.append(Self.segment(
                key: "microphone:\(turn.chunkID.uuidString):\(turn.index)",
                trackID: track.id,
                speakerID: isCleanLocalTurn ? localClusterID : unknownSpeakerID,
                start: turn.start,
                end: turn.end,
                text: turn.text,
                overlap: turn.overlapsRemote ? .overlapsOtherTrack : .none,
                isLikelyEcho: turn.isLikelyEcho
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
