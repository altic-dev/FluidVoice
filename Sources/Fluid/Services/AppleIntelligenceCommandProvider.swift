import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Availability

enum AppleIntelligenceAvailability {
    static let providerID = "apple-intelligence"
    static let modelID = "System Language Model"

    static var isAvailable: Bool {
        self.unavailableReason == nil
    }

    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            guard case let .unavailable(reason) = SystemLanguageModel.default.availability else { return nil }
            switch reason {
            case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings > Apple Intelligence & Siri."
            case .modelNotReady: return "The Apple Intelligence model is still downloading."
            @unknown default: return "Apple Intelligence is unavailable."
            }
        }
        #endif
        return "Apple Intelligence requires macOS 27."
    }
}

enum AppleIntelligenceCommandError: LocalizedError {
    case unavailable
    case contextTooLong

    var errorDescription: String? {
        switch self {
        case .unavailable: return AppleIntelligenceAvailability.unavailableReason
        case .contextTooLong: return "This conversation is too long for Apple Intelligence. Start a new chat."
        }
    }
}

// MARK: - Pure core

struct AppleIntelligenceCall: Equatable {
    let id: String
    let command: String
    let workingDirectory: String?
    let purpose: String?
}

enum AppleIntelligenceTurn: Equatable {
    case user(String)
    case call(AppleIntelligenceCall)
    case output(id: String, text: String)
    case text(String)

    enum Role { case user, assistant, tool }

    static let outputLimit = 1500

    /// Maps stored messages in order; thinking is never part of a turn.
    static func turns(_ history: [(role: Role, content: String, call: AppleIntelligenceCall?)]) -> [AppleIntelligenceTurn] {
        var lastCallID = ""
        return history.map { message in
            switch message.role {
            case .user: return .user(message.content)
            case .tool: return .output(id: lastCallID, text: message.content)
            case .assistant:
                guard let call = message.call else { return .text(message.content) }
                lastCallID = call.id
                return .call(call)
            }
        }
    }

    /// Caps the stdout and stderr fields in the transcript only, so the JSON stays valid; stored history is unchanged.
    var capped: AppleIntelligenceTurn {
        guard case let .output(id, text) = self,
              var json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return self }
        let long = ["output", "error"].filter { (json[$0] as? String)?.count ?? 0 > Self.outputLimit }
        for key in long {
            json[key] = String((json[key] as? String ?? "").prefix(Self.outputLimit)) + "...[truncated]"
        }
        guard !long.isEmpty, let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]), let capped = String(bytes: data, encoding: .utf8) else { return self }
        return .output(id: id, text: capped)
    }

    /// The model continues from this text: the user request or the latest tool result.
    var promptText: String {
        switch self {
        case let .user(text), let .text(text), let .output(_, text): return text
        case let .call(call): return call.command
        }
    }

    /// Drops the oldest request (everything before the second user turn), or empty if only one remains.
    static func droppingOldestRequest(_ turns: [AppleIntelligenceTurn]) -> [AppleIntelligenceTurn] {
        guard let next = turns.dropFirst().firstIndex(where: { if case .user = $0 { true } else { false } }) else { return [] }
        return Array(turns[next...])
    }
}

// MARK: - FoundationModels

enum AppleIntelligenceCommandProvider {
    private static let outputReserveTokens = 1024

    static func respond(to turns: [AppleIntelligenceTurn]) async throws -> (content: String, call: AppleIntelligenceCall?) {
        #if canImport(FoundationModels)
        if #available(macOS 27.0, *) {
            return try await self.run(turns.map(\.capped))
        }
        #endif
        throw AppleIntelligenceCommandError.unavailable
    }
}

#if canImport(FoundationModels)
@available(macOS 27.0, *)
private struct CapturedCommandCall: Error { let arguments: TerminalCommandTool.Arguments }

