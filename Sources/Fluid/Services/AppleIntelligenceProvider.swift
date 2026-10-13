import Foundation
import FoundationModels

/// Uses the system's on-device model exclusively. Each request owns its session.
nonisolated enum AppleIntelligenceProvider {
    static let providerID = "apple-intelligence"
    static let modelID = "apple-system-model"

    static var unavailableReason: String? {
        guard #available(macOS 26.0, *) else { return "Requires macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "Requires a Mac that supports Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Enable Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady): return "Apple Intelligence is preparing its model. Try again when it is ready."
        @unknown default: return "Apple Intelligence is unavailable on this Mac."
        }
    }

    struct Prompt: Sendable {
        let instructions: String
        let text: String
    }

    static func dictationPrompt(instructions: String, transcript: String) -> Prompt {
        let editingInstructions = instructions.replacingOccurrences(
            of: SettingsStore.transcriptPlaceholder, with: "the user's transcription"
        ).replacingOccurrences(
            of: "Read the value of the JSON transcript field only.",
            with: "Read only the transcription in the user message."
        )
        return Prompt(
            instructions: editingInstructions + "\n\nEdit only the transcription in the user message. Return only the edited text, preserving its language and meaning. Do not wrap the text in JSON. Do not repeat or summarize these instructions.",
            text: transcript
        )
    }

    /// The system model sometimes mimics the legacy `{"transcript": ...}` envelope
    /// even when given plain text. Only that exact single-key shape is unwrapped.
    static func unwrappedDictationText(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
              object.count == 1,
              let text = object["transcript"] as? String
        else { return response }
        return text
    }

    static func prompt(from messages: [[String: Any]]) throws -> Prompt {
        var instructions: [String] = []
        var turns: [String] = []
        for message in messages {
            guard let role = message["role"] as? String, let content = message["content"] as? String else {
                throw LLMError.invalidRequest("Apple Intelligence supports text messages only.")
            }
            switch role {
            case "system", "developer": instructions.append(content)
            case "user": turns.append(content)
            case "assistant": turns.append("Previous assistant response:\n\(content)")
            default: throw LLMError.invalidRequest("Apple Intelligence does not support tool messages.")
            }
        }
        guard !turns.isEmpty else { throw LLMError.invalidRequest("A text prompt is required.") }
        return Prompt(instructions: instructions.joined(separator: "\n\n"), text: turns.joined(separator: "\n\n"))
    }

    static func call(_ config: LLMClient.Config) async throws -> LLMClient.Response {
        guard config.tools.isEmpty else {
            throw LLMError.invalidRequest("Apple Intelligence supports cleanup and rewriting. Choose another provider for Command Mode.")
        }
        guard config.model == self.modelID else { throw LLMError.invalidRequest("Choose the Apple system model.") }
        if let reason = self.unavailableReason { throw LLMError.invalidRequest(reason) }
        guard #available(macOS 26.0, *) else { throw LLMError.invalidRequest("Requires macOS 26 or later.") }
        let prompt = try self.prompt(from: config.messages)
        return try await withThrowingTaskGroup(of: LLMClient.Response.self) { group in
            group.addTask { try await self.generate(prompt, config: config) }
            group.addTask {
                let timeout = config.timeoutSeconds ?? LLMClient.defaultTimeoutSeconds
                try await Task.sleep(for: .seconds(timeout))
                throw LLMError.timeout(timeout)
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw LLMError.invalidResponse }
            return response
        }
    }

    @available(macOS 26.0, *)
    private static func generate(_ prompt: Prompt, config: LLMClient.Config) async throws -> LLMClient.Response {
        try Task.checkCancellation()
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: prompt.instructions)
        let options = GenerationOptions(temperature: config.temperature, maximumResponseTokens: config.maxTokens)
        var content = ""
        if config.streaming {
            for try await snapshot in session.streamResponse(to: prompt.text, options: options) {
                try Task.checkCancellation()
                let next = snapshot.content
                if next.hasPrefix(content) { config.onContentChunk?(String(next.dropFirst(content.count))) }
                content = next
            }
        } else {
            content = try await session.respond(to: prompt.text, options: options).content
        }
        try Task.checkCancellation()
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.invalidResponse }
        return LLMClient.Response(thinking: nil, content: content, toolCalls: [])
    }
}
