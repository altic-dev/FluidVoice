import Combine
import CryptoKit
import Foundation

/// Only immutable signed release metadata reaches UI/provider lookup. Labels,
/// architecture, cache folders and artifact names always come from the app.
@MainActor
final class CompactSpeechModelReleaseCatalog: ObservableObject {
    typealias Descriptor = ParakeetSpeechModelCatalog.Descriptor
    typealias Variant = ParakeetSpeechModelCatalog.Variant
    typealias Fetcher = @Sendable () async throws -> Data

    nonisolated struct Snapshot: Equatable, Sendable {
        let revision: UInt64
        let descriptors: [Variant: Descriptor]
    }

    nonisolated enum CatalogError: Error {
        case oversized, invalidEnvelope, invalidSignature, invalidPayload, invalidRelease, invalidResponse, staleRelease
    }

    private nonisolated struct Envelope: Decodable {
        let schemaVersion: Int
        let payload: String
        let signature: String
    }

    private nonisolated struct Payload: Decodable {
        struct Model: Decodable {
            let variant: String
            let version: String
            let url: String
            let sha256: String
            let byteCount: Int64
        }

        let schemaVersion: Int
        let models: [Model]
    }

    static let shared = CompactSpeechModelReleaseCatalog()
    nonisolated static let manifestURL: URL = {
        guard let url = URL(string: "https://models.fluidvoice.app/parakeet/compact-models.json") else {
            preconditionFailure("Invalid compact model manifest URL")
        }
        return url
    }()

    nonisolated static let publicKeyBase64 = "W8u08HQORfqQsmfiGm8+w99Kut1DlVfyweA4WuFhc2c="
    nonisolated static let maximumManifestBytes = 16 * 1024
    @Published private(set) var snapshot = Snapshot(revision: 0, descriptors: [.mini: ParakeetSpeechModelCatalog.mini, .pico: ParakeetSpeechModelCatalog.pico])
    var revision: UInt64 { self.snapshot.revision }

    private let publicKey: Data
    private let cacheURL: URL?
    private let fetch: Fetcher
    private let refreshInterval: TimeInterval
    private var loadedCache = false
    private var lastCheck: Date?
    private var refreshTask: Task<Void, Never>?

    init(
        publicKey: Data = Data(base64Encoded: CompactSpeechModelReleaseCatalog.publicKeyBase64) ?? Data(),
        cacheURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FluidVoice/compact-model-catalog.json"),
        refreshInterval: TimeInterval = 6 * 60 * 60,
        fetch: @escaping Fetcher = { try await CompactSpeechModelReleaseCatalog.fetchManifest() }
    ) {
        self.publicKey = publicKey
        self.cacheURL = cacheURL
        self.refreshInterval = refreshInterval
        self.fetch = fetch
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

    /// Startup/Voice Engine events call this; rendering only reads the snapshot.
    /// Concurrent callers join one check, and failures preserve the last valid release.
    func refreshIfNeeded(force: Bool = false) async {
        if let refreshTask { await refreshTask.value; return }
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < self.refreshInterval { return }
        self.lastCheck = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            if !self.loadedCache {
                self.loadedCache = true
                if let cacheURL = self.cacheURL,
                   let cached = await Self.readCachedManifest(at: cacheURL),
                   let descriptors = try? Self.validate(cached, publicKey: self.publicKey)
                { try? self.apply(descriptors) }
            }
            do {
                let data = try await self.fetch()
                try Task.checkCancellation()
                let descriptors = try Self.validate(data, publicKey: self.publicKey)
                try self.apply(descriptors)
                if let cacheURL = self.cacheURL { await Self.writeCachedManifest(data, at: cacheURL) }
            } catch {
                // Offline, malformed or untrusted metadata cannot remove a usable model.
            }
            self.refreshTask = nil
        }
        self.refreshTask = task
        await task.value
    }

