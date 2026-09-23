import Foundation

/// Separates cleanup instructions from untrusted transcript data while keeping
/// explicitly authored transcript templates and blank prompts compatible.
struct DictationPromptRequest {
    let systemPrompt: String
    let userContent: String

    init(systemPrompt: String, userContent: String) {
        self.systemPrompt = systemPrompt
        self.userContent = userContent
    }

    init(promptText: String, transcript: String) {
        if promptText.contains("${transcript}") {
            self.init(systemPrompt: "", userContent: Self.renderTemplate(promptText: promptText, transcript: transcript))
        } else if promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.init(systemPrompt: "", userContent: transcript)
        } else {
            // JSON escaping prevents quotes, newlines, or transcript-supplied
            // delimiters from escaping the data envelope.
            let data: Data
            do {
                data = try JSONEncoder().encode(["transcript": transcript])
            } catch {
                // A dictionary containing only Swift strings is always JSON encodable.
                preconditionFailure("Unable to encode dictation transcript: \(error)")
            }
            guard let encoded = String(data: data, encoding: .utf8) else {
                preconditionFailure("JSONEncoder returned invalid UTF-8")
            }
            self.init(systemPrompt: promptText, userContent: encoded)
        }
    }

    var messages: [[String: Any]] {
        var result: [[String: Any]] = []
        if !self.systemPrompt.isEmpty {
            result.append(["role": "system", "content": self.systemPrompt])
        }
        result.append(["role": "user", "content": self.userContent])
        return result
    }

    static func renderTemplate(promptText: String, transcript: String) -> String {
        if promptText.contains("${transcript}") {
            return promptText.replacingOccurrences(of: "${transcript}", with: transcript)
        }
        if promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return transcript }
        return promptText + "\n\n" + transcript
    }
}
