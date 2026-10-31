//
//  AppServices.swift
//  Fluid
//
//  Centralized service container to reduce SwiftUI view type complexity.
//  By holding heavy services here (outside ContentView's @StateObject declarations),
//  we reduce the generic type signature of ContentView, which helps avoid
//  Swift runtime type metadata crashes at app launch.
//
//  DEFENSIVE STRATEGY (2025-12-21):
//  This file implements multiple layers of defense against startup crashes:
//  1. Services are lazily initialized (not created until first access)
//  2. A startup gate prevents any heavy work before UI is ready
//  3. Combined with the 1.5s delay in ContentView for belt-and-suspenders approach
//

import Combine
import Foundation

/// Centralized container for app-wide services.
/// This exists to reduce ContentView's generic type signature complexity,
/// which has been observed to cause EXC_BAD_ACCESS crashes during Swift
/// runtime type metadata resolution at app launch.
@MainActor
final class AppServices: ObservableObject {
    /// Shared singleton instance
    static let shared = AppServices()

    // MARK: - Startup Gate

    /// Flag indicating the UI has completed its initial render.
    /// Heavy operations should wait until this is true.
    @Published private(set) var isUIReady: Bool = false
    @Published private(set) var meetingAutoDetectHealth: MeetingAutoDetector.Health?
    @Published private(set) var meetingAutomaticTarget: MeetingAutoDetector.ResolvedTarget?

    /// Call this once the main UI has finished its initial layout.
    /// This signals that it's safe to start heavy services.
    func signalUIReady() {
        if !self.isUIReady {
            DebugLogger.shared.info("🚦 UI Ready signal received - services can now initialize", source: "AppServices")
            self.isUIReady = true
        }
        self.refreshFluidMeetAvailability()
    }

    // MARK: - Lazy Services

    /// Audio hardware observation service (lazily initialized)
    private var _audioObserver: AudioHardwareObserver?
    var audioObserver: AudioHardwareObserver {
        if let existing = self._audioObserver {
            return existing
        }
        DebugLogger.shared.info("🔊 Lazily creating AudioHardwareObserver", source: "AppServices")
        let observer = AudioHardwareObserver()
        self._audioObserver = observer
        self.setupAudioObserverForwarding()
        return observer
    }

    /// Automatic speech recognition service (lazily initialized)
    private var _asr: ASRService?
    var asr: ASRService {
        if let existing = self._asr {
            return existing
        }
        DebugLogger.shared.info("🎤 Lazily creating ASRService", source: "AppServices")
        let service = ASRService()
        self._asr = service
        self.setupASRForwarding()
        return service
    }

    private var _fileTranscriptionService: FileTranscriptionService?
    var fileTranscriptionService: FileTranscriptionService {
        if let existing = self._fileTranscriptionService {
            return existing
        }
        let service = FileTranscriptionService(asrService: self.asr)
        self._fileTranscriptionService = service
        return service
    }

    private var _microphonePreferenceCoordinator: MicrophonePreferenceCoordinator?
    var microphonePreferenceCoordinator: MicrophonePreferenceCoordinator {
        if let existing = self._microphonePreferenceCoordinator {
            return existing
        }
        let coordinator = MicrophonePreferenceCoordinator()
        self._microphonePreferenceCoordinator = coordinator
        return coordinator
    }

    private var _meetingAudioActivityArbiter: AudioActivityArbiter?
    var meetingAudioActivityArbiter: AudioActivityArbiter {
        if let existing = self._meetingAudioActivityArbiter {
            return existing
        }
        let arbiter = AudioActivityArbiter { [weak self] in
            guard let self else { throw MeetingCoordinatorError.activityInProgress }
            return self.asr as any ASRActivityLeasing
        }
        self._meetingAudioActivityArbiter = arbiter
        return arbiter
    }

