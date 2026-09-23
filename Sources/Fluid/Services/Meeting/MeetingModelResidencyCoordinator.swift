import Foundation

nonisolated enum MeetingModelResidencyError: LocalizedError {
    case busy
    case staleGrant
    case terminating
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .busy: return "Models are busy. Wait for the current model operation to finish."
        case .staleGrant: return "This model operation no longer owns meeting processing."
        case .terminating: return "The app is shutting down."
        case .unsupportedProvider: return "This Fluid provider needs an update before meeting model switching can run."
        }
    }
}

nonisolated struct MeetingResidentModel: Equatable, Sendable {
    let id: String
    let configuration: String
}

@MainActor
struct MeetingModelParticipant {
    let owner: String
    let snapshot: () async throws -> MeetingResidentModel?
    let suspend: () async throws -> Void
    let restore: (MeetingResidentModel) async throws -> Void
    var finish: () async -> Void = {}
}

nonisolated struct MeetingModelGrant: Sendable {
    let attempt: UUID
    let generation: UUID
    let owner: String
    let modelID: String
}

nonisolated enum MeetingModelContext {
    @TaskLocal static var grant: MeetingModelGrant?
}

/// Admission and restoration have one owner. Snapshots contain values, never model references.
@MainActor
final class MeetingModelResidencyCoordinator {
    static let shared = MeetingModelResidencyCoordinator()

    enum Phase: String, Sendable {
        case normal, suspending, transcription, summary, cleaning, restoring, terminating
    }

    private(set) var phase: Phase = .normal
    private(set) var restorationErrors: [String] = []
    private var attempt: UUID?
    private var generation = UUID()
    private var operations: Set<UUID> = []
    private var vetoedOwners: Set<String> = []
    private var terminating = false

    var isExclusive: Bool { self.attempt != nil || self.terminating }

    var warmupGeneration: UUID? { self.isExclusive ? nil : self.generation }

    func canRunWarmup(_ generation: UUID?) -> Bool {
        generation != nil && generation == self.warmupGeneration
    }

    func beginOperation(owner: String, modelID: String) throws -> UUID {
        guard !self.terminating else { throw MeetingModelResidencyError.terminating }
        if let attempt {
            guard self.phase == .restoring || (self.phase == .transcription && owner == "speech"),
                  let grant = MeetingModelContext.grant,
                  grant.attempt == attempt, grant.generation == self.generation, grant.owner == owner, grant.modelID == modelID,
                  !self.vetoedOwners.contains(owner)
            else { throw MeetingModelResidencyError.busy }
        } else if MeetingModelContext.grant != nil {
            throw MeetingModelResidencyError.staleGrant
        }
        let token = UUID()
        self.operations.insert(token)
        return token
    }

    func endOperation(_ token: UUID) { self.operations.remove(token) }

    /// Decide whether an unload belongs to the meeting or ordinary work in one actor turn.
    /// Separate checks allow a meeting to start between checking exclusivity and admission.
    func vetoOrBeginOperation(owner: String, modelID: String, vetoDuringMeeting: Bool) throws -> UUID? {
        if self.isExclusive {
            if vetoDuringMeeting { self.vetoRestoration(owner: owner) }
            return nil
        }
        return try self.beginOperation(owner: owner, modelID: modelID)
    }

    /// Background enrollment may hold a second ASR model outside the transcription executor.
    /// Keep admission until the actual model call returns, even when its caller is cancelled.
    func withBackgroundOperation<T>(owner: String, modelID: String, work: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let token: UUID
        do { token = try self.beginOperation(owner: owner, modelID: modelID) } catch { throw CancellationError() } // Optional background work must remain retryable.
        defer { self.endOperation(token) }
        let result = try await work()
        try Task.checkCancellation()
        return result
    }

    /// Explicit unload/disable may remove restoration eligibility, never add a new model.
    func vetoRestoration(owner: String) { if self.attempt != nil { self.vetoedOwners.insert(owner) } }

    func beginTermination() {
        self.terminating = true
        self.phase = .terminating
    }

