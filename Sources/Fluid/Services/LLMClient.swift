import Foundation

// MARK: - Error Types

enum LLMError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case networkError(Error)
    case encodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from LLM"
        case let .httpError(code, message):
            return "HTTP \(code): \(message)"
        case let .networkError(error):
            return "Network error: \(error.localizedDescription)"
        case .encodingError:
            return "Failed to encode request"
        }
    }
}

// MARK: - LLMClient

/// Unified LLM communication layer for all modes (Transcription, Command, Rewrite).
/// Handles HTTP requests, SSE streaming, thinking token extraction, and tool call parsing.
@MainActor
final class LLMClient {
    static let shared = LLMClient()

    private init() {}

    // MARK: - Response Types

    struct Response {
        /// Extracted <think>...</think> content (nil if none)
        let thinking: String?
        /// Main response content with thinking tags stripped
        let content: String
        /// Parsed tool calls for agentic modes (nil if none)
        let toolCalls: [ToolCall]
    }

    struct ToolCall {
        let id: String
        let name: String
        let arguments: [String: Any]

        /// Get a string argument by key
        func getString(_ key: String) -> String? {
            return self.arguments[key] as? String
        }

        /// Get an optional string argument, returning nil if empty
        func getOptionalString(_ key: String) -> String? {
            guard let value = arguments[key] as? String, !value.isEmpty else { return nil }
            return value
        }
    }

    // MARK: - Configuration

    struct Config {
        let messages: [[String: Any]]
        let model: String
        let baseURL: String
        let apiKey: String
        let streaming: Bool
        let tools: [[String: Any]]
        let temperature: Double?

        /// Optional token limit (max_tokens or max_completion_tokens depending on model)
        var maxTokens: Int?

        /// Extra parameters to add to the request body (e.g., reasoning_effort, enable_thinking)
        /// These are model-specific and come from user settings
        var extraParameters: [String: Any]

        // Retry configuration
        var maxRetries: Int = 3
        var retryDelayMs: Int = 200

        // Optional real-time callbacks (for streaming UI updates)
        var onThinkingStart: (() -> Void)?
        var onThinkingChunk: ((String) -> Void)?
        var onThinkingEnd: (() -> Void)?
        var onContentChunk: ((String) -> Void)?
        var onToolCallStart: ((String) -> Void)?

        init(
            messages: [[String: Any]],
            model: String,
            baseURL: String,
            apiKey: String,
            streaming: Bool = true,
            tools: [[String: Any]] = [],
            temperature: Double? = nil,
            maxTokens: Int? = nil,
            extraParameters: [String: Any] = [:]
        ) {
            self.messages = messages
            self.model = model
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.streaming = streaming
            self.tools = tools
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.extraParameters = extraParameters
        }
    }

    // MARK: - Main Entry Point

