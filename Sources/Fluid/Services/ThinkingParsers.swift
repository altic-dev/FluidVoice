import Foundation

// MARK: - Thinking Parser Protocol

/// Protocol for parsing thinking tokens from LLM streaming responses.
/// Different model families have different patterns for thinking tokens.
protocol ThinkingParser {
    /// Process a content chunk during streaming.
    /// - Parameters:
    ///   - chunk: The new content chunk from the stream
    ///   - currentState: Current parsing state
    ///   - tagBuffer: Buffer for incomplete tag detection (inout)
    /// - Returns: Tuple of (newState, thinkingChunk, contentChunk)
    mutating func processChunk(
        _ chunk: String,
        currentState: ThinkingParserState,
        tagBuffer: inout String
    ) -> (ThinkingParserState, String, String)
    
    /// Post-process the final buffers after streaming completes.
    /// Some parsers may need to do final cleanup.
    /// - Parameters:
    ///   - thinkingBuffer: Accumulated thinking chunks
    ///   - contentBuffer: Accumulated content chunks
    ///   - finalState: The state at the end of streaming
    /// - Returns: Tuple of cleaned (thinking, content) strings
    func finalize(thinkingBuffer: [String], contentBuffer: [String], finalState: ThinkingParserState) -> (thinking: String, content: String)
}

// MARK: - Parser State

enum ThinkingParserState {
    case initial       // Haven't determined if we're in thinking or content yet
    case inThinking    // Currently inside thinking section
    case inContent     // Currently in main content
}

// MARK: - Parser Factory

/// Factory to create the appropriate parser and extra parameters based on model name
enum ThinkingParserFactory {
    
    /// Create a parser appropriate for the given model
    static func createParser(for model: String) -> ThinkingParser {
        let modelLower = model.lowercased()
        
        // Nemotron/Nemo models: no opening <think>, just </think> as separator
        if modelLower.contains("nemotron") || modelLower.contains("nemo") {
            DebugLogger.shared.debug("ThinkingParser: Using NemoParser for model '\(model)'", source: "LLMClient")
            return NemoThinkingParser()
        }
        
        // Qwen models with thinking: use standard <think>...</think> pattern
        if modelLower.contains("qwen") && (modelLower.contains("think") || modelLower.contains("qwq")) {
            DebugLogger.shared.debug("ThinkingParser: Using StandardParser for Qwen model '\(model)'", source: "LLMClient")
            return StandardThinkingParser()
        }
        
        // DeepSeek models: use standard pattern (they also have reasoning_content field handled separately)
        if modelLower.contains("deepseek") {
            DebugLogger.shared.debug("ThinkingParser: Using StandardParser for DeepSeek model '\(model)'", source: "LLMClient")
            return StandardThinkingParser()
        }
        
        // Default: Standard parser with <think>...</think> pattern
        DebugLogger.shared.debug("ThinkingParser: Using StandardParser (default) for model '\(model)'", source: "LLMClient")
        return StandardThinkingParser()
    }
    
    /// Get model-specific extra parameters for the API request.
    /// These are parameters beyond the standard model/messages/temperature.
    static func getExtraParameters(for model: String) -> [String: Any]? {
        let modelLower = model.lowercased()
        
        // Nemotron/Nemo models: require enable_thinking flag
        if modelLower.contains("nemotron") || modelLower.contains("nemo") {
            DebugLogger.shared.debug("ThinkingParser: Adding enable_thinking=true for Nemotron model '\(model)'", source: "LLMClient")
            return [
                "enable_thinking": true
                // "truncate_history_thinking": false  // Optional: could expose this in settings
            ]
        }
        
        // DeepSeek R1 models: may need reasoning parameters
        if modelLower.contains("deepseek") && modelLower.contains("r1") {
            DebugLogger.shared.debug("ThinkingParser: Adding reasoning params for DeepSeek R1 model '\(model)'", source: "LLMClient")
            return [
                "enable_reasoning": true
            ]
        }
        
        // Claude with thinking: requires thinking parameters (handled via Anthropic API differently)
        // OpenAI o1/o3 with reasoning: uses reasoning_effort parameter
        
        return nil
    }
}


// MARK: - Standard Thinking Parser

/// Standard parser for models that use `<think>...</think>` or `<thinking>...</thinking>` tags.
/// Used by: DeepSeek, Qwen, Claude (when thinking enabled), most open models
struct StandardThinkingParser: ThinkingParser {
    
