import Foundation

/// Lightweight analytics pipeline:
/// - bounded in-memory queue (drops oldest)
/// - periodic background flush
/// - fire-and-forget publishing (does not await responses)
final class AnalyticsService {
    static let shared = AnalyticsService()

    private let core = AnalyticsCore()

    private init() {}

    /// Call once at startup. Cheap and does not start networking unless configured + enabled.
    func bootstrap() {
        let enabled = SettingsStore.shared.shareAnonymousAnalytics
        let config = AnalyticsConfig.fromBundle()
        Task.detached(priority: .background) { [core] in
            await core.bootstrap(enabled: enabled, config: config)
        }
    }

    func setEnabled(_ enabled: Bool) {
        let config = AnalyticsConfig.fromBundle()
        Task.detached(priority: .background) { [core] in
            await core.setEnabled(enabled, config: config)
        }
    }

    func capture(_ event: AnalyticsEvent, properties: [String: Any] = [:]) {
        // Capture should be as close to O(1) as possible on the caller thread.
        // We compute common properties quickly (no heavy work, no content).
        let common = AnalyticsService.commonProperties()
        let merged = common.merging(properties) { _, new in new }

        let enabled = SettingsStore.shared.shareAnonymousAnalytics
        let config = AnalyticsConfig.fromBundle()
        let distinctID = AnalyticsIdentityStore.shared.anonymousInstallID

        Task.detached(priority: .background) { [core] in
            await core.capture(
                eventName: event.rawValue,
                distinctID: distinctID,
                enabled: enabled,
                config: config,
                properties: merged
            )
        }
    }

    // MARK: - Common props (low-cardinality only)

    private static func commonProperties() -> [String: Any] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif

        #if DEBUG
        let environment = "debug"
        #else
        let environment = "release"
        #endif

        let settings = SettingsStore.shared

        return [
            "app_version": version,
            "app_build": build,
            "os_version": osVersion,
            "arch": arch,
            "environment": environment,

            // Low-cardinality settings snapshot
            "ai_processing_enabled": settings.enableAIProcessing,
            "streaming_preview_enabled": settings.enableStreamingPreview,
            "press_and_hold_mode": settings.pressAndHoldMode,
            "copy_to_clipboard_enabled": settings.copyTranscriptionToClipboard,
        ]
    }
}

// MARK: - Core (actor)

private actor AnalyticsCore {
    private var enabled: Bool = true
    private var config: AnalyticsConfig = .fromBundle()

    // Bounded queue to protect memory.
    private var queue: [[String: Any]] = []
    private let maxQueuedEvents: Int = 200

    // Flush tuning.
    private let flushAt: Int = 20
    private let flushIntervalSeconds: UInt64 = 30

    private var flushTask: Task<Void, Never>?
    private var isFlushing: Bool = false

    func bootstrap(enabled: Bool, config: AnalyticsConfig) async {
        self.enabled = enabled
        self.config = config

        // Record first open timestamp (used for retention-style calculations).
        _ = AnalyticsIdentityStore.shared.ensureFirstOpenRecorded()

        self.startFlushLoopIfNeeded()
    }

    func setEnabled(_ enabled: Bool, config: AnalyticsConfig) async {
        self.enabled = enabled
        self.config = config

        if !enabled {
            // Drop any pending events to honor opt-out immediately.
            self.queue.removeAll(keepingCapacity: true)
        }

        self.startFlushLoopIfNeeded()
    }

    func capture(
        eventName: String,
        distinctID: String,
        enabled: Bool,
        config: AnalyticsConfig,
        properties: [String: Any]
    ) async {
        // Use latest values passed by caller to avoid cross-actor UserDefaults reads.
        self.enabled = enabled
        self.config = config

        guard self.enabled, self.config.isConfigured else { return }

        var event: [String: Any] = [:]
        event["event"] = eventName
        event["timestamp"] = ISO8601DateFormatter().string(from: Date())

        // PostHog expects distinct_id inside properties.
        var props = properties
        props["distinct_id"] = distinctID
        props["$lib"] = "FluidVoice"
        props["$lib_version"] = "1"
        event["properties"] = props

        self.enqueue(event)

        if self.queue.count >= self.flushAt {
            await self.flushIfNeeded()
        }
    }

    private func enqueue(_ event: [String: Any]) {
        self.queue.append(event)
        if self.queue.count > self.maxQueuedEvents {
            // Drop oldest.
            self.queue.removeFirst(self.queue.count - self.maxQueuedEvents)
        }
    }

    private func startFlushLoopIfNeeded() {
        // Only run a background flush loop when enabled and configured.
        guard self.enabled, self.config.isConfigured else {
            self.flushTask?.cancel()
            self.flushTask = nil
            return
        }

        guard self.flushTask == nil else { return }

        self.flushTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self.flushIntervalSeconds * 1_000_000_000)
                await self.flushIfNeeded()
            }
        }
    }

    private func flushIfNeeded() async {
        guard self.enabled, self.config.isConfigured else { return }
        guard !self.queue.isEmpty else { return }
        guard !self.isFlushing else { return }

        self.isFlushing = true
        defer { self.isFlushing = false }

        // Drain up to max batch size.
        let batchCount = min(self.queue.count, self.maxQueuedEvents)
        let batch = Array(self.queue.prefix(batchCount))
        self.queue.removeFirst(batchCount)

        await self.sendBatch(batch)
    }

    private func sendBatch(_ batch: [[String: Any]]) async {
        // Fire-and-forget network request; do not await response.
        let host = self.config.postHogHost
        let apiKey = self.config.postHogApiKey

        guard let url = URL(string: host)?.appendingPathComponent("batch") else { return }

        var payload: [String: Any] = [
            "api_key": apiKey,
            "batch": batch,
        ]

        // Ensure payload is JSON serializable.
        guard JSONSerialization.isValidJSONObject(payload) else { return }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        // Detached task ensures we never block the actor while URLSession does its work.
        Task.detached(priority: .background) {
            let session = URLSession.shared
            _ = try? await session.data(for: request)
        }
    }
}
