import AppKit
import Combine
import Foundation

// MARK: - Context Types (Scalable for future image/file support)

/// Represents context that can be passed to Ask Mode
/// Designed to be extensible for images, files, URLs, etc.
enum AskModeContextItem: Equatable, Sendable {
    case text(String)
    // Future: case image(Data, mimeType: String)
    // Future: case file(URL)
    // Future: case url(URL)

    var description: String {
        switch self {
        case .text(let content):
            let preview = content.prefix(100)
            return content.count > 100 ? "\(preview)..." : String(content)
        }
    }

    var isEmpty: Bool {
        switch self {
        case .text(let content):
            return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Container for all context items in a question
struct AskModeContext: Equatable, Sendable {
    var items: [AskModeContextItem]

    var isEmpty: Bool {
        items.isEmpty || items.allSatisfy { $0.isEmpty }
    }

    var textContent: String? {
        items.compactMap {
            if case .text(let content) = $0 { return content }
            return nil
        }.joined(separator: "\n\n")
    }

    static let empty = AskModeContext(items: [])
}

// MARK: - Output Handler Protocol (Decoupled UI)

/// Protocol for handling Ask Mode output - allows different UI renderers
@MainActor
protocol AskModeOutputHandler: AnyObject {
    /// Called when a question is submitted
    func onQuestionSubmitted(_ question: String, context: AskModeContext)

    /// Called when processing starts
    func onProcessingStarted()

    /// Called with streaming content chunks
    func onContentChunk(_ chunk: String)

    /// Called with streaming thinking chunks (if model supports)
    func onThinkingChunk(_ chunk: String)

    /// Called when processing completes with full response
    func onProcessingCompleted(answer: String, thinking: String?)

    /// Called when an error occurs
    func onError(_ error: Error)

    /// Called to clear/reset the output
    func onClear()
}

// MARK: - Ask Mode Service

@MainActor
final class AskModeService: ObservableObject {
    // MARK: - Published State

    @Published var question: String = ""
    @Published var answer: String = ""
    @Published var streamingThinkingText: String = ""
    @Published var isProcessing = false
    @Published var context: AskModeContext = .empty
    @Published var conversationHistory: [Message] = []

    // MARK: - Dependencies

    private let textSelectionService = TextSelectionService.shared
    private var thinkingBuffer: [String] = []

    // MARK: - Output Handler (Decoupled UI)

    private weak var outputHandler: AskModeOutputHandler?

    func setOutputHandler(_ handler: AskModeOutputHandler) {
        self.outputHandler = handler
    }

    // MARK: - Message Model

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let content: String
        let timestamp: Date = .init()

        enum Role: Equatable {
            case user
            case assistant
        }
    }

    // MARK: - Context Capture

    /// Capture selected text as context
    /// Returns true if text was captured
    func captureSelectedText() -> Bool {
        if let text = textSelectionService.getSelectedText(), !text.isEmpty {
            self.context = AskModeContext(items: [.text(text)])
            return true
        }
        return false
    }

    /// Add context item manually
    func addContext(_ item: AskModeContextItem) {
        var items = self.context.items
        items.append(item)
        self.context = AskModeContext(items: items)
    }

    /// Clear all context
    func clearContext() {
        self.context = .empty
    }

    // MARK: - Question Processing

    /// Process a question with current context
    func processQuestion(_ questionText: String) async {
        guard !questionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        self.question = questionText
        self.answer = ""
        self.streamingThinkingText = ""
        self.thinkingBuffer = []
        self.isProcessing = true

        // Notify output handler
        outputHandler?.onQuestionSubmitted(questionText, context: context)
        outputHandler?.onProcessingStarted()

        // Build the prompt with context
        let prompt = buildPrompt(question: questionText, context: context)

        // Add to conversation history
        self.conversationHistory.append(Message(role: .user, content: prompt))

        do {
            let response = try await callLLM(prompt: prompt)
            self.conversationHistory.append(Message(role: .assistant, content: response))
            self.answer = response
            self.isProcessing = false

            outputHandler?.onProcessingCompleted(answer: response, thinking: streamingThinkingText.isEmpty ? nil : streamingThinkingText)
        } catch {
            let errorMessage = "Error: \(error.localizedDescription)"
            self.conversationHistory.append(Message(role: .assistant, content: errorMessage))
            self.answer = errorMessage
            self.isProcessing = false

            outputHandler?.onError(error)
        }
    }

    /// Process a follow-up question (maintains context and history)
    func processFollowUp(_ followUpText: String) async {
        guard !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        self.question = followUpText
        self.answer = ""
        self.streamingThinkingText = ""
        self.thinkingBuffer = []
        self.isProcessing = true

        outputHandler?.onQuestionSubmitted(followUpText, context: .empty)
        outputHandler?.onProcessingStarted()

        // Add follow-up to history
        self.conversationHistory.append(Message(role: .user, content: followUpText))

        do {
            let response = try await callLLMWithHistory()
            self.conversationHistory.append(Message(role: .assistant, content: response))
            self.answer = response
            self.isProcessing = false

            outputHandler?.onProcessingCompleted(answer: response, thinking: streamingThinkingText.isEmpty ? nil : streamingThinkingText)
        } catch {
            let errorMessage = "Error: \(error.localizedDescription)"
            self.conversationHistory.append(Message(role: .assistant, content: errorMessage))
            self.answer = errorMessage
            self.isProcessing = false

            outputHandler?.onError(error)
        }
    }

    /// Clear all state
    func clearState() {
        self.question = ""
        self.answer = ""
        self.streamingThinkingText = ""
        self.context = .empty
        self.conversationHistory = []
        self.isProcessing = false
        self.thinkingBuffer = []

        outputHandler?.onClear()
    }

    // MARK: - Private Helpers

    private func buildPrompt(question: String, context: AskModeContext) -> String {
        if context.isEmpty {
            return question
        }

        // Build prompt with context
        var parts: [String] = []

        if let textContent = context.textContent, !textContent.isEmpty {
            parts.append("Context:\n\"\"\"\n\(textContent)\n\"\"\"")
        }

        parts.append("Question: \(question)")

        return parts.joined(separator: "\n\n")
    }

    // MARK: - LLM Integration

    private func callLLM(prompt: String) async throws -> String {
        let settings = SettingsStore.shared
        let providerID = settings.askModeSelectedProviderID

        // Route to Apple Intelligence if selected
        if providerID == "apple-intelligence" {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let provider = AppleIntelligenceProvider()
                DebugLogger.shared.debug("Using Apple Intelligence for ask mode", source: "AskModeService")
                let systemPrompt = """
                You are a helpful assistant that answers questions clearly and concisely.
                When context is provided, use it to inform your answer.
                Be direct and informative. If you don't know something, say so.
                """
                let result = await provider.process(systemPrompt: systemPrompt, userText: prompt)
                // Check for error responses
                if result.hasPrefix("Error:") {
                    throw NSError(
                        domain: "AskMode",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: result]
                    )
                }
                return result
            }
            #endif
            throw NSError(
                domain: "AskMode",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not available"]
            )
        }

        let model = settings.askModeSelectedModel ?? "gpt-4o"
        let apiKey = settings.getAPIKey(for: providerID) ?? ""

        let baseURL: String
        if let provider = settings.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = provider.baseURL
        } else if providerID == "groq" {
            baseURL = "https://api.groq.com/openai/v1"
        } else {
            baseURL = "https://api.openai.com/v1"
        }

