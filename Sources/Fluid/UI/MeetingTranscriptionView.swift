import AppKit
import AVFoundation
import Combine
import CoreGraphics
import SwiftUI

nonisolated struct MeetingApplicationOption: Identifiable, Equatable, Sendable {
    let id: String
    let identity: MeetingApplicationIdentity
    var icon: MeetingApplicationIcon?

    init(identity: MeetingApplicationIdentity, icon: MeetingApplicationIcon? = nil) {
        self.identity = identity
        self.icon = icon
        self.id = "\(identity.bundleIdentifier)-\(identity.processID ?? 0)"
    }
}

extension [MeetingApplicationOption] {
    /// The usual meeting sources first, then the rest with background helpers last.
    @MainActor
    var pickerSections: (usual: [MeetingApplicationOption], others: [MeetingApplicationOption]) {
        MeetingAppRegistry.pickerSections(
            self,
            bundleIdentifier: { $0.identity.bundleIdentifier },
            name: { $0.identity.displayName },
            isBackgroundItem: { _ in false }
        )
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
    var mode: MeetingCaptureMode = .systemAudio
    var title: String = Self.defaultTitle(mode: .onlineCall, applicationDisplayName: nil)
    var selectedApplicationID: String?
    var usesAutomaticApplication = true
    var preferredApplicationBundleIdentifier: String?
    var applicationSelectionWasEdited = false
    var selectedMicrophoneID: String?
    /// Once true, the default title stops following the selected application/mode.
    var languageCode: String
    var titleWasEdited = false
    var autoDetectEnabled: Bool
    var browserDetectionEnabled: Bool

    init(settings: SettingsStore = .shared) {
        self.init(
            defaults: settings.meetingRecordingDefaults.preferringLastPickedApplication(settings.meetingRecentApplication),
            autoDetectEnabled: settings.meetingAutoDetectEnabled,
            browserDetectionEnabled: settings.meetingAutoDetectBrowserEnabled
        )
    }

    init(defaults: MeetingRecordingDefaults, autoDetectEnabled: Bool, browserDetectionEnabled: Bool) {
        let defaults = defaults.preferringLastPickedApplication(nil)
        self.autoDetectEnabled = autoDetectEnabled
        self.browserDetectionEnabled = browserDetectionEnabled
        self.languageCode = defaults.languageCode ?? "en"
        self.mode = defaults.mode
        self.title = Self.defaultTitle(mode: defaults.mode, applicationDisplayName: nil)
        self.selectedApplicationID = nil
        self.preferredApplicationBundleIdentifier = defaults.isConfigured ? defaults.applicationBundleIdentifier : nil
        self.usesAutomaticApplication = self.preferredApplicationBundleIdentifier == nil
        // Left unset here: selectPreferredMicrophone decides once identities load.
        self.selectedMicrophoneID = nil
    }

    static func defaultTitle(mode: MeetingCaptureMode, applicationDisplayName: String?) -> String {
        if mode == .inRoom { return "In-room meeting" }
        if mode == .systemAudio { return "Meeting" }
        guard let applicationDisplayName, !applicationDisplayName.isEmpty else { return "Meeting" }
        return "\(applicationDisplayName) call"
    }

    func applyingSource(to previous: MeetingRecordingDefaults, application: MeetingApplicationIdentity?) -> MeetingRecordingDefaults {
        var defaults = previous
        defaults.isConfigured = true
        defaults.mode = self.mode
        if self.usesAutomaticApplication {
            defaults.applicationBundleIdentifier = nil
            defaults.applicationDisplayName = nil
        } else {
            let bundleIdentifier = application?.bundleIdentifier ?? self.preferredApplicationBundleIdentifier
            defaults.applicationBundleIdentifier = bundleIdentifier
            defaults.applicationDisplayName = application?.displayName
                ?? (previous.applicationBundleIdentifier == bundleIdentifier ? previous.applicationDisplayName : nil)
        }
        return defaults
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

/// Registers only this meeting's saved corrections with the window's native Undo command.
@MainActor
final class MeetingCorrectionUndoRegistration: ObservableObject {
    private weak var manager: UndoManager?
    private var sessionID: MeetingSessionID?
    private var isEnabled = false
    private var action: (@MainActor () async -> Bool)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func refresh(manager: UndoManager?, sessionID: MeetingSessionID, isEnabled: Bool, action: @escaping @MainActor () async -> Bool) {
        if self.manager !== manager || self.sessionID != sessionID { self.detach() }
        self.manager = manager
        self.sessionID = sessionID
        self.isEnabled = isEnabled
        self.action = action
        if self.task == nil { self.install() }
    }

    func detach() {
        self.manager?.removeAllActions(withTarget: self)
        self.manager = nil
        self.sessionID = nil
        self.action = nil
        self.isEnabled = false
        self.generation = UUID()
        // An authorized save may finish after navigation, but must never register Undo in
        // the next meeting or another page. Do not cancel persistence mid-write.
        self.task = nil
    }

    private func install() {
        guard let manager = self.manager else { return }
        manager.removeAllActions(withTarget: self)
        guard self.isEnabled else { return }
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { $0.performUndo() }
        manager.setActionName("Meeting Correction")
        manager.endUndoGrouping()
    }

    private func performUndo() {
        guard self.isEnabled, self.task == nil, let action = self.action else { return }
        let generation = self.generation
        self.task = Task { @MainActor in
            let hasMore = await action()
            guard self.generation == generation else { return }
            self.task = nil
            self.isEnabled = self.isEnabled && hasMore
            // Register after the async save, outside UndoManager's undo callback. This is
            // another correction to undo, not a redo. A failed save remains retryable.
            self.install()
        }
    }
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
        try await MeetingSessionStore.shared.loadHistory()
    }) {
        self.load = load
    }

    /// A correction already returned the saved session. Publish it without rereading every
    /// meeting and probing all their audio chunks. An older in-flight read must not undo it.
    func applySavedSession(_ session: MeetingSession) {
        if let index = self.sessions.firstIndex(where: { $0.id == session.id }) {
            self.sessions[index] = session
        } else {
            self.sessions.append(session)
            self.sessions.sort { $0.startedAt > $1.startedAt }
        }
        if self.refreshTask != nil { self.refreshRequested = true }
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
    @ObservedObject private var summaryActivity = MeetingSummaryActivityCoordinator.shared
    let onOpenVoiceEngine: () -> Void
    let resumingSummarySessionID: MeetingSessionID?

    @Environment(\.theme) private var theme

    @State private var setupDraft: MeetingTranscriptionSetupDraft
    @State private var setupDraftBeforeEditing: MeetingTranscriptionSetupDraft
    @State private var pendingBackupSetupRefresh = false
    @State private var pendingSourceChoiceRefresh = false
    @State private var cachedSystemDefaultMicrophoneUID: String?
    @State private var isShowingMeetingSettings: Bool
    /// Which tab the settings sheet opens on; set just before it is shown.
    @State private var meetingSettingsInitialSection: MeetingSettingsSection = .recording
    @State private var applications: [MeetingApplicationOption] = []
    @State private var microphones: [MeetingMicrophoneOption] = []
    @State private var isRefreshingSources = false
    @State private var lastSourceRefresh: Date?
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
    @State private var storageReadinessRevision = 0
    @ObservedObject var historySnapshot: MeetingHistorySnapshot
    @State private var route: MeetingRoute
    @State private var pendingDeleteSessionID: MeetingSessionID?
    @State private var pendingDeleteAudioSessionID: MeetingSessionID?
    @State private var draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy

    init(
        coordinator: MeetingSessionCoordinator,
        asrService: ASRService,
        historySnapshot: MeetingHistorySnapshot,
        resumingSummarySessionID: MeetingSessionID? = nil,
        onOpenVoiceEngine: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.asrService = asrService
        self.historySnapshot = historySnapshot
        self.resumingSummarySessionID = resumingSummarySessionID
        self.onOpenVoiceEngine = onOpenVoiceEngine
        if let resumingSummarySessionID, coordinator.state != .completed(resumingSummarySessionID) {
            self._route = State(initialValue: .meeting(resumingSummarySessionID))
        } else {
            self._route = State(initialValue: .home)
        }

        let initialDraft = MeetingTranscriptionSetupDraft(settings: .shared)
        self._setupDraft = State(initialValue: initialDraft)
        self._setupDraftBeforeEditing = State(initialValue: initialDraft)
        self._isShowingMeetingSettings = State(initialValue: false)
    }

    var body: some View {
        let screen = self.screen
        VStack(spacing: 0) {
            if case .canvas = screen {
                MeetingTranscriptionHeader(
                    actions: MeetingHeaderActions(
                        screen: screen,
                        isQuiescent: self.coordinator.isQuiescent,
                        isSummaryRunning: self.summaryActivity.selectionLock != nil
                    ),
                    onBack: self.goHome,
                    onNewRecording: self.openRecordingView,
                    onOpenMeetingSettings: self.openMeetingSettings
                )
                .padding(.horizontal, FluidPageLayout.inset)
                .padding(.vertical, 12)
                Divider()
            }

            switch screen {
            case .home:
                self.homeList
            case let .canvas(state):
                self.canvas(for: state)
            }
        }
        .fluidCanvas()
        .clipped()
        .onFluidPagePresented { MeetingDiarizationModelStore.shared.prepareInBackground() }
        .task { await self.refreshPageData() }
        .onChange(of: self.setupDraft.mode) { _, _ in
            Task { await self.refreshSources(requestPermissions: false) }
            self.regenerateDefaultTitleIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsBackupDidRestore)) { _ in
            self.pendingBackupSetupRefresh = true
            self.applyPendingBackupSetupRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingRecordingSourceChoiceDidChange)) { _ in
            self.pendingSourceChoiceRefresh = true
            self.applyPendingSourceChoiceRefresh()
        }
        .onChange(of: self.canRefreshSetupAfterBackupRestore) { _, canRefresh in
            if canRefresh {
                self.applyPendingBackupSetupRefresh()
                self.applyPendingSourceChoiceRefresh()
            }
        }
        .onChange(of: self.setupDraft.selectedApplicationID) { _, _ in
            self.regenerateDefaultTitleIfNeeded()
        }
        .onChange(of: self.setupDraft.usesAutomaticApplication) { _, automatic in
            guard automatic else { return }
            self.selectPreferredApplication(from: self.applications.map(\.identity))
        }

        .onChange(of: self.coordinator.latestCompletedSession?.id) { _, _ in
            Task { await self.loadMeetingHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                async let sources: Void = self.refreshSources(requestPermissions: false)
                await self.loadMeetingHistory()
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
                onModelImported: { Task { await self.refreshModelReadiness() } },
                initialSection: self.meetingSettingsInitialSection
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

    private var screen: MeetingScreen {
        MeetingScreen(route: self.route, canvasState: self.canvasState)
    }

    private var homeList: some View {
        MeetingHomeList(
            sessions: self.historySnapshot.sessions,
            historyErrorMessage: self.historySnapshot.errorMessage,
            actionErrorMessage: self.actionErrorMessage,
            isLoading: !self.historySnapshot.hasLoaded,
            isQuiescent: self.coordinator.isQuiescent,
            canStartRecording: MeetingHeaderActions(
                screen: .home,
                isQuiescent: self.coordinator.isQuiescent,
                isSummaryRunning: self.summaryActivity.selectionLock != nil
            ).canStartRecording,
            actions: self.homeActions
        )
    }

    private var homeActions: MeetingHomeActions {
        MeetingHomeActions(
            openMeeting: self.openMeeting,
            startRecording: self.openRecordingView,
            retry: { id in
                let session = self.historySnapshot.sessions.first { $0.id == id }
                self.retryProcessingSession(
                    id: id,
                    languageCode: session.flatMap(MeetingRetranscriptionLanguage.failedAttemptLanguage(for:))
                )
            },
            revealAudio: self.revealCapturedAudio,
            exportAudio: self.exportAudio,
            exportTranscript: { self.exportTranscript($0, format: $1, includeEchoes: false) },
            requestAudioDeletion: { self.pendingDeleteAudioSessionID = $0 },
            requestDeletion: { self.pendingDeleteSessionID = $0 },
            rename: { self.renameMeetingSession(sessionID: $0, to: $1) },
            recordAgain: self.recordAgain,
            openIntegrations: self.openMeetingIntegrations,
            openSettings: self.openMeetingSettings
        )
    }

    private func canvas(for state: MeetingTranscriptionCanvasState) -> some View {
        MeetingTranscriptionCanvas(
            setupDraft: self.$setupDraft,
            state: state,
            applications: self.applications,
            microphones: self.microphones,
            readiness: self.readiness,
            errorMessage: self.actionErrorMessage,
            onStart: self.startRecording,
            onStop: self.stopAndTranscribe,
            onRetrySession: { self.retryProcessingSession(id: $0.id, languageCode: MeetingRetranscriptionLanguage.failedAttemptLanguage(for: $0)) },
            onRetranscribe: { self.retryProcessingSession(id: $0, languageCode: $1) },
            onRevealAudio: self.revealCapturedAudio,
            onRecordAgain: self.recordAgain,
            onCopyTranscript: self.copyTranscript,
            onExportTranscript: self.exportTranscript,
            onReassignSegment: self.reassignSegment,
            onEditTranscriptSegment: self.editTranscriptSegment,
            onNameUnknownSegment: self.nameUnknownSegment,
            onUndoCorrection: self.undoTranscriptCorrection,
            onRenameSession: self.renameMeetingSession,
            onAssignSpeakers: self.assignSpeakers,
            canUndoCorrection: { self.coordinator.canUndoCorrection(sessionID: $0) },
            isQuiescent: self.coordinator.isQuiescent && self.summaryActivity.selectionLock == nil,
            onRepairSetup: self.repairRecordingSetup,
            onEditSetup: self.openMeetingSettings,
            isRetrying: self.isRetrying,
            onCloseSelection: self.closeCanvasAction,
            onOpenIntegrations: self.openMeetingIntegrations,
            resumingSummarySessionID: self.resumingSummarySessionID
        )
    }

    private var canvasState: MeetingTranscriptionCanvasState {
        if let selectedMeeting, self.isCaptureIdle {
            switch selectedMeeting.state {
            case .failed:
                let message = selectedMeeting.failures.last?.message ?? "This meeting failed."
                return .failed(session: selectedMeeting, message: message)
            case .interrupted:
                let message = selectedMeeting.endedAt != nil && !selectedMeeting.processingAttempts.isEmpty
                    ? "Transcription was interrupted. Captured audio is ready to retry."
                    : "Recording was interrupted. Captured audio has been preserved on this Mac."
                return .failed(session: selectedMeeting, message: message)
            default:
                return .result(selectedMeeting)
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

    private var selectedMeeting: MeetingSession? {
        guard let id = self.route.meetingID else { return nil }
        return self.historySnapshot.sessions.first(where: { $0.id == id })
    }

    private var closeCanvasAction: (() -> Void)? {
        guard self.summaryActivity.selectionLock == nil, self.isCaptureIdle else { return nil }
        return self.goHome
    }

    private var isCaptureIdle: Bool {
        switch self.coordinator.state {
        case .idle, .completed, .interrupted, .failed:
            return true
        case .preparing, .recording, .recordingDegraded, .stopping, .processing:
            return false
        }
    }

    private var effectiveCaptureMode: MeetingCaptureMode {
        self.setupDraft.mode
    }

    private var readiness: MeetingSetupReadiness {
        let microphoneStatus = self.cachedMicrophoneStatus
        let microphoneReady = microphoneStatus == .authorized
        let meetingAudioReady = self.setupDraft.mode == .inRoom || self.cachedScreenCaptureAccess
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
            showScreenRecordingSettingsAction: self.setupDraft.mode.capturesComputerAudio && !self.cachedScreenCaptureAccess,
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
    private func refreshPageData() async {
        if let lastRefresh = self.lastSourceRefresh {
            guard Date().timeIntervalSince(lastRefresh) >= 30 else { return }
            // The cached setup is on screen, so the check can wait for the page to settle.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
        } else {
            self.pendingSourceChoiceRefresh = true
            self.applyPendingSourceChoiceRefresh()
        }
        self.lastSourceRefresh = Date()
        async let sources: Void = self.refreshSources(requestPermissions: false)
        await self.loadMeetingHistory()
        await sources
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
            self.cachedSystemDefaultMicrophoneUID = snapshot.defaultCoreAudioUID
            self.microphones = identities.map(MeetingMicrophoneOption.init)
            self.selectPreferredMicrophone(from: identities, systemDefaultUID: snapshot.defaultCoreAudioUID)
        } else {
            self.microphones = []
            self.setupDraft.selectedMicrophoneID = nil
        }

        guard self.setupDraft.mode.capturesComputerAudio else { return }

        if requestPermissions, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        guard CGPreflightScreenCaptureAccess() else {
            self.applications = []
            self.setupDraft.selectedApplicationID = nil
            return
        }

        do {
            let identities = try await MeetingRecordingSourceResolver.applicationChoices(from: MeetingCaptureSourceCatalog.availableApplications())
            let icons = await MeetingApplicationIcon.snapshot(bundleIdentifiers: identities.map(\.bundleIdentifier))
            self.applications = identities.map { MeetingApplicationOption(identity: $0, icon: icons[$0.bundleIdentifier]) }
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
        let options = identities.map { MeetingApplicationOption(identity: $0) }
        if self.setupDraft.usesAutomaticApplication {
            self.setupDraft.selectedApplicationID = nil
            return
        }
        if let selectedID = setupDraft.selectedApplicationID,
           options.contains(where: { $0.id == selectedID })
        {
            return
        }

        if let lastPicked = SettingsStore.shared.meetingRecentApplication,
           lastPicked.bundleIdentifier == self.setupDraft.preferredApplicationBundleIdentifier,
           let exact = options.first(where: {
               $0.identity.bundleIdentifier == lastPicked.bundleIdentifier && $0.identity.processID == lastPicked.processID && ($0.identity.processID ?? 0) > 0
           })
        {
            self.setupDraft.selectedApplicationID = exact.id
            return
        }
        let matches = options.filter { $0.identity.bundleIdentifier == self.setupDraft.preferredApplicationBundleIdentifier }
        self.setupDraft.selectedApplicationID = matches.count == 1 ? matches.first?.id : nil
    }

    private func startRecording() {
        guard !self.isStarting else { return }
        if self.setupDraft.mode == .onlineCall, self.setupDraft.selectedApplicationID == nil {
            MeetingRecordingSourcePromptController.shared.handleShortcut(microphoneID: self.setupDraft.selectedMicrophoneID)
            return
        }
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

        let selected = self.applications.first(where: { $0.id == self.setupDraft.selectedApplicationID })?.identity
        guard self.setupDraft.mode != .onlineCall || selected != nil else { return nil }
        let source: MeetingRecordingSource = self.setupDraft.usesAutomaticApplication ? .automatic : selected.map(MeetingRecordingSource.init(application:)) ?? .automatic
        let application: MeetingApplicationIdentity?
        do {
            application = try MeetingRecordingSourceResolver.resolve(
                mode: self.setupDraft.mode,
                source: source,
                target: self.appServices.meetingAutomaticTarget,
                applications: self.applications.map(\.identity)
            )
        } catch {
            return nil
        }

        return MeetingCaptureConfiguration(
            mode: self.setupDraft.mode,
            title: title,
            languageCode: self.setupDraft.languageCode,
            platform: application.map {
                MeetingPlatformProfile(identifier: $0.bundleIdentifier, displayName: $0.displayName)
            },
            application: application,
            microphone: microphone,
            timestampDefaultTitle: !self.setupDraft.titleWasEdited
        )
    }

    private func stopAndTranscribe() {
        guard !self.isStopping else { return }
        self.isStopping = true
        self.actionErrorMessage = nil
        // Stop is an explicit "show me my meeting" — an open meeting must not hijack the outcome.
        self.route = .home
        Task {
            defer { self.isStopping = false }
            do {
                _ = try await self.coordinator.stopAndTranscribe()
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func retryProcessingSession(id: MeetingSessionID, languageCode: String? = nil) {
        guard !self.isRetrying, self.summaryActivity.selectionLock == nil else { return }
        self.isRetrying = true
        self.actionErrorMessage = nil
        self.route = .home
        Task {
            defer { self.isRetrying = false }
            do {
                _ = try await self.coordinator.retryProcessing(sessionID: id, languageCode: languageCode)
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
                let saved = try await self.coordinator.reassignSegment(sessionID: sessionID, segmentID: segmentID, to: speakerID)
                self.historySnapshot.applySavedSession(saved)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
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
                let saved = try await self.coordinator.nameUnknownSegment(
                    sessionID: sessionID,
                    segmentID: segmentID,
                    displayName: displayName
                )
                self.historySnapshot.applySavedSession(saved)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func editTranscriptSegment(sessionID: MeetingSessionID, segmentID: MeetingTranscriptSegmentID, text: String, revision: Int) async -> String? {
        do {
            let saved = try await self.coordinator.editTranscriptText(sessionID: sessionID, segmentID: segmentID, text: text, expectedRevision: revision)
            self.historySnapshot.applySavedSession(saved)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func assignSpeakers(sessionID: MeetingSessionID, edits: MeetingSpeakerEdits) async -> String? {
        self.actionErrorMessage = nil
        var errorMessage: String?
        do {
            let saved = try await self.coordinator.editSpeakers(sessionID: sessionID, edits: edits)
            self.historySnapshot.applySavedSession(saved)
        } catch {
            errorMessage = error.localizedDescription
        }
        return errorMessage
    }

    private func renameMeetingSession(sessionID: MeetingSessionID, to title: String) {
        self.actionErrorMessage = nil
        Task {
            do {
                let saved = try await self.coordinator.renameSession(sessionID: sessionID, to: title)
                self.historySnapshot.applySavedSession(saved)
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func undoTranscriptCorrection(sessionID: MeetingSessionID) async -> Bool {
        self.actionErrorMessage = nil
        do {
            let saved = try await self.coordinator.undoTranscriptCorrection(sessionID: sessionID)
            self.historySnapshot.applySavedSession(saved)
        } catch {
            self.actionErrorMessage = error.localizedDescription
        }
        return self.coordinator.canUndoCorrection(sessionID: sessionID)
    }

    private func deleteSession(id: MeetingSessionID) {
        guard self.summaryActivity.selectionLock == nil else { return }
        self.pendingDeleteSessionID = nil
        self.actionErrorMessage = nil
        Task {
            do {
                try await self.coordinator.deleteSession(id: id)
                if self.route == .meeting(id) { self.route = .home }
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
            await self.loadMeetingHistory()
        }
    }

    private func deleteAudio(id: MeetingSessionID) {
        guard self.summaryActivity.selectionLock == nil else { return }
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
        guard self.summaryActivity.selectionLock == nil else { return }
        guard let configuration = self.recordAgainConfiguration(from: session) else { return }
        self.actionErrorMessage = nil
        Task {
            do {
                _ = try await self.coordinator.recordAgain(from: session.id, configuration: configuration)
                self.route = .home
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
            mode: session.mode == .inRoom ? .systemAudio : session.mode,
            title: session.defaultTitleBase ?? session.title,
            languageCode: session.languageCode,
            platform: session.platform,
            application: application,
            microphone: microphone,
            timestampDefaultTitle: session.defaultTitleBase != nil
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

    private func openMeeting(_ id: MeetingSessionID) {
        guard self.isCaptureIdle, self.summaryActivity.selectionLock == nil else { return }
        self.actionErrorMessage = nil
        self.route = .meeting(id)
    }

    private func openRecordingView() {
        guard self.isCaptureIdle, self.startNewMeeting() else { return }
        self.route = .newRecording
    }

    /// Leaving an open meeting must not resolve a recovery offer waiting underneath it.
    private func goHome() {
        guard self.summaryActivity.selectionLock == nil else { return }
        if self.route.meetingID != nil {
            self.actionErrorMessage = nil
            self.route = .home
        } else if self.startNewMeeting() {
            self.route = .home
        }
    }

    private func startNewMeeting() -> Bool {
        guard self.summaryActivity.selectionLock == nil else { return false }
        do {
            try self.coordinator.resetForNewMeeting()
            self.selectPreferredApplication(from: self.applications.map(\.identity))
            self.resetDraftTitleToDefault()
            self.actionErrorMessage = nil
            return true
        } catch {
            self.actionErrorMessage = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func loadMeetingHistory() async {
        await self.historySnapshot.refresh()
        guard self.historySnapshot.errorMessage == nil else { return }
        if let id = self.route.meetingID, !self.historySnapshot.sessions.contains(where: { $0.id == id }) {
            self.route = .home
        }
    }

    // Restore updates future setup only; a running meeting and an open editing sheet
    // keep their draft until the existing activity/dismissal events reach a safe point.
    private var canRefreshSetupAfterBackupRestore: Bool {
        self.coordinator.isQuiescent && !self.isStarting && !self.isStopping &&
            !self.isRetrying && !self.isRefreshingSources && !self.isShowingMeetingSettings
    }

    // Refresh only the future app choice. An open sheet or active capture keeps
    // its current input until it closes; rapid changes coalesce to the latest choice.
    private func applyPendingSourceChoiceRefresh() {
        guard self.pendingSourceChoiceRefresh, self.canRefreshSetupAfterBackupRestore else { return }
        self.pendingSourceChoiceRefresh = false
        let settings = SettingsStore.shared
        let defaults = settings.meetingRecordingDefaults.preferringLastPickedApplication(settings.meetingRecentApplication)
        self.setupDraft.mode = defaults.mode
        self.setupDraft.usesAutomaticApplication = !defaults.isConfigured || defaults.applicationBundleIdentifier == nil
        self.setupDraft.preferredApplicationBundleIdentifier = defaults.isConfigured ? defaults.applicationBundleIdentifier : nil
        self.setupDraft.selectedApplicationID = nil
        self.selectPreferredApplication(from: self.applications.map(\.identity))
        self.regenerateDefaultTitleIfNeeded()
    }

    private func applyPendingBackupSetupRefresh() {
        guard self.pendingBackupSetupRefresh, self.canRefreshSetupAfterBackupRestore else { return }
        self.pendingBackupSetupRefresh = false
        var restoredDraft = MeetingTranscriptionSetupDraft(settings: .shared)
        if self.setupDraft.titleWasEdited {
            restoredDraft.title = self.setupDraft.title
            restoredDraft.titleWasEdited = true
        }
        self.setupDraft = restoredDraft
        self.selectPreferredMicrophone(
            from: self.microphones.map(\.identity),
            systemDefaultUID: self.cachedSystemDefaultMicrophoneUID
        )
        self.selectPreferredApplication(from: self.applications.map(\.identity))
        self.regenerateDefaultTitleIfNeeded()
        self.setupDraftBeforeEditing = self.setupDraft
        self.draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
    }

    private func finishRestoredMeetingSettingsIfPending() -> Bool {
        guard self.pendingBackupSetupRefresh else { return false }
        // A backup imported in another window supersedes this older sheet. Closing
        // it must not write its stale language/mode over the restored preferences.
        self.isShowingMeetingSettings = false
        self.applyPendingBackupSetupRefresh()
        return true
    }

    /// Opens FluidMeet settings on the Integrations tab, from a meeting's More menu.
    private func openMeetingIntegrations() {
        self.openMeetingSettings(section: .integrations)
    }

    private func openMeetingSettings() {
        self.openMeetingSettings(section: .recording)
    }

    private func openMeetingSettings(section: MeetingSettingsSection) {
        self.meetingSettingsInitialSection = section
        self.setupDraft.autoDetectEnabled = SettingsStore.shared.meetingAutoDetectEnabled
        self.setupDraft.browserDetectionEnabled = SettingsStore.shared.meetingAutoDetectBrowserEnabled
        self.setupDraft.applicationSelectionWasEdited = false
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
        if self.finishRestoredMeetingSettingsIfPending() { return }
        self.setupDraft = self.setupDraftBeforeEditing
        self.draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
        self.isShowingMeetingSettings = false
        Task { await self.refreshSources(requestPermissions: false) }
    }

    private func saveMeetingSettings() {
        if self.finishRestoredMeetingSettingsIfPending() { return }
        guard let microphone = self.microphones.first(where: { $0.id == self.setupDraft.selectedMicrophoneID }) else {
            self.actionErrorMessage = "Choose an available microphone before saving."
            return
        }

        // Save only the explicitly chosen app; automatic suggestions stay temporary.
        let settings = SettingsStore.shared
        let application = self.applications.first(where: { $0.id == self.setupDraft.selectedApplicationID })
        if self.setupDraft.applicationSelectionWasEdited,
           self.setupDraft.mode == .onlineCall, !self.setupDraft.usesAutomaticApplication, application == nil
        {
            self.actionErrorMessage = "Choose an available audio source or Automatic before saving."
            return
        }

        // A source chosen elsewhere while this sheet is open wins unless this sheet edited it.
        var defaults = settings.meetingRecordingDefaults.preferringLastPickedApplication(settings.meetingRecentApplication)
        if self.setupDraft.applicationSelectionWasEdited {
            defaults = self.setupDraft.applyingSource(to: defaults, application: application?.identity)
        }
        defaults.isConfigured = true
        defaults.microphoneCaptureDeviceID = microphone.identity.captureDeviceID
        defaults.microphoneCoreAudioUID = microphone.identity.coreAudioUID
        defaults.microphoneRole = .unknown
        defaults.languageCode = self.setupDraft.languageCode
        let recentApplication = self.setupDraft.applicationSelectionWasEdited
            ? (self.setupDraft.usesAutomaticApplication ? nil : application?.identity)
            : settings.meetingRecentApplication
        settings.saveMeetingRecordingSource(defaults, recentApplication: recentApplication)

        let previousRetentionPolicy = settings.meetingAudioRetentionPolicy
        // A detection prompt can change these preferences while this sheet is open.
        // Only save switches that were changed in this sheet.
        if self.setupDraft.autoDetectEnabled != self.setupDraftBeforeEditing.autoDetectEnabled {
            settings.meetingAutoDetectEnabled = self.setupDraft.autoDetectEnabled
        }
        if self.setupDraft.browserDetectionEnabled != self.setupDraftBeforeEditing.browserDetectionEnabled {
            settings.meetingAutoDetectBrowserEnabled = self.setupDraft.browserDetectionEnabled
        }
        settings.meetingAudioRetentionPolicy = self.draftMeetingAudioRetentionPolicy
        if previousRetentionPolicy != self.draftMeetingAudioRetentionPolicy {
            Task { await self.coordinator.sweepExpiredAudio() }
        }

        self.setupDraft.applicationSelectionWasEdited = false
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
            case .markdown: data = Data(MeetingTranscriptExporter.markdown(for: session, includeEchoes: includeEchoes).utf8)
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
        self.storageReadinessRevision += 1
        let revision = self.storageReadinessRevision
        let trackCount = MeetingPCMStoragePolicy.trackCount(for: self.effectiveCaptureMode)
        Task {
            // Volume capacity queries can block, so keep them off the main thread.
            let storage = await Task.detached(priority: .userInitiated) {
                Self.storageReadiness(trackCount: trackCount)
            }.value
            guard self.storageReadinessRevision == revision else { return }
            self.cachedStorageStatus = storage.status
            self.cachedStorageReady = storage.ready
        }
    }

    private nonisolated static func storageReadiness(trackCount: Int) -> (status: String, ready: Bool) {
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
    case markdown
    case json

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
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

/// Where the user navigated; live capture and unresolved sessions can still take over the screen.
enum MeetingRoute: Equatable {
    case home
    case newRecording
    case meeting(MeetingSessionID)

    var meetingID: MeetingSessionID? {
        if case let .meeting(id) = self { id } else { nil }
    }
}

enum MeetingScreen {
    case home
    case canvas(MeetingTranscriptionCanvasState)

    init(route: MeetingRoute, canvasState: MeetingTranscriptionCanvasState) {
        if route != .newRecording, case .setup(isStarting: false, _) = canvasState {
            self = .home
        } else {
            self = .canvas(canvasState)
        }
    }
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
    var onRetranscribe: (MeetingSessionID, String) -> Void = { _, _ in }
    let onRevealAudio: (MeetingSession) -> Void
    let onRecordAgain: (MeetingSession) -> Void
    let onCopyTranscript: (MeetingSession, Bool) -> Void
    let onExportTranscript: (MeetingSession, MeetingTranscriptExportFormat, Bool) -> Void
    let onReassignSegment: (MeetingSessionID, MeetingTranscriptSegmentID, SessionSpeakerID) -> Void
    var onEditTranscriptSegment: (MeetingSessionID, MeetingTranscriptSegmentID, String, Int) async -> String? = { _, _, _, _ in "Transcript editing is unavailable." }
    let onNameUnknownSegment: (MeetingSessionID, MeetingTranscriptSegmentID, String) -> Void
    let onUndoCorrection: (MeetingSessionID) async -> Bool
    let onRenameSession: (MeetingSessionID, String) -> Void
    let onAssignSpeakers: (MeetingSessionID, MeetingSpeakerEdits) async -> String?
    let canUndoCorrection: (MeetingSessionID) -> Bool
    let isQuiescent: Bool
    let onRepairSetup: () -> Void
    var onEditSetup: (() -> Void)? = nil
    let isRetrying: Bool
    let onCloseSelection: (() -> Void)?
    var onOpenIntegrations: (() -> Void)? = nil
    var resumingSummarySessionID: MeetingSessionID? = nil

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
                    onEditSetup: self.onEditSetup ?? self.onRepairSetup
                )
            case let .recording(session, trackHealth, liveTranscript):
                MeetingRecordingCanvas(
                    session: session,
                    trackHealth: trackHealth,
                    liveTranscript: liveTranscript,
                    isStopping: false,
                    onStop: self.onStop,
                    onRename: { self.onRenameSession(session.id, $0) },
                    errorMessage: self.errorMessage
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
                            .fluidText(.body)
                            .foregroundStyle(self.theme.look.text)
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
                        onEditTranscriptSegment: { segmentID, text, revision in
                            await self.onEditTranscriptSegment(session.id, segmentID, text, revision)
                        },
                        onNameUnknownSegment: { segmentID, name in
                            self.onNameUnknownSegment(session.id, segmentID, name)
                        },
                        onUndo: { await self.onUndoCorrection(session.id) },
                        onRenameSession: { title in self.onRenameSession(session.id, title) },
                        onRetranscribe: { languageCode in self.onRetranscribe(session.id, languageCode) },
                        onAssignSpeakers: { names in await self.onAssignSpeakers(session.id, names) },
                        onClose: self.onCloseSelection,
                        isRetranscribing: self.isRetrying,
                        onOpenIntegrations: self.onOpenIntegrations,
                        resumesSummary: session.id == self.resumingSummarySessionID
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

struct MeetingHeaderActions: Equatable {
    let showsBack: Bool
    let canGoBack: Bool
    let showsNewRecording: Bool
    let canStartRecording: Bool
    let canEditSetup: Bool

    init(screen: MeetingScreen, isQuiescent: Bool, isSummaryRunning: Bool) {
        let offersRecording: Bool
        switch screen {
        case .home:
            self.showsBack = false
            self.showsNewRecording = false
            self.canEditSetup = true
            offersRecording = true
        case .canvas(.result), .canvas(.failed):
            self.showsBack = true
            self.showsNewRecording = true
            self.canEditSetup = true
            offersRecording = true
        case let .canvas(.setup(isStarting, _)):
            self.showsBack = !isStarting
            self.showsNewRecording = false
            self.canEditSetup = !isStarting
            offersRecording = false
        case .canvas(.recording), .canvas(.stopping), .canvas(.processing):
            self.showsBack = false
            self.showsNewRecording = false
            self.canEditSetup = false
            offersRecording = false
        }
        self.canGoBack = !isSummaryRunning
        self.canStartRecording = offersRecording && isQuiescent && !isSummaryRunning
    }
}

private struct MeetingTranscriptionHeader: View {
    let actions: MeetingHeaderActions
    let onBack: () -> Void
    let onNewRecording: () -> Void
    let onOpenMeetingSettings: () -> Void
    @Environment(\.fluidPageToolbarVisible) private var isPageVisible

    var body: some View {
        FluidGlassControlGroup {
            HStack(spacing: 12) {
                if self.actions.showsBack {
                    Button(action: self.onBack) {
                        Label("Meetings", systemImage: "chevron.left")
                    }
                    .fluidGlassAction()
                    .disabled(!self.actions.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .help(self.actions.canGoBack ? "Back to your meetings" : "Finish or cancel the summary before returning to your meetings")
                    .accessibilityHint("Return to the meeting list; the current meeting stays saved")
                }
                Spacer(minLength: 8)
                if self.actions.showsNewRecording {
                    MeetingHeaderIconButton(
                        systemImage: "plus",
                        label: "New recording",
                        action: self.onNewRecording
                    )
                    .disabled(!self.actions.canStartRecording)
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityHint("Open the recording view to start a new meeting")
                }

                MeetingHeaderIconButton(
                    systemImage: "gearshape",
                    label: "FluidMeet settings",
                    action: self.onOpenMeetingSettings
                )
                .disabled(!self.actions.canEditSetup)
                .accessibilityHint("Change the saved recording application, microphone, and meeting defaults")
            }
        }
        .disabled(!self.isPageVisible)
    }
}

private struct MeetingHeaderIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    var body: some View {
        Button(action: self.action) {
            Label(self.label, systemImage: self.systemImage)
                .foregroundStyle(self.theme.palette.primaryText)
        }
        .labelStyle(.iconOnly)
        .fluidGlassAction(circular: true, quiet: true)
        // An open panel keeps a quiet fill behind its toggle instead of a colored icon.
        .background {
            if self.isSelected {
                Circle().fill(self.theme.look.highlightFill).allowsHitTesting(false)
            }
        }
        .help(self.label)
        .accessibilityLabel(self.label)
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

    @Environment(\.theme) private var theme

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
        if self.draft.mode == .systemAudio { return "Record your computer and mic." }
        if let app = resolvedApplication { return "\(app.identity.displayName) is open." }
        return self.draft.mode == .inRoom ? "In-person meeting." : "Choose an app to record."
    }

    private var planDetail: String {
        if self.draft.mode == .systemAudio { return "All computer audio and your microphone will be recorded." }
        if let app = resolvedApplication { return "\(app.identity.displayName) and your mic will be recorded." }
        if self.draft.mode == .inRoom { return "Your mic will record the room." }
        return "Choose an app, or Automatic to record all computer audio."
    }

    private var sourceLabel: String {
        if self.draft.mode == .systemAudio { return "Automatic" }
        if let app = resolvedApplication { return app.identity.displayName }
        if self.draft.mode == .inRoom { return "In person" }
        return self.draft.usesAutomaticApplication ? "Automatic" : "App unavailable"
    }

    private var meetingApplications: [MeetingApplicationOption] {
        self.applications.pickerSections.usual
    }

    private var otherApplications: [MeetingApplicationOption] {
        self.applications.pickerSections.others
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                MeetingDocumentTitle(title: "Be in the conversation.")
                Text("Record your meeting. Come back to every word.")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            self.recordingSetup
        }
    }

    private var recordingSetup: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            FluidSurfaceCard(padding: self.theme.metrics.spacing.xl) {
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
                    .foregroundStyle(self.theme.look.text)
                Text(self.planDetail)
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.secondaryText)
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
            self.sourceEntry(
                "Automatic · all computer audio + mic",
                systemImage: "desktopcomputer",
                selected: self.draft.mode == .systemAudio
            ) {
                self.draft.mode = .systemAudio
                self.draft.usesAutomaticApplication = true
                self.draft.selectedApplicationID = nil
                self.draft.preferredApplicationBundleIdentifier = nil
                self.persistSourceChoice()
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
            Text("Change · \(self.sourceLabel)")
        }
        .fluidDropdownStyle()
        .disabled(self.isStarting)
        .help("Choose what gets recorded.")
        .accessibilityLabel("Change recording source. Currently \(self.sourceLabel)")
    }

    private func applicationEntry(_ option: MeetingApplicationOption) -> some View {
        let selected = self.draft.mode == .onlineCall && !self.draft.usesAutomaticApplication && self.draft.selectedApplicationID == option.id
        return MeetingApplicationMenuEntry(title: option.identity.displayName, icon: option.icon, selected: selected) {
            self.draft.mode = .onlineCall
            self.draft.usesAutomaticApplication = false
            self.draft.selectedApplicationID = option.id
            self.draft.preferredApplicationBundleIdentifier = option.identity.bundleIdentifier
            self.persistSourceChoice()
        }
    }

    private func persistSourceChoice() {
        let application = self.draft.mode == .onlineCall && !self.draft.usesAutomaticApplication ? self.resolvedApplication?.identity : nil
        let defaults = self.draft.applyingSource(
            to: SettingsStore.shared.meetingRecordingDefaults,
            application: application
        )
        SettingsStore.shared.saveMeetingRecordingSource(defaults, recentApplication: application)
    }

    private func sourceEntry(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        MeetingApplicationMenuEntry(title: title, selected: selected, systemImage: systemImage, action: action)
    }

    private var recordingFooter: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            Label(
                self.draft.mode.capturesComputerAudio
                    ? "Source saved for future recordings. Use headphones for clearer speaker separation."
                    : "Stays on this Mac. Place it where everyone can be heard.",
                systemImage: "lock"
            )
            .fluidText(.label)
            .foregroundStyle(self.theme.look.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if let errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .fluidText(.body)
                    .foregroundStyle(self.theme.look.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Could not start recording. \(errorMessage)")
            }

            if let recentSession {
                FluidHairline()
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(self.theme.look.secondaryText)
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text("Last meeting").fluidText(.label).foregroundStyle(.secondary)
                        Text(recentSession.title).fluidText(.rowTitle).lineLimit(2)
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
            Label(self.isStarting ? "Starting…" : (self.draft.mode == .onlineCall && self.resolvedApplication == nil ? "Choose app…" : "Start recording"), systemImage: self.isStarting ? "hourglass" : "record.circle")
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
                    Circle().fill(self.theme.look.text)
                }
            }
            .frame(width: 12, height: 12)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(self.title)
                    .fluidText(.rowTitle)
                    .foregroundStyle(self.theme.look.text)
                Text(self.detail)
                    .fluidText(.label)
                    .foregroundStyle(self.theme.look.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.title). \(self.detail)")
    }
}
