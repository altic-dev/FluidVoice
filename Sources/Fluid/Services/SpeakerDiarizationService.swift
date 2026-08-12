import Foundation

#if arch(arm64)
import FluidAudio

/// Identifies who spoke when in an audio file using FluidAudio's offline diarizer.
/// Diarizer CoreML models download automatically on first use (same flow as the ASR models).
actor SpeakerDiarizationService {
    static let isSupported = true

    /// A contiguous stretch of speech attributed to one speaker.
    nonisolated struct SpeakerTurn: Sendable, Equatable {
        let speakerLabel: String
        let startSeconds: Double
        let endSeconds: Double

        var durationSeconds: Double {
            self.endSeconds - self.startSeconds
        }
    }

    nonisolated struct SpeakerProfile: Sendable, Equatable {
        let embedding: [Float]
        let averageQuality: Float
    }

    nonisolated struct DiarizationOutput: Sendable, Equatable {
        let turns: [SpeakerTurn]
        let profilesByLabel: [String: SpeakerProfile]
    }

    private let manager: OfflineDiarizerManager
    private var modelsReady = false

    /// - Parameter expectedSpeakers: Exact speaker count hint for clustering.
    ///   Pass nil (or a non-positive count upstream) to let the diarizer estimate it.
    init(expectedSpeakers: Int? = nil) {
        var config = OfflineDiarizerConfig.default
        if let expectedSpeakers, expectedSpeakers > 0 {
            config = config.withSpeakers(exactly: expectedSpeakers)
        }
        self.manager = OfflineDiarizerManager(config: config)
    }

    /// Diarize an audio file into chronological speaker turns.
    /// Speaker labels are assigned in order of first appearance ("Speaker 1" spoke first).
    /// Returns an empty array when no speech is detected.
    func diarize(fileURL: URL) async throws -> [SpeakerTurn] {
        try await self.diarizeWithProfiles(fileURL: fileURL).turns
    }

    /// Includes one bounded centroid per local cluster so callers can stitch the
    /// same voice across independently processed files without retaining audio.
    /// - Parameter maxGapSeconds: file transcription keeps the 1.0s default; meetings pass wider.
    func diarizeWithProfiles(fileURL: URL, maxGapSeconds: Double = 1.0) async throws -> DiarizationOutput {
        if !self.modelsReady {
            await MainActor.run {
                DebugLogger.shared.info(
                    "SpeakerDiarizationService: preparing diarizer models",
                    source: "SpeakerDiarizationService"
                )
            }
            try await self.manager.prepareModels()
            self.modelsReady = true
        }

        let result: DiarizationResult
        do {
            result = try await self.manager.process(fileURL)
        } catch let error as OfflineDiarizationError {
            if case .noSpeechDetected = error {
                return DiarizationOutput(turns: [], profilesByLabel: [:])
            }
            throw error
        }

        // Sort chronologically before assigning stable labels so "Speaker 1" is the
        // first speaker to talk, not the first cluster the pipeline happens to emit.
        let chronological = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }

        var labelByClusterId: [String: String] = [:]
        var nextSpeakerNumber = 1
        let turns: [SpeakerTurn] = chronological.map { segment in
            let label: String
            if let existing = labelByClusterId[segment.speakerId] {
                label = existing
            } else {
                label = "Speaker \(nextSpeakerNumber)"
                labelByClusterId[segment.speakerId] = label
                nextSpeakerNumber += 1
            }
            return SpeakerTurn(
                speakerLabel: label,
                startSeconds: Double(segment.startTimeSeconds),
                endSeconds: Double(segment.endTimeSeconds)
            )
        }

        var profilesByLabel: [String: SpeakerProfile] = [:]
        for (clusterID, label) in labelByClusterId {
            let clusterSegments = chronological.filter { $0.speakerId == clusterID }
            let embedding = result.speakerDatabase?[clusterID] ?? clusterSegments.first?.embedding ?? []
            guard !embedding.isEmpty else { continue }
            let quality = clusterSegments.isEmpty
                ? 0
                : clusterSegments.reduce(Float.zero) { $0 + $1.qualityScore } / Float(clusterSegments.count)
            profilesByLabel[label] = SpeakerProfile(
                embedding: embedding,
                averageQuality: quality
            )
        }

        return DiarizationOutput(
            turns: Self.mergeAdjacentTurns(turns, maxGapSeconds: maxGapSeconds),
            profilesByLabel: profilesByLabel
        )
    }

    /// Merge consecutive turns from the same speaker separated by short gaps.
    /// Fewer, longer turns give the ASR more context per slice and read better.
    /// Merged turns are capped so downstream slice reads stay bounded (mirrors the
    /// 20-minute chunk ceiling used by the standard file transcription path).
    static func mergeAdjacentTurns(
        _ turns: [SpeakerTurn],
        maxGapSeconds: Double = 1.0,
        maxTurnSeconds: Double = 20 * 60
    ) -> [SpeakerTurn] {
        guard var current = turns.first else { return [] }
        var merged: [SpeakerTurn] = []

        for turn in turns.dropFirst() {
            let gap = turn.startSeconds - current.endSeconds
            let combinedDuration = turn.endSeconds - current.startSeconds
            if turn.speakerLabel == current.speakerLabel,
               gap <= maxGapSeconds,
               combinedDuration <= maxTurnSeconds
            {
                // A merge must never shrink the covered time range. Diarization
                // segments can overlap at boundaries (overlapping speech, VAD
                // imprecision), so a later same-speaker turn may end before the
                // accumulated turn — taking turn.endSeconds directly would drop the
                // trailing audio ([turn.end, current.end]) from the slice.
                current = SpeakerTurn(
                    speakerLabel: current.speakerLabel,
                    startSeconds: current.startSeconds,
                    endSeconds: max(current.endSeconds, turn.endSeconds)
                )
            } else {
                merged.append(current)
                current = turn
            }
        }
        merged.append(current)
        return merged
    }
}

#else

/// Stub for Intel Macs where FluidAudio (and therefore diarization) is unavailable.
actor SpeakerDiarizationService {
    static let isSupported = false

    nonisolated struct SpeakerTurn: Sendable, Equatable {
        let speakerLabel: String
        let startSeconds: Double
        let endSeconds: Double

        var durationSeconds: Double {
            self.endSeconds - self.startSeconds
        }
    }

    nonisolated struct SpeakerProfile: Sendable, Equatable {
        let embedding: [Float]
        let averageQuality: Float
    }

    nonisolated struct DiarizationOutput: Sendable, Equatable {
        let turns: [SpeakerTurn]
        let profilesByLabel: [String: SpeakerProfile]
    }

    init(expectedSpeakers: Int? = nil) {}

    func diarize(fileURL: URL) async throws -> [SpeakerTurn] {
        try await self.diarizeWithProfiles(fileURL: fileURL).turns
    }

    func diarizeWithProfiles(fileURL: URL, maxGapSeconds: Double = 1.0) async throws -> DiarizationOutput {
        throw NSError(
            domain: "SpeakerDiarizationService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Speaker diarization is not supported on Intel Macs"]
        )
    }
}

#endif
