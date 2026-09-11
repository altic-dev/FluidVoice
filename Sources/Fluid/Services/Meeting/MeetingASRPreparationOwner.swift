import Foundation

/// Rejection of a meeting ASR preparation request before or during claim.
nonisolated enum MeetingASRPreparationError: LocalizedError, Equatable {
    case invalidActivityLease
    case userModelDownloadInProgress
    case preparationInProgress

    var errorDescription: String? {
        switch self {
        case .invalidActivityLease:
            return "The meeting no longer holds the exclusive audio activity lease."
        case .userModelDownloadInProgress:
            return "Wait for the active voice model download to finish."
        case .preparationInProgress:
            return "Meeting transcription preparation is already in progress."
        }
    }
}

/// Immutable identity for one claimed preparation operation.
nonisolated struct MeetingASRPreparationClaimToken: Equatable, @unchecked Sendable {
    let lease: ASRActivityLease
    let operationID: UUID
}

/// Owns the meeting post-processing ASR provider slot: at most one claimed preparation
/// (provider, owned task, generated operation ID, immutable configuration) exists at a time.
/// The same lease+attempt+configuration joins the in-flight preparation or returns the ready
/// provider; any different request fails busy without cancelling the existing one.
///
/// The owner never acquires or releases the ASR activity lease itself — the caller keeps that
/// responsibility — and it never touches dictation state directly; every side effect goes
/// through the injected production closures. `isClaimed` stays true from the synchronous claim
/// through readiness and teardown; future service guards key on `isClaimed`/`isDraining`
/// rather than the exclusive-activity enum so legacy meetings keep working while unwired.
@MainActor
final class MeetingASRPreparationOwner {
    private struct Slot {
        let lease: ASRActivityLease
        let attemptID: UUID
        let operationID: UUID
        let configuration: MeetingFinalProcessingConfiguration
        var provider: (any TranscriptionProvider)?
        var task: Task<Void, Error>?
        var isReady = false

        var claimToken: MeetingASRPreparationClaimToken {
            MeetingASRPreparationClaimToken(lease: self.lease, operationID: self.operationID)
        }

        func matches(
            lease: ASRActivityLease,
            attemptID: UUID,
            configuration: MeetingFinalProcessingConfiguration
        ) -> Bool {
            self.lease == lease && self.attemptID == attemptID && self.configuration == configuration
        }
    }

    private let isActiveLease: @MainActor (ASRActivityLease) -> Bool
    private let isUserDownloadInProgress: @MainActor () -> Bool
    private let retireDictationResources: @MainActor (ASRActivityLease) async throws -> Void
    private let makeProvider: @MainActor (MeetingFinalProcessingConfiguration) throws -> any TranscriptionProvider
    private let prepareProvider: @MainActor (
        any TranscriptionProvider,
        MeetingFinalProcessingConfiguration,
        @escaping (ModelPreparationProgress) -> Void
    ) async throws -> Void
    private let drainExecutor: @MainActor (ASRActivityLease) async -> Void
#if DEBUG
    var didMarkReadyForTesting: (@MainActor () -> Void)?
    var didBeginWaitingForTesting: (@MainActor () -> Void)?
#endif

    private var slot: Slot?
    private var drainTask: Task<Void, Never>?

    init(
        isActiveLease: @escaping @MainActor (ASRActivityLease) -> Bool,
        isUserDownloadInProgress: @escaping @MainActor () -> Bool,
        retireDictationResources: @escaping @MainActor (ASRActivityLease) async throws -> Void,
        makeProvider: @escaping @MainActor (MeetingFinalProcessingConfiguration) throws -> any TranscriptionProvider,
        prepareProvider: @escaping @MainActor (
            any TranscriptionProvider,
            MeetingFinalProcessingConfiguration,
            @escaping (ModelPreparationProgress) -> Void
        ) async throws -> Void,
        drainExecutor: @escaping @MainActor (ASRActivityLease) async -> Void
    ) {
        self.isActiveLease = isActiveLease
        self.isUserDownloadInProgress = isUserDownloadInProgress
        self.retireDictationResources = retireDictationResources
        self.makeProvider = makeProvider
        self.prepareProvider = prepareProvider
        self.drainExecutor = drainExecutor
    }

    /// True from the synchronous claim through the ready state and the entire teardown.
    var isClaimed: Bool { self.slot != nil }

    /// True while a release drain is in flight, including its final state-clearing tail.
    var isDraining: Bool { self.drainTask != nil }

    /// Snapshot of the currently claimed operation. A caller must capture this on the main
    /// actor before scheduling a later release; cleanup never looks this value up dynamically.
    var currentClaimToken: MeetingASRPreparationClaimToken? { self.slot?.claimToken }