    private var _meetingSessionCoordinator: MeetingSessionCoordinator?
    var meetingSessionCoordinator: MeetingSessionCoordinator {
        if let existing = self._meetingSessionCoordinator {
            return existing
        }
        DebugLogger.shared.info("Lazily creating MeetingSessionCoordinator", source: "AppServices")
        let coordinator = MeetingSessionCoordinator(
            store: MeetingSessionStore.shared,
            capture: MeetingCaptureEngine(),
            processing: MeetingProcessingPipeline(
                asrServiceProvider: { AppServices.shared.asr },
                prepareDiarizationModel: { try await MeetingDiarizationModelStore.shared.ensureInstalled() }
            ),
            audioArbiter: self.meetingAudioActivityArbiter,
            preferredMicrophoneUID: { [weak self] in
                self?.microphonePreferenceCoordinator.inputDeviceForCapture()?.uid
            },
            // The speaker model is only needed after Stop, so a missing model never blocks
            // recording; final processing waits for `MeetingDiarizationModelStore` instead.
            validateRecordingModels: {
                guard CPUArchitecture.isAppleSilicon else {
                    throw MeetingParakeetNemotronRuntimeError.unsupportedArchitecture
                }
            }
        )
        self._meetingSessionCoordinator = coordinator
        self.setupMeetingCoordinatorForwarding()
        // Attach end monitoring to every captured call, including manual and menu-bar starts.
        // Start-prompt episodes remain consumed until the meeting's own evidence ends.
        coordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak coordinator] state in
                // Deliveries are queued, so read the state as it is now before calling a recording over.
                Self.synchronizeMeetingEndWatch(
                    state: coordinator?.state,
                    session: coordinator?.activeSession,
                    detector: self?._meetingAutoDetector
                )
                guard !MeetingOverlayVisibility.isVisible(for: state) else { return }
                MeetingStillRecordingNudgeController.shared.hide()
            }
            .store(in: &self.cancellables)
        Task { @MainActor in
            guard SettingsStore.shared.fluidMeetEnabled else { return }
            MeetingRecordingPillController.shared.activate(coordinator: coordinator)
            await coordinator.ensureRestored()
            guard SettingsStore.shared.fluidMeetEnabled else { return }
            await coordinator.sweepExpiredAudio()
        }
        return coordinator
    }

    /// Standalone — activated once, independently of `meetingSessionCoordinator`'s lazy getter.
    private var _meetingAutoDetector: MeetingAutoDetector?
    var meetingAutoDetector: MeetingAutoDetector {
        if let existing = self._meetingAutoDetector {
            return existing
        }
        let detector = MeetingAutoDetector(
            workspaceEvents: WorkspaceEventsMonitor(),
            micActivity: CoreAudioMicActivitySignal(),
            audioProcessActivity: CoreAudioProcessActivityProvider(),
            windowSnapshotProvider: CGWindowSnapshotProvider(),
            browserTabReader: AXBrowserTabReader(),
            activityGate: LiveDetectionActivityGate(),
            clock: SystemClock(),
            isNativeDetectionEnabled: { SettingsStore.shared.fluidMeetEnabled && SettingsStore.shared.meetingAutoDetectEnabled },
            isBrowserDetectionEnabled: {
                SettingsStore.shared.fluidMeetEnabled && SettingsStore.shared.meetingAutoDetectEnabled && SettingsStore.shared.meetingAutoDetectBrowserEnabled
            },
            lastSpeechAt: { [weak self] in self?._meetingSessionCoordinator?.lastLiveSpeechAt }
        )
        self._meetingAutoDetector = detector
        self.wireMeetingAutoDetector(detector)
        if SettingsStore.shared.fluidMeetEnabled { detector.start() }
        DebugLogger.shared.info("detector-started", source: "MeetingAutoDetector")
        return detector
    }

    private func wireMeetingAutoDetector(_ detector: MeetingAutoDetector) {
        // The detector is lazy; a manual recording may already be running when it is created.
        Self.synchronizeMeetingEndWatch(
            state: self._meetingSessionCoordinator?.state,
            session: self._meetingSessionCoordinator?.activeSession,
            detector: detector
        )
        detector.onAutomaticTargetChanged = { [weak self] target in
            self?.meetingAutomaticTarget = target
        }
        detector.onPromptRequested = { request in
            MeetingDetectionPromptController.shared.present(request)
        }
        detector.onHealthChanged = { [weak self] health in
            self?.meetingAutoDetectHealth = health
        }
        detector.onStillRecordingNudge = {
            MeetingStillRecordingNudgeController.shared.present()
        }
        detector.onStillRecordingNudgeWithdrawn = {
            MeetingStillRecordingNudgeController.shared.hide()
        }
        detector.onSuggestDisablingAutoDetect = {
            MeetingAutoDetectDismissalAdvisor.shared.shouldSuggest = true
        }
        detector.onEpisodeInvalidated = { episodeID in
            MeetingDetectionPromptController.shared.invalidateEpisode(episodeID)
        }
        MeetingDetectionPromptController.shared.onStart = { [weak self] episodeID in
            guard let self else { throw MeetingAutoDetector.StartError.cannotStart }
            try await self.startAutoDetectedRecording(episodeID: episodeID)
        }
        MeetingDetectionPromptController.shared.onSetup = { [weak self] episodeID in
            // Setup is intentionally navigation-only: it must never materialize a recording.
            self?._meetingAutoDetector?.timeoutDismissed(episodeID: episodeID)
            AppNavigationRouter.shared.request(.meetingTranscription)
        }
        MeetingDetectionPromptController.shared.onDismiss = { [weak self] episodeID in
            self?._meetingAutoDetector?.dismissTapped(episodeID: episodeID, at: Date())
        }
        MeetingDetectionPromptController.shared.onTimeout = { [weak self] episodeID in
            self?._meetingAutoDetector?.timeoutDismissed(episodeID: episodeID)
        }
        MeetingStillRecordingNudgeController.shared.onDismiss = { [weak self] in
            self?._meetingAutoDetector?.stillRecordingNudgeDismissed()
        }
        MeetingStillRecordingNudgeController.shared.onStop = { [weak self] in
            guard let self else { return }
            Task { @MainActor in _ = try? await self.meetingSessionCoordinator.stopAndTranscribe() }
        }
    }

    /// Inputs must be the coordinator's current snapshot, not a queued state notification.
    static func synchronizeMeetingEndWatch(
        state: MeetingCoordinatorState?,
        session: MeetingSession?,
        detector: MeetingAutoDetector?
    ) {
        guard let detector else { return }
        switch state {
        case .preparing:
            break
        case let .recording(id), let .recordingDegraded(id):
            guard let session, session.id == id else {
                detector.recordingStopped()
                return
            }
            detector.recordingStarted(
                sessionID: id,
                application: session.mode == .onlineCall ? session.capturedApplication : nil
            )
        default:
            detector.recordingStopped()
        }
    }

    private func startAutoDetectedRecording(episodeID: UUID) async throws {
        guard SettingsStore.shared.fluidMeetEnabled,
              let detector = self._meetingAutoDetector,
              let target = detector.resolvedTarget(for: episodeID),
              detector.canStart(episodeID: episodeID)
        else {
            throw MeetingAutoDetector.StartError.cannotStart
        }
        let coordinator = self.meetingSessionCoordinator
        let configuration = try await coordinator.defaultConfiguration(
            mode: .onlineCall,
            title: MeetingTranscriptionSetupDraft.defaultTitle(mode: .onlineCall, applicationDisplayName: nil),
            preferredBundleIdentifier: target.bundleIdentifier,
            preferredWindowID: target.windowID,
            requirePreferredApplication: true
        )
        try Task.checkCancellation()
        guard detector.canStart(episodeID: episodeID) else {
            throw MeetingAutoDetector.StartError.cannotStart
        }
        _ = try await coordinator.startRecording(configuration: configuration)
        detector.adoptStartedEpisode(episodeID: episodeID)
        AppNavigationRouter.shared.request(.meetingTranscription)
    }

    /// Read-only meeting check that does not initialize the meeting stack.
    var hasActiveMeetingSessionActivity: Bool {
        guard let coordinator = self._meetingSessionCoordinator else { return false }
        if coordinator.hasPendingStart { return true }
        switch coordinator.state {
        case .preparing, .recording, .recordingDegraded, .stopping, .processing:
            return true
        case .idle, .completed, .interrupted, .failed:
            return false
        }
    }

    var hasActiveFileTranscriptionActivity: Bool {
        self._asr?.activeExclusiveActivity == .fileTranscription
    }

    /// Read-only checks for MeetingAutoDetector: never force either lazy service into existence.
    var isMeetingSessionCoordinatorMaterialized: Bool { self._meetingSessionCoordinator != nil }
    var activeExclusiveActivityIfASRMaterialized: ASRExclusiveActivity? { self._asr?.activeExclusiveActivity }

    /// Legacy UI guard; ASRService is the atomic source of truth for acquisition.
    var hasActiveMeetingActivity: Bool {
        self.hasActiveMeetingSessionActivity || self._asr?.activeExclusiveActivity == .meeting
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        NotificationCenter.default.publisher(for: .fluidMeetEnabledChanged)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshFluidMeetAvailability() }
            }
            .store(in: &self.cancellables)
        // CRITICAL: Services are NOT created here.
        // They are created lazily on first access, which happens AFTER the UI is ready.
        // This ensures SwiftUI's AttributeGraph has finished processing before
        // any heavy audio system work begins.
        DebugLogger.shared.info("📦 AppServices singleton created (services not yet initialized)", source: "AppServices")
    }

    /// Do not abandon an active recording or processing job when changing availability.
    func setFluidMeetEnabled(_ enabled: Bool) {
        guard enabled || !self.hasActiveMeetingSessionActivity else { return }
        SettingsStore.shared.fluidMeetEnabled = enabled
    }

    private func refreshFluidMeetAvailability() {
        guard SettingsStore.shared.fluidMeetEnabled else {
            self._meetingAutoDetector?.stop()
            self._meetingAutoDetector = nil
            self.meetingAutomaticTarget = nil
            self.meetingAutoDetectHealth = nil
            MeetingDetectionPromptController.shared.cancelForFeatureDisable()
            MeetingStillRecordingNudgeController.shared.hide()
            MeetingRecordingPillController.shared.deactivate()
            return
        }
        guard self.isUIReady else { return }
        if let coordinator = self._meetingSessionCoordinator {
            MeetingRecordingPillController.shared.activate(coordinator: coordinator)
        }
        _ = self.meetingAutoDetector
    }

    // MARK: - Change Forwarding

    /// Forward AudioHardwareObserver changes to trigger UI updates
    private func setupAudioObserverForwarding() {
        guard let observer = _audioObserver else { return }
        observer.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &self.cancellables)
    }

    /// Forward ASRService changes to trigger UI updates
    private func setupASRForwarding() {
        guard let asr = _asr else { return }
        asr.objectWillChange
            .sink { [weak self, weak asr] _ in
                guard asr?.defersStopUIInvalidation == false else { return }
                self?.objectWillChange.send()
            }
            .store(in: &self.cancellables)
    }

    private func setupMeetingCoordinatorForwarding() {
        guard let coordinator = self._meetingSessionCoordinator else { return }
        coordinator.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &self.cancellables)
    }

    // MARK: - Safe Initialization

    /// Safely initialize all services after the UI is ready.
    /// This is the recommended way to start services - call this from ContentView.onAppear
    /// after the delay has passed.
    func initializeServicesIfNeeded() {
        guard self.isUIReady else {
            DebugLogger.shared.warning("⚠️ initializeServicesIfNeeded called before UI ready - deferring", source: "AppServices")
            return
        }

        // Access the properties to trigger lazy initialization
        _ = self.audioObserver
        _ = self.asr
        self.refreshFluidMeetAvailability()

        DebugLogger.shared.info("✅ All services initialized", source: "AppServices")
    }

    func shutdownForTermination() async {
        self._meetingAutoDetector?.stop()
        self._meetingAutoDetector = nil
        if let meetingSessionCoordinator = self._meetingSessionCoordinator {
            await meetingSessionCoordinator.shutdownForTermination()
            self._meetingSessionCoordinator = nil
        }
        if let asr = self._asr {
            await asr.shutdownForTermination()
            self._asr = nil
        }
    }
}
