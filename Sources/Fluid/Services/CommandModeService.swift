import Combine
import Foundation

@MainActor
final class CommandModeService: ObservableObject {
    @Published var conversationHistory: [Message] = []
    @Published var isProcessing = false
    @Published var pendingCommand: PendingCommand? = nil
    @Published var currentStep: AgentStep? = nil
    @Published var streamingText: String = "" // Real-time streaming text for UI
    @Published var streamingThinkingText: String = "" // Real-time thinking tokens for UI
    @Published private(set) var currentChatID: String?

    private let terminalService = TerminalService()
    private let chatStore = ChatHistoryStore.shared
    private var currentTurnCount = 0
    private let maxTurns = 20
    private var didRequireConfirmationThisRun: Bool = false

    // Flag to enable notch output display
    var enableNotchOutput: Bool = true

    // Streaming UI update throttling - adaptive rate based on content length
    private var lastUIUpdate: CFAbsoluteTime = 0
    private var lastThinkingUIUpdate: CFAbsoluteTime = 0
    private var streamingBuffer: [String] = [] // Buffer tokens instead of string concat
    private var thinkingBuffer: [String] = [] // Buffer thinking tokens

    // MARK: - Initialization

    init() {
        // Load current chat from store
        self.loadCurrentChatFromStore()
    }

    private func loadCurrentChatFromStore() {
        if let session = chatStore.currentSession {
            self.currentChatID = session.id
            self.conversationHistory = session.messages.map { self.chatMessageToMessage($0) }
            self.syncToNotchState()
        } else {
            // Create new chat if none exists
            let newSession = self.chatStore.createNewChat()
            self.currentChatID = newSession.id
            self.conversationHistory = []
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
        let thinking: String? // Display-only: AI reasoning tokens (NOT sent to API)
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
            case thinking // AI reasoning
            case checking // Pre-flight verification
            case executing // Running command
            case verifying // Post-action check
            case success // Action completed
            case failure // Action failed
        }

        struct ToolCall: Equatable {
            let id: String
            let command: String
            let workingDirectory: String?
            let purpose: String? // Why this command is being run
        }

        init(role: Role, content: String, thinking: String? = nil, toolCall: ToolCall? = nil, stepType: StepType = .normal) {
            self.role = role
            self.content = content
            self.thinking = thinking
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
        self.conversationHistory.removeAll()
        self.pendingCommand = nil
        self.currentTurnCount = 0

        // Clear in store as well
        self.chatStore.clearCurrentChat()

        // Also clear notch state
        NotchContentState.shared.clearCommandOutput()
    }

    // MARK: - Chat Management

    /// Get recent chats for dropdown
    func getRecentChats() -> [ChatSession] {
        return self.chatStore.getRecentChats(excludingCurrent: false)
    }

    /// Create a new chat and switch to it
    func createNewChat() {
        // Can't switch while processing
        guard !self.isProcessing else { return }

        // Save current chat first
        self.saveCurrentChat()

        // Create new
        let newSession = self.chatStore.createNewChat()
        self.currentChatID = newSession.id
        self.conversationHistory = []
        self.pendingCommand = nil
        self.currentTurnCount = 0
        self.currentStep = nil

        // Clear notch state
        NotchContentState.shared.clearCommandOutput()
        NotchContentState.shared.refreshRecentChats()
    }

    /// Switch to a different chat by ID
    /// Returns false if switching is blocked (e.g., during processing)
    @discardableResult
    func switchToChat(id: String) -> Bool {
        // Can't switch while processing
        guard !self.isProcessing else { return false }

        // Don't switch to current
        guard id != self.currentChatID else { return true }

        // Save current chat first
        self.saveCurrentChat()

        // Load the target chat
        guard let session = chatStore.switchToChat(id: id) else { return false }

        self.currentChatID = session.id
        self.conversationHistory = session.messages.map { self.chatMessageToMessage($0) }
        self.pendingCommand = nil
        self.currentTurnCount = 0
        self.currentStep = nil

        // Sync to notch state
        self.syncToNotchState()
        NotchContentState.shared.refreshRecentChats()

        return true
    }

    /// Delete current chat and switch to next
    func deleteCurrentChat() {
        // Can't delete while processing
        guard !self.isProcessing else { return }

        self.chatStore.deleteCurrentChat()

        // Load the new current chat
        self.loadCurrentChatFromStore()
        NotchContentState.shared.refreshRecentChats()
    }

    /// Save current conversation to store
    func saveCurrentChat() {
        guard self.currentChatID != nil else { return }

        let messages = self.conversationHistory.map { self.messageToChatMessage($0) }
        self.chatStore.updateCurrentChat(messages: messages)
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

        for msg in self.conversationHistory {
            let role: NotchContentState.CommandOutputMessage.Role
            switch msg.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .tool: role = .status // Tool outputs shown as status in notch
            }

            // Skip tool outputs in notch (they're verbose)
            if msg.role == .tool { continue }

            NotchContentState.shared.addCommandMessage(role: role, content: msg.content)
        }
    }

