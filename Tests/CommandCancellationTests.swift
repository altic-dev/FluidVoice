import Foundation

// Shadows Foundation.UserDefaults so the real chat store never accesses app preferences.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    var writes = 0
    func data(forKey key: String) -> Data? { self.values[key] as? Data }
    func string(forKey key: String) -> String? { self.values[key] as? String }
    func set(_ value: Any?, forKey key: String) { self.values[key] = value; self.writes += 1 }
}

@MainActor final class TerminalService {
    struct CommandResult: Codable {
        let success: Bool
        let command: String
        let output: String
        let error: String?
        let exitCode: Int32
        let executionTimeMs: Int
    }

    static let toolDefinition: [String: Any] = [:]
    static var executed: [String] = []
    static var delay = false
    static var pending: CheckedContinuation<CommandResult, Never>?
    func execute(command: String, workingDirectory: String?) async -> CommandResult {
        Self.executed.append(command)
        if Self.delay {
            return await withCheckedContinuation { Self.pending = $0 }
        }
        return Self.result(command)
    }

    static func result(_ command: String) -> CommandResult {
        .init(success: true, command: command, output: "fake output", error: nil, exitCode: 0, executionTimeMs: 1)
    }
}

@MainActor final class SettingsStore {
    enum Mode { case command }
    struct Provider { let id: String; let baseURL: String }
    struct ReasoningConfig { let isEnabled: Bool; let parameterName: String; let parameterValue: String }
    static let shared = SettingsStore()
    var commandModeConfirmBeforeExecute = false
    let commandModeReadinessIssue: String? = nil
    let effectiveCommandModeProviderID = "fake"
    let effectiveCommandModeSelectedModel = "fake"
    let savedProviders = [Provider(id: "fake", baseURL: "https://fake.invalid")]
    let enableAIStreaming = true
    func analyticsAIModelDescriptor(for mode: Mode) -> String { "fake" }
    func getAPIKey(for provider: String) -> String? { nil }
    func isReasoningModel(_ model: String) -> Bool { false }
    func isTemperatureUnsupported(_ model: String) -> Bool { false }
    func getReasoningConfig(forModel: String, provider: String) -> ReasoningConfig? { nil }
}

@MainActor final class ModelRepository {
    static let shared = ModelRepository()
    func isBuiltIn(_ provider: String) -> Bool { false }
    func defaultBaseURL(for provider: String) -> String { "" }
}

@MainActor final class AnalyticsService {
    static let shared = AnalyticsService()
    func recordUsage(mode: SettingsStore.Mode, aiModel: String) {}
}

@MainActor final class MeetingSummaryActivityCoordinator {
    static let shared = MeetingSummaryActivityCoordinator()
    private var processing = Set<UUID>()
    var active: Bool { !self.processing.isEmpty }
    func beginProcessing() -> UUID? {
        let token = UUID()
        self.processing.insert(token)
        return token
    }

    func endProcessing(_ id: UUID) { self.processing.remove(id) }
    static var busyErrors = 0
    static func presentBusyError() { self.busyErrors += 1 }
}

@MainActor final class NotificationService {
    static var failures = 0
    static func showCommandModeFailure(error: String) { self.failures += 1 }
}

@MainActor final class DebugLogger {
    static let shared = DebugLogger()
    var errors = 0
    func debug(_ message: String, source: String) {}
    func info(_ message: String, source: String) {}
    func error(_ message: String, source: String) { self.errors += 1 }
}

@MainActor final class NotchOverlayManager {
    static let shared = NotchOverlayManager()
    var shouldSyncCommandConversationToNotch = true
    var canShowExpandedCommandOutput = true
    var shows = 0
    func showExpandedCommandOutput() { self.shows += 1 }
}

@MainActor final class NotchContentState {
    struct CommandOutputMessage: Equatable {
        enum Role { case user, assistant, status }
        let role: Role
        let content: String
    }

    static let shared = NotchContentState()
    var commandConversationHistory: [CommandOutputMessage] = []
    var processing = false
    var streaming = ""
    var nonemptyStreamUpdates = 0
    func clearCommandOutput() { self.commandConversationHistory = [] }
    func refreshRecentChats() {}
    func addCommandMessage(role: CommandOutputMessage.Role, content: String) {
        self.commandConversationHistory.append(.init(role: role, content: content))
    }

