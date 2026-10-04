import AVFoundation
import Foundation
#if arch(arm64)
import FluidAudio
#endif

nonisolated struct DictionaryMatchReport: Codable, Sendable {
    struct Candidate: Codable, Identifiable, Sendable {
        let id: String
        let word: String
        var sampleNumber: Int?
        let enrollmentCount: Int
        let eligible: Bool
        var score: Float?
        var start: Double?
        var end: Double?
        var heard = ""
        var requiredScore: Float = 0.70
        var competingWord: String?
        var competingScore: Float?

        var explanation: String {
            guard let score else { return "No usable audio window" }
            if !self.eligible { return "Not active: needs more compatible recordings" }
            if score < self.requiredScore { return "Below cutoff by \(String(format: "%.3f", self.requiredScore - score))" }
            if self.heard.isEmpty { return "Score clears cutoff, but no word overlaps this audio window" }
            if let competingScore, competingScore > score - 0.05 { return "Close competing best window: less than 0.05 separation" }
            return "Above score cutoff in this replay; verify the matched phrase"
        }
    }

    /// One strongest individual recording per word, retaining its window and evidence.
    static func bestCandidates(from samples: [Candidate]) -> [Candidate] {
        Dictionary(grouping: samples, by: { $0.word.lowercased() }).values.compactMap { group in
            guard var best = group.max(by: { ($0.score ?? -.infinity) < ($1.score ?? -.infinity) }) else { return nil }
            best.sampleNumber = nil
            return best
        }
    }

    let createdAt: Date
    let recordingID: UUID
    let audioPath: String
    let targetWord: String
    let modelKey: String
    let duration: Double
    let rawTranscript: String
    let savedTranscript: String
    let availableProfileCount: Int
    let candidates: [Candidate]
    let targetSamples: [Candidate]
    // Local export retains the exact reference vectors used by this replay.
    let profiles: [PronunciationDictionaryProfile]
    var inspection: DictionaryAudioInspection? = nil
}

enum DictionaryMatchPlaygroundError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        }
    }
}