    @discardableResult
    func prepare(
        lease: ASRActivityLease,
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        progress: ((ModelPreparationProgress) -> Void)? = nil
    ) async throws -> any TranscriptionProvider {
        // Validation is pure: no claim, retirement, factory, or hook runs for a rejected request.
        try Task.checkCancellation()
        guard lease.activity == .meeting, self.isActiveLease(lease) else {
            throw MeetingASRPreparationError.invalidActivityLease
        }
        _ = try MeetingProviderOptions.resolve(configuration)
        guard !self.isUserDownloadInProgress() else {
            throw MeetingASRPreparationError.userModelDownloadInProgress
        }

        if self.slot != nil {
            guard self.drainTask == nil,
                  self.slot?.matches(
                      lease: lease, attemptID: attemptID, configuration: configuration
                  ) == true
            else { throw MeetingASRPreparationError.preparationInProgress }
            guard let token = self.slot?.claimToken else {
                throw MeetingASRPreparationError.preparationInProgress
            }
            if self.slot?.isReady == true, let provider = self.slot?.provider {
                try Task.checkCancellation()
                guard self.drainTask == nil,
                      self.isActiveLease(lease),
                      self.slot?.claimToken == token,
                      self.slot?.task?.isCancelled == false else {
                    throw CancellationError()
                }
                return provider
            }
            guard let task = self.slot?.task else {
                throw MeetingASRPreparationError.preparationInProgress
            }
            return try await self.awaitPreparation(task, token: token)
        }
        guard self.drainTask == nil else {
            throw MeetingASRPreparationError.preparationInProgress
        }

        // Claim synchronously before the first suspension so a racing request sees the slot.
        let operationID = UUID()
        let progressHandler = self.makeProgressHandler(
            lease: lease, operationID: operationID, progress: progress
        )
        let token = MeetingASRPreparationClaimToken(lease: lease, operationID: operationID)
        let task = Task { @MainActor [weak self] () throws -> Void in
            guard let self else { throw CancellationError() }
            try await self.performPreparation(
                lease: lease,
                operationID: operationID,
                configuration: configuration,
                progressHandler: progressHandler
            )
        }
        self.slot = Slot(
            lease: lease,
            attemptID: attemptID,
            operationID: operationID,
            configuration: configuration,
            task: task
        )
        return try await self.awaitPreparation(task, token: token)
    }

    /// Idempotent teardown for the exact claim token. Joins the single in-flight drain task if one
    /// exists; otherwise cancels and awaits the preparation task (a non-cooperative hook still
    /// runs to completion), drains the executor, then releases the provider and clears the
    /// claim. The ASR activity lease is never released here.
    func release(_ token: MeetingASRPreparationClaimToken) async {
        await self.drain(token: token)
    }

    private func awaitPreparation(
        _ task: Task<Void, Error>,
        token: MeetingASRPreparationClaimToken
    ) async throws -> any TranscriptionProvider {
        do {
            try await withTaskCancellationHandler {
#if DEBUG
                self.didBeginWaitingForTesting?()
#endif
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard self.drainTask == nil,
                  self.isActiveLease(token.lease),
                  self.slot?.claimToken == token,
                  self.slot?.isReady == true,
                  self.slot?.task?.isCancelled == false,
                  let provider = self.slot?.provider
            else {
                throw CancellationError()
            }
            return provider
        } catch {
            await self.drain(token: token)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func performPreparation(
        lease: ASRActivityLease,
        operationID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        progressHandler: @escaping (ModelPreparationProgress) -> Void
    ) async throws {
        try self.recheck(lease: lease, operationID: operationID)
        try await self.retireDictationResources(lease)
        try self.recheck(lease: lease, operationID: operationID)
        let provider = try self.makeProvider(configuration)
        self.adoptProvider(provider, operationID: operationID)
        try await self.prepareProvider(provider, configuration, progressHandler)
        try self.recheck(lease: lease, operationID: operationID)
        guard self.slot?.operationID == operationID else { throw CancellationError() }
        self.markReady(operationID: operationID)
#if DEBUG
        self.didMarkReadyForTesting?()
#endif
    }

    private func recheck(lease: ASRActivityLease, operationID: UUID) throws {
        try Task.checkCancellation()
        guard self.slot?.operationID == operationID,
              self.slot?.lease == lease,
              self.drainTask == nil,
              self.isActiveLease(lease)
        else { throw CancellationError() }
    }

    private func makeProgressHandler(
        lease: ASRActivityLease,
        operationID: UUID,
        progress: ((ModelPreparationProgress) -> Void)?
    ) -> (ModelPreparationProgress) -> Void {
        { [weak self] update in
            guard let progress else { return }
            // Providers report from arbitrary queues; hop to the main actor and drop anything
            // stale, cancelled, or draining by the time the hop lands.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let slot = self.slot,
                          slot.operationID == operationID,
                          slot.lease == lease,
                          !slot.isReady,
                          self.drainTask == nil,
                          self.isActiveLease(lease),
                          slot.task?.isCancelled == false
                    else { return }
                    progress(update)
                }
            }
        }
    }

    private func adoptProvider(_ provider: any TranscriptionProvider, operationID: UUID) {
        guard self.slot?.operationID == operationID else { return }
        self.slot?.provider = provider
    }

    private func markReady(operationID: UUID) {
        guard self.slot?.operationID == operationID else { return }
        self.slot?.isReady = true
    }

    private func clearSlot(operationID: UUID) {
        guard self.slot?.operationID == operationID else { return }
        self.slot = nil
    }

    /// Creates the one owned drain synchronously on the main actor. The worker only prepares;
    /// this task owns cancellation, executor draining, and the final state-clearing tail.
    private func drain(token: MeetingASRPreparationClaimToken) async {
        guard self.slot?.claimToken == token else { return }
        if let drainTask = self.drainTask {
            await drainTask.value
            return
        }

        let preparationTask = self.slot?.task
        let drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            preparationTask?.cancel()
            _ = await preparationTask?.result
            // This production hook must only drain executor state; it must not call back into
            // this owner, since that would attempt to await the drain task from itself.
            await self.drainExecutor(token.lease)
            self.clearSlot(operationID: token.operationID)
            self.drainTask = nil
        }
        self.drainTask = drainTask
        await drainTask.value
    }
}
