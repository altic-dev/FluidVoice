//
//  ModelRepository.swift
//  Fluid
//
//  Single source of truth for default model lists and base URLs per provider.
//  All views (AISettings, ContentView, CommandMode, RewriteMode) should use this
//  instead of maintaining their own hardcoded lists.
//

import Foundation

final class ModelRepository {
    static let shared = ModelRepository()

    private init() {}

    /// All built-in provider IDs (not including custom/saved providers)
    static let builtInProviderIDs = [
        "fluid-1", "openai", "anthropic", "xai", "groq", "cerebras", "google", "openrouter", "ollama", "lmstudio", "apple-intelligence",
    ]

    /// Returns the default models for a given provider ID.
    /// This is used when the user has not added any custom models for that provider.
    func defaultModels(for providerID: String) -> [String] {
        switch providerID {
        case "fluid-1":
            return ["fluid-1-preview"]
        case "openai":
            return ["gpt-4.1"]
        case "anthropic":
            return ["claude-sonnet-4-20250514"]
        case "xai":
            return ["grok-3-fast"]
        case "groq":
            return ["openai/gpt-oss-120b"]
        case "cerebras":
            return ["gpt-oss-120b"]
        case "google":
            return ["gemini-2.5-flash"]
        case "openrouter":
            return ["openai/gpt-oss-20b"]
        case "ollama", "lmstudio":
            // Local providers - models vary per user, they must add their own
            return []
        case "apple-intelligence":
            return ["System Model"]
        default:
            // Custom providers start with no default models; user must add them
            return []
        }
    }

    /// Returns the default base URL for a given provider ID.
    func defaultBaseURL(for providerID: String) -> String {
        switch providerID {
        case "openai":
            return "https://api.openai.com/v1"
        case "anthropic":
            return "https://api.anthropic.com/v1"
        case "xai":
            return "https://api.x.ai/v1"
        case "groq":
            return "https://api.groq.com/openai/v1"
        case "cerebras":
            return "https://api.cerebras.ai/v1"
        case "google":
            return "https://generativelanguage.googleapis.com/v1beta/openai"
        case "openrouter":
            return "https://openrouter.ai/api/v1"
        case "ollama":
            return "http://localhost:11434/v1"
        case "lmstudio":
            return "http://localhost:1234/v1"
        default:
            return ""
        }
    }

    /// Returns the display name for a provider ID
    func displayName(for providerID: String) -> String {
        switch providerID {
        case "fluid-1": return "Fluid-1"
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "xai": return "xAI"
        case "groq": return "Groq"
        case "cerebras": return "Cerebras"
        case "google": return "Google"
        case "openrouter": return "OpenRouter"
        case "ollama": return "Ollama"
        case "lmstudio": return "LM Studio"
        case "apple-intelligence": return "Apple Intelligence"
        default: return providerID.capitalized
        }
    }

    /// Check if a provider ID is a built-in provider
    func isBuiltIn(_ providerID: String) -> Bool {
        Self.builtInProviderIDs.contains(providerID)
    }

    /// Returns the website URL for getting an API key or downloading the provider software.
    /// Returns nil for providers that don't have a relevant URL (e.g., Apple Intelligence).
    func providerWebsiteURL(for providerID: String) -> (url: String, label: String)? {
        switch providerID {
        case "openai":
            return ("https://platform.openai.com/api-keys", "Get API Key")
        case "anthropic":
            return ("https://console.anthropic.com/settings/keys", "Get API Key")
        case "xai":
            return ("https://console.x.ai/", "Get API Key")
        case "groq":
            return ("https://console.groq.com/keys", "Get API Key")
        case "cerebras":
            return ("https://cloud.cerebras.ai/platform", "Get API Key")
        case "google":
            return ("https://aistudio.google.com/apikey", "Get API Key")
        case "openrouter":
            return ("https://openrouter.ai/settings/keys", "Get API Key")
        case "ollama":
            return ("https://github.com/ollama/ollama/blob/main/docs/openai.md", "Setup Guide")
        case "lmstudio":
            return ("https://lmstudio.ai/docs/local-server", "Setup Guide")
        default:
            return nil
        }
    }

