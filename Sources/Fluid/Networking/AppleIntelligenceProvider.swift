import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Intelligence Availability Service

enum AppleIntelligenceService {
    /// Whether the current OS supports FoundationModels (compile-time + runtime check)
    static var isSupported: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    /// Whether Apple Intelligence is available and enabled on this device
    static var isAvailable: Bool {
        guard isSupported else { return false }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Human-readable reason why Apple Intelligence is unavailable
    static var unavailabilityReason: String? {
        if !isSupported {
            return "Requires macOS 26 (Tahoe) or later"
        }
        if !isAvailable {
            return "Enable in System Settings → Apple Intelligence & Siri"
        }
        return nil
    }
}

// MARK: - Apple Intelligence Provider

#if canImport(FoundationModels)
@available(macOS 26.0, *)
final class AppleIntelligenceProvider {
    /// Process text with a system prompt (for transcription enhancement)
    func process(systemPrompt: String, userText: String) async throws -> String {
        let session = LanguageModelSession()

        let fullPrompt = """
        \(systemPrompt)

        \(userText)
        """

        let response = try await session.respond(to: fullPrompt)
        return response.content
    }

    /// Process rewrite/write requests with conversation history
    func processRewrite(messages: [(role: String, content: String)], systemPrompt: String) async throws -> String {
        let session = LanguageModelSession()

        // Build the conversation as a single prompt since FoundationModels
        // doesn't have the same multi-turn API as OpenAI
        var fullPrompt = ""

        // Add system context
        fullPrompt += "\(systemPrompt)\n\n"

        // Add conversation history
        for message in messages {
            if message.role == "user" {
                fullPrompt += "User: \(message.content)\n\n"
            } else if message.role == "assistant" {
                fullPrompt += "Assistant: \(message.content)\n\n"
            }
        }

        fullPrompt += "Assistant:"

        let response = try await session.respond(to: fullPrompt)
        return response.content
    }
}
#endif
