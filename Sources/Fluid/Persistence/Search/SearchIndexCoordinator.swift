import Combine
import Foundation

/// Keeps `SearchIndex` equal to the three stores it mirrors.
///
/// Each store publishes its whole array on every change, and `@Published` replays
/// the current value on subscription, so one subscription per store covers the
/// launch backfill and every later change with the same code path. The debounce
/// folds a burst of saves into one reconcile, and reconciles for one kind run in
/// order so two cannot interleave.
@MainActor
final class SearchIndexCoordinator {
    static let shared = SearchIndexCoordinator()

    private var cancellables: Set<AnyCancellable> = []
    private var pending: [SearchIndexKind: Task<Void, Never>] = [:]
    private let index = SearchIndex.shared

    func start() {
        guard self.cancellables.isEmpty else { return }
        self.mirror(.history, TranscriptionHistoryStore.shared.$entries.map { $0.map(\.searchRecord) })
        self.mirror(.transcripts, FileTranscriptionHistoryStore.shared.$entries.map { $0.map(\.searchRecord) })
        self.mirror(.chats, ChatHistoryStore.shared.$sessions.map { $0.compactMap(\.searchRecord) })
    }

    private func mirror<P: Publisher>(
        _ kind: SearchIndexKind,
        _ records: P
    ) where P.Output == [SearchIndexRecord], P.Failure == Never {
        records
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] records in
                guard let self else { return }
                let previous = self.pending[kind]
                self.pending[kind] = Task { [index] in
                    await previous?.value
                    do {
                        let report = try await index.reconcile(kind, with: records)
                        if report != SearchIndex.ReconcileReport() {
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