    /// Process user voice/text command
    func processUserCommand(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        self.isProcessing = true
        self.currentTurnCount = 0
        self.didRequireConfirmationThisRun = false
        self.conversationHistory.append(Message(role: .user, content: text))

        // Auto-save after adding user message
        self.saveCurrentChat()

        // Push to notch
        if self.enableNotchOutput {
            NotchContentState.shared.addCommandMessage(role: .user, content: text)
            NotchContentState.shared.setCommandProcessing(true)
        }

        await self.processNextTurn()
    }

    /// Process follow-up command from notch input
    func processFollowUpCommand(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Add to both histories
        self.conversationHistory.append(Message(role: .user, content: text))
        NotchContentState.shared.addCommandMessage(role: .user, content: text)

        // Auto-save after adding user message
        self.saveCurrentChat()

        self.isProcessing = true
        self.didRequireConfirmationThisRun = false
        NotchContentState.shared.setCommandProcessing(true)

        await self.processNextTurn()
    }

    /// Execute pending command (after user confirmation)
    func confirmAndExecute() async {
        guard let pending = pendingCommand else { return }
        self.pendingCommand = nil
        self.isProcessing = true

        await self.executeCommand(pending.command, workingDirectory: pending.workingDirectory, callId: pending.id)
    }

    /// Cancel pending command
    func cancelPendingCommand() {
        self.pendingCommand = nil
        self.conversationHistory.append(Message(
            role: .assistant,
            content: "Command cancelled.",
            stepType: .failure
        ))
        self.isProcessing = false
        self.currentStep = nil
    }

    // MARK: - Agent Loop

