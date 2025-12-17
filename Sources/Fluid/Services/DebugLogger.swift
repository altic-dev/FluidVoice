import Combine
import Foundation
import SwiftUI

class DebugLogger: ObservableObject {
    static let shared = DebugLogger()

    @Published var logs: [LogEntry] = []
    private let maxLogs = 1000 // Keep last 1000 log entries
    private let queue = DispatchQueue(label: "debug.logger", qos: .utility)

    // IMPORTANT: Cached setting to avoid circular dependency with SettingsStore
    // During SettingsStore.init(), if an error is logged, accessing SettingsStore.shared
    // would cause a recursive dispatch_once deadlock. We use a cached value instead.
    private var _loggingEnabledCache: Bool?
    private var loggingEnabled: Bool {
        if let cached = _loggingEnabledCache {
            return cached
        }
        // Delay access to SettingsStore until after initial singleton setup
        // Use UserDefaults directly to avoid the circular dependency
        let enabled = UserDefaults.standard.bool(forKey: "EnableDebugLogs")
        self._loggingEnabledCache = enabled
        return enabled
    }

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let message: String
        let source: String
        let formattedTimestamp: String

        init(timestamp: Date, level: LogLevel, message: String, source: String, formattedTimestamp: String) {
            self.timestamp = timestamp
            self.level = level
            self.message = message
            self.source = source
            self.formattedTimestamp = formattedTimestamp
        }
    }

    enum LogLevel: String, CaseIterable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"

        var color: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .error: return .red
            case .debug: return .gray
            }
        }
    }

    private init() {}

    /// Refresh the cached logging setting (call after SettingsStore is fully initialized)
    func refreshLoggingEnabled() {
        self._loggingEnabledCache = UserDefaults.standard.bool(forKey: "EnableDebugLogs")
    }

    func log(_ message: String, level: LogLevel = .info, source: String = "App") {
        let loggingEnabled = self.loggingEnabled

        self.queue.async {
            let timestamp = Date()
            let timestampString = Self.logFormatter.string(from: timestamp)
            let entry: LogEntry? = loggingEnabled
                ? LogEntry(
                    timestamp: timestamp,
                    level: level,
                    message: message,
                    source: source,
                    formattedTimestamp: timestampString
                )
                : nil
            let formattedLine = entry.map(self.formatLogEntry)
                ?? self.formatLogLine(timestamp: timestampString, level: level, source: source, message: message)

            FileLogger.shared.append(line: formattedLine)

            if level == .error || level == .warning || level == .debug {
                // Also print to console for Xcode debugging
                print(formattedLine)
            }

            guard let entry = entry else { return }

            DispatchQueue.main.async {
                self.logs.append(entry)

                // Only trim when significantly above capacity to reduce churn
                if self.logs.count > self.maxLogs + 100 {
                    let excess = self.logs.count - self.maxLogs
                    if excess > 0 {
                        self.logs.removeFirst(excess)
                    }
                }
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }

    func exportLogs() -> String {
        return self.logs.map { entry in
            self.formatLogEntry(entry)
        }.joined(separator: "\n")
    }

    private func formatLogEntry(_ entry: LogEntry) -> String {
        self.formatLogLine(
            timestamp: entry.formattedTimestamp,
            level: entry.level,
            source: entry.source,
            message: entry.message
        )
    }

    private func formatLogLine(timestamp: String, level: LogLevel, source: String, message: String) -> String {
        "[\(timestamp)] [\(level.rawValue)] [\(source)] \(message)"
    }
}

// Convenience functions for easier logging
extension DebugLogger {
    func info(_ message: String, source: String = "App") {
        self.log(message, level: .info, source: source)
    }

    func warning(_ message: String, source: String = "App") {
        self.log(message, level: .warning, source: source)
    }

    func error(_ message: String, source: String = "App") {
        self.log(message, level: .error, source: source)
    }

    func debug(_ message: String, source: String = "App") {
        self.log(message, level: .debug, source: source)
    }
}
