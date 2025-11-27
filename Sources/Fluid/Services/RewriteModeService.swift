import Foundation
import Combine
import AppKit

@MainActor
final class RewriteModeService: ObservableObject {
    @Published var originalText: String = ""
    @Published var rewrittenText: String = ""
    @Published var isProcessing = false
    @Published var conversationHistory: [Message] = []
    @Published var isWriteMode: Bool = false  // true = no text selected (write/improve), false = text selected (rewrite)
    
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
        if originalText.isEmpty {
            originalText = prompt
            isWriteMode = true
            
            // Write Mode: User is asking AI to write/generate something
            conversationHistory.append(Message(role: .user, content: prompt))
        } else {
            // Rewrite Mode: User has selected text and is giving instructions
            isWriteMode = false
            
            if conversationHistory.isEmpty {
                let rewritePrompt = """
                Here is the text to rewrite:

                "\(originalText)"

                User's instruction: \(prompt)

                Rewrite the text according to the instruction. Output ONLY the rewritten text, nothing else.
                """
                conversationHistory.append(Message(role: .user, content: rewritePrompt))
            } else {
                // Follow-up request
                conversationHistory.append(Message(role: .user, content: "Follow-up instruction: \(prompt)\n\nApply this to the previous result. Output ONLY the updated text."))
            }
        }
        
        guard !conversationHistory.isEmpty else { return }
        
        isProcessing = true
        
        do {
            let response = try await callLLM(messages: conversationHistory, isWriteMode: isWriteMode)
            conversationHistory.append(Message(role: .assistant, content: response))
            rewrittenText = response
            isProcessing = false
        } catch {
            conversationHistory.append(Message(role: .assistant, content: "Error: \(error.localizedDescription)"))
            isProcessing = false
        }
    }
    
    func acceptRewrite() {
        guard !rewrittenText.isEmpty else { return }
        NSApp.hide(nil) // Restore focus to the previous app
        typingService.typeTextInstantly(rewrittenText)
    }
    
    func clearState() {
        originalText = ""
        rewrittenText = ""
        conversationHistory = []
        isWriteMode = false
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
                let messageTuples = messages.map { (role: $0.role == .user ? "user" : "assistant", content: $0.content) }
                DebugLogger.shared.debug("Using Apple Intelligence for rewrite mode", source: "RewriteModeService")
                return try await provider.processRewrite(messages: messageTuples, isWriteMode: isWriteMode)
            }
            #endif
            throw NSError(domain: "RewriteMode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not available"])
        }
        
        let model = settings.rewriteModeSelectedModel ?? "gpt-4o"
        let apiKey = settings.providerAPIKeys[providerID] ?? ""
        
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
            ["role": "system", "content": systemPrompt]
        ]
        
        for msg in messages {
            apiMessages.append(["role": msg.role == .user ? "user" : "assistant", "content": msg.content])
        }
        
        // Check streaming setting
        let enableStreaming = settings.enableAIStreaming
        
        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "temperature": 0.7
        ]
        
        if enableStreaming {
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
            return try await processStreamingResponse(request: request)
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
                  let content = message["content"] as? String else {
                throw NSError(domain: "RewriteMode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
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
        var currentLine = ""
        
        for try await byte in bytes {
            let char = Character(UnicodeScalar(byte))
            
            if char == "\n" {
                let line = currentLine.trimmingCharacters(in: .whitespaces)
                
                if line.hasPrefix("data:") {
                    var jsonString = String(line.dropFirst(5))
                    if jsonString.hasPrefix(" ") {
                        jsonString = String(jsonString.dropFirst(1))
                    }
                    
                    if jsonString.trimmingCharacters(in: .whitespaces) == "[DONE]" {
                        currentLine = ""
                        continue
                    }
                    
                    if let jsonData = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let delta = firstChoice["delta"] as? [String: Any],
                       let content = delta["content"] as? String {
                        fullContent += content
                    }
                }
                currentLine = ""
            } else if char != "\r" {
                currentLine.append(char)
            }
        }
        
        DebugLogger.shared.debug("Streaming complete. Content length: \(fullContent.count)", source: "RewriteModeService")
        return fullContent.isEmpty ? "" : fullContent
    }
}
