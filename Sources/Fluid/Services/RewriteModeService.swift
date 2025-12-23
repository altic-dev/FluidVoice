import AppKit
import Combine
import Foundation

@MainActor
final class RewriteModeService: ObservableObject {
    @Published var originalText: String = ""
    @Published var rewrittenText: String = ""
    @Published var streamingThinkingText: String = "" // Real-time thinking tokens for UI
    @Published var isProcessing = false
    @Published var conversationHistory: [Message] = []
    @Published var isWriteMode: Bool = false // true = no text selected (write/improve), false = text selected (rewrite)

    private let textSelectionService = TextSelectionService.shared
    private let typingService = TypingService()
    private var thinkingBuffer: [String] = [] // Buffer thinking tokens

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let content: String

        enum Role: Equatable {
            case user
            case assistant
        }
    }

    func captureSelectedText() -> Bool {
        if let text = textSelectionService.getSelectedText(), !text.isEmpty {
            self.originalText = text
            self.rewrittenText = ""
            self.conversationHistory = []
            self.isWriteMode = false
            return true
        }
        return false
    }

    /// Start rewrite mode without selected text - user will provide text via voice
    func startWithoutSelection() {
        self.originalText = ""
        self.rewrittenText = ""
        self.conversationHistory = []
        self.isWriteMode = true
    }

    /// Set the original text directly (from voice input when no text was selected)
    func setOriginalText(_ text: String) {
        self.originalText = text
        self.rewrittenText = ""
        self.conversationHistory = []
    }

    func processRewriteRequest(_ prompt: String) async {
        let startTime = Date()
        // If no original text, we're in "Write Mode" - generate content based on user's request
        if self.originalText.isEmpty {
            self.originalText = prompt
            self.isWriteMode = true

            // Write Mode: User is asking AI to write/generate something
            self.conversationHistory.append(Message(role: .user, content: prompt))
        } else {
            // Rewrite Mode: User has selected text and is giving instructions
            self.isWriteMode = false

            if self.conversationHistory.isEmpty {
                let rewritePrompt = """
                Here is the text to rewrite:

                "\(originalText)"

                User's instruction: \(prompt)

                Rewrite the text according to the instruction. Output ONLY the rewritten text, nothing else.
                """
                self.conversationHistory.append(Message(role: .user, content: rewritePrompt))
            } else {
                // Follow-up request
                self.conversationHistory.append(Message(role: .user, content: "Follow-up instruction: \(prompt)\n\nApply this to the previous result. Output ONLY the updated text."))
            }
        }

        guard !self.conversationHistory.isEmpty else { return }

        self.isProcessing = true

        do {
            let response = try await callLLM(messages: conversationHistory, isWriteMode: isWriteMode)
            self.conversationHistory.append(Message(role: .assistant, content: response))
            self.rewrittenText = response
            self.isProcessing = false

            AnalyticsService.shared.capture(
                .rewriteRunCompleted,
                properties: [
                    "write_mode": self.isWriteMode,
                    "success": true,
                    "latency_bucket": AnalyticsBuckets.bucketSeconds(Date().timeIntervalSince(startTime)),
                ]
            )
        } catch {
            self.conversationHistory.append(Message(role: .assistant, content: "Error: \(error.localizedDescription)"))
            self.isProcessing = false

            AnalyticsService.shared.capture(
                .rewriteRunCompleted,
                properties: [
                    "write_mode": self.isWriteMode,
                    "success": false,
                    "latency_bucket": AnalyticsBuckets.bucketSeconds(Date().timeIntervalSince(startTime)),
                ]
            )
        }
    }

    func acceptRewrite() {
        guard !self.rewrittenText.isEmpty else { return }
        NSApp.hide(nil) // Restore focus to the previous app
        self.typingService.typeTextInstantly(self.rewrittenText)

        AnalyticsService.shared.capture(
            .outputDelivered,
            properties: [
                "mode": AnalyticsMode.rewrite.rawValue,
                "method": AnalyticsOutputMethod.typed.rawValue,
            ]
        )
    }

    func clearState() {
        self.originalText = ""
        self.rewrittenText = ""
        self.streamingThinkingText = ""
        self.conversationHistory = []
        self.isWriteMode = false
        self.thinkingBuffer = []
    }

    // MARK: - LLM Integration

    private func callLLM(messages: [Message], isWriteMode: Bool) async throws -> String {
        let settings = SettingsStore.shared
        // Use Write Mode's independent provider/model settings
        let providerID = settings.rewriteModeSelectedProviderID

        // Route to Apple Intelligence if selected
        if providerID == "apple-intelligence" {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let provider = AppleIntelligenceProvider()
                let messageTuples = messages
                    .map { (role: $0.role == .user ? "user" : "assistant", content: $0.content) }
                DebugLogger.shared.debug("Using Apple Intelligence for rewrite mode", source: "RewriteModeService")
                return try await provider.processRewrite(messages: messageTuples, isWriteMode: isWriteMode)
            }
            #endif
            throw NSError(
                domain: "RewriteMode",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not available"]
            )
        }

        let model = settings.rewriteModeSelectedModel ?? "gpt-4o"
        let apiKey = settings.getAPIKey(for: providerID) ?? ""

        let baseURL: String
        if let provider = settings.savedProviders.first(where: { $0.id == providerID }) {
            baseURL = provider.baseURL
        } else if providerID == "groq" {
            baseURL = "https://api.groq.com/openai/v1"
        } else {
            baseURL = "https://api.openai.com/v1"
        }

        // Different system prompts for each mode
        let systemPrompt: String
        if isWriteMode {
            // Write Mode: Generate content based on user's request
            systemPrompt = """
            You are a helpful writing assistant. The user will ask you to write or generate text for them.

            Examples of requests:
            - "Write an email to my boss asking for time off"
            - "Draft a reply saying I'll be there at 5"
            - "Write a professional summary for LinkedIn"
            - "Answer this: what is the capital of France"

            Respond directly with the requested content. Be concise and helpful.
            Output ONLY what they asked for - no explanations or preamble.
            """
        } else {
            // Rewrite Mode: Transform selected text based on instructions
            systemPrompt = """
            You are a writing assistant that rewrites text according to user instructions. The user has selected existing text and wants you to transform it.

            Your job:
            - Follow the user's specific instructions for how to rewrite
            - Maintain the core meaning unless asked to change it
            - Apply the requested style, tone, or format changes

            Output ONLY the rewritten text. No explanations, no quotes around the text, no preamble.
            """
        }

        // Build messages array for LLMClient
        var apiMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]

        for msg in messages {
            apiMessages.append(["role": msg.role == .user ? "user" : "assistant", "content": msg.content])
        }

        // Check streaming setting
        let enableStreaming = settings.enableAIStreaming

        // Reasoning models (o1, o3, gpt-5) don't support temperature parameter at all
        let isReasoningModel = settings.isReasoningModel(model)

        // Get reasoning config for this model (e.g., reasoning_effort, enable_thinking)
        let reasoningConfig = settings.getReasoningConfig(forModel: model, provider: providerID)
        var extraParams: [String: Any] = [:]
        if let rConfig = reasoningConfig, rConfig.isEnabled {
            if rConfig.parameterName == "enable_thinking" {
                extraParams = [rConfig.parameterName: rConfig.parameterValue == "true"]
            } else {
                extraParams = [rConfig.parameterName: rConfig.parameterValue]
            }
            DebugLogger.shared.debug("Added reasoning param: \(rConfig.parameterName)=\(rConfig.parameterValue)", source: "RewriteModeService")
        }

        // Build LLMClient configuration
        var config = LLMClient.Config(
            messages: apiMessages,
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            streaming: enableStreaming,
            tools: [],
            temperature: isReasoningModel ? nil : 0.7,
            maxTokens: isReasoningModel ? 32_000 : nil, // Reasoning models like o1 need a large budget for extended thought chains
            extraParameters: extraParams
        )

        // Add real-time streaming callbacks for UI updates
        if enableStreaming {
            // Thinking tokens callback
            config.onThinkingChunk = { [weak self] chunk in
                Task { @MainActor in
                    self?.thinkingBuffer.append(chunk)
                    self?.streamingThinkingText = self?.thinkingBuffer.joined() ?? ""
                }
            }

            // Content callback
            config.onContentChunk = { [weak self] chunk in
                Task { @MainActor in
                    self?.rewrittenText += chunk
                }
            }
        }

        DebugLogger.shared.info("Using LLMClient for Write/Rewrite (streaming=\(enableStreaming))", source: "RewriteModeService")

        // Clear streaming buffers before starting
        if enableStreaming {
            self.rewrittenText = ""
            self.streamingThinkingText = ""
            self.thinkingBuffer = []
        }

        let response = try await LLMClient.shared.call(config)

        // Clear thinking display after response complete
        self.streamingThinkingText = ""
        self.thinkingBuffer = []

        // Log thinking if present (for debugging)
        if let thinking = response.thinking {
            DebugLogger.shared.debug("LLM thinking tokens extracted (\(thinking.count) chars)", source: "RewriteModeService")
        }

        DebugLogger.shared.debug("Response complete. Content length: \(response.content.count)", source: "RewriteModeService")

        // For non-streaming, we return the content directly
        // For streaming, rewrittenText is already updated via callback,
        // but we return the final content for consistency
        return response.content
    }
}
