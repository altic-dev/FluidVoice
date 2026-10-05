import Foundation

/// Processes the tests started, killed before a failing exit so none outlive the run.
private var spawnedPIDs: [pid_t] = []

private func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        spawnedPIDs.forEach { kill($0, SIGKILL) }
        exit(1)
    }
    print("ok: \(message)")
}

private func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

/// Killed processes are reparented to launchd and reaped shortly after, so give them a moment.
private func waitUntilGone(_ pid: pid_t) async -> Bool {
    for _ in 0..<40 {
        if !isAlive(pid) { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

private func readPID(_ url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return nil }
    spawnedPIDs.append(pid)
    return pid
}

@main
enum TerminalServiceTests {
    static func main() async {
        let service = TerminalService()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidvoice-terminal-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let result = await service.execute(command: "echo hello", timeout: 5)
            expect(result.success && result.output == "hello" && result.error == nil, "plain command is unaffected")
        }

        do {
            // The shell exits at once, but a background descendant inherits stdout
            // and stderr. Before the fix this returned only when sleep exited.
            let pidFile = directory.appendingPathComponent("descendant.pid")
            let started = Date()
            let result = await service.execute(
                command: "sleep 20 & echo $! > '\(pidFile.path)'; echo started",
                timeout: 1
            )
            let elapsed = Date().timeIntervalSince(started)
            guard let pid = readPID(pidFile) else { return expect(false, "descendant pid recorded") }
            expect(elapsed < 5, "returns shortly after the timeout when a descendant holds the pipes (\(elapsed)s)")
            expect(result.output == "started", "keeps output written before the timeout")
            expect(!result.success, "a timed-out command is not a success even though the shell exited 0")
            expect(result.error?.contains("Timed out after 1s") == true, "reports the timeout")
            let gone = await waitUntilGone(pid)
            expect(gone, "descendant holding the pipes is killed")
        }

        do {
            // Only stderr is held open, so the stdout read finishes first and the
            // timeout has to stay armed through the stderr read.
            let pidFile = directory.appendingPathComponent("stderr-holder.pid")
            let started = Date()
            let result = await service.execute(
                command: "sleep 20 > /dev/null & echo $! > '\(pidFile.path)'; echo diagnostic >&2",
                timeout: 1
            )
            let elapsed = Date().timeIntervalSince(started)
            guard let pid = readPID(pidFile) else { return expect(false, "stderr holder pid recorded") }
            expect(elapsed < 5, "returns shortly after the timeout when only stderr is held open (\(elapsed)s)")
            expect(result.error == "diagnostic\nTimed out after 1s.", "keeps stderr and appends the timeout note")
            let gone = await waitUntilGone(pid)
            expect(gone, "process holding only stderr is killed")
        }

        do {
            // Still running at the timeout: the shell and its child both stop.
            let pidFile = directory.appendingPathComponent("child.pid")
            let started = Date()
            let result = await service.execute(
                command: "sleep 20 & echo $! > '\(pidFile.path)'; wait",
                timeout: 1
            )
            let elapsed = Date().timeIntervalSince(started)
            guard let pid = readPID(pidFile) else { return expect(false, "child pid recorded") }
            expect(elapsed < 5, "returns shortly after the timeout while the shell is still running (\(elapsed)s)")
            expect(!result.success, "a command stopped by the timeout is not a success")
            let gone = await waitUntilGone(pid)
            expect(gone, "child of a timed-out shell is killed")
        }

        do {
            // A descendant that ignores SIGTERM gets SIGKILL after the grace period.
            let pidFile = directory.appendingPathComponent("stubborn.pid")
            let started = Date()
            _ = await service.execute(
                command: "/bin/sh -c 'trap \"\" TERM; echo $$ > \"\(pidFile.path)\"; exec sleep 20' & echo started",
                timeout: 1
            )
            let elapsed = Date().timeIntervalSince(started)
            guard let pid = readPID(pidFile) else { return expect(false, "stubborn pid recorded") }
            expect(elapsed >= 2.5 && elapsed < 7, "escalates to SIGKILL after the grace period (\(elapsed)s)")
            let gone = await waitUntilGone(pid)
            expect(gone, "descendant ignoring SIGTERM is killed")
        }

        do {
            // Background work that does not hold the pipes is left alone.
            let pidFile = directory.appendingPathComponent("detached.pid")
            let started = Date()
            let result = await service.execute(
                command: "sleep 20 > /dev/null 2>&1 & echo $! > '\(pidFile.path)'",
                timeout: 3
            )
            let elapsed = Date().timeIntervalSince(started)
            guard let pid = readPID(pidFile) else { return expect(false, "detached pid recorded") }
            defer { kill(pid, SIGKILL) }
            expect(elapsed < 2.5, "returns without waiting for the timeout when no descendant holds the pipes (\(elapsed)s)")
            expect(result.success && result.error == nil, "detached command succeeds without a timeout note")
            try? await Task.sleep(nanoseconds: UInt64((4 - elapsed) * 1_000_000_000))
            expect(isAlive(pid), "background process that released the pipes survives past the timeout")
        }
    }
}
