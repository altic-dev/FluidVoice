import AppKit
import AVFoundation
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
    var title: String = Self.defaultTitle()
    var selectedApplicationID: String?
    var selectedMicrophoneID: String?
    var microphoneRole: MeetingMicrophoneRole = .unknown

    init(settings: SettingsStore = .shared) {
        let defaults = settings.meetingRecordingDefaults
        self.mode = defaults.mode
        self.title = Self.defaultTitle()
        self.selectedApplicationID = nil
        self.selectedMicrophoneID = defaults.microphoneCaptureDeviceID
        self.microphoneRole = defaults.microphoneRole
    }

    static func defaultTitle(now: Date = Date()) -> String {
        "Meeting · \(now.formatted(date: .abbreviated, time: .shortened))"
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

struct MeetingTranscriptionView: View {
    @ObservedObject var coordinator: MeetingSessionCoordinator
    @ObservedObject var asrService: ASRService
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
    @State private var cachedStorageStatus = "Checking…"
    @State private var cachedStorageReady = false
    @State private var meetingHistory: [MeetingSession] = []
    @State private var selectedHistorySessionID: MeetingSessionID?
    @State private var meetingHistoryError: String?
    @State private var pendingDeleteSessionID: MeetingSessionID?
    @State private var pendingDeleteAudioSessionID: MeetingSessionID?
    @State private var draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
    @AppStorage("MeetingHistoryInspectorVisible") private var isMeetingHistoryVisible = true

    init(
        coordinator: MeetingSessionCoordinator,
        asrService: ASRService,
        onOpenVoiceEngine: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.asrService = asrService
        self.onOpenVoiceEngine = onOpenVoiceEngine

        let initialDraft = MeetingTranscriptionSetupDraft(settings: .shared)
        self._setupDraft = State(initialValue: initialDraft)
        self._setupDraftBeforeEditing = State(initialValue: initialDraft)
        self._isShowingMeetingSettings = State(initialValue: !SettingsStore.shared.meetingRecordingDefaults.isConfigured)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                    if willShowHistory, self.meetingHistory.isEmpty {
                        Task { await self.loadMeetingHistory() }
                    }
                }
            )

            Divider()

            HStack(spacing: 0) {
                MeetingTranscriptionCanvas(
                    setupDraft: self.$setupDraft,
                    state: self.canvasState,
                    applications: self.applications,
                    microphones: self.microphones,
                    readiness: self.readiness,
                    errorMessage: self.actionErrorMessage,
                    onRefreshSources: self.refreshSourcesFromUserAction,
                    onStart: self.startRecording,
                    onStop: self.stopAndTranscribe,
                    onRetrySession: { self.retryProcessingSession(id: $0.id) },
                    onRevealAudio: self.revealCapturedAudio,
                    onRecordAgain: self.recordAgain,
                    onCopyTranscript: self.copyTranscript,
                    onExportTranscript: self.exportTranscript,
                    onReassignSegment: self.reassignSegment,
                    onRenameSpeaker: self.renameSpeaker,
                    onMergeSpeakers: self.mergeSpeakers,
                    onUndoCorrection: self.undoTranscriptCorrection,
                    canUndoCorrection: { self.coordinator.canUndoCorrection(sessionID: $0) },
                    isQuiescent: self.coordinator.isQuiescent,
                    onOpenMeetingSettings: self.openMeetingSettings,
                    isRetrying: self.isRetrying
                )

                if self.isMeetingHistoryVisible {
                    Divider()
                    MeetingHistoryInspector(
                        sessions: self.meetingHistory,
                        selectedSessionID: self.$selectedHistorySessionID,
                        errorMessage: self.meetingHistoryError,
                        isQuiescent: self.coordinator.isQuiescent,
                        onRefresh: { Task { await self.loadMeetingHistory() } },
                        onRetry: { self.retryProcessingSession(id: $0) },
                        onRevealAudio: self.revealCapturedAudio,
                        onExportAudio: self.exportAudio,
                        onExportTranscript: { self.exportTranscript($0, format: $1, includeEchoes: false) },
                        onDeleteAudioRequest: { self.pendingDeleteAudioSessionID = $0 },
                        onDeleteRequest: { self.pendingDeleteSessionID = $0 }
                    )
                    .frame(width: 290)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(self.theme.palette.windowBackground)
        .clipped()
        .task {
            async let sources: Void = self.refreshSources(requestPermissions: false)
            if self.isMeetingHistoryVisible {
                await self.loadMeetingHistory()
            }
            await sources
        }
        .onChange(of: self.setupDraft.mode) { _, _ in
            Task { await self.refreshSources(requestPermissions: false) }
        }
        .onChange(of: self.asrService.isAsrReady) { _, isReady in
            self.cachedModelReady = isReady || self.asrService.modelsExistOnDisk
        }
        .onChange(of: self.asrService.modelsExistOnDisk) { _, existsOnDisk in
            self.cachedModelReady = self.asrService.isAsrReady || existsOnDisk
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
                savedApplicationName: Self.savedApplicationName,
                savedApplicationBundleIdentifier: SettingsStore.shared.meetingRecordingDefaults.applicationBundleIdentifier,
                onRefreshSources: self.refreshSourcesFromUserAction,
                onOpenMicrophoneSettings: { Self.openMicrophoneSettings() },
                onOpenScreenRecordingSettings: { self.openScreenRecordingSettings() },
                onOpenVoiceEngine: self.onOpenVoiceEngine,
                onCancel: self.cancelMeetingSettings,
                onSave: self.saveMeetingSettings
            )
            .interactiveDismissDisabled(!SettingsStore.shared.meetingRecordingDefaults.isConfigured)
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
                return .stopping(session: session, trackHealth: self.coordinator.trackHealth)
            }
            return .recording(session: session, trackHealth: self.coordinator.trackHealth)
        case .stopping:
            guard let session = self.coordinator.activeSession else {
                return .failed(session: nil, message: "The meeting is stopping, but its session could not be loaded.")
            }
            return .stopping(session: session, trackHealth: self.coordinator.trackHealth)
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
        return self.meetingHistory.first(where: { $0.id == selectedHistorySessionID })
    }

    private var canBrowseMeetingHistory: Bool {
        switch self.coordinator.state {
        case .idle, .completed, .interrupted, .failed:
            return true
        case .preparing, .recording, .recordingDegraded, .stopping, .processing:
            return false
        }
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
        } else if self.setupDraft.mode == .onlineCall, !meetingAudioReady {
            blockingMessage = "Allow Screen & System Audio access, then refresh sources."
        } else if !self.cachedStorageReady {
            blockingMessage = "Free at least 512 MB of storage before recording."
        } else {
            blockingMessage = nil
        }

        return MeetingSetupReadiness(
            isCheckingSources: self.isRefreshingSources,
            meetingAudioStatus: meetingAudioReady ? "Ready" : "Access required",
            meetingAudioReady: meetingAudioReady,
            microphoneStatus: microphoneStatusText,
            microphoneReady: microphoneReady && !self.microphones.isEmpty,
            modelStatus: modelReady ? "Installed · runs after Stop" : "Will prepare after Stop",
            modelReady: modelReady,
            storageStatus: self.cachedStorageStatus,
            storageReady: self.cachedStorageReady,
            activityStatus: conflictingActivity.map { "Wait for \($0.displayName)" } ?? "Ready",
            activityReady: activityReady,
            showMicrophoneSettingsAction: microphoneStatus == .denied,
            showScreenRecordingSettingsAction: self.setupDraft.mode == .onlineCall && !meetingAudioReady,
            blockingMessage: blockingMessage
        )
    }

    private func refreshSourcesFromUserAction() {
        Task { await self.refreshSources(requestPermissions: true) }
    }

    @MainActor
    private func refreshSources(requestPermissions: Bool) async {
        guard !self.isRefreshingSources else { return }
        self.isRefreshingSources = true
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
            let identities = MeetingCaptureSourceCatalog.availableMicrophones()
            self.microphones = identities.map(MeetingMicrophoneOption.init)
            self.selectPreferredMicrophone(from: identities)
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

    private func selectPreferredMicrophone(from identities: [MeetingMicrophoneIdentity]) {
        if let selectedID = setupDraft.selectedMicrophoneID,
           identities.contains(where: { $0.captureDeviceID == selectedID })
        {
            return
        }

        let settings = SettingsStore.shared
        let defaults = settings.meetingRecordingDefaults
        let preferredCoreAudioUID = defaults.microphoneCoreAudioUID ?? settings.preferredInputDeviceUID
        let savedMicrophone = defaults.savedMicrophone(in: identities)
        if defaults.isConfigured {
            self.setupDraft.selectedMicrophoneID = savedMicrophone?.captureDeviceID
            return
        }

        let preferred = savedMicrophone ?? (try? MeetingCaptureSourceCatalog.defaultMicrophone(
            preferredCoreAudioUID: preferredCoreAudioUID
        ))
        self.setupDraft.selectedMicrophoneID = preferred?.captureDeviceID ?? identities.first?.captureDeviceID
    }

    private func selectPreferredApplication(from identities: [MeetingApplicationIdentity]) {
        let options = identities.map(MeetingApplicationOption.init)
        if let selectedID = setupDraft.selectedApplicationID,
           options.contains(where: { $0.id == selectedID })
        {
            return
        }

        let defaults = SettingsStore.shared.meetingRecordingDefaults
        if defaults.isConfigured {
            let savedIdentity = defaults.savedApplication(in: identities)
            self.setupDraft.selectedApplicationID = savedIdentity.map { MeetingApplicationOption(identity: $0).id }
            return
        }

        let preferredBundleIdentifiers = [
            "us.zoom.xos",
            "com.google.Chrome",
            "com.microsoft.teams2",
        ]
        let preferredIdentity = preferredBundleIdentifiers.lazy.compactMap { bundleIdentifier in
            identities.first(where: { $0.bundleIdentifier == bundleIdentifier })
        }.first ?? identities.first
        self.setupDraft.selectedApplicationID = preferredIdentity.map { MeetingApplicationOption(identity: $0).id }
    }

    private func startRecording() {
        guard !self.isStarting else { return }
        let readiness = self.readiness
        guard readiness.activityReady,
              readiness.storageReady,
              readiness.microphoneReady,
              self.setupDraft.mode == .inRoom || readiness.meetingAudioReady,
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
        microphone.role = self.setupDraft.mode == .onlineCall ? self.setupDraft.microphoneRole : .unknown

        let applicationOption = self.applications.first(where: { $0.id == self.setupDraft.selectedApplicationID })
        if self.setupDraft.mode == .onlineCall, applicationOption == nil { return nil }
        let application = self.setupDraft.mode == .onlineCall ? applicationOption?.identity : nil

        return MeetingCaptureConfiguration(
            mode: self.setupDraft.mode,
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
                self.setupDraft.title = MeetingTranscriptionSetupDraft.defaultTitle()
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
            identity.role = session.selectedMicrophone.role
            return identity
        }
        guard let match = self.microphones.first(where: { $0.identity.captureDeviceID == session.selectedMicrophone.captureDeviceID }) else {
            return nil
        }
        var identity = match.identity
        identity.role = session.selectedMicrophone.role
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
                let firstAudioURL = freshSession.audioTracks
                    .flatMap(\.chunks)
                    .first(where: { $0.finalizationState == .finalized && $0.byteCount > 0 })?
                    .fileURL(relativeTo: directory)
                NSWorkspace.shared.activateFileViewerSelecting([firstAudioURL ?? directory])
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
                try Self.stageExport(of: freshSession, from: sourceDirectory, into: destinationFolder)
            } catch {
                self.actionErrorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private static func stageExport(
        of session: MeetingSession,
        from sourceDirectory: URL,
        into destinationFolder: URL
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
                    try fileManager.copyItem(
                        at: sourceURL,
                        to: stagingDirectory.appendingPathComponent(fileName, isDirectory: false)
                    )
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

    private static func sanitizedExportName(_ title: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _.-")
        let sanitized = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.prefix(80))
        return sanitized.isEmpty ? "Meeting" : sanitized
    }

    private static func uniqueExportName(_ baseName: String, in folder: URL, fileManager: FileManager) -> String {
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
            self.setupDraft.title = MeetingTranscriptionSetupDraft.defaultTitle()
            self.actionErrorMessage = nil
        } catch {
            self.actionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMeetingHistory() async {
        do {
            self.meetingHistory = try await MeetingSessionStore.shared.loadAll()
            self.meetingHistoryError = nil
            if let selectedHistorySessionID,
               !self.meetingHistory.contains(where: { $0.id == selectedHistorySessionID })
            {
                self.selectedHistorySessionID = nil
            }
        } catch {
            self.meetingHistoryError = "Meeting history could not be loaded."
        }
    }

    private static var savedApplicationName: String? {
        let defaults = SettingsStore.shared.meetingRecordingDefaults
        guard defaults.isConfigured, let bundleIdentifier = defaults.applicationBundleIdentifier else { return nil }
        return defaults.applicationDisplayName ?? bundleIdentifier
    }

    private func openMeetingSettings() {
        self.setupDraftBeforeEditing = self.setupDraft
        self.draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
        self.isShowingMeetingSettings = true
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

        // A settings-only change must not require the meeting app to be running:
        // fall back to the previously saved app; recording re-validates availability anyway.
        // The fallback never applies while the saved app IS running — a nil selection then
        // means the user deliberately deselected it.
        let settings = SettingsStore.shared
        let previousDefaults = settings.meetingRecordingDefaults
        let application = self.applications.first(where: { $0.id == self.setupDraft.selectedApplicationID })
        var applicationBundleIdentifier = application?.identity.bundleIdentifier
        var applicationDisplayName = application?.identity.displayName
        if application == nil {
            let savedIsRunning = previousDefaults.applicationBundleIdentifier.map { saved in
                self.applications.contains { $0.identity.bundleIdentifier == saved }
            } ?? false
            if self.setupDraft.mode == .onlineCall,
               savedIsRunning || previousDefaults.applicationBundleIdentifier == nil
            {
                self.actionErrorMessage = "Choose an available meeting application before saving."
                return
            }
            applicationBundleIdentifier = previousDefaults.applicationBundleIdentifier
            applicationDisplayName = previousDefaults.applicationDisplayName
        }

        settings.meetingRecordingDefaults = MeetingRecordingDefaults(
            isConfigured: true,
            mode: self.setupDraft.mode,
            applicationBundleIdentifier: applicationBundleIdentifier,
            applicationDisplayName: applicationDisplayName,
            microphoneCaptureDeviceID: microphone.identity.captureDeviceID,
            microphoneCoreAudioUID: microphone.identity.coreAudioUID,
            microphoneRole: self.setupDraft.microphoneRole
        )

        let previousRetentionPolicy = settings.meetingAudioRetentionPolicy
        settings.meetingAudioRetentionPolicy = self.draftMeetingAudioRetentionPolicy
        if previousRetentionPolicy != self.draftMeetingAudioRetentionPolicy {
            Task { await self.coordinator.sweepExpiredAudio() }
        }

        self.setupDraftBeforeEditing = self.setupDraft
        self.actionErrorMessage = nil
        self.isShowingMeetingSettings = false
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
        self.cachedModelReady = self.asrService.isAsrReady ||
            self.asrService.modelsExistOnDisk ||
            SettingsStore.shared.selectedSpeechModel.isInstalled
        let storage = Self.storageReadiness()
        self.cachedStorageStatus = storage.status
        self.cachedStorageReady = storage.ready
    }

    private static func storageReadiness() -> (status: String, ready: Bool) {
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
        let requiredBytes: Int64 = 512 * 1024 * 1024
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
    case recording(session: MeetingSession, trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth])
    case stopping(session: MeetingSession, trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth])
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
    let onRefreshSources: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onRetrySession: (MeetingSession) -> Void
    let onRevealAudio: (MeetingSession) -> Void
    let onRecordAgain: (MeetingSession) -> Void
    let onCopyTranscript: (MeetingSession, Bool) -> Void
    let onExportTranscript: (MeetingSession, MeetingTranscriptExportFormat, Bool) -> Void
    let onReassignSegment: (MeetingSessionID, MeetingTranscriptSegmentID, SessionSpeakerID) -> Void
    let onRenameSpeaker: (MeetingSessionID, SessionSpeakerID, String) -> Void
    let onMergeSpeakers: (MeetingSessionID, SessionSpeakerID, SessionSpeakerID) -> Void
    let onUndoCorrection: (MeetingSessionID) -> Void
    let canUndoCorrection: (MeetingSessionID) -> Bool
    let isQuiescent: Bool
    let onOpenMeetingSettings: () -> Void
    let isRetrying: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            Group {
                switch self.state {
                case let .setup(isStarting, recentSession):
                    MeetingSetupCanvas(
                        draft: self.$setupDraft,
                        applications: self.applications,
                        microphones: self.microphones,
                        readiness: self.readiness,
                        isStarting: isStarting,
                        errorMessage: self.errorMessage,
                        recentSession: recentSession,
                        onRefreshSources: self.onRefreshSources,
                        onStart: self.onStart,
                        onOpenMeetingSettings: self.onOpenMeetingSettings
                    )
                case let .recording(session, trackHealth):
                    MeetingRecordingCanvas(
                        session: session,
                        trackHealth: trackHealth,
                        isStopping: false,
                        onStop: self.onStop
                    )
                case let .stopping(session, trackHealth):
                    MeetingRecordingCanvas(
                        session: session,
                        trackHealth: trackHealth,
                        isStopping: true,
                        onStop: self.onStop
                    )
                case let .processing(session, stage):
                    MeetingProcessingCanvas(session: session, stage: stage)
                case let .result(session):
                    MeetingResultCanvas(
                        session: session,
                        isQuiescent: self.isQuiescent,
                        canUndo: self.canUndoCorrection(session.id),
                        onCopyTranscript: self.onCopyTranscript,
                        onExportTranscript: self.onExportTranscript,
                        onReassignSegment: { segmentID, speakerID in
                            self.onReassignSegment(session.id, segmentID, speakerID)
                        },
                        onRenameSpeaker: { speakerID, name in
                            self.onRenameSpeaker(session.id, speakerID, name)
                        },
                        onMergeSpeakers: { source, target in
                            self.onMergeSpeakers(session.id, source, target)
                        },
                        onUndo: { self.onUndoCorrection(session.id) }
                    )
                case let .failed(session, message):
                    MeetingFailureCanvas(
                        session: session,
                        message: self.errorMessage ?? message,
                        isRetrying: self.isRetrying,
                        onRetrySession: self.onRetrySession,
                        onRevealAudio: self.onRevealAudio,
                        onRecordAgain: self.onRecordAgain
                    )
                }
            }
            .frame(maxWidth: 820)
            .padding(self.theme.metrics.spacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.windowBackground)
    }
}