    func setCommandProcessing(_ value: Bool) { self.processing = value }
    func updateCommandStreamingText(_ text: String) {
        self.streaming = text
        if !text.isEmpty { self.nonemptyStreamUpdates += 1 }
    }
}

enum LLMError: Error { case invalidRequest(String), invalidResponse }
@MainActor final class LLMClient {
    struct ToolCall {
        let id: String
        let name = "execute_terminal_command"
        let command: String
        func getString(_ key: String) -> String? { key == "command" ? self.command : nil }
        func getOptionalString(_ key: String) -> String? { nil }
    }

    struct Response {
        let content: String
        let thinking: String?
        let toolCalls: [ToolCall]
        static let done = Self(content: "Done", thinking: nil, toolCalls: [])
        static let tool = Self(content: "Run tool", thinking: nil, toolCalls: [.init(id: "tool", command: "fake command")])
    }

    struct Config {
        let messages: [[String: Any]]
        var maxRetries = 0
        var retryDelayMs = 0
        var onThinkingChunk: (@Sendable (String) -> Void)?
        var onContentChunk: (@Sendable (String) -> Void)?
        init(
            messages: [[String: Any]],
            model: String,
            baseURL: String,
            apiKey: String,
            streaming: Bool,
            tools: [[String: Any]],
            temperature: Double?,
            maxTokens: Int?,
            extraParameters: [String: Any]
        ) {
            self.messages = messages
        }
    }

    static let shared = LLMClient()
    var configs: [Config] = []
    var delay = true
    var delayOnCallNumber: Int?
    var responses: [Response] = []
    var pending: CheckedContinuation<Response, Error>?
    func call(_ config: Config) async throws -> Response {
        self.configs.append(config)
        if self.delay || self.delayOnCallNumber == self.configs.count {
            defer { self.pending = nil }
            return try await withCheckedThrowingContinuation { self.pending = $0 }
        }
        return self.responses.isEmpty ? .done : self.responses.removeFirst()
    }

    func reset() { self.configs = []; self.responses = []; self.delay = true; self.delayOnCallNumber = nil; self.pending = nil }
}

@MainActor final class CommandMenuDouble {
    var updates: [Bool] = []
    func setProcessing(_ value: Bool) { self.updates.append(value) }
}

@MainActor final class CommandBoundaryDouble {
    let service: CommandModeService
    var afterRequest: (() -> Void)?
    var pendingCommand: CommandModeService.PendingCommand? { self.service.pendingCommand }
    init(_ service: CommandModeService) { self.service = service }
    func processUserCommand(_ text: String, notifyInvalidRequest: Bool, isOutputValid: @escaping @MainActor () -> Bool) async {
        await self.service.processUserCommand(text, notifyInvalidRequest: notifyInvalidRequest, isOutputValid: isOutputValid)
        self.afterRequest?()
    }

    @discardableResult func cancelInvalidPendingCommand() -> Bool { self.service.cancelInvalidPendingCommand() }
}

@MainActor final class VoiceCommandOwner {
    var overlayLifecycleID: UInt64 = 7
    var cancelledOutputLifecycleID: UInt64?
    var pendingVoiceCommandLifecycleID: UInt64?
    let commandModeService: CommandBoundaryDouble
    let menuBarManager = CommandMenuDouble()
    init(_ service: CommandModeService) { self.commandModeService = CommandBoundaryDouble(service) }
}

@MainActor final class NotchInputOwner {
    var inputText = ""
    var onSubmit: (String) async -> Bool = { _ in false }
}

