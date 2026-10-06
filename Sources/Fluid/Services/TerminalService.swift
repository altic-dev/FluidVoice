import Foundation

/// Simple terminal command execution service
/// All responses are JSON-parsable for easy AI processing
final class TerminalService {
    // MARK: - JSON Response Types

    struct CommandResult: Codable {
        let success: Bool
        let command: String
        let output: String
        let error: String?
        let exitCode: Int32
        let executionTimeMs: Int
    }

    // MARK: - Tool Definition for AI

    /// Returns the tool definition in OpenAI function calling format
    static var toolDefinition: [String: Any] {
        return [
            "type": "function",
            "function": [
                "name": "execute_terminal_command",
                "description": """
                Execute a terminal/shell command on the user's macOS computer.
                Use this for file operations (ls, cat, mkdir, rm), git commands, brew, npm, python, or any CLI tool.

                IMPORTANT: Follow the agentic workflow:
                1. ALWAYS check prerequisites first (file exists, command available)
                2. Execute the main action
                3. Verify the result

                Returns JSON with: success (bool), output (stdout), error (stderr), exitCode, purpose.
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The shell command to execute (e.g., 'ls -la', 'git status', 'rm file.txt')",
                        ],
                        "workingDirectory": [
                            "type": "string",
                            "description": "Optional working directory path. Defaults to user's home directory.",
                        ],
                        "purpose": [
                            "type": "string",
                            "description": """
                            Brief description of why this command is being run. Must be one of:
                            - 'checking' (verifying prerequisites)
                            - 'executing' (main action)
                            - 'verifying' (confirming result)
                            Example: 'Checking if config.json exists'
                            """,
                        ],
                    ],
                    "required": ["command", "purpose"],
                ],
            ],
        ]
    }

    // MARK: - Execution

    /// Execute a terminal command and return JSON-parsable result
    func execute(
        command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) async -> CommandResult {
        let startTime = Date()

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        // Use zsh (default macOS shell)
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        // Set working directory
        if let dir = workingDirectory, !dir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        } else {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        // Inherit user's environment (PATH, etc.)
        var environment = ProcessInfo.processInfo.environment
        // Ensure common paths are available
        if let path = environment["PATH"] {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(path)"
        }
        process.environment = environment

        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            // waitUntilExit() and the pipe reads block, so they run on a dispatch
            // queue rather than on the main actor or a Swift concurrency thread.
            let (outputData, errorData, timedOut) = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.waitForExit(
                        of: process,
                        outputPipe: outputPipe,
                        errorPipe: errorPipe,
                        timeout: timeout
                    ))
                }
            }

            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if timedOut {
                let note = "Timed out after \(String(format: "%g", timeout))s."
                errorOutput = errorOutput.isEmpty ? note : errorOutput + "\n" + note
            }

            let executionTime = Int(Date().timeIntervalSince(startTime) * 1000)

            return CommandResult(
                success: !timedOut && process.terminationStatus == 0,
                command: command,
                output: output,
                error: errorOutput.isEmpty ? nil : errorOutput,
                exitCode: process.terminationStatus,
                executionTimeMs: executionTime
            )

        } catch {
            let executionTime = Int(Date().timeIntervalSince(startTime) * 1000)
            return CommandResult(
                success: false,
                command: command,
                output: "",
                error: "Failed to execute: \(error.localizedDescription)",
                exitCode: -1,
                executionTimeMs: executionTime
            )
        }
    }

    /// Waits for the command and reads its output. Blocks; returns whether the timeout fired.
    nonisolated private static func waitForExit(
        of process: Process,
        outputPipe: Pipe,
        errorPipe: Pipe,
        timeout: TimeInterval
    ) -> (Data, Data, Bool) {
        let deadline = TerminalCommandDeadline(process: process)
        let timeoutWork = DispatchWorkItem { deadline.expire() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

        process.waitUntilExit()

        // The reads end at EOF, which only arrives once every copy of the write
        // ends has been closed, so keep the timeout armed until both finish.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let timedOut = deadline.finish()
        timeoutWork.cancel()
        return (outputData, errorData, timedOut)
    }

    /// Convert result to JSON string for AI processing
    func resultToJSON(_ result: CommandResult) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(result),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }

        // Fallback: always return valid JSON (avoid manual string interpolation of output)
        let fallbackPayload: [String: Any] = [
            "success": result.success,
            "output": result.output,
            "exitCode": Int(result.exitCode),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: fallbackPayload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }

        // If serialization fails for any reason, return minimal safe JSON
        return #"{"success":false,"output":"<json-serialization-failed>","exitCode":-1}"#
    }
}

/// Stops a timed-out command. On macOS, Process launches the shell as the leader
/// of a new process group (pgid == pid), and whatever the command starts inherits
/// that group unless it moves itself out (setsid, setpgid). Signal the group
/// directly: a descendant can outlive the shell and keep stdout/stderr open, and
/// once the shell has exited there is nothing left for process.terminate() to reach.
private final nonisolated class TerminalCommandDeadline: @unchecked Sendable {
    private static let killGracePeriod: TimeInterval = 2

    private let lock = NSLock()
    private let process: Process
    private var finished = false
    private var expired = false

    init(process: Process) { self.process = process }

    /// SIGTERM now, then SIGKILL after the grace period if the reads still haven't finished.
    func expire() {
        guard self.signal(SIGTERM, expiring: true) else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGracePeriod) {
            _ = self.signal(SIGKILL, expiring: false)
        }
    }

    /// Marks the reads finished so no further signal is sent. Returns whether the timeout fired.
    func finish() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.finished = true
        return self.expired
    }

    private func signal(_ signal: Int32, expiring: Bool) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        // kill(0, ...) would signal FluidVoice's own process group.
        let processGroup = self.process.processIdentifier
        guard !self.finished, processGroup > 0 else { return false }
        if expiring { self.expired = true }
        if kill(-processGroup, signal) != 0, self.process.isRunning {
            kill(processGroup, signal)
        }
        return true
    }
}
