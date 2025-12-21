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
}
