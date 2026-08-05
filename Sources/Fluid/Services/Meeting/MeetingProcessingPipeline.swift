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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !self.isLeased {
            self.isLeased = true
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func release() {
        guard !self.waiters.isEmpty else {
            self.isLeased = false
            return
        }
        self.waiters.removeFirst().resume()
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
    static let pipelineVersion = 1

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

        await self.serializationGate.acquire()
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

        let context = ProcessingContext(
            origin: origin,
            sessionDirectory: sessionDirectory,
            provider: provider,
            languageCode: languagePin.languageCode,
            asrService: asrService,
            languagePin: languagePin
        )
        if let applicationTrack = session.audioTracks.first(where: { $0.kind == .applicationAudio }) {
            try await self.processApplicationTrack(
                applicationTrack,
                context: context,
                accumulator: &accumulator,
                remoteSpeech: &remoteSpeech
            )
            attempt.lastCompletedTrackID = applicationTrack.id
        }

        progress(.transcribing)
        if let microphoneTrack = session.audioTracks.first(where: { $0.kind == .microphone }) {
            try await self.processMicrophoneTrack(
                microphoneTrack,
                session: session,
                context: context,
                remoteSpeech: remoteSpeech,
                accumulator: &accumulator
            )
            attempt.lastCompletedTrackID = microphoneTrack.id
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
            attempt: attempt
        )
    }

    private func processApplicationTrack(
        _ track: MeetingAudioTrack,
        context: ProcessingContext,
        accumulator: inout Accumulator,
        remoteSpeech: inout [TimelineInterval]
    ) async throws {
        let diarizer = SpeakerDiarizationService()
        for chunk in track.chunks where chunk.finalizationState == .finalized {
            let url = chunk.fileURL(relativeTo: context.sessionDirectory)
            let chunkOffset = chunk.presentationStart.seconds - context.origin
            if SpeakerDiarizationService.isSupported {
                do {
                    let diarization = try await diarizer.diarizeWithProfiles(fileURL: url)
                    let turns = diarization.turns
                    if !turns.isEmpty {
                        remoteSpeech.append(contentsOf: turns.map { turn in
                            TimelineInterval(
                                start: chunkOffset + turn.startSeconds,
                                end: chunkOffset + turn.endSeconds
                            )
                        })
                        var transcribedTurns: [(Int, SpeakerDiarizationService.SpeakerTurn, String)] = []
                        for (index, turn) in turns.enumerated() {
                            let text = try await self.transcribeTurn(
                                turn,
                                fileURL: url,
                                provider: context.provider,
                                languageCode: context.languageCode,
                                asrService: context.asrService,
                                languagePin: context.languagePin
                            )
                            guard !text.isEmpty else { throw LabeledPassError.emptyTurn }
                            transcribedTurns.append((index, turn, text))
                        }
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
                        continue
                    }
                } catch {
                    DebugLogger.shared.warning(
                        "Meeting remote diarization failed; preserving an unlabeled track transcript",
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
                let duration = try await Task.detached(priority: .userInitiated) {
                    try Self.audioDuration(url)
                }.value
                let key = "meeting-audio"
                let speakerID = accumulator.speaker(
                    key: key,
                    displayName: "Meeting audio",
                    trackKind: .applicationAudio,
                    isLocalUser: false,
                    clusterID: nil
                )
                remoteSpeech.append(TimelineInterval(start: chunkOffset, end: chunkOffset + duration))
                accumulator.segments.append(Self.segment(
                    key: "remote-fallback:\(chunk.id.uuidString)",
                    trackID: track.id,
                    speakerID: speakerID,
                    start: chunkOffset,
                    end: chunkOffset + duration,
                    text: fallback,
                    overlap: .none
                ))
            }
        }
    }

    private func processMicrophoneTrack(
        _ track: MeetingAudioTrack,
        session: MeetingSession,
        context: ProcessingContext,
        remoteSpeech: [TimelineInterval],
        accumulator: inout Accumulator
    ) async throws {
        let diarizer = SpeakerDiarizationService()
        var stagedTurns: [StagedMicrophoneTurn] = []
        var cleanDurationByCluster: [SessionSpeakerID: TimeInterval] = [:]
        for chunk in track.chunks where chunk.finalizationState == .finalized {
            let url = chunk.fileURL(relativeTo: context.sessionDirectory)
            let chunkOffset = chunk.presentationStart.seconds - context.origin
            if SpeakerDiarizationService.isSupported {
                do {
                    let diarization = try await diarizer.diarizeWithProfiles(fileURL: url)
                    let turns = diarization.turns
                    if !turns.isEmpty {
                        var transcribedTurns: [(Int, SpeakerDiarizationService.SpeakerTurn, String)] = []
                        for (index, turn) in turns.enumerated() {
                            let text = try await self.transcribeTurn(
                                turn,
                                fileURL: url,
                                provider: context.provider,
                                languageCode: context.languageCode,
                                asrService: context.asrService,
                                languagePin: context.languagePin
                            )
                            guard !text.isEmpty else { throw LabeledPassError.emptyTurn }
                            transcribedTurns.append((index, turn, text))
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
                        continue
                    }
                } catch {
                    DebugLogger.shared.warning(
                        "Meeting microphone speech detection failed; preserving an unlabeled track transcript",
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
                let duration = try await Task.detached(priority: .userInitiated) {
                    try Self.audioDuration(url)
                }.value
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
        for turn in stagedTurns {
            let isCleanLocalTurn = turn.clusterID == localClusterID && !turn.overlapsRemote
            accumulator.segments.append(Self.segment(
                key: "microphone:\(turn.chunkID.uuidString):\(turn.index)",
                trackID: track.id,
                speakerID: isCleanLocalTurn ? localClusterID : unknownSpeakerID,
                start: turn.start,
                end: turn.end,
                text: turn.text,
                overlap: turn.overlapsRemote ? .overlapsOtherTrack : .none
            ))
        }
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

    private nonisolated static func readSamples(
        fileURL: URL,
        startSeconds: TimeInterval,
        endSeconds: TimeInterval?
    ) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: fileURL)
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
        try audioFile.read(into: buffer, frameCount: frameCount)
        return try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)
    }

    private nonisolated static func audioDuration(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate > 0 else { throw MeetingProcessingError.audioUnreadable }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func segment(
        key: String,
        trackID: MeetingAudioTrackID,
        speakerID: SessionSpeakerID?,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        overlap: MeetingTranscriptOverlap
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
            completeness: .complete
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
