import Combine
import Foundation

/// Mirrors authoritative store snapshots only once search is requested.
/// Each kind retains at most one running snapshot and one replaceable successor.
@MainActor
final class SearchIndexCoordinator {
    static let shared = SearchIndexCoordinator()

    enum Snapshot {
        case history([TranscriptionHistoryEntry])
        case transcripts([FileTranscriptionEntry])
        case chats([ChatSession])

        var kind: SearchIndexKind {
            switch self {
            case .history: .history
            case .transcripts: .transcripts
            case .chats: .chats
            }
        }
    }

    enum PreparationError: LocalizedError {
        case timedOut

        var errorDescription: String? {
            "Search is taking longer than expected. Please try again."
        }
    }

    private struct PendingSnapshot {
        let generation: UInt64
        let snapshot: Snapshot
    }

    private struct Waiter {
        let id: UUID
        let generation: UInt64
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }

    private final class State {
        var generation: UInt64 = 0
        var completedGeneration: UInt64 = 0
        var latest: PendingSnapshot?
        var worker: Task<Void, Never>?
        var debounce: Task<Void, Never>?
        var waiters: [Waiter] = []
        var seeded = false
        var failure: (generation: UInt64, error: Error)?
        var needsRefresh = false
        var suppressedGeneration: UInt64 = 0
    }

    /// Chat metadata stays on the main actor; only immutable text fields cross it.
    private nonisolated struct ChatFields: Sendable {
        let id: UUID
        let revision: UInt64
        let timestamp: Date
        let parts: [String]

        var record: SearchIndexRecord {
            SearchIndexRecord(
                id: self.id,
                revision: self.revision,
                timestamp: self.timestamp,
                text: SearchIndexRecord.joined(self.parts)
            )
        }
    }

    private var cancellables: Set<AnyCancellable> = []
    private var states: [SearchIndexKind: State] = [:]
    private var stopped = false
    private var preparing = 0
    private var historyWaiters: [Waiter] = []
    private var historyLoad: Task<Void, Never>?
    private let preparationTimeout: Duration
    private let reconcile: @Sendable (SearchIndexKind, [SearchIndexRecord]) async throws -> SearchIndex.ReconcileReport
    private let refresh: @MainActor () -> Void

    init(
        index: SearchIndex = .shared,
        reconcile: (@Sendable (SearchIndexKind, [SearchIndexRecord]) async throws -> SearchIndex.ReconcileReport)? = nil,
        refresh: @escaping @MainActor () -> Void = { AppSearchService.shared.refresh() },
        preparationTimeout: Duration = .seconds(20)
    ) {
        self.reconcile = reconcile ?? { kind, records in
            try await index.reconcile(kind, with: records)
        }
        self.refresh = refresh
        self.preparationTimeout = preparationTimeout
    }

    /// Explicit callers retain write-through behavior. Production calls this lazily.
    func start(historyStore: TranscriptionHistoryStore? = nil) {
        guard !self.stopped, self.cancellables.isEmpty else { return }
        let historyStore = historyStore ?? .shared
        // This publisher never treats an incomplete or failed load as empty history.
        historyStore.loadedEntriesPublisher
            .sink { [weak self] in self?.submit(.history($0)) }
            .store(in: &self.cancellables)
        FileTranscriptionHistoryStore.shared.$entries
            .sink { [weak self] in self?.submit(.transcripts($0)) }
            .store(in: &self.cancellables)
        ChatHistoryStore.shared.$sessions
            .sink { [weak self] in self?.submit(.chats($0)) }
            .store(in: &self.cancellables)
    }

    /// The first query waits for complete history and its latest captured index state.
    /// Later edits cannot extend this barrier indefinitely: targets are fixed here.
    func prepareForSearch(historyStore: TranscriptionHistoryStore? = nil) async throws {
        guard !self.stopped else { throw CancellationError() }
        let historyStore = historyStore ?? .shared
        let deadline = ContinuousClock.now.advanced(by: self.preparationTimeout)
        var targets: [SearchIndexKind: UInt64] = [:]
        self.preparing += 1
        defer {
            self.preparing -= 1
            if self.preparing == 0 {
                let missedChange = self.states.contains { kind, state in
                    state.suppressedGeneration > (targets[kind] ?? state.generation)
                }
                for state in self.states.values {
                    state.suppressedGeneration = 0
                }
                if missedChange, !self.stopped { self.refresh() }
            }
        }
        self.start(historyStore: historyStore)
        try await self.waitForHistory(historyStore, until: deadline)
        try Task.checkCancellation()
        targets = self.states.mapValues(\.generation)
        try await self.waitUntilCurrent(targets: targets, deadline: deadline)
    }