private struct MeetingTranscriptionHeader: View {
    let state: MeetingTranscriptionCanvasState
    let isMeetingHistoryVisible: Bool
    let onNewMeeting: () -> Void
    let onOpenMeetingSettings: () -> Void
    let onToggleMeetingHistory: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Image(systemName: "person.2.wave.2.fill")
                .font(self.theme.typography.titleIcon)
                .foregroundStyle(self.theme.palette.accent)

            Text("Meeting Transcription")
                .font(self.theme.typography.title)
                .foregroundStyle(self.theme.palette.primaryText)

            Spacer()

            HStack(spacing: self.theme.metrics.spacing.xs) {
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
                    label: "Meeting Settings",
                    action: self.onOpenMeetingSettings
                )
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
        .padding(.horizontal, self.theme.metrics.spacing.xxl)
        .padding(.vertical, self.theme.metrics.spacing.lg)
    }

    private var canStartNewMeeting: Bool {
        switch self.state {
        case .result, .failed:
            return true
        case .setup, .recording, .stopping, .processing:
            return false
        }
    }
}

private struct MeetingHeaderIconButton: View {
    let systemImage: String
    let label: String
    var isSelected = false
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            Image(systemName: self.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(self.isSelected ? self.theme.palette.accent : self.theme.palette.primaryText)
                .frame(width: 32, height: 30)
                .background(self.backgroundColor, in: RoundedRectangle(
                    cornerRadius: self.theme.metrics.corners.md,
                    style: .continuous
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .stroke(self.theme.palette.separator.opacity(0.55), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous))
        .onHover { self.isHovered = $0 }
        .help(self.label)
        .accessibilityLabel(self.label)
    }

    private var backgroundColor: Color {
        if self.isSelected {
            return self.theme.palette.accent.opacity(0.14)
        }
        if self.isHovered {
            return self.theme.palette.contentBackground.opacity(0.9)
        }
        return self.theme.palette.contentBackground.opacity(0.55)
    }
}

private struct MeetingHistoryInspector: View {
    let sessions: [MeetingSession]
    @Binding var selectedSessionID: MeetingSessionID?
    let errorMessage: String?
    let isQuiescent: Bool
    let onRefresh: () -> Void
    let onRetry: (MeetingSessionID) -> Void
    let onRevealAudio: (MeetingSession) -> Void
    let onExportAudio: (MeetingSession) -> Void
    let onExportTranscript: (MeetingSession, MeetingTranscriptExportFormat) -> Void
    let onDeleteAudioRequest: (MeetingSessionID) -> Void
    let onDeleteRequest: (MeetingSessionID) -> Void

