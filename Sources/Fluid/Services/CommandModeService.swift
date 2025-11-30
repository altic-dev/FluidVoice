import Foundation
import Combine

@MainActor
final class CommandModeService: ObservableObject {
    @Published var conversationHistory: [Message] = []
    @Published var isProcessing = false
    @Published var pendingCommand: PendingCommand? = nil
    @Published var currentStep: AgentStep? = nil
    @Published var streamingText: String = ""  // Real-time streaming text for UI
    @Published private(set) var currentChatID: String?
    
    private let terminalService = TerminalService()
    private let chatStore = ChatHistoryStore.shared
    private var currentTurnCount = 0
    private let maxTurns = 20
    
    // Flag to enable notch output display
    var enableNotchOutput: Bool = true
    
    // Streaming UI update throttling - adaptive rate based on content length
    private var lastUIUpdate: CFAbsoluteTime = 0
    private var streamingBuffer: [String] = []  // Buffer tokens instead of string concat
    
    // MARK: - Initialization
    
    init() {
        // Load current chat from store
        loadCurrentChatFromStore()
    }
    
    private func loadCurrentChatFromStore() {
        if let session = chatStore.currentSession {
            currentChatID = session.id
            conversationHistory = session.messages.map { chatMessageToMessage($0) }
            syncToNotchState()
        } else {
            // Create new chat if none exists
            let newSession = chatStore.createNewChat()
            currentChatID = newSession.id
            conversationHistory = []
        }
    }
    
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
        
        // Clear in store as well
        chatStore.clearCurrentChat()
        