/// Optional, on-demand replay. Does not use the live ASR service, write the dictionary,
/// open a microphone, or change production matching thresholds.
actor DictionaryMatchPlayground {
    static let shared = DictionaryMatchPlayground()
    private var running = false

    /// Resolve before loading a model: an older checkpoint's vectors remain saved
    /// but cannot be replayed through a different encoder with the same dimensions.
    nonisolated static func targetProfile(from profiles: [PronunciationDictionaryProfile], target: String) throws -> PronunciationDictionaryProfile {
        let matching = profiles.filter { $0.label.caseInsensitiveCompare(target) == .orderedSame }
        if let current = matching.first(where: { ParakeetSpeechModelCatalog.descriptor(forPronunciationModelKey: $0.modelKey) != nil }) {
            return current
        }
        if matching.contains(where: { ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey($0.modelKey) }) {
            throw PronunciationDictionaryStoreError.outdatedModelRevision
        }
        throw DictionaryMatchPlaygroundError.unavailable("No saved Parakeet pronunciation recordings for “\(target)”. Train this word by voice first.")
    }

    func analyze(recordingID: UUID, audioURL: URL, savedTranscript: String, target: String) async throws -> DictionaryMatchReport {
        let file = try AVAudioFile(forReading: audioURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > 0, duration <= 120 else {
            throw DictionaryMatchPlaygroundError.unavailable("Use a recording up to two minutes long.")
        }
        #if arch(arm64)
        let samples = try AudioConverter().resampleAudioFile(path: audioURL.path)
        return try await self.analyze(recordingID: recordingID, samples: samples, savedTranscript: savedTranscript, target: target, audioPath: audioURL.path)
        #else
        throw DictionaryMatchPlaygroundError.unavailable("Pronunciation matching requires Apple Silicon.")
        #endif
    }

    func analyze(recordingID: UUID, samples: [Float], savedTranscript: String, target: String, audioPath: String = "") async throws -> DictionaryMatchReport {
        // A cancelled prior attempt releases its model before a new one starts.
        for _ in 0..<100 where self.running {
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard !self.running else { throw DictionaryMatchPlaygroundError.unavailable("The previous recording is still finishing. Try again.") }
        guard !samples.isEmpty, samples.count <= 16_000 * 120 else {
            throw DictionaryMatchPlaygroundError.unavailable("Use a recording up to two minutes long.")
        }
        self.running = true
        defer { self.running = false }
        let duration = Double(samples.count) / 16_000
        #if arch(arm64)
        let allProfiles = await PronunciationDictionaryStore.shared.allProfiles()
        let targetProfile = try Self.targetProfile(from: allProfiles, target: target)
        let matching = allProfiles.filter { $0.modelKey == targetProfile.modelKey }.sorted {
            let lhsTarget = $0.dictionaryEntryID == targetProfile.dictionaryEntryID
            let rhsTarget = $1.dictionaryEntryID == targetProfile.dictionaryEntryID
            if lhsTarget != rhsTarget { return lhsTarget }
            return $0.label < $1.label
        }
        let profiles = Array(matching.prefix(64))
        try Task.checkCancellation()
        guard let descriptor = ParakeetSpeechModelCatalog.descriptor(forPronunciationModelKey: targetProfile.modelKey) else {
            throw DictionaryMatchPlaygroundError.unavailable("This pronunciation model is unavailable.")
        }
        let version = descriptor.asrModelVersion
        let directory = AsrModels.defaultCacheDirectory(for: version)
        guard descriptor.installationRevisionMatches(at: directory) else {
            throw PronunciationDictionaryStoreError.outdatedModelRevision
        }
        let models = try await AsrModels.loadLocalOnly(from: directory, version: version)
        let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId), encoderHiddenSize: version.encoderHiddenSize))
        do {
            try await manager.initialize(models: models)
            let report = try await self.scan(
                samples: samples,
                manager: manager,
                profiles: profiles,
                targetProfile: targetProfile,
                context: ReplayContext(recordingID: recordingID, audioPath: audioPath, savedTranscript: savedTranscript, duration: duration, availableProfileCount: matching.count)
            )
            await manager.cleanup()
            return report
        } catch {
            await manager.cleanup()
            throw error
        }
        #else
        throw DictionaryMatchPlaygroundError.unavailable("Pronunciation replay diagnostics require Apple Silicon.")
        #endif
    }

    #if arch(arm64)
    private struct ReplayContext {
        let recordingID: UUID
        let audioPath: String
        let savedTranscript: String
        let duration: Double
        let availableProfileCount: Int
    }

    private func scan(
        samples: [Float], manager: AsrManager, profiles: [PronunciationDictionaryProfile],
        targetProfile: PronunciationDictionaryProfile, context: ReplayContext
    ) async throws -> DictionaryMatchReport {
        let references = DictionaryPronunciationReferences.make(profiles: profiles)
        let vectors = references.map(\.embedding)
        var rows = references.map { reference in
            DictionaryMatchReport.Candidate(
                id: "\(reference.profile.id):sample-\(reference.sampleNumber)",
                word: reference.profile.label,
                sampleNumber: reference.sampleNumber,
                enrollmentCount: reference.profile.enrollments.count,
                eligible: reference.profile.isEligibleForMatching
            )
        }
        var transcripts: [String] = []
        var inspectedFrames: [DictionaryAudioInspection.Frames] = []
        var inspectedWords: [DictionaryAudioInspection.Word] = []
        // Match the same 80ms encoder frames in bounded chunks. No confidence cutoff:
        // bestMatches retains near misses that production allMatches intentionally drops.
        for offset in stride(from: 0, to: samples.count, by: 238_080) {
            try Task.checkCancellation()
            var chunk = Array(samples[offset..<min(offset + 238_080, samples.count)])
            let unpaddedCount = chunk.count
            if chunk.count < 16_000 { chunk += repeatElement(0, count: 16_000 - chunk.count) }
            await manager.setPronunciationCustomizationEnabled(true)
            let result = try await manager.transcribe(chunk, source: .microphone)
            let features = await manager.consumePronunciationEncoderFeatures()
            transcripts.append(result.text)
            guard let features else { continue }
            let words = WordAudioChunkExtractor.words(from: result.tokenTimings ?? [])
            let frameCount = min(features.frameCount, Int(ceil(Double(unpaddedCount) / 16_000 / features.frameDuration)))
            inspectedFrames.append(.init(
                offset: Double(offset) / 16_000,
                frameDuration: features.frameDuration,
                hiddenSize: features.hiddenSize,
                values: Array(features.values.prefix(frameCount * features.hiddenSize))
            ))
            inspectedWords += words.map { .init(text: $0.text, start: Double(offset) / 16_000 + $0.startTime, end: Double(offset) / 16_000 + $0.endTime) }
            let matches = PronunciationEmbeddingMatcher.bestMatches(prototypes: vectors, in: features)
            for (index, match) in matches.enumerated() {
                guard let match, match.score.isFinite, rows.indices.contains(index),
                      rows[index].score == nil || match.score > (rows[index].score ?? -.infinity)
                else { continue }
                let start = Double(match.frameRange.lowerBound) * 0.08
                let end = Double(match.frameRange.upperBound) * 0.08
                let heard = words.filter {
                    max(0, min($0.endTime, end) - max($0.startTime, start)) / max(0.0001, $0.endTime - $0.startTime) >= 0.5
                }.map(\.text).joined(separator: " ")
                rows[index].score = match.score
                rows[index].start = Double(offset) / 16_000 + start
                rows[index].end = Double(offset) / 16_000 + end
                rows[index].heard = heard
                rows[index].requiredScore = DictionaryPronunciationDecision.requiredScore(heardText: heard, profile: references[index].profile)
            }
        }
        try Task.checkCancellation()
        var candidates = DictionaryMatchReport.bestCandidates(from: rows)
        for index in candidates.indices {
            let current = candidates[index]
            let competing = candidates.filter {
                $0.word.caseInsensitiveCompare(current.word) != .orderedSame && $0.eligible &&
                    ($0.score ?? -.infinity) >= $0.requiredScore &&
                    max($0.start ?? 0, current.start ?? 0) < min($0.end ?? 0, current.end ?? 0)
            }.max { ($0.score ?? -.infinity) < ($1.score ?? -.infinity) }
            candidates[index].competingWord = competing?.word
            candidates[index].competingScore = competing?.score
        }
        candidates.sort { ($0.score ?? -.infinity) > ($1.score ?? -.infinity) }
        return DictionaryMatchReport(
            createdAt: Date(),
            recordingID: context.recordingID,
            audioPath: context.audioPath,
            targetWord: targetProfile.label,
            modelKey: targetProfile.modelKey,
            duration: context.duration,
            rawTranscript: transcripts.joined(separator: " "),
            savedTranscript: context.savedTranscript,
            availableProfileCount: context.availableProfileCount,
            candidates: candidates,
            targetSamples: rows.filter { $0.id.hasPrefix(targetProfile.id + ":sample-") },
            profiles: profiles,
            inspection: inspectedFrames.isEmpty ? nil : DictionaryAudioInspection(
                samples: samples,
                recordedSampleCount: samples.count,
                frames: inspectedFrames,
                words: inspectedWords,
                selectedStart: 0,
                selectedEnd: context.duration
            )
        )
    }
    #endif
}
