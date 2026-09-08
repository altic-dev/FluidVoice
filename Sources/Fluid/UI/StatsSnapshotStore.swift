import AppKit
import Combine

/// Only aggregates while Stats is visible; keeps one small result for subsequent visits.
@MainActor
final class StatsSnapshotStore: ObservableObject {
    static let shared = StatsSnapshotStore(history: .shared)

    @Published private(set) var snapshot: StatsSnapshot?
    @Published private(set) var isUpdating = false
    private let history: TranscriptionHistoryStore
    private var subscriptions = Set<AnyCancellable>()
    private var owners = Set<UUID>()
    private var revision: UInt64 = 0
    private var completedRevision: UInt64?
    private var completedDay: Date?
    private var task: Task<Void, Never>?

    init(history: TranscriptionHistoryStore) {
        self.history = history
        history.$entries.sink { [weak self] entries in
            guard let self else { return }
            self.revision &+= 1
            self.task?.cancel()
            self.task = nil
            self.isUpdating = false
            if entries.isEmpty { self.snapshot = nil }
            if !self.owners.isEmpty { self.refresh(entries: entries) }
        }.store(in: &self.subscriptions)

        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                self.revision &+= 1
                if !self.owners.isEmpty { self.refresh(entries: self.history.entries) }
            }.store(in: &self.subscriptions)
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, !self.owners.isEmpty else { return }
                self.refreshIfNeeded()
            }.store(in: &self.subscriptions)
    }

    func activate(_ owner: UUID) {
        self.owners.insert(owner)
        self.refreshIfNeeded()
    }

    func deactivate(_ owner: UUID) {
        self.owners.remove(owner)
        if self.owners.isEmpty {
            self.task?.cancel()
            self.task = nil
            self.isUpdating = false
        }
    }

    private func refreshIfNeeded() {
        guard self.completedRevision != self.revision || self.completedDay != Calendar.current.startOfDay(for: Date()) else { return }
        self.refresh(entries: self.history.entries)
    }

    private func refresh(entries: [TranscriptionHistoryEntry]) {
        self.task?.cancel()
        let revision = self.revision
        let calendar = Calendar.current
        let now = Date()
        self.isUpdating = true
        self.task = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                // Coalesce a burst of history mutations without delaying navigation.
                try await Task.sleep(nanoseconds: 50_000_000)
                return try StatsSnapshot.build(entries: entries, now: now, calendar: calendar)
            }
            let value = await withTaskCancellationHandler {
                try? await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.revision == revision, !self.owners.isEmpty else { return }
            self.isUpdating = false
            self.task = nil
            guard let value else { return }
            self.snapshot = value
            self.completedRevision = revision
            self.completedDay = calendar.startOfDay(for: now)
        }
    }
}
