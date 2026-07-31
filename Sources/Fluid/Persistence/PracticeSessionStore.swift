//
//  PracticeSessionStore.swift
//  Voix
//
//  Persistence for speech-practice sessions.
//

import Combine
import Foundation

// MARK: - Entry

/// One practice session: what was said, how it was delivered, and what the coach said back.
///
/// Deliberately not `TranscriptionHistoryEntry`. That type is dictation-shaped
/// (target app name, window title, "was AI processed") and has consumers that
/// assume those fields mean something. None of it applies here.
///
/// ponytail: the recorded audio itself is not retained — only the analysis of it.
/// Per-session playback is v1.1; `DictationAudioHistoryStore` already has the WAV
/// plumbing when we want it.
nonisolated struct PracticeSession: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let durationSeconds: Double
    let transcript: String
    let feedback: String
    /// LLM that produced the feedback; empty when coaching failed or was skipped.
    let model: String
    /// Non-nil when the analysis succeeded but coaching did not. The session is
    /// still worth keeping — the measurements are the durable part.
    let coachingError: String?
    let metrics: DeliveryMetrics

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        durationSeconds: Double,
        transcript: String,
        feedback: String,
        model: String,
        coachingError: String? = nil,
        metrics: DeliveryMetrics
    ) {
        self.id = id
        self.date = date
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.feedback = feedback
        self.model = model
        self.coachingError = coachingError
        self.metrics = metrics
    }

    var previewText: String {
        let text = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 80 ? String(text.prefix(77)) + "..." : text
    }

    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self.date, relativeTo: Date())
    }

    var formattedDuration: String {
        let total = Int(self.durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Store

@MainActor
final class PracticeSessionStore: ObservableObject {
    static let shared = PracticeSessionStore()

    @Published private(set) var sessions: [PracticeSession] = []

    /// Sessions carry contour arrays and full coaching text, which is far more than
    /// belongs in UserDefaults (where the dictation history lives). A JSON file in
    /// Application Support keeps the preferences plist small.
    private let fileManager = FileManager.default
    /// Not "FluidVoice": the app is not sandboxed, so this folder name is the only
    /// thing separating Voix's data from an installed FluidVoice's.
    private let appSupportFolder = "Voix"
    private let fileName = "PracticeSessions.json"

    private let maximumSessions = 200

    init() {
        self.load()
    }

    // MARK: - Mutation

    func add(_ session: PracticeSession) {
        self.sessions.insert(session, at: 0)
        if self.sessions.count > self.maximumSessions {
            self.sessions.removeLast(self.sessions.count - self.maximumSessions)
        }
        self.save()
    }

    func delete(id: UUID) {
        self.sessions.removeAll { $0.id == id }
        self.save()
    }

    func deleteAll() {
        self.sessions.removeAll()
        self.save()
    }

    // MARK: - Persistence

    private func load() {
        guard let url = try? self.storeURL(createIfNeeded: false),
              self.fileManager.fileExists(atPath: url.path)
        else {
            self.sessions = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            self.sessions = try Self.decoder.decode([PracticeSession].self, from: data)
        } catch {
            // A corrupt or older-shaped file must not take the app down with it.
            DebugLogger.shared.error(
                "Failed to load practice sessions: \(error.localizedDescription)",
                source: "PracticeSessionStore"
            )
            self.sessions = []
        }
    }

    private func save() {
        do {
            let url = try self.storeURL(createIfNeeded: true)
            let data = try Self.encoder.encode(self.sessions)
            try data.write(to: url, options: .atomic)
        } catch {
            DebugLogger.shared.error(
                "Failed to save practice sessions: \(error.localizedDescription)",
                source: "PracticeSessionStore"
            )
        }
    }

    private func storeURL(createIfNeeded: Bool) throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = base.appendingPathComponent(self.appSupportFolder, isDirectory: true)
        if createIfNeeded {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(self.fileName, isDirectory: false)
    }

    /// Default date strategy, matching TranscriptionHistoryStore. ISO8601 would read
    /// better in the file but truncates sub-second precision, so a decoded session
    /// would no longer compare equal to the one that was written.
    nonisolated static let encoder = JSONEncoder()
    nonisolated static let decoder = JSONDecoder()
}
