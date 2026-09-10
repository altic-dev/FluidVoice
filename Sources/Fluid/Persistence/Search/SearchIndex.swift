import Foundation
import ZeppelinEmbed

/// The full-text index behind the sidebar search: one record-only Zeppelin
/// namespace per `SearchIndexKind`.
///
/// This is a derived copy. The stores in `UserDefaults` remain the source of truth,
/// so a namespace that is missing, reset, or from another build is simply rebuilt
/// from its store.
///
/// The one write operation is `reconcile`: compare what the store has with what the
/// namespace has, delete the rest, upsert the difference. It is idempotent, so the
/// same call is the launch backfill, the write-through after a change, the cleanup
/// after a store evicts rows past its cap, and the recovery after a reset. An
/// interrupted run leaves nothing to undo; the next run finishes it.
actor SearchIndex {
    static let shared = SearchIndex()

    struct ReconcileReport: Equatable, Sendable {
        var upserted = 0
        var deleted = 0
    }

    struct Hit: Equatable, Sendable {
        let id: UUID
        let score: Double
    }

    private let root: FluidZeppelinRoot

    init(root: FluidZeppelinRoot = .shared) {
        self.root = root
    }

    /// No attributes: there is no filtered lexical query, and grouping is by
    /// namespace. No vector space: this index is words only.
    static let spec = NamespaceSpec(attributes: [], vectorSpace: nil)

    func namespace(_ kind: SearchIndexKind) async throws -> ZeppelinStore {
        try await self.root.namespace(kind.rawValue, spec: Self.spec)
    }

    // MARK: - Reconcile

    /// Makes the namespace equal to `records`.
    @discardableResult
    func reconcile(
        _ kind: SearchIndexKind,
        with records: [SearchIndexRecord]
    ) async throws -> ReconcileReport {
        let store = try await self.namespace(kind)
        var report = ReconcileReport()

        var indexed: [UUID: UInt64] = [:]
        for try await document in store.documents(fields: []) {
            indexed[document.id.uuid] = document.revision
        }

        var wanted = Set<UUID>()
        var pending: [SearchIndexRecord] = []
        for record in records {
            wanted.insert(record.id)
            guard let revision = indexed[record.id] else {
                pending.append(record)
                continue
            }
            // Equal: already indexed. Higher: a newer snapshot has already won,
            // so reconciliation must not replace it with stale input.
            if revision < record.revision {
                pending.append(record)
            }
        }
        let stale = indexed.keys
            .filter { !wanted.contains($0) }
            .map { DocumentID(uuid: $0) }

        if !stale.isEmpty {
            _ = try await store.delete(stale)
            report.deleted = stale.count
        }
        if !pending.isEmpty {
            _ = try await store.upsert(pending.map(Self.document))
            report.upserted = pending.count
        }
        if report != ReconcileReport() {
            await DebugLogger.shared.info(
                "Search index \(kind.rawValue): +\(report.upserted) -\(report.deleted)",
                source: "SearchIndex"
            )
        }
        return report
    }

    private static func document(_ record: SearchIndexRecord) -> IngestDocument {
        IngestDocument(
            id: DocumentID(uuid: record.id),
            revision: record.revision,
            timestamp: Int64(record.timestamp.timeIntervalSince1970 * 1000),
            vector: [],
            text: record.text
        )
    }

    // MARK: - Query

    /// Ranked ids for `text`. The last word is matched as a prefix so results appear
    /// while the user types. Scores are only comparable within one kind.
    func query(
        _ kind: SearchIndexKind,
        text: String,
        limit: Int,
        cancellationToken: ZeppelinCancellationToken? = nil
    ) async throws -> [Hit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let store = try await self.namespace(kind)
        let result = try await store.query(
            text: trimmed,
            options: QueryOptions(
                k: limit,
                lastAsPrefix: true,
                cancellationToken: cancellationToken
            )
        )
        return result.hits.compactMap { hit in
            hit.documentID.map { Hit(id: $0.uuid, score: hit.score) }
        }
    }
}
