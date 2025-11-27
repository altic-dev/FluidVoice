import Foundation

protocol AIProvider
{
    func process(systemPrompt: String, userText: String, model: String, apiKey: String, baseURL: String, stream: Bool) async -> String
}

final class OpenAICompatibleProvider: AIProvider
{
    struct ChatMessage: Codable { let role: String; let content: String }
    struct ChatRequest: Codable { 
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let reasoning_effort: String?
        let stream: Bool?
        
        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, reasoning_effort, stream
        }
    }
    struct ChatChoiceMessage: Codable { let role: String; let content: String }
    struct ChatChoice: Codable { let index: Int?; let message: ChatChoiceMessage }
    struct ChatResponse: Codable { let choices: [ChatChoice] }
    
    // Helper function to detect if the endpoint is local
    private func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host else { return false }
        
        let hostLower = host.lowercased()
        
        // Check for localhost variations
        if hostLower == "localhost" || hostLower == "127.0.0.1" {
            return true
        }
        
        // Check for private IP ranges
        // 127.x.x.x
        if hostLower.hasPrefix("127.") {
            return true
        }
        // 10.x.x.x
        if hostLower.hasPrefix("10.") {
            return true
        }
        // 192.168.x.x
        if hostLower.hasPrefix("192.168.") {
            return true
        }
        // 172.16.x.x - 172.31.x.x
        if hostLower.hasPrefix("172.") {
            let components = hostLower.split(separator: ".")
            if components.count >= 2,
               let secondOctet = Int(components[1]),
               secondOctet >= 16 && secondOctet <= 31 {
                return true
            }
        }
        
        return false
    }
    
    // Helper function to detect if model is a gpt-oss model (Groq reasoning models)
    private func isGptOssModel(_ modelName: String) -> Bool {
        let modelLower = modelName.lowercased()
        // Check for gpt-oss pattern or openai/ prefix (Groq's naming convention)
        return modelLower.contains("gpt-oss") || modelLower.hasPrefix("openai/")
    }

    func process(systemPrompt: String, userText: String, model: String, apiKey: String, baseURL: String, stream: Bool = false) async -> String
    {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "https://api.openai.com/v1" : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Build the full URL - only append /chat/completions if not already present
        let fullEndpoint: String
        if endpoint.contains("/chat/completions") || 
           endpoint.contains("/api/chat") || 
           endpoint.contains("/api/generate") {
            // URL already has a complete path, use as-is
            fullEndpoint = endpoint
        } else {
            // Append /chat/completions for OpenAI-compatible endpoints
            fullEndpoint = endpoint + "/chat/completions"
        }
        
        guard let url = URL(string: fullEndpoint) else { return "Error: Invalid Base URL" }
        
        let isLocal = isLocalEndpoint(endpoint)
        
        // Check if model is gpt-oss and add reasoning_effort parameter
        let shouldAddReasoningEffort = isGptOssModel(model)

        let body = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userText)
            ],
            temperature: 0.2,
            reasoning_effort: shouldAddReasoningEffort ? "low" : nil,
            stream: stream ? true : nil
        )

        guard let jsonData = try? JSONEncoder().encode(body) else { return "Error: Failed to encode request" }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Only add Authorization header for non-local endpoints
        if !isLocal {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        request.httpBody = jsonData

        do
        {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            #if DEBUG
            DebugLogger.shared.debug("AI Request to: \(request.url?.absoluteString ?? "unknown")", source: "AIProvider")
            if let http = response as? HTTPURLResponse {
                DebugLogger.shared.debug("HTTP Status: \(http.statusCode)", source: "AIProvider")
            }
            #endif
            
            if let http = response as? HTTPURLResponse, http.statusCode >= 400
            {
                let errText = String(data: data, encoding: .utf8) ?? "Unknown error"
                DebugLogger.shared.error("AI API error HTTP \(http.statusCode): \(errText)", source: "AIProvider")
                return "Error: HTTP \(http.statusCode): \(errText)"
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return decoded.choices.first?.message.content ?? "<no content>"
        }
        catch
        {
            DebugLogger.shared.error("AI API request failed: \(error.localizedDescription)", source: "AIProvider")
            #if DEBUG
            if let decodingError = error as? DecodingError {
                DebugLogger.shared.debug("Decoding error details: \(decodingError)", source: "AIProvider")
            }
            #endif
            return "Error: \(error.localizedDescription)"
        }
    }
}

