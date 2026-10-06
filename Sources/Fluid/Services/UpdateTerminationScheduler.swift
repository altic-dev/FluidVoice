import AppKit

@MainActor
enum UpdateTerminationScheduler {
    static func requestTermination() {
        // AppKit may synchronously pump its termination run loop for .terminateLater.
        // Calling terminate from a main-queue block keeps that serial queue occupied,
        // preventing applicationShouldTerminate's MainActor history-save task from running.
        // A run-loop callback leaves the main dispatch queue available for that task.
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
    }
}

/// A freshly updated app can start while the copy that installed it is still alive: that copy's
/// quit was delayed or cancelled, and its install progress window stays on screen with it.
enum SupersededInstanceRetirement {
    struct Instance: Equatable {
        let processID: pid_t
        let launchDate: Date?
    }

    /// The old copy normally quits itself about two seconds after launching this one.
    nonisolated static let quitRequestDelay: Duration = .seconds(5)
    /// A copy that accepted the quit may still be saving: AppDelegate allows 8s for private AI,
    /// 12s for ASR and meeting shutdown, and 2s for Zeppelin. Never cut that short.
    nonisolated static let forceQuitGracePeriod: Duration = .seconds(30)

    /// Only copies already running when this one launched: never this process, a newer copy,
    /// or one whose age is unknown.
    nonisolated static func superseded(among instances: [Instance], currentProcessID: pid_t, currentLaunchDate: Date) -> [pid_t] {
        instances.compactMap { instance in
            guard instance.processID != currentProcessID,
                  let launchDate = instance.launchDate,
                  launchDate < currentLaunchDate
            else { return nil }
            return instance.processID
        }
    }

    /// One bounded pass per launch: wait for the old copy to quit by itself, ask it to quit, then force it.
    static func start() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let currentLaunchDate = NSRunningApplication.current.launchDate ?? Date()
        Task.detached(priority: .utility) {
            let supersededApplications: @Sendable () -> [NSRunningApplication] = {
                let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                let superseded = Set(Self.superseded(
                    among: applications.map { Instance(processID: $0.processIdentifier, launchDate: $0.launchDate) },
                    currentProcessID: currentProcessID,
                    currentLaunchDate: currentLaunchDate
                ))
                return applications.filter { superseded.contains($0.processIdentifier) }
            }
            try? await Task.sleep(for: Self.quitRequestDelay)
            let lingering = supersededApplications()
            guard !lingering.isEmpty else { return }
            await DebugLogger.shared.info("Asking \(lingering.count) superseded app instance(s) to quit", source: "AppDelegate")
            lingering.forEach { $0.terminate() }
            try? await Task.sleep(for: Self.forceQuitGracePeriod)
            let stuck = supersededApplications()
            guard !stuck.isEmpty else { return }
            await DebugLogger.shared.warning("Force quitting \(stuck.count) superseded app instance(s)", source: "AppDelegate")
            stuck.forEach { $0.forceTerminate() }
        }
    }
}
