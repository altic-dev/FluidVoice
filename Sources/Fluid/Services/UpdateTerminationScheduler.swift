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

/// Releases before 1.6.10-beta.8 quit after an update from a main-queue block, which can leave the
/// old copy stuck mid-quit with its install progress window on screen. Those releases cannot be
/// changed, so the first launch of a fixed build removes that stuck copy, once.
enum SupersededInstanceRetirement {
    struct Instance: Equatable {
        let processID: pid_t
        let launchDate: Date?
        let bundlePath: String?
    }

    nonisolated static let completedDefaultsKey = "SupersededLegacyInstanceRetirementCompleted"
    /// The old copy normally quits itself about two seconds after launching this one.
    nonisolated static let quitRequestDelay: Duration = .seconds(5)
    /// A copy that accepted the quit may still be saving: AppDelegate allows 8s for private AI,
    /// 12s for ASR and meeting shutdown, and 2s for Zeppelin. Never cut that short.
    nonisolated static let forceQuitGracePeriod: Duration = .seconds(30)

    /// An update replaces the app in place, so the outgoing copy was launched earlier from this same
    /// path. Never this process, a newer copy, a copy opened from another location (a second install
    /// or a saved rollback), or one whose age or location is unknown.
    nonisolated static func superseded(
        among instances: [Instance],
        currentProcessID: pid_t,
        currentLaunchDate: Date,
        currentBundlePath: String
    ) -> [pid_t] {
        instances.compactMap { instance in
            guard instance.processID != currentProcessID,
                  let launchDate = instance.launchDate,
                  launchDate < currentLaunchDate,
                  instance.bundlePath == currentBundlePath
            else { return nil }
            return instance.processID
        }
    }

    /// One bounded pass, repeated on later launches only until one completes. Fixed builds close
    /// their own progress window and are never asked or forced to quit by a later copy.
    static func start() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !UserDefaults.standard.bool(forKey: Self.completedDefaultsKey)
        else { return }
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let currentLaunchDate = NSRunningApplication.current.launchDate ?? Date()
        let currentBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        Task.detached(priority: .utility) {
            let supersededApplications: @Sendable () -> [NSRunningApplication] = {
                let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                let superseded = Set(Self.superseded(
                    among: applications.map {
                        Instance(processID: $0.processIdentifier, launchDate: $0.launchDate, bundlePath: $0.bundleURL?.standardizedFileURL.path)
                    },
                    currentProcessID: currentProcessID,
                    currentLaunchDate: currentLaunchDate,
                    currentBundlePath: currentBundlePath
                ))
                return applications.filter { superseded.contains($0.processIdentifier) }
            }
            try? await Task.sleep(for: Self.quitRequestDelay)
            let lingering = supersededApplications()
            if !lingering.isEmpty {
                await DebugLogger.shared.info("Asking \(lingering.count) superseded app instance(s) to quit", source: "AppDelegate")
                lingering.forEach { $0.terminate() }
                try? await Task.sleep(for: Self.forceQuitGracePeriod)
                let stuck = supersededApplications()
                if !stuck.isEmpty {
                    await DebugLogger.shared.warning("Force quitting \(stuck.count) superseded app instance(s)", source: "AppDelegate")
                    stuck.forEach { $0.forceTerminate() }
                }
            }
            UserDefaults.standard.set(true, forKey: Self.completedDefaultsKey)
        }
    }
}