    nonisolated static func ordinary<T: Sendable>(
        owner: String, modelID: String, work: () async throws -> T
    ) async throws -> T {
        let token = try await self.shared.beginOperation(owner: owner, modelID: modelID)
        do {
            let value = try await work()
            await self.shared.endOperation(token)
            return value
        } catch {
            await self.shared.endOperation(token)
            throw error
        }
    }

    /// Compatibility backend uses the selected speech provider inside the exclusive meeting scope.
    /// This capability never admits Fluid models or ordinary warmups from another task.
    func withLegacySpeechModel<T>(modelID: String, work: () async throws -> T) async throws -> T {
        guard let attempt, self.phase == .transcription else { throw MeetingModelResidencyError.staleGrant }
        let grant = MeetingModelGrant(attempt: attempt, generation: self.generation, owner: "speech", modelID: modelID)
        return try await MeetingModelContext.$grant.withValue(grant, operation: work)
    }

    func markSummary() throws {
        guard self.attempt != nil, self.phase == .transcription else { throw MeetingModelResidencyError.staleGrant }
        self.phase = .summary
    }

    func withExclusive<T>(
        attemptID: UUID, participants: [MeetingModelParticipant],
        acceptsCompletedCancellation: (T) -> Bool = { _ in false }, work: () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !self.terminating else { throw MeetingModelResidencyError.terminating }
        guard self.attempt == nil, self.operations.isEmpty,
              Set(participants.map(\.owner)).count == participants.count
        else { throw MeetingModelResidencyError.busy }
        self.generation = UUID()
        self.attempt = attemptID
        self.phase = .suspending
        self.vetoedOwners.removeAll()
        self.restorationErrors.removeAll()
        var snapshots: [(MeetingModelParticipant, MeetingResidentModel)] = []
        var suspendedOwners: Set<String> = []
        do {
            // Close admission before any await, then snapshot everyone before unloading anyone.
            for participant in participants {
                if let snapshot = try await participant.snapshot() { snapshots.append((participant, snapshot)) }
                try Task.checkCancellation()
            }
            for participant in participants {
                suspendedOwners.insert(participant.owner)
                try await participant.suspend()
                try Task.checkCancellation()
                guard !self.terminating else { throw MeetingModelResidencyError.terminating }
            }
            self.phase = .transcription
            let value = try await work()
            if !acceptsCompletedCancellation(value) { try Task.checkCancellation() }
            await self.finish(attemptID: attemptID, snapshots: snapshots.filter { suspendedOwners.contains($0.0.owner) }, participants: participants)
            return value
        } catch {
            await self.finish(attemptID: attemptID, snapshots: snapshots.filter { suspendedOwners.contains($0.0.owner) }, participants: participants)
            throw error
        }
    }

    private func finish(attemptID: UUID, snapshots: [(MeetingModelParticipant, MeetingResidentModel)], participants: [MeetingModelParticipant]) async {
        guard self.attempt == attemptID else { return }
        self.phase = self.terminating ? .terminating : .cleaning
        // An unstructured joined task does not inherit the caller's cancelled status. Restoration
        // must run after a cancelled meeting, but never after termination has been requested.
        let cleanup = Task { @MainActor in
            for (participant, model) in snapshots {
                guard !self.terminating else { break }
                guard !self.vetoedOwners.contains(participant.owner) else { continue }
                self.phase = .restoring
                let grant = MeetingModelGrant(attempt: attemptID, generation: self.generation, owner: participant.owner, modelID: model.id)
                do {
                    try await MeetingModelContext.$grant.withValue(grant) {
                        try await participant.restore(model)
                    }
                    if self.vetoedOwners.contains(participant.owner) || self.terminating {
                        try await participant.suspend()
                    }
                } catch {
                    // A failed load may still own partial allocations. Drain them before another
                    // participant restores, and report the unloaded fallback without losing output.
                    try? await participant.suspend()
                    self.restorationErrors.append("\(participant.owner): \(error.localizedDescription)")
                    DebugLogger.shared.warning("Meeting saved; \(participant.owner) model could not reload: \(error.localizedDescription)", source: "MeetingModelResidency")
                }
            }
        }
        await cleanup.value
        for participant in participants {
            await participant.finish()
        }
        guard self.attempt == attemptID else { return }
        self.attempt = nil
        self.vetoedOwners.removeAll()
        self.phase = self.terminating ? .terminating : .normal
    }
}
