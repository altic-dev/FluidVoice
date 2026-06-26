import Darwin
import Foundation

/// A lightweight file-backed logger that mirrors in-app debug logs to disk for diagnostics.
final class FileLogger {
    static let shared = FileLogger()

    private let queue = DispatchQueue(label: "file.logger.queue", qos: .utility)
    private let fileManager = FileManager.default
    private let logDirectory: URL
    private let logFileURL: URL
    private let backupLogURL: URL
    private let legacyLogFileURL: URL
    private let legacyBackupLogURL: URL
    private let maxLogFileSize: UInt64 = 1 * 1024 * 1024 // 1 MB limit per log file
    private let maxLogFileAge: TimeInterval = 72 * 60 * 60 // Rotate every 72 hours
    private static var crashFileDescriptor: Int32 = -1
    private static var crashHandlersInstalled = false
    private static let sigAbrtLine = Array("[CRASH] Fatal signal SIGABRT\n".utf8)
    private static let sigIllLine = Array("[CRASH] Fatal signal SIGILL\n".utf8)
    private static let sigSegvLine = Array("[CRASH] Fatal signal SIGSEGV\n".utf8)
    private static let sigBusLine = Array("[CRASH] Fatal signal SIGBUS\n".utf8)
    private static let sigTrapLine = Array("[CRASH] Fatal signal SIGTRAP\n".utf8)
    private static let sigUnknownLine = Array("[CRASH] Fatal signal UNKNOWN\n".utf8)

    private init() {
        let baseDirectory = self.fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.logDirectory = baseDirectory.appendingPathComponent("Logs/Fluid", isDirectory: true)
        self.logFileURL = self.logDirectory.appendingPathComponent("Fluid.log", isDirectory: false)
        self.backupLogURL = self.logDirectory.appendingPathComponent("Fluid.log.1", isDirectory: false)
        self.legacyLogFileURL = self.logDirectory.appendingPathComponent("fluid.log", isDirectory: false)
        self.legacyBackupLogURL = self.logDirectory.appendingPathComponent("fluid.log.1", isDirectory: false)

        self.queue.sync {
            self.createLogDirectoryIfNeeded()
            self.migrateLegacyLogFilesIfNeeded()
            self.rotateIfNeeded(force: false)
            self.prepareCrashLogging()
            self.appendRunMetadata()
        }
        self.installCrashHandlersIfNeeded()
    }

    func append(line: String) {
        self.queue.async { [weak self] in
            guard let self = self else { return }
            self.appendUnlocked(line: line)
        }
    }

    func appendSync(line: String) {
        self.queue.sync {
            self.appendUnlocked(line: line)
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

    private func migrateLegacyLogFilesIfNeeded() {
        if !self.fileManager.fileExists(atPath: self.logFileURL.path),
           self.fileManager.fileExists(atPath: self.legacyLogFileURL.path)
        {
            try? self.fileManager.moveItem(at: self.legacyLogFileURL, to: self.logFileURL)
        }

        if !self.fileManager.fileExists(atPath: self.backupLogURL.path),
           self.fileManager.fileExists(atPath: self.legacyBackupLogURL.path)
        {
            try? self.fileManager.moveItem(at: self.legacyBackupLogURL, to: self.backupLogURL)
        }
    }

    private func appendUnlocked(line: String) {
        self.createLogDirectoryIfNeeded()
        self.rotateIfNeeded(force: false)
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if !self.fileManager.fileExists(atPath: self.logFileURL.path) {
            self.fileManager.createFile(atPath: self.logFileURL.path, contents: data)
            self.prepareCrashLogging()
            return
        }
        guard let handle = try? FileHandle(forWritingTo: self.logFileURL) else {
            self.prepareCrashLogging()
            return
        }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
        self.prepareCrashLogging()
    }

    private func appendRunMetadata() {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let pid = ProcessInfo.processInfo.processIdentifier
        self.appendUnlocked(line: "[RUN] PID=\(pid) AppVersion=\(appVersion) Build=\(build) OS=\(osVersion)")
        self.appendUnlocked(line: "[RUN] Processed by \(Bundle.main.bundleIdentifier ?? "unknown")")
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
        self.prepareCrashLogging()
    }

    private func prepareCrashLogging() {
        if Self.crashFileDescriptor >= 0 {
            close(Self.crashFileDescriptor)
            Self.crashFileDescriptor = -1
        }
        Self.crashFileDescriptor = open(self.logFileURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
    }

    private func installCrashHandlersIfNeeded() {
        guard !Self.crashHandlersInstalled else { return }
        Self.crashHandlersInstalled = true

        NSSetUncaughtExceptionHandler { exception in
            let line = "[CRASH] Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "Unknown reason")"
            FileLogger.writeCrashLineDirect(line)
            if !exception.callStackSymbols.isEmpty {
                FileLogger.writeCrashLineDirect("[CRASH] Stack: \(exception.callStackSymbols.joined(separator: " | "))")
            }
        }

        signal(SIGABRT, fileLoggerSignalHandler)
        signal(SIGILL, fileLoggerSignalHandler)
        signal(SIGSEGV, fileLoggerSignalHandler)
        signal(SIGBUS, fileLoggerSignalHandler)
        signal(SIGTRAP, fileLoggerSignalHandler)
    }

    static func writeCrashSignalLine(_ signalNumber: Int32) {
        guard self.crashFileDescriptor >= 0 else { return }
        let bytes: [UInt8]
        switch signalNumber {
        case SIGABRT: bytes = Self.sigAbrtLine
        case SIGILL: bytes = Self.sigIllLine
        case SIGSEGV: bytes = Self.sigSegvLine
        case SIGBUS: bytes = Self.sigBusLine
        case SIGTRAP: bytes = Self.sigTrapLine
        default: bytes = Self.sigUnknownLine
        }
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = write(Self.crashFileDescriptor, baseAddress, rawBuffer.count)
        }
    }

    static func writeCrashLineDirect(_ line: String) {
        guard self.crashFileDescriptor >= 0 else { return }
        let message = line.hasSuffix("\n") ? line : "\(line)\n"
        message.withCString { ptr in
            _ = write(Self.crashFileDescriptor, ptr, strlen(ptr))
        }
    }
}

private func fileLoggerSignalHandler(_ signalNumber: Int32) {
    FileLogger.writeCrashSignalLine(signalNumber)
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}
