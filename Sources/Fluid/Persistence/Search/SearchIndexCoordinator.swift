import Combine
import Foundation

/// Keeps `SearchIndex` equal to the three stores it mirrors.
///
/// Each store publishes its whole array on every change and replays its current
/// snapshot on subscription. History waits until its asynchronous load succeeds,
/// so an incomplete snapshot cannot erase the index. One subscription per store
/// covers the launch backfill and every later change with the same code path.
/// The debounce folds a burst of saves into one reconcile, and reconciles for
/// one kind run in order so two cannot interleave.
@MainActor
final class SearchIndexCoordinator {
    static let shared = SearchIndexCoordinator()

    private var cancellables: Set<AnyCancellable> = []
    private var pending: [SearchIndexKind: Task<Void, Never>] = [:]
    private var seeded: Set<SearchIndexKind> = []
    private let index: SearchIndex

    init(index: SearchIndex = .shared) {
        self.index = index
    }

    func start(historyStore: TranscriptionHistoryStore = .shared) {
        guard self.cancellables.isEmpty else { return }
        // Results join the index against `TranscriptionHistoryStore.entries`, which is
        // empty until the load finishes. A query typed before then finds nothing to
        // join, and an index already equal to the loaded history reconciles to no
        // change, so the first snapshot has to refresh on its own.
        self.mirror(
            .history,
            historyStore.loadedEntriesPublisher.map { $0.map(\.searchRecord) },
            refreshOnFirstSnapshot: true
        )
        self.mirror(.transcripts, FileTranscriptionHistoryStore.shared.$entries.map { $0.map(\.searchRecord) })
        self.mirror(.chats, ChatHistoryStore.shared.$sessions.map { $0.compactMap(\.searchRecord) })
    }

    private func mirror<P: Publisher>(
        _ kind: SearchIndexKind,
        _ records: P,
        refreshOnFirstSnapshot: Bool = false
    ) where P.Output == [SearchIndexRecord], P.Failure == Never {
        records
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] records in
                guard let self else { return }
                let isFirstSnapshot = self.seeded.insert(kind).inserted
                let previous = self.pending[kind]
                self.pending[kind] = Task { [index] in
                    await previous?.value
                    do {
                        let report = try await index.reconcile(kind, with: records)
                        if report != SearchIndex.ReconcileReport() || (refreshOnFirstSnapshot && isFirstSnapshot) {
                            AppSearchService.shared.refresh()
                        }
                    } catch {
                        DebugLogger.shared.error(
                            "Search index \(kind.rawValue) reconcile failed: \(error)",
                            source: "SearchIndex"
                        )
                    }
                }
            }
            .store(in: &self.cancellables)
    }
}
