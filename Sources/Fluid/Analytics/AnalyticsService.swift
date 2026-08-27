import Foundation

/// Typed API for low-volume analytics.
final class AnalyticsService {
    static let shared = AnalyticsService()

    private let detailedConsentGate: DetailedAnalyticsConsentGate
    private let core: AnalyticsCore

    private init() {
        let detailedConsentGate = DetailedAnalyticsConsentGate()
        self.detailedConsentGate = detailedConsentGate
        self.core = AnalyticsCore(detailedConsentGate: detailedConsentGate)
    }

    func bootstrap() {
        self.submit { core, context in
            await core.bootstrap(context: context)
        }
    }

    func setDetailedAnalyticsEnabled(_ enabled: Bool) {
        let consentGeneration = self.detailedConsentGate.advance()
        let context = Self.context(
            detailedAnalyticsEnabled: enabled,
            detailedConsentGeneration: consentGeneration
        )
        Task.detached(priority: .background) { [core] in
            await core.setDetailedAnalyticsEnabled(context: context)
        }
    }

    /// Records one active-user event per local day.
    func recordAppActivity() {
        self.submit { core, context in
            await core.recordActivity(.app, context: context)
        }
    }

    /// Counts accepted usage and attempted AI requests.
    func recordUsage(
        mode: AnalyticsUsageMode,
        transcriptionModel: AnalyticsModelDescriptor? = nil,
        aiModel: AnalyticsModelDescriptor? = nil
    ) {
        self.submit { core, context in
            await core.recordUsage(
                mode: mode,
                transcriptionModel: transcriptionModel,
                aiModel: aiModel,
                context: context
            )
        }
    }

    func recordModelUsage(
        role: AnalyticsModelRole,
        mode: AnalyticsUsageMode,
        descriptor: AnalyticsModelDescriptor
    ) {
        self.submit { core, context in
            await core.recordModelUsage(role: role, mode: mode, descriptor: descriptor, context: context)
        }
    }

    func recordOnboardingStarted(origin: AnalyticsOnboardingOrigin) {
        self.submit { core, context in
            await core.recordOnboardingStarted(origin: origin, context: context)
        }
    }

    func recordOnboardingStepViewed(_ step: AnalyticsOnboardingStep, origin: AnalyticsOnboardingOrigin) {
        self.submit { core, context in
            await core.recordOnboardingStepViewed(step, origin: origin, context: context)
        }
    }

    func recordOnboardingStepCompleted(
        _ step: AnalyticsOnboardingStep,
        outcome: AnalyticsOnboardingOutcome,
        origin: AnalyticsOnboardingOrigin,
        completesFlow: Bool = false
    ) {
        self.submit { core, context in
            await core.recordOnboardingStepCompleted(
                step,
                outcome: outcome,
                origin: origin,
                completesFlow: completesFlow,
                context: context
            )
        }
    }

    func recordModelDownloadStarted(
        id: UUID,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource
    ) {
        self.submit { core, context in
            await core.recordModelDownloadStarted(
                id: id.uuidString.lowercased(),
                descriptor: descriptor,
                source: source,
                context: context
            )
        }
    }

    func recordModelDownloadFinished(
        id: UUID,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource,
        outcome: AnalyticsModelDownloadOutcome,
        duration: TimeInterval?
    ) {
        self.submit { core, context in
            await core.recordModelDownloadFinished(
                id: id.uuidString.lowercased(),
                descriptor: descriptor,
                source: source,
                outcome: outcome,
                duration: duration,
                context: context
            )
        }
    }

    private func submit(
        _ operation: @escaping @Sendable (AnalyticsCore, AnalyticsContext) async -> Void
    ) {
        let context = Self.context(
            detailedAnalyticsEnabled: SettingsStore.shared.shareDetailedAnalytics,
            detailedConsentGeneration: self.detailedConsentGate.currentGeneration
        )
        Task.detached(priority: .background) { [core] in
            await operation(core, context)
        }
    }

    private static func context(
        detailedAnalyticsEnabled: Bool,
        detailedConsentGeneration: UInt64
    ) -> AnalyticsContext {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return AnalyticsContext(
            detailedAnalyticsEnabled: detailedAnalyticsEnabled,
            detailedConsentGeneration: detailedConsentGeneration,
            config: AnalyticsConfig.fromBundle(),
            distinctID: AnalyticsIdentityStore.shared.anonymousInstallID,
            appVersion: version
        )
    }
}

