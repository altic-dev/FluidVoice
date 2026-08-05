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
            onRetry: self.retryProcessing,
            onRevealAudio: self.revealCapturedAudio,
            onNewMeeting: self.startNewMeeting,
            onCopyTranscript: self.copyTranscript,
            onOpenMeetingSettings: self.openMeetingSettings,
            isRetrying: self.isRetrying
        )
        .task {
            await self.refreshSources(requestPermissions: false)
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await self.refreshSources(requestPermissions: false) }
        }
        .sheet(isPresented: self.$isShowingMeetingSettings) {
            MeetingRecordingSettingsSheet(
                draft: self.$setupDraft,
                applications: self.applications,
                microphones: self.microphones,
                readiness: self.readiness,
                isFirstSetup: !SettingsStore.shared.meetingRecordingDefaults.isConfigured,
                onRefreshSources: self.refreshSourcesFromUserAction,
                onOpenMicrophoneSettings: { Self.openMicrophoneSettings() },
                onOpenScreenRecordingSettings: { Self.openScreenRecordingSettings() },
                onOpenVoiceEngine: self.onOpenVoiceEngine,
                onCancel: self.cancelMeetingSettings,
                onSave: self.saveMeetingSettings
            )
            .interactiveDismissDisabled(!SettingsStore.shared.meetingRecordingDefaults.isConfigured)
        }
    }

    private var canvasState: MeetingTranscriptionCanvasState {
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

    private func retryProcessing() {
        guard !self.isRetrying else { return }
        self.isRetrying = true
        self.actionErrorMessage = nil
        Task {
            defer { self.isRetrying = false }
            do {
                _ = try await self.coordinator.retryProcessing()
            } catch {
                self.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func revealCapturedAudio(_ session: MeetingSession) {
        Task {
            do {
                let directory = try await MeetingSessionStore.shared.sessionDirectory(for: session.id)
                let firstAudioURL = session.audioTracks
                    .flatMap(\.chunks)
                    .first(where: { $0.finalizationState == .finalized })?
                    .fileURL(relativeTo: directory)
                NSWorkspace.shared.activateFileViewerSelecting([firstAudioURL ?? directory])
            } catch {
                self.actionErrorMessage = "Captured audio could not be revealed: \(error.localizedDescription)"
            }
        }
    }

    private func startNewMeeting() {
        do {
            try self.coordinator.resetForNewMeeting()
            self.setupDraft.title = MeetingTranscriptionSetupDraft.defaultTitle()
            self.actionErrorMessage = nil
        } catch {
            self.actionErrorMessage = error.localizedDescription
        }
    }

    private func openMeetingSettings() {
        self.setupDraftBeforeEditing = self.setupDraft
        self.isShowingMeetingSettings = true
    }

    private func cancelMeetingSettings() {
        self.setupDraft = self.setupDraftBeforeEditing
        self.isShowingMeetingSettings = false
        Task { await self.refreshSources(requestPermissions: false) }
    }

    private func saveMeetingSettings() {
        guard let microphone = self.microphones.first(where: { $0.id == self.setupDraft.selectedMicrophoneID }) else {
            self.actionErrorMessage = "Choose an available microphone before saving."
            return
        }

        let application = self.applications.first(where: { $0.id == self.setupDraft.selectedApplicationID })
        if self.setupDraft.mode == .onlineCall, application == nil {
            self.actionErrorMessage = "Choose an available meeting application before saving."
            return
        }

        let settings = SettingsStore.shared
        settings.meetingRecordingDefaults = MeetingRecordingDefaults(
            isConfigured: true,
            mode: self.setupDraft.mode,
            applicationBundleIdentifier: application?.identity.bundleIdentifier,
            microphoneCaptureDeviceID: microphone.identity.captureDeviceID,
            microphoneCoreAudioUID: microphone.identity.coreAudioUID,
            microphoneRole: self.setupDraft.microphoneRole
        )

        self.setupDraftBeforeEditing = self.setupDraft
        self.actionErrorMessage = nil
        self.isShowingMeetingSettings = false
    }

    private func copyTranscript(_ session: MeetingSession) {
        let speakerNames = Dictionary(uniqueKeysWithValues: session.speakers.map { ($0.id, $0.displayName) })
        let text = session.transcriptSegments.map { segment in
            let speaker = segment.speakerID.flatMap { speakerNames[$0] } ?? "Unknown speaker"
            return "[\(Self.timestampText(segment.start.seconds))] \(speaker): \(segment.text)"
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        NSWorkspace.shared.open(url)
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

    private static func timestampText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
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
    let onRetry: () -> Void
    let onRevealAudio: (MeetingSession) -> Void
    let onNewMeeting: () -> Void
    let onCopyTranscript: (MeetingSession) -> Void
    let onOpenMeetingSettings: () -> Void
    let isRetrying: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()

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
                            onCopyTranscript: self.onCopyTranscript
                        )
                    case let .failed(session, message):
                        MeetingFailureCanvas(
                            session: session,
                            message: self.errorMessage ?? message,
                            isRetrying: self.isRetrying,
                            onRetry: self.onRetry,
                            onRevealAudio: self.onRevealAudio
                        )
                    }
                }
                .frame(maxWidth: 820)
                .padding(self.theme.metrics.spacing.xxl)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.windowBackground)
    }

    private var header: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Image(systemName: "person.2.wave.2.fill")
                .font(self.theme.typography.titleIcon)
                .foregroundStyle(self.theme.palette.accent)

            Text("Meeting Transcription")
                .font(self.theme.typography.title)
                .foregroundStyle(self.theme.palette.primaryText)

            Spacer()

            if self.canStartNewMeeting {
                Button("New Meeting", systemImage: "plus", action: self.onNewMeeting)
                    .fluidButton(.accent, size: .small)
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityHint("Clear the current meeting and return to recording setup")
            }

            Button(action: self.onOpenMeetingSettings) {
                Label("Meeting Settings", systemImage: "gearshape")
            }
            .fluidButton(.compact, size: .small)
            .accessibilityHint("Change the saved recording application, microphone, and meeting defaults")
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

private struct MeetingRecordingSettingsSheet: View {
    @Binding var draft: MeetingTranscriptionSetupDraft

    let applications: [MeetingApplicationOption]
    let microphones: [MeetingMicrophoneOption]
    let readiness: MeetingSetupReadiness
    let isFirstSetup: Bool
    let onRefreshSources: () -> Void
    let onOpenMicrophoneSettings: @MainActor @Sendable () -> Void
    let onOpenScreenRecordingSettings: @MainActor @Sendable () -> Void
    let onOpenVoiceEngine: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    @Environment(\.theme) private var theme

    private var canSave: Bool {
        guard self.draft.selectedMicrophoneID != nil else { return false }
        return self.draft.mode == .inRoom || self.draft.selectedApplicationID != nil
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
                                    detail: "FluidVoice records audio from this application."
                                ) {
                                    Picker("Meeting audio", selection: self.$draft.selectedApplicationID) {
                                        Text("Choose application…").tag(String?.none)
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
    let onCopyTranscript: (MeetingSession) -> Void

    @Environment(\.theme) private var theme

    private var speakerNames: [SessionSpeakerID: String] {
        Dictionary(uniqueKeysWithValues: self.session.speakers.map { ($0.id, $0.displayName) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.session.title)
                    .font(self.theme.typography.title)
                Spacer()
                Text(Self.durationText(self.session.duration))
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

            if !self.session.speakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        ForEach(self.session.speakers) { speaker in
                            Label(
                                self.displayName(for: speaker),
                                systemImage: speaker.isLocalUser ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
                            )
                            .font(self.theme.typography.badge)
                            .padding(.horizontal, self.theme.metrics.spacing.md)
                            .padding(.vertical, self.theme.metrics.spacing.sm)
                            .background(self.theme.palette.contentBackground, in: Capsule())
                        }
                    }
                }
            }

            ThemedCard {
                if self.session.transcriptSegments.isEmpty {
                    ContentUnavailableView(
                        "No transcript text",
                        systemImage: "waveform.slash",
                        description: Text("The recording is preserved if you need to retry processing.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                        ForEach(self.session.transcriptSegments) { segment in
                            MeetingTranscriptSegmentRow(
                                segment: segment,
                                speakerName: segment.speakerID.flatMap { self.speakerNames[$0] } ?? "Unknown speaker"
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button("Copy Transcript", systemImage: "doc.on.doc") {
                self.onCopyTranscript(self.session)
            }
            .fluidButton(.compact, size: .medium)
            .disabled(self.session.transcriptSegments.isEmpty)
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
    let onRetry: () -> Void
    let onRevealAudio: (MeetingSession) -> Void

    @Environment(\.theme) private var theme

    private var hasRecoverableAudio: Bool {
        guard let session, session.endedAt != nil else { return false }
        return session.audioTracks
            .flatMap(\.chunks)
            .contains(where: { $0.finalizationState == .finalized && $0.byteCount > 0 })
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
                        Button(action: self.onRetry) {
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

    @Environment(\.theme) private var theme

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: self.theme.metrics.spacing.lg) {
            GridRow {
                Text(Self.timestampText(self.segment.start.seconds))
                    .font(self.theme.typography.codeCaption)
                    .foregroundStyle(self.theme.palette.tertiaryText)

                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                    Text(self.speakerName)
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.theme.palette.accent)
                    Text(self.segment.text)
                        .font(self.theme.typography.body)
                        .foregroundStyle(self.theme.palette.primaryText)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(Self.timestampText(self.segment.start.seconds)), \(self.speakerName), \(self.segment.text)"
        )
    }

    private static func timestampText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