@main @MainActor enum CommandCancellationTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        self.checks += 1
    }

    static func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        preconditionFailure("Timed out awaiting fake dependency")
    }

    static func fixture() -> CommandModeService {
        LLMClient.shared.reset()
        SettingsStore.shared.commandModeConfirmBeforeExecute = false
        TerminalService.executed = []
        TerminalService.delay = false
        TerminalService.pending = nil
        DebugLogger.shared.errors = 0
        NotificationService.failures = 0
        NotchOverlayManager.shared.shows = 0
        NotchContentState.shared.nonemptyStreamUpdates = 0
        let service = CommandModeService()
        service.clearHistory()
        return service
    }

    static func main() async {
        await self.cancelDelayedLLM(response: .tool)
        await self.cancelDelayedLLM(response: .done)
        await self.cancelDelayedLLMError()
        await self.cancelRunningTerminal(result: TerminalService.result("fake command"))
        await self.cancelRunningTerminal(result: .init(success: false, command: "fake command", output: "partial stdout", error: "actual failure", exitCode: 17, executionTimeMs: 42))
        await self.cancelAfterCompletedTool()
        await self.cancelRenderDelay()
        await self.validRecursiveToolRequestStillWorks()
        await self.validFollowUpAndConfirmationStillWork()
        await self.cancelVoiceConfirmation(cancelThroughEscape: true)
        await self.cancelVoiceConfirmation(cancelThroughEscape: false)
        await self.cancelVoiceConfirmationAfterCompletedTool()
        await self.confirmedVoiceDoesNotOwnLaterTypedConfirmation()
        await self.voiceConfirmationCancelledAtCallerContinuation()
        await self.notchInputClearsOnlyAcceptedText()
        await self.invalidRequestDoesNothing()
        self.check(MeetingSummaryActivityCoordinator.busyErrors == 0, "A canceled request left processing locked")
        print("Command cancellation: \(self.checks) checks passed (production agent loop, streaming callbacks, real in-memory chat store)")
    }

    static func cancelDelayedLLM(response: LLMClient.Response) async {
        let service = self.fixture()
        service.conversationHistory.append(.init(role: .assistant, content: "prior completed answer"))
        service.saveCurrentChat()
        NotchContentState.shared.addCommandMessage(role: .assistant, content: "prior completed answer")
        let messages = service.conversationHistory
        let savedMessages = ChatHistoryStore.shared.currentSession?.messages
        let notch = NotchContentState.shared.commandConversationHistory
        var valid = true
        let task = Task { await service.processUserCommand("voice", notifyInvalidRequest: true, isOutputValid: { valid }) }
        await self.waitFor { LLMClient.shared.pending != nil }
        let writes = UserDefaults.standard.writes
        // Every API entry must reject another command while the voice request awaits.
        await service.processUserCommand("interleaved typed command")
        let accepted = await service.processFollowUpCommand("interleaved follow-up")
        self.check(!accepted, "Blocked follow-up falsely reported acceptance")
        await service.confirmAndExecute()
        self.check(LLMClient.shared.configs.count == 1 && service.conversationHistory.count == messages.count + 1, "Another entry point interleaved with canceled request cleanup")
        valid = false
        // Both callbacks enqueue Tasks; the guards must live inside those Tasks.
        LLMClient.shared.configs[0].onContentChunk?("late content")
        LLMClient.shared.configs[0].onThinkingChunk?("late thinking")
        for _ in 0..<10 {
            await Task.yield()
        }
        self.check(service.streamingText.isEmpty && service.streamingThinkingText.isEmpty, "Canceled stream reached editor")
        self.check(NotchContentState.shared.nonemptyStreamUpdates == 0, "Canceled stream reached notch")
        LLMClient.shared.pending?.resume(returning: response)
        await task.value
        self.check(TerminalService.executed.isEmpty, "Canceled model response executed tool")
        self.check(LLMClient.shared.configs.count == 1, "Canceled response continued agent loop")
        self.check(service.conversationHistory == messages, "Undispatched canceled intent remained in conversation")
        self.check(ChatHistoryStore.shared.currentSession?.messages == savedMessages && UserDefaults.standard.writes == writes + 2, "Undispatched canceled intent remained in saved chat")
        self.check(CommandModeService().conversationHistory.map(\.content) == messages.map(\.content), "Reloaded chat revived canceled intent")
        self.check(NotchContentState.shared.commandConversationHistory == notch && NotchOverlayManager.shared.shows == 0, "Canceled response displayed output")
        self.check(!service.isProcessing && service.currentStep == nil && service.pendingCommand == nil && !NotchContentState.shared.processing, "Canceled request left pending UI")
        self.check(!MeetingSummaryActivityCoordinator.shared.active, "Canceled request left processing lock")
        // Keep the canceled callback false even while the next request succeeds.
        LLMClient.shared.delay = false
        await service.processUserCommand("typed next")
        self.check(service.conversationHistory.last?.content == "Done" && !service.isProcessing, "Next default request failed")
        self.check(LLMClient.shared.configs[1].messages.allSatisfy { $0["content"] as? String != "voice" }, "Next request inherited canceled intent")
        LLMClient.shared.configs[0].onContentChunk?("stale old callback")
        LLMClient.shared.configs[0].onThinkingChunk?("stale old thinking")
        for _ in 0..<10 {
            await Task.yield()
        }
        self.check(service.streamingText.isEmpty && service.streamingThinkingText.isEmpty, "Old canceled callback contaminated next request")
    }

    static func cancelDelayedLLMError() async {
        let service = self.fixture()
        let messages = service.conversationHistory
        var valid = true
        let task = Task { await service.processUserCommand("voice error", notifyInvalidRequest: true, isOutputValid: { valid }) }
        await self.waitFor { LLMClient.shared.pending != nil }
        let writes = UserDefaults.standard.writes
        valid = false
        LLMClient.shared.pending?.resume(throwing: LLMError.invalidRequest("fake failure"))
        await task.value
        self.check(service.conversationHistory == messages && UserDefaults.standard.writes == writes + 2, "Canceled model error left its undispatched intent in chat")
        self.check(CommandModeService().conversationHistory.map(\.content) == messages.map(\.content), "Reloaded error case revived canceled intent")
        self.check(DebugLogger.shared.errors == 0 && NotificationService.failures == 0 && NotchOverlayManager.shared.shows == 0, "Canceled model error published failure")
        self.check(!service.isProcessing, "Canceled error left processing flag")
    }

    static func cancelRunningTerminal(result: TerminalService.CommandResult) async {
        let service = self.fixture()
        LLMClient.shared.delay = false
        LLMClient.shared.responses = [.tool]
        TerminalService.delay = true
        var valid = true
        let task = Task { await service.processUserCommand("voice tool", isOutputValid: { valid }) }
        await self.waitFor { TerminalService.pending != nil }
        let messages = service.conversationHistory
        let writes = UserDefaults.standard.writes
        let notch = NotchContentState.shared.commandConversationHistory
        valid = false
        TerminalService.pending?.resume(returning: result)
        await task.value
        self.check(TerminalService.executed.count == 1, "Started terminal operation was duplicated")
        self.check(LLMClient.shared.configs.count == 1, "Canceled terminal result continued loop")
        let completion = service.conversationHistory.last
        self.check(
            service.conversationHistory.count == messages.count + 1 && Array(service.conversationHistory.dropLast()) == messages && completion?.role == .tool,
            "Canceled terminal did not append exactly its actual completion"
        )
        let completionJSON = completion?.content.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        self.check(
            completionJSON?["output"] as? String == result.output && completionJSON?["exitCode"] as? Int32 == result.exitCode && completionJSON?["success"] as? Bool == result.success,
            "Canceled terminal lost actual stdout, exit code, or success"
        )
        self.check(completionJSON?["error"] as? String == result.error && completion?.stepType == (result.success ? .success : .failure), "Canceled terminal lost actual error or result status")
        self.check(
            UserDefaults.standard.writes == writes + 2 && ChatHistoryStore.shared.currentSession?.messages.count == service.conversationHistory.count,
            "Canceled terminal completion was not persisted exactly once"
        )
        self.check(NotchContentState.shared.commandConversationHistory == notch && NotchOverlayManager.shared.shows == 0, "Canceled terminal result displayed output")
        self.check(!service.isProcessing && service.currentStep == nil, "Canceled terminal left pending UI")
        self.check(service.conversationHistory[messages.count - 1].toolCall?.command == "fake command", "Canceled terminal lost already-started execution evidence")
        await service.processUserCommand("next typed request")
        let nextMessages = LLMClient.shared.configs[1].messages
        let nextToolCalls = nextMessages.filter { $0["tool_calls"] != nil }
        let nextToolResults = nextMessages.filter { $0["role"] as? String == "tool" }
        self.check(nextToolCalls.count == 1 && nextToolResults.count == 1 && nextToolResults[0]["tool_call_id"] as? String == "tool", "Next request did not retain a valid completed tool pair")
        self.check(nextToolResults[0]["content"] as? String == completion?.content, "Next request lost the actual executed result")
        self.check(service.conversationHistory.last?.content == "Done" && !service.isProcessing, "Next request after terminal cancellation failed")
    }

    static func cancelAfterCompletedTool() async {
        let service = self.fixture()
        LLMClient.shared.delay = false
        LLMClient.shared.delayOnCallNumber = 2
        LLMClient.shared.responses = [.tool]
        var valid = true
        let task = Task { await service.processUserCommand("partially executed voice", isOutputValid: { valid }) }
        await self.waitFor { LLMClient.shared.pending != nil }
        let messages = service.conversationHistory
        let writes = UserDefaults.standard.writes
        valid = false
        LLMClient.shared.pending?.resume(returning: .tool)
        await task.value
        self.check(TerminalService.executed.count == 1 && LLMClient.shared.configs.count == 2, "Canceled second model turn executed another tool")
        self.check(service.conversationHistory == messages && messages.last?.role == .tool, "Cancellation removed completed execution evidence")
        self.check(UserDefaults.standard.writes == writes + 2 && ChatHistoryStore.shared.currentSession?.messages.count == messages.count, "Cancellation after a completed tool lost its saved result")
        self.check(CommandModeService().conversationHistory.map(\.content) == messages.map(\.content), "Reload lost completed tool output")
        self.check(!service.isProcessing && service.pendingCommand == nil && NotchOverlayManager.shared.shows == 0, "Canceled second turn left pending UI or reopened output")
    }

    static func cancelRenderDelay() async {
        let service = self.fixture()
        let messages = service.conversationHistory
        var valid = true
        let task = Task { await service.processUserCommand("voice render", isOutputValid: { valid }) }
        await self.waitFor { LLMClient.shared.pending != nil }
        LLMClient.shared.configs[0].onContentChunk?("live content")
        for _ in 0..<10 {
            await Task.yield()
        }
        LLMClient.shared.pending?.resume(returning: .tool)
        // The fake call has returned and production callLLM published its final buffer,
        // so the real agent is suspended in its existing 50ms rendering sleep.
        await self.waitFor { LLMClient.shared.pending == nil && service.streamingText == "live content" }
        valid = false
        let writes = UserDefaults.standard.writes
        await task.value
        self.check(TerminalService.executed.isEmpty && LLMClient.shared.configs.count == 1, "Cancellation during render delay executed a tool")
        self.check(service.conversationHistory == messages && UserDefaults.standard.writes == writes + 2, "Cancellation during render delay left its undispatched intent")
        self.check(!service.isProcessing, "Render-delay cancellation left pending UI")
    }

    static func validRecursiveToolRequestStillWorks() async {
        let service = self.fixture()
        LLMClient.shared.delay = false
        LLMClient.shared.responses = [.tool, .done]
        await service.processUserCommand("valid tool")
        self.check(TerminalService.executed == ["fake command"], "Valid tool failed")
        self.check(LLMClient.shared.configs.count == 2, "Valid tool did not continue agent loop")
        let requestMessages = LLMClient.shared.configs[1].messages
        let assistantCall = requestMessages.first { $0["tool_calls"] != nil }
        let toolResult = requestMessages.first { $0["role"] as? String == "tool" }
        self.check(assistantCall != nil && toolResult?["tool_call_id"] as? String == "tool", "Valid paired tool call lost its wire format")
        self.check(service.conversationHistory.map(\.role) == [.user, .assistant, .tool, .assistant], "Valid conversation lost messages")
        self.check(ChatHistoryStore.shared.currentSession?.messages.count == 4, "Valid request failed to persist")
        self.check(!service.isProcessing && NotchOverlayManager.shared.shows == 1, "Valid request did not finish visibly")
    }

    static func validFollowUpAndConfirmationStillWork() async {
        let followUp = self.fixture()
        LLMClient.shared.delay = false
        let accepted = await followUp.processFollowUpCommand("typed follow-up")
        self.check(accepted, "Normal follow-up was not accepted")
        self.check(followUp.conversationHistory.map(\.role) == [.user, .assistant] && !followUp.isProcessing, "Default follow-up stopped working")
        self.check(ChatHistoryStore.shared.currentSession?.messages.last?.content == "Done", "Default follow-up failed to persist")

        let confirmed = self.fixture()
        SettingsStore.shared.commandModeConfirmBeforeExecute = true
        LLMClient.shared.delay = false
        LLMClient.shared.responses = [.init(content: "Confirm removal", thinking: nil, toolCalls: [.init(id: "confirmed", command: "rm -rf fake")])]
        await confirmed.processUserCommand("typed destructive request")
        self.check(confirmed.pendingCommand != nil && TerminalService.executed.isEmpty, "Default confirmation did not defer terminal execution")
        self.check(!confirmed.cancelInvalidPendingCommand(), "Escape canceled a typed confirmation")
        await confirmed.confirmAndExecute()
        self.check(TerminalService.executed == ["rm -rf fake"] && confirmed.pendingCommand == nil && !confirmed.isProcessing, "Default confirmed command stopped working")
        self.check(confirmed.conversationHistory.map(\.role) == [.user, .assistant, .tool, .assistant], "Default confirmation lost its complete tool pair")
    }

    static var destructiveResponse: LLMClient.Response {
        .init(content: "Confirm removal", thinking: nil, toolCalls: [.init(id: "pending-voice", command: "rm -rf fake")])
    }

    static func cancelVoiceConfirmation(cancelThroughEscape: Bool) async {
        let service = self.fixture()
        SettingsStore.shared.commandModeConfirmBeforeExecute = true
        LLMClient.shared.delay = false
        LLMClient.shared.responses = [self.destructiveResponse]
        var valid = true
        await service.processUserCommand("undispatched voice deletion", isOutputValid: { valid })
        self.check(service.pendingCommand != nil && TerminalService.executed.isEmpty && !service.isProcessing, "Voice request did not defer for confirmation")
        let count = service.conversationHistory.count
        await service.processUserCommand("interleaved typed request")
        let accepted = await service.processFollowUpCommand("interleaved follow-up")
        self.check(!accepted, "Blocked follow-up falsely reported acceptance")
        self.check(service.conversationHistory.count == count && LLMClient.shared.configs.count == 1, "Another request replaced pending voice ownership")
        valid = false
        if cancelThroughEscape {
            self.check(service.cancelInvalidPendingCommand(), "Escape did not clear invalid voice confirmation")
        }
        await service.confirmAndExecute()
        self.check(service.pendingCommand == nil && TerminalService.executed.isEmpty && LLMClient.shared.configs.count == 1, "Canceled pending voice command remained executable")
        self.check(service.conversationHistory.isEmpty && ChatHistoryStore.shared.currentSession?.messages.isEmpty == true, "Canceled pending voice intent remained in chat")
        self.check(!service.cancelInvalidPendingCommand() && NotchOverlayManager.shared.shows == 0, "Repeated pending cancellation reopened output")
        await service.processUserCommand("next typed request")
        self.check(LLMClient.shared.configs[1].messages.allSatisfy { $0["content"] as? String != "undispatched voice deletion" }, "Next typed request revived canceled pending intent")
        self.check(service.conversationHistory.last?.content == "Done", "Next typed request after canceled confirmation failed")
    }

    static func cancelVoiceConfirmationAfterCompletedTool() async {
        let service = self.fixture()
        SettingsStore.shared.commandModeConfirmBeforeExecute = true
        LLMClient.shared.delay = false
        LLMClient.shared.responses = [.tool, self.destructiveResponse]
        var valid = true
        await service.processUserCommand("check then delete by voice", isOutputValid: { valid })
        self.check(TerminalService.executed == ["fake command"] && service.pendingCommand != nil, "Fixture did not execute one tool before deferred confirmation")
        valid = false
        self.check(service.cancelInvalidPendingCommand(), "Voice confirmation after completed tool was not canceled")
        await service.confirmAndExecute()
        self.check(TerminalService.executed == ["fake command"] && service.pendingCommand == nil, "Canceled second tool still executed")
        self.check(service.conversationHistory.map(\.role) == [.user, .assistant, .tool], "Pending cleanup damaged completed tool pair or retained undispatched tail")
        self.check(ChatHistoryStore.shared.currentSession?.messages.count == 3 && NotchOverlayManager.shared.shows == 0, "Pending cleanup lost saved execution evidence or reopened output")
        await service.processUserCommand("next typed request")
        let next = LLMClient.shared.configs[2].messages
        self.check(next.filter { $0["tool_calls"] != nil }.count == 1 && next.filter { $0["role"] as? String == "tool" }.count == 1, "Next request inherited an orphan pending tool call")
    }

    static func confirmedVoiceDoesNotOwnLaterTypedConfirmation() async {
        let service = self.fixture()
        SettingsStore.shared.commandModeConfirmBeforeExecute = true
        LLMClient.shared.delay = false
        LLMClient.shared.responses = [self.destructiveResponse]
        var valid = true
        await service.processUserCommand("explicitly confirmed voice", isOutputValid: { valid })
        await service.confirmAndExecute()
        self.check(TerminalService.executed.count == 1 && service.pendingCommand == nil, "Explicit voice confirmation did not execute normally")
        LLMClient.shared.responses = [self.destructiveResponse]
        await service.processUserCommand("later typed deletion")
        valid = false
        self.check(!service.cancelInvalidPendingCommand() && service.pendingCommand != nil, "Stale voice validity canceled a later typed confirmation with the same tool ID")
        await service.confirmAndExecute()
        self.check(TerminalService.executed.count == 2 && service.pendingCommand == nil, "Later typed confirmation lost its normal behavior")
    }

    static func voiceConfirmationCancelledAtCallerContinuation() async {
        for cancel in [true, false] {
            let service = self.fixture()
            SettingsStore.shared.commandModeConfirmBeforeExecute = true
            LLMClient.shared.delay = false
            LLMClient.shared.responses = [self.destructiveResponse]
            let owner = VoiceCommandOwner(service)
            if cancel {
                owner.commandModeService.afterRequest = { owner.cancelledOutputLifecycleID = 7 }
            }
            await owner.processCommandWithVoice("voice awaiting approval", lifecycleID: 7)
            self.check(TerminalService.executed.isEmpty, "Voice continuation dispatched without approval")
            if cancel {
                self.check(service.pendingCommand == nil && service.conversationHistory.isEmpty, "Escape at caller continuation left hidden confirmation or intent")
                self.check(owner.pendingVoiceCommandLifecycleID == nil && owner.menuBarManager.updates == [true], "Canceled continuation published pending owner or late UI")
                await service.processUserCommand("next typed request")
                self.check(service.conversationHistory.last?.content == "Done", "Race cleanup left future commands blocked")
            } else {
                self.check(service.pendingCommand != nil && owner.pendingVoiceCommandLifecycleID == 7, "Valid voice confirmation lost ownership")
                self.check(owner.menuBarManager.updates == [true, false], "Valid continuation failed to finish processing UI")
            }
        }
    }

    static func notchInputClearsOnlyAcceptedText() async {
        for accepted in [true, false] {
            for editsDraft in [true, false] {
                let owner = NotchInputOwner()
                owner.inputText = "follow-up"
                var resume: CheckedContinuation<Bool, Never>?
                var returned = false
                owner.onSubmit = { text in
                    self.check(text == "follow-up", "Notch submitted the wrong draft")
                    let result = await withCheckedContinuation { resume = $0 }
                    returned = true
                    return result
                }
                owner.submitFollowUp()
                await self.waitFor { resume != nil }
                self.check(owner.inputText == "follow-up", "Notch erased text before acceptance")
                if editsDraft { owner.inputText = "new draft" }
                resume?.resume(returning: accepted)
                await self.waitFor { returned }
                for _ in 0..<10 {
                    await Task.yield()
                }
                let expected = editsDraft ? "new draft" : (accepted ? "" : "follow-up")
                self.check(owner.inputText == expected, "Notch lost rejected or newly edited text")
            }
        }
    }

    static func invalidRequestDoesNothing() async {
        let service = self.fixture()
        let messages = service.conversationHistory
        let writes = UserDefaults.standard.writes
        await service.processUserCommand("already canceled", isOutputValid: { false })
        self.check(service.conversationHistory == messages && UserDefaults.standard.writes == writes, "Already canceled request wrote chat")
        self.check(LLMClient.shared.configs.isEmpty && TerminalService.executed.isEmpty && !service.isProcessing, "Already canceled request started work")
    }
}
