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
                            "description": "The shell command to execute (e.g., 'ls -la', 'git status', 'rm file.txt')"
                        ],
                        "workingDirectory": [
                            "type": "string",
                            "description": "Optional working directory path. Defaults to user's home directory."
                        ],
                        "purpose": [
                            "type": "string",
                            "description": "Brief description of why this command is being run. Must be one of: 'checking' (verifying prerequisites), 'executing' (main action), 'verifying' (confirming result). Example: 'Checking if config.json exists'"
                        ]
                    ],
                    "required": ["command", "purpose"]
                ]
            ]
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
            
            // Wait with timeout
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                }
            }
            
            process.waitUntilExit()
            timeoutTask.cancel()
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let executionTime = Int(Date().timeIntervalSince(startTime) * 1000)
            
            return CommandResult(
                success: process.terminationStatus == 0,
                command: command,
                output: output,
                error: errorOutput?.isEmpty == true ? nil : errorOutput,
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
    
    /// Convert result to JSON string for AI processing
    func resultToJSON(_ result: CommandResult) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        if let data = try? encoder.encode(result),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        
        // Fallback
        return """
        {"success": \(result.success), "output": "\(result.output)", "exitCode": \(result.exitCode)}
        """
    }
}



