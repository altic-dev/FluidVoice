//
//  AppleIntelligenceProvider.swift
//  FluidVoice
//
//  On-device AI processing using Apple's FoundationModels framework (macOS 26+)
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Intelligence Availability Service

struct AppleIntelligenceService {
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
    
    /// Process text with a system prompt (for transcription cleanup)
    func process(systemPrompt: String, userText: String) async -> String {
        do {
            let session = LanguageModelSession()
            
            let fullPrompt = """
            \(systemPrompt)
            
            \(userText)
            """
            
            let response = try await session.respond(to: fullPrompt)
            return response.content
        } catch {
            DebugLogger.shared.error("Apple Intelligence error: \(error.localizedDescription)", source: "AppleIntelligenceProvider")
            return "Error: \(error.localizedDescription)"
        }
    }
    
    /// Process rewrite/write requests with conversation history
    func processRewrite(messages: [(role: String, content: String)], isWriteMode: Bool) async throws -> String {
        let session = LanguageModelSession()
        
        // Build the conversation as a single prompt since FoundationModels
        // doesn't have the same multi-turn API as OpenAI
        var fullPrompt = ""
        
        // Add system context
        if isWriteMode {
            fullPrompt += """
            You are a helpful writing assistant. The user will ask you to write or generate text for them.
            Respond directly with the requested content. Be concise and helpful.
            Output ONLY what they asked for - no explanations or preamble.
            
            """
        } else {
            fullPrompt += """
            You are a writing assistant that rewrites text according to user instructions.
            Follow the user's specific instructions for how to rewrite.
            Output ONLY the rewritten text. No explanations, no quotes, no preamble.
            
            """
        }
        
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


