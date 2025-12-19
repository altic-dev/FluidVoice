import Foundation

/// Extends OpenAI-compatible API to support function calling with MCP tools
final class FunctionCallingProvider {
    struct FunctionCall: Codable {
        let name: String
        let arguments: String // JSON string
    }

    struct ToolCall: Codable {
        let id: String
        let type: String
        let function: FunctionCall
    }

    struct ChatMessage: Codable {
        let role: String
        let content: String?
        let tool_calls: [ToolCall]
        let tool_call_id: String?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case role, content, tool_calls, tool_call_id, name
        }

        init(role: String, content: String?, tool_calls: [ToolCall] = [], tool_call_id: String? = nil, name: String? = nil) {
            self.role = role
            self.content = content
            self.tool_calls = tool_calls
            self.tool_call_id = tool_call_id
            self.name = name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.role = try container.decode(String.self, forKey: .role)
            self.content = try container.decodeIfPresent(String.self, forKey: .content)
            self.tool_calls = try container.decodeIfPresent([ToolCall].self, forKey: .tool_calls) ?? []
            self.tool_call_id = try container.decodeIfPresent(String.self, forKey: .tool_call_id)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.role, forKey: .role)
            try container.encodeIfPresent(self.content, forKey: .content)
            if self.tool_calls.isEmpty == false {
                try container.encode(self.tool_calls, forKey: .tool_calls)
            }
            try container.encodeIfPresent(self.tool_call_id, forKey: .tool_call_id)
            try container.encodeIfPresent(self.name, forKey: .name)
        }
    }

    struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let tools: [[String: Any]]
        let tool_choice: String?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, tools, tool_choice
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.model, forKey: .model)
            try container.encode(self.messages, forKey: .messages)
            try container.encodeIfPresent(self.temperature, forKey: .temperature)
            try container.encodeIfPresent(self.tool_choice, forKey: .tool_choice)

            if self.tools.isEmpty == false {
                let toolsData = try JSONSerialization.data(withJSONObject: self.tools)
                let toolsArray = try JSONDecoder().decode([AnyCodable].self, from: toolsData)
                try container.encode(toolsArray, forKey: .tools)
            }
        }
    }

    struct ChatChoice: Codable {
        let index: Int?
        let message: ChatMessage
        let finish_reason: String?
    }

    struct ChatResponse: Codable {
        let choices: [ChatChoice]
    }

    // Helper for encoding/decoding Any
    struct AnyCodable: Codable {
        let value: Any

        init(_ value: Any) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let dict = try? container.decode([String: AnyCodable].self) {
                self.value = dict.mapValues { $0.value }
            } else if let array = try? container.decode([AnyCodable].self) {
                self.value = array.map { $0.value }
            } else if let string = try? container.decode(String.self) {
                self.value = string
            } else if let int = try? container.decode(Int.self) {
                self.value = int
            } else if let double = try? container.decode(Double.self) {
                self.value = double
            } else if let bool = try? container.decode(Bool.self) {
                self.value = bool
            } else {
                self.value = NSNull()
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let dict = value as? [String: Any] {
                try container.encode(dict.mapValues { AnyCodable($0) })
            } else if let array = value as? [Any] {
                try container.encode(array.map { AnyCodable($0) })
            } else if let string = value as? String {
                try container.encode(string)
            } else if let int = value as? Int {
                try container.encode(int)
            } else if let double = value as? Double {
                try container.encode(double)
            } else if let bool = value as? Bool {
                try container.encode(bool)
            } else {
                try container.encodeNil()
            }
        }
    }

    /// Result of LLM processing - either a text response or tool calls
    enum LLMResult {
        case textResponse(String)
        case toolCalls([(name: String, arguments: [String: Any], callId: String)])
        case error(String)
    }

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
        if hostLower.hasPrefix("127.") || hostLower.hasPrefix("10.") ||
            hostLower.hasPrefix("192.168.")
        {
            return true
        }

        // 172.16.x.x - 172.31.x.x
        if hostLower.hasPrefix("172.") {
            let components = hostLower.split(separator: ".")
            if components.count >= 2,
               let secondOctet = Int(components[1]),
               secondOctet >= 16 && secondOctet <= 31
            {
                return true
            }
        }

        return false
    }

    /// Process user input with LLM and MCP tools
    func processWithTools(
        userText: String,
        conversationHistory: [ChatMessage],
        tools: [[String: Any]],
        model: String,
        apiKey: String,
        baseURL: String
    ) async -> LLMResult {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
            "https://api.openai.com/v1" : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build the full URL
        let fullEndpoint: String
        if endpoint.contains("/chat/completions") ||
            endpoint.contains("/api/chat") ||
            endpoint.contains("/api/generate")
        {
            fullEndpoint = endpoint
        } else {
            fullEndpoint = endpoint + "/chat/completions"
        }

        guard let url = URL(string: fullEndpoint) else {
            return .error("Invalid Base URL")
        }

        let isLocal = self.isLocalEndpoint(endpoint)

        // Build messages array
        var messages = conversationHistory
        messages.append(ChatMessage(role: "user", content: userText))

        // Check if this is a reasoning model that doesn't support temperature parameter
        let modelLower = model.lowercased()
        let isReasoningModel = modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") || modelLower.hasPrefix("gpt-5")

        let body = ChatRequest(
            model: model,
            messages: messages,
            temperature: isReasoningModel ? nil : 0.2,
            tools: tools,
            tool_choice: tools.isEmpty ? nil : "auto"
        )

        DebugLogger.shared.info("📤 Sending to LLM: \(tools.count) tools, model: \(model)", source: "FunctionCallingProvider")
        if !tools.isEmpty {
            DebugLogger.shared
                .info(
                    "Tools in request: \(tools.map { ($0["function"] as? [String: Any])?["name"] as? String ?? "?" }.joined(separator: ", "))",
                    source: "FunctionCallingProvider"
                )
        }

        guard let jsonData = try? JSONEncoder().encode(body) else {
            DebugLogger.shared.error("Failed to encode request", source: "FunctionCallingProvider")
            return .error("Failed to encode request")
        }

        // Debug: Log request payload
        if let requestString = String(data: jsonData, encoding: .utf8) {
            DebugLogger.shared.debug("Request JSON: \(requestString)", source: "FunctionCallingProvider")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Only add Authorization header for non-local endpoints
        if !isLocal {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            // Log response
            if let responseString = String(data: data, encoding: .utf8) {
                DebugLogger.shared.debug("📥 LLM Response: \(responseString)", source: "FunctionCallingProvider")
            }

            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let errText = String(data: data, encoding: .utf8) ?? "Unknown error"
                DebugLogger.shared.error("HTTP \(http.statusCode): \(errText)", source: "FunctionCallingProvider")
                return .error("HTTP \(http.statusCode): \(errText)")
            }

            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let choice = decoded.choices.first else {
                DebugLogger.shared.error("No choices in LLM response", source: "FunctionCallingProvider")
                return .error("No response from LLM")
            }

            let message = choice.message

            // Check if LLM wants to call tools
            let toolCalls = message.tool_calls
            if toolCalls.isEmpty == false {
                DebugLogger.shared.info(
                    "🎯 LLM decided to call \(toolCalls.count) tools",
                    source: "FunctionCallingProvider"
                )
                var parsedCalls: [(name: String, arguments: [String: Any], callId: String)] = []

                for toolCall in toolCalls {
                    DebugLogger.shared.info(
                        "  → \(toolCall.function.name)(\(toolCall.function.arguments))",
                        source: "FunctionCallingProvider"
                    )
                    // Parse arguments JSON string
                    if let argsData = toolCall.function.arguments.data(using: .utf8),
                       let argsDict = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                    {
                        parsedCalls.append((
                            name: toolCall.function.name,
                            arguments: argsDict,
                            callId: toolCall.id
                        ))
                    }
                }

                return .toolCalls(parsedCalls)
            }

            // Otherwise, return text response
            DebugLogger.shared.info(
                "💭 LLM responded with text only (finish_reason: \(choice.finish_reason ?? "none"))",
                source: "FunctionCallingProvider"
            )
            return .textResponse(message.content ?? "<no content>")

        } catch {
            DebugLogger.shared.error(
                "❌ Function calling failed: \(error.localizedDescription)",
                source: "FunctionCallingProvider"
            )
            return .error(error.localizedDescription)
        }
    }

    /// Continue conversation after tool execution
    func continueWithToolResults(
        conversationHistory: [ChatMessage],
        toolResults: [(callId: String, toolName: String, result: String)],
        model: String,
        apiKey: String,
        baseURL: String
    ) async -> LLMResult {
        let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?
            "https://api.openai.com/v1" : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        let fullEndpoint: String
        if endpoint.contains("/chat/completions") ||
            endpoint.contains("/api/chat") ||
            endpoint.contains("/api/generate")
        {
            fullEndpoint = endpoint
        } else {
            fullEndpoint = endpoint + "/chat/completions"
        }

        guard let url = URL(string: fullEndpoint) else {
            return .error("Invalid Base URL")
        }

        let isLocal = self.isLocalEndpoint(endpoint)

        // Use conversation history as-is (tool messages should already be added by caller)
        let messages = conversationHistory

        // Check if this is a reasoning model that doesn't support temperature parameter
        let modelLower = model.lowercased()
        let isReasoningModel = modelLower.hasPrefix("o1") || modelLower.hasPrefix("o3") || modelLower.hasPrefix("gpt-5")

        // Don't pass tools or tool_choice in the final response request
        // Some providers (like OpenAI) reject tool_choice when tools is nil
        let body = ChatRequest(
            model: model,
            messages: messages,
            temperature: isReasoningModel ? nil : 0.2,
            tools: [],
            tool_choice: nil
        )

        guard let jsonData = try? JSONEncoder().encode(body) else {
            return .error("Failed to encode request")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        if !isLocal {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                let errText = String(data: data, encoding: .utf8) ?? "Unknown error"
                DebugLogger.shared.error(
                    "HTTP \(http.statusCode) in continueWithToolResults: \(errText)",
                    source: "FunctionCallingProvider"
                )
                return .error("HTTP \(http.statusCode): \(errText)")
            }

            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let choice = decoded.choices.first else {
                return .error("No response from LLM")
            }

            // If the model tries to call tools again despite tool_choice being "none",
            // just extract the text content or return a generic message
            let toolCalls = choice.message.tool_calls
            if !toolCalls.isEmpty {
                DebugLogger.shared
                    .warning(
                        "Model tried to call tools in final response (tool_choice was 'none'). Ignoring tool calls.",
                        source: "FunctionCallingProvider"
                    )
                // Try to extract any text content if available
                if let content = choice.message.content, !content.isEmpty {
                    return .textResponse(content)
                }
                // Otherwise, return a generic success message
                return .textResponse("Task completed successfully.")
            }

            return .textResponse(choice.message.content ?? "<no content>")

        } catch {
            DebugLogger.shared.error(
                "Error in continueWithToolResults: \(error.localizedDescription)",
                source: "FunctionCallingProvider"
            )
            return .error(error.localizedDescription)
        }
    }
}
