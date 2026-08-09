import Foundation

// MARK: - Error Types

enum LLMError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case networkError(Error)
    case encodingError
    case timeout(TimeInterval)
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from LLM"
        case let .httpError(code, message):
            return "HTTP \(code): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .networkError(error):
            return Self.userFacingNetworkMessage(from: error)
        case .encodingError:
            return "Failed to encode request"
        case let .timeout(seconds):
            return "Request timed out after \(Int(seconds)) seconds"
        case let .invalidRequest(message):
            return message
        }
    }

    private static func userFacingNetworkMessage(from error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "Network error: \(error.localizedDescription)"
        }

        switch urlError.code {
        case .notConnectedToInternet:
            return "Network error: no internet connection."
        case .timedOut:
            return "Network error: request timed out."
        case .cannotFindHost:
            return "Network error: could not find API host."
        case .cannotConnectToHost:
            return "Network error: could not connect to API host."
        case .networkConnectionLost:
            return "Network error: connection dropped during the request."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "Network error: TLS certificate validation failed."
        default:
            return "Network error: \(urlError.localizedDescription)"
        }
    }
}

// MARK: - LLMClient

/// Unified LLM communication layer for all modes (Transcription, Command, Rewrite).
/// Handles HTTP requests, SSE streaming, thinking token extraction, and tool call parsing.
@MainActor
final class LLMClient {
    static let shared = LLMClient()

    /// Default timeout for LLM requests (30 seconds)
    static let defaultTimeoutSeconds: TimeInterval = 30

