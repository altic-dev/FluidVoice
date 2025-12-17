import AppKit
import Combine
import Foundation

@MainActor
final class RewriteModeService: ObservableObject {
    @Published var originalText: String = ""
    @Published var rewrittenText: String = ""
    @Published var isProcessing = false
    @Published var conversationHistory: [Message] = []
    @Published var isWriteMode: Bool = false // true = no text selected (write/improve), false = text selected (rewrite)

    private let textSelectionService = TextSelectionService.shared
    private let typingService = TypingService()

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
                self.conversationHistory.append(Message(
                    role: .user,
                    content: "Follow-up instruction: \(prompt)\n\nApply this to the previous result. Output ONLY the updated text."
                ))
            }
        }

        guard !self.conversationHistory.isEmpty else { return }

        self.isProcessing = true

        do {
            let response = try await callLLM(messages: conversationHistory, isWriteMode: isWriteMode)
            self.conversationHistory.append(Message(role: .assistant, content: response))
            self.rewrittenText = response
            self.isProcessing = false
        } catch {
            self.conversationHistory.append(Message(role: .assistant, content: "Error: \(error.localizedDescription)"))
            self.isProcessing = false
        }
    }

    func acceptRewrite() {
        guard !self.rewrittenText.isEmpty else { return }
        NSApp.hide(nil) // Restore focus to the previous app
        self.typingService.typeTextInstantly(self.rewrittenText)
    }

    func clearState() {
        self.originalText = ""
        self.rewrittenText = ""
        self.conversationHistory = []
        self.isWriteMode = false
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

        var apiMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
        ]

        for msg in messages {
            apiMessages.append(["role": msg.role == .user ? "user" : "assistant", "content": msg.content])
        }

        // Check streaming setting
        let enableStreaming = settings.enableAIStreaming

        // Reasoning models (o1, o3, gpt-5) don't support temperature parameter at all
        let isReasoningModel = model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("gpt-5")

        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
        ]

        // Only add temperature for non-reasoning models
        if !isReasoningModel {
            body["temperature"] = 0.7
        }

        if enableStreaming {
            // TODO: Streamed text is still buffered; add incremental UI updates so write mode visibly streams.
            body["stream"] = true
        }

        let endpoint = baseURL.hasSuffix("/chat/completions") ? baseURL : "\(baseURL)/chat/completions"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "RewriteMode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        if enableStreaming {
            DebugLogger.shared.info("Using STREAMING mode for Write/Rewrite", source: "RewriteModeService")
            return try await self.processStreamingResponse(request: request)
        } else {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let err = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "RewriteMode", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: err])
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let message = choice["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                throw NSError(
                    domain: "RewriteMode",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
                )
            }

            return content
        }
    }

    // MARK: - Streaming Response Handler

    private func processStreamingResponse(request: URLRequest) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let errText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "RewriteMode", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: errText])
        }

        var fullContent = ""

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

            if let jsonData = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let delta = firstChoice["delta"] as? [String: Any],
               let content = delta["content"] as? String
            {
                fullContent += content
                // Update UI in real-time for streaming feedback
                self.rewrittenText = fullContent
            }
        }

        DebugLogger.shared.debug(
            "Streaming complete. Content length: \(fullContent.count)",
            source: "RewriteModeService"
        )
        return fullContent.isEmpty ? "" : fullContent
    }
}