@available(macOS 27.0, *)
private struct TerminalCommandTool: Tool {
    let name = "execute_terminal_command"
    let description = """
    Execute a terminal/shell command on the user's macOS computer.
    Use this for file operations (ls, cat, mkdir, rm), git commands, brew, npm, python, or any CLI tool.
    Follow the workflow: check prerequisites first, execute the main action, then verify the result.
    Returns JSON with: success, output (stdout), error (stderr), exitCode, purpose.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The shell command to execute (e.g., 'ls -la', 'git status', 'rm file.txt')")
        var command: String
        @Guide(description: "Optional working directory path. Defaults to user's home directory.")
        var workingDirectory: String?
        @Guide(description: "Brief description of why this command is being run. Start with one of: 'checking' (verifying prerequisites), 'executing' (main action), 'verifying' (confirming result). Example: 'Checking if config.json exists'")
        var purpose: String
    }

    /// The app's agent loop runs and confirms commands, so the tool only captures the call.
    func call(arguments: Arguments) async throws -> String {
        throw CapturedCommandCall(arguments: arguments)
    }
}

@available(macOS 27.0, *)
extension AppleIntelligenceCommandProvider {
    private static let instructions = """
    You are a macOS terminal agent. You act only by calling execute_terminal_command; never claim you did something without calling it.
    Rules:
    1. Check first: before changing anything, check the target (ls, test -e, which).
    2. Every call needs a purpose: 'checking', 'executing' or 'verifying', plus a short reason.
    3. After modifying anything, verify it with ls or cat.
    4. Use full absolute paths. The shell is zsh on macOS.
    5. Call one command at a time and read its result before the next step. Never repeat a command whose result you already have.
       To create a file with content, write it in one command: echo 'text' > /abs/path/file (touch makes an empty file).
    6. On failure, read the error and try another approach; never assume success.
    7. For deletions, list the target first, then run rm.
    When the task is done, reply with a short plain-text summary starting with ✓ (success) or ✗ (failure). Do not call the tool again after that.
    """

    static func run(_ allTurns: [AppleIntelligenceTurn]) async throws -> (content: String, call: AppleIntelligenceCall?) {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        var turns = allTurns
        var entries = self.entries(turns)
        while try await model.tokenCount(for: entries) > model.contextSize - self.outputReserveTokens {
            let rest = AppleIntelligenceTurn.droppingOldestRequest(turns)
            guard !rest.isEmpty else { throw AppleIntelligenceCommandError.contextTooLong }
            turns = rest
            entries = self.entries(turns)
        }
        // A trailing tool result only worked as the prompt, with its ToolCalls entry left in the transcript.
        let session = LanguageModelSession(model: model, tools: [TerminalCommandTool()], transcript: Transcript(entries: entries.dropLast()))
        do {
            let reply = try await session.respond(to: turns.last?.promptText ?? "", options: GenerationOptions(temperature: 0.1))
            return (reply.content, nil)
        } catch let error as LanguageModelSession.ToolCallError {
            guard let captured = error.underlyingError as? CapturedCommandCall else { throw error }
            let args = captured.arguments
            return ("", AppleIntelligenceCall(id: UUID().uuidString, command: args.command, workingDirectory: args.workingDirectory, purpose: args.purpose))
        }
    }

    private static func entries(_ turns: [AppleIntelligenceTurn]) -> [Transcript.Entry] {
        let tool = TerminalCommandTool()
        func text(_ string: String) -> [Transcript.Segment] {
            [.text(.init(content: string))]
        }
        let head = Transcript.Entry.instructions(Transcript.Instructions(segments: text(self.instructions), toolDefinitions: [Transcript.ToolDefinition(tool: tool)]))
        return [head] + turns.map { turn in
            switch turn {
            case let .user(string): return .prompt(Transcript.Prompt(segments: text(string)))
            case let .text(string): return .response(Transcript.Response(assetIDs: [], segments: text(string)))
            case let .output(id, string): return .toolOutput(Transcript.ToolOutput(id: id, toolName: tool.name, segments: text(string)))
            case let .call(call):
                let arguments = TerminalCommandTool.Arguments(command: call.command, workingDirectory: call.workingDirectory, purpose: call.purpose ?? "").generatedContent
                return .toolCalls(Transcript.ToolCalls([Transcript.ToolCall(id: call.id, toolName: tool.name, arguments: arguments)]))
            }
        }
    }
}
#endif
