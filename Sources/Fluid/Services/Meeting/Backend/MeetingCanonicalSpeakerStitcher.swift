import AVFoundation
import CryptoKit
import Foundation

#if arch(arm64)
    import FluidAudio
#endif

/// Reconciles epoch-local Nemotron slots only after canonical echo and timing admission.
/// The sidecar's raw word/slot evidence remains unchanged; a failed or unavailable match keeps
/// the original product speaker. Embeddings are attempt-local and are never persisted as profiles.
nonisolated struct MeetingCanonicalSpeakerStitcher {
    struct Result: Sendable {
        let aliases: [SessionSpeakerID: SessionSpeakerID]
        let status: String
        let modelFingerprint: String?
    }

    struct Observation: Sendable {
        let speakerID: SessionSpeakerID
        let token: MeetingBackendSpeakerToken
        let trackID: MeetingAudioTrackID
        let deviceUID: String?
        let embedding: [Float]
        let speechSeconds: TimeInterval
    }

    private struct Word {
        let start: TimeInterval
        let end: TimeInterval
        let span: MeetingAnalysisSpan
    }

    private struct Window {
        let token: MeetingBackendSpeakerToken
        let span: MeetingAnalysisSpan
        let start: TimeInterval
        let end: TimeInterval
        let speechSeconds: TimeInterval
    }

    struct Policy {
        static let minimumSpeechSeconds: TimeInterval = 1.5
        static let crossDeviceMinimumSpeechSeconds: TimeInterval = 4
        static let maximumWindowSeconds: TimeInterval = 8
        static let maximumWindowsPerSlot = 5
        static let minimumWindowSpeechSeconds: TimeInterval = 0.8
        static let maximumEvidenceClipSeconds: TimeInterval = 10
        static let joinedWindowSilenceFrames = 800 // 50 ms at 16 kHz
        static let maximumWordGapSeconds: TimeInterval = 0.35
        static let competingActivityToleranceSeconds: TimeInterval = 0.015
        static let maximumCosineDistance: Float = 0.40
        static let ambiguityMargin: Float = 0.08
    }

    /// No model is loaded when there is only one epoch on every track. Missing local embedding
    /// weights and extraction failures are abstentions, never transcription failures or downloads.
    func stitch(
        assembly: MeetingAssemblyResult,
        evidence: MeetingFinalTranscriptEvidence,
        sessionDirectory: URL
    ) async -> Result {
        #if arch(arm64)
            guard assembly.sidecar.analysisManifest.tracks.contains(where: { $0.epochs.count > 1 })
            else { return Result(aliases: [:], status: "notNeeded", modelFingerprint: nil) }

            let modelDirectory = DiarizerModels.defaultModelsDirectory()
            let segmentationURL = modelDirectory.appendingPathComponent("pyannote_segmentation.mlmodelc")
            let embeddingURL = modelDirectory.appendingPathComponent("wespeaker_v2.mlmodelc")
            guard FileManager.default.fileExists(atPath: segmentationURL.path),
                  FileManager.default.fileExists(atPath: embeddingURL.path)
            else { return Result(aliases: [:], status: "modelUnavailable", modelFingerprint: nil) }
            guard let modelFingerprint = Self.modelFingerprint(
                segmentationURL: segmentationURL,
                embeddingURL: embeddingURL
            ) else {
                return Result(aliases: [:], status: "modelUnverifiable", modelFingerprint: nil)
            }

            do {
                let models = try await DiarizerModels.load(
                    localSegmentationModel: segmentationURL,
                    localEmbeddingModel: embeddingURL
                )
                guard Self.modelFingerprint(
                    segmentationURL: segmentationURL,
                    embeddingURL: embeddingURL
                ) == modelFingerprint else {
                    return Result(aliases: [:], status: "modelChanged", modelFingerprint: nil)
                }
                let manager = DiarizerManager()
                manager.initialize(models: models)
                defer { manager.cleanup() }
                let observations = self.observations(
                    assembly: assembly,
                    evidence: evidence,
                    sessionDirectory: sessionDirectory,
                    embeddingManager: manager
                )
                guard !Task.isCancelled else {
                    return Result(aliases: [:], status: "cancelled", modelFingerprint: modelFingerprint)
                }
                let aliases = Self.aliases(for: observations)
                return Result(
                    aliases: aliases,
                    status: aliases.isEmpty ? "abstained" : "matched",
                    modelFingerprint: modelFingerprint
                )
            } catch {
                return Result(aliases: [:], status: "modelLoadFailed", modelFingerprint: modelFingerprint)
            }
        #else
            return Result(aliases: [:], status: "unsupportedArchitecture", modelFingerprint: nil)
        #endif
    }

    private static func modelFingerprint(segmentationURL: URL, embeddingURL: URL) -> String? {
        let files = [segmentationURL, embeddingURL].flatMap { modelURL in
            [modelURL.appendingPathComponent("model.mil"),
             modelURL.appendingPathComponent("weights/weight.bin")]
        }
        let digests = files.compactMap { MeetingChunkPathConfinement.sha256Hex(contentsOf: $0) }
        guard digests.count == files.count else { return nil }
        let digest = SHA256.hash(data: Data(digests.joined(separator: ":").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    #if arch(arm64)
        private func observations(
            assembly: MeetingAssemblyResult,
            evidence: MeetingFinalTranscriptEvidence,
            sessionDirectory: URL,
            embeddingManager: DiarizerManager
        ) -> [Observation] {
            let spans = Dictionary(
                assembly.sidecar.analysisManifest.allSpans.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let dispositions = Dictionary(
                assembly.sidecar.dispositions.map { ($0.unitID, $0.disposition) },
                uniquingKeysWith: { first, _ in first }
            )
            let speakerByCluster = Dictionary(
                assembly.speakers.compactMap { speaker in
                    speaker.diarizationClusterID.map { ($0, speaker) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            let activityByEpoch = Dictionary(grouping: evidence.speakerActivity, by: {
                $0.token.analysisEpochID
            })
            var wordsByToken: [MeetingBackendSpeakerToken: [Word]] = [:]
            for unit in assembly.sidecar.units where dispositions[unit.id] == .emitted {
                if Task.isCancelled { return [] }
                guard unit.precision == .word,
                      case let .assigned(token) = unit.speaker,
                      unit.analysisSpanIDs.count == 1,
                      let span = spans[unit.analysisSpanIDs[0]],
                      span.timing.certainty == .certain,
                      unit.analysisStart >= span.analysisInterval.start,
                      unit.analysisEnd <= span.analysisInterval.end,
                      unit.analysisEnd > unit.analysisStart
                else { continue }
                let hasCompetingActivity = (activityByEpoch[token.analysisEpochID] ?? []).contains { activity in
                    activity.token != token
                        && min(activity.end, unit.analysisEnd) - max(activity.start, unit.analysisStart)
                            > Policy.competingActivityToleranceSeconds
                }
                guard !hasCompetingActivity else { continue }
                wordsByToken[token, default: []].append(Word(
                    start: unit.analysisStart,
                    end: unit.analysisEnd,
                    span: span
                ))
            }

            var observations: [Observation] = []
            for token in wordsByToken.keys.sorted(by: {
                ("\($0.analysisEpochID):\($0.label)") < ("\($1.analysisEpochID):\($1.label)")
            }) {
                if Task.isCancelled { return [] }
                guard let words = wordsByToken[token],
                      let speaker = speakerByCluster["\(token.analysisEpochID):\(token.label.precomposedStringWithCanonicalMapping)"]
                else { continue }
                let windows = Self.evidenceWindows(
                    words: words,
                    token: token,
                    activity: activityByEpoch[token.analysisEpochID] ?? []
                )
                var joinedSamples: [Float] = []
                var speechSeconds: TimeInterval = 0
                for window in windows {
                    if Task.isCancelled { return [] }
                    guard let samples = try? Self.readSamples(window: window, sessionDirectory: sessionDirectory),
                          !samples.isEmpty
                    else { continue }
                    let maximumFrames = Int(Policy.maximumEvidenceClipSeconds * 16_000)
                    let separatorFrames = joinedSamples.isEmpty ? 0 : Policy.joinedWindowSilenceFrames
                    let availableFrames = maximumFrames - joinedSamples.count - separatorFrames
                    guard availableFrames > 0 else { break }
                    if separatorFrames > 0 {
                        joinedSamples.append(contentsOf: repeatElement(Float.zero, count: separatorFrames))
                    }
                    let acceptedFrames = min(samples.count, availableFrames)
                    joinedSamples.append(contentsOf: samples.prefix(acceptedFrames))
                    speechSeconds += window.speechSeconds * Double(acceptedFrames) / Double(samples.count)
                }
                guard speechSeconds >= Policy.minimumSpeechSeconds,
                      let firstWindow = windows.first
                else { continue }
                guard let rawEmbedding = try? embeddingManager.extractSpeakerEmbedding(from: joinedSamples),
                      let embedding = Self.normalized(rawEmbedding)
                else {
                    continue
                }
                observations.append(Observation(
                    speakerID: speaker.id,
                    token: token,
                    trackID: token.analysisEpochID.trackID,
                    deviceUID: firstWindow.span.captureEra.deviceUID,
                    embedding: embedding,
                    speechSeconds: speechSeconds
                ))
            }
            return observations
        }
    #endif

    private static func evidenceWindows(
        words: [Word],
        token: MeetingBackendSpeakerToken,
        activity: [MeetingBackendSpeakerActivity]
    ) -> [Window] {
        let ordered = words.sorted { ($0.span.id, $0.start, $0.end) < ($1.span.id, $1.start, $1.end) }
        var runs: [Window] = []
        var current: Window?
        for word in ordered {
            if let prior = current,
               prior.span.id == word.span.id,
               word.start - prior.end <= Policy.maximumWordGapSeconds
            {
                current = Window(
                    token: token,
                    span: prior.span,
                    start: prior.start,
                    end: max(prior.end, word.end),
                    speechSeconds: prior.speechSeconds + word.end - word.start
                )
            } else {
                if let current { runs.append(current) }
                current = Window(
                    token: token,
                    span: word.span,
                    start: word.start,
                    end: word.end,
                    speechSeconds: word.end - word.start
                )
            }
        }
        if let current { runs.append(current) }
        return Array(runs
            .filter { run in
                guard run.speechSeconds >= Policy.minimumWindowSpeechSeconds,
                      run.end - run.start >= Policy.minimumWindowSpeechSeconds
                else { return false }
                return !activity.contains { other in
                    other.token != token
                        && min(other.end, run.end) - max(other.start, run.start)
                            > Policy.competingActivityToleranceSeconds
                }
            }
            .sorted {
                if $0.speechSeconds != $1.speechSeconds { return $0.speechSeconds > $1.speechSeconds }
                return ($0.span.id, $0.start) < ($1.span.id, $1.start)
            }
            .prefix(Policy.maximumWindowsPerSlot).map { run in
                let duration = min(run.end - run.start, Policy.maximumWindowSeconds)
                let start = run.start + (run.end - run.start - duration) / 2
                let speechSeconds = words
                    .filter { $0.span.id == run.span.id }
                    .reduce(0) { total, word in
                        total + max(0, min(word.end, start + duration) - max(word.start, start))
                    }
                return Window(
                    token: token, span: run.span, start: start, end: start + duration,
                    speechSeconds: speechSeconds
                )
            })
    }

    private static func readSamples(window: Window, sessionDirectory: URL) throws -> [Float] {
        let span = window.span
        let url = try MeetingChunkPathConfinement.containedURL(
            sessionDirectory: sessionDirectory,
            relativePath: span.chunk.relativeFilePath
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == span.storedByteCount,
              MeetingChunkPathConfinement.sha256Hex(contentsOf: url) == span.storedSHA256.lowercased()
        else { return [] }
        let start = span.sourceLocalInterval.start + window.start - span.analysisInterval.start
        let end = span.sourceLocalInterval.start + window.end - span.analysisInterval.start
        return try MeetingProcessingPipeline.readSamples(
            fileURL: url,
            startSeconds: start,
            endSeconds: end
        )
    }

    private static func normalized(_ embedding: [Float]) -> [Float]? {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return nil }
        let magnitude = sqrt(embedding.reduce(Float.zero) { $0 + $1 * $1 })
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        return embedding.map { $0 / magnitude }
    }

    /// Visit epochs chronologically. A new slot may attach only to an already established
    /// same-track cluster, with a mutual-best match and separation from every other candidate.
    /// Complete linkage prevents an intermediate voice from bridging two different people.
    static func aliases(for observations: [Observation]) -> [SessionSpeakerID: SessionSpeakerID] {
        struct Cluster {
            var members: [Observation]
            var key: String { self.members.map { $0.speakerID.uuidString }.min() ?? "" }
        }
        let prepared = observations
            .compactMap { observation -> Observation? in
                guard observation.speechSeconds >= Policy.minimumSpeechSeconds,
                      let embedding = Self.normalized(observation.embedding)
                else { return nil }
                return Observation(
                    speakerID: observation.speakerID,
                    token: observation.token,
                    trackID: observation.trackID,
                    deviceUID: observation.deviceUID,
                    embedding: embedding,
                    speechSeconds: observation.speechSeconds
                )
            }
        struct Candidate {
            let observation: Int
            let cluster: Int
            let distance: Float
        }
        var clusters: [Cluster] = []
        for trackID in Set(prepared.map(\.trackID)).sorted(by: { $0.uuidString < $1.uuidString }) {
            let trackObservations = prepared.filter { $0.trackID == trackID }
            let epochs = Dictionary(grouping: trackObservations, by: { $0.token.analysisEpochID })
            let orderedEpochs = epochs.keys.sorted {
                ($0.ordinal, $0.generation) < ($1.ordinal, $1.generation)
            }
            for epoch in orderedEpochs {
                if Task.isCancelled { return [:] }
                let current = (epochs[epoch] ?? []).sorted {
                    ($0.token.label, $0.speakerID.uuidString)
                        < ($1.token.label, $1.speakerID.uuidString)
                }
                var candidates: [Candidate] = []
                for observationIndex in current.indices {
                    let observation = current[observationIndex]
                    for clusterIndex in clusters.indices where clusters[clusterIndex].members[0].trackID == trackID {
                        let members = clusters[clusterIndex].members
                        guard members.allSatisfy({ member in
                            member.token.analysisEpochID != epoch
                                && member.embedding.count == observation.embedding.count
                                && (member.deviceUID == observation.deviceUID
                                    || (member.speechSeconds >= Policy.crossDeviceMinimumSpeechSeconds
                                        && observation.speechSeconds >= Policy.crossDeviceMinimumSpeechSeconds))
                        }) else { continue }
                        let diameter = members.map { member in
                            1 - zip(member.embedding, observation.embedding)
                                .reduce(Float.zero) { $0 + $1.0 * $1.1 }
                        }.max() ?? .infinity
                        guard diameter <= Policy.maximumCosineDistance else { continue }
                        candidates.append(Candidate(
                            observation: observationIndex,
                            cluster: clusterIndex,
                            distance: diameter
                        ))
                    }
                }

                var assigned: [Int: Int] = [:]
                for observationIndex in current.indices {
                    let options = candidates.filter { $0.observation == observationIndex }.sorted {
                        if $0.distance != $1.distance { return $0.distance < $1.distance }
                        return clusters[$0.cluster].key < clusters[$1.cluster].key
                    }
                    guard let best = options.first,
                          options.dropFirst().first.map({
                              $0.distance - best.distance >= Policy.ambiguityMargin
                          }) ?? true
                    else { continue }
                    let competitors = candidates.filter { $0.cluster == best.cluster }.sorted {
                        if $0.distance != $1.distance { return $0.distance < $1.distance }
                        return current[$0.observation].speakerID.uuidString
                            < current[$1.observation].speakerID.uuidString
                    }
                    guard competitors.first?.observation == observationIndex,
                          competitors.dropFirst().first.map({
                              $0.distance - best.distance >= Policy.ambiguityMargin
                          }) ?? true
                    else { continue }
                    assigned[observationIndex] = best.cluster
                }
                for observationIndex in current.indices {
                    if let clusterIndex = assigned[observationIndex] {
                        clusters[clusterIndex].members.append(current[observationIndex])
                    } else {
                        clusters.append(Cluster(members: [current[observationIndex]]))
                    }
                }
            }
        }
        var aliases: [SessionSpeakerID: SessionSpeakerID] = [:]
        for cluster in clusters where cluster.members.count > 1 {
            let ordered = cluster.members.sorted {
                let lhs = ($0.token.analysisEpochID.ordinal, $0.token.label, $0.speakerID.uuidString)
                let rhs = ($1.token.analysisEpochID.ordinal, $1.token.label, $1.speakerID.uuidString)
                return lhs < rhs
            }
            guard let target = ordered.first?.speakerID else { continue }
            for source in ordered.dropFirst() { aliases[source.speakerID] = target }
        }
        return aliases
    }

    static func applying(
        _ aliases: [SessionSpeakerID: SessionSpeakerID],
        to input: MeetingProcessingResult
    ) -> MeetingProcessingResult {
        guard !aliases.isEmpty else { return input }
        var output = input
        var speakers = output.speakers
        for index in speakers.indices {
            speakers[index].mergedIntoSpeakerID = aliases[speakers[index].id]
        }
        let segments = output.segments.map { segment -> MeetingTranscriptSegment in
            var updated = segment
            if let speakerID = updated.speakerID, let target = aliases[speakerID] {
                updated.speakerID = target
            }
            return updated
        }
        let firstAppearance = Dictionary(grouping: segments.compactMap { segment -> (SessionSpeakerID, TimeInterval)? in
            segment.speakerID.map { ($0, segment.start.seconds) }
        }, by: { $0.0 }).mapValues { $0.map(\.1).min() ?? .infinity }
        let activeIndices = speakers.indices.filter { speakers[$0].mergedIntoSpeakerID == nil }
            .sorted {
                let left = speakers[$0]
                let right = speakers[$1]
                return (firstAppearance[left.id] ?? .infinity, left.id.uuidString)
                    < (firstAppearance[right.id] ?? .infinity, right.id.uuidString)
            }
        for (ordinal, index) in activeIndices.enumerated() {
            let prefix = "Speaker "
            if speakers[index].displayName.hasPrefix(prefix),
               Int(speakers[index].displayName.dropFirst(prefix.count)) != nil
            {
                speakers[index].displayName = "Speaker \(ordinal + 1)"
            }
        }
        output.speakers = speakers
        output.segments = segments
        return output
    }
}
