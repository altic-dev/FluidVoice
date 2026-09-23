import Combine
import CryptoKit
import Foundation

nonisolated enum MeetingSummaryKind: String, CaseIterable, Identifiable, Codable {
    case executive, detailed, actions, decisions, participants, topics
    var id: String { self.rawValue }
    var title: String {
        switch self {
        case .executive: "Executive summary"
        case .detailed: "Detailed summary"
        case .actions: "Action items"
        case .decisions: "Key decisions"
        case .participants: "Participants"
        case .topics: "Topics discussed"
        }
    }
}

nonisolated enum MeetingSummaryInput {
    static func transcript(for session: MeetingSession) -> String {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let date = formatter.string(from: session.startedAt)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: session.startedAt)
        let duration = max(0, (session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt) / 60)
        let turns = session.transcriptSegments.filter { !$0.isEcho }.sorted { $0.start.seconds < $1.start.seconds }
        return """
        Title: \(session.title)
        Date: \(date)
        Time: \(time)
        Duration: \(Int(duration)) minutes
        Participants: \(session.activeSpeakers.map(\.displayName).joined(separator: ", "))
        ----------
        """ + "\n" + turns.map {
            "**\(MeetingTranscriptExporter.speakerLabel(for: $0, in: session, speakerNames: names))**: \($0.text)"
        }.joined(separator: "\n")
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps summary admission separate from ordinary processing, including cloud calls that
/// do not own a local-model residency token. Tokens survive cancellation until work drains.
@MainActor
final class MeetingSummaryActivityCoordinator: ObservableObject {
    static let shared = MeetingSummaryActivityCoordinator()
    private var processing: Set<UUID> = []
    private var summary: UUID?
    @Published private(set) var selectionLock: UUID?

    /// Acquired synchronously by the button action, before generation's task starts.
    func lockSelection() -> UUID? {
        guard self.selectionLock == nil else { return nil }
        let token = UUID()
        self.selectionLock = token
        return token
    }

    func unlockSelection(_ token: UUID) {
        guard self.selectionLock == token else { return }
        self.selectionLock = nil
    }

    func beginProcessing() -> UUID? {
        guard self.summary == nil else { return nil }
        let token = UUID()
        self.processing.insert(token)
        return token
    }

    func endProcessing(_ token: UUID) { self.processing.remove(token) }

    static func presentBusyError() {
        let asr = AppServices.shared.asr
        asr.errorTitle = "Summary in Progress"
        asr.errorMessage = "Wait for the meeting summary to finish, then try again."
        asr.showError = true
    }

    func withSummary<T>(activity: any ASRActivityLeasing, work: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard self.summary == nil, self.processing.isEmpty else { throw MeetingModelResidencyError.busy }
        let token = UUID()
        self.summary = token
        defer { if self.summary == token { self.summary = nil } }
        let lease = try activity.acquireExclusiveActivity(.meeting)
        do {
            try await activity.prepareMeetingAudioHandoff(lease)
            try Task.checkCancellation()
            let value = try await work()
            await Task { await activity.completeMeetingAudioHandback(lease) }.value
            return value
        } catch {
            await Task { await activity.completeMeetingAudioHandback(lease) }.value
            throw error
        }
    }
}

@MainActor
final class MeetingSummaryController: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var checking = true
    @Published private(set) var downloading = false
    @Published private(set) var generating = false
    @Published private(set) var deleting = false
    @Published private(set) var progress: PrivateAIModelDownloadProgress?
    @Published private(set) var output = ""
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    var busy: Bool { self.downloading || self.generating || self.deleting }
    var model: PrivateAIRegisteredModel? {
        PrivateAIModelRegistry.modelIDs(for: .meetingSummary).first.flatMap { PrivateAIModelRegistry.model(id: $0) }
    }

    private nonisolated struct SavedSummary: Codable, Sendable {
        let transcriptHash: String
        let modelID: String
        let text: String
    }

    func refresh(session: MeetingSession?, kind: MeetingSummaryKind) async {
        guard !self.busy else { return }
        let generation = UUID()
        self.generation = generation
        self.output = ""
        self.error = nil
        self.checking = true
        let model = self.model
        let modelID = model?.id
        let snapshot = await Task.detached(priority: .utility) { () -> (Bool, String) in
            let installed = model.map { PrivateAIIntegrationService.isModelInstalled($0) } ?? false
            guard let session, let modelID,
                  let directory = try? await MeetingSessionStore.shared.existingSessionDirectory(for: session.id),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json")),
                  let saved = try? JSONDecoder().decode(SavedSummary.self, from: data),
                  saved.modelID == modelID,
                  saved.transcriptHash == MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session))
            else { return (installed, "") }
            return (installed, saved.text)
        }.value
        guard self.generation == generation, !Task.isCancelled else { return }
        self.installed = snapshot.0
        self.output = snapshot.1
        self.checking = false
    }

    func download() {
        guard !self.busy, let model else { return }
        self.downloading = true
        self.error = nil
        self.progress = .init(initialExpectedBytes: model.artifact.byteCount)
        self.operation = Task { [weak self] in
            guard let self else { return }
            defer { self.downloading = false; self.operation = nil }
            do {
                _ = try await PrivateAIIntegrationService.prepareModel(model) { [weak self] progress in
                    await self?.receiveProgress(progress)
                }
                try Task.checkCancellation()
                self.installed = true
            } catch is CancellationError {
                self.error = nil
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    func deleteModel(asr: ASRService) {
        guard !self.busy, !self.checking, self.installed, let model else { return }
        self.generation = UUID()
        self.deleting = true
        self.error = nil
        self.operation = Task { [weak self] in
            guard let self else { return }
            defer { self.deleting = false; self.operation = nil }
            do {
                try await MeetingSummaryActivityCoordinator.shared.withSummary(activity: asr) {
                    try await asr.withMeetingModelResidency(attemptID: UUID()) {
                        try Task.checkCancellation()
                        try await Task.detached(priority: .utility) {
                            try PrivateAIIntegrationService.removeInstalledModel(model)
                        }.value
                    }
                }
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
            // Reconcile partial removal too; saved summaries and selections stay untouched.
            self.installed = await Task.detached(priority: .utility) {
                PrivateAIIntegrationService.isModelInstalled(model)
            }.value
        }
    }

    func summarize(session: MeetingSession, kind: MeetingSummaryKind, asr: ASRService) {
        guard !self.busy, self.installed, let model,
              let selectionLock = MeetingSummaryActivityCoordinator.shared.lockSelection() else { return }
        self.generating = true
        self.error = nil
        self.operation = Task {
            defer {
                self.generating = false
                self.operation = nil
                MeetingSummaryActivityCoordinator.shared.unlockSelection(selectionLock)
            }
            do {
                try await MeetingSummaryActivityCoordinator.shared.withSummary(activity: asr) {
                    let transcript = await Task.detached(priority: .utility) { MeetingSummaryInput.transcript(for: session) }.value
                    guard transcript.utf8.count <= 96_000 else { throw MeetingPostProcessingError.inputTooLarge }
                    guard session.transcriptSegments.contains(where: { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                        throw MeetingPostProcessingError.invalidOutput
                    }
                    try Task.checkCancellation()
                    let text = try await asr.withMeetingModelResidency(attemptID: UUID()) {
                        try MeetingModelResidencyCoordinator.shared.markSummary()
                        return try await PrivateAIIntegrationService.summarizeMeeting(transcript, style: kind.rawValue)
                    }
                    try Task.checkCancellation()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingPostProcessingError.invalidOutput }
                    self.output = text
                    guard let directory = try await MeetingSessionStore.shared.existingSessionDirectory(for: session.id) else { return }
                    let saved = SavedSummary(transcriptHash: MeetingSummaryInput.fingerprint(transcript), modelID: model.id, text: text)
                    try await Task.detached(priority: .utility) {
                        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"), options: .atomic)
                    }.value
                }
            } catch is CancellationError {
                self.error = nil
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    private func receiveProgress(_ progress: PrivateAIModelDownloadProgress) { self.progress = progress }

    func cancel() { self.operation?.cancel() }
}
