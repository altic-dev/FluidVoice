import Foundation

/// Explicitly selected cloud ASR. Never used as a fallback for a local engine.
final class SixtyDBProvider: TranscriptionProvider {
    private let session: URLSession
    private let apiKey: () -> String

    init(
        session: URLSession = SixtyDBProvider.cloudSession,
        apiKey: @escaping () -> String = {
            ProcessInfo.processInfo.environment["SIXTYDB_API_KEY"] ?? ""
        }
    ) {
        self.session = session
        self.apiKey = apiKey
    }

    var name: String {
        "60db (Cloud)"
    }

    var isAvailable: Bool {
        true
    }

    var isReady: Bool {
        !self.apiKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var shouldClearCacheAfterCancellation: Bool {
        false
    }

    func modelsExistOnDisk() -> Bool {
        true
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        guard self.isReady else { throw SixtyDBError.missingKey }
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        // Batch API: preview requests must not upload repeated prefixes or incur charges.
        ASRTranscriptionResult(text: "", confidence: 0)
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try Task.checkCancellation()
        let request = try Self.request(samples: samples, apiKey: self.apiKey())
        let (data, response) = try await self.session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SixtyDBError.invalidResponse }
        guard http.statusCode == 200 else { throw SixtyDBError.http(http.statusCode) }
        struct Response: Decodable {
            let text: String
            let success: Bool?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.success != false
        else { throw SixtyDBError.invalidResponse }
        return ASRTranscriptionResult(text: decoded.text, confidence: decoded.text.isEmpty ? 0 : 1)
    }

    static func request(samples: [Float], apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }) else { throw SixtyDBError.missingKey }
        // Conservatively use decimal MB for the documented 10 MB limit, including WAV header.
        guard !samples.isEmpty, samples.count <= (10_000_000 - 44) / 2,
              samples.allSatisfy(\.isFinite)
        else { throw SixtyDBError.invalidAudio }

        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        append(UInt32(36 + samples.count * 2))
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(16_000))
        append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(samples.count * 2))
        for value in samples {
            append(Int16(max(-1, min(1, value)) * Float(Int16.max)))
        }

        let boundary = "FluidVoice-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.60db.ai/stt")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    static let cloudSession = URLSession(configuration: .ephemeral, delegate: RedirectDelegate(), delegateQueue: nil)
}

enum SixtyDBError: LocalizedError {
    case missingKey
    case invalidAudio
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Set SIXTYDB_API_KEY when launching FluidVoice to use the 60db cloud engine."
        case .invalidAudio:
            return "60db requires nonempty, finite audio encoded as a WAV of at most 10 MB. Use a shorter recording."
        case .invalidResponse:
            return "60db returned an invalid transcription response."
        case .http(401), .http(403):
            return "60db rejected the API key. Check SIXTYDB_API_KEY."
        case .http(402):
            return "Your 60db account has insufficient credits."
        case .http(429):
            return "60db is rate limited. Try again later."
        case let .http(status):
            return "60db transcription failed (HTTP \(status))."
        }
    }
}
