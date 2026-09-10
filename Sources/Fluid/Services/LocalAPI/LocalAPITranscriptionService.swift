import Foundation

struct LocalAPITranscriptionPayload {
    let text: String
    let confidence: Float
    let sampleCount: Int
}

@MainActor
enum LocalAPITranscriptionService {
    static func transcribe(_ fileURL: URL) async throws -> LocalAPITranscriptionPayload {
        let apiResult = try await AppServices.shared.asr.transcribeFileForAPI(fileURL)
        return LocalAPITranscriptionPayload(
            text: apiResult.result.text,
            confidence: apiResult.result.confidence,
            sampleCount: apiResult.sampleCount
        )
    }
}
