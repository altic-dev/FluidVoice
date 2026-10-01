import Combine
import CryptoKit
import Foundation

nonisolated enum MeetingSummaryKind: String, CaseIterable, Identifiable, Codable {
    case executive, detailed, actions, decisions, participants, topics
    var id: String {
        self.rawValue
    }

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
    @Published private(set) var isProcessing = false
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
        self.isProcessing = true
        return token
    }

    func endProcessing(_ token: UUID) {
        self.processing.remove(token)
        self.isProcessing = !self.processing.isEmpty
    }

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
    @Published private(set) var outputProvenance = ""
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    var busy: Bool {
        self.downloading || self.generating || self.deleting
    }

    var model: PrivateAIRegisteredModel? {
        PrivateAIModelRegistry.modelIDs(for: .meetingSummary).first.flatMap { PrivateAIModelRegistry.model(id: $0) }
    }

    nonisolated struct SavedSummary: Codable {
        let transcriptHash: String
        let modelID: String
        let text: String
        var providerID: String?
        var providerName: String?
        var configurationHash: String?
        var promptVersion: Int?
        var generatedAt: Date?

        var provenance: String {
            "\(self.providerName ?? "Fluid Intelligence") · \(self.modelID)"
        }
    }

    func refresh(session: MeetingSession?, kind: MeetingSummaryKind) async {
        guard !self.busy else { return }
        let generation = UUID()
        self.generation = generation
        self.output = ""
        self.outputProvenance = ""
        self.error = nil
        self.checking = true
        let model = self.model
        let snapshot = await Task.detached(priority: .utility) { () -> (Bool, SavedSummary?) in
            let installed = model.map { PrivateAIIntegrationService.isModelInstalled($0) } ?? false
            guard let session,
                  let directory = try? await MeetingSessionStore.shared.existingSessionDirectory(for: session.id),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json")),
                  let saved = try? JSONDecoder().decode(SavedSummary.self, from: data),
                  saved.transcriptHash == MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session))
            else { return (installed, nil) }
            return (installed, saved)
        }.value
        guard self.generation == generation, !Task.isCancelled else { return }
        self.installed = snapshot.0
        self.output = snapshot.1?.text ?? ""
        self.outputProvenance = snapshot.1?.provenance ?? ""
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

    func summarize(session: MeetingSession, kind: MeetingSummaryKind, asr: ASRService, route: MeetingSummaryRoute) {
        guard !self.busy, !self.checking, !route.isOnDevice || self.installed,
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
                    guard session.transcriptSegments.contains(where: { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                        throw MeetingPostProcessingError.invalidOutput
                    }
                    try Task.checkCancellation()
                    let text: String
                    if route.isOnDevice {
                        guard transcript.utf8.count <= 96_000 else { throw MeetingPostProcessingError.inputTooLarge }
                        text = try await asr.withMeetingModelResidency(attemptID: UUID()) {
                            try MeetingModelResidencyCoordinator.shared.markSummary()
                            return try await PrivateAIIntegrationService.summarizeMeeting(transcript, style: kind.rawValue)
                        }
                    } else if route.cli != nil {
                        text = try await MeetingSummaryCLIService.generate(transcript: transcript, kind: kind, route: route)
                    } else {
                        text = try await MeetingSummaryRemoteService.shared.generate(transcript: transcript, kind: kind, route: route)
                    }
                    try Task.checkCancellation()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingPostProcessingError.invalidOutput }
                    guard let directory = try await MeetingSessionStore.shared.existingSessionDirectory(for: session.id) else {
                        throw MeetingPostProcessingError.checkpointFailed
                    }
                    let saved = SavedSummary(
                        transcriptHash: MeetingSummaryInput.fingerprint(transcript),
                        modelID: route.modelID,
                        text: text,
                        providerID: route.providerID,
                        providerName: route.providerName,
                        configurationHash: route.configurationHash,
                        promptVersion: 1,
                        generatedAt: Date()
                    )
                    try await Task.detached(priority: .utility) {
                        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"), options: .atomic)
                    }.value
                    self.output = text
                    self.outputProvenance = saved.provenance
                }
            } catch is CancellationError {
                self.error = nil
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    private func receiveProgress(_ progress: PrivateAIModelDownloadProgress) {
        self.progress = progress
    }

    func cancel() {
        self.operation?.cancel()
    }
}