    /// Retains raw values, so a burst never constructs text for discarded snapshots.
    func submit(_ snapshot: Snapshot) {
        guard !self.stopped else { return }
        let kind = snapshot.kind
        let state = self.state(for: kind)
        state.generation &+= 1
        state.latest = PendingSnapshot(generation: state.generation, snapshot: snapshot)
        state.debounce?.cancel()
        state.debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, let self, !self.stopped else { return }
            state.debounce = nil
            self.startWorker(kind, state: state)
        }
    }

    /// Flushes the debounce without building records on the caller's actor.
    func flush() {
        guard !self.stopped else { return }
        for (kind, state) in self.states {
            state.debounce?.cancel()
            state.debounce = nil
            self.startWorker(kind, state: state)
        }
    }

    /// A bounded barrier for snapshots already received; subsequent edits coalesce.
    func waitUntilCurrent() async throws {
        guard !self.stopped else { throw CancellationError() }
        let targets = self.states.mapValues(\.generation)
        try await self.waitUntilCurrent(
            targets: targets,
            deadline: ContinuousClock.now.advanced(by: self.preparationTimeout)
        )
    }

    private func waitUntilCurrent(targets: [SearchIndexKind: UInt64], deadline: ContinuousClock.Instant) async throws {
        self.flush()
        for (kind, generation) in targets {
            try Task.checkCancellation()
            try await self.wait(for: generation, kind: kind, deadline: deadline)
        }
    }

    /// Once stopped, this instance cannot reopen namespaces or refresh search again.
    func stop() async {
        self.stopped = true
        self.cancellables.removeAll()
        self.historyLoad?.cancel()
        self.historyLoad = nil
        for waiter in self.historyWaiters {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: CancellationError())
        }
        self.historyWaiters.removeAll()
        let workers = self.states.values.compactMap(\.worker)
        for state in self.states.values {
            state.debounce?.cancel()
            state.debounce = nil
            state.latest = nil
            self.finishWaiters(state, through: .max, result: .failure(CancellationError()))
        }
        for worker in workers {
            await worker.value
        }
    }

    private func state(for kind: SearchIndexKind) -> State {
        if let state = self.states[kind] { return state }
        let state = State()
        self.states[kind] = state
        return state
    }

    private func startWorker(_ kind: SearchIndexKind, state: State) {
        guard !self.stopped, state.worker == nil, state.latest != nil else { return }
        state.worker = Task { [weak self] in
            guard let self else { return }
            while !self.stopped, state.debounce == nil, let pending = state.latest {
                state.latest = nil
                state.debounce?.cancel()
                state.debounce = nil
                let records = await self.records(for: pending.snapshot)
                guard !self.stopped else { break }
                do {
                    let report = try await self.reconcile(kind, records)
                    let first = !state.seeded
                    state.seeded = true
                    state.completedGeneration = pending.generation
                    state.failure = nil
                    self.finishWaiters(state, through: pending.generation, result: .success(()))
                    state.needsRefresh = state.needsRefresh || report != SearchIndex.ReconcileReport() || (kind == .history && first)
                } catch {
                    state.failure = (state.generation, error)
                    self.finishWaiters(state, through: state.generation, result: .failure(error))
                    DebugLogger.shared.error(
                        "Search index \(kind.rawValue) reconcile failed: \(error)",
                        source: "SearchIndex"
                    )
                    // Preserve only the latest raw snapshot for a later retry. Never
                    // spin on a failed index or let older input replace newer input.
                    if state.latest == nil, !self.stopped { state.latest = pending }
                    break
                }
            }
            state.worker = nil
            if state.latest == nil {
                let shouldRefresh = state.needsRefresh
                state.needsRefresh = false
                if shouldRefresh, !self.stopped {
                    if self.preparing == 0 {
                        self.refresh()
                    } else {
                        state.suppressedGeneration = state.completedGeneration
                    }
                }
            }
        }
    }

    private func records(for snapshot: Snapshot) async -> [SearchIndexRecord] {
        switch snapshot {
        case let .history(entries):
            return await Task.detached(priority: .utility) {
                autoreleasepool { entries.map(\.searchRecord) }
            }.value
        case let .transcripts(entries):
            return await Task.detached(priority: .utility) {
                autoreleasepool { entries.map(\.searchRecord) }
            }.value
        case let .chats(sessions):
            let fields = sessions.compactMap { session -> ChatFields? in
                guard !session.isArchived, let id = UUID(uuidString: session.id) else { return nil }
                var parts = [session.title]
                for message in session.messages {
                    parts.append(message.content)
                    if let command = message.toolCall?.command { parts.append(command) }
                }
                return ChatFields(
                    id: id,
                    revision: session.searchRevision ?? UInt64(max(1, session.updatedAt.timeIntervalSince1970 * 1000)),
                    timestamp: session.updatedAt,
                    parts: parts
                )
            }
            return await Task.detached(priority: .utility) {
                autoreleasepool { fields.map(\.record) }
            }.value
        }
    }

    private func wait(for generation: UInt64, kind: SearchIndexKind, deadline: ContinuousClock.Instant) async throws {
        guard !self.stopped else { throw CancellationError() }
        let state = self.state(for: kind)
        guard state.completedGeneration < generation else { return }
        if state.worker == nil, let failure = state.failure, failure.generation >= generation {
            throw failure.error
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || self.stopped {
                    continuation.resume(throwing: CancellationError())
                } else {
                    state.waiters.append(Waiter(
                        id: id,
                        generation: generation,
                        continuation: continuation,
                        timeout: self.timeout(id: id, kind: kind, deadline: deadline)
                    ))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let state = self.states[kind],
                      let position = state.waiters.firstIndex(where: { $0.id == id }) else { return }
                let waiter = state.waiters.remove(at: position)
                waiter.timeout.cancel()
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func finishWaiters(_ state: State, through generation: UInt64, result: Result<Void, Error>) {
        let ready = state.waiters.filter { $0.generation <= generation }
        state.waiters.removeAll { $0.generation <= generation }
        for waiter in ready {
            waiter.timeout.cancel()
            waiter.continuation.resume(with: result)
        }
    }

    private func waitForHistory(_ store: TranscriptionHistoryStore, until deadline: ContinuousClock.Instant) async throws {
        guard !self.stopped else { throw CancellationError() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, !self.stopped else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.historyWaiters.append(Waiter(
                    id: id,
                    generation: 0,
                    continuation: continuation,
                    timeout: self.timeout(id: id, kind: nil, deadline: deadline)
                ))
                guard self.historyLoad == nil else { return }
                self.historyLoad = Task { [weak self] in
                    let result: Result<Void, Error>
                    do {
                        try await store.waitUntilLoaded()
                        result = .success(())
                    } catch {
                        result = .failure(error)
                    }
                    guard let self else { return }
                    self.historyLoad = nil
                    let waiters = self.historyWaiters
                    self.historyWaiters.removeAll()
                    for waiter in waiters {
                        waiter.timeout.cancel()
                        waiter.continuation.resume(with: result)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.removeWaiter(id: id, kind: nil, error: CancellationError()) }
        }
    }

    private func timeout(id: UUID, kind: SearchIndexKind?, deadline: ContinuousClock.Instant) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled else { return }
            self?.removeWaiter(id: id, kind: kind, error: PreparationError.timedOut)
        }
    }

    private func removeWaiter(id: UUID, kind: SearchIndexKind?, error: Error) {
        let waiter: Waiter
        if let kind {
            guard let state = self.states[kind], let position = state.waiters.firstIndex(where: { $0.id == id }) else { return }
            waiter = state.waiters.remove(at: position)
        } else {
            guard let position = self.historyWaiters.firstIndex(where: { $0.id == id }) else { return }
            waiter = self.historyWaiters.remove(at: position)
        }
        waiter.timeout.cancel()
        waiter.continuation.resume(throwing: error)
    }
}
