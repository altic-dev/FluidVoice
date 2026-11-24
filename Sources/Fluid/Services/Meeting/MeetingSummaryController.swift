import Combine
import CryptoKit
import Foundation

nonisolated enum MeetingSummaryKind: String, CaseIterable, Identifiable, Codable {
    case executive, detailed, actions, decisions, participants, topics, custom
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
        case .custom: "Custom prompt"
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
        // A saved meeting keeps whole seconds. Count the same way here, so the text (and the fingerprint
        // that decides whether a saved summary is still shown) is the same before and after a restart.
        let startSeconds = session.startedAt.timeIntervalSinceReferenceDate.rounded(.down)
        let endSeconds = (session.endedAt ?? session.startedAt).timeIntervalSinceReferenceDate.rounded(.down)
        let duration = max(0, (endSeconds - startSeconds) / 60)
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

    static func contentFingerprint(for session: MeetingSession) -> String {
        // Keep the title in the model's input, but exclude it from summary validity.
        var source = session
        source.title = ""
        return self.fingerprint(self.transcript(for: source))
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
    private var remoteSummary: UUID?
    @Published private(set) var selectionLock: UUID?
    private let isMeetingActive: @MainActor () -> Bool

    var isSummarizing: Bool {
        self.summary != nil
    }

    init(isMeetingActive: @escaping @MainActor () -> Bool = { AppServices.shared.asr.activeExclusiveActivity == .meeting }) {
        self.isMeetingActive = isMeetingActive
    }

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

    /// Cloud summaries hold neither the audio lease nor the processing gate that on-device
    /// summaries need, so dictation, Command Mode, and Rewrite keep working while a provider responds.
    func withRemoteSummary<T>(work: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard self.remoteSummary == nil, self.summary == nil else { throw MeetingModelResidencyError.busy }
        let token = UUID()
        self.remoteSummary = token
        defer {
            if self.remoteSummary == token {
                self.remoteSummary = nil
            }
        }
        return try await work()
    }

    /// On-device summaries only contend with the local LLM, so they take no audio lease and
    /// leave speech recognition loaded: dictation keeps working while a summary runs.
    func withSummary<T>(work: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard self.summary == nil, self.remoteSummary == nil, self.processing.isEmpty else { throw MeetingModelResidencyError.busy }
        // Meeting processing needs exclusive model residency; the arbiter refuses new meetings while this runs.
        guard !self.isMeetingActive() else { throw ASRActivityError.activityInProgress(.meeting) }
        let token = UUID()
        self.summary = token
        defer { if self.summary == token { self.summary = nil } }
        return try await work()
    }

    /// Unloads only the local LLM for the duration of `work`, then restores it.
    static func withSummaryModelResidency<T>(work: () async throws -> T) async throws -> T {
        try await MeetingModelResidencyCoordinator.shared.withExclusive(
            attemptID: UUID(),
            participants: [PrivateAIIntegrationService.meetingResidencyParticipant()],
            exemptOwners: ["speech", "dictionary-vad"],
            work: work
        )
    }
}

@MainActor
final class MeetingSummaryController: ObservableObject {
    @Published private(set) var installed = false
    @Published private(set) var checking = true
    @Published private(set) var downloading = false
    @Published private(set) var deleting = false
    @Published private(set) var progress: PrivateAIModelDownloadProgress?
    @Published private(set) var output = ""
    @Published private(set) var outputProvenance = ""
    @Published private(set) var outputNotice = ""
    /// The transcript or speaker names changed after the shown summary was written.
    @Published private(set) var outputIsOutdated = false
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let store: any MeetingSessionStoring

    init(store: any MeetingSessionStoring = MeetingSessionStore.shared) {
        self.store = store
    }

    var busy: Bool {
        self.downloading || self.deleting
    }

    var model: PrivateAIRegisteredModel? {
        PrivateAIModelRegistry.modelIDs(for: .meetingSummary).first.flatMap { PrivateAIModelRegistry.model(id: $0) }
    }

    nonisolated struct SavedSummary: Codable {
        static let currentTranscriptHashVersion = 2

        var transcriptHash: String
        let modelID: String
        let text: String
        var providerID: String?
        var providerName: String?
        var configurationHash: String?
        var promptVersion: Int?
        var generatedAt: Date?
        /// The custom prompt a summary was written with, kept as a record.
        var promptHash: String?
        /// Display name of an on-device model, whose ID is not meant to be read.
        var modelName: String?
        /// Version 2 excludes the meeting title. A missing version uses the original full input.
        var transcriptHashVersion: Int?

        var provenance: String {
            "\(self.providerName ?? "Fluid Intelligence") · \(self.modelName ?? self.modelID)"
        }

        var notice: String {
            self.providerID == MeetingSummaryOnDevice.providerID
                ? "Generated by AI on your Mac. May contain mistakes."
                : "Generated by AI. May contain mistakes."
        }

        /// Summaries saved before providers were recorded came from the earlier on-device
        /// model, which was withdrawn for accuracy; they stay hidden.
        var isShown: Bool {
            self.providerID != nil
        }

        /// The transcript or speaker names changed since this summary was written. It is still shown, with a warning.
        func isOutdated(for session: MeetingSession) -> Bool {
            let hash: String?
            switch self.transcriptHashVersion {
            case nil:
                hash = MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session))
            case Self.currentTranscriptHashVersion:
                hash = MeetingSummaryInput.contentFingerprint(for: session)
            default:
                hash = nil
            }
            return hash != self.transcriptHash
        }

        /// Upgrade before saving a rename, while the original title can still verify old files.
        /// Each upgrade remains valid even if a later write (including the rename) fails.
        static func migrateLegacySummaries(in directory: URL, for session: MeetingSession) throws {
            let legacyHash = MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session))
            let contentHash = MeetingSummaryInput.contentFingerprint(for: session)
            for kind in MeetingSummaryKind.allCases {
                let url = directory.appendingPathComponent("manual-summary-\(kind.rawValue).json")
                guard var saved = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url)),
                      saved.transcriptHashVersion == nil,
                      saved.providerID != nil,
                      saved.transcriptHash == legacyHash
                else { continue }
                saved.transcriptHash = contentHash
                saved.transcriptHashVersion = Self.currentTranscriptHashVersion
                try JSONEncoder().encode(saved).write(to: url, options: .atomic)
            }
        }
    }

    func refresh(session: MeetingSession?, kind: MeetingSummaryKind) async {
        guard !self.busy else { return }
        let generation = UUID()
        self.generation = generation
        self.show(nil)
        self.error = nil
        self.checking = true
        let model = self.model
        let store = self.store
        let snapshot = await Task.detached(priority: .utility) { () -> (installed: Bool, saved: SavedSummary?, isOutdated: Bool) in
            let installed = model.map { PrivateAIIntegrationService.isModelInstalled($0) } ?? false
            guard let session,
                  let directory = try? await store.existingSessionDirectory(for: session.id),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json")),
                  let saved = try? JSONDecoder().decode(SavedSummary.self, from: data),
                  saved.isShown
            else { return (installed, nil, false) }
            return (installed, saved, saved.isOutdated(for: session))
        }.value
        guard self.generation == generation, !Task.isCancelled else { return }
        self.installed = snapshot.installed
        self.show(snapshot.saved, isOutdated: snapshot.isOutdated)
        self.checking = false
    }

    private func show(_ saved: SavedSummary?, isOutdated: Bool = false) {
        self.output = saved?.text ?? ""
        self.outputProvenance = saved?.provenance ?? ""
        self.outputNotice = saved?.notice ?? ""
        self.outputIsOutdated = isOutdated
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

    func deleteModel() {
        guard !self.busy, !self.checking, self.installed, let model else { return }
        self.generation = UUID()
        self.deleting = true
        self.error = nil
        self.operation = Task { [weak self] in
            guard let self else { return }
            defer { self.deleting = false; self.operation = nil }
            do {
                try await MeetingSummaryActivityCoordinator.shared.withSummary {
                    try await MeetingSummaryActivityCoordinator.withSummaryModelResidency {
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

    private func receiveProgress(_ progress: PrivateAIModelDownloadProgress) {
        self.progress = progress
    }

    func cancelModelOperation() {
        self.operation?.cancel()
    }
}

/// One app-wide summary job. Views can disappear while the model runs and reattach to its state.
@MainActor
final class MeetingSummaryGeneration: ObservableObject {
    struct Request {
        let sessionID: MeetingSessionID
        let kind: MeetingSummaryKind
        let promptHash: String?
    }

    @Published private(set) var request: Request?
    @Published private(set) var isRunning = false
    @Published private(set) var savedRevision = 0
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private let store: any MeetingSessionStoring
    private let remoteService: MeetingSummaryRemoteService
    private let activity: MeetingSummaryActivityCoordinator

    init(
        store: any MeetingSessionStoring = MeetingSessionStore.shared,
        remoteService: MeetingSummaryRemoteService = .shared,
        activity: MeetingSummaryActivityCoordinator = .shared
    ) {
        self.store = store
        self.remoteService = remoteService
        self.activity = activity
    }

    func summarize(session: MeetingSession, kind: MeetingSummaryKind, route: MeetingSummaryRoute, customPrompt: String) {
        self.start(session: session, kind: kind, customPrompt: customPrompt) { instructions, promptHash in
            try await self.activity.withRemoteSummary {
                let (transcript, contentHash) = try await Self.input(for: session)
                try Task.checkCancellation()
                let text = try await self.remoteService.generate(
                    transcript: transcript, kind: kind, route: route, customInstructions: instructions
                )
                try await self.save(
                    .init(
                        transcriptHash: contentHash,
                        modelID: route.modelID,
                        text: text,
                        providerID: route.providerID,
                        providerName: route.providerName,
                        configurationHash: route.configurationHash,
                        promptVersion: 1,
                        generatedAt: Date(),
                        promptHash: promptHash,
                        transcriptHashVersion: MeetingSummaryController.SavedSummary.currentTranscriptHashVersion
                    ),
                    sessionID: session.id,
                    kind: kind
                )
            }
        }
    }

    func summarizeOnDevice(
        session: MeetingSession,
        kind: MeetingSummaryKind,
        model: PrivateAIRegisteredModel,
        customPrompt: String,
        thinking: Bool
    ) {
        self.start(session: session, kind: kind, customPrompt: customPrompt) { instructions, promptHash in
            try await self.activity.withSummary {
                let (transcript, contentHash) = try await Self.input(
                    for: session, maximumBytes: MeetingSummaryOnDevice.maximumTranscriptBytes
                )
                guard kind != .custom || !instructions.isEmpty else {
                    throw LLMError.invalidRequest("Write a custom prompt before generating.")
                }
                try Task.checkCancellation()
                let text = try await MeetingSummaryActivityCoordinator.withSummaryModelResidency {
                    try MeetingModelResidencyCoordinator.shared.markSummary()
                    return try await PrivateAIIntegrationService.summarizeMeeting(
                        transcript, style: kind.rawValue, instructions: instructions, thinking: thinking
                    )
                }
                try Task.checkCancellation()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingPostProcessingError.invalidOutput }
                try await self.save(
                    .init(
                        transcriptHash: contentHash,
                        modelID: model.id,
                        text: text,
                        providerID: MeetingSummaryOnDevice.providerID,
                        providerName: MeetingSummaryOnDevice.providerName,
                        configurationHash: MeetingSummaryInput.fingerprint("\(MeetingSummaryOnDevice.providerID)|\(model.id)|\(thinking)"),
                        promptVersion: 1,
                        generatedAt: Date(),
                        promptHash: promptHash,
                        modelName: model.displayName,
                        transcriptHashVersion: MeetingSummaryController.SavedSummary.currentTranscriptHashVersion
                    ),
                    sessionID: session.id,
                    kind: kind
                )
            }
        }
    }

    func cancel() {
        self.operation?.cancel()
    }

    private func start(
        session: MeetingSession,
        kind: MeetingSummaryKind,
        customPrompt: String,
        work: @escaping (String, String?) async throws -> Void
    ) {
        guard !self.isRunning, let selectionLock = self.activity.lockSelection() else { return }
        let instructions = kind == .custom ? customPrompt.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let promptHash = kind == .custom ? MeetingSummaryInput.fingerprint(instructions) : nil
        self.request = Request(sessionID: session.id, kind: kind, promptHash: promptHash)
        self.error = nil
        self.isRunning = true
        self.operation = Task {
            defer {
                self.operation = nil
                self.isRunning = false
                self.activity.unlockSelection(selectionLock)
            }
            do {
                try await work(instructions, promptHash)
                self.savedRevision += 1
            } catch is CancellationError {
                self.error = nil
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    private static func input(for session: MeetingSession, maximumBytes: Int? = nil) async throws -> (String, String) {
        try await Task.detached(priority: .utility) {
            let transcript = MeetingSummaryInput.transcript(for: session)
            if let maximumBytes, transcript.utf8.count > maximumBytes {
                throw MeetingPostProcessingError.inputTooLarge
            }
            guard session.transcriptSegments.contains(where: { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw MeetingPostProcessingError.invalidOutput
            }
            return (transcript, MeetingSummaryInput.contentFingerprint(for: session))
        }.value
    }

    private func save(_ summary: MeetingSummaryController.SavedSummary, sessionID: MeetingSessionID, kind: MeetingSummaryKind) async throws {
        try Task.checkCancellation()
        guard let directory = try await self.store.existingSessionDirectory(for: sessionID) else {
            throw MeetingPostProcessingError.checkpointFailed
        }
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try JSONEncoder().encode(summary).write(
                to: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"), options: .atomic
            )
        }.value
    }
}
