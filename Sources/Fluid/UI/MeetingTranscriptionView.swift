import AppKit
import AVFoundation
import Combine
import CoreGraphics
import SwiftUI

nonisolated struct MeetingApplicationOption: Identifiable, Equatable, Sendable {
    let id: String
    let identity: MeetingApplicationIdentity

    init(identity: MeetingApplicationIdentity) {
        self.identity = identity
        self.id = "\(identity.bundleIdentifier)-\(identity.processID ?? 0)"
    }
}

struct MeetingMicrophoneOption: Identifiable, Equatable {
    let id: String
    let identity: MeetingMicrophoneIdentity

    init(identity: MeetingMicrophoneIdentity) {
        self.identity = identity
        self.id = identity.captureDeviceID
    }
}

struct MeetingTranscriptionSetupDraft: Equatable {
    var mode: MeetingCaptureMode = .onlineCall
    var title: String = Self.defaultTitle(mode: .onlineCall, applicationDisplayName: nil)
    var selectedApplicationID: String?
    var usesAutomaticApplication = true
    var selectedMicrophoneID: String?
    /// Once true, the default title stops following the selected application/mode.
    var titleWasEdited = false
    var autoDetectEnabled: Bool
    var browserDetectionEnabled: Bool

    init(settings: SettingsStore = .shared) {
        let defaults = settings.meetingRecordingDefaults
        self.autoDetectEnabled = settings.meetingAutoDetectEnabled
        self.browserDetectionEnabled = settings.meetingAutoDetectBrowserEnabled
        self.mode = defaults.mode
        self.title = Self.defaultTitle(mode: defaults.mode, applicationDisplayName: nil)
        self.selectedApplicationID = nil
        // Left unset here: selectPreferredMicrophone decides once identities load.
        self.selectedMicrophoneID = nil
    }

    static func defaultTitle(mode: MeetingCaptureMode, applicationDisplayName: String?) -> String {
        guard mode == .onlineCall else { return "In-room meeting" }
        guard let applicationDisplayName, !applicationDisplayName.isEmpty else { return "Meeting" }
        return "\(applicationDisplayName) call"
    }
}

struct MeetingSetupReadiness: Equatable {
    var isCheckingSources: Bool
    var meetingAudioStatus: String
    var meetingAudioReady: Bool
    var microphoneStatus: String
    var microphoneReady: Bool
    var modelStatus: String
    var modelReady: Bool
    var storageStatus: String
    var storageReady: Bool
    var activityStatus: String
    var activityReady: Bool
    var showMicrophoneSettingsAction: Bool
    var showScreenRecordingSettingsAction: Bool
    var blockingMessage: String?

    static let checking = Self(
        isCheckingSources: true,
        meetingAudioStatus: "Checking…",
        meetingAudioReady: false,
        microphoneStatus: "Checking…",
        microphoneReady: false,
        modelStatus: "Available after recording",
        modelReady: false,
        storageStatus: "Checking…",
        storageReady: false,
        activityStatus: "Checking…",
        activityReady: false,
        showMicrophoneSettingsAction: false,
        showScreenRecordingSettingsAction: false,
        blockingMessage: "Checking recording access and sources."
    )
}

/// Owned by the window, so leaving FluidMeet does not discard its last loaded history.
@MainActor
final class MeetingHistorySnapshot: ObservableObject {
    @Published private(set) var sessions: [MeetingSession] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false
    private let load: @Sendable () async throws -> [MeetingSession]
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false

    init(load: @escaping @Sendable () async throws -> [MeetingSession] = {
        try await MeetingSessionStore.shared.loadAll()
    }) {
        self.load = load
    }

    func refresh() async {
        self.refreshRequested = true
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor in
            // A mutation during a disk read requests one follow-up, never a competing read.
            while self.refreshRequested {
                self.refreshRequested = false
                do {
                    let sessions = try await self.load()
                    guard !self.refreshRequested else { continue }
                    self.sessions = sessions
                    self.errorMessage = nil
                    self.hasLoaded = true
                } catch {
                    guard !self.refreshRequested else { continue }
                    self.errorMessage = "Meeting history could not be loaded."
                    self.hasLoaded = true
                }
            }
            self.refreshTask = nil
        }
        self.refreshTask = task
        await task.value
    }
}

struct MeetingTranscriptionView: View {
    @ObservedObject var coordinator: MeetingSessionCoordinator
    @ObservedObject var asrService: ASRService
    @ObservedObject private var appServices = AppServices.shared
    let onOpenVoiceEngine: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var setupDraft: MeetingTranscriptionSetupDraft
    @State private var setupDraftBeforeEditing: MeetingTranscriptionSetupDraft
    @State private var isShowingMeetingSettings: Bool
    @State private var applications: [MeetingApplicationOption] = []
    @State private var microphones: [MeetingMicrophoneOption] = []
    @State private var isRefreshingSources = false
    @State private var isStarting = false
    @State private var isStopping = false
    @State private var isRetrying = false
    @State private var actionErrorMessage: String?
    @State private var cachedMicrophoneStatus: AVAuthorizationStatus = .notDetermined
    @State private var cachedScreenCaptureAccess = false
    @State private var cachedModelReady = false
    @State private var modelReadinessRevision = 0
    @State private var cachedStorageStatus = "Checking…"
    @State private var cachedStorageReady = false
    @ObservedObject var historySnapshot: MeetingHistorySnapshot
    @State private var selectedHistorySessionID: MeetingSessionID?
    @State private var pendingDeleteSessionID: MeetingSessionID?
    @State private var pendingDeleteAudioSessionID: MeetingSessionID?
    @State private var draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
    @AppStorage("MeetingHistoryInspectorVisible") private var isMeetingHistoryVisible = true

