import Foundation

/// A lightweight file-backed logger that mirrors in-app debug logs to disk for diagnostics.
final class FileLogger {
    static let shared = FileLogger()

    private let queue = DispatchQueue(label: "file.logger.queue", qos: .utility)
    private let fileManager = FileManager.default
    private let logDirectory: URL
    private let logFileURL: URL
    private let backupLogURL: URL
    private let maxLogFileSize: UInt64 = 1 * 1024 * 1024 // 1 MB limit per log file
    private let maxLogFileAge: TimeInterval = 72 * 60 * 60 // Rotate every 72 hours

    private init() {
        let baseDirectory = self.fileManager.urls(for: .libraryDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.logDirectory = baseDirectory.appendingPathComponent("Logs/Fluid", isDirectory: true)
        self.logFileURL = self.logDirectory.appendingPathComponent("fluid.log", isDirectory: false)
        self.backupLogURL = self.logDirectory.appendingPathComponent("fluid.log.1", isDirectory: false)

        self.queue.sync {
            self.createLogDirectoryIfNeeded()
            self.rotateIfNeeded(force: false)
        }
    }

    func append(line: String) {
        self.queue.async { [weak self] in
            guard let self = self else { return }
            self.createLogDirectoryIfNeeded()
            self.rotateIfNeeded(force: false)
            let data = (line + "\n").data(using: .utf8) ?? Data()
            if !self.fileManager.fileExists(atPath: self.logFileURL.path) {
                self.fileManager.createFile(atPath: self.logFileURL.path, contents: data)
            } else if let handle = try? FileHandle(forWritingTo: self.logFileURL) {
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    try? handle.close()
                }
            }
        }
    }

    func currentLogFileURL() -> URL {
        return self.logFileURL
    }

    // MARK: - Private helpers

    private func createLogDirectoryIfNeeded() {
        guard !self.fileManager.fileExists(atPath: self.logDirectory.path) else { return }
        do {
            try self.fileManager.createDirectory(at: self.logDirectory, withIntermediateDirectories: true)
        } catch {
            // If the directory cannot be created, fall back to /tmp
        }
    }

    private func rotateIfNeeded(force: Bool) {
        guard self.fileManager.fileExists(atPath: self.logFileURL.path) else { return }

        let shouldRotate: Bool
        if force {
            shouldRotate = true
        } else {
            let attributes = try? self.fileManager.attributesOfItem(atPath: self.logFileURL.path)
            let size = attributes?[.size] as? UInt64 ?? 0
            let modifiedDate = attributes?[.modificationDate] as? Date ?? Date()
            let ageExceedsLimit = Date().timeIntervalSince(modifiedDate) >= self.maxLogFileAge
            shouldRotate = size >= self.maxLogFileSize || ageExceedsLimit
        }

        guard shouldRotate else { return }

        // Remove existing backup if present
        if self.fileManager.fileExists(atPath: self.backupLogURL.path) {
            try? self.fileManager.removeItem(at: self.backupLogURL)
        }

        // Move current log to backup and create a fresh file
        try? self.fileManager.moveItem(at: self.logFileURL, to: self.backupLogURL)
        self.fileManager.createFile(atPath: self.logFileURL.path, contents: nil)
    }
}
