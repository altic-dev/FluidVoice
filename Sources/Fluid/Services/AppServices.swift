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

    /// Call this once the main UI has finished its initial layout.
    /// This signals that it's safe to start heavy services.
    func signalUIReady() {
        guard !self.isUIReady else { return }
        DebugLogger.shared.info("🚦 UI Ready signal received - services can now initialize", source: "AppServices")
        self.isUIReady = true
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
            return self.asr
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
                asrServiceProvider: { AppServices.shared.asr }
            ),
            audioArbiter: self.meetingAudioActivityArbiter,
            preferredMicrophoneUID: { [weak self] in
                self?.microphonePreferenceCoordinator.inputDeviceForCapture()?.uid
            }
        )
        self._meetingSessionCoordinator = coordinator
        self.setupMeetingCoordinatorForwarding()
        Task { @MainActor [weak coordinator] in
            await coordinator?.ensureRestored()
        }
        return coordinator
    }

    /// Read-only meeting check that does not initialize the meeting stack.
    var hasActiveMeetingSessionActivity: Bool {
        guard let coordinator = self._meetingSessionCoordinator else { return false }
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

    /// Legacy UI guard; ASRService is the atomic source of truth for acquisition.
    var hasActiveMeetingActivity: Bool {
        self.hasActiveMeetingSessionActivity || self._asr?.activeExclusiveActivity == .meeting
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // CRITICAL: Services are NOT created here.
        // They are created lazily on first access, which happens AFTER the UI is ready.
        // This ensures SwiftUI's AttributeGraph has finished processing before
        // any heavy audio system work begins.
        DebugLogger.shared.info("📦 AppServices singleton created (services not yet initialized)", source: "AppServices")
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
            .sink { [weak self] _ in self?.objectWillChange.send() }
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

        DebugLogger.shared.info("✅ All services initialized", source: "AppServices")
    }

    func shutdownForTermination() async {
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
