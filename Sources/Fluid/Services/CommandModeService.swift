import Foundation
import Combine

@MainActor
final class CommandModeService: ObservableObject {
    @Published var conversationHistory: [Message] = []
    @Published var isProcessing = false
    @Published var pendingCommand: PendingCommand? = nil
    @Published var currentStep: AgentStep? = nil
    
    private let terminalService = TerminalService()
    private var currentTurnCount = 0
    private let maxTurns = 20
    
    // MARK: - Agent Step Tracking
    
    enum AgentStep: Equatable {
        case thinking(String)
        case checking(String)
        case executing(String)
        case verifying(String)
        case completed(Bool)
    }
    
    // MARK: - Models
    
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let content: String
        let toolCall: ToolCall?
        let stepType: StepType
        let timestamp: Date
        
        enum Role: Equatable {
            case user
            case assistant
            case tool
        }
        
        enum StepType: Equatable {
            case normal
            case thinking      // AI reasoning
            case checking      // Pre-flight verification
            case executing     // Running command
            case verifying     // Post-action check
            case success       // Action completed
            case failure       // Action failed
        }
        
        struct ToolCall: Equatable {
            let id: String
            let command: String
            let workingDirectory: String?
            let purpose: String?  // Why this command is being run
        }
        
        init(role: Role, content: String, toolCall: ToolCall? = nil, stepType: StepType = .normal) {
            self.role = role
            self.content = content
            self.toolCall = toolCall
            self.stepType = stepType
            self.timestamp = Date()
        }
    }
    
    struct PendingCommand {
        let id: String
        let command: String
        let workingDirectory: String?
        let purpose: String?
    }
    
    // MARK: - Public Methods
    
    func clearHistory() {
        conversationHistory.removeAll()
        pendingCommand = nil
        currentTurnCount = 0
    }
    
    /// Process user voice/text command
    func processUserCommand(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        isProcessing = true
        currentTurnCount = 0
        conversationHistory.append(Message(role: .user, content: text))
        
        await processNextTurn()
    }
    
    /// Execute pending command (after user confirmation)
    func confirmAndExecute() async {
        guard let pending = pendingCommand else { return }
        pendingCommand = nil
        isProcessing = true
        
        await executeCommand(pending.command, workingDirectory: pending.workingDirectory, callId: pending.id)
    }
    
    /// Cancel pending command
    func cancelPendingCommand() {
        pendingCommand = nil
        conversationHistory.append(Message(
            role: .assistant,
            content: "Command cancelled.",
            stepType: .failure
        ))
        isProcessing = false
        currentStep = nil
    }
    
    // MARK: - Agent Loop
    
    private func processNextTurn() async {
        if currentTurnCount >= maxTurns {
            conversationHistory.append(Message(
                role: .assistant,
                content: "Reached maximum steps limit. Please review the progress and continue if needed.",
                stepType: .failure
            ))
            isProcessing = false
            currentStep = .completed(false)
            return
        }
        
        currentTurnCount += 1
        currentStep = .thinking("Analyzing...")
        
        do {
            let response = try await callLLM()
            
            if let tc = response.toolCall {
                // Determine step type based on command purpose
                let stepType = determineStepType(for: tc.command, purpose: tc.purpose)
                currentStep = stepType == .checking ? .checking(tc.command) : .executing(tc.command)
                
                // AI wants to run a command
                conversationHistory.append(Message(
                    role: .assistant,
                    content: response.content.isEmpty ? stepDescription(for: stepType) : response.content,
                    toolCall: Message.ToolCall(
                        id: tc.id,
                        command: tc.command,
                        workingDirectory: tc.workingDirectory,
                        purpose: tc.purpose
                    ),
                    stepType: stepType
                ))
                
                // Check if we need confirmation for destructive commands
                if SettingsStore.shared.commandModeConfirmBeforeExecute && isDestructiveCommand(tc.command) {
                    pendingCommand = PendingCommand(
                        id: tc.id,
                        command: tc.command,
                        workingDirectory: tc.workingDirectory,
                        purpose: tc.purpose
                    )
                    isProcessing = false
                    currentStep = nil
                    return
                }
                
                // Auto-execute
                await executeCommand(tc.command, workingDirectory: tc.workingDirectory, callId: tc.id, purpose: tc.purpose)
                
            } else {
                // Just a text response - check if it's a final summary
                let isFinal = response.content.lowercased().contains("complete") ||
                              response.content.lowercased().contains("done") ||
                              response.content.lowercased().contains("success") ||
                              response.content.lowercased().contains("finished")
                
                conversationHistory.append(Message(
                    role: .assistant,
                    content: response.content,
                    stepType: isFinal ? .success : .normal
                ))
                isProcessing = false
                currentStep = .completed(isFinal)
            }
            
        } catch {
            conversationHistory.append(Message(
                role: .assistant,
                content: "Error: \(error.localizedDescription)",
                stepType: .failure
            ))
            isProcessing = false
            currentStep = .completed(false)
        }
    }
    
    private func determineStepType(for command: String, purpose: String?) -> Message.StepType {
        let cmd = command.lowercased()
        let purposeLower = purpose?.lowercased() ?? ""
        
        // Check commands
        if purposeLower.contains("check") || purposeLower.contains("verify") || purposeLower.contains("exist") {
            return .checking
        }
        if cmd.hasPrefix("ls ") || cmd.hasPrefix("cat ") || cmd.hasPrefix("test ") || cmd.hasPrefix("[ ") ||
           cmd.contains("--version") || cmd.contains("which ") || cmd.contains("file ") ||
           cmd.hasPrefix("stat ") || cmd.hasPrefix("head ") || cmd.hasPrefix("tail ") {
            return .checking
        }
        
        // Verification commands
        if purposeLower.contains("confirm") || purposeLower.contains("result") {
            return .verifying
        }
        
        return .executing
    }
    
    private func stepDescription(for stepType: Message.StepType) -> String {
        switch stepType {
        case .checking: return "Checking prerequisites..."
        case .verifying: return "Verifying the result..."
        case .executing: return "Executing command..."
        default: return ""
        }
    }
    
    private func isDestructiveCommand(_ command: String) -> Bool {
        let destructive = ["rm ", "rm\t", "rmdir", "mv ", "mv\t", "> ", ">> ", 
                          "chmod ", "chown ", "kill ", "pkill ", "sudo "]
        return destructive.contains { command.lowercased().hasPrefix($0) || command.contains(" \($0)") }
    }
    
    private func executeCommand(_ command: String, workingDirectory: String?, callId: String, purpose: String? = nil) async {
        currentStep = .executing(command)
        
        let result = await terminalService.execute(
            command: command,
            workingDirectory: workingDirectory
        )
        
        // Create enhanced result with context
        let enhancedResult = EnhancedCommandResult(
            result: result,
            purpose: purpose
        )
        
        let resultJSON = enhancedResult.toJSON()
        
        // Determine result step type
        let resultStepType: Message.StepType = result.success ? .success : .failure
        
        // Add tool result to conversation
        conversationHistory.append(Message(
            role: .tool,
            content: resultJSON,
            stepType: resultStepType
        ))
        
        // Continue the loop - let the AI see the result and decide what to do next
        await processNextTurn()
    }
    
    // MARK: - Enhanced Result
    
    private struct EnhancedCommandResult: Codable {
        let success: Bool
        let command: String
        let output: String
        let error: String?
        let exitCode: Int32
        let executionTimeMs: Int
        let purpose: String?
        
        init(result: TerminalService.CommandResult, purpose: String?) {
            self.success = result.success
            self.command = result.command
            self.output = result.output
            self.error = result.error
            self.exitCode = result.exitCode
            self.executionTimeMs = result.executionTimeMs
            self.purpose = purpose
        }
        
        func toJSON() -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(self),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return """
            {"success": \(success), "output": "\(output)", "exitCode": \(exitCode)}
            """
        }
    }
    
    // MARK: - LLM Integration
    
    private struct LLMResponse {
        let content: String
        let toolCall: ToolCallData?
        
        struct ToolCallData {
            let id: String
            let command: String
            let workingDirectory: String?
            let purpose: String?
        }
    }
    
    private func callLLM() async throws -> LLMResponse {
        let settings = SettingsStore.shared
        // Use Command Mode's independent provider/model settings
        let providerID = settings.commandModeSelectedProviderID
        let model = settings.commandModeSelectedModel ?? "gpt-4o"
        let apiKey = settings.providerAPIKeys[providerID] ?? ""
        
        let baseURL: String
        if let provider = settings.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = provider.baseURL
        } else if providerID == "groq" {
            baseURL = "https://api.groq.com/openai/v1"
        } else {
            baseURL = "https://api.openai.com/v1"
        }
        
        // Build conversation with agentic system prompt
        let systemPrompt = """
        You are an autonomous, thoughtful macOS terminal agent. Execute user requests reliably and safely.
        
        ## AGENTIC WORKFLOW (Follow this pattern):
        
        ### 1. PRE-FLIGHT CHECKS (Always do this first!)
        Before ANY action, verify prerequisites:
        - File operations: Check if file/folder exists first (`ls`, `test -e`, `[ -f file ]`)
        - Deletions: List contents before removing, confirm target exists
        - Modifications: Read current state before changing
        - Installations: Check if already installed (`which`, `--version`)
        
        ### 2. EXECUTE WITH CONTEXT
        When calling execute_terminal_command, ALWAYS include a `purpose` parameter explaining:
        - "checking" - Verifying something exists/state
        - "executing" - Performing the main action  
        - "verifying" - Confirming the result
        Example purposes: "Checking if image1.png exists", "Creating the backup directory", "Verifying file was deleted"
        
        ### 3. POST-ACTION VERIFICATION
        After modifying anything, verify it worked:
        - Created file? `ls` to confirm it exists
        - Deleted file? `ls` to confirm it's gone  
        - Modified content? `cat` or `head` to verify changes
        - Installed app? Check version/existence
        
        ### 4. HANDLE FAILURES GRACEFULLY
        - If something doesn't exist: Tell the user clearly
        - If command fails: Analyze error, try alternative approach
        - If permission denied: Explain and suggest solutions
        - Never assume success without verification
        
        ## RESPONSE FORMAT:
        - Keep reasoning brief and clear
        - State what you're checking/doing before each command
        - After verification, give a clear success/failure summary
        - Use natural language, not code comments
        
        ## SAFETY RULES:
        - For destructive ops (rm, mv, overwrite): ALWAYS check target exists first
        - Show what will be affected before destroying
        - Prefer `rm -i` or listing contents before bulk deletes
        - Use full absolute paths when possible
        
        ## EXAMPLES OF GOOD BEHAVIOR:
        
        User: "Delete image1.png in Downloads"
        You: First check if it exists
        → execute_terminal_command(command: "ls -la ~/Downloads/image1.png", purpose: "Checking if image1.png exists")
        If exists → execute_terminal_command(command: "rm ~/Downloads/image1.png", purpose: "Deleting the file")
        Then verify → execute_terminal_command(command: "ls ~/Downloads/image1.png 2>&1", purpose: "Verifying file was deleted")
        Finally: "✓ Successfully deleted image1.png from Downloads."
        
        User: "Create a project folder with a readme"
        You: → Check if folder exists, create it, create readme, verify both
        
        The user is on macOS with zsh shell. Be thorough but efficient. 
        When task is complete, provide a clear summary starting with ✓ or ✗.
        """
        
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        
        // Add conversation history
        var lastToolCallId: String? = nil
        
        for msg in conversationHistory {
            switch msg.role {
            case .user:
                messages.append(["role": "user", "content": msg.content])
            case .assistant:
                if let tc = msg.toolCall {
                    lastToolCallId = tc.id
                    messages.append([
                        "role": "assistant",
                        "content": msg.content,
                        "tool_calls": [[
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": "execute_terminal_command",
                                "arguments": try! String(data: JSONSerialization.data(withJSONObject: [
                                    "command": tc.command,
                                    "workingDirectory": tc.workingDirectory ?? ""
                                ]), encoding: .utf8)!
                            ]
                        ]]
                    ])
                } else {
                    messages.append(["role": "assistant", "content": msg.content])
                }
            case .tool:
                messages.append([
                    "role": "tool",
                    "content": msg.content,
                    "tool_call_id": lastToolCallId ?? "call_unknown"
                ])
            }
        }
        
        // We assume conversationHistory contains the user's latest message already

        
        // Build request
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": [TerminalService.toolDefinition],
            "tool_choice": "auto",
            "temperature": 0.1
        ]
        
        let endpoint = baseURL.hasSuffix("/chat/completions") ? baseURL : "\(baseURL)/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "CommandMode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let err = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "CommandMode", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: err])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw NSError(domain: "CommandMode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        // Check for tool calls
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let toolCall = toolCalls.first,
           let function = toolCall["function"] as? [String: Any],
           let name = function["name"] as? String,
           name == "execute_terminal_command",
           let argsString = function["arguments"] as? String,
           let argsData = argsString.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
            
            let command = args["command"] as? String ?? ""
            let workDir = args["workingDirectory"] as? String
            let purpose = args["purpose"] as? String
            let callId = toolCall["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
            
            return LLMResponse(
                content: message["content"] as? String ?? "",
                toolCall: LLMResponse.ToolCallData(
                    id: callId,
                    command: command,
                    workingDirectory: workDir?.isEmpty == true ? nil : workDir,
                    purpose: purpose
                )
            )
        }
        
        // Text response only
        return LLMResponse(
            content: message["content"] as? String ?? "I couldn't understand that.",
            toolCall: nil
        )
    }
}

