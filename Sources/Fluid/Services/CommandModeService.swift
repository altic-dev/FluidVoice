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

    private var shouldSyncCommandNotchState: Bool {
        self.enableNotchOutput && NotchOverlayManager.shared.shouldSyncCommandConversationToNotch
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
        guard self.shouldSyncCommandNotchState else {
            return
        }

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
    func processUserCommand(_ text: String, notifyInvalidRequest: Bool = false) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        AnalyticsService.shared.recordUsage(
            mode: .command,
            aiModel: SettingsStore.shared.analyticsAIModelDescriptor(for: .command)
        )

        self.isProcessing = true
        self.currentTurnCount = 0
        self.conversationHistory.append(Message(role: .user, content: text))

        // Auto-save after adding user message
        self.saveCurrentChat()

        // Push to notch
        if self.shouldSyncCommandNotchState {
            NotchContentState.shared.addCommandMessage(role: .user, content: text)
            NotchContentState.shared.setCommandProcessing(true)
        }

        await self.processNextTurn(notifyInvalidRequest: notifyInvalidRequest)
    }

    /// Process follow-up command from notch input
    func processFollowUpCommand(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        AnalyticsService.shared.recordUsage(
            mode: .command,
            aiModel: SettingsStore.shared.analyticsAIModelDescriptor(for: .command)
        )

        // Add to both histories
        self.conversationHistory.append(Message(role: .user, content: text))
        if self.shouldSyncCommandNotchState {
            NotchContentState.shared.addCommandMessage(role: .user, content: text)
        }

        // Auto-save after adding user message
        self.saveCurrentChat()

        self.isProcessing = true
        if self.shouldSyncCommandNotchState {
            NotchContentState.shared.setCommandProcessing(true)
        }

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

    private func processNextTurn(notifyInvalidRequest: Bool = false) async {
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

            // Push to notch
            if self.shouldSyncCommandNotchState {
                NotchContentState.shared.addCommandMessage(role: .assistant, content: errorMsg)
                NotchContentState.shared.setCommandProcessing(false)
                self.showExpandedNotchIfNeeded()
            }
            return
        }

        self.currentTurnCount += 1
        self.currentStep = .thinking("Analyzing...")

        // Push status to notch
        if self.shouldSyncCommandNotchState {
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
                if self.shouldSyncCommandNotchState {
                    let statusText = tc.purpose ?? self.stepDescription(for: stepType)
                    NotchContentState.shared.addCommandMessage(role: .status, content: statusText)
                }

                // Check if we need confirmation for destructive commands
                if SettingsStore.shared.commandModeConfirmBeforeExecute, Self.isDestructiveCommand(tc.command) {
                    self.pendingCommand = PendingCommand(
                        id: tc.id,
                        command: tc.command,
                        workingDirectory: tc.workingDirectory,
                        purpose: tc.purpose
                    )
                    self.isProcessing = false
                    self.currentStep = nil

                    // Push confirmation needed to notch
                    if self.shouldSyncCommandNotchState {
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

                // Push final response to notch and show expanded view
                if self.shouldSyncCommandNotchState {
                    NotchContentState.shared.updateCommandStreamingText("") // Clear streaming
                    NotchContentState.shared.addCommandMessage(role: .assistant, content: response.content)
                    NotchContentState.shared.setCommandProcessing(false)
                    self.showExpandedNotchIfNeeded()
                }
            }

        } catch {
            let errorMsg: String
            if case LLMError.invalidRequest = error {
                errorMsg = error.localizedDescription
            } else {
                errorMsg = "Error: \(error.localizedDescription)"
            }
            DebugLogger.shared.error("Command mode failed: \(error.localizedDescription)", source: "CommandModeService")
            if notifyInvalidRequest, case LLMError.invalidRequest = error {
                NotificationService.showCommandModeFailure(error: errorMsg)
            }
            self.conversationHistory.append(Message(
                role: .assistant,
                content: errorMsg,
                stepType: .failure
            ))
            self.isProcessing = false
            self.currentStep = .completed(false)

            // Auto-save on error
            self.saveCurrentChat()

            // Push error to notch
            if self.shouldSyncCommandNotchState {
                NotchContentState.shared.addCommandMessage(role: .assistant, content: errorMsg)
                NotchContentState.shared.setCommandProcessing(false)
                self.showExpandedNotchIfNeeded()
            }
        }
    }

    /// Show expanded notch output if there's content to display
    private func showExpandedNotchIfNeeded() {
        guard self.shouldSyncCommandNotchState else { return }
        guard NotchOverlayManager.shared.canShowExpandedCommandOutput else { return }
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

    private static let destructiveCommandNames: Set<String> = [
        "rm", "rmdir", "mv", "sudo", "kill", "pkill", "killall",
        "chmod", "chown", "chgrp", "dd", "shred", "truncate", "format",
    ]

    private static let destructiveDiskutilSubcommands: Set<String> = [
        "erasedisk", "erasevolume", "secureerase",
        "reformat", "partitiondisk", "zerodisk", "unmountdisk",
    ]

    /// Splits a full command into the individual commands a shell would run, on unquoted
    /// `&&`, `||`, `;`, `&`, `|`, and newline. Every prior version of this classifier only
    /// ever looked at the leading token of the whole string, so anything after a separator
    /// -- `cd /tmp && rm -rf victim` -- was invisible to it. This makes every command in a
    /// chain go through the same check, at whatever position it's in.
    ///
    /// Doesn't handle backslash-escaped separators (`\;`) -- an escaped operator inside a
    /// `find -exec ... \;` gets split as if it were real, but the -exec/rm detection below
    /// checks word membership on the resulting pieces rather than the exact tail, so it
    /// still matches correctly. A real escape-aware parser would be needed to do better,
    /// and nothing here depends on it.
    private nonisolated static func splitIntoSimpleCommands(_ command: String) -> [String] {
        var commands: [String] = []
        var current = ""
        var quote: Character?
        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // A backslash escapes the next character (outside single quotes), so an
            // escaped separator like `find ... -exec rm {} \;` doesn't split here.
            // Both characters are kept verbatim -- tokenizeWords consumes the escape.
            if c == "\\", quote != "'", i + 1 < chars.count {
                current.append(c)
                current.append(chars[i + 1])
                i += 2
                continue
            }
            if let q = quote {
                current.append(c)
                if c == q { quote = nil }
                i += 1
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                current.append(c)
                i += 1
                continue
            }
            if c == "&" || c == "|" {
                if i + 1 < chars.count, chars[i + 1] == c {
                    i += 1  // swallow the doubled form (&&, ||) as one separator
                }
                commands.append(current)
                current = ""
                i += 1
                continue
            }
            if c == ";" || c == "\n" {
                commands.append(current)
                current = ""
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        commands.append(current)
        return commands
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Tokenizes one simple command into words, tracking quote state so a quoted span
    /// (single or double) stays one word even when it contains whitespace -- the gap that
    /// let `"/tmp/tools dir/rm" file` resolve to `tools` instead of `rm`. Quote characters
    /// themselves are dropped from the output, the same way a shell would consume them,
    /// and a backslash escapes the next character (outside single quotes, where a shell
    /// treats it literally) so `/tmp/tools\ dir/rm` stays one word too.
    private nonisolated static func tokenizeWords(_ simpleCommand: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        var escaped = false
        for c in simpleCommand {
            if escaped {
                current.append(c)
                inWord = true
                escaped = false
                continue
            }
            if c == "\\", quote != "'" {
                escaped = true
                inWord = true
                continue
            }
            if let q = quote {
                if c == q {
                    quote = nil
                } else {
                    current.append(c)
                }
                inWord = true
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                inWord = true
                continue
            }
            if c == " " || c == "\t" {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
                continue
            }
            current.append(c)
            inWord = true
        }
        if inWord {
            words.append(current)
        }
        return words
    }

    /// `NAME=value` in leading position is a real shell feature -- it scopes an
    /// environment variable to the command that follows, not a command itself.
    /// `LC_ALL=C rm -rf victim` runs `rm`, not `lc_all=c`.
    private nonisolated static func isEnvironmentAssignmentWord(_ word: String) -> Bool {
        guard let equalsIndex = word.firstIndex(of: "=") else { return false }
        let name = word[word.startIndex..<equalsIndex]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Utilities that take another program as an argument and run it. The destructive
    /// program is never this simple command's own leading word, so each argument has to
    /// be considered a candidate command in its own right.
    private static let commandRunnerNames: Set<String> = [
        "xargs", "env", "nohup", "command", "exec", "time", "nice",
        "setsid", "stdbuf", "timeout", "watch", "sudo",
    ]

    /// Shells whose `-c` payload is itself a shell command, so it can be parsed with the
    /// same machinery rather than treated as an opaque string. Distinct from a general
    /// interpreter (`python3 -c`), whose payload is a different language entirely and is
    /// out of reach of this classifier.
    private static let shellInterpreterNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh",
    ]

    /// True if any word, resolved to its basename, names a destructive program.
    /// Anywhere a program can appear as an argument rather than as argv[0], the same
    /// basename resolution the leading command gets has to apply -- comparing raw words
    /// misses `/bin/rm` in exactly the places the leading-word check would have caught it.
    private nonisolated static func containsDestructiveProgram(
        _ words: ArraySlice<String>
    ) -> Bool {
        words.contains { word in
            let name = (word as NSString).lastPathComponent
            return destructiveCommandNames.contains(name) || name.hasPrefix("mkfs")
        }
    }

    /// Classifies one already-split simple command. `words` is already lowercase and
    /// tokenized, so this only ever deals with correctly-resolved argv, not raw text.
    /// `depth` bounds recursion into nested shell payloads.
    private nonisolated static func isDestructiveSimpleCommand(
        _ words: [String],
        depth: Int
    ) -> Bool {
        guard !words.isEmpty else { return false }

        // A bare truncating/creating redirect, `> file` or `>> file`, anywhere in the
        // command's own words, including as the very first one (`> file` alone is a
        // complete, valid, destructive command).
        if words.contains(where: { $0 == ">" || $0 == ">>" }) {
            return true
        }

        let remaining = words.drop(while: isEnvironmentAssignmentWord)
        guard let rawCommand = remaining.first else { return false }

        // Absolute and relative paths resolve to the same bare name a shell would use
        // (`/bin/rm`, `/usr/bin/rm`, and bare `rm` are all just `rm`), so this alone
        // covers what used to need a separate prefix-list plus a path-resolution pass.
        let commandName = (rawCommand as NSString).lastPathComponent

        if destructiveCommandNames.contains(commandName) || commandName.hasPrefix("mkfs") {
            return true
        }

        // `find -delete` / `find ... -exec rm ...` deletes without ever matching a
        // bare command name, since `find` itself isn't destructive. The -exec target
        // can be path-qualified like any other program reference.
        if commandName == "find" {
            if remaining.contains("-delete") { return true }
            if remaining.contains("-exec") || remaining.contains("-execdir") {
                if containsDestructiveProgram(remaining.dropFirst()) { return true }
            }
        }

        // diskutil's erase/reformat/partition subcommands are as destructive as
        // `dd`/`mkfs`/`format` but are a different binary and weren't covered by any
        // check above. Scoped to the destructive subcommands specifically so read-only
        // uses (`diskutil list`, `diskutil info`) aren't flagged. `quiet` is a real
        // diskutil modifier that can precede the verb (`diskutil quiet eraseDisk ...`),
        // so it's skipped rather than read as the verb itself.
        if commandName == "diskutil" {
            let subcommand = remaining.dropFirst().drop(while: { $0 == "quiet" }).first ?? ""
            if destructiveDiskutilSubcommands.contains(subcommand) {
                return true
            }
        }

        // `xargs rm`, `env rm`, `nohup rm`, `sudo rm` -- the program that actually runs
        // is an argument here, not argv[0].
        if commandRunnerNames.contains(commandName) {
            if containsDestructiveProgram(remaining.dropFirst()) { return true }
        }

        // `sh -c 'rm -rf victim'` -- the payload is a shell command, so run it back
        // through the same parse instead of treating it as an opaque argument.
        if shellInterpreterNames.contains(commandName), depth < maxShellRecursionDepth {
            for argument in remaining.dropFirst() where !argument.hasPrefix("-") {
                if isDestructiveCommand(argument, depth: depth + 1) { return true }
            }
        }

        return false
    }

    /// Bounds `sh -c '...'` nesting so a pathological payload can't recurse without end.
    private static let maxShellRecursionDepth = 4

    private nonisolated static func isDestructiveCommand(_ command: String, depth: Int) -> Bool {
        let simpleCommands = splitIntoSimpleCommands(command.lowercased())
        return simpleCommands.contains {
            isDestructiveSimpleCommand(tokenizeWords($0), depth: depth)
        }
    }

    nonisolated static func isDestructiveCommand(_ command: String) -> Bool {
        isDestructiveCommand(command, depth: 0)
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
        if let issue = settings.commandModeReadinessIssue {
            throw LLMError.invalidRequest(issue)
        }

        let providerID = settings.effectiveCommandModeProviderID
        let model = settings.effectiveCommandModeSelectedModel
        let apiKey = settings.getAPIKey(for: providerID) ?? ""

        let baseURL: String
        if let provider = settings.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = provider.baseURL
        } else if ModelRepository.shared.isBuiltIn(providerID) {
            baseURL = ModelRepository.shared.defaultBaseURL(for: providerID)
        } else {
            baseURL = ""
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
        let isTemperatureUnsupported = settings.isTemperatureUnsupported(model)

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
            temperature: isTemperatureUnsupported ? nil : 0.1,
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
                        if self.shouldSyncCommandNotchState {
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
            if self.shouldSyncCommandNotchState {
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
        if self.shouldSyncCommandNotchState {
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

        if response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DebugLogger.shared.error(
                "Command mode LLM returned empty content with no tool calls (model=\(model), provider=\(providerID))",
                source: "CommandModeService"
            )
            throw LLMError.invalidResponse
        }

        // Text response only
        return LLMResponse(
            content: response.content,
            thinking: finalThinking, // Display-only
            toolCall: nil
        )
    }
}
