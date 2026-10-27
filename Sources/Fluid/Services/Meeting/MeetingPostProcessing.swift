import CryptoKit
import Foundation

nonisolated struct MeetingPostProcessingRequest: Sendable {
    let sessionID: UUID
    let attemptID: UUID
    let transcriptHash: String
    let language: String
    let speakers: [MeetingSessionSpeaker]
    let segments: [MeetingTranscriptSegment]
    let coverageGaps: [MeetingTranscriptCoverageGap]
}

nonisolated struct MeetingPostProcessingOutput: Codable, Equatable, Sendable {
    let summary: String
    let sourceSegmentIDs: [UUID]
}

nonisolated struct MeetingPostProcessingArtifact: Codable, Equatable, Sendable {
    let attemptID: UUID
    let transcriptHash: String
    let providerID: String
    let modelID: String
    let output: MeetingPostProcessingOutput?
    let error: String?
}

/// The prepared scope owns all model resources. prepare must drain partial allocations before
/// throwing; cancelAndUnload must return only after inference and owned helper processes exit.
nonisolated protocol PreparedMeetingPostProcessor: Sendable {
    func generate(_ request: MeetingPostProcessingRequest) async throws -> MeetingPostProcessingOutput
    func cancelAndUnload() async
}

nonisolated protocol MeetingPostProcessingProviding: Sendable {
    var providerID: String { get }
    var modelID: String { get }
    var maximumInputCharacters: Int { get }
    func isReady() async throws -> Bool
    func prepare() async throws -> any PreparedMeetingPostProcessor
    /// Must also release allocations made by a prepare call that throws before returning a scope.
    func cancelAndUnload() async
}

@MainActor
final class MeetingPostProcessingRegistry {
    static let shared = MeetingPostProcessingRegistry()
    private let residency: MeetingModelResidencyCoordinator

    init(residency: MeetingModelResidencyCoordinator = .shared) { self.residency = residency }

    private(set) var provider: (any MeetingPostProcessingProviding)?

    func register(_ provider: (any MeetingPostProcessingProviding)?) throws {
        guard !self.residency.isExclusive else { throw MeetingModelResidencyError.busy }
        self.provider = provider
    }

    /// No configured provider is a no-op. Failures belong to summary, never erase transcription.
    func process(
        sessionID: UUID, language: String, result: MeetingProcessingResult,
        directory: URL, provider: (any MeetingPostProcessingProviding)?
    ) async -> MeetingPostProcessingArtifact? {
        guard let provider else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(result.segments) else { return nil }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let request = MeetingPostProcessingRequest(
            sessionID: sessionID,
            attemptID: result.attempt.id,
            transcriptHash: hash,
            language: language,
            speakers: result.speakers,
            segments: result.segments,
            coverageGaps: result.coverageGaps
        )
        var prepared: (any PreparedMeetingPostProcessor)?
        let artifact: MeetingPostProcessingArtifact
        do {
            try Task.checkCancellation()
            // A checkpoint is a prerequisite for summary generation, not for publishing the
            // already completed transcript. Keep write failures inside this optional stage.
            do {
                let transcriptURL = directory.appendingPathComponent("transcript-\(result.attempt.id.uuidString).json")
                try await Task.detached(priority: .utility) {
                    let checkpointEncoder = JSONEncoder()
                    checkpointEncoder.dateEncodingStrategy = .iso8601
                    try checkpointEncoder.encode(result).write(to: transcriptURL, options: .atomic)
                }.value
            } catch {
                throw MeetingPostProcessingError.checkpointFailed
            }
            try Task.checkCancellation()
            try self.residency.markSummary()
            guard (1...1_000_000).contains(provider.maximumInputCharacters),
                  result.segments.reduce(0, { $0 + $1.text.count }) <= provider.maximumInputCharacters
            else { throw MeetingPostProcessingError.inputTooLarge }
            guard try await provider.isReady() else { throw MeetingPostProcessingError.notReady }
            try Task.checkCancellation()
            let model = try await provider.prepare()
            prepared = model
            try Task.checkCancellation()
            let output = try await model.generate(request)
            try Task.checkCancellation()
            let allowed = Set(result.segments.map(\.id))
            guard !output.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  output.summary.count <= 100_000,
                  output.sourceSegmentIDs.count <= result.segments.count,
                  Set(output.sourceSegmentIDs).isSubset(of: allowed)
            else { throw MeetingPostProcessingError.invalidOutput }
            artifact = .init(
                attemptID: result.attempt.id,
                transcriptHash: hash,
                providerID: provider.providerID,
                modelID: provider.modelID,
                output: output,
                error: nil
            )
        } catch {
            artifact = .init(
                attemptID: result.attempt.id,
                transcriptHash: hash,
                providerID: provider.providerID,
                modelID: provider.modelID,
                output: nil,
                error: String(error.localizedDescription.prefix(500))
            )
        }
        // Joined cleanup deliberately runs outside the cancelled task's context.
        await Task {
            if let prepared { await prepared.cancelAndUnload() }
            await provider.cancelAndUnload()
        }.value
        do {
            let data = try encoder.encode(artifact)
            let artifactURL = directory.appendingPathComponent("summary-\(result.attempt.id.uuidString).json")
            try await Task.detached(priority: .utility) { try data.write(to: artifactURL, options: .atomic) }.value
        } catch {
            return .init(
                attemptID: artifact.attemptID,
                transcriptHash: hash,
                providerID: artifact.providerID,
                modelID: artifact.modelID,
                output: artifact.output,
                error: "Could not save the summary artifact."
            )
        }
        return artifact
    }
}

nonisolated enum MeetingPostProcessingError: LocalizedError {
    case inputTooLarge, notReady, invalidOutput, checkpointFailed
    var errorDescription: String? {
        switch self {
        case .inputTooLarge: return "The transcript exceeds this summary model's input limit."
        case .notReady: return "The meeting summary model is not installed or ready."
        case .invalidOutput: return "The summary model returned an invalid result."
        case .checkpointFailed: return "Could not save the transcript checkpoint. Summary generation was skipped."
        }
    }
}
