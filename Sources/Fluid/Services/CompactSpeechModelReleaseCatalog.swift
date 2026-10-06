import Combine
import Darwin
import Foundation

/// UI/provider lookup reads immutable metadata; all feed and state IO happens off main.
@MainActor
final class CompactSpeechModelReleaseCatalog: ObservableObject {
    typealias Descriptor = ParakeetSpeechModelCatalog.Descriptor
    typealias Variant = ParakeetSpeechModelCatalog.Variant
    typealias Fetcher = @Sendable () async throws -> Data

    nonisolated struct Snapshot: Equatable, Sendable {
        let revision: UInt64
        let sequence: Int
        let descriptors: [Variant: Descriptor]
        let rejectedManifestHashes: Set<String>
    }

    private nonisolated struct StoredState: Codable, Sendable {
        let lastCheck: Date?
        let lastCheckSucceeded: Bool
        let rejectedManifestHashes: [String]
    }

    private nonisolated struct FeedCommit: Sendable {
        let payload: SpeechModelFeed.Payload
        let acceptedIncoming: Bool
    }

    private nonisolated enum CacheError: Error { case busy, invalidLock }

    static let shared = CompactSpeechModelReleaseCatalog()
    nonisolated static let manifestURL = CompactSpeechModelReleaseCatalog.fixedURL("https://models.fluidvoice.app/feed/v1/speech-models.json")
    nonisolated static let stagingURL = CompactSpeechModelReleaseCatalog.fixedURL("https://models.fluidvoice.app/feed/v1/speech-models-staging.json")
    nonisolated static let publicKeys = [
        "etCg9rPWJ81mB3XdJfKs2Y6QeuJjIIqCYfbYy40LRY4=",
        "Lf4aPkJzkEbu7nUj2Oh+ltoCePbPGXQMEMh+KfqtJvw=",
    ]
    nonisolated static let maximumManifestBytes = SpeechModelFeed.maximumEnvelopeBytes
    nonisolated static let supportedFormat = 1
    private nonisolated static let maximumRejectedReleases = 64
    @Published private(set) var snapshot = Snapshot(
        revision: 0,
        sequence: 0,
        descriptors: [.mini: ParakeetSpeechModelCatalog.mini, .pico: ParakeetSpeechModelCatalog.pico],
        rejectedManifestHashes: []
    )
    var revision: UInt64 { self.snapshot.revision }

    private let keys: [String]
    private let cacheURL: URL?
    private let stateURL: URL?
    private let fetch: Fetcher
    private let build: Int
    private let refreshInterval: TimeInterval
    private let retryInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let staging: Bool
    private var loadedCache = false
    private var loadTask: Task<Void, Never>?
    private var lastCheck: Date?
    private var lastCheckSucceeded = false
    private var rejectedOrder: [String] = []
    private var refreshTask: Task<Void, Never>?
    private var stateWriteTask: Task<Void, Never>?
    private var pendingState: StoredState?

    init(
        publicKeys: [String] = CompactSpeechModelReleaseCatalog.publicKeys,
        cacheURL: URL? = CompactSpeechModelReleaseCatalog.defaultCacheURL(),
        build: Int = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0,
        refreshInterval: TimeInterval = 24 * 60 * 60,
        retryInterval: TimeInterval = 60 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        fetch: Fetcher? = nil
    ) {
        self.keys = publicKeys
        self.cacheURL = cacheURL
        self.stateURL = cacheURL?.appendingPathExtension("state")
        self.build = build
        self.refreshInterval = refreshInterval
        self.retryInterval = retryInterval
        self.now = now
        self.staging = Self.usesStaging
        self.fetch = fetch ?? { try await Self.fetchManifest() }
    }

    func descriptor(for model: SettingsStore.SpeechModel) -> Descriptor? {
        switch model {
        case .fluidParakeetMini: self.descriptor(for: .mini)
        case .fluidParakeetPico: self.descriptor(for: .pico)
        default: nil
        }
    }

    func descriptor(for variant: Variant) -> Descriptor {
        self.snapshot.descriptors[variant] ?? ParakeetSpeechModelCatalog.descriptor(for: variant)
    }

