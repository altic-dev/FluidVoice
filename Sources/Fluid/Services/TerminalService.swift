import Foundation
import os

/// Simple terminal command execution service
/// All responses are JSON-parsable for easy AI processing
final nonisolated class TerminalService: Sendable {
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

    /// Execute a terminal command and return JSON-parsable result.
    /// `@concurrent` keeps it off the caller's actor; command-mode callers are on the main actor.
    @concurrent
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

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain both pipes while the command runs; a full pipe blocks the command forever.
        let stdout = PipeCollector(outputPipe)
        let stderr = PipeCollector(errorPipe)

        let timedOut: Bool
        do {
            timedOut = try await Self.run(process, timeout: timeout)
        } catch {
            stdout.finish()
            stderr.finish()
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

        // Backgrounded children inherit the pipes and can keep them open after the shell exits.
        async let outputData = stdout.collect(grace: 1)
        async let errorData = stderr.collect(grace: 1)
        let (outputBytes, errorBytes) = await (outputData, errorData)

        let output = (String(bytes: outputBytes, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var errorOutput = (String(bytes: errorBytes, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut {
            let note = "Command timed out after \(Int(timeout))s and was terminated."
            errorOutput = errorOutput.isEmpty ? note : "\(errorOutput)\n\(note)"
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
    }

    /// Runs `process` to completion without blocking a thread. Returns whether the timeout fired.
    private static func run(_ process: Process, timeout: TimeInterval) async throws -> Bool {
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            // Weak so a pending timer doesn't keep a finished process and its pipes alive.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                guard let process, process.isRunning else { return }
                timedOut.withLock { $0 = true }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
                    if let process, process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
        return timedOut.withLock { $0 }
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

/// Accumulates a pipe's output as it arrives.
private final nonisolated class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(_ pipe: Pipe) {
        self.handle = pipe.fileHandleForReading
        // `finish()` clears the handler, which breaks this retain cycle.
        self.handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                self.finish()
            } else {
                self.lock.withLock { self.data.append(chunk) }
            }
        }
    }

    /// Waits for EOF, or at most `grace` seconds, then returns what was read.
    func collect(grace: TimeInterval) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyFinished = self.lock.withLock {
                if self.finished { return true }
                self.waiter = continuation
                return false
            }
            if alreadyFinished {
                continuation.resume()
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [weak self] in self?.finish() }
        }
        return self.lock.withLock { self.data }
    }

    func finish() {
        self.handle.readabilityHandler = nil
        let waiter = self.lock.withLock {
            self.finished = true
            let waiter = self.waiter
            self.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
}