    private func processNextTurn() async {
        if self.currentTurnCount >= self.maxTurns {
            let errorMsg = "Reached maximum steps limit. Please review the progress and continue if needed."
            self.conversationHistory.append(Message(
                role: .assistant,
                content: errorMsg,
                stepType: .failure
            ))
            self.isProcessing = false
            self.currentStep = .completed(false)

            // Auto-save on completion
            self.saveCurrentChat()

            self.captureCommandRunCompleted(success: false)

            // Push to notch
            if self.enableNotchOutput {
                NotchContentState.shared.addCommandMessage(role: .assistant, content: errorMsg)
                NotchContentState.shared.setCommandProcessing(false)
                self.showExpandedNotchIfNeeded()
            }
            return
        }

        self.currentTurnCount += 1
        self.currentStep = .thinking("Analyzing...")

        // Push status to notch
        if self.enableNotchOutput {
            NotchContentState.shared.addCommandMessage(role: .status, content: "Thinking...")
        }

        do {
            let response = try await callLLM()

            if let tc = response.toolCall {
                // Determine step type based on command purpose
                let stepType = self.determineStepType(for: tc.command, purpose: tc.purpose)
                self.currentStep = stepType == .checking ? .checking(tc.command) : .executing(tc.command)

                // AI wants to run a command - include thinking for display
                self.conversationHistory.append(Message(
                    role: .assistant,
                    content: response.content.isEmpty ? self.stepDescription(for: stepType) : response.content,
                    thinking: response.thinking, // Display-only
                    toolCall: Message.ToolCall(
                        id: tc.id,
                        command: tc.command,
                        workingDirectory: tc
                            .workingDirectory,
                        purpose: tc.purpose
                    ),
                    stepType: stepType
                ))

                // Push step to notch
                if self.enableNotchOutput {
                    let statusText = tc.purpose ?? self.stepDescription(for: stepType)
                    NotchContentState.shared.addCommandMessage(role: .status, content: statusText)
                }

                // Check if we need confirmation for destructive commands
                if SettingsStore.shared.commandModeConfirmBeforeExecute, self.isDestructiveCommand(tc.command) {
                    self.didRequireConfirmationThisRun = true
                    self.pendingCommand = PendingCommand(
                        id: tc.id,
                        command: tc.command,
                        workingDirectory: tc.workingDirectory,
                        purpose: tc.purpose
                    )
                    self.isProcessing = false
                    self.currentStep = nil

                    // Push confirmation needed to notch
                    if self.enableNotchOutput {
                        NotchContentState.shared.addCommandMessage(role: .status, content: "⚠️ Confirmation needed in Command Mode window")
                        NotchContentState.shared.setCommandProcessing(false)
                    }
                    return
                }

                // Auto-execute
                await self.executeCommand(tc.command, workingDirectory: tc.workingDirectory, callId: tc.id, purpose: tc.purpose)

            } else {
                // Just a text response - check if it's a final summary
                let isFinal = response.content.lowercased().contains("complete") ||
                    response.content.lowercased().contains("done") ||
                    response.content.lowercased().contains("success") ||
                    response.content.lowercased().contains("finished")

                self.conversationHistory.append(Message(
                    role: .assistant,
                    content: response.content,
                    thinking: response.thinking, // Display-only
                    stepType: isFinal ? .success : .normal
                ))
                self.isProcessing = false
                self.currentStep = .completed(isFinal)

                // Auto-save on completion
                self.saveCurrentChat()

                self.captureCommandRunCompleted(success: isFinal)

                // Push final response to notch and show expanded view
                if self.enableNotchOutput {
                    NotchContentState.shared.updateCommandStreamingText("") // Clear streaming
                    NotchContentState.shared.addCommandMessage(role: .assistant, content: response.content)
                    NotchContentState.shared.setCommandProcessing(false)
                    self.showExpandedNotchIfNeeded()
                }
            }

        } catch {
            let errorMsg = "Error: \(error.localizedDescription)"
            self.conversationHistory.append(Message(
                role: .assistant,
                content: errorMsg,
                stepType: .failure
            ))
            self.isProcessing = false
            self.currentStep = .completed(false)

            // Auto-save on error
            self.saveCurrentChat()

            self.captureCommandRunCompleted(success: false)

            // Push error to notch
            if self.enableNotchOutput {
                NotchContentState.shared.addCommandMessage(role: .assistant, content: errorMsg)
                NotchContentState.shared.setCommandProcessing(false)
                self.showExpandedNotchIfNeeded()
            }
        }
    }

    private func captureCommandRunCompleted(success: Bool) {
        let toolCalls = self.conversationHistory.compactMap { $0.toolCall }.count
        let turns = self.currentTurnCount

        let turnsBucket: String
        switch turns {
        case ...1: turnsBucket = "1"
        case 2...3: turnsBucket = "2-3"
        case 4...7: turnsBucket = "4-7"
        case 8...20: turnsBucket = "8-20"
        default: turnsBucket = "20+"
        }

        let toolCallsBucket: String
        switch toolCalls {
        case 0: toolCallsBucket = "0"
        case 1...2: toolCallsBucket = "1-2"
        case 3...5: toolCallsBucket = "3-5"
        default: toolCallsBucket = "6+"
        }

        AnalyticsService.shared.capture(
            .commandModeRunCompleted,
            properties: [
                "success": success,
                "turns_bucket": turnsBucket,
                "tool_calls_bucket": toolCallsBucket,
                "confirmation_needed": self.didRequireConfirmationThisRun,
            ]
        )
    }