    /// Event-driven checks join one worker. A failure never removes the last good feed.
    func refreshIfNeeded(force: Bool = false) async {
        if let refreshTask { await refreshTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadCacheIfNeeded()
            let date = self.now()
            let interval = self.lastCheckSucceeded ? self.refreshInterval : self.retryInterval
            if !force, !self.staging, let lastCheck = self.lastCheck {
                let elapsed = date.timeIntervalSince(lastCheck)
                if elapsed >= 0, elapsed < interval {
                    if self.pendingState != nil { await self.persistState() }
                    self.refreshTask = nil
                    return
                }
            }
            self.lastCheck = date
            do {
                let data = try await self.fetch()
                try Task.checkCancellation()
                if let cacheURL = self.cacheURL {
                    let commit = try await Self.commitFeed(data, at: cacheURL, publicKeys: self.keys, lastSequence: self.snapshot.sequence)
                    self.apply(commit.payload)
                    self.lastCheckSucceeded = commit.acceptedIncoming
                } else {
                    let payload = try await Self.verify(data, publicKeys: self.keys, lastSequence: self.snapshot.sequence)
                    self.apply(payload)
                    self.lastCheckSucceeded = true
                }
            } catch {
                self.lastCheckSucceeded = false
            }
            await self.persistState()
            self.refreshTask = nil
        }
        self.refreshTask = task
        await task.value
    }

    /// Only a staged model's load/sentence proof failure rejects a release; cancellation does not.
    func reject(manifestSHA256: String) async {
        guard Self.validHash(manifestSHA256) else { return }
        await self.loadCacheIfNeeded()
        if self.snapshot.rejectedManifestHashes.contains(manifestSHA256) {
            if self.pendingState != nil { await self.persistState() }
            return
        }
        self.rejectedOrder.append(manifestSHA256)
        if self.rejectedOrder.count > Self.maximumRejectedReleases {
            self.rejectedOrder.removeFirst(self.rejectedOrder.count - Self.maximumRejectedReleases)
        }
        self.snapshot = Snapshot(
            revision: self.snapshot.revision &+ 1,
            sequence: self.snapshot.sequence,
            descriptors: self.snapshot.descriptors,
            rejectedManifestHashes: Set(self.rejectedOrder)
        )
        await self.persistState()
    }