    /// Make an LLM API call with the given configuration.
    /// Supports both streaming and non-streaming modes.
    /// Handles thinking token extraction, tool call parsing, and retries.
    func call(_ config: Config) async throws -> Response {
        let request = try buildRequest(config)

        // Retry logic for transient network errors
        var lastError: Error?
        for attempt in 1...config.maxRetries {
            do {
                if config.streaming {
                    return try await self.processStreaming(request: request, config: config)
                } else {
                    return try await self.processNonStreaming(request: request)
                }
            } catch let error as URLError where self.isRetryableError(error) {
                lastError = error
                if attempt < config.maxRetries {
                    // Exponential backoff
                    let delayNs = UInt64(config.retryDelayMs * 1_000_000 * attempt)
                    try? await Task.sleep(nanoseconds: delayNs)
                    continue
                }
            } catch {
                throw error // Non-retryable error
            }
        }

        throw lastError ?? LLMError.networkError(
            NSError(domain: "LLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Request failed after retries"])
        )
    }

    // MARK: - Request Building

    private func buildRequest(_ config: Config) throws -> URLRequest {
        // Build endpoint URL
        let baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint: String
        if baseURL.contains("/chat/completions") ||
            baseURL.contains("/api/chat") ||
            baseURL.contains("/api/generate")
        {
            endpoint = baseURL
        } else {
            endpoint = baseURL.isEmpty ? "https://api.openai.com/v1/chat/completions" : "\(baseURL)/chat/completions"
        }

        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidURL
        }

        // Detect if this is a local endpoint (skip auth for local)
        let isLocal = self.isLocalEndpoint(baseURL)

        // Build request body
        var body: [String: Any] = [
            "model": config.model,
            "messages": config.messages,
        ]

        // Add temperature if provided (reasoning models like o1/o3/gpt-5 don't support it)
        if let temp = config.temperature {
            body["temperature"] = temp
        }

        // Add tools if provided
        if !config.tools.isEmpty {
            body["tools"] = config.tools
            body["tool_choice"] = "auto"
        }

        // Add streaming flag
        if config.streaming {
            body["stream"] = true
        }

        // Add extra parameters in layers:
        // 1. Model-specific parameters (from ThinkingParserFactory)
        // 2. User-provided parameters (can override model defaults)

        // Layer 1: Model-specific parameters (e.g., enable_thinking for Nemotron)
        let modelExtras = ThinkingParserFactory.getExtraParameters(for: config.model)
        for (key, value) in modelExtras {
            body[key] = value
        }

        // Layer 2: User-provided extra parameters (e.g., reasoning_effort from settings)
        for (key, value) in config.extraParameters {
            body[key] = value
        }

        // Final Layer: Common parameters with model-specific keys
        if let tokens = config.maxTokens {
            if SettingsStore.shared.isReasoningModel(config.model) {
                body["max_completion_tokens"] = tokens
            } else {
                body["max_tokens"] = tokens
            }
        }

        // Serialize to JSON
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            throw LLMError.encodingError
        }

        // Log the request for debugging
        let messageCount = config.messages.count
        if let bodyStr = String(data: jsonData, encoding: .utf8) {
            let truncated = bodyStr.count > 500 ? String(bodyStr.prefix(500)) + "..." : bodyStr
            DebugLogger.shared.debug("LLMClient: Request (\(messageCount) messages, model=\(config.model), streaming=\(config.streaming)): \(truncated)", source: "LLMClient")
        }

        // Build URLRequest
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Only add Authorization header for non-local endpoints
        if !isLocal && !config.apiKey.isEmpty {
            request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = jsonData

        return request
    }

    // MARK: - Non-Streaming Response

    private func processNonStreaming(request: URLRequest) async throws -> Response {
        DebugLogger.shared.debug("LLMClient: Making non-streaming request to \(request.url?.absoluteString ?? "unknown")", source: "LLMClient")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let errText = String(data: data, encoding: .utf8) ?? "Unknown error"
            DebugLogger.shared.error("LLMClient: HTTP error \(http.statusCode): \(errText.prefix(200))", source: "LLMClient")
            throw LLMError.httpError(http.statusCode, errText)
        }

        DebugLogger.shared.debug("LLMClient: Non-streaming response received (\(data.count) bytes)", source: "LLMClient")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any]
        else {
            throw LLMError.invalidResponse
        }

        return self.parseMessageResponse(message)
    }

    private func processStreaming(request: URLRequest, config: Config) async throws -> Response {
        DebugLogger.shared.debug("LLMClient: Starting streaming request to \(request.url?.absoluteString ?? "unknown")", source: "LLMClient")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        // Check for HTTP errors
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let errText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw LLMError.httpError(http.statusCode, errText)
        }

        // Create the appropriate parser for this model
        var parser = ThinkingParserFactory.createParser(for: config.model)

        // Streaming state
        var state = ThinkingParserState.initial
        var thinkingBuffer: [String] = []
        var contentBuffer: [String] = []
        var tagDetectionBuffer = ""

        // Tool call accumulation
        var toolCallId: String?
        var toolCallName: String?
        var toolCallArguments = ""

        // Process SSE lines
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
                  let delta = choices.first?["delta"] as? [String: Any]
            else {
                continue
            }

            // Handle reasoning_content field (DeepSeek style - separate from text content)
            if let reasoning = delta["reasoning_content"] as? String {
                if state == .initial {
                    state = .inThinking
                    config.onThinkingStart?()
                }
                thinkingBuffer.append(reasoning)
                config.onThinkingChunk?(reasoning)
            }

            // Handle content with potential <think> tags
            if let content = delta["content"] as? String {
                // Debug: Log first few chunks and any chunk containing think tags
                let containsThinkTag = content.contains("<think") || content.contains("</think") || content.contains("<thinking") || content.contains("</thinking")
                if thinkingBuffer.count + contentBuffer.count < 8 || containsThinkTag {
                    let escaped = content.replacingOccurrences(of: "\n", with: "\\n")
                    let marker = containsThinkTag ? " [HAS THINK TAG!]" : ""
                    DebugLogger.shared.debug("LLMClient: Chunk '\(escaped)'\(marker)", source: "LLMClient")
                }

                let previousState = state
                let (newState, thinkChunk, contentChunk) = parser.processChunk(
                    content,
                    currentState: state,
                    tagBuffer: &tagDetectionBuffer
                )

                // Handle state transitions for callbacks
                if previousState != .inThinking && newState == .inThinking {
                    DebugLogger.shared.debug("LLMClient: State transition → inThinking", source: "LLMClient")
                    config.onThinkingStart?()
                }
                if previousState == .inThinking && newState == .inContent {
                    DebugLogger.shared.debug("LLMClient: State transition → inContent", source: "LLMClient")
                    config.onThinkingEnd?()
                }
                state = newState

                // Accumulate and callback
                if !thinkChunk.isEmpty {
                    thinkingBuffer.append(thinkChunk)
                    config.onThinkingChunk?(thinkChunk)
                }
                if !contentChunk.isEmpty {
                    contentBuffer.append(contentChunk)
                    config.onContentChunk?(contentChunk)
                }
            }

            // Handle tool calls (streamed in parts)
            if let toolCalls = delta["tool_calls"] as? [[String: Any]],
               let tc = toolCalls.first
            {
                if let id = tc["id"] as? String {
                    toolCallId = id
                }
                if let function = tc["function"] as? [String: Any] {
                    if let name = function["name"] as? String {
                        toolCallName = name
                        config.onToolCallStart?(name)
                    }
                    if let args = function["arguments"] as? String {
                        toolCallArguments += args
                    }
                }
            }
        }

        // Finalize - flush any remaining content in tagDetectionBuffer
        if !tagDetectionBuffer.isEmpty {
            // Anything left in the buffer should go to the appropriate place
            if state == .inThinking {
                thinkingBuffer.append(tagDetectionBuffer)
                config.onThinkingChunk?(tagDetectionBuffer)
                DebugLogger.shared.debug("LLMClient: Flushing remaining tagBuffer to thinking (\(tagDetectionBuffer.count) chars)", source: "LLMClient")
            } else {
                contentBuffer.append(tagDetectionBuffer)
                config.onContentChunk?(tagDetectionBuffer)
                DebugLogger.shared.debug("LLMClient: Flushing remaining tagBuffer to content (\(tagDetectionBuffer.count) chars)", source: "LLMClient")
            }
        }

        // Use parser's finalize to get final clean thinking and content
        let (thinkingText, contentText) = parser.finalize(thinkingBuffer: thinkingBuffer, contentBuffer: contentBuffer, finalState: state)

        DebugLogger.shared.debug("LLMClient: Streaming complete. Thinking: \(thinkingText.count) chars, Content: \(contentText.count) chars", source: "LLMClient")

        // Build tool calls array
        var parsedToolCalls: [ToolCall] = []
        if let name = toolCallName,
           let argsData = toolCallArguments.data(using: .utf8),
           let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        {
            parsedToolCalls = [
                ToolCall(
                    id: toolCallId ?? "call_\(UUID().uuidString.prefix(8))",
                    name: name,
                    arguments: args
                ),
            ]
            DebugLogger.shared.debug("LLMClient: Parsed tool call: \(name)", source: "LLMClient")
        }

        DebugLogger.shared.debug("LLMClient: Returning response. Content length: \(contentText.count), Has thinking: \(thinkingText.isEmpty ? "No" : "Yes (\(thinkingText.count) chars)")", source: "LLMClient")

        return Response(
            thinking: thinkingText.isEmpty ? nil : thinkingText,
            content: contentText,
            toolCalls: parsedToolCalls
        )
    }

    // MARK: - Parse Non-Streaming Message

    private func parseMessageResponse(_ message: [String: Any]) -> Response {
        // Extract content
        let rawContent = message["content"] as? String ?? ""

        // Check for tool calls
        var parsedToolCalls: [ToolCall] = []
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            parsedToolCalls = toolCalls.compactMap { tc -> ToolCall? in
                guard let function = tc["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let argsString = function["arguments"] as? String,
                      let argsData = argsString.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                else {
                    return nil
                }
                let id = tc["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                return ToolCall(id: id, name: name, arguments: args)
            }
            // Empty tool calls are fine, no action needed
        }

        // Strip thinking tags and extract thinking content
        let (thinking, cleanedContent) = self.stripThinkingTags(rawContent)

        // Also check for reasoning_content field (DeepSeek style)
        let reasoningContent = message["reasoning_content"] as? String
        let finalThinking = [thinking, reasoningContent].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")

        return Response(
            thinking: finalThinking.isEmpty ? nil : finalThinking,
            content: cleanedContent.isEmpty ? rawContent : cleanedContent,
            toolCalls: parsedToolCalls
        )
    }

    // MARK: - Thinking Token Extraction

    /// Pattern matches both <think>...</think> and <thinking>...</thinking> including multiline
    private static let thinkingTagPattern = #"<think(?:ing)?>([\s\S]*?)</think(?:ing)?>"#

    /// Pattern for orphan closing tags with content before them (no opening tag)
    private static let orphanThinkingPattern = #"^([\s\S]*?)</think(?:ing)?>"#

    /// Strips thinking tags from text and returns (thinking, cleanedContent)
    func stripThinkingTags(_ text: String) -> (thinking: String, content: String) {
        var workingText = text
        var thinking = ""

        // First, handle proper <think>...</think> pairs
        if let regex = try? NSRegularExpression(pattern: Self.thinkingTagPattern, options: []) {
            let range = NSRange(workingText.startIndex..., in: workingText)
            let matches = regex.matches(in: workingText, options: [], range: range)

            for match in matches {
                if let thinkRange = Range(match.range(at: 1), in: workingText) {
                    thinking += String(workingText[thinkRange])
                }
            }

            workingText = regex.stringByReplacingMatches(in: workingText, options: [], range: range, withTemplate: "")
        }

        // Second, handle orphan closing tags (content before </think> without opening tag)
        // This handles cases like "We have a request...</think>Hello!"
        if let orphanRegex = try? NSRegularExpression(pattern: Self.orphanThinkingPattern, options: []) {
            let range = NSRange(workingText.startIndex..., in: workingText)
            let matches = orphanRegex.matches(in: workingText, options: [], range: range)

            for match in matches {
                if let thinkRange = Range(match.range(at: 1), in: workingText) {
                    thinking += String(workingText[thinkRange])
                }
            }

            workingText = orphanRegex.stringByReplacingMatches(in: workingText, options: [], range: range, withTemplate: "")
        }

        // Also remove any stray </think> or </thinking> tags that might remain
        workingText = workingText.replacingOccurrences(of: "</think>", with: "")
        workingText = workingText.replacingOccurrences(of: "</thinking>", with: "")
        workingText = workingText.replacingOccurrences(of: "<think>", with: "")
        workingText = workingText.replacingOccurrences(of: "<thinking>", with: "")

        let cleaned = workingText.trimmingCharacters(in: .whitespacesAndNewlines)

        return (thinking, cleaned)
    }

    // MARK: - Helper Methods

    /// Check if an error is retryable (transient network issues)
    private func isRetryableError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet,
             .timedOut,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// Check if a URL is a local/private endpoint
    private func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host else { return false }

        let hostLower = host.lowercased()

        // Localhost
        if hostLower == "localhost" || hostLower == "127.0.0.1" {
            return true
        }

        // 127.x.x.x
        if hostLower.hasPrefix("127.") {
            return true
        }

        // 10.x.x.x (Private Class A)
        if hostLower.hasPrefix("10.") {
            return true
        }

        // 192.168.x.x (Private Class C)
        if hostLower.hasPrefix("192.168.") {
            return true
        }

        // 172.16.x.x - 172.31.x.x (Private Class B)
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
}
