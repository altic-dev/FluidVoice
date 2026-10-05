import Darwin
import Foundation

/// Installs only the descriptor's hash-pinned archive, without changing model selection.
nonisolated enum ParakeetArchiveDownloader {
    typealias Transport = @Sendable (URL, @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse)
    typealias RevisionWriter = @Sendable (URL, ParakeetSpeechModelCatalog.Descriptor) throws -> Void
    typealias CapacityReader = @Sendable (URL) throws -> Int64
    typealias StageValidator = @Sendable (URL) async throws -> Void
    private static let publicationLock = NSLock()

    private struct InstallationIO: Sendable {
        let transport: Transport?
        let capacityReader: CapacityReader?
        let revisionWriter: RevisionWriter
    }

    private struct InstalledIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let revision: String
    }

    enum DownloadError: LocalizedError {
        case invalidDescriptor, invalidResponse, checksumMismatch, invalidArchive, incompleteModel, targetExists
        case cleanupFailed(URL)
        case targetChanged
        case capacityUnavailable
        case insufficientSpace(required: Int64, available: Int64)
        case replacementCleanupFailed(installed: URL, retainedOld: URL)
        case updateFailedWithCleanup(reason: String, installed: URL, temporaryFiles: URL)

        var errorDescription: String? {
            switch self {
            case .invalidDescriptor: return "This voice model has no valid pinned download."
            case .invalidResponse: return "The model server did not return the expected archive. Please try again."
            case .checksumMismatch: return "The downloaded voice model failed verification. Please try again."
            case .invalidArchive: return "The voice model archive contains invalid or unsafe files."
            case .incompleteModel: return "The voice model archive is incomplete."
            case .targetExists: return "A different or incomplete voice model is already cached. Delete this model in Voice Engine settings, then download it again."
            case let .cleanupFailed(url): return "Voice model temporary files could not be removed: \(url.path)"
            case .capacityUnavailable: return "Available disk space could not be checked. Your installed model was kept. Please try again."
            case .insufficientSpace: return "There is not enough free disk space to safely update this voice model. Free some space and try again. Your installed model was kept."
            case .targetChanged: return "The installed voice model changed during this update. Its files were preserved. Please try again."
            case let .replacementCleanupFailed(installed, retainedOld): return "The updated voice model is installed at \(installed.path), but its old files could not be removed: \(retainedOld.path)"
            case let .updateFailedWithCleanup(reason, installed, temporaryFiles):
                return "The voice model update failed: \(reason). "
                    + "This update did not replace the installed model at \(installed.path). "
                    + "Temporary files could not be removed: \(temporaryFiles.path)"
            }
        }
    }

    static func ensurePresent(
        descriptor: ParakeetSpeechModelCatalog.Descriptor,
        in modelsDirectory: URL,
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void = { _ in },
        replaceExisting: Bool = false,
        stageValidator: StageValidator? = nil,
        transport: Transport? = nil,
        capacityReader: CapacityReader? = nil,
        revisionWriter: @escaping RevisionWriter = { directory, descriptor in try descriptor.writeInstallationRevision(at: directory) }
    ) async throws -> URL {
        let task = Task.detached(priority: .utility) {
            try await self.install(
                descriptor: descriptor,
                modelsDirectory: modelsDirectory,
                progressHandler: progressHandler,
                replaceExisting: replaceExisting,
                stageValidator: stageValidator,
                io: InstallationIO(transport: transport, capacityReader: capacityReader, revisionWriter: revisionWriter)
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func isCleanupFailure(_ error: Error) -> Bool {
        guard let failure = error as? DownloadError else { return false }
        if case .cleanupFailed = failure { return true }
        if case .replacementCleanupFailed = failure { return true }
        if case .updateFailedWithCleanup = failure { return true }
        return false
    }

    private static func install(
        descriptor: ParakeetSpeechModelCatalog.Descriptor,
        modelsDirectory: URL,
        progressHandler: @escaping @Sendable (ModelPreparationProgress) -> Void,
        replaceExisting: Bool,
        stageValidator: StageValidator?,
        io: InstallationIO
    ) async throws -> URL {
        let transport = io.transport
        let capacityReader = io.capacityReader
        let revisionWriter = io.revisionWriter
        try Task.checkCancellation()
        guard self.isComponent(descriptor.folderName), self.isComponent(descriptor.vocabularyFile),
              !descriptor.requiredModelNames.isEmpty,
              descriptor.requiredModelNames.allSatisfy(self.isComponent),
              Set(descriptor.requiredModelNames).count == descriptor.requiredModelNames.count,
              modelsDirectory.isFileURL
        else { throw DownloadError.invalidDescriptor }
        let manager = FileManager.default
        let target = descriptor.cacheDirectory(in: modelsDirectory)
        if self.pathExists(modelsDirectory) { try self.requireDirectory(modelsDirectory) }
        if self.artifactsAreComplete(at: target, descriptor: descriptor) {
            progressHandler(.loading)
            return target
        }
        guard let archiveURL = descriptor.archiveURL, archiveURL.scheme == "https", archiveURL.host != nil,
              let checksum = descriptor.archiveSHA256,
              checksum.count == 64, checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              descriptor.expectedDownloadBytes > 0, descriptor.expectedDownloadBytes <= 1_073_741_824
        else { throw DownloadError.invalidDescriptor }
        try manager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try self.requireDirectory(modelsDirectory)
        let original: InstalledIdentity?
        if self.pathExists(target) {
            guard replaceExisting else { throw DownloadError.targetExists }
            original = try self.installedIdentity(at: target, descriptor: descriptor)
        } else {
            original = nil
        }
        // The old model already consumes disk space; reserve both the tar and its unpacked copy.
        // Runs inside this detached installer, before transport or private staging is created.
        let headroom: Int64 = 32 * 1024 * 1024
        let required = descriptor.expectedDownloadBytes * 2 + headroom
        let available: Int64
        do {
            available = try (capacityReader ?? self.availableCapacity)(modelsDirectory)
        } catch {
            try Task.checkCancellation()
            throw DownloadError.capacityUnavailable
        }
        guard available >= 0 else { throw DownloadError.capacityUnavailable }
        guard available >= required else { throw DownloadError.insufficientSpace(required: required, available: available) }
        try Task.checkCancellation()
        let stage = modelsDirectory.appendingPathComponent(".\(descriptor.folderName)-\(UUID().uuidString).staging", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retainedDownload: URL?
        do {
            progressHandler(.preparingDownload)
            let transfer: Transport = transport ?? { _, progress in
                try await CompactSpeechModelArchiveTransport.download(descriptor: descriptor, in: modelsDirectory, progress: progress)
            }
            let (downloaded, response) = try await transfer(archiveURL) { bytes, _ in
                let bounded = max(0, min(bytes, descriptor.expectedDownloadBytes))
                progressHandler(.downloading(Double(bounded) / Double(descriptor.expectedDownloadBytes)))
            }
            retainedDownload = downloaded
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https",
                  try self.regularFileSize(downloaded) == descriptor.expectedDownloadBytes
            else { throw DownloadError.invalidResponse }
            let archive = stage.appendingPathComponent("archive.tar")
            try manager.moveItem(at: downloaded, to: archive)
            retainedDownload = nil
            guard try self.sha256(archive) == checksum else { throw DownloadError.checksumMismatch }
            progressHandler(.optimizing)
            let extraction = stage.appendingPathComponent("extracted", isDirectory: true)
            let extracted = try ParakeetArchiveInstaller.unpack(
                archive: archive,
                folderName: descriptor.folderName,
                staging: extraction,
                manifestSHA256: descriptor.manifestSHA256
            )
            guard self.contentsAreComplete(at: extracted, descriptor: descriptor) else { throw DownloadError.incompleteModel }
            try Task.checkCancellation()
            try revisionWriter(extracted, descriptor)
            try Task.checkCancellation()
            guard self.artifactsAreComplete(at: extracted, descriptor: descriptor) else { throw DownloadError.incompleteModel }
            if let stageValidator { try await stageValidator(extracted) }
            try Task.checkCancellation()
            guard self.artifactsAreComplete(at: extracted, descriptor: descriptor) else { throw DownloadError.incompleteModel }
            // Serialize only publication, not transfers or Core ML validation. Identity
            // and revision checks reject a competing completed update in this process.
            try self.publicationLock.withLock {
                try Task.checkCancellation()
                try self.requireDirectory(modelsDirectory)
                if let original {
                    guard try self.installedIdentity(at: target, descriptor: descriptor) == original else { throw DownloadError.targetChanged }
                }
                let result = extracted.withUnsafeFileSystemRepresentation { source in
                    target.withUnsafeFileSystemRepresentation { destination in
                        renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(original == nil ? RENAME_EXCL : RENAME_SWAP))
                    }
                }
                guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
        } catch {
            let originalError = error
            var cleanupFailure: DownloadError?
            if let retainedDownload {
                do { try manager.removeItem(at: retainedDownload) } catch { cleanupFailure = .cleanupFailed(retainedDownload) }
            }
            do { try manager.removeItem(at: stage) } catch { cleanupFailure = .cleanupFailed(stage) }
            if let cleanupFailure {
                if original != nil {
                    throw DownloadError.updateFailedWithCleanup(reason: originalError.localizedDescription, installed: target, temporaryFiles: stage)
                }
                throw cleanupFailure
            }
            throw originalError
        }
        do { try manager.removeItem(at: stage) } catch {
            if original != nil { throw DownloadError.replacementCleanupFailed(installed: target, retainedOld: stage) }
            throw DownloadError.cleanupFailed(stage)
        }
        progressHandler(.loading)
        return target
    }

    private static func availableCapacity(at directory: URL) throws -> Int64 {
        if let capacity = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           capacity >= 0 { return capacity }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let bytes = attributes[.systemFreeSize] as? NSNumber, bytes.int64Value >= 0 else {
            throw DownloadError.capacityUnavailable
        }
        return bytes.int64Value
    }

    private static func installedIdentity(at directory: URL, descriptor: ParakeetSpeechModelCatalog.Descriptor) throws -> InstalledIdentity {
        guard let revision = descriptor.installedArchiveSHA256(at: directory),
              self.contentsAreComplete(at: directory, descriptor: descriptor),
              let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber
        else {
            try Task.checkCancellation()
            throw DownloadError.targetChanged
        }
        return InstalledIdentity(device: device.uint64Value, inode: inode.uint64Value, revision: revision)
    }

    /// Mirrors compiled-artifact readiness while rejecting links anywhere in the tree.
    static func artifactsAreComplete(at directory: URL, descriptor: ParakeetSpeechModelCatalog.Descriptor) -> Bool {
        guard descriptor.installationRevisionMatches(at: directory),
              self.contentsAreComplete(at: directory, descriptor: descriptor)
        else { return false }
        if let manifestSHA256 = descriptor.manifestSHA256 {
            return descriptor.installedManifestSHA256(at: directory) == manifestSHA256
        }
        return true
    }

    private static func contentsAreComplete(at directory: URL, descriptor: ParakeetSpeechModelCatalog.Descriptor) -> Bool {
        do {
            try Task.checkCancellation()
            try self.requireDirectory(directory)
            let manager = FileManager.default
            var enumerationFailed = false
            guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }) else { return false }
            var count = 0
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                count += 1
                guard count <= 50_000 else { return false }
                let type = try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
                guard type == .typeDirectory || type == .typeRegular else { return false }
            }
            guard !enumerationFailed else { return false }
            guard try self.regularFileSize(directory.appendingPathComponent(descriptor.vocabularyFile)) > 0 else { return false }
            for name in descriptor.requiredModelNames {
                let model = directory.appendingPathComponent(name, isDirectory: true)
                try self.requireDirectory(model)
                for file in ["coremldata.bin", "metadata.json", "weights/weight.bin"] {
                    guard try self.regularFileSize(model.appendingPathComponent(file)) > 0 else { return false }
                }
            }
            return true
        } catch { return false }
    }

    private static func isComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func pathExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func requireDirectory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw DownloadError.invalidArchive
        }
    }

    private static func regularFileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? NSNumber else {
            throw DownloadError.invalidArchive
        }
        return size.int64Value
    }

    private static func sha256(_ url: URL) throws -> String {
        try ParakeetArchiveInstaller.sha256(of: url)
    }
}