    /// URLSession configured with appropriate timeouts
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.defaultTimeoutSeconds
        config.timeoutIntervalForResource = Self.defaultTimeoutSeconds * 2 // Allow extra time for resource loading
        self.session = URLSession(configuration: config)
    }

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

    private struct ResponsesToolCallAccumulator {
        var id: String?
        var callID: String?
        var name: String?
        var arguments: String = ""
    }

    private struct AnthropicToolCallAccumulator {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    // MARK: - Configuration

    struct Config {
        /// Provider identity is required for non-OpenAI wire protocols and
        /// first-party subscription logins. Empty preserves legacy behavior.
        let providerID: String
        let messages: [[String: Any]]
        let model: String
        let baseURL: String
        let apiKey: String
        var streaming: Bool
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

        /// Timeout configuration (nil = use default)
        var timeoutSeconds: TimeInterval?

        // Optional real-time callbacks (for streaming UI updates)
        var onThinkingStart: (() -> Void)?
        var onThinkingChunk: ((String) -> Void)?
        var onThinkingEnd: (() -> Void)?
        var onContentChunk: ((String) -> Void)?
        var onToolCallStart: ((String) -> Void)?

        init(
            providerID: String = "",
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
            self.providerID = providerID
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
        let officialSession: OfficialProviderAuth.Session?
        if OfficialProviderAuth.isOfficialProvider(config.providerID) {
            officialSession = try await OfficialProviderAuth.resolve(
                providerID: config.providerID,
                session: self.session
            )
        } else {
            officialSession = nil
        }
        var effectiveConfig = config
        effectiveConfig.streaming = Self.effectiveStreaming(
            providerID: config.providerID,
            requested: config.streaming
        )
        var request = try self.buildRequest(effectiveConfig, officialSession: officialSession)
        let wireProtocol = officialSession?.wireProtocol

        // Apply timeout to the request itself
        let timeout = config.timeoutSeconds ?? Self.defaultTimeoutSeconds
        request.timeoutInterval = timeout

        self.logRequest(request)

        // Execute the request. We rely on URLRequest/URLSession timeouts (30s default) rather
        // than racing a separate "timeout task". A task-group timeout wrapper can accidentally
        // keep the caller suspended until the full timeout elapses, which is the exact stall
        // we want to eliminate for overlay responsiveness.
        return try await self.executeWithRetry(
            request: request,
            config: effectiveConfig,
            wireProtocol: wireProtocol
        )
    }

    static func effectiveStreaming(providerID: String, requested: Bool) -> Bool {
        requested || OfficialProviderAuth.requiresStreamingRequests(providerID)
    }

    /// Execute request with retry logic (extracted for timeout wrapper)
    private func executeWithRetry(
        request: URLRequest,
        config: Config,
        wireProtocol: OfficialProviderAuth.WireProtocol?
    ) async throws -> Response {
        var lastError: Error?
        for attempt in 1...config.maxRetries {
            do {
                if config.streaming {
                    if wireProtocol == .anthropicMessages {
                        return try await self.processAnthropicStreaming(request: request, config: config)
                    }
                    if wireProtocol == .geminiCodeAssist {
                        return try await self.processGeminiStreaming(request: request, config: config)
                    }
                    if wireProtocol == .responses || self.isResponsesRequest(request) {
                        return try await self.processResponsesStreaming(request: request, config: config)
                    }
                    return try await self.processStreaming(request: request, config: config)
                } else {
                    return try await self.processNonStreaming(request: request, wireProtocol: wireProtocol)
                }
            } catch let error as URLError where self.isRetryableError(error) {
                lastError = LLMError.networkError(error)
                DebugLogger.shared.warning("LLMClient: Retry \(attempt)/\(config.maxRetries) due to \(error.code.rawValue)", source: "LLMClient")
                if attempt < config.maxRetries {
                    // Exponential backoff
                    let delayNs = UInt64(config.retryDelayMs * 1_000_000 * attempt)
                    try? await Task.sleep(nanoseconds: delayNs)
                    continue
                }
            } catch let error as URLError {
                throw LLMError.networkError(error)
            } catch {
                throw error // Non-retryable error
            }
        }

        throw lastError ?? LLMError.networkError(
            NSError(domain: "LLMClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Request failed after retries"])
        )
    }

    // MARK: - Request Building

    private func buildRequest(
        _ config: Config,
        officialSession: OfficialProviderAuth.Session? = nil
    ) throws -> URLRequest {
        // Build endpoint URL
        let baseURL = (officialSession?.baseURL ?? config.baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else {
            DebugLogger.shared.error("LLMClient: Missing base URL; refusing to fall back to OpenAI", source: "LLMClient")
            throw LLMError.invalidURL
        }

        let wireProtocol = officialSession?.wireProtocol
        let useResponsesAPI = wireProtocol == .responses || self.shouldUseResponsesAPI(for: config, baseURL: baseURL)
        let endpoint: String
        switch wireProtocol {
        case .anthropicMessages:
            endpoint = baseURL.contains("/messages") ? baseURL : self.appendingPath("messages", to: baseURL)
        case .geminiCodeAssist:
            let operation = config.streaming ? ":streamGenerateContent?alt=sse" : ":generateContent"
            endpoint = baseURL.contains(":generateContent") || baseURL.contains(":streamGenerateContent")
                ? baseURL
                : "\(baseURL)\(operation)"
        case .responses, .none:
            endpoint = self.endpoint(for: baseURL, useResponsesAPI: useResponsesAPI)
        }

        guard let url = URL(string: endpoint) else {
            throw LLMError.invalidURL
        }

        let body: [String: Any]
        switch wireProtocol {
        case .anthropicMessages:
            body = self.buildAnthropicMessagesBody(config)
        case .geminiCodeAssist:
            body = self.buildGeminiCodeAssistBody(config, project: officialSession?.project ?? "")
        case .responses, .none:
            body = useResponsesAPI ? self.buildResponsesBody(config) : self.buildChatCompletionsBody(config)
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

        // Send Authorization whenever a key exists; some localhost endpoints still require auth.
        let accessToken = officialSession?.accessToken ?? config.apiKey
        if !accessToken.isEmpty {
            request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in officialSession?.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }

        request.httpBody = jsonData

        return request
    }

    private func appendingPath(_ path: String, to baseURL: String) -> String {
        baseURL.hasSuffix("/") ? "\(baseURL)\(path)" : "\(baseURL)/\(path)"
    }

    private func endpoint(for baseURL: String, useResponsesAPI: Bool) -> String {
        if useResponsesAPI {
            if baseURL.contains("/responses") {
                return baseURL
            }
            if baseURL.contains("/chat/completions") {
                return baseURL.replacingOccurrences(of: "/chat/completions", with: "/responses")
            }
            return self.appendingPath("responses", to: baseURL)
        }

        if baseURL.contains("/chat/completions") ||
            baseURL.contains("/api/chat") ||
            baseURL.contains("/api/generate")
        {
            return baseURL
        }
        return self.appendingPath("chat/completions", to: baseURL)
    }

    private func shouldUseResponsesAPI(for config: Config, baseURL: String) -> Bool {
        if baseURL.contains("/responses") {
            return true
        }

        guard let url = URL(string: baseURL),
              url.host?.lowercased() == "api.openai.com"
        else { return false }

        let modelLower = config.model.lowercased()
        return modelLower.hasPrefix("gpt-5") ||
            modelLower.hasPrefix("o1") ||
            modelLower.hasPrefix("o3") ||
            modelLower.hasPrefix("o4")
    }

    private func isResponsesRequest(_ request: URLRequest) -> Bool {
        request.url?.path.contains("/responses") == true
    }

    func buildChatCompletionsBody(_ config: Config) -> [String: Any] {
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

        // Always send stream explicitly — providers like Ollama treat an absent key as true
        body["stream"] = config.streaming

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

        return body
    }

    func buildResponsesBody(_ config: Config) -> [String: Any] {
        let usesCodexSubscription = config.providerID == OfficialProviderAuth.codexProviderID
        let systemInstructions = config.messages.compactMap { message -> String? in
            guard message["role"] as? String == "system",
                  let content = message["content"] as? String,
                  !content.isEmpty
            else { return nil }
            return content
        }.joined(separator: "\n\n")
        var body: [String: Any] = [
            "model": config.model,
            "input": self.responsesInput(
                from: config.messages,
                excludingSystemMessages: usesCodexSubscription
            ),
            "store": false,
        ]

        if usesCodexSubscription {
            if !systemInstructions.isEmpty { body["instructions"] = systemInstructions }
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = false
            body["include"] = ["reasoning.encrypted_content"]
        }

        // Always send stream explicitly — providers like Ollama treat an absent key as true
        body["stream"] = config.streaming

        if !config.tools.isEmpty {
            body["tools"] = self.responsesTools(from: config.tools)
            body["tool_choice"] = "auto"
        }

        // The ChatGPT Codex subscription backend follows the official Codex
        // request contract, which does not accept `max_output_tokens`.
        // Keep the standard Responses API behavior for API-key providers.
        if let tokens = config.maxTokens, !usesCodexSubscription {
            body["max_output_tokens"] = tokens
        }

        if let temp = config.temperature {
            body["temperature"] = temp
        }

        for (key, value) in ThinkingParserFactory.getExtraParameters(for: config.model) {
            self.addResponsesExtraParameter(name: key, value: value, to: &body)
        }

        for (key, value) in config.extraParameters {
            self.addResponsesExtraParameter(name: key, value: value, to: &body)
        }

        return body
    }

    func buildAnthropicMessagesBody(_ config: Config) -> [String: Any] {
        var systemParts: [String] = []
        var messages: [[String: Any]] = []

        func appendMessage(role: String, blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let lastIndex = messages.indices.last,
               messages[lastIndex]["role"] as? String == role,
               var existing = messages[lastIndex]["content"] as? [[String: Any]]
            {
                existing.append(contentsOf: blocks)
                messages[lastIndex]["content"] = existing
            } else {
                messages.append(["role": role, "content": blocks])
            }
        }

        for message in config.messages {
            let role = message["role"] as? String ?? "user"
            let content = message["content"] as? String ?? ""
            if role == "system" {
                if !content.isEmpty { systemParts.append(content) }
                continue
            }
            if role == "tool" {
                appendMessage(role: "user", blocks: [[
                    "type": "tool_result",
                    "tool_use_id": message["tool_call_id"] as? String ?? "call_unknown",
                    "content": content,
                ]])
                continue
            }

            var blocks: [[String: Any]] = []
            if !content.isEmpty {
                blocks.append(["type": "text", "text": content])
            }
            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                for toolCall in toolCalls {
                    guard let function = toolCall["function"] as? [String: Any],
                          let name = function["name"] as? String
                    else { continue }
                    let argumentsString = function["arguments"] as? String ?? "{}"
                    let input = argumentsString.data(using: .utf8)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    blocks.append([
                        "type": "tool_use",
                        "id": toolCall["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))",
                        "name": name,
                        "input": input,
                    ])
                }
            }
            appendMessage(role: role == "assistant" ? "assistant" : "user", blocks: blocks)
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "max_tokens": config.maxTokens ?? 4096,
            "stream": config.streaming,
        ]
        if !systemParts.isEmpty {
            body["system"] = systemParts.joined(separator: "\n\n")
        }
        if let temperature = config.temperature {
            body["temperature"] = temperature
        }
        if !config.tools.isEmpty {
            body["tools"] = config.tools.compactMap { tool -> [String: Any]? in
                guard tool["type"] as? String == "function",
                      let function = tool["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let parameters = function["parameters"] as? [String: Any]
                else { return nil }
                var converted: [String: Any] = ["name": name, "input_schema": parameters]
                if let description = function["description"] as? String {
                    converted["description"] = description
                }
                return converted
            }
        }
        for (name, value) in config.extraParameters where name != "reasoning_effort" {
            body[name] = value
        }
        return body
    }

    func buildGeminiCodeAssistBody(_ config: Config, project: String) -> [String: Any] {
        var systemParts: [String] = []
        var contents: [[String: Any]] = []
        var toolNamesByCallID: [String: String] = [:]

        for message in config.messages {
            guard let toolCalls = message["tool_calls"] as? [[String: Any]] else { continue }
            for toolCall in toolCalls {
                guard let callID = toolCall["id"] as? String,
                      let function = toolCall["function"] as? [String: Any],
                      let name = function["name"] as? String
                else { continue }
                toolNamesByCallID[callID] = name
            }
        }

        func appendContent(role: String, parts: [[String: Any]]) {
            guard !parts.isEmpty else { return }
            if let lastIndex = contents.indices.last,
               contents[lastIndex]["role"] as? String == role,
               var existing = contents[lastIndex]["parts"] as? [[String: Any]]
            {
                existing.append(contentsOf: parts)
                contents[lastIndex]["parts"] = existing
            } else {
                contents.append(["role": role, "parts": parts])
            }
        }

        for message in config.messages {
            let role = message["role"] as? String ?? "user"
            let content = message["content"] as? String ?? ""
            if role == "system" {
                if !content.isEmpty { systemParts.append(content) }
                continue
            }
            if role == "tool" {
                let callID = message["tool_call_id"] as? String ?? "call_unknown"
                appendContent(role: "user", parts: [[
                    "functionResponse": [
                        "name": toolNamesByCallID[callID] ?? "tool",
                        "response": ["result": content],
                    ],
                ]])
                continue
            }

            var parts: [[String: Any]] = []
            if !content.isEmpty { parts.append(["text": content]) }
            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                for toolCall in toolCalls {
                    guard let function = toolCall["function"] as? [String: Any],
                          let name = function["name"] as? String
                    else { continue }
                    let argumentsString = function["arguments"] as? String ?? "{}"
                    let arguments = argumentsString.data(using: .utf8)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    parts.append(["functionCall": ["name": name, "args": arguments]])
                }
            }
            appendContent(role: role == "assistant" ? "model" : "user", parts: parts)
        }

        var request: [String: Any] = [
            "contents": contents,
            "session_id": UUID().uuidString.lowercased(),
        ]
        if !systemParts.isEmpty {
            request["systemInstruction"] = ["parts": [["text": systemParts.joined(separator: "\n\n")]]]
        }

        var generationConfig: [String: Any] = [:]
        if let temperature = config.temperature { generationConfig["temperature"] = temperature }
        if let maxTokens = config.maxTokens { generationConfig["maxOutputTokens"] = maxTokens }
        for (name, value) in config.extraParameters where name != "reasoning_effort" {
            generationConfig[name] = value
        }
        if !generationConfig.isEmpty { request["generationConfig"] = generationConfig }

        if !config.tools.isEmpty {
            let declarations = config.tools.compactMap { tool -> [String: Any]? in
                guard tool["type"] as? String == "function",
                      let function = tool["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      let parameters = function["parameters"] as? [String: Any]
                else { return nil }
                var declaration: [String: Any] = ["name": name, "parameters": parameters]
                if let description = function["description"] as? String {
                    declaration["description"] = description
                }
                return declaration
            }
            if !declarations.isEmpty { request["tools"] = [["functionDeclarations": declarations]] }
        }

        return [
            "model": config.model,
            "project": project,
            "user_prompt_id": UUID().uuidString.lowercased(),
            "request": request,
        ]
    }

    private func addResponsesExtraParameter(name: String, value: Any, to body: inout [String: Any]) {
        if name == "reasoning_effort" {
            body["reasoning"] = ["effort": value]
        } else {
            body[name] = value
        }
    }

    private func responsesTools(from chatTools: [[String: Any]]) -> [[String: Any]] {
        var tools: [[String: Any]] = []

        for chatTool in chatTools {
            guard chatTool["type"] as? String == "function",
                  let function = chatTool["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let parameters = function["parameters"] as? [String: Any]
            else { continue }

            var tool: [String: Any] = [
                "type": "function",
                "name": name,
                "parameters": parameters,
                "strict": false,
            ]
            if let description = function["description"] as? String {
                tool["description"] = description
            }
            tools.append(tool)
        }

        return tools
    }

    private func responsesInput(
        from messages: [[String: Any]],
        excludingSystemMessages: Bool = false
    ) -> [[String: Any]] {
        var input: [[String: Any]] = []

        for message in messages {
            let role = message["role"] as? String ?? "user"
            if excludingSystemMessages, role == "system" { continue }

            if role == "tool" {
                input.append([
                    "type": "function_call_output",
                    "call_id": message["tool_call_id"] as? String ?? "call_unknown",
                    "output": message["content"] as? String ?? "",
                ])
                continue
            }

            if let content = message["content"] as? String, !content.isEmpty {
                input.append([
                    "role": role,
                    "content": content,
                ])
            }

            guard let toolCalls = message["tool_calls"] as? [[String: Any]] else { continue }
            for toolCall in toolCalls {
                guard let function = toolCall["function"] as? [String: Any],
                      let name = function["name"] as? String
                else { continue }

                input.append([
                    "type": "function_call",
                    "call_id": toolCall["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))",
                    "name": name,
                    "arguments": function["arguments"] as? String ?? "{}",
                ])
            }
        }

        return input
    }

    // MARK: - Non-Streaming Response

    private func processNonStreaming(
        request: URLRequest,
        wireProtocol: OfficialProviderAuth.WireProtocol?
    ) async throws -> Response {
        DebugLogger.shared.debug("LLMClient: Making non-streaming request to \(request.url?.absoluteString ?? "unknown")", source: "LLMClient")

        let (data, response) = try await self.session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let errText = String(data: data, encoding: .utf8) ?? "Unknown error"
            DebugLogger.shared.error("LLMClient: HTTP error \(http.statusCode): \(errText.prefix(200))", source: "LLMClient")
            throw LLMError.httpError(http.statusCode, errText)
        }

        DebugLogger.shared.debug("LLMClient: Non-streaming response received (\(data.count) bytes)", source: "LLMClient")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse
        }

        if wireProtocol == .anthropicMessages {
            return try self.parseAnthropicResponse(json)
        }
        if wireProtocol == .geminiCodeAssist {
            return try self.parseGeminiResponse(json)
        }
        if wireProtocol == .responses || self.isResponsesRequest(request) {
            return try self.parseResponsesResponse(json)
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any]
        else { throw LLMError.invalidResponse }

        return self.parseMessageResponse(message)
    }

    private func processAnthropicStreaming(request: URLRequest, config: Config) async throws -> Response {
        let (bytes, response) = try await self.session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw LLMError.httpError(http.statusCode, String(data: errorData, encoding: .utf8) ?? "Unknown error")
        }

        var content: [String] = []
        var thinking: [String] = []
        var toolCalls: [Int: AnthropicToolCallAccumulator] = [:]
        var isThinking = false

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let jsonString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = jsonString.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            let index = event["index"] as? Int ?? 0
            switch type {
            case "content_block_start":
                guard let block = event["content_block"] as? [String: Any] else { continue }
                switch block["type"] as? String {
                case "tool_use":
                    var call = toolCalls[index] ?? AnthropicToolCallAccumulator()
                    call.id = block["id"] as? String
                    call.name = block["name"] as? String
                    if let input = block["input"] as? [String: Any], !input.isEmpty,
                       let inputData = try? JSONSerialization.data(withJSONObject: input),
                       let inputString = String(data: inputData, encoding: .utf8)
                    {
                        call.arguments = inputString
                    }
                    toolCalls[index] = call
                    if let name = call.name { config.onToolCallStart?(name) }
                case "thinking":
                    if !isThinking { config.onThinkingStart?() }
                    isThinking = true
                default:
                    break
                }
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    if isThinking {
                        isThinking = false
                        config.onThinkingEnd?()
                    }
                    if let text = delta["text"] as? String {
                        content.append(text)
                        config.onContentChunk?(text)
                    }
                case "thinking_delta":
                    if !isThinking { config.onThinkingStart?() }
                    isThinking = true
                    if let text = delta["thinking"] as? String {
                        thinking.append(text)
                        config.onThinkingChunk?(text)
                    }
                case "input_json_delta":
                    var call = toolCalls[index] ?? AnthropicToolCallAccumulator()
                    call.arguments += delta["partial_json"] as? String ?? ""
                    toolCalls[index] = call
                default:
                    break
                }
            default:
                continue
            }
        }
        if isThinking { config.onThinkingEnd?() }

        let parsedTools = toolCalls.keys.sorted().compactMap { index -> ToolCall? in
            guard let call = toolCalls[index], let name = call.name else { return nil }
            let argumentString = call.arguments.isEmpty ? "{}" : call.arguments
            guard let data = argumentString.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return ToolCall(
                id: call.id ?? "call_\(UUID().uuidString.prefix(8))",
                name: name,
                arguments: arguments
            )
        }
        let thinkingText = thinking.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return Response(
            thinking: thinkingText.isEmpty ? nil : thinkingText,
            content: content.joined().trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: parsedTools
        )
    }

    private func processGeminiStreaming(request: URLRequest, config: Config) async throws -> Response {
        let (bytes, response) = try await self.session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw LLMError.httpError(http.statusCode, String(data: errorData, encoding: .utf8) ?? "Unknown error")
        }

        var content: [String] = []
        var thinking: [String] = []
        var tools: [ToolCall] = []
        var reportedThinking = false

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let jsonString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = jsonString.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let parsed = self.geminiParts(from: root)
            for text in parsed.content {
                content.append(text)
                config.onContentChunk?(text)
            }
            for text in parsed.thinking {
                if !reportedThinking { config.onThinkingStart?() }
                reportedThinking = true
                thinking.append(text)
                config.onThinkingChunk?(text)
            }
            for tool in parsed.toolCalls {
                tools.append(tool)
                config.onToolCallStart?(tool.name)
            }
        }
        if reportedThinking { config.onThinkingEnd?() }
        let thinkingText = thinking.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return Response(
            thinking: thinkingText.isEmpty ? nil : thinkingText,
            content: content.joined().trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: tools
        )
    }

    private func processResponsesStreaming(request: URLRequest, config: Config) async throws -> Response {
        DebugLogger.shared.debug("LLMClient: Starting Responses streaming request to \(request.url?.absoluteString ?? "unknown")", source: "LLMClient")

        let (bytes, response) = try await self.session.bytes(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let errText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw LLMError.httpError(http.statusCode, errText)
        }

        var contentBuffer: [String] = []
        var toolCallsByIndex: [Int: ResponsesToolCallAccumulator] = [:]

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
                  let event = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = event["type"] as? String
            else {
                continue
            }

            switch type {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String {
                    contentBuffer.append(delta)
                    config.onContentChunk?(delta)
                }
            case "response.output_item.added", "response.output_item.done":
                guard let item = event["item"] as? [String: Any],
                      item["type"] as? String == "function_call"
                else { continue }
                let index = event["output_index"] as? Int ?? 0
                var call = toolCallsByIndex[index] ?? ResponsesToolCallAccumulator()
                call.id = item["id"] as? String ?? call.id
                call.callID = item["call_id"] as? String ?? call.callID
                call.name = item["name"] as? String ?? call.name
                if let arguments = item["arguments"] as? String, !arguments.isEmpty {
                    call.arguments = arguments
                }
                toolCallsByIndex[index] = call
                if let name = call.name {
                    config.onToolCallStart?(name)
                }
            case "response.function_call_arguments.delta":
                let index = event["output_index"] as? Int ?? 0
                var call = toolCallsByIndex[index] ?? ResponsesToolCallAccumulator()
                call.arguments += event["delta"] as? String ?? ""
                toolCallsByIndex[index] = call
            case "response.function_call_arguments.done":
                let index = event["output_index"] as? Int ?? 0
                var call = toolCallsByIndex[index] ?? ResponsesToolCallAccumulator()
                call.id = event["item_id"] as? String ?? call.id
                call.callID = event["call_id"] as? String ?? call.callID
                call.name = event["name"] as? String ?? call.name
                call.arguments = event["arguments"] as? String ?? call.arguments
                if let item = event["item"] as? [String: Any] {
                    call.id = item["id"] as? String ?? call.id
                    call.callID = item["call_id"] as? String ?? call.callID
                    call.name = item["name"] as? String ?? call.name
                    call.arguments = item["arguments"] as? String ?? call.arguments
                }
                toolCallsByIndex[index] = call
            default:
                continue
            }
        }

        let toolCalls = toolCallsByIndex.keys.sorted().compactMap { index -> ToolCall? in
            guard let call = toolCallsByIndex[index],
                  let name = call.name,
                  let argsData = call.arguments.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
            else { return nil }

            return ToolCall(
                id: call.callID ?? call.id ?? "call_\(UUID().uuidString.prefix(8))",
                name: name,
                arguments: args
            )
        }

        return Response(
            thinking: nil,
            content: contentBuffer.joined().trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: toolCalls
        )
    }

    private func processStreaming(request: URLRequest, config: Config) async throws -> Response {
        DebugLogger.shared.debug("LLMClient: Starting streaming request to \(request.url?.absoluteString ?? "unknown")", source: "LLMClient")

        let (bytes, response) = try await self.session.bytes(for: request)

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
        var usesSeparateReasoningFields = false

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

            // DEBUG LOG: Show full delta to see all fields (e.g., 'reasoning', 'thought', 'delta_reasoning', etc.)
            if let deltaData = try? JSONSerialization.data(withJSONObject: delta, options: [.fragmentsAllowed]),
               let deltaString = String(data: deltaData, encoding: .utf8)
            {
                DebugLogger.shared.debug("LLMClient: Full Delta: \(deltaString)", source: "LLMClient")
            }

            // Handle separate reasoning fields (OpenAI 'reasoning', 'reasoning_content', DeepSeek, etc.)
            let reasoningField = delta["reasoning_content"] as? String ??
                delta["reasoning"] as? String ??
                delta["thought"] as? String ??
                delta["thinking"] as? String

            if let reasoning = reasoningField {
                usesSeparateReasoningFields = true
                if state == .initial {
                    state = .inThinking
                    config.onThinkingStart?()
                }
                thinkingBuffer.append(reasoning)
                config.onThinkingChunk?(reasoning)
            }

            // Handle content with potential <think> tags
            if let content = delta["content"] as? String {
                if usesSeparateReasoningFields {
                    if state == .inThinking {
                        state = .inContent
                        config.onThinkingEnd?()
                    }
                    contentBuffer.append(content)
                    config.onContentChunk?(content)
                    continue
                }

                // If we were in thinking mode via a separate field (not tag-based),
                // receiving "content" usually means the thinking phase is over.
                if state == .inThinking && reasoningField == nil && tagDetectionBuffer.isEmpty {
                    // This is a subtle heuristic: if we were thinking, didn't just get a reasoning field chunk,
                    // and have no partial tags buffered, we should check if this content chunk
                    // is the start of the final answer.
                    // For safety with tag-based parsers, we let the parser decide unless it's a known separate-field model.
                }

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

    private func parseAnthropicResponse(_ json: [String: Any]) throws -> Response {
        guard let blocks = json["content"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }
        var content: [String] = []
        var thinking: [String] = []
        var tools: [ToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { content.append(text) }
            case "thinking":
                if let text = block["thinking"] as? String { thinking.append(text) }
            case "tool_use":
                guard let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any]
                else { continue }
                tools.append(ToolCall(
                    id: block["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))",
                    name: name,
                    arguments: input
                ))
            default:
                continue
            }
        }
        let thinkingText = thinking.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Response(
            thinking: thinkingText.isEmpty ? nil : thinkingText,
            content: content.joined().trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: tools
        )
    }

    private func parseGeminiResponse(_ json: [String: Any]) throws -> Response {
        let parsed = self.geminiParts(from: json)
        guard !parsed.content.isEmpty || !parsed.thinking.isEmpty || !parsed.toolCalls.isEmpty else {
            throw LLMError.invalidResponse
        }
        let thinkingText = parsed.thinking.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return Response(
            thinking: thinkingText.isEmpty ? nil : thinkingText,
            content: parsed.content.joined().trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: parsed.toolCalls
        )
    }

    private func geminiParts(from root: [String: Any]) -> (
        content: [String],
        thinking: [String],
        toolCalls: [ToolCall]
    ) {
        let payload = (root["response"] as? [String: Any]) ?? root
        let candidates = payload["candidates"] as? [[String: Any]] ?? []
        var content: [String] = []
        var thinking: [String] = []
        var tools: [ToolCall] = []

        for candidate in candidates {
            guard let candidateContent = candidate["content"] as? [String: Any],
                  let parts = candidateContent["parts"] as? [[String: Any]]
            else { continue }
            for part in parts {
                if let text = part["text"] as? String {
                    if part["thought"] as? Bool == true {
                        thinking.append(text)
                    } else {
                        content.append(text)
                    }
                }
                if let call = part["functionCall"] as? [String: Any],
                   let name = call["name"] as? String
                {
                    tools.append(ToolCall(
                        id: call["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))",
                        name: name,
                        arguments: call["args"] as? [String: Any] ?? [:]
                    ))
                }
            }
        }
        return (content, thinking, tools)
    }

    private func parseResponsesResponse(_ json: [String: Any]) throws -> Response {
        guard let output = json["output"] as? [[String: Any]] else {
            throw LLMError.invalidResponse
        }

        var contentParts: [String] = []
        var parsedToolCalls: [ToolCall] = []

        for item in output {
            switch item["type"] as? String {
            case "message":
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    if part["type"] as? String == "output_text",
                       let text = part["text"] as? String
                    {
                        contentParts.append(text)
                    }
                }
            case "function_call":
                guard let name = item["name"] as? String,
                      let argsString = item["arguments"] as? String,
                      let argsData = argsString.data(using: .utf8),
                      let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]
                else { continue }

                parsedToolCalls.append(
                    ToolCall(
                        id: item["call_id"] as? String ?? item["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))",
                        name: name,
                        arguments: args
                    )
                )
            default:
                continue
            }
        }

        let rawContent = contentParts.joined()
        let (thinking, cleanedContent) = self.stripThinkingTags(rawContent)

        return Response(
            thinking: thinking.isEmpty ? nil : thinking,
            content: cleanedContent.isEmpty ? rawContent.trimmingCharacters(in: .whitespacesAndNewlines) : cleanedContent,
            toolCalls: parsedToolCalls
        )
    }

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

        // Also check for multiple reasoning field variants
        let reasoningContent = message["reasoning_content"] as? String ??
            message["reasoning"] as? String ??
            message["thought"] as? String ??
            message["thinking"] as? String

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

    // MARK: - Logging Helpers

    private func logRequest(_ request: URLRequest) {
        guard let url = request.url, let method = request.httpMethod else { return }

        var bodyString = ""
        if let body = request.httpBody {
            bodyString = String(data: body, encoding: .utf8) ?? ""
        }

        var curl = "curl -X \(method) \"\(url.absoluteString)\" \\\n"
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let normalizedKey = key.lowercased()
            let isSensitive = normalizedKey.contains("auth") ||
                normalizedKey.contains("token") ||
                normalizedKey.contains("api-key") ||
                normalizedKey.contains("account-id") ||
                normalizedKey.contains("userid") ||
                normalizedKey.contains("user-id")
            let maskedValue = isSensitive ? "[REDACTED]" : value
            curl += "  -H \"\(key): \(maskedValue)\" \\\n"
        }
        curl += "  -d '\(bodyString)'"

        DebugLogger.shared.info("LLMClient: Full Request as cURL:\n\(curl)", source: "LLMClient")
    }
}
