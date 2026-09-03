import Foundation

/// Frees on-device models after a period without dictation so the app stops
/// pinning gigabytes while idle. Recording never waits on this: the models
/// reload in the background on the next hotkey press.
@MainActor
final class IdleModelUnloader {
    static let shared = IdleModelUnloader()

    private var countdown: Task<Void, Never>?

    private init() {}

    // MARK: - Public

    /// Restart the idle countdown. Call whenever a model was just used.
    func recordActivity() {
        let minutes = SettingsStore.shared.modelIdleUnloadMinutes
        guard minutes > 0 else {
            self.cancel()
            return
        }
        self.schedule(after: .seconds(minutes * 60))
    }

    /// Release both models immediately (settings button). Same busy guard as the timer.
    func unloadNow() async {
        await self.fire()
    }

    /// Stop the countdown while a session is active.
    func cancel() {
        self.countdown?.cancel()
        self.countdown = nil
    }

    // MARK: - Private

    private func schedule(after delay: Duration) {
        self.countdown?.cancel()
        self.countdown = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            await self?.fire()
        }
    }

    private func fire() async {
        let asr = AppServices.shared.asr
        let overlay = NotchContentState.shared
        if asr.isRunningOrStarting || overlay.isProcessing || overlay.isCommandProcessing {
            // Busy windows last seconds, not minutes, so a fixed short retry is enough.
            DebugLogger.shared.debug("Idle unload deferred: session active", source: "IdleModelUnloader")
            self.schedule(after: .seconds(60))
            return
        }
        DebugLogger.shared.info("Idle unload: releasing models", source: "IdleModelUnloader")
        self.countdown = nil
        await PrivateAIIntegrationService.shared.unloadCachedRuntime(reason: "idle")
        asr.unloadForIdle()
    }
}