    /// Show expanded notch output if there's content to display
    private func showExpandedNotchIfNeeded() {
        guard self.enableNotchOutput else { return }
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
            cmd.hasPrefix("stat ") || cmd.hasPrefix("head ") || cmd.hasPrefix("tail ")
        {
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
            "mv ", "mv\t", // move/rename
            "sudo ", // elevated privileges
            "kill ", "pkill ", "killall ", // terminate processes
            "chmod ", "chown ", "chgrp ", // change permissions/ownership
            "dd ", // disk operations
            "mkfs", "format", // filesystem formatting
            "> ", // overwrite file
            "truncate ", // truncate file
            "shred ", // secure delete
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
        self.currentStep = .executing(command)

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
        self.conversationHistory.append(Message(
            role: .tool,
            content: resultJSON,
            stepType: resultStepType
        ))

        // Continue the loop - let the AI see the result and decide what to do next
        await self.processNextTurn()
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
               let json = String(data: data, encoding: .utf8)
            {
                return json
            }
            return """
            {"success": \(self.success), "output": "\(self.output)", "exitCode": \(self.exitCode)}
            """
        }
    }

    // MARK: - LLM Integration

    private struct LLMResponse {
        let content: String
        let thinking: String? // Display-only, NOT sent back to API
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
        let apiKey = settings.getAPIKey(for: providerID) ?? ""

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
            ["role": "system", "content": systemPrompt],
        ]

        // Add conversation history
        var lastToolCallId: String? = nil