        let systemPrompt = """
        You are a helpful assistant that answers questions clearly and concisely.
        When context is provided, use it to inform your answer.
        Be direct and informative. If you don't know something, say so.
        Format your response for easy reading - use bullet points or numbered lists when appropriate.
        """

        var apiMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": prompt],
        ]

        return try await executeLLMCall(
            messages: apiMessages,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            providerID: providerID
        )
    }

    private func callLLMWithHistory() async throws -> String {
        let settings = SettingsStore.shared
        let providerID = settings.askModeSelectedProviderID
        let model = settings.askModeSelectedModel ?? "gpt-4o"
        let apiKey = settings.getAPIKey(for: providerID) ?? ""

        let baseURL: String
        if let provider = settings.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = provider.baseURL
        } else if providerID == "groq" {
            baseURL = "https://api.groq.com/openai/v1"
        } else {
            baseURL = "https://api.openai.com/v1"
        }

        let systemPrompt = """
        You are a helpful assistant that answers questions clearly and concisely.
        When context is provided, use it to inform your answer.
        Be direct and informative. If you don't know something, say so.
        Format your response for easy reading - use bullet points or numbered lists when appropriate.
        """

        var apiMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]

        for msg in conversationHistory {
            apiMessages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.content,
            ])
        }

        return try await executeLLMCall(
            messages: apiMessages,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            providerID: providerID
        )
    }

    private func executeLLMCall(
        messages: [[String: Any]],
        model: String,
        baseURL: String,
        apiKey: String,
        providerID: String
    ) async throws -> String {
        let settings = SettingsStore.shared
        let enableStreaming = settings.enableAIStreaming

        // Reasoning models don't support temperature
        let isReasoningModel = settings.isReasoningModel(model)

        // Get reasoning config for this model
        let reasoningConfig = settings.getReasoningConfig(forModel: model, provider: providerID)
        var extraParams: [String: Any] = [:]
        if let rConfig = reasoningConfig, rConfig.isEnabled {
            if rConfig.parameterName == "enable_thinking" {
                extraParams = [rConfig.parameterName: rConfig.parameterValue == "true"]
            } else {
                extraParams = [rConfig.parameterName: rConfig.parameterValue]
            }
            DebugLogger.shared.debug("Added reasoning param: \(rConfig.parameterName)=\(rConfig.parameterValue)", source: "AskModeService")
        }

        var config = LLMClient.Config(
            messages: messages,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            streaming: enableStreaming,
            tools: [],
            temperature: isReasoningModel ? nil : 0.7,
            maxTokens: isReasoningModel ? 32_000 : nil,
            extraParameters: extraParams
        )

        // Add streaming callbacks
        if enableStreaming {
            config.onThinkingChunk = { [weak self] chunk in
                Task { @MainActor in
                    self?.thinkingBuffer.append(chunk)
                    self?.streamingThinkingText = self?.thinkingBuffer.joined() ?? ""
                    self?.outputHandler?.onThinkingChunk(chunk)
                }
            }

            config.onContentChunk = { [weak self] chunk in
                Task { @MainActor in
                    self?.answer += chunk
                    self?.outputHandler?.onContentChunk(chunk)
                }
            }
        }

        DebugLogger.shared.info("Using LLMClient for Ask Mode (streaming=\(enableStreaming))", source: "AskModeService")

        // Clear streaming buffers before starting
        if enableStreaming {
            self.answer = ""
            self.streamingThinkingText = ""
            self.thinkingBuffer = []
        }

        let response = try await LLMClient.shared.call(config)

        // Clear thinking display after response complete
        self.streamingThinkingText = ""
        self.thinkingBuffer = []

        if let thinking = response.thinking {
            DebugLogger.shared.debug("LLM thinking tokens extracted (\(thinking.count) chars)", source: "AskModeService")
        }

        return response.content
    }
}