    private func apply(_ descriptors: [Variant: Descriptor]) throws {
        for variant in [Variant.mini, .pico] {
            guard let offered = descriptors[variant]?.archiveURL?.deletingLastPathComponent().lastPathComponent,
                  let current = self.snapshot.descriptors[variant]?.archiveURL?.deletingLastPathComponent().lastPathComponent,
                  !Self.versionIsOlder(offered, than: current)
            else { throw CatalogError.staleRelease }
        }
        guard descriptors != self.snapshot.descriptors else { return }
        self.snapshot = Snapshot(revision: self.snapshot.revision &+ 1, descriptors: descriptors)
    }

    nonisolated static func validate(_ data: Data, publicKey: Data) throws -> [Variant: Descriptor] {
        guard data.count <= self.maximumManifestBytes else { throw CatalogError.oversized }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.schemaVersion == 1,
              let payload = Data(base64Encoded: envelope.payload), payload.count <= self.maximumManifestBytes,
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        else { throw CatalogError.invalidEnvelope }
        guard key.isValidSignature(signature, for: payload) else { throw CatalogError.invalidSignature }
        guard String(data: payload, encoding: .utf8) != nil,
              let decoded = try? JSONDecoder().decode(Payload.self, from: payload), decoded.schemaVersion == 1,
              decoded.models.count == 2
        else { throw CatalogError.invalidPayload }
        var descriptors: [Variant: Descriptor] = [:]
        for model in decoded.models {
            guard let variant = Variant(rawValue: model.variant), variant == .mini || variant == .pico,
                  descriptors[variant] == nil, self.validVersion(model.version),
                  model.sha256.utf8.count == 64,
                  model.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  model.byteCount > 0, model.byteCount <= 600_000_000
            else { throw CatalogError.invalidRelease }
            let builtIn = ParakeetSpeechModelCatalog.descriptor(for: variant)
            guard let baseline = builtIn.archiveURL?.deletingLastPathComponent().lastPathComponent,
                  !self.versionIsOlder(model.version, than: baseline)
            else { throw CatalogError.staleRelease }
            let expectedURL = "https://models.fluidvoice.app/parakeet/fluid-\(variant.rawValue)/\(model.version)/\(builtIn.folderName).tar"
            guard model.url == expectedURL, let url = URL(string: expectedURL) else { throw CatalogError.invalidRelease }
            descriptors[variant] = builtIn.replacingArchive(url: url, sha256: model.sha256, byteCount: model.byteCount)
        }
        guard descriptors[.mini] != nil, descriptors[.pico] != nil else { throw CatalogError.invalidPayload }
        return descriptors
    }

    private nonisolated static func validVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        return version.utf8.count <= 32 && components.count == 3 && components.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 9 && $0.utf8.allSatisfy { (48...57).contains($0) }
                && ($0.count == 1 || $0.first != "0")
        }
    }

    /// Every component was bounded to nine ASCII digits before descriptor construction.
    private nonisolated static func versionIsOlder(_ offered: String, than current: String) -> Bool {
        guard self.validVersion(offered), self.validVersion(current) else { return true }
        let lhs = offered.split(separator: ".").compactMap { Int($0) }
        let rhs = current.split(separator: ".").compactMap { Int($0) }
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right
        }
        return false
    }

    @concurrent private static func fetchManifest() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: self.manifestURL)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.absoluteString == self.manifestURL.absoluteString,
              http.expectedContentLength <= Int64(self.maximumManifestBytes)
        else { throw CatalogError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < self.maximumManifestBytes else { throw CatalogError.oversized }
            data.append(byte)
        }
        return data
    }

    @concurrent private static func readCachedManifest(at url: URL) async -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= self.maximumManifestBytes,
              let input = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? input.close() }
        guard let data = try? input.read(upToCount: self.maximumManifestBytes + 1), data.count <= self.maximumManifestBytes else { return nil }
        return data
    }

    @concurrent private static func writeCachedManifest(_ data: Data, at url: URL) async {
        guard data.count <= self.maximumManifestBytes else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { /* Cache failure does not invalidate the checked in-memory release. */ }
    }
}

extension ParakeetSpeechModelCatalog.Descriptor {
    nonisolated func replacingArchive(url: URL?, sha256: String?, byteCount: Int64? = nil) -> Self {
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
            performanceRatings: self.performanceRatings
        )
    }
}