    init(
        coordinator: MeetingSessionCoordinator,
        asrService: ASRService,
        historySnapshot: MeetingHistorySnapshot,
        onOpenVoiceEngine: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.asrService = asrService
        self.historySnapshot = historySnapshot
        self.onOpenVoiceEngine = onOpenVoiceEngine

        let initialDraft = MeetingTranscriptionSetupDraft(settings: .shared)
        self._setupDraft = State(initialValue: initialDraft)
        self._setupDraftBeforeEditing = State(initialValue: initialDraft)
        self._isShowingMeetingSettings = State(initialValue: false)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    MeetingTranscriptionCanvas(
                        setupDraft: self.$setupDraft,
                        state: self.canvasState,
                        applications: self.applications,
                        microphones: self.microphones,
                        readiness: self.readiness,
                        errorMessage: self.actionErrorMessage,
                        onStart: self.startRecording,
                        onStop: self.stopAndTranscribe,
                        onRetrySession: { self.retryProcessingSession(id: $0.id) },
                        onRevealAudio: self.revealCapturedAudio,
                        onRecordAgain: self.recordAgain,
                        onCopyTranscript: self.copyTranscript,
                        onExportTranscript: self.exportTranscript,
                        onReassignSegment: self.reassignSegment,
                        onNameUnknownSegment: self.nameUnknownSegment,
                        onRenameSpeaker: self.renameSpeaker,
                        onMergeSpeakers: self.mergeSpeakers,
                        onUndoCorrection: self.undoTranscriptCorrection,
                        onRenameSession: self.renameMeetingSession,
                        onAssignSpeakers: self.assignSpeakers,
                        canUndoCorrection: { self.coordinator.canUndoCorrection(sessionID: $0) },
                        isQuiescent: self.coordinator.isQuiescent,
                        onRepairSetup: self.repairRecordingSetup,
                        onEditSetup: self.openMeetingSettings,
                        isRetrying: self.isRetrying,
                        onCloseSelection: self.closeCanvasAction,
                        summaryASRService: self.asrService
                    )
                    .padding(.trailing, self.isMeetingHistoryVisible && geometry.size.width >= 900 ? 272 : 0)
                    .allowsHitTesting(!self.isMeetingHistoryVisible || geometry.size.width >= 900)
                    .accessibilityHidden(self.isMeetingHistoryVisible && geometry.size.width < 900)

                    if self.isMeetingHistoryVisible {
                        if geometry.size.width < 900 {
                            Button {
                                self.isMeetingHistoryVisible = false
                            } label: {
                                self.theme.palette.windowBackground.opacity(0.65)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close meeting history")
                        }
                        MeetingHistoryInspector(
                            sessions: self.historySnapshot.sessions,
                            selectedSessionID: Binding(
                                get: { self.selectedHistorySessionID },
                                set: {
                                    if self.canBrowseMeetingHistory {
                                        self.selectedHistorySessionID = $0
                                        if geometry.size.width < 900 { self.isMeetingHistoryVisible = false }
                                    }
                                }
                            ),
                            errorMessage: self.historySnapshot.errorMessage,
                            isLoading: !self.historySnapshot.hasLoaded,
                            isQuiescent: self.coordinator.isQuiescent,
                            onRefresh: { Task { await self.loadMeetingHistory() } },
                            onRetry: { self.retryProcessingSession(id: $0) },
                            onRevealAudio: self.revealCapturedAudio,
                            onExportAudio: self.exportAudio,
                            onExportTranscript: { self.exportTranscript($0, format: $1, includeEchoes: false) },
                            onDeleteAudioRequest: { self.pendingDeleteAudioSessionID = $0 },
                            onDeleteRequest: { self.pendingDeleteSessionID = $0 },
                            onRename: { self.renameMeetingSession(sessionID: $0, to: $1) },
                            onRecordAgain: self.recordAgain
                        )
                        .frame(width: min(272, geometry.size.width))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(self.theme.palette.separator)
                                .frame(width: 1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .background(self.theme.palette.contentBackground)
        .fluidPageActions {
            MeetingTranscriptionHeader(
                state: self.canvasState,
                isMeetingHistoryVisible: self.isMeetingHistoryVisible,
                onNewMeeting: self.startNewMeeting,
                onOpenMeetingSettings: self.openMeetingSettings,
                onToggleMeetingHistory: {
                    let willShowHistory = !self.isMeetingHistoryVisible
                    withAnimation(self.accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        self.isMeetingHistoryVisible.toggle()
                    }
                    if willShowHistory, self.historySnapshot.sessions.isEmpty {
                        Task { await self.loadMeetingHistory() }
                    }
                }
            )
        }
        .clipped()
        .task {
            MeetingDiarizationModelStore.shared.prepareInBackground()
            async let sources: Void = self.refreshSources(requestPermissions: false)
            if self.isMeetingHistoryVisible {
                await self.loadMeetingHistory()
            }
            await sources
        }
        .onChange(of: self.setupDraft.mode) { _, _ in
            Task { await self.refreshSources(requestPermissions: false) }
            self.regenerateDefaultTitleIfNeeded()
        }
        .onChange(of: self.setupDraft.selectedApplicationID) { _, _ in
            self.regenerateDefaultTitleIfNeeded()
        }
        .onChange(of: self.setupDraft.usesAutomaticApplication) { _, automatic in
            guard automatic else { return }
            self.selectPreferredApplication(from: self.applications.map(\.identity))
        }
        .onChange(of: self.appServices.meetingAutomaticTarget) { _, _ in
            guard self.setupDraft.usesAutomaticApplication, !self.isShowingMeetingSettings,
                  self.coordinator.isQuiescent, !self.isStarting else { return }
            self.selectPreferredApplication(from: self.applications.map(\.identity))
            Task { await self.refreshSources(requestPermissions: false) }
        }
        .onChange(of: self.coordinator.latestCompletedSession?.id) { _, _ in
            Task { await self.loadMeetingHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                async let sources: Void = self.refreshSources(requestPermissions: false)
                if self.isMeetingHistoryVisible {
                    await self.loadMeetingHistory()
                }
                await sources
            }
        }
        .sheet(isPresented: self.$isShowingMeetingSettings) {
            MeetingRecordingSettingsSheet(
                draft: self.$setupDraft,
                retentionPolicy: self.$draftMeetingAudioRetentionPolicy,
                applications: self.applications,
                microphones: self.microphones,
                readiness: self.readiness,
                isFirstSetup: !SettingsStore.shared.meetingRecordingDefaults.isConfigured,
                onRefreshSources: self.refreshSourcesFromUserAction,
                onOpenMicrophoneSettings: { Self.openMicrophoneSettings() },
                onOpenScreenRecordingSettings: { self.openScreenRecordingSettings() },
                onOpenVoiceEngine: self.onOpenVoiceEngine,
                onCancel: self.cancelMeetingSettings,
                onSave: self.saveMeetingSettings,
                onModelImported: { Task { await self.refreshModelReadiness() } }
            )
            .background(FluidSheetOutsideDismiss(onCancel: self.cancelMeetingSettings))
            .interactiveDismissDisabled()
        }
        .alert(
            "Delete Meeting?",
            isPresented: Binding(
                get: { self.pendingDeleteSessionID != nil },
                set: { if !$0 { self.pendingDeleteSessionID = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { self.pendingDeleteSessionID = nil }
            Button("Delete", role: .destructive) {
                if let id = self.pendingDeleteSessionID { self.deleteSession(id: id) }
            }
        } message: {
            Text("The recording and transcript will be permanently deleted from this Mac.")
        }
        .alert(
            "Delete Audio?",
            isPresented: Binding(
                get: { self.pendingDeleteAudioSessionID != nil },
                set: { if !$0 { self.pendingDeleteAudioSessionID = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { self.pendingDeleteAudioSessionID = nil }
            Button("Delete Audio", role: .destructive) {
                if let id = self.pendingDeleteAudioSessionID { self.deleteAudio(id: id) }
            }
        } message: {
            Text("The transcript stays; the audio files are deleted from this Mac.")
        }
    }

    private var canvasState: MeetingTranscriptionCanvasState {
        if let selectedHistorySession, self.canBrowseMeetingHistory {
            switch selectedHistorySession.state {
            case .failed:
                let message = selectedHistorySession.failures.last?.message ?? "This meeting failed."
                return .failed(session: selectedHistorySession, message: message)
            case .interrupted:
                let message = selectedHistorySession.endedAt != nil && !selectedHistorySession.processingAttempts.isEmpty
                    ? "Transcription was interrupted. Captured audio is ready to retry."
                    : "Recording was interrupted. Captured audio has been preserved on this Mac."
                return .failed(session: selectedHistorySession, message: message)
            default:
                return .result(selectedHistorySession)
            }
        }

        switch self.coordinator.state {
        case .idle:
            return .setup(isStarting: self.isStarting, recentSession: self.coordinator.latestCompletedSession)
        case .preparing:
            return .setup(isStarting: true, recentSession: self.coordinator.latestCompletedSession)
        case .recording, .recordingDegraded:
            guard let session = self.coordinator.activeSession else {
                return .failed(session: nil, message: "The active meeting could not be loaded.")
            }
            if self.isStopping {
                return .stopping(session: session, trackHealth: self.coordinator.trackHealth, liveTranscript: self.coordinator.liveTranscript)
            }
            return .recording(session: session, trackHealth: self.coordinator.trackHealth, liveTranscript: self.coordinator.liveTranscript)
        case .stopping:
            guard let session = self.coordinator.activeSession else {
                return .failed(session: nil, message: "The meeting is stopping, but its session could not be loaded.")
            }
            return .stopping(session: session, trackHealth: self.coordinator.trackHealth, liveTranscript: self.coordinator.liveTranscript)
        case let .processing(_, stage):
            guard let session = self.coordinator.activeSession else {
                return .failed(session: nil, message: "The meeting is processing, but its session could not be loaded.")
            }
            return .processing(session: session, stage: stage)
        case .completed:
            guard let session = self.coordinator.latestCompletedSession else {
                return .failed(session: nil, message: "The completed transcript could not be loaded.")
            }
            return .result(session)
        case .interrupted:
            let session = self.coordinator.activeSession
            let message = session?.endedAt != nil && session?.processingAttempts.isEmpty == false
                ? "Transcription was interrupted. Captured audio is ready to retry."
                : "Recording was interrupted. Captured audio has been preserved on this Mac."
            return .failed(
                session: session,
                message: message
            )
        case let .failed(_, failure):
            return .failed(session: self.coordinator.activeSession, message: failure.message)
        }
    }

    private var selectedHistorySession: MeetingSession? {
        guard let selectedHistorySessionID else { return nil }
        return self.historySnapshot.sessions.first(where: { $0.id == selectedHistorySessionID })
    }

    /// Closing a history selection returns to whatever is underneath; closing the just-finished
    /// meeting's own result/failure returns to the new-meeting screen.
    private var closeCanvasAction: (() -> Void)? {
        if self.selectedHistorySessionID != nil {
            return { self.selectedHistorySessionID = nil }
        }
        switch self.coordinator.state {
        case .completed, .failed, .interrupted:
            return { self.startNewMeeting() }
        default:
            return nil
        }
    }

    private var canBrowseMeetingHistory: Bool {
        switch self.coordinator.state {
        case .idle, .completed, .interrupted, .failed:
            return true
        case .preparing, .recording, .recordingDegraded, .stopping, .processing:
            return false
        }
    }

    /// True only when an actual app will be captured; otherwise recording is mic-only.
    private var capturesMeetingAudio: Bool {
        guard self.setupDraft.mode == .onlineCall, let id = self.setupDraft.selectedApplicationID else { return false }
        return self.applications.contains { $0.id == id }
    }

    private var effectiveCaptureMode: MeetingCaptureMode {
        self.capturesMeetingAudio ? .onlineCall : .inRoom
    }

    private var readiness: MeetingSetupReadiness {
        let microphoneStatus = self.cachedMicrophoneStatus
        let microphoneReady = microphoneStatus == .authorized
        let meetingAudioReady = !self.capturesMeetingAudio || self.cachedScreenCaptureAccess
        let modelReady = self.cachedModelReady
        let conflictingActivity = self.asrService.activeExclusiveActivity
        let activityReady = conflictingActivity == nil

        let microphoneStatusText: String
        switch microphoneStatus {
        case .authorized:
            microphoneStatusText = self.microphones.isEmpty ? "No microphone found" : "Ready"
        case .notDetermined:
            microphoneStatusText = "Access required"
        case .denied:
            microphoneStatusText = "Access denied"
        case .restricted:
            microphoneStatusText = "Access restricted"
        @unknown default:
            microphoneStatusText = "Access unavailable"
        }

        let blockingMessage: String?
        if self.isRefreshingSources {
            blockingMessage = "Checking recording access and sources."
        } else if let conflictingActivity {
            blockingMessage = "Wait for the active \(conflictingActivity.displayName) to finish."
        } else if microphoneStatus == .restricted {
            blockingMessage = "Microphone access is restricted by system policy."
        } else if !microphoneReady {
            blockingMessage = "Allow microphone access, then refresh sources."
        } else if self.microphones.isEmpty {
            blockingMessage = "Connect a microphone, then refresh sources."
        } else if !meetingAudioReady {
            blockingMessage = "Allow Screen & System Audio access, then refresh sources."
        } else if !self.cachedStorageReady {
            let trackCount = MeetingPCMStoragePolicy.trackCount(for: self.effectiveCaptureMode)
            blockingMessage = "Free at least \(MeetingPCMStoragePolicy.requiredFreeSpaceDescription(trackCount: trackCount)) of storage before recording."
        } else if !CPUArchitecture.isAppleSilicon {
            blockingMessage = "FluidMeet requires an Apple silicon Mac."
        } else {
            blockingMessage = nil
        }

        return MeetingSetupReadiness(
            isCheckingSources: self.isRefreshingSources,
            meetingAudioStatus: meetingAudioReady ? "Ready" : "Access required",
            meetingAudioReady: meetingAudioReady,
            microphoneStatus: microphoneStatusText,
            microphoneReady: microphoneReady && !self.microphones.isEmpty,
            modelStatus: modelReady ? "Speaker model installed · transcription prepares after Stop" : "Speaker model downloads before transcription",
            modelReady: modelReady,
            storageStatus: self.cachedStorageStatus,
            storageReady: self.cachedStorageReady,
            activityStatus: conflictingActivity.map { "Wait for \($0.displayName)" } ?? "Ready",
            activityReady: activityReady,
            showMicrophoneSettingsAction: microphoneStatus == .denied,
            showScreenRecordingSettingsAction: self.setupDraft.mode == .onlineCall && !self.cachedScreenCaptureAccess,
            blockingMessage: blockingMessage
        )
    }

    private func refreshSourcesFromUserAction() {
        Task { await self.refreshSources(requestPermissions: true) }
    }

    @MainActor
    private func refreshModelReadiness() async {
        self.modelReadinessRevision += 1
        let revision = self.modelReadinessRevision
        let ready = await Task.detached(priority: .utility) {
            CPUArchitecture.isAppleSilicon && (try? MeetingNemotronModelLocator().locate()) != nil
        }.value
        // An older check must not overwrite an import completion's newer result.
        guard self.modelReadinessRevision == revision else { return }
        self.cachedModelReady = ready
    }

    @MainActor
    private func refreshSources(requestPermissions: Bool) async {
        guard !self.isRefreshingSources else { return }
        self.isRefreshingSources = true
        await self.refreshModelReadiness()
        self.refreshCachedReadiness()
        defer {
            self.refreshCachedReadiness()
            self.isRefreshingSources = false
        }

        self.actionErrorMessage = nil

        if requestPermissions, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await Self.requestMicrophoneAccess()
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            let snapshot = await MeetingCaptureSourceCatalog.microphoneSnapshot()
            let identities = snapshot.identities
            self.microphones = identities.map(MeetingMicrophoneOption.init)
            self.selectPreferredMicrophone(from: identities, systemDefaultUID: snapshot.defaultCoreAudioUID)
        } else {
            self.microphones = []
            self.setupDraft.selectedMicrophoneID = nil
        }

        guard self.setupDraft.mode == .onlineCall else { return }

        if requestPermissions, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        guard CGPreflightScreenCaptureAccess() else {
            self.applications = []
            self.setupDraft.selectedApplicationID = nil
            return
        }

        do {
            let identities = try await MeetingCaptureSourceCatalog.availableApplications()
            self.applications = identities.map(MeetingApplicationOption.init)
            self.selectPreferredApplication(from: identities)
        } catch {
            self.applications = []
            self.setupDraft.selectedApplicationID = nil
            self.actionErrorMessage = error.localizedDescription
        }
    }

    /// Keeps the title following the selected app/mode until the user types their own.
    private func regenerateDefaultTitleIfNeeded() {
        guard !self.setupDraft.titleWasEdited else { return }
        let applicationName = self.applications.first(where: { $0.id == self.setupDraft.selectedApplicationID })?.identity.displayName
        self.setupDraft.title = MeetingTranscriptionSetupDraft.defaultTitle(
            mode: self.setupDraft.mode,
            applicationDisplayName: applicationName
        )
    }

    private func resetDraftTitleToDefault() {
        self.setupDraft.titleWasEdited = false
        self.regenerateDefaultTitleIfNeeded()
    }

    private func selectPreferredMicrophone(
        from identities: [MeetingMicrophoneIdentity],
        systemDefaultUID: String?
    ) {
        if let selectedID = setupDraft.selectedMicrophoneID,
           identities.contains(where: { $0.captureDeviceID == selectedID })
        {
            return
        }

        let defaults = SettingsStore.shared.meetingRecordingDefaults
        let savedMicrophone = defaults.savedMicrophone(in: identities)
        let preferredInputUID = SettingsStore.shared.preferredInputDeviceUID
        // Default preselection follows the system's current input, not the remembered device.
        let selection = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: savedMicrophone?.captureDeviceID,
            savedRole: defaults.microphoneRole,
            systemDefaultUID: systemDefaultUID,
            preferredInputUID: preferredInputUID,
            systemDefaultCaptureID: nil
        )
        self.setupDraft.selectedMicrophoneID = selection.deviceID
    }

    private func selectPreferredApplication(from identities: [MeetingApplicationIdentity]) {
        let options = identities.map(MeetingApplicationOption.init)
        if self.setupDraft.usesAutomaticApplication {
            let target = self.appServices.meetingAutomaticTarget
            self.setupDraft.selectedApplicationID = options.first {
                $0.identity.bundleIdentifier == target?.bundleIdentifier && $0.identity.processID == target?.pid
            }?.id
            return
        }
        if let selectedID = setupDraft.selectedApplicationID,
           options.contains(where: { $0.id == selectedID })
        {
            return
        }

        self.setupDraft.selectedApplicationID = nil
    }

    private func startRecording() {
        guard !self.isStarting else { return }
        let readiness = self.readiness
        guard readiness.activityReady,
              readiness.storageReady,
              readiness.microphoneReady,
              readiness.meetingAudioReady,
              let configuration = self.captureConfiguration
        else {
            self.actionErrorMessage = readiness.blockingMessage ?? "Finish meeting setup before recording."
            return
        }
        self.isStarting = true
        self.actionErrorMessage = nil

        Task {
            defer { self.isStarting = false }
            do {
                _ = try await self.coordinator.startRecording(configuration: configuration)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private var captureConfiguration: MeetingCaptureConfiguration? {
        let title = self.setupDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let microphoneOption = self.microphones.first(where: { $0.id == self.setupDraft.selectedMicrophoneID })
        else {
            return nil
        }

        var microphone = microphoneOption.identity
        microphone.role = .unknown

        // No resolved app means a mic-only recording, never a refusal to record.
        let applicationOption = self.applications.first(where: { $0.id == self.setupDraft.selectedApplicationID })
        var application = self.setupDraft.mode == .onlineCall ? applicationOption?.identity : nil
        if application != nil, self.setupDraft.usesAutomaticApplication {
            if let target = self.appServices.meetingAutomaticTarget,
               application?.bundleIdentifier == target.bundleIdentifier,
               application?.processID == target.pid
            {
                application?.windowID = target.windowID
            } else {
                application = nil
            }
        }

        return MeetingCaptureConfiguration(
            mode: application == nil ? .inRoom : .onlineCall,
            title: title,
            platform: application.map {
                MeetingPlatformProfile(identifier: $0.bundleIdentifier, displayName: $0.displayName)
            },
            application: application,
            microphone: microphone
        )
    }

    private func stopAndTranscribe() {
        guard !self.isStopping else { return }
        self.isStopping = true
        self.actionErrorMessage = nil
        // Stop is an explicit "show me my meeting" — a stale sidebar pick must not hijack the outcome.
        self.selectedHistorySessionID = nil
        Task {
            defer { self.isStopping = false }
            do {
                _ = try await self.coordinator.stopAndTranscribe()
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func retryProcessingSession(id: MeetingSessionID) {
        guard !self.isRetrying else { return }
        self.isRetrying = true
        self.actionErrorMessage = nil
        self.selectedHistorySessionID = nil
        Task {
            defer { self.isRetrying = false }
            do {
                _ = try await self.coordinator.retryProcessing(sessionID: id)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
            await self.loadMeetingHistory()
        }
    }

    private func reassignSegment(sessionID: MeetingSessionID, segmentID: MeetingTranscriptSegmentID, to speakerID: SessionSpeakerID) {
        self.actionErrorMessage = nil
        Task {
            do {
                _ = try await self.coordinator.reassignSegment(sessionID: sessionID, segmentID: segmentID, to: speakerID)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
            await self.loadMeetingHistory()
        }
    }

    private func nameUnknownSegment(
        sessionID: MeetingSessionID,
        segmentID: MeetingTranscriptSegmentID,
        displayName: String
    ) {
        self.actionErrorMessage = nil
        Task {
            do {
                _ = try await self.coordinator.nameUnknownSegment(
                    sessionID: sessionID,
                    segmentID: segmentID,
                    displayName: displayName
                )
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
            await self.loadMeetingHistory()
        }
    }

    private func renameSpeaker(sessionID: MeetingSessionID, speakerID: SessionSpeakerID, to displayName: String) {
        self.actionErrorMessage = nil
        Task {
            do {
                _ = try await self.coordinator.renameSpeaker(sessionID: sessionID, speakerID: speakerID, to: displayName)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
            await self.loadMeetingHistory()
        }
    }

    private func assignSpeakers(sessionID: MeetingSessionID, names: [SessionSpeakerID: String]) async -> String? {
        self.actionErrorMessage = nil
        var errorMessage: String?
        do {
            _ = try await self.coordinator.renameSpeakers(sessionID: sessionID, names: names)
        } catch {
            errorMessage = error.localizedDescription
        }
        await self.loadMeetingHistory()
        return errorMessage
    }

    private func mergeSpeakers(sessionID: MeetingSessionID, source: SessionSpeakerID, into targetID: SessionSpeakerID) {
        self.actionErrorMessage = nil
        Task {
            do {
                _ = try await self.coordinator.mergeSpeakers(sessionID: sessionID, source: source, into: targetID)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
            await self.loadMeetingHistory()
        }
    }

    private func renameMeetingSession(sessionID: MeetingSessionID, to title: String) {
        self.actionErrorMessage = nil
        Task {
            do {
                _ = try await self.coordinator.renameSession(sessionID: sessionID, to: title)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
            await self.loadMeetingHistory()
        }
    }

    private func undoTranscriptCorrection(sessionID: MeetingSessionID) {
        self.actionErrorMessage = nil
        Task {
            do {
                _ = try await self.coordinator.undoTranscriptCorrection(sessionID: sessionID)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
            await self.loadMeetingHistory()
        }
    }

    private func deleteSession(id: MeetingSessionID) {
        self.pendingDeleteSessionID = nil
        self.actionErrorMessage = nil
        Task {
            do {
                try await self.coordinator.deleteSession(id: id)
                if self.selectedHistorySessionID == id { self.selectedHistorySessionID = nil }
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
            await self.loadMeetingHistory()
        }
    }

    private func deleteAudio(id: MeetingSessionID) {
        self.pendingDeleteAudioSessionID = nil
        self.actionErrorMessage = nil
        Task {
            do {
                _ = try await self.coordinator.deleteAudio(sessionID: id)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
            await self.loadMeetingHistory()
        }
    }

    private func recordAgain(_ session: MeetingSession) {
        guard let configuration = self.recordAgainConfiguration(from: session) else { return }
        self.actionErrorMessage = nil
        Task {
            do {
                _ = try await self.coordinator.recordAgain(from: session.id, configuration: configuration)
                self.selectedHistorySessionID = nil
                self.resetDraftTitleToDefault()
                await self.loadMeetingHistory()
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func recordAgainConfiguration(from session: MeetingSession) -> MeetingCaptureConfiguration? {
        guard let microphone = self.resolvedMicrophone(for: session) else {
            self.actionErrorMessage = "microphone unavailable"
            return nil
        }
        var application: MeetingApplicationIdentity?
        if session.mode == .onlineCall {
            guard let bundleIdentifier = session.capturedApplication?.bundleIdentifier,
                  let resolved = self.applications.first(where: { $0.identity.bundleIdentifier == bundleIdentifier })
            else {
                self.actionErrorMessage = "app not running"
                return nil
            }
            application = resolved.identity
        }
        return MeetingCaptureConfiguration(
            mode: session.mode,
            title: session.title,
            platform: session.platform,
            application: application,
            microphone: microphone
        )
    }

    private func resolvedMicrophone(for session: MeetingSession) -> MeetingMicrophoneIdentity? {
        if let coreAudioUID = session.selectedMicrophone.coreAudioUID,
           let match = self.microphones.first(where: { $0.identity.coreAudioUID == coreAudioUID })
        {
            var identity = match.identity
            identity.role = .unknown
            return identity
        }
        guard let match = self.microphones.first(where: { $0.identity.captureDeviceID == session.selectedMicrophone.captureDeviceID }) else {
            return nil
        }
        var identity = match.identity
        identity.role = .unknown
        return identity
    }

    private func revealCapturedAudio(_ session: MeetingSession) {
        Task {
            do {
                // Reload fresh: the passed-in session may predate a since-completed audio deletion.
                guard let freshSession = try await MeetingSessionStore.shared.load(id: session.id) else {
                    self.actionErrorMessage = "Captured audio could not be revealed: recording no longer on disk."
                    return
                }
                guard freshSession.retention.audioDeletedAt == nil,
                      freshSession.hasFinalizedAudio
                else {
                    self.actionErrorMessage = "Captured audio could not be revealed: audio for this recording has been deleted."
                    return
                }
                guard let directory = try await MeetingSessionStore.shared.existingSessionDirectory(for: freshSession.id) else {
                    self.actionErrorMessage = "Captured audio could not be revealed: recording no longer on disk."
                    return
                }
                guard let firstAudioURL = MeetingAudioPresentation.firstPlaybackURL(
                    in: freshSession,
                    directory: directory
                ) else {
                    self.actionErrorMessage = "Captured audio is still preparing or is no longer available on disk."
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([firstAudioURL])
            } catch {
                self.actionErrorMessage = "Captured audio could not be revealed: \(error.localizedDescription)"
            }
        }
    }

    private func exportAudio(_ session: MeetingSession) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }

        self.actionErrorMessage = nil
        Task {
            do {
                // Reload fresh: the passed-in session may predate a since-completed audio deletion.
                guard let freshSession = try await MeetingSessionStore.shared.load(id: session.id) else {
                    self.actionErrorMessage = "Export failed: recording no longer on disk."
                    return
                }
                guard freshSession.retention.audioDeletedAt == nil,
                      freshSession.hasFinalizedAudio
                else {
                    self.actionErrorMessage = "Export failed: audio for this recording has been deleted."
                    return
                }
                guard let sourceDirectory = try await MeetingSessionStore.shared.existingSessionDirectory(for: freshSession.id) else {
                    self.actionErrorMessage = "Export failed: recording no longer on disk."
                    return
                }
                try await Self.exportAudioFiles(of: freshSession, from: sourceDirectory, into: destinationFolder)
            } catch {
                self.actionErrorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private nonisolated static let audioExportLock = NSLock()

    nonisolated static func exportAudioFiles(
        of session: MeetingSession,
        from sourceDirectory: URL,
        into destinationFolder: URL,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) async throws {
        // The session and URLs are immutable snapshots; no view state crosses to the worker.
        try await Task.detached(priority: .utility) {
            let accessing = destinationFolder.startAccessingSecurityScopedResource()
            defer { if accessing { destinationFolder.stopAccessingSecurityScopedResource() } }
            // Preserve the old serial export semantics when users request another export
            // while copying. The lock and all filesystem work stay off the main actor.
            try Self.audioExportLock.withLock {
                try Self.stageExport(of: session, from: sourceDirectory, into: destinationFolder, copyItem: copyItem)
            }
        }.value
    }

    private nonisolated static func stageExport(
        of session: MeetingSession,
        from sourceDirectory: URL,
        into destinationFolder: URL,
        copyItem: (URL, URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let baseName = Self.sanitizedExportName(session.title)
        let name = Self.uniqueExportName(baseName, in: destinationFolder, fileManager: fileManager)
        let stagingDirectory = destinationFolder.appendingPathComponent(".\(name).\(UUID().uuidString).export-tmp", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        do {
            for track in session.audioTracks {
                for chunk in track.chunks where chunk.finalizationState == .finalized && chunk.byteCount > 0 {
                    let sourceURL = chunk.fileURL(relativeTo: sourceDirectory)
                    let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
                    let fileName = "\(track.kind.rawValue)-\(String(format: "%03d", chunk.sequence)).\(ext)"
                    try copyItem(sourceURL, stagingDirectory.appendingPathComponent(fileName, isDirectory: false))
                }
            }
            var destinationName = name
            do {
                try fileManager.moveItem(at: stagingDirectory, to: destinationFolder.appendingPathComponent(destinationName, isDirectory: true))
            } catch CocoaError.fileWriteFileExists {
                // Destination appeared between the uniqueness check and the move; retry once with a fresh name.
                destinationName = Self.uniqueExportName(baseName, in: destinationFolder, fileManager: fileManager)
                try fileManager.moveItem(at: stagingDirectory, to: destinationFolder.appendingPathComponent(destinationName, isDirectory: true))
            }
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private nonisolated static func sanitizedExportName(_ title: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _.-")
        let sanitized = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.prefix(80))
        return sanitized.isEmpty ? "Meeting" : sanitized
    }

    private nonisolated static func uniqueExportName(_ baseName: String, in folder: URL, fileManager: FileManager) -> String {
        var candidate = baseName
        var suffix = 2
        while fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(baseName) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func startNewMeeting() {
        do {
            try self.coordinator.resetForNewMeeting()
            self.selectedHistorySessionID = nil
            self.setupDraft.usesAutomaticApplication = true
            self.selectPreferredApplication(from: self.applications.map(\.identity))
            self.resetDraftTitleToDefault()
            self.actionErrorMessage = nil
        } catch {
            self.actionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMeetingHistory() async {
        await self.historySnapshot.refresh()
        guard self.historySnapshot.errorMessage == nil else { return }
        if let selectedHistorySessionID,
           !self.historySnapshot.sessions.contains(where: { $0.id == selectedHistorySessionID })
        {
            self.selectedHistorySessionID = nil
        }
    }

    private func openMeetingSettings() {
        self.setupDraft.autoDetectEnabled = SettingsStore.shared.meetingAutoDetectEnabled
        self.setupDraft.browserDetectionEnabled = SettingsStore.shared.meetingAutoDetectBrowserEnabled
        self.setupDraftBeforeEditing = self.setupDraft
        self.draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
        self.isShowingMeetingSettings = true
    }

    private func repairRecordingSetup() {
        if self.readiness.showMicrophoneSettingsAction {
            Self.openMicrophoneSettings()
        } else if self.readiness.showScreenRecordingSettingsAction {
            self.openScreenRecordingSettings()
        } else {
            self.openMeetingSettings()
        }
    }

    private func cancelMeetingSettings() {
        self.setupDraft = self.setupDraftBeforeEditing
        self.draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
        self.isShowingMeetingSettings = false
        Task { await self.refreshSources(requestPermissions: false) }
    }

    private func saveMeetingSettings() {
        guard let microphone = self.microphones.first(where: { $0.id == self.setupDraft.selectedMicrophoneID }) else {
            self.actionErrorMessage = "Choose an available microphone before saving."
            return
        }

        // Automatic is session-scoped and never rewrites the user's legacy saved source.
        // Source availability is checked again when recording starts.
        let settings = SettingsStore.shared
        let previousDefaults = settings.meetingRecordingDefaults
        let application = self.applications.first(where: { $0.id == self.setupDraft.selectedApplicationID })
        if self.setupDraft.mode == .onlineCall, !self.setupDraft.usesAutomaticApplication, application == nil {
            self.actionErrorMessage = "Choose an available audio source or Automatic before saving."
            return
        }

        settings.meetingRecordingDefaults = MeetingRecordingDefaults(
            isConfigured: true,
            mode: self.setupDraft.mode,
            applicationBundleIdentifier: previousDefaults.applicationBundleIdentifier,
            applicationDisplayName: previousDefaults.applicationDisplayName,
            microphoneCaptureDeviceID: microphone.identity.captureDeviceID,
            microphoneCoreAudioUID: microphone.identity.coreAudioUID,
            microphoneRole: .unknown
        )

        let previousRetentionPolicy = settings.meetingAudioRetentionPolicy
        settings.meetingAutoDetectEnabled = self.setupDraft.autoDetectEnabled
        settings.meetingAutoDetectBrowserEnabled = self.setupDraft.browserDetectionEnabled
        settings.meetingAudioRetentionPolicy = self.draftMeetingAudioRetentionPolicy
        if previousRetentionPolicy != self.draftMeetingAudioRetentionPolicy {
            Task { await self.coordinator.sweepExpiredAudio() }
        }

        self.setupDraftBeforeEditing = self.setupDraft
        self.actionErrorMessage = nil
        self.isShowingMeetingSettings = false
        self.selectPreferredApplication(from: self.applications.map(\.identity))
        // Import is applied immediately inside the sheet; Save must rediscover the installed
        // model even when no source selection changed and no app-activation event follows.
        Task { await self.refreshSources(requestPermissions: false) }
    }

    private func copyTranscript(_ session: MeetingSession, includeEchoes: Bool) {
        let text = MeetingTranscriptExporter.text(for: session, includeEchoes: includeEchoes)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportTranscript(_ session: MeetingSession, format: MeetingTranscriptExportFormat, includeEchoes: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Self.sanitizedExportName(session.title)).\(format.fileExtension)"
        panel.message = "Exported transcripts are outside FluidVoice's retention controls and may be indexed or synced by other apps."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.actionErrorMessage = nil
        do {
            let data: Data
            switch format {
            case .text: data = Data(MeetingTranscriptExporter.text(for: session, includeEchoes: includeEchoes).utf8)
            case .json: data = try MeetingTranscriptExporter.json(for: session)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            self.actionErrorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        PermissionDragGuideController.shared.present(
            instruction: "Drag \(Bundle.main.fluidAppDisplayName) into the Screen & System Audio Recording list as shown",
            settingsPaneURL: url,
            isGranted: { CGPreflightScreenCaptureAccess() },
            onGranted: { [self] in
                self.refreshCachedReadiness()
                Task { await self.refreshSources(requestPermissions: false) }
            }
        )
    }

    private func refreshCachedReadiness() {
        self.cachedMicrophoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.cachedScreenCaptureAccess = CGPreflightScreenCaptureAccess()
        let storage = Self.storageReadiness(trackCount: MeetingPCMStoragePolicy.trackCount(for: self.effectiveCaptureMode))
        self.cachedStorageStatus = storage.status
        self.cachedStorageReady = storage.ready
    }

    private static func storageReadiness(trackCount: Int) -> (status: String, ready: Bool) {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
            let capacity = try? applicationSupport.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
        else {
            return ("Storage availability unavailable", false)
        }
        let requiredBytes = MeetingPCMStoragePolicy.requiredFreeBytes(trackCount: trackCount)
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return ("\(formatter.string(fromByteCount: capacity)) available", capacity >= requiredBytes)
    }
}

enum MeetingTranscriptExportFormat {
    case text
    case json

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .json: return "json"
        }
    }
}

enum MeetingTranscriptionCanvasState {
    case setup(isStarting: Bool, recentSession: MeetingSession?)
    case recording(
        session: MeetingSession,
        trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth],
        liveTranscript: MeetingLiveTranscriptSnapshot
    )
    case stopping(
        session: MeetingSession,
        trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth],
        liveTranscript: MeetingLiveTranscriptSnapshot
    )
    case processing(session: MeetingSession, stage: MeetingProcessingStage)
    case result(MeetingSession)
    case failed(session: MeetingSession?, message: String)
}

struct MeetingTranscriptionCanvas: View {
    @Binding var setupDraft: MeetingTranscriptionSetupDraft

    let state: MeetingTranscriptionCanvasState
    let applications: [MeetingApplicationOption]
    let microphones: [MeetingMicrophoneOption]
    let readiness: MeetingSetupReadiness
    let errorMessage: String?
    let onStart: () -> Void
    let onStop: () -> Void
    let onRetrySession: (MeetingSession) -> Void
    let onRevealAudio: (MeetingSession) -> Void
    let onRecordAgain: (MeetingSession) -> Void
    let onCopyTranscript: (MeetingSession, Bool) -> Void
    let onExportTranscript: (MeetingSession, MeetingTranscriptExportFormat, Bool) -> Void
    let onReassignSegment: (MeetingSessionID, MeetingTranscriptSegmentID, SessionSpeakerID) -> Void
    let onNameUnknownSegment: (MeetingSessionID, MeetingTranscriptSegmentID, String) -> Void
    let onRenameSpeaker: (MeetingSessionID, SessionSpeakerID, String) -> Void
    let onMergeSpeakers: (MeetingSessionID, SessionSpeakerID, SessionSpeakerID) -> Void
    let onUndoCorrection: (MeetingSessionID) -> Void
    let onRenameSession: (MeetingSessionID, String) -> Void
    let onAssignSpeakers: (MeetingSessionID, [SessionSpeakerID: String]) async -> String?
    let canUndoCorrection: (MeetingSessionID) -> Bool
    let isQuiescent: Bool
    let onRepairSetup: () -> Void
    var onEditSetup: (() -> Void)? = nil
    let isRetrying: Bool
    let onCloseSelection: (() -> Void)?

    var summaryASRService: ASRService? = nil

    @Environment(\.theme) private var theme

    /// Recording renders outside the ScrollView so the live captions card can fill the height;
    /// its transcript list is its own scroller, and nested scrolling would fight it.
    private var fillsCanvasHeight: Bool {
        switch self.state {
        case .recording, .stopping, .result: true
        default: false
        }
    }

    var body: some View {
        Group {
            if self.fillsCanvasHeight {
                self.canvasContent
                    .frame(maxWidth: 820)
                    .padding(self.theme.metrics.spacing.lg * 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    self.canvasContent
                        .frame(maxWidth: 720)
                        .padding(self.theme.metrics.spacing.lg * 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.windowBackground)
    }

    @ViewBuilder
    private var canvasContent: some View {
        Group {
            switch self.state {
            case let .setup(isStarting, recentSession):
                MeetingSetupCanvas(
                    draft: self.$setupDraft,
                    applications: self.applications,
                    readiness: self.readiness,
                    isStarting: isStarting,
                    errorMessage: self.errorMessage,
                    recentSession: recentSession,
                    onStart: self.onStart,
                    onRepairSetup: self.onRepairSetup,
                    onEditSetup: self.onEditSetup ?? self.onRepairSetup,
                    summaryASRService: self.summaryASRService,
                    isQuiescent: self.isQuiescent
                )
            case let .recording(session, trackHealth, liveTranscript):
                MeetingRecordingCanvas(
                    session: session,
                    trackHealth: trackHealth,
                    liveTranscript: liveTranscript,
                    isStopping: false,
                    onStop: self.onStop
                )
            case let .stopping(session, trackHealth, liveTranscript):
                MeetingRecordingCanvas(
                    session: session,
                    trackHealth: trackHealth,
                    liveTranscript: liveTranscript,
                    isStopping: true,
                    onStop: self.onStop
                )
            case let .processing(session, stage):
                MeetingProcessingCanvas(session: session, stage: stage)
            case let .result(session):
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                    if let errorMessage, !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityIdentifier("meeting-result-action-error")
                    }
                    MeetingResultCanvas(
                        session: session,
                        isQuiescent: self.isQuiescent,
                        canUndo: self.canUndoCorrection(session.id),
                        onCopyTranscript: self.onCopyTranscript,
                        onExportTranscript: self.onExportTranscript,
                        onReassignSegment: { segmentID, speakerID in
                            self.onReassignSegment(session.id, segmentID, speakerID)
                        },
                        onNameUnknownSegment: { segmentID, name in
                            self.onNameUnknownSegment(session.id, segmentID, name)
                        },
                        onRenameSpeaker: { speakerID, name in
                            self.onRenameSpeaker(session.id, speakerID, name)
                        },
                        onMergeSpeakers: { source, target in
                            self.onMergeSpeakers(session.id, source, target)
                        },
                        onUndo: { self.onUndoCorrection(session.id) },
                        onRenameSession: { title in self.onRenameSession(session.id, title) },
                        onAssignSpeakers: { names in await self.onAssignSpeakers(session.id, names) },
                        onClose: self.onCloseSelection,
                        summaryASRService: self.summaryASRService
                    )
                }
            case let .failed(session, message):
                MeetingFailureCanvas(
                    session: session,
                    message: self.errorMessage ?? message,
                    isRetrying: self.isRetrying,
                    onRetrySession: self.onRetrySession,
                    onRevealAudio: self.onRevealAudio,
                    onRecordAgain: self.onRecordAgain,
                    onClose: self.onCloseSelection
                )
            }
        }
    }
}

private struct MeetingTranscriptionHeader: View {
    let state: MeetingTranscriptionCanvasState
    let isMeetingHistoryVisible: Bool
    let onNewMeeting: () -> Void
    let onOpenMeetingSettings: () -> Void
    let onToggleMeetingHistory: () -> Void

    var body: some View {
        Group {
            if self.canStartNewMeeting {
                MeetingHeaderIconButton(
                    systemImage: "plus",
                    label: "New Meeting",
                    action: self.onNewMeeting
                )
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityHint("Clear the current meeting and return to recording setup")
            }

            MeetingHeaderIconButton(
                systemImage: "gearshape",
                label: "FluidMeet settings",
                action: self.onOpenMeetingSettings
            )
            .disabled(!self.canEditSetup)
            .accessibilityHint("Change the saved recording application, microphone, and meeting defaults")

            MeetingHeaderIconButton(
                systemImage: self.isMeetingHistoryVisible
                    ? "rectangle.righthalf.inset.filled"
                    : "sidebar.right",
                label: self.isMeetingHistoryVisible ? "Hide meeting history" : "Show meeting history",
                isSelected: self.isMeetingHistoryVisible,
                action: self.onToggleMeetingHistory
            )
        }
    }

    private var canStartNewMeeting: Bool {
        switch self.state {
        case .result, .failed:
            return true
        case .setup, .recording, .stopping, .processing:
            return false
        }
    }

    private var canEditSetup: Bool {
        switch self.state {
        case let .setup(isStarting, _): !isStarting
        case .result, .failed: true
        case .recording, .stopping, .processing: false
        }
    }
}

private struct MeetingHeaderIconButton: View {
    let systemImage: String
    let label: String
    var isSelected = false
    let action: () -> Void

    @Environment(\.theme) private var theme
    var body: some View {
        Button(action: self.action) {
            Label(self.label, systemImage: self.systemImage)
                .foregroundStyle(self.isSelected ? self.theme.palette.accent : self.theme.palette.primaryText)
        }
        .buttonStyle(.automatic)
        .help(self.label)
        .accessibilityLabel(self.label)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}

private struct MeetingHistoryInspector: View {
    let sessions: [MeetingSession]
    @Binding var selectedSessionID: MeetingSessionID?
    let errorMessage: String?
    let isLoading: Bool
    let isQuiescent: Bool
    let onRefresh: () -> Void
    let onRetry: (MeetingSessionID) -> Void
    let onRevealAudio: (MeetingSession) -> Void
    let onExportAudio: (MeetingSession) -> Void
    let onExportTranscript: (MeetingSession, MeetingTranscriptExportFormat) -> Void
    let onDeleteAudioRequest: (MeetingSessionID) -> Void
    let onDeleteRequest: (MeetingSessionID) -> Void
    let onRename: (MeetingSessionID, String) -> Void
    let onRecordAgain: (MeetingSession) -> Void

    @State private var renameSessionID: MeetingSessionID?
    @State private var renameDraft = ""

    @Environment(\.theme) private var theme
    @State private var searchText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredSessions: [MeetingSession] {
        let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return self.sessions }
        return self.sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(query) ||
                session.capturedApplication?.displayName.localizedCaseInsensitiveContains(query) == true ||
                session.activeSpeakers.contains(where: { $0.displayName.localizedCaseInsensitiveContains(query) })
        }
    }

    /// Sessions arrive newest-first, so a first-seen-order bucket walk keeps groups chronological.
    private var groupedSessions: [(key: String, sessions: [MeetingSession])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [MeetingSession]] = [:]
        for session in self.filteredSessions {
            let key = Self.dayLabel(for: session.startedAt, calendar: calendar)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(session)
        }
        return order.map { (key: $0, sessions: buckets[$0] ?? []) }
    }

    private static func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Meetings")
                    .font(self.theme.typography.bodySmallStrong)
                Text("\(self.sessions.count)")
                    .font(self.theme.typography.badge)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Spacer()
                Button(action: self.onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .meetingHoverFeedback()
                .help("Refresh meeting history")
                .accessibilityLabel("Refresh meeting history")
            }
            .padding(.horizontal, self.theme.metrics.spacing.lg)
            .padding(.top, self.theme.metrics.spacing.lg)
            .padding(.bottom, self.theme.metrics.spacing.md)

            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search meetings", text: self.$searchText).textFieldStyle(.plain)
                if !self.searchText.isEmpty {
                    Button { self.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .meetingHoverFeedback()
                    .accessibilityLabel("Clear meeting search")
                }
            }
            .padding(self.theme.metrics.spacing.md)
            .fluidDropdownSurface()
            .padding(.horizontal, self.theme.metrics.spacing.lg)
            .padding(.bottom, self.theme.metrics.spacing.md)

            Divider()

            if let errorMessage, !self.sessions.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(self.theme.metrics.spacing.md)
            }

            if let errorMessage, self.sessions.isEmpty {
                ContentUnavailableView(
                    "History unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if self.isLoading, self.sessions.isEmpty {
                ProgressView("Loading meetings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.filteredSessions.isEmpty {
                ContentUnavailableView(
                    self.searchText.isEmpty ? "No meetings yet" : "No matching meetings",
                    systemImage: self.searchText.isEmpty ? "person.2.wave.2" : "magnifyingglass",
                    description: Text(self.searchText.isEmpty
                        ? "Completed meetings will appear here."
                        : "Try a different title, app, or speaker.")
                )
            } else {
                // Rows draw their own selection/hover fill (never the saturated system blue),
                // so a plain ScrollView replaces List here instead of fighting its native highlight.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(self.groupedSessions, id: \.key) { group in
                                Section {
                                    ForEach(group.sessions) { session in
                                        MeetingHistoryRow(
                                            session: session,
                                            isSelected: self.selectedSessionID == session.id,
                                            isQuiescent: self.isQuiescent,
                                            onSelect: { self.selectedSessionID = session.id },
                                            onRetry: { self.onRetry(session.id) },
                                            onRename: { self.onRename(session.id, $0) },
                                            onRecordAgain: { self.onRecordAgain(session) }
                                        )
                                        .id(session.id)
                                        .contextMenu { self.contextMenu(for: session) }
                                        .overlay(alignment: .topTrailing) {
                                            Menu { self.contextMenu(for: session) } label: {
                                                Image(systemName: "ellipsis")
                                                    .frame(width: 24, height: 24)
                                                    .contentShape(Rectangle())
                                            }
                                            .menuStyle(.borderlessButton)
                                            .menuIndicator(.hidden)
                                            .fixedSize()
                                            .meetingHoverFeedback()
                                            .accessibilityLabel("Actions for \(session.title)")
                                            .padding(self.theme.metrics.spacing.sm)
                                        }
                                    }
                                } header: {
                                    // Matches the Command sidebar: unpinned, aligned with the row icons.
                                    Text(group.key)
                                        .font(self.theme.typography.caption)
                                        .foregroundStyle(self.theme.palette.secondaryText)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, self.theme.metrics.spacing.md)
                                        .padding(.top, self.theme.metrics.spacing.lg)
                                        .padding(.bottom, self.theme.metrics.spacing.xs)
                                }
                            }
                        }
                        .padding(.horizontal, self.theme.metrics.spacing.sm)
                        .padding(.bottom, self.theme.metrics.spacing.md)
                    }
                    // Dropping List for a custom highlight also drops its arrow-key traversal.
                    .focusable()
                    .onMoveCommand { direction in
                        guard let moved = self.sessionID(movingFrom: self.selectedSessionID, direction: direction)
                        else { return }
                        self.selectedSessionID = moved
                        withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(moved, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(self.theme.materials.sidebar)
        .alert("Rename Meeting", isPresented: Binding(
            get: { self.renameSessionID != nil },
            set: { if !$0 { self.renameSessionID = nil } }
        )) {
            TextField("Meeting title", text: self.$renameDraft)
            Button("Cancel", role: .cancel) { self.renameSessionID = nil }
            Button("Rename") {
                if self.isQuiescent, let id = self.renameSessionID,
                   self.sessions.contains(where: { $0.id == id })
                {
                    self.onRename(id, self.renameDraft)
                }
                self.renameSessionID = nil
            }
            .disabled(!self.isQuiescent || self.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sessionID(
        movingFrom current: MeetingSessionID?,
        direction: MoveCommandDirection
    ) -> MeetingSessionID? {
        MeetingHistoryTraversal.sessionID(
            movingFrom: current,
            direction: direction,
            ordered: self.groupedSessions.flatMap(\.sessions).map(\.id)
        )
    }

    @ViewBuilder
    private func contextMenu(for session: MeetingSession) -> some View {
        Button("Rename…", systemImage: "pencil") {
            self.renameDraft = session.title
            self.renameSessionID = session.id
        }
        .disabled(!self.isQuiescent)
        Divider()
        if session.hasRetryableAudio, session.state == .failed || session.state == .interrupted {
            Button("Retry Transcription", systemImage: "arrow.clockwise") {
                self.onRetry(session.id)
            }
            .disabled(!self.isQuiescent)
        }
        Button("Reveal Audio", systemImage: "folder") {
            self.onRevealAudio(session)
        }
        Button("Export Audio…", systemImage: "square.and.arrow.up") {
            self.onExportAudio(session)
        }
        .disabled(!session.hasFinalizedAudio)
        Button("Export Transcript (Text)…", systemImage: "doc.text") {
            self.onExportTranscript(session, .text)
        }
        .disabled(!session.transcriptSegments.contains(where: { !$0.isEcho }))
        Button("Export Transcript (JSON)…", systemImage: "curlybraces") {
            self.onExportTranscript(session, .json)
        }
        .disabled(session.transcriptSegments.isEmpty)
        if session.hasFinalizedAudio, session.retention.audioDeletedAt == nil, session.state == .completed {
            Button("Delete Audio (Keep Transcript)…", systemImage: "waveform.slash") {
                self.onDeleteAudioRequest(session.id)
            }
            .disabled(!self.isQuiescent)
        }
        Divider()
        Button("Delete Meeting…", systemImage: "trash", role: .destructive) {
            self.onDeleteRequest(session.id)
        }
        .disabled(!self.isQuiescent)
    }
}

nonisolated enum MeetingHistoryTraversal {
    static func sessionID(
        movingFrom current: MeetingSessionID?,
        direction: MoveCommandDirection,
        ordered: [MeetingSessionID]
    ) -> MeetingSessionID? {
        guard !ordered.isEmpty else { return nil }
        guard let current, let index = ordered.firstIndex(of: current) else { return ordered.first }
        switch direction {
        case .up: return index > 0 ? ordered[index - 1] : nil
        case .down: return index < ordered.count - 1 ? ordered[index + 1] : nil
        default: return nil
        }
    }
}

private struct MeetingHistoryRow: View {
    let session: MeetingSession
    let isSelected: Bool
    let isQuiescent: Bool
    let onSelect: () -> Void
    let onRetry: () -> Void
    let onRename: (String) -> Void
    let onRecordAgain: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Button(action: self.onSelect) {
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                    self.tile
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text(self.session.title)
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.trailing, self.theme.metrics.spacing.xxl)
                        self.secondaryLine
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.vertical, self.theme.metrics.spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(self.session.title), \(self.statusText), \(self.sourceName)")
            .accessibilityAddTraits(self.isSelected ? .isSelected : [])
            .editableTitle(self.session.title, id: String(describing: self.session.id), enabled: self.isQuiescent, onRename: self.onRename)
            if let actionLabel {
                Button(actionLabel, action: self.performAction)
                    .buttonStyle(.borderless)
                    .meetingHoverFeedback()
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.actionColor)
                    .disabled(!self.isQuiescent)
                    .accessibilityLabel(self.actionAccessibilityLabel ?? actionLabel)
                    .padding(.leading, 18 + self.theme.metrics.spacing.md * 2)
                    .padding(.bottom, self.theme.metrics.spacing.sm)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.rowBackground)
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: self.isHovered && self.isEnabled)
        }
        .contentShape(Rectangle())
        .onHover { self.isHovered = $0 && self.isEnabled }
        .onChange(of: self.isEnabled) { _, enabled in
            if !enabled { self.isHovered = false }
        }
        .onDisappear { self.isHovered = false }
        .accessibilityElement(children: .contain)
    }

    private var tile: some View {
        Image(systemName: self.tileIcon)
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(self.tileIconColor)
            .frame(width: 18, height: 22)
    }

    @ViewBuilder
    private var secondaryLine: some View {
        HStack(spacing: self.theme.metrics.spacing.xs) {
            ForEach(Array(self.secondaryTextParts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·").foregroundStyle(self.theme.palette.tertiaryText)
                }
                Text(part)
            }
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.secondaryText)
        .lineLimit(1)
    }

    private func performAction() {
        switch self.session.state {
        case .interrupted: self.onRetry()
        case .failed: self.onRecordAgain()
        default: break
        }
    }

    private var timeText: String {
        self.session.startedAt.formatted(date: .omitted, time: .shortened)
    }

    private var secondaryTextParts: [String] {
        switch self.session.state {
        case .completed:
            var parts = [self.timeText, Self.durationText(self.session.duration)]
            if !self.session.activeSpeakers.isEmpty {
                parts.append(self.session.activeSpeakers.count == 1 ? "1 speaker" : "\(self.session.activeSpeakers.count) speakers")
            }
            return parts
        case .interrupted:
            return [self.timeText, "Interrupted"]
        case .failed:
            return [self.timeText, "Failed"]
        case .processing:
            return [self.timeText, "Processing"]
        case .recording, .recordingDegraded, .preparing, .stopping:
            return [self.timeText, "Recording"]
        }
    }

    private var actionLabel: String? {
        switch self.session.state {
        case .interrupted: return self.session.hasRetryableAudio ? "Retry" : nil
        case .failed: return "Record again"
        default: return nil
        }
    }

    /// The row shows "Retry" to fit a narrow sidebar; spoken output keeps the full sentence.
    private var actionAccessibilityLabel: String? {
        switch self.session.state {
        case .interrupted: return self.session.hasRetryableAudio ? "Retry transcription" : nil
        case .failed: return "Record again"
        default: return nil
        }
    }

    private var actionColor: Color {
        self.session.state == .interrupted ? self.theme.palette.warning : self.theme.palette.accent
    }

    private var rowBackground: Color {
        if self.isSelected { return self.theme.palette.primaryText.opacity(self.isHovered && self.isEnabled ? 0.14 : 0.08) }
        if self.isHovered && self.isEnabled { return self.theme.palette.primaryText.opacity(0.06) }
        return .clear
    }

    private var sourceName: String {
        self.session.capturedApplication?.displayName ?? "In-room"
    }

    private var statusText: String {
        switch self.session.state {
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .processing: "Processing"
        case .recording, .recordingDegraded, .preparing, .stopping: "Recording"
        }
    }

    private var tileIcon: String {
        switch self.session.state {
        case .interrupted: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle"
        default: "doc.text"
        }
    }

    private var tileIconColor: Color {
        switch self.session.state {
        case .interrupted: self.theme.palette.warning
        case .failed: Color(nsColor: .systemRed)
        default: self.theme.palette.secondaryText
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        if totalMinutes >= 60 {
            return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
        }
        return "\(max(1, totalMinutes))m"
    }
}

private struct MeetingSetupCanvas: View {
    @Binding var draft: MeetingTranscriptionSetupDraft

    let applications: [MeetingApplicationOption]
    let readiness: MeetingSetupReadiness
    let isStarting: Bool
    let errorMessage: String?
    let recentSession: MeetingSession?
    let onStart: () -> Void
    let onRepairSetup: () -> Void
    let onEditSetup: () -> Void
    var summaryASRService: ASRService? = nil
    var isQuiescent = true

    @Environment(\.theme) private var theme
    @State private var documentSection = MeetingDocumentSection.transcript

    private var systemsReady: Bool {
        !self.readiness.isCheckingSources &&
            self.readiness.microphoneReady &&
            self.readiness.storageReady &&
            self.readiness.activityReady &&
            self.readiness.meetingAudioReady
    }

    private var canStart: Bool {
        self.systemsReady && self.draft.selectedMicrophoneID != nil &&
            !self.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resolvedApplication: MeetingApplicationOption? {
        guard self.draft.mode == .onlineCall else { return nil }
        return self.applications.first(where: { $0.id == self.draft.selectedApplicationID })
    }

    private var blockedHelp: String {
        if let blockingMessage = readiness.blockingMessage { return blockingMessage }
        if self.draft.selectedMicrophoneID == nil { return "Choose a microphone in Settings to continue." }
        return "Check the recording setup."
    }

    private var planHeadline: String {
        if let app = resolvedApplication { return "\(app.identity.displayName) is open." }
        return self.draft.mode == .inRoom ? "In-person meeting." : "No call open."
    }

    private var planDetail: String {
        if let app = resolvedApplication { return "\(app.identity.displayName) and your mic will be recorded." }
        if self.draft.mode == .inRoom { return "Your mic will record the room." }
        if self.readiness.showScreenRecordingSettingsAction {
            return "Your mic will record the room. Allow Screen & System Audio access to capture meeting apps too."
        }
        if self.applications.isEmpty { return "Your mic will record the room. No meeting apps are available to capture yet." }
        return "Your mic will record the room. If a call is running, pick its app under Change."
    }

    private var sourceLabel: String {
        if let app = resolvedApplication { return app.identity.displayName }
        return self.draft.mode == .inRoom ? "In person" : "Automatic"
    }

    private var meetingApplications: [MeetingApplicationOption] {
        self.applications.filter { MeetingAppRegistry.tier(forBundleIdentifier: $0.identity.bundleIdentifier) != nil }
    }

    private var otherApplications: [MeetingApplicationOption] {
        self.applications.filter { MeetingAppRegistry.tier(forBundleIdentifier: $0.identity.bundleIdentifier) == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                MeetingDocumentTitle(title: "Be in the conversation.")
                Text("Record your meeting. Come back to every word.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MeetingDocumentTabs(selection: self.$documentSection, primaryTitle: "Meeting home", primaryIcon: "house", isEnabled: !self.isStarting)

            if self.documentSection == .summary {
                MeetingSummaryView(asrService: self.summaryASRService, isQuiescent: self.isQuiescent)
            } else {
                self.recordingSetup
            }
        }
    }

    private var recordingSetup: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            ThemedCard(style: .standard, padding: self.theme.metrics.spacing.xl) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                    self.plan
                    FluidGlassControlGroup {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: self.theme.metrics.spacing.md) { self.actions }
                            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) { self.actions }
                        }
                    }
                }
            }

            self.recordingFooter
        }
    }

    @ViewBuilder private var plan: some View {
        if self.readiness.isCheckingSources {
            MeetingHomeStatus(kind: .checking, title: "Checking your setup…", detail: "This only takes a moment.")
        } else if !self.canStart {
            MeetingHomeStatus(kind: .blocked, title: "One thing before recording", detail: self.blockedHelp)
        } else {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(self.planHeadline)
                    .font(.system(.title2, design: .serif).weight(.medium))
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(self.planDetail)
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var actions: some View {
        self.startAction
        self.sourceMenu
        self.permissionAction
    }

    private var sourceMenu: some View {
        Menu {
            self.sourceEntry("In person · mic only", systemImage: "person.2", selected: self.draft.mode == .inRoom) {
                self.draft.mode = .inRoom
            }
            self.sourceEntry(
                "Automatic · follows a detected call",
                systemImage: "wand.and.stars",
                selected: self.draft.mode == .onlineCall && self.draft.usesAutomaticApplication
            ) {
                self.draft.mode = .onlineCall
                self.draft.usesAutomaticApplication = true
                self.draft.selectedApplicationID = nil
            }
            if !self.meetingApplications.isEmpty {
                Divider()
                ForEach(self.meetingApplications) { option in
                    self.applicationEntry(option)
                }
            }
            if !self.otherApplications.isEmpty {
                Divider()
                Menu("Other audio sources") {
                    ForEach(self.otherApplications) { option in
                        self.applicationEntry(option)
                    }
                }
            }
            if self.readiness.showScreenRecordingSettingsAction {
                Divider()
                Button("Allow meeting audio access…", systemImage: "arrow.up.right", action: self.onRepairSetup)
            }
            Divider()
            Button("More settings…", systemImage: "gearshape", action: self.onEditSetup)
        } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Change · \(self.sourceLabel)")
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .meetingGlassAction(spacious: true)
        .disabled(self.isStarting)
        .help("Choose what gets recorded.")
        .accessibilityLabel("Change recording source. Currently \(self.sourceLabel)")
    }

    private func applicationEntry(_ option: MeetingApplicationOption) -> some View {
        let selected = self.draft.mode == .onlineCall && !self.draft.usesAutomaticApplication && self.draft.selectedApplicationID == option.id
        return self.sourceEntry(option.identity.displayName, systemImage: "app", selected: selected) {
            self.draft.mode = .onlineCall
            self.draft.usesAutomaticApplication = false
            self.draft.selectedApplicationID = option.id
        }
    }

    private func sourceEntry(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var recordingFooter: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            Label(
                self.resolvedApplication != nil
                    ? "Stays on this Mac. Use headphones for clearer speaker separation."
                    : "Stays on this Mac. Place it where everyone can be heard.",
                systemImage: "lock"
            )
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if let errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Could not start recording. \(errorMessage)")
            }

            if let recentSession {
                Divider()
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(self.theme.palette.secondaryText)
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text("Last meeting").font(self.theme.typography.caption).foregroundStyle(.secondary)
                        Text(recentSession.title).font(self.theme.typography.bodyStrong).lineLimit(2)
                    }
                    Spacer()
                    Text(Self.durationText(recentSession.duration))
                        .font(self.theme.typography.codeCaption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var permissionAction: some View {
        if !self.readiness.isCheckingSources,
           self.readiness.showScreenRecordingSettingsAction ||
           (!self.canStart && (self.readiness.showMicrophoneSettingsAction ||
                   !self.readiness.microphoneReady || self.draft.selectedMicrophoneID == nil))
        {
            Button(
                self.readiness.showMicrophoneSettingsAction ? "Allow microphone access" :
                    (self.readiness.showScreenRecordingSettingsAction ? "Allow meeting audio access" :
                        "Set up microphone…"),
                systemImage: self.readiness.showMicrophoneSettingsAction || self.readiness.showScreenRecordingSettingsAction ? "arrow.up.right" : "gearshape",
                action: self.onRepairSetup
            )
            .meetingGlassAction(spacious: true)
            .disabled(self.isStarting)
        }
    }

    private var startAction: some View {
        Button(action: self.onStart) {
            Label(self.isStarting ? "Starting…" : "Start recording", systemImage: self.isStarting ? "hourglass" : "record.circle")
        }
        .meetingGlassAction(prominent: true, spacious: true)
        .disabled(!self.canStart || self.isStarting)
        .keyboardShortcut(.defaultAction)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Readiness at a glance: a single dot carries the state, the text explains it.
private struct MeetingHomeStatus: View {
    enum Kind { case checking, blocked }

    let kind: Kind
    let title: String
    let detail: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.md) {
            Group {
                if self.kind == .checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(self.theme.palette.warning)
                }
            }
            .frame(width: 12, height: 12)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(self.title)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(self.detail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.title). \(self.detail)")
    }
}
