import Darwin
import Foundation

nonisolated enum MeetingSummaryCLI: String, CaseIterable {
    case claude = "meeting:claude-cli"
    case codex = "meeting:codex-cli"

    static let defaultModel = "CLI default"
    var command: String {
        self == .claude ? "claude" : "codex"
    }

    var title: String {
        self == .claude ? "Claude Code CLI" : "Codex CLI"
    }

    /// Finder-launched apps do not inherit the interactive shell's PATH.
    var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        paths += [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".volta/bin").path]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { nvm.appendingPathComponent("\($0)/bin").path }
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent(self.command) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func arguments(model: String, output: URL) -> [String] {
        var arguments: [String]
        switch self {
        case .claude:
            arguments = [
                "-p",
                "--output-format",
                "json",
                "--tools",
                "",
                "--strict-mcp-config",
                "--mcp-config",
                "{\"mcpServers\":{}}",
                "--no-session-persistence",
                "--disable-slash-commands",
                "--settings",
                "{\"disableAllHooks\":true}",
            ]
        case .codex:
            arguments = [
                "exec",
                "--ignore-user-config",
                "--ephemeral",
                "--skip-git-repo-check",
                "--sandbox",
                "read-only",
                "--color",
                "never",
                "--output-last-message",
                output.path,
                "-c",
                "approval_policy=\"never\"",
                "-c",
                "web_search=\"disabled\"",
                "-c",
                "project_doc_max_bytes=0",
            ]
            for feature in ["shell_tool", "unified_exec", "apps", "plugins", "hooks", "multi_agent", "memories", "browser_use", "computer_use", "image_generation"] {
                arguments += ["-c", "features.\(feature)=false"]
            }
        }
        if !model.isEmpty, model != Self.defaultModel { arguments += ["--model", model] }
        if self == .codex { arguments.append("-") }
        return arguments
    }

    func summary(from data: Data) throws -> String {
        let text: String
        if self == .claude {
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  response["is_error"] as? Bool != true,
                  response["subtype"] as? String == "success",
                  let result = response["result"] as? String
            else { throw LLMError.invalidRequest("Claude Code did not return a summary. Check its sign-in, usage limits, and model in Terminal.") }
            text = result
        } else {
            guard let result = String(data: data, encoding: .utf8) else { throw MeetingPostProcessingError.invalidOutput }
            text = result
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingPostProcessingError.invalidOutput }
        return text
    }
}

nonisolated enum MeetingSummaryCLIService {
    static func generate(transcript: String, kind: MeetingSummaryKind, route: MeetingSummaryRoute, timeout: TimeInterval = 240) async throws -> String {
        try Task.checkCancellation()
        guard let cli = route.cli else { throw LLMError.invalidRequest("Choose a CLI summary provider.") }
        guard transcript.utf8.count <= 512_000 else { throw MeetingPostProcessingError.inputTooLarge }
        let prompt = """
        \(MeetingSummaryRemoteService.prompt(for: kind))
        Answer in one turn using only the transcript below. Do not use tools, read files, or run commands.

        <meeting_transcript>
        \(transcript)
        </meeting_transcript>
        """
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FluidMeet-summary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input")
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        let output = directory.appendingPathComponent("summary")
        try Data(prompt.utf8).write(to: input)
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let inputHandle = try FileHandle(forReadingFrom: input)
        let outputHandle = try FileHandle(forWritingTo: stdout)
        let errorHandle = try FileHandle(forWritingTo: stderr)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
            try? errorHandle.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: route.baseURL)
        process.arguments = cli.arguments(model: route.modelID, output: output)
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        // npm-installed CLIs use /usr/bin/env node; include the chosen installation's bin directory.
        environment["PATH"] = "\(URL(fileURLWithPath: route.baseURL).deletingLastPathComponent().path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment.removeValue(forKey: "CLAUDECODE")
        process.environment = environment
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try Task.checkCancellation()
        do { try process.run() } catch {
            throw LLMError.invalidRequest("Could not start \(cli.title). Check its installation in Terminal.")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw LLMError.invalidRequest("\(cli.title) timed out. Check its sign-in and try again.") }
                try self.checkOutputSizes([stdout, stderr, output])
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                // CLI diagnostics may echo the transcript or credentials; never persist or display them.
                throw LLMError.invalidRequest("\(cli.title) exited with code \(process.terminationStatus). Check its sign-in, model, and usage limits in Terminal; update the CLI if needed.")
            }
            try self.checkOutputSizes([stdout, stderr, output])
            return try cli.summary(from: Data(contentsOf: cli == .claude ? stdout : output))
        } catch {
            await self.stop(process)
            throw error
        }
    }

    private static func checkOutputSizes(_ files: [URL]) throws {
        for file in files {
            let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let size, size > 2_000_000 { throw LLMError.invalidRequest("The CLI response exceeded the summary size limit.") }
        }
    }

    private static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        // Foundation creates a new process group on macOS. Include npm wrapper children.
        let target = getpgid(pid) == pid ? -pid : pid
        kill(target, SIGTERM)
        // A cancelled task cannot sleep; use a separate cleanup task and await actual exit before releasing the activity lock.
        await Task.detached {
            for _ in 0..<20 where kill(target, 0) == 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if kill(target, 0) == 0 { kill(target, SIGKILL) }
            while process.isRunning {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }.value
    }
}