private struct AnalyticsContext {
    let detailedAnalyticsEnabled: Bool
    let detailedConsentGeneration: UInt64
    let config: AnalyticsConfig
    let distinctID: String
    let appVersion: String
}

final nonisolated class DetailedAnalyticsConsentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    var currentGeneration: UInt64 {
        self.lock.withLock { self.generation }
    }

    func advance() -> UInt64 {
        self.lock.withLock {
            self.generation &+= 1
            return self.generation
        }
    }

    func accepts(_ generation: UInt64) -> Bool {
        self.lock.withLock { generation == self.generation }
    }
}

private actor AnalyticsCore {
    private var context: AnalyticsContext?
    private let detailedConsentGate: DetailedAnalyticsConsentGate
    private var database: AnalyticsDatabase?
    private var flushTask: Task<Void, Never>?
    private var activeUploadTask: Task<Int, Error>?
    private var isFlushing = false

    private let batchSize = 50

    init(detailedConsentGate: DetailedAnalyticsConsentGate) {
        self.detailedConsentGate = detailedConsentGate
    }

    func bootstrap(context: AnalyticsContext) async {
        guard self.apply(context) else { return }
        do {
            if !context.detailedAnalyticsEnabled {
                try self.purgeStoredDetailedAnalyticsIfPresent(context: context)
            }
            guard context.config.isConfigured else { return }
            let database = try self.database(for: context)
            if context.detailedAnalyticsEnabled {
                try database.finalizeDays(before: Date())
                try database.recoverInterruptedModelDownloads(at: Date())
            }
            self.startFlushLoopIfNeeded()
            await self.flushIfNeeded()
        } catch {
            self.stopFlushLoop()
        }
    }

    func setDetailedAnalyticsEnabled(context: AnalyticsContext) async {
        guard self.apply(context) else { return }
        self.activeUploadTask?.cancel()
        self.stopFlushLoop()
        await self.bootstrap(context: context)
    }

    func recordActivity(_ kind: AnalyticsActivityKind, context: AnalyticsContext) async {
        await self.writeActivity(context: context) { database, date in
            try database.recordActivity(kind, at: date)
        }
    }

    func recordUsage(
        mode: AnalyticsUsageMode,
        transcriptionModel: AnalyticsModelDescriptor?,
        aiModel: AnalyticsModelDescriptor?,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context, fallbackActivity: .coreAction) { database, date in
            try database.recordUsage(
                mode: mode,
                transcriptionModel: transcriptionModel,
                aiModel: aiModel,
                at: date
            )
        }
    }

    func recordModelUsage(
        role: AnalyticsModelRole,
        mode: AnalyticsUsageMode,
        descriptor: AnalyticsModelDescriptor,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context, fallbackActivity: .coreAction) { database, date in
            try database.recordModelUsage(role: role, mode: mode, descriptor: descriptor, at: date)
        }
    }

    func recordOnboardingStarted(origin: AnalyticsOnboardingOrigin, context: AnalyticsContext) async {
        await self.writeDetailed(context: context, fallbackActivity: .app) { database, date in
            try database.recordOnboardingStarted(origin: origin, at: date)
        }
    }

    func recordOnboardingStepViewed(
        _ step: AnalyticsOnboardingStep,
        origin: AnalyticsOnboardingOrigin,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context) { database, date in
            try database.recordOnboardingStepViewed(step, origin: origin, at: date)
        }
    }

    func recordOnboardingStepCompleted(
        _ step: AnalyticsOnboardingStep,
        outcome: AnalyticsOnboardingOutcome,
        origin: AnalyticsOnboardingOrigin,
        completesFlow: Bool,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context) { database, date in
            try database.recordOnboardingStepCompleted(
                step,
                outcome: outcome,
                origin: origin,
                completesFlow: completesFlow,
                at: date
            )
        }
    }

    func recordModelDownloadStarted(
        id: String,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context, fallbackActivity: .coreAction) { database, date in
            try database.recordModelDownloadStarted(id: id, descriptor: descriptor, source: source, at: date)
        }
    }

    func recordModelDownloadFinished(
        id: String,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource,
        outcome: AnalyticsModelDownloadOutcome,
        duration: TimeInterval?,
        context: AnalyticsContext
    ) async {
        await self.writeDetailed(context: context) { database, date in
            try database.recordModelDownloadFinished(
                id: id,
                descriptor: descriptor,
                source: source,
                outcome: outcome,
                duration: duration,
                at: date
            )
        }
    }

    private func writeActivity(
        context: AnalyticsContext,
        operation: (AnalyticsDatabase, Date) throws -> Void
    ) async {
        guard context.config.isConfigured else { return }
        do {
            let database = try self.database(for: context)
            try operation(database, Date())
            self.startFlushLoopIfNeeded()
        } catch {
            return
        }
    }

    private func writeDetailed(
        context: AnalyticsContext,
        fallbackActivity: AnalyticsActivityKind? = nil,
        operation: (AnalyticsDatabase, Date) throws -> Void
    ) async {
        let mayRecordDetails = self.apply(context) && context.detailedAnalyticsEnabled
        guard context.config.isConfigured else { return }
        guard mayRecordDetails || fallbackActivity != nil else { return }
        do {
            let database = try self.database(for: context)
            let date = Date()
            if mayRecordDetails {
                try operation(database, date)
            } else if let fallbackActivity {
                try database.recordActivity(fallbackActivity, at: date)
            }
            self.startFlushLoopIfNeeded()
        } catch {
            return
        }
    }

    private func apply(_ context: AnalyticsContext) -> Bool {
        guard self.detailedConsentGate.accepts(context.detailedConsentGeneration) else { return false }
        self.context = context
        return true
    }

    private func database(for context: AnalyticsContext) throws -> AnalyticsDatabase {
        if let database { return database }
        let url = try self.databaseURL()
        let database = try AnalyticsDatabase(
            url: url,
            distinctID: context.distinctID,
            appVersion: context.appVersion
        )
        self.database = database
        return database
    }

    private func databaseURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryName = Bundle.main.bundleIdentifier ?? "FluidVoice"
        return applicationSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("Analytics", isDirectory: true)
            .appendingPathComponent("analytics-v2.sqlite3")
    }

    private func purgeStoredDetailedAnalyticsIfPresent(context: AnalyticsContext) throws {
        if let database {
            try database.purgeDetailedAnalytics()
            return
        }
        let url = try self.databaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existingDatabase = try AnalyticsDatabase(
            url: url,
            distinctID: context.distinctID,
            appVersion: context.appVersion
        )
        try existingDatabase.purgeDetailedAnalytics()
    }

    private func startFlushLoopIfNeeded() {
        guard self.flushTask == nil,
              let context,
              self.detailedConsentGate.accepts(context.detailedConsentGeneration),
              context.config.isConfigured
        else { return }
        self.flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.flushIfNeeded()
            }
        }
    }

    private func stopFlushLoop() {
        self.flushTask?.cancel()
        self.flushTask = nil
    }

    private func flushIfNeeded() async {
        guard !self.isFlushing,
              let context,
              self.detailedConsentGate.accepts(context.detailedConsentGeneration),
              context.config.isConfigured,
              let database
        else { return }

        self.isFlushing = true
        defer {
            self.activeUploadTask = nil
            self.isFlushing = false
        }

        let items: [AnalyticsOutboxItem]
        do {
            if context.detailedAnalyticsEnabled {
                try database.finalizeDays(before: Date())
            }
            items = try database.readyOutbox(limit: self.batchSize, at: Date())
        } catch {
            return
        }
        guard !items.isEmpty else { return }
        guard self.detailedConsentGate.accepts(context.detailedConsentGeneration) else { return }

        let ids = items.map(\.id)
        let uploadTask = Task {
            guard self.detailedConsentGate.accepts(context.detailedConsentGeneration) else {
                throw CancellationError()
            }
            return try await self.send(items: items, config: context.config)
        }
        self.activeUploadTask = uploadTask

        let status: Int
        do {
            status = try await uploadTask.value
        } catch {
            guard self.detailedConsentGate.accepts(context.detailedConsentGeneration) else { return }
            try? database.retry(ids: ids, at: Date())
            return
        }
        guard self.detailedConsentGate.accepts(context.detailedConsentGeneration) else { return }

        switch status {
        case 200..<300:
            try? database.acknowledgeUploaded(ids: ids, at: Date())
        case 408, 429, 500...599:
            try? database.retry(ids: ids, at: Date())
        default:
            try? database.discardPermanently(ids: ids)
        }
    }

    private func send(items: [AnalyticsOutboxItem], config: AnalyticsConfig) async throws -> Int {
        guard let url = URL(string: config.postHogHost)?.appendingPathComponent("batch") else {
            throw URLError(.badURL)
        }
        let batch = try items.map { item -> Any in
            try JSONSerialization.jsonObject(with: item.payload)
        }
        let body: [String: Any] = ["api_key": config.postHogApiKey, "batch": batch]
        let data = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return httpResponse.statusCode
    }
}