    @Environment(\.theme) private var theme
    @State private var searchText = ""

    private var filteredSessions: [MeetingSession] {
        let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return self.sessions }
        return self.sessions.filter { session in
            session.title.localizedCaseInsensitiveContains(query) ||
                session.capturedApplication?.displayName.localizedCaseInsensitiveContains(query) == true ||
                session.activeSpeakers.contains(where: { $0.displayName.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Meetings")
                    .font(self.theme.typography.sectionTitle)
                Text("\(self.sessions.count)")
                    .font(self.theme.typography.badge)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Spacer()
                Button(action: self.onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh meeting history")
                .accessibilityLabel("Refresh meeting history")
            }
            .padding(.horizontal, self.theme.metrics.spacing.lg)
            .padding(.top, self.theme.metrics.spacing.lg)
            .padding(.bottom, self.theme.metrics.spacing.md)

            TextField("Search meetings", text: self.$searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, self.theme.metrics.spacing.lg)
                .padding(.bottom, self.theme.metrics.spacing.md)

            Divider()

            if let errorMessage {
                ContentUnavailableView(
                    "History unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if self.filteredSessions.isEmpty {
                ContentUnavailableView(
                    self.searchText.isEmpty ? "No meetings yet" : "No matching meetings",
                    systemImage: self.searchText.isEmpty ? "person.2.wave.2" : "magnifyingglass",
                    description: Text(self.searchText.isEmpty
                        ? "Completed meetings will appear here."
                        : "Try a different title, app, or speaker.")
                )
            } else {
                List(selection: self.$selectedSessionID) {
                    ForEach(self.filteredSessions) { session in
                        MeetingHistoryRow(session: session)
                            .tag(session.id)
                            .contextMenu {
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
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(self.theme.palette.sidebarBackground)
    }
}

private struct MeetingHistoryRow: View {
    let session: MeetingSession

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: self.statusIcon)
                    .foregroundStyle(self.statusColor)
                    .accessibilityHidden(true)
                Text(self.session.title)
                    .font(self.theme.typography.bodySmallStrong)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(self.session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .lineLimit(1)

            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text(Self.durationText(self.session.duration))
                Text("·")
                Text(self.sourceName)
                    .lineLimit(1)
                if !self.session.activeSpeakers.isEmpty {
                    Text("·")
                    Text("\(self.session.activeSpeakers.count) speakers")
                }
            }
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.tertiaryText)
        }
        .padding(.vertical, self.theme.metrics.spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.session.title), \(self.statusText), \(self.sourceName)")
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

    private var statusIcon: String {
        switch self.session.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "exclamationmark.circle.fill"
        case .processing: "ellipsis.circle.fill"
        case .recording, .recordingDegraded, .preparing, .stopping: "record.circle.fill"
        }
    }

    private var statusColor: Color {
        switch self.session.state {
        case .completed: self.theme.palette.success
        case .failed: Color(nsColor: .systemRed)
        case .interrupted: self.theme.palette.warning
        case .processing: self.theme.palette.accent
        case .recording, .recordingDegraded, .preparing, .stopping: self.theme.palette.warning
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

private struct MeetingRecordingSettingsSheet: View {
    @Binding var draft: MeetingTranscriptionSetupDraft
    @Binding var retentionPolicy: MeetingAudioRetentionPolicy

    let applications: [MeetingApplicationOption]
    let microphones: [MeetingMicrophoneOption]
    let readiness: MeetingSetupReadiness
    let isFirstSetup: Bool
    let savedApplicationName: String?
    let savedApplicationBundleIdentifier: String?
    let onRefreshSources: () -> Void
    let onOpenMicrophoneSettings: @MainActor @Sendable () -> Void
    let onOpenScreenRecordingSettings: @MainActor @Sendable () -> Void
    let onOpenVoiceEngine: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    @Environment(\.theme) private var theme

    private var savedApplicationIsRunning: Bool {
        guard let savedApplicationBundleIdentifier else { return false }
        return self.applications.contains { $0.identity.bundleIdentifier == savedApplicationBundleIdentifier }
    }

    private var usesSavedApplicationFallback: Bool {
        self.draft.mode == .onlineCall
            && self.draft.selectedApplicationID == nil
            && self.savedApplicationName != nil
            && !self.savedApplicationIsRunning
    }

    private var canSave: Bool {
        guard self.draft.selectedMicrophoneID != nil else { return false }
        return self.draft.mode == .inRoom
            || self.draft.selectedApplicationID != nil
            || self.usesSavedApplicationFallback
    }

    private var separationDescription: String {
        if !CPUArchitecture.isAppleSilicon {
            return "Plain transcript on Intel"
        }
        return self.readiness.modelReady ? "Automatic after Stop" : "Prepares after Stop"
    }

    private var saveHelp: String? {
        guard !self.canSave else { return nil }
        if let blockingMessage = readiness.blockingMessage {
            return blockingMessage
        }
        if self.draft.selectedMicrophoneID == nil {
            return "Choose an available microphone to save this setup."
        }
        return "Choose an available meeting application to save this setup."
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                Image(systemName: "gearshape.fill")
                    .font(self.theme.typography.titleIcon)
                    .foregroundStyle(self.theme.palette.accent)

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                    Text(self.isFirstSetup ? "Set up meeting recording" : "Meeting Settings")
                        .font(self.theme.typography.title)
                    Text("Saved for future meetings until you change it.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer()
            }
            .padding(.horizontal, self.theme.metrics.spacing.xl)
            .padding(.vertical, self.theme.metrics.spacing.lg)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                    ThemedCard(style: .subtle, padding: 0) {
                        VStack(spacing: 0) {
                            MeetingAdaptiveSetupRow(
                                title: "Meeting type",
                                detail: "Choose the setup you use most often."
                            ) {
                                Picker("Meeting type", selection: self.$draft.mode) {
                                    Text("Online call").tag(MeetingCaptureMode.onlineCall)
                                    Text("In-room").tag(MeetingCaptureMode.inRoom)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 320, alignment: .trailing)
                                .accessibilityLabel("Default meeting type")
                            }

                            if self.draft.mode == .onlineCall {
                                Divider()
                                MeetingAdaptiveSetupRow(
                                    title: "Meeting audio",
                                    detail: self.usesSavedApplicationFallback
                                        ? "\(self.savedApplicationName ?? "Your saved app") is saved but not running — it will be captured next time it's open."
                                        : "FluidVoice records audio from this application."
                                ) {
                                    Picker("Meeting audio", selection: self.$draft.selectedApplicationID) {
                                        Text(self.usesSavedApplicationFallback
                                            ? "\(self.savedApplicationName ?? "Saved app") (not running)"
                                            : "Choose application…").tag(String?.none)
                                        ForEach(self.applications) { option in
                                            Text(option.identity.displayName).tag(Optional(option.id))
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 320, alignment: .trailing)
                                    .accessibilityLabel("Default meeting application")
                                }
                            }

                            Divider()
                            MeetingAdaptiveSetupRow(
                                title: "Microphone",
                                detail: "Used for your voice and in-room meetings."
                            ) {
                                Picker("Microphone", selection: self.$draft.selectedMicrophoneID) {
                                    Text("Choose microphone…").tag(String?.none)
                                    ForEach(self.microphones) { option in
                                        Text(option.identity.displayName).tag(Optional(option.id))
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 320, alignment: .trailing)
                                .accessibilityLabel("Default meeting microphone")
                            }

                            if self.draft.mode == .onlineCall {
                                Divider()
                                MeetingAdaptiveSetupRow(
                                    title: "Microphone use",
                                    detail: "A personal mic can identify clean speech as You."
                                ) {
                                    Picker("Microphone use", selection: self.$draft.microphoneRole) {
                                        Text("Only me").tag(MeetingMicrophoneRole.personal)
                                        Text("Shared").tag(MeetingMicrophoneRole.shared)
                                        Text("Not sure").tag(MeetingMicrophoneRole.unknown)
                                    }
                                    .labelsHidden()
                                    .frame(width: 320, alignment: .trailing)
                                    .accessibilityLabel("Default microphone use")
                                }
                            }

                            Divider()
                            MeetingAdaptiveSetupRow(title: "Language") {
                                Text("English")
                                    .font(self.theme.typography.bodyStrong)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Divider()
                            MeetingAdaptiveSetupRow(title: "Speaker separation") {
                                Text(self.separationDescription)
                                    .font(self.theme.typography.bodyStrong)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Divider()
                            MeetingAdaptiveSetupRow(
                                title: "Keep audio",
                                detail: "Applies to all recordings, including past ones. Audio is deleted only "
                                    + "while FluidVoice is running; transcripts are always kept."
                            ) {
                                Picker("Keep audio", selection: self.$retentionPolicy) {
                                    ForEach(MeetingAudioRetentionPolicy.allCases, id: \.self) { policy in
                                        Text(policy.displayName).tag(policy)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 320, alignment: .trailing)
                                .accessibilityLabel("Audio retention")
                            }
                        }
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            self.repairActions
                        }
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                            self.repairActions
                        }
                    }

                    Label("Recording and transcription stay on this Mac.", systemImage: "lock.fill")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)

                    if let saveHelp {
                        Label(saveHelp, systemImage: "exclamationmark.circle")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.warning)
                    }
                }
                .padding(self.theme.metrics.spacing.xl)
            }

            Divider()

            HStack(spacing: self.theme.metrics.spacing.md) {
                Button(self.isFirstSetup ? "Not Now" : "Cancel", action: self.onCancel)
                    .fluidButton(.compact, size: .medium)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(self.readiness.isCheckingSources ? "Refreshing…" : "Refresh Sources", systemImage: "arrow.clockwise") {
                    self.onRefreshSources()
                }
                .fluidButton(.compact, size: .medium)
                .disabled(self.readiness.isCheckingSources)

                Button(self.isFirstSetup ? "Save Setup" : "Save Changes", action: self.onSave)
                    .fluidButton(.accent, size: .medium)
                    .disabled(!self.canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(self.theme.metrics.spacing.lg)
        }
        .frame(minWidth: 560, idealWidth: 720, maxWidth: 720)
        .frame(minHeight: 540, idealHeight: 620)
        .background(self.theme.palette.windowBackground)
    }

    @ViewBuilder
    private var repairActions: some View {
        if self.readiness.showMicrophoneSettingsAction {
            Button("Microphone Settings", systemImage: "mic.fill", action: self.onOpenMicrophoneSettings)
                .fluidButton(.compact, size: .small)
        }
        if self.readiness.showScreenRecordingSettingsAction {
            Button(
                "Screen Recording Settings",
                systemImage: "rectangle.inset.filled.and.person.filled",
                action: self.onOpenScreenRecordingSettings
            )
            .fluidButton(.compact, size: .small)
        }
        if !self.readiness.modelReady {
            Button("Voice Engine", systemImage: "waveform", action: self.onOpenVoiceEngine)
                .fluidButton(.compact, size: .small)
        }
    }
}

private struct MeetingSetupCanvas: View {
    @Binding var draft: MeetingTranscriptionSetupDraft

    let applications: [MeetingApplicationOption]
    let microphones: [MeetingMicrophoneOption]
    let readiness: MeetingSetupReadiness
    let isStarting: Bool
    let errorMessage: String?
    let recentSession: MeetingSession?
    let onRefreshSources: () -> Void
    let onStart: () -> Void
    let onOpenMeetingSettings: () -> Void

    @Environment(\.theme) private var theme

    private var requiredSystemsReady: Bool {
        !self.readiness.isCheckingSources &&
            self.readiness.microphoneReady &&
            self.readiness.storageReady &&
            self.readiness.activityReady &&
            (self.draft.mode == .inRoom || self.readiness.meetingAudioReady)
    }

    private var canStart: Bool {
        guard self.requiredSystemsReady,
              self.draft.selectedMicrophoneID != nil,
              !self.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return self.draft.mode == .inRoom || self.draft.selectedApplicationID != nil
    }

    private var startHelp: String? {
        if let blockingMessage = readiness.blockingMessage, !self.requiredSystemsReady {
            return blockingMessage
        }
        if self.draft.selectedMicrophoneID == nil {
            return "Choose a microphone to continue."
        }
        if self.draft.mode == .onlineCall, self.draft.selectedApplicationID == nil {
            return "Choose the application playing meeting audio."
        }
        if self.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a title for this meeting."
        }
        return nil
    }

    private var modeName: String {
        self.draft.mode == .onlineCall ? "Online call" : "In-room meeting"
    }

    private var applicationName: String? {
        guard self.draft.mode == .onlineCall else { return nil }
        return self.applications.first(where: { $0.id == self.draft.selectedApplicationID })?.identity.displayName
    }

    private var microphoneName: String {
        self.microphones.first(where: { $0.id == self.draft.selectedMicrophoneID })?.identity.displayName
            ?? "Choose microphone"
    }

    private var microphoneRoleName: String? {
        guard self.draft.mode == .onlineCall else { return nil }
        switch self.draft.microphoneRole {
        case .personal: return "Personal mic"
        case .shared: return "Shared mic"
        case .unknown: return "Mic use not set"
        }
    }

    private var setupSummary: String {
        [self.applicationName, self.microphoneName, self.microphoneRoleName]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            ThemedCard(style: .subtle, padding: 0) {
                VStack(spacing: 0) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: self.theme.metrics.spacing.lg) {
                            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                                Text(self.modeName)
                                    .font(self.theme.typography.sectionTitle)
                                    .foregroundStyle(self.theme.palette.primaryText)
                                Text(self.setupSummary)
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.theme.palette.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: self.theme.metrics.spacing.lg)
                            Button("Edit setup…", systemImage: "slider.horizontal.3", action: self.onOpenMeetingSettings)
                                .fluidButton(.compact, size: .small)
                        }

                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                                Text(self.modeName)
                                    .font(self.theme.typography.sectionTitle)
                                Text(self.setupSummary)
                                    .font(self.theme.typography.bodySmall)
                                    .foregroundStyle(self.theme.palette.secondaryText)
                            }
                            Button("Edit setup…", systemImage: "slider.horizontal.3", action: self.onOpenMeetingSettings)
                                .fluidButton(.compact, size: .small)
                        }
                    }
                    .padding(.horizontal, self.theme.metrics.spacing.lg)
                    .padding(.vertical, self.theme.metrics.spacing.md)
                    .accessibilityElement(children: .contain)

                    Divider()

                    MeetingAdaptiveSetupRow(title: "Meeting title") {
                        TextField("Meeting title", text: self.$draft.title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Meeting title")
                    }

                    Divider()

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: self.theme.metrics.spacing.md) {
                            MeetingReadyStatus(
                                isReady: self.canStart,
                                title: self.canStart ? "Ready to record" : "Setup needs attention",
                                detail: self.canStart
                                    ? "English · \(self.readiness.storageStatus)"
                                    : (self.startHelp ?? "Check the recording setup.")
                            )
                            Spacer(minLength: self.theme.metrics.spacing.md)
                            Button("Refresh", systemImage: "arrow.clockwise", action: self.onRefreshSources)
                                .fluidButton(.compact, size: .small)
                                .disabled(self.readiness.isCheckingSources || self.isStarting)
                        }

                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                            MeetingReadyStatus(
                                isReady: self.canStart,
                                title: self.canStart ? "Ready to record" : "Setup needs attention",
                                detail: self.canStart
                                    ? "English · \(self.readiness.storageStatus)"
                                    : (self.startHelp ?? "Check the recording setup.")
                            )
                            Button("Refresh", systemImage: "arrow.clockwise", action: self.onRefreshSources)
                                .fluidButton(.compact, size: .small)
                                .disabled(self.readiness.isCheckingSources || self.isStarting)
                        }
                    }
                    .padding(.horizontal, self.theme.metrics.spacing.lg)
                    .padding(.vertical, self.theme.metrics.spacing.md)
                }
            }

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                Label("Recording and transcription stay on this Mac.", systemImage: "lock.fill")
                Label(
                    self.draft.mode == .onlineCall
                        ? "Headphones give the cleanest speaker separation."
                        : "Place the Mac where every speaker can be heard clearly.",
                    systemImage: self.draft.mode == .onlineCall ? "headphones" : "mic.fill"
                )
                Label("Make sure everyone knows the meeting is being recorded.", systemImage: "person.2")
            }
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)

            if let errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .accessibilityLabel("Could not start recording. \(errorMessage)")
            }

            HStack {
                Spacer()
                Button(action: self.onStart) {
                    if self.isStarting {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Starting…")
                        }
                    } else {
                        Label("Start recording", systemImage: "record.circle")
                    }
                }
                .fluidButton(.accent, size: .medium)
                .disabled(!self.canStart || self.isStarting)
                .keyboardShortcut(.defaultAction)
            }

            if let recentSession {
                Divider()
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    Text("Recent meeting")
                        .font(self.theme.typography.sectionTitle)

                    HStack {
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                            Text(recentSession.title)
                                .font(self.theme.typography.bodyStrong)
                            Text(recentSession.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                        Spacer()
                        Text(Self.durationText(recentSession.duration))
                            .font(self.theme.typography.codeCaption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                    }
                    .padding(self.theme.metrics.spacing.md)
                    .background(self.theme.palette.contentBackground, in: RoundedRectangle(
                        cornerRadius: self.theme.metrics.corners.md,
                        style: .continuous
                    ))
                }
            }
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct MeetingRecordingCanvas: View {
    let session: MeetingSession
    let trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth]
    let isStopping: Bool
    let onStop: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    Label(
                        self.isStopping ? "Stopping…" : "Recording",
                        systemImage: self.isStopping ? "stop.circle.fill" : "record.circle.fill"
                    )
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.isStopping ? self.theme.palette.warning : Color(nsColor: .systemRed))

                    Text(Self.durationText(context.date.timeIntervalSince(self.session.startedAt)))
                        .font(self.theme.typography.codeCaption)
                        .foregroundStyle(self.theme.palette.primaryText)

                    Spacer()

                    Text(self.sourceSummary)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(self.isStopping ? "Meeting recording is stopping" : "Meeting recording in progress"), " +
                        "\(Self.durationText(context.date.timeIntervalSince(self.session.startedAt))) elapsed, " +
                        self.sourceSummary
                )
            }

            ThemedCard(style: .prominent) {
                VStack(spacing: self.theme.metrics.spacing.lg) {
                    if self.session.mode == .onlineCall {
                        MeetingTrackHealthRow(
                            title: "Meeting audio",
                            health: self.trackHealth[.applicationAudio] ?? .waiting
                        )
                    }
                    MeetingTrackHealthRow(
                        title: "Microphone",
                        health: self.trackHealth[.microphone] ?? .waiting
                    )
                }
            }

            Text(
                self.isStopping
                    ? "Saving captured audio before offline transcription begins…"
                    : "When the meeting ends, stop recording to transcribe it offline."
            )
            .font(self.theme.typography.body)
            .foregroundStyle(self.theme.palette.secondaryText)

            HStack {
                Spacer()

                Button(action: self.onStop) {
                    if self.isStopping {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Stopping…")
                        }
                    } else {
                        Label("Stop & Transcribe", systemImage: "stop.fill")
                    }
                }
                .fluidButton(.destructive, size: .medium)
                .disabled(self.isStopping)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var sourceSummary: String {
        let microphoneName = self.session.selectedMicrophone.displayName
        guard self.session.mode == .onlineCall else { return microphoneName }
        let applicationName = self.session.capturedApplication?.displayName ?? "Meeting audio"
        return "\(applicationName) · \(microphoneName)"
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct MeetingProcessingCanvas: View {
    let session: MeetingSession
    let stage: MeetingProcessingStage

    @Environment(\.theme) private var theme

    private let stages: [MeetingProcessingStage] = [
        .saving,
        .identifyingSpeakers,
        .transcribing,
        .finalizing,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                ProgressView()
                    .controlSize(.regular)
                    .fixedSize()

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                    Text("Transcribing meeting…")
                        .font(self.theme.typography.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text("You can close this window. Processing will continue.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
            }

            ThemedCard {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                    ForEach(Array(self.stages.enumerated()), id: \.element) { index, stage in
                        HStack(spacing: self.theme.metrics.spacing.md) {
                            Image(systemName: self.icon(for: stage, index: index))
                                .foregroundStyle(self.color(for: stage, index: index))
                                .frame(width: 20)
                            Text(Self.title(for: stage))
                                .font(self.theme.typography.body)
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(Self.title(for: stage)), \(self.accessibilityStatus(for: stage, index: index))")
                    }
                }
            }

            Text(self.session.title)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var activeIndex: Int {
        self.stages.firstIndex(of: self.stage) ?? 0
    }

    private func icon(for stage: MeetingProcessingStage, index: Int) -> String {
        if self.stage == .completed || index < self.activeIndex { return "checkmark.circle.fill" }
        if stage == self.stage { return "circle.dotted" }
        return "circle"
    }

    private func color(for stage: MeetingProcessingStage, index: Int) -> Color {
        if self.stage == .completed || index < self.activeIndex { return self.theme.palette.success }
        if stage == self.stage { return self.theme.palette.accent }
        return self.theme.palette.tertiaryText
    }

    private func accessibilityStatus(for stage: MeetingProcessingStage, index: Int) -> String {
        if self.stage == .completed || index < self.activeIndex { return "complete" }
        if stage == self.stage { return "in progress" }
        return "waiting"
    }

    private static func title(for stage: MeetingProcessingStage) -> String {
        switch stage {
        case .pending: return "Waiting"
        case .saving: return "Saving"
        case .identifyingSpeakers: return "Identifying speakers"
        case .transcribing: return "Transcribing"
        case .finalizing: return "Finalizing"
        case .completed: return "Complete"
        }
    }
}

private struct MeetingResultCanvas: View {
    let session: MeetingSession
    let isQuiescent: Bool
    let canUndo: Bool
    @State private var showsProbableEchoes = false
    let onCopyTranscript: (MeetingSession, Bool) -> Void
    let onExportTranscript: (MeetingSession, MeetingTranscriptExportFormat, Bool) -> Void
    let onReassignSegment: (MeetingTranscriptSegmentID, SessionSpeakerID) -> Void
    let onRenameSpeaker: (SessionSpeakerID, String) -> Void
    let onMergeSpeakers: (SessionSpeakerID, SessionSpeakerID) -> Void
    let onUndo: () -> Void

    @Environment(\.theme) private var theme
    @State private var pendingRenameSpeaker: MeetingSessionSpeaker?
    @State private var pendingRenameText = ""

    private var speakerNames: [SessionSpeakerID: String] {
        Dictionary(uniqueKeysWithValues: self.session.activeSpeakers.map { ($0.id, $0.displayName) })
    }

    private var hasEchoSegments: Bool {
        self.session.transcriptSegments.contains(where: \.isEcho)
    }

    /// Single projection so shown and copied never disagree.
    private func visibleSegments(sorted: [MeetingTranscriptSegment]) -> [MeetingTranscriptSegment] {
        self.showsProbableEchoes ? sorted : sorted.filter { !$0.isEcho }
    }

    /// Sorted once with per-row display state — no per-row re-sorting.
    private func rows(
        for visibleSegments: [MeetingTranscriptSegment]
    ) -> [(segment: MeetingTranscriptSegment, showsLabel: Bool, isLocal: Bool)] {
        visibleSegments.enumerated().map { index, segment in
            let showsLabel = index == 0 || segment.speakerID != visibleSegments[index - 1].speakerID
            return (segment, showsLabel, self.isLocalSegment(segment))
        }
    }

    var body: some View {
        let speakerNames = self.speakerNames
        let sorted = self.session.transcriptSegments.sorted { $0.start.seconds < $1.start.seconds }
        let visibleSegments = self.visibleSegments(sorted: sorted)
        let visibleSpeakerIDs = Set(visibleSegments.compactMap(\.speakerID))
        let activeSpeakers = self.session.activeSpeakers.filter { visibleSpeakerIDs.contains($0.id) }
        let rows = self.rows(for: visibleSegments)
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.session.title)
                    .font(self.theme.typography.title)
                Spacer()
                if self.hasEchoSegments {
                    Toggle("Show probable echo", isOn: self.$showsProbableEchoes)
                        .toggleStyle(.checkbox)
                        .font(self.theme.typography.caption)
                }
                Label(self.statusText, systemImage: self.statusIcon)
                    .font(self.theme.typography.badge)
                    .foregroundStyle(self.statusColor)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: self.theme.metrics.spacing.lg) {
                    self.meetingMetadata
                }
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    self.meetingMetadata
                }
            }
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)

            if !activeSpeakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        ForEach(activeSpeakers) { speaker in
                            Label(
                                self.displayName(for: speaker),
                                systemImage: speaker.isLocalUser ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
                            )
                            .font(self.theme.typography.badge)
                            .padding(.horizontal, self.theme.metrics.spacing.md)
                            .padding(.vertical, self.theme.metrics.spacing.sm)
                            .background(self.theme.palette.contentBackground, in: Capsule())
                            .contextMenu { self.speakerChipMenu(for: speaker) }
                        }
                    }
                }
            }

            if visibleSegments.isEmpty {
                ContentUnavailableView(
                    "No transcript text",
                    systemImage: "waveform.slash",
                    description: Text("The recording is preserved if you need to retry processing.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(rows, id: \.segment.id) { row in
                        MeetingTranscriptSegmentRow(
                            segment: row.segment,
                            speakerName: row.segment.speakerID.flatMap { speakerNames[$0] } ?? "Unknown speaker",
                            isLocalUser: row.isLocal,
                            showsSpeakerLabel: row.showsLabel,
                            reassignTargets: activeSpeakers.filter { $0.id != row.segment.speakerID },
                            isQuiescent: self.isQuiescent,
                            onReassign: { speakerID in self.onReassignSegment(row.segment.id, speakerID) }
                        )
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.vertical, self.theme.metrics.spacing.lg)
            }

            HStack(spacing: self.theme.metrics.spacing.sm) {
                Button("Copy Transcript", systemImage: "doc.on.doc") {
                    self.onCopyTranscript(self.session, self.showsProbableEchoes)
                }
                .fluidButton(.compact, size: .medium)
                .disabled(visibleSegments.isEmpty)

                Menu("Export Transcript", systemImage: "square.and.arrow.up") {
                    Button("Text…") { self.onExportTranscript(self.session, .text, self.showsProbableEchoes) }
                    Button("JSON…") { self.onExportTranscript(self.session, .json, self.showsProbableEchoes) }
                }
                .fluidButton(.compact, size: .medium)
                .disabled(visibleSegments.isEmpty)

                Button("Undo", systemImage: "arrow.uturn.backward") {
                    self.onUndo()
                }
                .fluidButton(.compact, size: .medium)
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!self.canUndo || !self.isQuiescent)
            }
        }
        .alert(
            "Rename Speaker",
            isPresented: Binding(
                get: { self.pendingRenameSpeaker != nil },
                set: { if !$0 { self.pendingRenameSpeaker = nil } }
            )
        ) {
            TextField("Speaker name", text: self.$pendingRenameText)
            Button("Cancel", role: .cancel) { self.pendingRenameSpeaker = nil }
            Button("Rename") {
                if let speaker = self.pendingRenameSpeaker {
                    self.onRenameSpeaker(speaker.id, self.pendingRenameText)
                }
                self.pendingRenameSpeaker = nil
            }
        } message: {
            Text("Enter a new name for this speaker.")
        }
        // Prevents an echo toggle left on for one meeting from leaking into the next.
        .onChange(of: self.session.id) { _, _ in self.showsProbableEchoes = false }
    }

    @ViewBuilder
    private func speakerChipMenu(for speaker: MeetingSessionSpeaker) -> some View {
        Button("Rename…", systemImage: "pencil") {
            self.pendingRenameSpeaker = speaker
            self.pendingRenameText = speaker.displayName
        }
        .disabled(!self.isQuiescent)
        if !speaker.isLocalUser {
            let eligibleTargets = self.session.activeSpeakers.filter {
                $0.id != speaker.id && !$0.isLocalUser && $0.trackKind == speaker.trackKind
            }
            if !eligibleTargets.isEmpty {
                Menu("Merge into") {
                    ForEach(eligibleTargets) { target in
                        Button(target.displayName) {
                            self.onMergeSpeakers(speaker.id, target.id)
                        }
                    }
                }
                .disabled(!self.isQuiescent)
            }
        }
    }

    private func displayName(for speaker: MeetingSessionSpeaker) -> String {
        guard speaker.isLocalUser,
              speaker.displayName.caseInsensitiveCompare("You") != .orderedSame
        else {
            return speaker.displayName
        }
        return "\(speaker.displayName) (You)"
    }

    // The whole mic feed reads as "my side" of the chat, not just segments attributed to You.
    private func isLocalSegment(_ segment: MeetingTranscriptSegment) -> Bool {
        guard let speakerID = segment.speakerID,
              let speaker = self.session.speakers.first(where: { $0.id == speakerID })
        else { return false }
        return speaker.isLocalUser || speaker.trackKind == .microphone
    }

    @ViewBuilder
    private var meetingMetadata: some View {
        Label(
            self.session.startedAt.formatted(date: .abbreviated, time: .shortened),
            systemImage: "calendar"
        )
        Label(Self.durationText(self.session.duration), systemImage: "clock")
        Label(self.sourceName, systemImage: self.session.mode == .onlineCall ? "macwindow" : "person.3")
        Label(self.session.selectedMicrophone.displayName, systemImage: "mic")
    }

    private var sourceName: String {
        self.session.capturedApplication?.displayName ?? "In-room meeting"
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

    private var statusIcon: String {
        switch self.session.state {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "exclamationmark.circle.fill"
        case .processing: "ellipsis.circle.fill"
        case .recording, .recordingDegraded, .preparing, .stopping: "record.circle.fill"
        }
    }

    private var statusColor: Color {
        switch self.session.state {
        case .completed: self.theme.palette.success
        case .failed: Color(nsColor: .systemRed)
        case .interrupted: self.theme.palette.warning
        case .processing: self.theme.palette.accent
        case .recording, .recordingDegraded, .preparing, .stopping: self.theme.palette.warning
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct MeetingFailureCanvas: View {
    let session: MeetingSession?
    let message: String
    let isRetrying: Bool
    let onRetrySession: (MeetingSession) -> Void
    let onRevealAudio: (MeetingSession) -> Void
    let onRecordAgain: (MeetingSession) -> Void

    @Environment(\.theme) private var theme

    private var hasRecoverableAudio: Bool {
        self.session?.hasRetryableAudio == true
    }

    private var title: String {
        guard let session else { return "Meeting setup failed" }
        let lastFailureDomain = session.failures.last?.domain
        if lastFailureDomain == .processing ||
            (session.state == .interrupted && !session.processingAttempts.isEmpty)
        {
            return session.state == .interrupted
                ? "Meeting transcription was interrupted"
                : "Meeting transcription failed"
        }
        if self.hasRecoverableAudio {
            return session.state == .interrupted
                ? "Meeting recording was interrupted"
                : "Meeting recording failed"
        }
        return "Meeting setup failed"
    }

    var body: some View {
        ThemedCard(style: .prominent) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                Label(self.title, systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.theme.palette.warning)
                    .accessibilityAddTraits(.isHeader)
                Text(self.message)
                    .font(self.theme.typography.body)
                    .textSelection(.enabled)
                if self.hasRecoverableAudio {
                    Text("The captured audio has been preserved on this Mac.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    if let session, self.hasRecoverableAudio {
                        Button("Reveal Audio", systemImage: "folder", action: { self.onRevealAudio(session) })
                            .fluidButton(.compact, size: .medium)
                        Button(action: { self.onRetrySession(session) }) {
                            if self.isRetrying {
                                HStack(spacing: self.theme.metrics.spacing.sm) {
                                    ProgressView().controlSize(.small)
                                    Text("Retrying…")
                                }
                            } else {
                                Label("Retry Transcription", systemImage: "arrow.clockwise")
                            }
                        }
                        .fluidButton(.accent, size: .medium)
                        .disabled(self.isRetrying)
                    }
                    if let session {
                        Button("Record Again", systemImage: "arrow.counterclockwise.circle") {
                            self.onRecordAgain(session)
                        }
                        .fluidButton(.compact, size: .medium)
                    }
                }
            }
        }
    }
}

private struct MeetingAdaptiveSetupRow<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let content: Content

    @Environment(\.theme) private var theme

    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: self.theme.metrics.spacing.lg) {
                self.label
                    .frame(width: 164, alignment: .leading)
                self.content
                    .frame(width: 320, alignment: .leading)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                self.label
                self.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.lg)
        .padding(.vertical, self.theme.metrics.spacing.md)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Text(self.title)
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
            if let detail {
                Text(detail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MeetingReadyStatus: View {
    let isReady: Bool
    let title: String
    let detail: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Image(systemName: self.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(self.isReady ? self.theme.palette.success : self.theme.palette.warning)
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

private struct MeetingTrackHealthRow: View {
    let title: String
    let health: MeetingTrackHealth

    @Environment(\.theme) private var theme

    private var statusText: String {
        switch self.health.status {
        case .waiting: return "Waiting for audio"
        case .healthy: return "Healthy"
        case .degraded: return self.health.detail ?? "Audio source degraded"
        case .unavailable: return self.health.detail ?? "Audio source unavailable"
        case .stopped: return "Stopped"
        }
    }

    private var isHealthy: Bool {
        self.health.status == .healthy
    }

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(self.title)
                    .font(self.theme.typography.bodyStrong)
                Text(self.statusText)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(2)
            }

            Spacer()

            ProgressView(value: min(max(Double(self.health.level), 0), 1))
                .progressViewStyle(.linear)
                .frame(width: 150)
                .accessibilityLabel("\(self.title) level")

            Label(
                self.statusText,
                systemImage: self.isHealthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(self.isHealthy ? self.theme.palette.success : self.theme.palette.warning)
            .accessibilityLabel(self.statusText)
        }
    }
}

private struct MeetingTranscriptSegmentRow: View {
    let segment: MeetingTranscriptSegment
    let speakerName: String
    let isLocalUser: Bool
    let showsSpeakerLabel: Bool
    let reassignTargets: [MeetingSessionSpeaker]
    let isQuiescent: Bool
    let onReassign: (SessionSpeakerID) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if self.isLocalUser {
                self.localBubble
            } else {
                self.remoteMessage
            }
        }
        .opacity(self.segment.isEcho ? 0.6 : 1)
        .contextMenu {
            Menu("Reassign to") {
                ForEach(self.reassignTargets) { target in
                    Button(target.displayName) {
                        self.onReassign(target.id)
                    }
                }
            }
            .disabled(!self.isQuiescent)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(MeetingTranscriptExporter.timestampText(self.segment.start.seconds)), \(self.speakerName), \(self.segment.text)"
        )
    }

    private var localBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if self.showsSpeakerLabel {
                Text("\(self.speakerName)  ·  \(MeetingTranscriptExporter.timestampText(self.segment.start.seconds))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }
            Text(self.segment.text)
                .font(.system(size: 15, design: .monospaced))
                .lineSpacing(5)
                .foregroundStyle(self.theme.palette.primaryText)
                .textSelection(.enabled)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    self.theme.palette.contentBackground,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            if self.segment.isEcho {
                Text("probable echo")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 96)
    }

    private var remoteMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.showsSpeakerLabel {
                Text("\(self.speakerName)  ·  \(MeetingTranscriptExporter.timestampText(self.segment.start.seconds))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }
            Text(self.segment.text)
                .font(.system(size: 15, design: .monospaced))
                .lineSpacing(5)
                .foregroundStyle(self.theme.palette.primaryText)
                .textSelection(.enabled)
            if self.segment.isEcho {
                Text("probable echo")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 48)
    }

}