        // Also clear notch state
        NotchContentState.shared.clearCommandOutput()
    }
    
    // MARK: - Chat Management
    
    /// Get recent chats for dropdown
    func getRecentChats() -> [ChatSession] {
        return chatStore.getRecentChats(excludingCurrent: false)
    }
    
    /// Create a new chat and switch to it
    func createNewChat() {
        // Can't switch while processing
        guard !isProcessing else { return }
        
        // Save current chat first
        saveCurrentChat()
        
        // Create new
        let newSession = chatStore.createNewChat()
        currentChatID = newSession.id
        conversationHistory = []
        pendingCommand = nil
        currentTurnCount = 0
        currentStep = nil
        
        // Clear notch state
        NotchContentState.shared.clearCommandOutput()
        NotchContentState.shared.refreshRecentChats()
    }
    
    /// Switch to a different chat by ID
    /// Returns false if switching is blocked (e.g., during processing)
    @discardableResult
    func switchToChat(id: String) -> Bool {
        // Can't switch while processing
        guard !isProcessing else { return false }
        
        // Don't switch to current
        guard id != currentChatID else { return true }
        
        // Save current chat first
        saveCurrentChat()
        
        // Load the target chat
        guard let session = chatStore.switchToChat(id: id) else { return false }
        
        currentChatID = session.id
        conversationHistory = session.messages.map { chatMessageToMessage($0) }
        pendingCommand = nil
        currentTurnCount = 0
        currentStep = nil
        
        // Sync to notch state
        syncToNotchState()
        NotchContentState.shared.refreshRecentChats()
        
        return true
    }
    
    /// Delete current chat and switch to next
    func deleteCurrentChat() {
        // Can't delete while processing
        guard !isProcessing else { return }
        
        chatStore.deleteCurrentChat()
        
        // Load the new current chat
        loadCurrentChatFromStore()
        NotchContentState.shared.refreshRecentChats()
    }
    
    /// Save current conversation to store
    func saveCurrentChat() {
        guard let chatID = currentChatID else { return }
        
        let messages = conversationHistory.map { messageToChatMessage($0) }
        chatStore.updateCurrentChat(messages: messages)
    }
    
    // MARK: - Conversion Helpers
    
    private func messageToChatMessage(_ msg: Message) -> ChatMessage {
        let role: ChatMessage.Role
        switch msg.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .tool: role = .tool
        }
        
        let stepType: ChatMessage.StepType
        switch msg.stepType {
        case .normal: stepType = .normal
        case .thinking: stepType = .thinking
        case .checking: stepType = .checking
        case .executing: stepType = .executing
        case .verifying: stepType = .verifying
        case .success: stepType = .success
        case .failure: stepType = .failure
        }
        
        var toolCall: ChatMessage.ToolCall? = nil
        if let tc = msg.toolCall {
            toolCall = ChatMessage.ToolCall(
                id: tc.id,
                command: tc.command,
                workingDirectory: tc.workingDirectory,
                purpose: tc.purpose
            )
        }
        
        return ChatMessage(
            id: msg.id,
            role: role,
            content: msg.content,
            toolCall: toolCall,
            stepType: stepType,
            timestamp: msg.timestamp
        )
    }
    
    private func chatMessageToMessage(_ chatMsg: ChatMessage) -> Message {
        let role: Message.Role
        switch chatMsg.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .tool: role = .tool
        }
        
        let stepType: Message.StepType
        switch chatMsg.stepType {
        case .normal: stepType = .normal
        case .thinking: stepType = .thinking
        case .checking: stepType = .checking
        case .executing: stepType = .executing
        case .verifying: stepType = .verifying
        case .success: stepType = .success
        case .failure: stepType = .failure
        }
        
        var toolCall: Message.ToolCall? = nil
        if let tc = chatMsg.toolCall {
            toolCall = Message.ToolCall(
                id: tc.id,
                command: tc.command,
                workingDirectory: tc.workingDirectory,
                purpose: tc.purpose
            )
        }
        
        return Message(
            role: role,
            content: chatMsg.content,
            toolCall: toolCall,
            stepType: stepType
        )
    }
    
    /// Sync conversation history to NotchContentState
    private func syncToNotchState() {
        NotchContentState.shared.clearCommandOutput()
        
        for msg in conversationHistory {
            let role: NotchContentState.CommandOutputMessage.Role
            switch msg.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .tool: role = .status  // Tool outputs shown as status in notch
            }
            
            // Skip tool outputs in notch (they're verbose)
            if msg.role == .tool { continue }
            
            NotchContentState.shared.addCommandMessage(role: role, content: msg.content)
        }
    }
    
    /// Process user voice/text command
    func processUserCommand(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        isProcessing = true
        currentTurnCount = 0
        conversationHistory.append(Message(role: .user, content: text))
        
        // Auto-save after adding user message
        saveCurrentChat()
        
        // Push to notch
        if enableNotchOutput {
            NotchContentState.shared.addCommandMessage(role: .user, content: text)
            NotchContentState.shared.setCommandProcessing(true)
        }
        
        await processNextTurn()
    }
    
    /// Process follow-up command from notch input
    func processFollowUpCommand(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // Add to both histories
        conversationHistory.append(Message(role: .user, content: text))
        NotchContentState.shared.addCommandMessage(role: .user, content: text)
        
        // Auto-save after adding user message
        saveCurrentChat()
        
        isProcessing = true
        NotchContentState.shared.setCommandProcessing(true)
        
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
            let errorMsg = "Reached maximum steps limit. Please review the progress and continue if needed."
            conversationHistory.append(Message(
                role: .assistant,
                content: errorMsg,
                stepType: .failure
            ))
            isProcessing = false
            currentStep = .completed(false)
            
            // Auto-save on completion
            saveCurrentChat()
            
            // Push to notch
            if enableNotchOutput {
                NotchContentState.shared.addCommandMessage(role: .assistant, content: errorMsg)
                NotchContentState.shared.setCommandProcessing(false)
                showExpandedNotchIfNeeded()
            }
            return
        }
        
        currentTurnCount += 1
        currentStep = .thinking("Analyzing...")
        
        // Push status to notch
        if enableNotchOutput {
            NotchContentState.shared.addCommandMessage(role: .status, content: "Thinking...")
        }
        
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
                
                // Push step to notch
                if enableNotchOutput {
                    let statusText = tc.purpose ?? stepDescription(for: stepType)
                    NotchContentState.shared.addCommandMessage(role: .status, content: statusText)
                }
                
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
                    
                    // Push confirmation needed to notch
                    if enableNotchOutput {
                        NotchContentState.shared.addCommandMessage(role: .status, content: "⚠️ Confirmation needed in Command Mode window")
                        NotchContentState.shared.setCommandProcessing(false)
                    }
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
                
                // Auto-save on completion
                saveCurrentChat()
                
                // Push final response to notch and show expanded view
                if enableNotchOutput {
                    NotchContentState.shared.updateCommandStreamingText("")  // Clear streaming
                    NotchContentState.shared.addCommandMessage(role: .assistant, content: response.content)
                    NotchContentState.shared.setCommandProcessing(false)
                    showExpandedNotchIfNeeded()
                }
            }
            
        } catch {
            let errorMsg = "Error: \(error.localizedDescription)"
            conversationHistory.append(Message(
                role: .assistant,
                content: errorMsg,
                stepType: .failure
            ))
            isProcessing = false
            currentStep = .completed(false)
            
            // Auto-save on error
            saveCurrentChat()
            
            // Push error to notch
            if enableNotchOutput {
                NotchContentState.shared.addCommandMessage(role: .assistant, content: errorMsg)
                NotchContentState.shared.setCommandProcessing(false)
                showExpandedNotchIfNeeded()
            }
        }
    }
    
    /// Show expanded notch output if there's content to display
    private func showExpandedNotchIfNeeded() {
        guard enableNotchOutput else { return }
        guard !NotchContentState.shared.commandConversationHistory.isEmpty else { return }
        
        // Show the expanded notch
        NotchOverlayManager.shared.showExpandedCommandOutput()
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
        let cmd = command.lowercased()
        
        // Commands that start with these are destructive
        let destructivePrefixes = [
            "rm ", "rm\t", "rmdir ", "rm -", // delete
            "mv ", "mv\t",                    // move/rename
            "sudo ",                          // elevated privileges
            "kill ", "pkill ", "killall ",    // terminate processes
            "chmod ", "chown ", "chgrp ",     // change permissions/ownership
            "dd ",                            // disk operations
            "mkfs", "format",                 // filesystem formatting
            "> ",                             // overwrite file
            "truncate ",                      // truncate file
            "shred ",                         // secure delete
        ]
        
        // Check if command starts with any destructive prefix
        if destructivePrefixes.contains(where: { cmd.hasPrefix($0) }) {
            return true
        }
        
        // Check for destructive patterns anywhere in piped commands
        let destructivePatterns = [
            "| rm ", "| sudo ", "| dd ",
            "; rm ", "; sudo ",
            "&& rm ", "&& sudo ",
            "xargs rm", "xargs -I",
        ]
        
        if destructivePatterns.contains(where: { cmd.contains($0) }) {
            return true
        }
        
        // rm with flags like -rf, -r, -f anywhere
        if cmd.contains("rm -") {
            return true
        }
        
        return false
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
        
        ## NATIVE macOS APP CONTROL (Use osascript):
        For Reminders, Notes, Calendar, Messages, Mail, and other native macOS apps, use `osascript`:
        
        ### Reminders:
        - Create reminder (default list): `osascript -e 'tell application "Reminders" to make new reminder with properties {name:"<text>"}'`
        - Create in specific list: `osascript -e 'tell application "Reminders" to make new reminder at end of list "<ListName>" with properties {name:"<text>"}'`
        - With due date: `osascript -e 'tell application "Reminders" to make new reminder with properties {name:"<text>", due date:date "12/25/2024 3:00 PM"}'`
        - ⚠️ Do NOT use `reminders list 1` syntax - it causes errors. Use `list "<name>"` or omit the list entirely.
        
        ### Notes:
        - Create note: `osascript -e 'tell application "Notes" to make new note at folder "Notes" with properties {name:"<title>", body:"<content>"}'`
        
        ### Calendar:
        - Create event: `osascript -e 'tell application "Calendar" to tell calendar "<CalendarName>" to make new event with properties {summary:"<title>", start date:date "<date>", end date:date "<date>"}'`
        
        ### Messages:
        - Send iMessage: `osascript -e 'tell application "Messages" to send "<message>" to buddy "<phone/email>"'`
        
        ### General Pattern:
        Always use `osascript -e 'tell application "<AppName>" to ...'` for native app automation.
        
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

        
        // Check streaming setting
        let enableStreaming = SettingsStore.shared.enableAIStreaming
        
        // Build request
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": [TerminalService.toolDefinition],
            "tool_choice": "auto",
            "temperature": 0.1
        ]
        
        if enableStreaming {
            body["stream"] = true
        }
        
        let endpoint = baseURL.hasSuffix("/chat/completions") ? baseURL : "\(baseURL)/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "CommandMode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // Retry logic for transient network errors (DNS resolution, connection cold start)
        var lastError: Error?
        for attempt in 1...3 {
            do {
                if enableStreaming {
                    return try await processStreamingLLMResponse(request: request)
                } else {
                    return try await processNonStreamingLLMResponse(request: request)
                }
            } catch let error as URLError where error.code == .notConnectedToInternet || 
                                                 error.code == .timedOut ||
                                                 error.code == .networkConnectionLost ||
                                                 error.code == .cannotFindHost ||
                                                 error.code == .cannotConnectToHost {
                lastError = error
                if attempt < 3 {
                    // Wait before retry (exponential backoff: 200ms, 400ms)
                    try? await Task.sleep(nanoseconds: UInt64(200_000_000 * attempt))
                    continue
                }
            } catch {
                throw error  // Non-retryable error
            }
        }
        throw lastError ?? NSError(domain: "CommandMode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Network request failed after retries"])
    }
    
    // MARK: - Non-Streaming Response
    private func processNonStreamingLLMResponse(request: URLRequest) async throws -> LLMResponse {
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
        
        return parseMessageResponse(message)
    }
    
    // MARK: - Streaming Response with Real-time UI Updates
    private func processStreamingLLMResponse(request: URLRequest) async throws -> LLMResponse {
        streamingText = ""
        streamingBuffer = []
        lastUIUpdate = CFAbsoluteTimeGetCurrent()
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let errText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "CommandMode", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        
        var toolCallId: String?
        var toolCallName: String?
        var toolCallArguments = ""
        
        // Use efficient line-based iteration instead of byte-by-byte
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            
            guard line.hasPrefix("data:") else { continue }
            
            var jsonString = String(line.dropFirst(5))
            if jsonString.hasPrefix(" ") {
                jsonString = String(jsonString.dropFirst(1))
            }
            
            if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                continue
            }
            
            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any] else {
                continue
            }
            
            // Handle text content - use buffer to avoid O(n²) string concat
            if let content = delta["content"] as? String {
                streamingBuffer.append(content)
                
                // Adaptive throttle: slower updates as content grows (reduces SwiftUI layout overhead)
                let bufferLength = streamingBuffer.count
                let updateInterval: CFAbsoluteTime
                if bufferLength < 50 {
                    updateInterval = 0.016  // 60fps for first ~50 tokens
                } else if bufferLength < 200 {
                    updateInterval = 0.033  // 30fps for medium content
                } else {
                    updateInterval = 0.066  // 15fps for long content
                }
                
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastUIUpdate >= updateInterval {
                    lastUIUpdate = now
                    let fullContent = streamingBuffer.joined()
                    streamingText = fullContent
                    
                    // Push to notch for real-time display
                    if enableNotchOutput {
                        NotchContentState.shared.updateCommandStreamingText(fullContent)
                    }
                }
            }
            
            // Handle tool calls (streamed in parts)
            if let toolCalls = delta["tool_calls"] as? [[String: Any]],
               let toolCall = toolCalls.first {
                
                if let id = toolCall["id"] as? String {
                    toolCallId = id
                }
                
                if let function = toolCall["function"] as? [String: Any] {
                    if let name = function["name"] as? String {
                        toolCallName = name
                    }
                    if let args = function["arguments"] as? String {
                        toolCallArguments += args
                    }
                }
            }
        }
        
        // Final update - join buffer once at the end
        let fullContent = streamingBuffer.joined()
        if !fullContent.isEmpty {
            streamingText = fullContent
            if enableNotchOutput {
                NotchContentState.shared.updateCommandStreamingText(fullContent)
            }
        }
        
        // Small delay to let the final content render, then clear
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        
        streamingText = ""  // Clear streaming text when done
        streamingBuffer = []  // Clear buffer
        
        // Clear notch streaming text as well
        if enableNotchOutput {
            NotchContentState.shared.updateCommandStreamingText("")
        }
        
        // If we got a tool call, parse it
        if let name = toolCallName, name == "execute_terminal_command",
           let argsData = toolCallArguments.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
            
            let command = args["command"] as? String ?? ""
            let workDir = args["workingDirectory"] as? String
            let purpose = args["purpose"] as? String
            let callId = toolCallId ?? "call_\(UUID().uuidString.prefix(8))"
            
            return LLMResponse(
                content: fullContent,
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
            content: fullContent.isEmpty ? "I couldn't understand that." : fullContent,
            toolCall: nil
        )
    }
    
    // MARK: - Parse Message Helper
    private func parseMessageResponse(_ message: [String: Any]) -> LLMResponse {
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

