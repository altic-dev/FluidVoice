@testable import FluidVoice_Debug
import Foundation
import XCTest

final class AppleIntelligenceProviderTests: XCTestCase {
    func testCleanupTemplateKeepsTranscriptSeparateFromInstructions() {
        let transcript = "hello ${transcript} and \"quoted\" words"
        let prompt = AppleIntelligenceProvider.dictationPrompt(
            instructions: "Clean and format raw transcribed speech: ${transcript}", transcript: transcript
        )
        XCTAssertEqual(prompt.text, transcript)
        XCTAssertFalse(prompt.instructions.contains("${transcript}"))
        XCTAssertFalse(prompt.instructions.contains(transcript))
    }

    func testShortDictationDoesNotRequestJSONWhenSendingPlainText() {
        // Regression: Apple cleanup returned {"transcript": "Meaning, what?"}.
        let transcript = "Meaning what?"
        let prompt = AppleIntelligenceProvider.dictationPrompt(
            instructions: SettingsStore.defaultDictationPromptBodyText(), transcript: transcript
        )
        XCTAssertEqual(prompt.text, transcript)
        XCTAssertFalse(prompt.instructions.contains("JSON transcript field"))
    }

    func testAppleCleanupUnwrapsTranscriptEnvelopeRegression() {
        // Regression: Apple Intelligence returned {"transcript": "Meaning, what?"}.
        XCTAssertEqual(
            AppleIntelligenceProvider.unwrappedDictationText("{\"transcript\": \"Meaning, what?\"}"),
            "Meaning, what?"
        )
    }

    func testIntentionalJSONOutputIsNeverUnwrapped() {
        let scenarios = [
            "{\"text\": \"Meaning, what?\"}",
            "{\"transcript\": \"Meaning, what?\", \"language\": \"en\"}",
            "{\"transcript\": 42}",
            "Meaning, what?",
        ]
        for response in scenarios {
            XCTAssertEqual(AppleIntelligenceProvider.unwrappedDictationText(response), response)
        }
        let envelope = "{\"transcript\": \"Meaning, what?\"}"
        XCTAssertEqual(
            DictationPromptRequest.cleanedText(response: envelope, instructions: "Fix grammar.", transcript: "Meaning what?"),
            envelope
        )
        // If the user deliberately dictated a {"transcript": "hello"} JSON envelope, preserve it:
        let intentionalJSON = "{\"transcript\": \"hello\"}"
        XCTAssertEqual(
            AppleIntelligenceProvider.unwrappedDictationText(intentionalJSON, originalTranscript: intentionalJSON),
            intentionalJSON
        )
    }

    func testCustomClosingPhrasePreservedInsteadOfFlaggedAsEcho() {
        let instructions = "Fix transcription typos.\nSign off with:\nThank you for your time."
        let transcript = "thanks for your time"
        let response = "Thank you for your time."
        XCTAssertEqual(
            DictationPromptRequest.cleanedText(response: response, instructions: instructions, transcript: transcript),
            response
        )
    }

    func testCleanupInstructionEchoPreservesSpeech() {
        let instruction = "Read the value of the JSON transcript field only."
        let transcript = "Please send the report tomorrow."
        let scenarios = [
            (instruction, transcript, transcript),
            (instruction + "\n" + transcript, transcript, transcript),
            ("Please send the report tomorrow.", transcript, transcript),
            (instruction, instruction, instruction),
            ("Send the report tomorrow!", transcript, "Send the report tomorrow!"),
            ("Read only the transcription in the user message", transcript, transcript),
        ]
        for (response, spokenText, expected) in scenarios {
            XCTAssertEqual(DictationPromptRequest.cleanedText(
                response: response, instructions: instruction, transcript: spokenText
            ), expected)
        }
    }

    func testSystemInstructionsStaySeparateFromConversation() throws {
        let prompt = try AppleIntelligenceProvider.prompt(from: [
            ["role": "system", "content": "Preserve meaning."],
            ["role": "user", "content": "First draft"],
            ["role": "assistant", "content": "Earlier revision"],
            ["role": "user", "content": "Make it shorter"],
        ])
        XCTAssertEqual(prompt.instructions, "Preserve meaning.")
        XCTAssertFalse(prompt.text.contains(prompt.instructions))
        for text in ["First draft", "Earlier revision", "Make it shorter"] { XCTAssertTrue(prompt.text.contains(text)) }
    }

    func testUnsupportedMessageShapesFailInsteadOfDroppingContent() {
        let scenarios: [[[String: Any]]] = [
            [], [["role": "system", "content": "Only instructions"]],
            [["role": "tool", "content": "Tool result"]],
            [["role": "user", "content": [["type": "image_url"]]]],
        ]
        for messages in scenarios {
            XCTAssertThrowsError(try AppleIntelligenceProvider.prompt(from: messages)) { error in
                guard case LLMError.invalidRequest = error else { return XCTFail("Expected invalid request, got \(error)") }
            }
        }
    }

    func testToolRequestsFailBeforeNativeModelOrHTTPTransport() async {
        let config = LLMClient.Config(
            providerID: AppleIntelligenceProvider.providerID,
            messages: [["role": "user", "content": "Open an app"]],
            model: AppleIntelligenceProvider.modelID,
            baseURL: "",
            apiKey: "",
            tools: [["type": "function"]]
        )
        do {
            _ = try await LLMClient.shared.call(config)
            XCTFail("Native text provider must reject Command Mode tools")
        } catch {
            guard case LLMError.invalidRequest = error else { return XCTFail("Expected invalid request, got \(error)") }
        }
    }
}