        for msg in self.conversationHistory {
            switch msg.role {
            case .user:
                messages.append(["role": "user", "content": msg.content])
            case .assistant:
                if let tc = msg.toolCall {
                    lastToolCallId = tc.id
                    let argsJSON: String
                    do {
                        let data = try JSONSerialization.data(withJSONObject: [
                            "command": tc.command,
                            "workingDirectory": tc.workingDirectory ?? "",
                        ])
                        argsJSON = String(data: data, encoding: .utf8) ?? "{}"
                    } catch {
                        DebugLogger.shared.error("Failed to encode tool call args: \(error)", source: "CommandModeService")
                        argsJSON = "{}"
                    }
                    messages.append([
                        "role": "assistant",
                        "content": msg.content,
                        "tool_calls": [[
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": "execute_terminal_command",
                                "arguments": argsJSON,
                            ],
                        ]],
                    ])
                } else {
                    messages.append(["role": "assistant", "content": msg.content])
                }
            case .tool:
                messages.append([
                    "role": "tool",
                    "content": msg.content,
                    "tool_call_id": lastToolCallId ?? "call_unknown",
                ])
            }
        }

        // Check streaming setting
        let enableStreaming = SettingsStore.shared.enableAIStreaming

        // Reasoning models (o1, o3, gpt-5) don't support temperature parameter at all
        let isReasoningModel = settings.isReasoningModel(model)

        // Get reasoning config for this model (e.g., reasoning_effort, enable_thinking)
        let reasoningConfig = SettingsStore.shared.getReasoningConfig(forModel: model, provider: providerID)
        var extraParams: [String: Any] = [:]
        if let rConfig = reasoningConfig, rConfig.isEnabled {
            if rConfig.parameterName == "enable_thinking" {
                extraParams = [rConfig.parameterName: rConfig.parameterValue == "true"]
            } else {
                extraParams = [rConfig.parameterName: rConfig.parameterValue]
            }
            DebugLogger.shared.debug("Added reasoning param: \(rConfig.parameterName)=\(rConfig.parameterValue)", source: "CommandModeService")
        }

        // Reset streaming state
        self.streamingText = ""
        self.streamingThinkingText = ""
        self.streamingBuffer = []
        self.thinkingBuffer = []
        self.lastUIUpdate = CFAbsoluteTimeGetCurrent()
        self.lastThinkingUIUpdate = CFAbsoluteTimeGetCurrent()

        // Build LLMClient configuration
        var config = LLMClient.Config(
            messages: messages,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            streaming: enableStreaming,
            tools: [TerminalService.toolDefinition],
            temperature: isReasoningModel ? nil : 0.1,
            maxTokens: isReasoningModel ? 32_000 : nil, // Reasoning models like o1 need a large budget for extended thought chains
            extraParameters: extraParams
        )

        // Keep retry logic (exponential backoff)
        config.maxRetries = 3
        config.retryDelayMs = 200

        // Add real-time streaming callbacks for UI updates (60fps throttled)
        if enableStreaming {
            // Thinking tokens callback
            config.onThinkingChunk = { [weak self] (chunk: String) in
                guard let self = self else { return }
                Task { @MainActor in
                    self.thinkingBuffer.append(chunk)

                    // 60fps UI update throttle for thinking
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - self.lastThinkingUIUpdate >= 0.016 {
                        self.lastThinkingUIUpdate = now
                        self.streamingThinkingText = self.thinkingBuffer.joined()
                    }
                }
            }

            // Content callback
            config.onContentChunk = { [weak self] (chunk: String) in
                guard let self = self else { return }
                Task { @MainActor in
                    self.streamingBuffer.append(chunk)

                    // 60fps UI update throttle
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - self.lastUIUpdate >= 0.016 {
                        self.lastUIUpdate = now
                        let fullContent = self.streamingBuffer.joined()
                        self.streamingText = fullContent

                        // Push to notch for real-time display
                        if self.enableNotchOutput {
                            NotchContentState.shared.updateCommandStreamingText(fullContent)
                        }
                    }
                }
            }
        }

        DebugLogger.shared.info("Using LLMClient for Command Mode (streaming=\(enableStreaming), messages=\(messages.count), history=\(self.conversationHistory.count))", source: "CommandModeService")

        let response = try await LLMClient.shared.call(config)

        // Final UI update - ensure all content is displayed
        let fullContent = self.streamingBuffer.joined()
        if !fullContent.isEmpty {
            self.streamingText = fullContent
            if self.enableNotchOutput {
                NotchContentState.shared.updateCommandStreamingText(fullContent)
            }
        }

        // Small delay to let the final content render, then clear
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Capture final thinking before clearing (for message storage)
        let finalThinking = response.thinking ?? (self.thinkingBuffer.isEmpty ? nil : self.thinkingBuffer.joined())

        self.streamingText = "" // Clear streaming text when done
        self.streamingThinkingText = "" // Clear thinking text when done
        self.streamingBuffer = [] // Clear buffer
        self.thinkingBuffer = [] // Clear thinking buffer

        // Clear notch streaming text as well
        if self.enableNotchOutput {
            NotchContentState.shared.updateCommandStreamingText("")
        }

        // Log thinking if present (for debugging)
        if let thinking = finalThinking {
            DebugLogger.shared.debug("LLM thinking tokens extracted (\(thinking.count) chars)", source: "CommandModeService")
        }

        // Convert LLMClient.Response to our internal LLMResponse
        // Check for tool calls
        if let tc = response.toolCalls.first,
           tc.name == "execute_terminal_command"
        {
            let command = tc.getString("command") ?? ""
            let workDir = tc.getOptionalString("workingDirectory")
            let purpose = tc.getString("purpose")

            return LLMResponse(
                content: response.content,
                thinking: finalThinking, // Display-only
                toolCall: LLMResponse.ToolCallData(
                    id: tc.id,
                    command: command,
                    workingDirectory: workDir,
                    purpose: purpose
                )
            )
        }

        // Text response only
        return LLMResponse(
            content: response.content.isEmpty ? "I couldn't understand that." : response.content,
            thinking: finalThinking, // Display-only
            toolCall: nil
        )
    }
}
