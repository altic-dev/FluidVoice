import Foundation

/// Called while the app replacement's process-shared lock is held.
/// Disk and signature work must run outside the main actor.
nonisolated enum UpdateRollbackBackup {
    struct Operations: Sendable {
        var createDirectory: @Sendable (URL) throws -> Void
        var copyBundle: @Sendable (URL, URL) throws -> Void
        var publishBundle: @Sendable (URL, URL) throws -> Void
        var removeDirectory: @Sendable (URL) throws -> Void

        static let live = Operations(
            createDirectory: { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            },
            copyBundle: { source, destination in try FileManager.default.copyItem(at: source, to: destination) },
            publishBundle: { source, destination in try FileManager.default.moveItem(at: source, to: destination) },
            removeDirectory: { url in
                do {
                    try FileManager.default.removeItem(at: url)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {}
            }
        )
    }

    struct Failure: LocalizedError {
        let retainedDirectoryURL: URL?
        let underlyingError: Error

        var errorDescription: String? {
            let retained = self.retainedDirectoryURL.map { " Retained backup files: \($0.path)." } ?? ""
            return "The current app could not be backed up. Nothing was replaced.\(retained) \(self.underlyingError.localizedDescription)"
        }
    }

    static func create(
        installedAppURL: URL,
        backupURL: URL,
        validate: @Sendable (URL) throws -> Void,
        operations: Operations = .live
    ) throws {
        let manager = FileManager.default
        let root = backupURL.deletingLastPathComponent()
        let directory = root.appendingPathComponent(".fluidvoice-backup-\(installedAppURL.lastPathComponent).staging", isDirectory: true)
        let marker = directory.appendingPathComponent("ownership")
        let ownership = Data("FluidVoiceRollbackBackup-v1\n\(installedAppURL.standardizedFileURL.path)\n".utf8)
        let stagedBundle = directory.appendingPathComponent(installedAppURL.lastPathComponent, isDirectory: true)
        var createdDirectory = false
        do {
            guard installedAppURL.isFileURL, backupURL.isFileURL,
                  installedAppURL.pathExtension == "app", backupURL.pathExtension == "app"
            else { throw CocoaError(.fileWriteInvalidFileName) }
            // Recheck before removing any owned crash leftovers. The supplied validator
            // must enforce the running app's identity, version, build and trusted signature.
            try validate(installedAppURL)
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if manager.fileExists(atPath: directory.path) {
                let attributes = try manager.attributesOfItem(atPath: directory.path)
                let markerAttributes = try manager.attributesOfItem(atPath: marker.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      markerAttributes[.type] as? FileAttributeType == .typeRegular,
                      (markerAttributes[.size] as? NSNumber)?.intValue == ownership.count,
                      try Data(contentsOf: marker) == ownership
                else { throw CocoaError(.fileWriteFileExists) }
                try operations.removeDirectory(directory)
            }
            try operations.createDirectory(directory)
            createdDirectory = true
            try ownership.write(to: marker, options: .atomic)
            try operations.copyBundle(installedAppURL, stagedBundle)
            try validate(stagedBundle)
            // Same-filesystem publication is exclusive: an existing backup is never replaced.
            try operations.publishBundle(stagedBundle, backupURL)
        } catch {
            let originalError = error
            if createdDirectory {
                do {
                    try operations.removeDirectory(directory)
                } catch {
                    throw Failure(retainedDirectoryURL: directory, underlyingError: error)
                }
            }
            throw Failure(
                retainedDirectoryURL: manager.fileExists(atPath: directory.path) ? directory : nil,
                underlyingError: originalError
            )
        }
        do {
            try operations.removeDirectory(directory)
        } catch {
            throw Failure(retainedDirectoryURL: directory, underlyingError: error)
        }
    }
}
