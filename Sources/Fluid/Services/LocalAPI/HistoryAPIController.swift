import Foundation

struct HistoryAPIController: LocalAPIRouteHandler {
    struct HistoryResponse: Encodable {
        let count: Int
        let items: [HistoryItem]
    }

    struct HistoryItem: Encodable {
        let id: UUID
        let timestamp: Date
        let originalText: String
        let finalText: String
        let rawText: String
        let processedText: String
        let appName: String
        let windowTitle: String
        let characterCount: Int
        let wasAIProcessed: Bool
        let transcriptionDurationMilliseconds: Int?
        let parakeetProcessingDurationMilliseconds: Int?
        let aiProcessingDurationMilliseconds: Int?
        let aiTokensPerSecond: Double?
        let aiProcessingError: String?
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        guard request.method == "GET" else {
            return LocalAPI.error("Method not allowed.", status: 405)
        }

        let limit = LocalAPI.boundedLimit(from: request)
        do {
            try await TranscriptionHistoryStore.shared.waitUntilLoaded()
        } catch {
            return LocalAPI.error("History is unavailable. Retry from History in FluidVoice.", status: 503)
        }
        let items = TranscriptionHistoryStore.shared.entries
            .prefix(limit)
            .map { entry in
                HistoryItem(
                    id: entry.id,
                    timestamp: entry.timestamp,
                    originalText: entry.rawText,
                    finalText: entry.processedText,
                    rawText: entry.rawText,
                    processedText: entry.processedText,
                    appName: entry.appName,
                    windowTitle: entry.windowTitle,
                    characterCount: entry.characterCount,
                    wasAIProcessed: entry.wasAIProcessed,
                    transcriptionDurationMilliseconds: entry.transcriptionDurationMilliseconds,
                    parakeetProcessingDurationMilliseconds: entry.parakeetProcessingDurationMilliseconds,
                    aiProcessingDurationMilliseconds: entry.aiProcessingDurationMilliseconds,
                    aiTokensPerSecond: entry.aiTokensPerSecond,
                    aiProcessingError: entry.aiProcessingError
                )
            }

        return LocalAPI.json(HistoryResponse(count: items.count, items: Array(items)))
    }
}