    private func loadCacheIfNeeded() async {
        if let loadTask { await loadTask.value; return }
        guard !self.loadedCache else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            if let stateURL = self.stateURL,
               let bytes = await Self.readBoundedData(at: stateURL),
               let state = await Self.decodeState(bytes)
            {
                self.lastCheck = state.lastCheck
                self.lastCheckSucceeded = state.lastCheckSucceeded
                self.rejectedOrder = state.rejectedManifestHashes
                self.snapshot = Snapshot(
                    revision: self.snapshot.revision &+ 1,
                    sequence: self.snapshot.sequence,
                    descriptors: self.snapshot.descriptors,
                    rejectedManifestHashes: Set(self.rejectedOrder)
                )
            }
            if let cacheURL = self.cacheURL,
               let bytes = await Self.readBoundedData(at: cacheURL),
               let payload = try? await Self.verify(bytes, publicKeys: self.keys, lastSequence: 0)
            {
                self.apply(payload)
            } else if self.lastCheckSucceeded {
                // Missing/corrupt last-good metadata cannot suppress a recovery fetch for a day.
                self.lastCheck = nil
                self.lastCheckSucceeded = false
            }
            self.loadedCache = true
            self.loadTask = nil
        }
        self.loadTask = task
        await task.value
    }

    private func apply(_ payload: SpeechModelFeed.Payload) {
        let descriptors = Self.descriptors(in: payload, build: self.build)
        guard self.snapshot.sequence != payload.sequence || descriptors != self.snapshot.descriptors else { return }
        self.snapshot = Snapshot(
            revision: self.snapshot.revision &+ 1,
            sequence: payload.sequence,
            descriptors: descriptors,
            rejectedManifestHashes: self.snapshot.rejectedManifestHashes
        )
    }

    nonisolated static func descriptors(in payload: SpeechModelFeed.Payload, build: Int) -> [Variant: Descriptor] {
        var result: [Variant: Descriptor] = [:]
        for variant in [Variant.mini, .pico] {
            let builtIn = ParakeetSpeechModelCatalog.descriptor(for: variant)
            if let entry = SpeechModelFeed.entry(in: payload, model: variant.rawValue, platform: "macos", build: build, supportedFormat: self.supportedFormat) {
                result[variant] = builtIn.replacingArchive(url: entry.url, sha256: entry.sha256, byteCount: entry.bytes, manifestSHA256: entry.manifestSHA256)
            } else {
                result[variant] = builtIn
            }
        }
        return result
    }

    private func persistState() async {
        guard let stateURL = self.stateURL else { return }
        self.pendingState = StoredState(
            lastCheck: self.lastCheck,
            lastCheckSucceeded: self.lastCheckSucceeded,
            rejectedManifestHashes: self.rejectedOrder
        )
        if let stateWriteTask { await stateWriteTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            while let state = self.pendingState {
                self.pendingState = nil
                if let stored = await Self.writeState(state, at: stateURL) {
                    // A competing process may have remembered another failed release.
                    let merged = Self.mergedRejections(stored.rejectedManifestHashes, self.rejectedOrder)
                    self.rejectedOrder = merged
                    if Set(merged) != self.snapshot.rejectedManifestHashes {
                        self.snapshot = Snapshot(
                            revision: self.snapshot.revision &+ 1,
                            sequence: self.snapshot.sequence,
                            descriptors: self.snapshot.descriptors,
                            rejectedManifestHashes: Set(merged)
                        )
                    }
                } else {
                    // Keep one latest state for the next event; never spin on a busy/broken volume.
                    if self.pendingState == nil { self.pendingState = state }
                    break
                }
            }
            self.stateWriteTask = nil
        }
        self.stateWriteTask = task
        await task.value
    }

    private nonisolated static var usesStaging: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--fv-model-feed=staging")
        #else
        false
        #endif
    }

    private nonisolated static func defaultCacheURL() -> URL? {
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let folder = self.cacheFolderName(bundleIdentifier: Bundle.main.bundleIdentifier, isDebug: isDebug)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(self.usesStaging ? "speech-model-feed-staging.json" : "speech-model-feed.json")
    }

    nonisolated static func cacheFolderName(bundleIdentifier: String?, isDebug: Bool) -> String {
        guard isDebug else { return "FluidVoice" }
        let identifier = bundleIdentifier ?? "debug"
        let valid = !identifier.isEmpty && identifier != "." && identifier != ".."
            && identifier.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }
        return "FluidVoice/\(valid ? identifier : "debug")"
    }

    private nonisolated static func fixedURL(_ value: String) -> URL {
        guard let url = URL(string: value) else { preconditionFailure("Invalid speech model feed URL") }
        return url
    }

    private nonisolated static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    @concurrent private static func verify(_ data: Data, publicKeys: [String], lastSequence: Int) async throws -> SpeechModelFeed.Payload {
        try SpeechModelFeed.verified(envelope: data, publicKeys: publicKeys, lastSequence: lastSequence)
    }

    private final nonisolated class NoRedirects: NSObject, URLSessionTaskDelegate {
        nonisolated func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    @concurrent private static func fetchManifest() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: self.usesStaging ? self.stagingURL : self.manifestURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= Int64(self.maximumManifestBytes)
        else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < self.maximumManifestBytes else { throw SpeechModelFeed.Rejection.tooLarge }
            data.append(byte)
        }
        return data
    }

    @concurrent private static func readBoundedData(at url: URL) async -> Data? {
        self.readData(at: url)
    }

    private nonisolated static func readData(at url: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= self.maximumManifestBytes,
              let input = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? input.close() }
        guard let data = try? input.read(upToCount: self.maximumManifestBytes + 1), data.count <= self.maximumManifestBytes else { return nil }
        return data
    }

    @concurrent private static func decodeState(_ data: Data) async -> StoredState? {
        self.validatedState(data)
    }

    private nonisolated static func validatedState(_ data: Data) -> StoredState? {
        guard let state = try? JSONDecoder().decode(StoredState.self, from: data),
              state.rejectedManifestHashes.count <= self.maximumRejectedReleases,
              state.rejectedManifestHashes.allSatisfy(self.validHash),
              Set(state.rejectedManifestHashes).count == state.rejectedManifestHashes.count
        else { return nil }
        return state
    }

    private nonisolated static func writeData(_ data: Data, at url: URL) throws {
        guard data.count <= self.maximumManifestBytes else { throw SpeechModelFeed.Rejection.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// No network work is performed while locked. Contention exits immediately for a later retry.
    private nonisolated static func withCacheLock<T>(at cacheURL: URL, operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = cacheURL.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else { throw CacheError.invalidLock }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CacheError.busy }
        defer { flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try operation()
    }

    @concurrent private static func commitFeed(_ data: Data, at url: URL, publicKeys: [String], lastSequence: Int) async throws -> FeedCommit {
        try self.withCacheLock(at: url) {
            let stored = self.readData(at: url).flatMap { try? SpeechModelFeed.verified(envelope: $0, publicKeys: publicKeys, lastSequence: 0) }
            let payload = try SpeechModelFeed.verified(envelope: data, publicKeys: publicKeys, lastSequence: 0)
            let floor = max(lastSequence, stored?.sequence ?? 0)
            if payload.sequence < floor {
                guard let stored, stored.sequence >= lastSequence else { throw SpeechModelFeed.Rejection.staleSequence }
                return FeedCommit(payload: stored, acceptedIncoming: false)
            }
            try Task.checkCancellation()
            try self.writeData(data, at: url)
            return FeedCommit(payload: payload, acceptedIncoming: true)
        }
    }

    private nonisolated static func mergedRejections(_ stored: [String], _ incoming: [String]) -> [String] {
        var result: [String] = []
        for hash in stored + incoming {
            result.removeAll { $0 == hash }
            result.append(hash)
        }
        return Array(result.suffix(self.maximumRejectedReleases))
    }

    @concurrent private static func writeState(_ state: StoredState, at url: URL) async -> StoredState? {
        for attempt in 0..<3 {
            do {
                return try self.mergeState(state, at: url)
            } catch CacheError.busy {
                guard attempt < 2, !Task.isCancelled else { return nil }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
            } catch {
                return nil
            }
        }
        return nil
    }

    private nonisolated static func mergeState(_ state: StoredState, at url: URL) throws -> StoredState {
        try self.withCacheLock(at: url.deletingPathExtension()) {
            let stored = self.readData(at: url).flatMap(self.validatedState)
            let freshness: StoredState
            if let storedDate = stored?.lastCheck,
               state.lastCheck == nil || storedDate > (state.lastCheck ?? .distantPast)
            {
                freshness = stored ?? state
            } else {
                freshness = state
            }
            let succeeded = stored?.lastCheck == state.lastCheck
                ? state.lastCheckSucceeded && (stored?.lastCheckSucceeded ?? true)
                : freshness.lastCheckSucceeded
            let merged = StoredState(
                lastCheck: freshness.lastCheck,
                lastCheckSucceeded: succeeded,
                rejectedManifestHashes: self.mergedRejections(stored?.rejectedManifestHashes ?? [], state.rejectedManifestHashes)
            )
            try Task.checkCancellation()
            try self.writeData(JSONEncoder().encode(merged), at: url)
            return merged
        }
    }
}

extension ParakeetSpeechModelCatalog.Descriptor {
    nonisolated func replacingArchive(url: URL?, sha256: String?, byteCount: Int64? = nil, manifestSHA256: String? = nil) -> Self {
        let bytes = byteCount ?? self.expectedDownloadBytes
        return Self(
            modelID: self.modelID,
            variant: self.variant,
            folderName: self.folderName,
            expectedDownloadBytes: bytes,
            archiveURL: url,
            archiveSHA256: sha256,
            requiredModelNames: self.requiredModelNames,
            vocabularyFile: self.vocabularyFile,
            displayName: self.displayName,
            humanReadableName: self.humanReadableName,
            languageSupport: self.languageSupport,
            supportedLanguageCodes: self.supportedLanguageCodes,
            downloadSize: String(format: "~%.1f MiB", Double(bytes) / 1_048_576),
            cardDescription: self.cardDescription,
            performanceRatings: self.performanceRatings,
            manifestSHA256: manifestSHA256
        )
    }
}
