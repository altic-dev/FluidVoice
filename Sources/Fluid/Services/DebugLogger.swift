import Foundation

class DebugLogger {
    static let shared = DebugLogger()

    private let queue = DispatchQueue(label: "debug.logger", qos: .utility)

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    enum LogLevel: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }

    private init() {}

    func log(_ message: String, level: LogLevel = .info, source: String = "App") {
        self.queue.async {
            let timestamp = Date()
            let timestampString = Self.logFormatter.string(from: timestamp)

            let formattedLine = self.formatLogLine(timestamp: timestampString, level: level, source: source, message: message)

            // Always persist diagnostics so issues can be debugged even if UI debug mode is off.
            FileLogger.shared.append(line: formattedLine)
            print(formattedLine)
        }
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

    func benchmark(_ marker: String, message: String, source: String = "Benchmark") {
        let now = ProcessInfo.processInfo.systemUptime
        self.info("\(marker) t=\(String(format: "%.6f", now)) \(message)", source: source)
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
