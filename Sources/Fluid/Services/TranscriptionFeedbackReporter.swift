import Foundation

enum TranscriptionFeedbackReporter {
    struct Payload: Encodable {
        let rawText: String
        let processedText: String
        let processingModel: String
        let comments: String
    }

    enum ReporterError: LocalizedError {
        case invalidURL
        case invalidResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid report endpoint."
            case .invalidResponse:
                return "Invalid report response."
            case let .httpError(statusCode):
                return "Report failed with HTTP \(statusCode)."
            }
        }
    }

    private static let endpoint = "https://altic.dev/api/fluid/examples"

    static func submit(_ payload: Payload) async throws {
        guard let url = URL(string: self.endpoint) else {
            throw ReporterError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReporterError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ReporterError.httpError(httpResponse.statusCode)
        }
    }
}
