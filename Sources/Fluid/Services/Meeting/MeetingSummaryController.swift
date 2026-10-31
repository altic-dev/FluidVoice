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

    func withSummary<T>(activity: any ASRActivityLeasing, work: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard self.summary == nil, self.remoteSummary == nil, self.processing.isEmpty else { throw MeetingModelResidencyError.busy }
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
    @Published private(set) var outputNotice = ""
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let store: any MeetingSessionStoring

    init(store: any MeetingSessionStoring = MeetingSessionStore.shared) {
        self.store = store
    }

    var busy: Bool {
        self.downloading || self.generating || self.deleting
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
        /// Set for custom-prompt summaries, so an edited prompt does not show an older result.
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
        func isCurrent(transcriptHash: String, promptHash: String?) -> Bool {
            self.providerID != nil && self.transcriptHash == transcriptHash && self.promptHash == promptHash
        }

        func isCurrent(session: MeetingSession, promptHash: String?) -> Bool {
            let hash: String
            switch self.transcriptHashVersion {
            case nil:
                hash = MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session))
            case Self.currentTranscriptHashVersion:
                hash = MeetingSummaryInput.contentFingerprint(for: session)
            default:
                return false
            }
            return self.isCurrent(transcriptHash: hash, promptHash: promptHash)
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

    func refresh(session: MeetingSession?, kind: MeetingSummaryKind, customPrompt: String = "") async {
        guard !self.busy else { return }
        let generation = UUID()
        self.generation = generation
        self.output = ""
        self.outputProvenance = ""
        self.outputNotice = ""
        self.error = nil
        self.checking = true
        let model = self.model
        let store = self.store
        let promptHash = kind == .custom ? MeetingSummaryInput.fingerprint(customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        let snapshot = await Task.detached(priority: .utility) { () -> (Bool, SavedSummary?) in
            let installed = model.map { PrivateAIIntegrationService.isModelInstalled($0) } ?? false
            guard let session,
                  let directory = try? await store.existingSessionDirectory(for: session.id),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json")),
                  let saved = try? JSONDecoder().decode(SavedSummary.self, from: data),
                  saved.isCurrent(
                      session: session,
                      promptHash: promptHash
                  )
            else { return (installed, nil) }
            return (installed, saved)
        }.value
        guard self.generation == generation, !Task.isCancelled else { return }
        self.installed = snapshot.0
        self.output = snapshot.1?.text ?? ""
        self.outputProvenance = snapshot.1?.provenance ?? ""
        self.outputNotice = snapshot.1?.notice ?? ""
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

    func summarize(session: MeetingSession, kind: MeetingSummaryKind, route: MeetingSummaryRoute, customPrompt: String = "") {
        guard !self.busy, !self.checking,
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
                try await MeetingSummaryActivityCoordinator.shared.withRemoteSummary {
                    let (transcript, contentHash) = await Task.detached(priority: .utility) {
                        (MeetingSummaryInput.transcript(for: session), MeetingSummaryInput.contentFingerprint(for: session))
                    }.value
                    guard session.transcriptSegments.contains(where: { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                        throw MeetingPostProcessingError.invalidOutput
                    }
                    try Task.checkCancellation()
                    let instructions = kind == .custom ? customPrompt.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let text = try await MeetingSummaryRemoteService.shared.generate(
                        transcript: transcript,
                        kind: kind,
                        route: route,
                        customInstructions: instructions
                    )
                    try Task.checkCancellation()
                    guard let directory = try await self.store.existingSessionDirectory(for: session.id) else {
                        throw MeetingPostProcessingError.checkpointFailed
                    }
                    let saved = SavedSummary(
                        transcriptHash: contentHash,
                        modelID: route.modelID,
                        text: text,
                        providerID: route.providerID,
                        providerName: route.providerName,
                        configurationHash: route.configurationHash,
                        promptVersion: 1,
                        generatedAt: Date(),
                        promptHash: kind == .custom ? MeetingSummaryInput.fingerprint(instructions) : nil,
                        transcriptHashVersion: SavedSummary.currentTranscriptHashVersion
                    )
                    try await Task.detached(priority: .utility) {
                        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"), options: .atomic)
                    }.value
                    self.output = text
                    self.outputProvenance = saved.provenance
                    self.outputNotice = saved.notice
                }
            } catch is CancellationError {
                self.error = nil
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    /// Summarizes with the on-device model. Unlike a cloud summary it takes the meeting model
    /// residency, so dictation and other local models make room while it runs.
    func summarizeOnDevice(
        session: MeetingSession,
        kind: MeetingSummaryKind,
        customPrompt: String = "",
        thinking: Bool,
        asr: ASRService
    ) {
        guard !self.busy, !self.checking, self.installed, let model,
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
                    let (transcript, contentHash) = await Task.detached(priority: .utility) {
                        (MeetingSummaryInput.transcript(for: session), MeetingSummaryInput.contentFingerprint(for: session))
                    }.value
                    guard transcript.utf8.count <= MeetingSummaryOnDevice.maximumTranscriptBytes else {
                        throw MeetingPostProcessingError.inputTooLarge
                    }
                    guard session.transcriptSegments.contains(where: { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                        throw MeetingPostProcessingError.invalidOutput
                    }
                    let instructions = kind == .custom ? customPrompt.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    guard kind != .custom || !instructions.isEmpty else {
                        throw LLMError.invalidRequest("Write a custom prompt before generating.")
                    }
                    try Task.checkCancellation()
                    let text = try await asr.withMeetingModelResidency(attemptID: UUID()) {
                        try MeetingModelResidencyCoordinator.shared.markSummary()
                        return try await PrivateAIIntegrationService.summarizeMeeting(
                            transcript,
                            style: kind.rawValue,
                            instructions: instructions,
                            thinking: thinking
                        )
                    }
                    try Task.checkCancellation()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingPostProcessingError.invalidOutput }
                    guard let directory = try await self.store.existingSessionDirectory(for: session.id) else {
                        throw MeetingPostProcessingError.checkpointFailed
                    }
                    let saved = SavedSummary(
                        transcriptHash: contentHash,
                        modelID: model.id,
                        text: text,
                        providerID: MeetingSummaryOnDevice.providerID,
                        providerName: MeetingSummaryOnDevice.providerName,
                        configurationHash: MeetingSummaryInput.fingerprint("\(MeetingSummaryOnDevice.providerID)|\(model.id)|\(thinking)"),
                        promptVersion: 1,
                        generatedAt: Date(),
                        promptHash: kind == .custom ? MeetingSummaryInput.fingerprint(instructions) : nil,
                        modelName: model.displayName,
                        transcriptHashVersion: SavedSummary.currentTranscriptHashVersion
                    )
                    try await Task.detached(priority: .utility) {
                        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"), options: .atomic)
                    }.value
                    self.output = text
                    self.outputProvenance = saved.provenance
                    self.outputNotice = saved.notice
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