    /// Check if a URL represents a local endpoint (localhost, local IP)
    func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host else { return false }
        let hostLower = host.lowercased()
        if hostLower == "localhost" || hostLower == "127.0.0.1" { return true }
        if hostLower.hasPrefix("127.") || hostLower.hasPrefix("10.") || hostLower.hasPrefix("192.168.") { return true }
        if hostLower.hasPrefix("172.") {
            let components = hostLower.split(separator: ".")
            if components.count >= 2, let secondOctet = Int(components[1]), secondOctet >= 16 && secondOctet <= 31 {
                return true
            }
        }
        return false
    }

    /// Returns the list of built-in providers for UI pickers
    /// - Parameter includeAppleIntelligence: Whether to include Apple Intelligence
    /// - Parameter appleIntelligenceAvailable: Whether Apple Intelligence is available on this device
    /// - Parameter appleIntelligenceDisabledReason: Optional reason if disabled (e.g., "No tools")
    func builtInProvidersList(
        includeAppleIntelligence: Bool = true,
        appleIntelligenceAvailable: Bool = false,
        appleIntelligenceDisabledReason: String? = nil
    ) -> [(id: String, name: String)] {
        var list: [(id: String, name: String)] = [
            ("fluid-1", "Fluid-1"),
            ("openai", "OpenAI"),
            ("anthropic", "Anthropic"),
            ("xai", "xAI"),
            ("groq", "Groq"),
            ("cerebras", "Cerebras"),
            ("google", "Google"),
            ("openrouter", "OpenRouter"),
            ("ollama", "Ollama"),
            ("lmstudio", "LM Studio"),
        ]

        if includeAppleIntelligence {
            if appleIntelligenceAvailable {
                list.append(("apple-intelligence", "Apple Intelligence"))
            } else if let reason = appleIntelligenceDisabledReason {
                list.append(("apple-intelligence-disabled", "Apple Intelligence (\(reason))"))
            } else {
                list.append(("apple-intelligence-disabled", "Apple Intelligence (Unavailable)"))
            }
        }

        return list
    }

    /// Converts a provider ID to a storage key for UserDefaults
    /// Built-in providers use their ID directly; custom providers get "custom:" prefix
    func providerKey(for providerID: String) -> String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return providerID }

        // Built-in providers use their ID directly
        if self.isBuiltIn(trimmed) {
            return trimmed
        }

        // Custom providers: ensure "custom:" prefix
        if trimmed.hasPrefix("custom:") {
            return trimmed
        }
        return "custom:\(trimmed)"
    }

    /// Returns all possible keys for a provider (for looking up stored settings)
    func providerKeys(for providerID: String) -> [String] {
        var keys: [String] = []
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return [providerID]
        }

        // Built-in providers: just use the ID
        if self.isBuiltIn(trimmed) {
            return [trimmed]
        }

        // Custom providers: try both with and without prefix
        if trimmed.hasPrefix("custom:") {
            keys.append(trimmed)
            keys.append(String(trimmed.dropFirst("custom:".count)))
        } else {
            keys.append("custom:\(trimmed)")
            keys.append(trimmed)
        }

        return Array(Set(keys))
    }

    // MARK: - Fetch Models from API

    /// Fetches available models from the provider's API
    /// - Parameters:
    ///   - providerID: The provider identifier
    ///   - baseURL: The base URL for the API (e.g., "https://api.openai.com/v1")
    ///   - apiKey: Optional API key for authentication
    /// - Returns: Array of model IDs sorted alphabetically
    func fetchModels(for providerID: String, baseURL: String, apiKey: String?) async throws -> [String] {
        let isAnthropic = providerID == "anthropic" || baseURL.contains("anthropic.com")

        // Construct the models endpoint URL
        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)models" : "\(baseURL)/models"
        guard let url = URL(string: urlString) else {
            DebugLogger.shared.error(
                "fetchModels: Invalid URL constructed from baseURL='\(baseURL)' -> '\(urlString)'",
                source: "ModelRepository"
            )
            throw FetchError.invalidURL(details: "Could not construct valid URL from base: \(baseURL)")
        }

        DebugLogger.shared.debug(
            "fetchModels: Fetching models for '\(providerID)' from \(urlString) (isAnthropic=\(isAnthropic))",
            source: "ModelRepository"
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        // Add authentication headers (different for Anthropic)
        if let key = apiKey, !key.isEmpty {
            if isAnthropic {
                // Anthropic uses x-api-key header and requires anthropic-version
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.compatData(for: request)
        } catch {
            let errorDetails = self.detailedNetworkError(error)
            DebugLogger.shared.error(
                "fetchModels: Network error for '\(providerID)': \(errorDetails)",
                source: "ModelRepository"
            )
            throw FetchError.networkError(details: errorDetails)
        }

        // Check for HTTP errors with detailed messages
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let bodyString = String(data: data, encoding: .utf8) ?? "<unable to decode response body>"
            let errorDetails = self.interpretHTTPError(
                statusCode: httpResponse.statusCode,
                providerID: providerID,
                responseBody: bodyString,
                endpoint: urlString
            )
            DebugLogger.shared.error(
                "fetchModels: HTTP \(httpResponse.statusCode) for '\(providerID)': \(errorDetails)\nResponse body: \(bodyString.prefix(500))",
                source: "ModelRepository"
            )
            throw FetchError.httpError(statusCode: httpResponse.statusCode, details: errorDetails)
        }

        // Parse the response - OpenAI format: { "data": [{ "id": "model-name" }, ...] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? "<binary data>"
            DebugLogger.shared.error(
                "fetchModels: Failed to parse JSON for '\(providerID)'. Response preview: \(bodyPreview)",
                source: "ModelRepository"
            )
            throw FetchError.invalidResponse(details: "Response is not valid JSON. Check if the base URL '\(baseURL)' is correct.")
        }

        // Try OpenAI/Groq/Cerebras format first
        if let dataArray = json["data"] as? [[String: Any]] {
            let models = dataArray.compactMap { $0["id"] as? String }
            DebugLogger.shared.debug(
                "fetchModels: Found \(models.count) models for '\(providerID)' (OpenAI format)",
                source: "ModelRepository"
            )
            return models.sorted()
        }

        // Try Google format: { "models": [{ "name": "models/gemini-pro" }, ...] }
        if let modelsArray = json["models"] as? [[String: Any]] {
            let models = modelsArray.compactMap { dict -> String? in
                if let name = dict["name"] as? String {
                    // Google returns "models/gemini-pro", extract just the model name
                    return name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                }
                return nil
            }
            DebugLogger.shared.debug(
                "fetchModels: Found \(models.count) models for '\(providerID)' (Google format)",
                source: "ModelRepository"
            )
            return models.sorted()
        }

        // Log what we actually received
        let topLevelKeys = json.keys.joined(separator: ", ")
        DebugLogger.shared.error(
            "fetchModels: Unknown response format for '\(providerID)'. Top-level keys: [\(topLevelKeys)]. Expected 'data' or 'models' array.",
            source: "ModelRepository"
        )
        throw FetchError.invalidResponse(details: "Unknown response format. Top-level keys: [\(topLevelKeys)]. Expected 'data' or 'models'.")
    }

    /// Provides detailed interpretation of HTTP errors
    private func interpretHTTPError(statusCode: Int, providerID: String, responseBody: String, endpoint: String) -> String {
        let providerName = self.displayName(for: providerID)

        switch statusCode {
        case 400:
            return "Bad Request - The request format was invalid. Check if the base URL '\(endpoint)' is correct for \(providerName)."
        case 401:
            if responseBody.lowercased().contains("invalid") || responseBody.lowercased().contains("api key") || responseBody.lowercased().contains("authentication") {
                return "Invalid API Key - The API key for \(providerName) appears to be incorrect or expired. Please verify your API key."
            }
            return "Unauthorized - API key is missing or invalid for \(providerName). Double-check your API key."
        case 403:
            if responseBody.lowercased().contains("permission") || responseBody.lowercased().contains("access") {
                return "Forbidden - Your API key doesn't have permission to list models for \(providerName). Check your account permissions."
            }
            return "Forbidden - Access denied for \(providerName). Your API key may lack the required permissions."
        case 404:
            return "Not Found - The /models endpoint doesn't exist at '\(endpoint)'. This provider may not support model listing, or the base URL is incorrect."
        case 429:
            return "Rate Limited - Too many requests to \(providerName). Wait a moment and try again."
        case 500, 502, 503:
            return "\(providerName) server error (HTTP \(statusCode)). The service may be temporarily unavailable."
        default:
            return "HTTP \(statusCode) from \(providerName). Check your API key and base URL configuration."
        }
    }

    /// Provides detailed network error messages
    private func detailedNetworkError(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut:
            return "Connection timed out - The server didn't respond in time. Check if the base URL is correct and the service is running."
        case NSURLErrorCannotConnectToHost:
            return "Cannot connect to host - Check if the base URL is correct. For local providers (Ollama, LM Studio), ensure the server is running."
        case NSURLErrorNetworkConnectionLost:
            return "Network connection lost - Check your internet connection."
        case NSURLErrorNotConnectedToInternet:
            return "No internet connection - Check your network settings."
        case NSURLErrorSecureConnectionFailed:
            return "SSL/TLS error - The server's security certificate may be invalid or expired."
        case NSURLErrorCannotFindHost:
            return "Cannot find host - The domain name doesn't exist. Check if the base URL is spelled correctly."
        default:
            return "\(error.localizedDescription) (Error code: \(nsError.code))"
        }
    }

    enum FetchError: LocalizedError {
        case invalidURL(details: String)
        case httpError(statusCode: Int, details: String)
        case invalidResponse(details: String)
        case networkError(details: String)

        var errorDescription: String? {
            switch self {
            case let .invalidURL(details):
                return "Invalid API URL: \(details)"
            case let .httpError(code, details):
                return "API error (HTTP \(code)): \(details)"
            case let .invalidResponse(details):
                return "Invalid response: \(details)"
            case let .networkError(details):
                return "Network error: \(details)"
            }
        }
    }
}
