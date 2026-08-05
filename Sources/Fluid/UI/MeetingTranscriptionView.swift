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

    @State private var setupDraft = MeetingTranscriptionSetupDraft()
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
            onOpenMicrophoneSettings: { Self.openMicrophoneSettings() },
            onOpenScreenRecordingSettings: { Self.openScreenRecordingSettings() },
            onOpenVoiceEngine: self.onOpenVoiceEngine,
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

        let preferredCoreAudioUID = SettingsStore.shared.preferredInputDeviceUID
        let preferred = preferredCoreAudioUID.flatMap { uid in
            identities.first(where: { $0.coreAudioUID == uid })
        } ?? (try? MeetingCaptureSourceCatalog.defaultMicrophone(
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
    let onOpenMicrophoneSettings: @MainActor @Sendable () -> Void
    let onOpenScreenRecordingSettings: @MainActor @Sendable () -> Void
    let onOpenVoiceEngine: () -> Void
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
                            onOpenMicrophoneSettings: { self.onOpenMicrophoneSettings() },
                            onOpenScreenRecordingSettings: { self.onOpenScreenRecordingSettings() },
                            onOpenVoiceEngine: self.onOpenVoiceEngine
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
                            onCopyTranscript: self.onCopyTranscript,
                            onNewMeeting: self.onNewMeeting
                        )
                    case let .failed(session, message):
                        MeetingFailureCanvas(
                            session: session,
                            message: self.errorMessage ?? message,
                            isRetrying: self.isRetrying,
                            onRetry: self.onRetry,
                            onRevealAudio: self.onRevealAudio,
                            onNewMeeting: self.onNewMeeting
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

            Label("Stored on this Mac", systemImage: "lock.fill")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .accessibilityLabel("Meeting data is stored on this Mac")
        }
        .padding(.horizontal, self.theme.metrics.spacing.xxl)
        .padding(.vertical, self.theme.metrics.spacing.lg)
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
    let onOpenMicrophoneSettings: @MainActor @Sendable () -> Void
    let onOpenScreenRecordingSettings: @MainActor @Sendable () -> Void
    let onOpenVoiceEngine: () -> Void

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

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            Picker("Meeting type", selection: self.$draft.mode) {
                Text("Online call").tag(MeetingCaptureMode.onlineCall)
                Text("In-room meeting").tag(MeetingCaptureMode.inRoom)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Meeting type")

            ThemedCard {
                VStack(spacing: 0) {
                    MeetingSetupRow(title: "Title") {
                        TextField("Meeting title", text: self.$draft.title)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 340)
                    }

                    if self.draft.mode == .onlineCall {
                        Divider()
                        MeetingSetupRow(title: "Meeting audio") {
                            Picker("Meeting audio", selection: self.$draft.selectedApplicationID) {
                                Text("Choose application…").tag(String?.none)
                                ForEach(self.applications) { option in
                                    Text(option.identity.displayName).tag(Optional(option.id))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 340)
                        }
                    }

                    Divider()
                    MeetingSetupRow(title: "Microphone") {
                        Picker("Microphone", selection: self.$draft.selectedMicrophoneID) {
                            Text("Choose microphone…").tag(String?.none)
                            ForEach(self.microphones) { option in
                                Text(option.identity.displayName).tag(Optional(option.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 340)
                    }

                    if self.draft.mode == .onlineCall {
                        Divider()
                        MeetingSetupRow(title: "Microphone use") {
                            Picker("Microphone use", selection: self.$draft.microphoneRole) {
                                Text("Only me").tag(MeetingMicrophoneRole.personal)
                                Text("Shared microphone").tag(MeetingMicrophoneRole.shared)
                                Text("Not sure").tag(MeetingMicrophoneRole.unknown)
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }
                    }

                    Divider()
                    MeetingSetupValueRow(title: "Language", value: "English")
                    Divider()
                    MeetingSetupValueRow(
                        title: "Speaker separation",
                        value: CPUArchitecture.isAppleSilicon ? "Automatic · prepares on first use" : "Plain transcript on Intel"
                    )
                }
            }

            ThemedCard(style: .subtle) {
                VStack(spacing: self.theme.metrics.spacing.md) {
                    MeetingReadinessRow(
                        title: "FluidVoice activity",
                        status: self.readiness.activityStatus,
                        isReady: self.readiness.activityReady
                    )
                    MeetingReadinessRow(
                        title: "Meeting audio",
                        status: self.draft.mode == .inRoom ? "Not used" : self.readiness.meetingAudioStatus,
                        isReady: self.draft.mode == .inRoom ||
                            (self.draft.selectedApplicationID != nil && self.readiness.meetingAudioReady)
                    )
                    MeetingReadinessRow(
                        title: "Microphone",
                        status: self.readiness.microphoneStatus,
                        isReady: self.draft.selectedMicrophoneID != nil && self.readiness.microphoneReady
                    )
                    MeetingReadinessRow(
                        title: "Transcription model",
                        status: self.readiness.modelStatus,
                        isReady: self.readiness.modelReady
                    )
                    MeetingReadinessRow(
                        title: "Storage",
                        status: self.readiness.storageStatus,
                        isReady: self.readiness.storageReady
                    )
                }
            }

            if self.readiness.showMicrophoneSettingsAction ||
                self.readiness.showScreenRecordingSettingsAction ||
                !self.readiness.modelReady
            {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    if self.readiness.showMicrophoneSettingsAction {
                        Button("Microphone Settings", systemImage: "mic.fill", action: self.onOpenMicrophoneSettings)
                            .fluidButton(.compact, size: .medium)
                    }
                    if self.readiness.showScreenRecordingSettingsAction {
                        Button(
                            "Screen Recording Settings",
                            systemImage: "rectangle.inset.filled.and.person.filled",
                            action: self.onOpenScreenRecordingSettings
                        )
                        .fluidButton(.compact, size: .medium)
                    }
                    if !self.readiness.modelReady {
                        Button("Open Voice Engine", systemImage: "waveform", action: self.onOpenVoiceEngine)
                            .fluidButton(.compact, size: .medium)
                    }
                }
            }

            Label(
                self.draft.mode == .onlineCall
                    ? "Headphones are recommended for the cleanest speaker separation."
                    : "Place the Mac where every speaker can be heard clearly.",
                systemImage: self.draft.mode == .onlineCall ? "headphones" : "mic.fill"
            )
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(self.theme.palette.secondaryText)

            Label(
                "Make sure everyone knows the meeting is being recorded.",
                systemImage: "person.2.badge.gearshape"
            )
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)

            if let errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .accessibilityLabel("Could not start recording. \(errorMessage)")
            }

            HStack {
                Button(action: self.onRefreshSources) {
                    if self.readiness.isCheckingSources {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Refreshing…")
                        }
                    } else {
                        Label("Refresh Sources", systemImage: "arrow.clockwise")
                    }
                }
                .fluidButton(.compact, size: .medium)
                .disabled(self.readiness.isCheckingSources || self.isStarting)

                Spacer()

                if let startHelp, !self.canStart {
                    Text(startHelp)
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .multilineTextAlignment(.trailing)
                }

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
    let onNewMeeting: () -> Void

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

            HStack {
                Button("Copy Transcript", systemImage: "doc.on.doc") {
                    self.onCopyTranscript(self.session)
                }
                .fluidButton(.compact, size: .medium)
                .disabled(self.session.transcriptSegments.isEmpty)

                Spacer()

                Button("New Meeting", systemImage: "plus", action: self.onNewMeeting)
                    .fluidButton(.accent, size: .medium)
                    .keyboardShortcut(.defaultAction)
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
    let onNewMeeting: () -> Void

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
                    Spacer()
                    Button("New Meeting", action: self.onNewMeeting)
                        .fluidButton(self.hasRecoverableAudio ? .compact : .accent, size: .medium)
                }
            }
        }
    }
}

private struct MeetingSetupRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.lg) {
            Text(self.title)
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
                .frame(width: 130, alignment: .leading)
            self.content
            Spacer(minLength: 0)
        }
        .padding(.vertical, self.theme.metrics.spacing.md)
    }
}

private struct MeetingSetupValueRow: View {
    let title: String
    let value: String

    @Environment(\.theme) private var theme

    var body: some View {
        MeetingSetupRow(title: self.title) {
            Text(self.value)
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
        }
    }
}

private struct MeetingReadinessRow: View {
    let title: String
    let status: String
    let isReady: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Image(systemName: self.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(self.isReady ? self.theme.palette.success : self.theme.palette.warning)
                .accessibilityHidden(true)
            Text(self.title)
                .font(self.theme.typography.body)
            Spacer()
            Text(self.status)
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.title), \(self.status)")
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
