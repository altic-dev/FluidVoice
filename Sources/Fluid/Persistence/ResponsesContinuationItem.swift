import Foundation

nonisolated struct LLMResponsesContinuationItem: Codable, Equatable, Sendable {
    let id: String
    let encryptedContent: String

    var inputItem: [String: Any] {
        [
            "type": "reasoning",
            "id": self.id,
            "summary": [],
            "encrypted_content": self.encryptedContent,
        ]
    }
}