    mutating func processChunk(
        _ chunk: String,
        currentState: ThinkingParserState,
        tagBuffer: inout String
    ) -> (ThinkingParserState, String, String) {
        
        // Add chunk to buffer for tag detection
        tagBuffer += chunk
        
        var thinkingChunk = ""
        var contentChunk = ""
        var newState = currentState
        
        // Check for opening tag
        if newState != .inThinking {
            if let openRange = tagBuffer.range(of: "<think>") ?? tagBuffer.range(of: "<thinking>") {
                // Content before the tag goes to content
                let beforeTag = String(tagBuffer[..<openRange.lowerBound])
                if !beforeTag.isEmpty {
                    contentChunk += beforeTag
                }
                // Remove processed part including open tag
                tagBuffer = String(tagBuffer[openRange.upperBound...])
                newState = .inThinking
            }
        }
        
        // Check for closing tag
        if newState == .inThinking {
            if let closeRange = tagBuffer.range(of: "</think>") ?? tagBuffer.range(of: "</thinking>") {
                // Content before the closing tag is thinking
                let beforeClose = String(tagBuffer[..<closeRange.lowerBound])
                if !beforeClose.isEmpty {
                    thinkingChunk += beforeClose
                }
                // Content after closing tag goes to content
                tagBuffer = String(tagBuffer[closeRange.upperBound...])
                newState = .inContent
                
                // Any remaining buffer is content
                if !tagBuffer.isEmpty {
                    contentChunk += tagBuffer
                    tagBuffer = ""
                }
            } else {
                // Still in thinking, emit what we have (minus potential partial tag)
                // Keep last 15 chars in buffer to detect partial closing tags
                let safeLength = max(0, tagBuffer.count - 15)
                if safeLength > 0 {
                    let safeIndex = tagBuffer.index(tagBuffer.startIndex, offsetBy: safeLength)
                    thinkingChunk = String(tagBuffer[..<safeIndex])
                    tagBuffer = String(tagBuffer[safeIndex...])
                }
            }
        } else if newState == .inContent || newState == .initial {
            // Not in thinking mode, emit content (minus potential partial open tag)
            let safeLength = max(0, tagBuffer.count - 15)
            if safeLength > 0 {
                let safeIndex = tagBuffer.index(tagBuffer.startIndex, offsetBy: safeLength)
                contentChunk = String(tagBuffer[..<safeIndex])
                tagBuffer = String(tagBuffer[safeIndex...])
            }
        }
        
        return (newState, thinkingChunk, contentChunk)
    }
    
    func finalize(thinkingBuffer: [String], contentBuffer: [String], finalState: ThinkingParserState) -> (thinking: String, content: String) {
        let thinking = thinkingBuffer.joined()
        var content = contentBuffer.joined()
        
        // Strip any remaining stray tags
        content = content.replacingOccurrences(of: "</think>", with: "")
        content = content.replacingOccurrences(of: "</thinking>", with: "")
        content = content.replacingOccurrences(of: "<think>", with: "")
        content = content.replacingOccurrences(of: "<thinking>", with: "")
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (thinking, content)
    }
}

// MARK: - Nemo Thinking Parser

/// Parser for Nemotron/Nemo models that output thinking WITHOUT an opening <think> tag.
/// Pattern: `thinking content</think>actual response`
/// Everything before `</think>` is thinking, everything after is content.
struct NemoThinkingParser: ThinkingParser {
    
    mutating func processChunk(
        _ chunk: String,
        currentState: ThinkingParserState,
        tagBuffer: inout String
    ) -> (ThinkingParserState, String, String) {
        
        // Add chunk to buffer
        tagBuffer += chunk
        
        var thinkingChunk = ""
        var contentChunk = ""
        var newState = currentState
        
        // For Nemo: we're in thinking mode until we see </think>
        // Initial state = thinking (no opening tag needed)
        if newState == .initial {
            newState = .inThinking
        }
        
        if newState == .inThinking {
            // Look for closing tag
            if let closeRange = tagBuffer.range(of: "</think>") ?? tagBuffer.range(of: "</thinking>") {
                // Everything before the tag is thinking
                let beforeClose = String(tagBuffer[..<closeRange.lowerBound])
                if !beforeClose.isEmpty {
                    thinkingChunk = beforeClose
                }
                
                // Everything after is content
                tagBuffer = String(tagBuffer[closeRange.upperBound...])
                newState = .inContent
                
                // Emit remaining buffer as content
                if !tagBuffer.isEmpty {
                    contentChunk = tagBuffer
                    tagBuffer = ""
                }
                
                DebugLogger.shared.debug("NemoParser: Found </think>. Thinking: \(thinkingChunk.count) chars, Content: \(contentChunk.count) chars", source: "LLMClient")
            } else {
                // Still waiting for </think>, emit thinking (minus potential partial tag)
                let safeLength = max(0, tagBuffer.count - 15)
                if safeLength > 0 {
                    let safeIndex = tagBuffer.index(tagBuffer.startIndex, offsetBy: safeLength)
                    thinkingChunk = String(tagBuffer[..<safeIndex])
                    tagBuffer = String(tagBuffer[safeIndex...])
                }
            }
        } else if newState == .inContent {
            // Already past the </think>, everything is content
            contentChunk = tagBuffer
            tagBuffer = ""
        }
        
        return (newState, thinkingChunk, contentChunk)
    }
    
    func finalize(thinkingBuffer: [String], contentBuffer: [String], finalState: ThinkingParserState) -> (thinking: String, content: String) {
        var thinking = thinkingBuffer.joined()
        var content = contentBuffer.joined()
        
        // IMPORTANT: If we're still in .inThinking state at the end, it means
        // we NEVER saw a </think> tag. This indicates thinking mode was OFF
        // (server didn't use thinking). All "thinking" is actually content!
        if finalState == .inThinking {
            // Move all thinking to content
            content = thinking + content
            thinking = ""
            DebugLogger.shared.debug("NemoParser finalize: No </think> found - treating all as content (\(content.count) chars)", source: "LLMClient")
        }
        
        // Clean up any stray tags
        content = content.replacingOccurrences(of: "</think>", with: "")
        content = content.replacingOccurrences(of: "</thinking>", with: "")
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return (thinking, content)
    }
}

// MARK: - No Thinking Parser

/// Parser for models that don't use thinking tokens at all.
/// Everything is content.
struct NoThinkingParser: ThinkingParser {
    
    mutating func processChunk(
        _ chunk: String,
        currentState: ThinkingParserState,
        tagBuffer: inout String
    ) -> (ThinkingParserState, String, String) {
        // Everything is content
        return (.inContent, "", chunk)
    }
    
    func finalize(thinkingBuffer: [String], contentBuffer: [String], finalState: ThinkingParserState) -> (thinking: String, content: String) {
        return ("", contentBuffer.joined())
    }
}
