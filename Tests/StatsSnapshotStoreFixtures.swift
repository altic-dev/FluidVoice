import Combine

/// In-memory publisher only: tests never open the production history or settings.
@MainActor
final class TranscriptionHistoryStore {
    static let shared = TranscriptionHistoryStore()
    @Published var entries: [TranscriptionHistoryEntry] = []
}
