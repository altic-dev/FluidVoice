import Darwin
import Foundation

/// macOS reopens the apps that were running at logout or restart ("Reopen windows when logging
/// back in"). That relaunch carries no login-item Apple Event, so it is recognized by timing
/// instead: the process starts moments after the console login.
enum LoginSessionLaunch {
    /// Session restore relaunches apps within seconds of login; a minute covers a slow cold boot.
    nonisolated static let restoreWindow: TimeInterval = 60

    /// Unknown times are never treated as a restore, so a manual open always shows the window.
    nonisolated static func startedWithLoginSession(processStart: Date?, consoleLogin: Date?) -> Bool {
        guard let processStart, let consoleLogin else { return false }
        let elapsed = processStart.timeIntervalSince(consoleLogin)
        return elapsed >= 0 && elapsed <= self.restoreWindow
    }

    nonisolated static func currentProcessStartedWithLoginSession() -> Bool {
        self.startedWithLoginSession(
            processStart: self.currentProcessStartDate(),
            consoleLogin: self.consoleLoginDate()
        )
    }

    nonisolated static func currentProcessStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// When the current user logged in at the console, from the system login records.
    nonisolated static func consoleLoginDate() -> Date? {
        setutxent()
        defer { endutxent() }
        let userName = NSUserName()
        var login: Date?
        while let entry = getutxent() {
            let record = entry.pointee
            guard Int32(record.ut_type) == USER_PROCESS,
                  Self.string(record.ut_line) == "console",
                  Self.string(record.ut_user) == userName
            else { continue }
            login = Date(timeIntervalSince1970: TimeInterval(record.ut_tv.tv_sec))
        }
        return login
    }

    private nonisolated static func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) ?? "" }
    }
}
