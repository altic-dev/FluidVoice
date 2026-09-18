import CryptoKit
import Foundation

// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§5): FluidVoice-side Nemotron model
// readiness. This locator only resolves and validates a local, already-installed model package.
// It never downloads, never guesses a hosting URL and never accepts a symlink — the 190 MB
// weights are delivered by a separate, not-yet-built preparation step, and `execute` performs no
// downloads.
//
// Resolution order: an injected URL (tests), then the development environment override
// `FLUIDVOICE_NEMOTRON_DIARIZATION_MODEL_PATH`, then the versioned FluidVoice cache location.
// `recheck` re-walks the package when it is opened and refuses a missing or changed artifact.

/// A validated local Nemotron model package plus the facts measured while validating it.
nonisolated struct MeetingNemotronModelArtifact: Equatable, Sendable {
    let packageURL: URL
    let totalByteCount: Int64
    let fileCount: Int
    /// SHA-256 of the package's `Manifest.json` — the package's own descriptor of its contents.
    let manifestSHA256: String
    /// Stable digest of every regular entry's relative path, logical size and modification time.
    /// This makes a same-size weight replacement visible without hashing 190 MB on the main actor.
    let entryMetadataSHA256: String
}

nonisolated enum MeetingNemotronModelReadinessError: LocalizedError, Equatable {
    /// Nothing exists at the resolved location.
    case modelNotInstalled(path: String)
    /// The resolved path fails package-structure validation. The payload is a stable diagnostic
    /// token, never a localized system string.
    case invalidModelPackage(reason: String)
    /// The package validated earlier no longer matches what is on disk now.
    case artifactChanged(path: String)

    var errorDescription: String? {
        switch self {
        case let .modelNotInstalled(path):
            return "The Nemotron diarization model is not installed at \(path). "
                + "Meeting model preparation has not run."
        case let .invalidModelPackage(reason):
            return "The Nemotron diarization model package is invalid (\(reason))."
        case let .artifactChanged(path):
            return "The Nemotron diarization model at \(path) changed since it was validated."
        }
    }
}

nonisolated protocol MeetingNemotronModelLocating: Sendable {
    func locate() throws -> MeetingNemotronModelArtifact
    /// Re-validates a previously located artifact before opening it. Any drift is a refusal.
    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact
}

nonisolated struct MeetingNemotronModelLocator: MeetingNemotronModelLocating {
    static let environmentOverrideKey = "FLUIDVOICE_NEMOTRON_DIARIZATION_MODEL_PATH"
    static let cacheVersion = "v1"
    static let packageFileName = "nemotron_diar_fp16.mlpackage"
    private static let maximumFileCount = 64
    private static let maximumTotalByteCount: Int64 = 1_000_000_000

    let injectedURL: URL?
    let environment: [String: String]

    init(
        injectedURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.injectedURL = injectedURL
        self.environment = environment
    }

    /// The versioned FluidVoice cache location used when nothing is injected or overridden.
    static func defaultPackageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("FluidVoice", isDirectory: true)
            .appendingPathComponent("MeetingModels", isDirectory: true)
            .appendingPathComponent("nemotron-3-diarization", isDirectory: true)
            .appendingPathComponent(Self.cacheVersion, isDirectory: true)
            .appendingPathComponent(Self.packageFileName, isDirectory: true)
    }

    func resolvedPackageURL() -> URL {
        if let injectedURL { return injectedURL }
        if let override = self.environment[Self.environmentOverrideKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return Self.defaultPackageURL()
    }

    func locate() throws -> MeetingNemotronModelArtifact {
        let url = self.resolvedPackageURL().standardizedFileURL
        return try Self.validatePackage(at: url)
    }

    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact {
        let current = try self.locate()
        guard current.packageURL == artifact.packageURL,
              current.totalByteCount == artifact.totalByteCount,
              current.fileCount == artifact.fileCount,
              current.manifestSHA256 == artifact.manifestSHA256,
              current.entryMetadataSHA256 == artifact.entryMetadataSHA256
        else {
            throw MeetingNemotronModelReadinessError.artifactChanged(path: artifact.packageURL.path)
        }
        return current
    }

    /// Structural validation of one package: a real directory (not a symlink) containing a real
    /// `Manifest.json` and at least one `model.mlmodel`, with no symlink anywhere inside it. A
    /// symlinked component would make the measured bytes describe a different file than CoreML
    /// later opens.
    static func validatePackage(at url: URL) throws -> MeetingNemotronModelArtifact {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else {
            throw MeetingNemotronModelReadinessError.modelNotInstalled(path: url.path)
        }
        guard type == .typeDirectory else {
            if type == .typeSymbolicLink {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageIsSymlink")
            }
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageNotDirectory")
        }
        guard url.resolvingSymlinksInPath().standardizedFileURL == url else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packagePathContainsSymlink")
        }

        var totalByteCount: Int64 = 0
        var fileCount = 0
        var hasManifest = false
        var hasModel = false
        var manifestSHA256 = ""
        var entryMetadata: [(path: String, size: Int, modified: TimeInterval)] = []

        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageUnreadable")
        }
        for case let entry as URL in enumerator {
            let values = try resourceValues(entry)
            if values.isSymbolicLink == true {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageContainsSymlink")
            }
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            guard fileCount <= Self.maximumFileCount else {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageHasTooManyFiles")
            }
            let logicalSize = values.fileSize ?? 0
            totalByteCount += Int64(logicalSize)
            guard totalByteCount <= Self.maximumTotalByteCount else {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageTooLarge")
            }
            let relativePath = String(entry.path.dropFirst(url.path.count + 1))
            entryMetadata.append((
                path: relativePath,
                size: logicalSize,
                modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
            if entry.lastPathComponent == "Manifest.json" {
                hasManifest = true
                manifestSHA256 = try Self.sha256Hex(contentsOf: entry)
            }
            if entry.lastPathComponent == "model.mlmodel" {
                hasModel = true
            }
        }
        guard hasManifest else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "manifestMissing")
        }
        guard hasModel else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "modelMissing")
        }
        guard fileCount > 0, totalByteCount > 0 else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageEmpty")
        }

        let metadataBytes = entryMetadata.sorted { $0.path < $1.path }.map {
            "\($0.path)\u{0}\($0.size)\u{0}\($0.modified.bitPattern)\n"
        }.joined()
        let entryMetadataSHA256 = SHA256.hash(data: Data(metadataBytes.utf8))
            .map { String(format: "%02x", $0) }.joined()

        return MeetingNemotronModelArtifact(
            packageURL: url,
            totalByteCount: totalByteCount,
            fileCount: fileCount,
            manifestSHA256: manifestSHA256,
            entryMetadataSHA256: entryMetadataSHA256
        )
    }

    private static func resourceValues(_ url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                .contentModificationDateKey,
            ])
        } catch {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "entryUnreadable")
        }
    }

    private static func sha256Hex(contentsOf url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "manifestUnreadable")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
