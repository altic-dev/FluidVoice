import Darwin
import Foundation

/// Copies the incoming bundle, then exchanges it atomically with the installed bundle.
/// The caller validates `stagedAppURL` and saves its durable rollback backup before commit.
/// All methods perform disk IO and must run outside the main actor.
final nonisolated class UpdateAppReplacement: @unchecked Sendable {
    nonisolated struct Operations: Sendable {
        var createDirectory: @Sendable (URL) throws -> Void
        var copyBundle: @Sendable (URL, URL) throws -> Void
        var exchangeBundles: @Sendable (URL, URL) throws -> Void
        var removeDirectory: @Sendable (URL) throws -> Void

        static let live = Operations(
            createDirectory: { url in
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            },
            copyBundle: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            },
            exchangeBundles: { installed, staged in
                let result = installed.withUnsafeFileSystemRepresentation { installedPath in
                    staged.withUnsafeFileSystemRepresentation { stagedPath in
                        renameatx_np(AT_FDCWD, installedPath, AT_FDCWD, stagedPath, UInt32(RENAME_SWAP))
                    }
                }
                guard result == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            },
            removeDirectory: { url in
                do {
                    try FileManager.default.removeItem(at: url)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Cleanup is idempotent after a completed prior attempt.
                }
            }
        )
    }

    nonisolated enum Operation: String, Sendable {
        case preparation, commit, recovery, cleanup
    }

    nonisolated struct Failure: LocalizedError {
        let operation: Operation
        let recoveryDirectoryURL: URL?
        let underlyingError: Error

        var errorDescription: String? {
            let recovery = self.recoveryDirectoryURL.map { " Recovery files: \($0.path)." } ?? ""
            return "App replacement \(self.operation.rawValue) failed: \(self.underlyingError.localizedDescription).\(recovery)"
        }
    }

    private enum State {
        case prepared, committed, restored, discarded, finalized
    }

    let installedAppURL: URL
    let stagedAppURL: URL
    let stagingDirectoryURL: URL
    /// After commit this contains the outgoing bundle, until recovery or finalization.
    var recoveryAppURL: URL { self.stagedAppURL }
    private let operations: Operations
    private var processLock: ProcessLock?
    private let installedIdentity: BundleIdentity
    private var stagedIdentity: BundleIdentity?
    private let lock = NSLock()
    private var state = State.prepared

    private init(installedAppURL: URL, stagingDirectoryURL: URL, operations: Operations, processLock: ProcessLock, installedIdentity: BundleIdentity) {
        self.installedAppURL = installedAppURL
        self.stagingDirectoryURL = stagingDirectoryURL
        self.stagedAppURL = stagingDirectoryURL.appendingPathComponent(installedAppURL.lastPathComponent, isDirectory: true)
        self.operations = operations
        self.processLock = processLock
        self.installedIdentity = installedIdentity
    }

    static func prepare(
        installedAppURL: URL,
        replacementAppURL: URL,
        validateInstalledApp: (@Sendable (URL) throws -> Void)? = nil,
        operations: Operations = .live
    ) throws -> UpdateAppReplacement {
        try self.requireRealBundleDirectory(installedAppURL)
        try self.requireRealBundleDirectory(replacementAppURL)
        // A retained recovery/cleanup directory blocks another attempt rather than
        // accumulating new copies or destroying recovery files from a prior attempt.
        let directory = installedAppURL.deletingLastPathComponent()
            .appendingPathComponent(".fluidvoice-update-\(installedAppURL.lastPathComponent).staging", isDirectory: true)
        let processLock = try ProcessLock(installedAppURL: installedAppURL)
        let transaction = try UpdateAppReplacement(
            installedAppURL: installedAppURL,
            stagingDirectoryURL: directory,
            operations: operations,
            processLock: processLock,
            installedIdentity: BundleIdentity(installedAppURL)
        )
        var createdDirectory = false
        do {
            // Revalidate under the process-shared lock, including normal attempts.
            try validateInstalledApp?(installedAppURL)
            if FileManager.default.fileExists(atPath: directory.path) {
                try transaction.discardStaleStage(validateInstalledApp: validateInstalledApp)
            }
            try operations.createDirectory(directory)
            createdDirectory = true
            try transaction.ownershipData.write(to: transaction.ownershipURL, options: .atomic)
            try operations.copyBundle(replacementAppURL, transaction.stagedAppURL)
            transaction.stagedIdentity = try BundleIdentity(transaction.stagedAppURL)
            return transaction
        } catch {
            guard createdDirectory else {
                throw Failure(
                    operation: .preparation,
                    recoveryDirectoryURL: FileManager.default.fileExists(atPath: directory.path) ? directory : nil,
                    underlyingError: error
                )
            }
            do {
                try operations.removeDirectory(directory)
            } catch let cleanupError {
                throw Failure(operation: .cleanup, recoveryDirectoryURL: directory, underlyingError: cleanupError)
            }
            throw Failure(operation: .preparation, recoveryDirectoryURL: nil, underlyingError: error)
        }
    }

    /// No delete/move fallback: exchange failure leaves the installed bundle in place.
    func commit() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state == .prepared else { throw self.invalidState(.commit) }
        do {
            try Self.requireRealBundleDirectory(self.installedAppURL)
            try Self.requireRealBundleDirectory(self.stagedAppURL)
            guard try BundleIdentity(self.installedAppURL) == self.installedIdentity,
                  try BundleIdentity(self.stagedAppURL) == self.stagedIdentity
            else { throw CocoaError(.fileWriteFileExists) }
            try self.operations.exchangeBundles(self.installedAppURL, self.stagedAppURL)
            self.state = .committed
        } catch {
            throw Failure(operation: .commit, recoveryDirectoryURL: self.stagingDirectoryURL, underlyingError: error)
        }
    }

    /// Cancels staging after validation/backup/commit failure without touching the installed app.
    func discardPrepared() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state == .prepared || self.state == .discarded else { throw self.invalidState(.cleanup) }
        guard self.processLock != nil else { return }
        self.state = .discarded
        try self.cleanup()
    }

    /// Restores the outgoing app after a failed relaunch. A failed exchange retains it for retry.
    func recover() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.state == .committed {
            do {
                guard try BundleIdentity(self.installedAppURL) == self.stagedIdentity,
                      try BundleIdentity(self.stagedAppURL) == self.installedIdentity
                else { throw CocoaError(.fileWriteFileExists) }
                try self.operations.exchangeBundles(self.installedAppURL, self.stagedAppURL)
                self.state = .restored
            } catch {
                throw Failure(operation: .recovery, recoveryDirectoryURL: self.stagingDirectoryURL, underlyingError: error)
            }
        } else if self.state != .restored {
            throw self.invalidState(.recovery)
        }
        guard self.processLock != nil else { return }
        try self.cleanup()
    }

    /// Call only after successful relaunch, with a durable precommit backup already retained.
    /// Recursive cleanup can partially fail; it must never trigger recovery afterward.
    func finalize() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state == .committed || self.state == .finalized else { throw self.invalidState(.cleanup) }
        guard self.processLock != nil else { return }
        self.state = .finalized
        try self.cleanup()
    }

    private func cleanup() throws {
        do {
            try self.operations.removeDirectory(self.stagingDirectoryURL)
            self.processLock = nil
        } catch {
            throw Failure(operation: .cleanup, recoveryDirectoryURL: self.stagingDirectoryURL, underlyingError: error)
        }
    }

    private func invalidState(_ operation: Operation) -> Failure {
        Failure(
            operation: operation,
            recoveryDirectoryURL: self.stagingDirectoryURL,
            underlyingError: CocoaError(.fileWriteUnknown)
        )
    }

    private var ownershipURL: URL { self.stagingDirectoryURL.appendingPathComponent("ownership") }
    private var ownershipData: Data {
        Data("FluidVoiceUpdateStage-v1\n\(self.installedAppURL.standardizedFileURL.path)\n".utf8)
    }

    private func discardStaleStage(validateInstalledApp: (@Sendable (URL) throws -> Void)?) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: self.stagingDirectoryURL.path)
        let markerAttributes = try FileManager.default.attributesOfItem(atPath: self.ownershipURL.path)
        guard validateInstalledApp != nil,
              attributes[.type] as? FileAttributeType == .typeDirectory,
              markerAttributes[.type] as? FileAttributeType == .typeRegular,
              (markerAttributes[.size] as? NSNumber)?.intValue == self.ownershipData.count,
              try Data(contentsOf: self.ownershipURL) == self.ownershipData
        else { throw CocoaError(.fileWriteFileExists) }
        // Installed validation already passed under this lock. Remove this one known
        // orphan only; no other sibling bundles or recovery paths are enumerated.
        try self.operations.removeDirectory(self.stagingDirectoryURL)
    }

    private static func requireRealBundleDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard url.isFileURL, url.pathExtension == "app", attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileReadInvalidFileName)
        }
    }

    private struct BundleIdentity: Equatable, Sendable {
        private let device: dev_t
        private let inode: ino_t

        init(_ url: URL) throws {
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else { throw CocoaError(.fileReadInvalidFileName) }
            self.device = status.st_dev
            self.inode = status.st_ino
        }
    }

    /// The lock file is intentionally retained: unlinking it could let another
    /// process lock a different inode while this transaction still owns the old one.
    private final class ProcessLock {
        private let descriptor: Int32

        init(installedAppURL: URL) throws {
            let url = installedAppURL.deletingLastPathComponent()
                .appendingPathComponent(".fluidvoice-update-\(installedAppURL.lastPathComponent).lock")
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            }
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  status.st_uid == geteuid(), status.st_nlink == 1
            else {
                Darwin.close(descriptor)
                throw CocoaError(.fileWriteInvalidFileName)
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                Darwin.close(descriptor)
                throw error
            }
            self.descriptor = descriptor
        }

        deinit {
            Darwin.close(self.descriptor)
        }
    }
}
