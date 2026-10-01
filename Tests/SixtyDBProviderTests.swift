import Foundation

// Unrelated local-engine metadata types keep the real provider protocol runnable in isolation.
struct PronunciationEnrollmentCapture {}
struct DictionaryLearningAlignment {}

final class SixtyDBURLProtocol: URLProtocol {
    static var status = 200
    static var responseBody = Data(#"{"text":"Hello from 60db"}"#.utf8)
    static var requests: [URLRequest] = []

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(self.request)
        guard let url = self.request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: nil)
        else { preconditionFailure("Fixture requires an HTTP request") }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Self.responseBody)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
enum SixtyDBProviderTests {
    static func main() async throws {
        let request = try SixtyDBProvider.request(samples: [-2, 0, 2], apiKey: " fixture-key ")
        precondition(request.url?.absoluteString == "https://api.60db.ai/stt")
        precondition(request.httpMethod == "POST" && request.timeoutInterval == 60)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        guard let body = request.httpBody,
              let riff = body.range(of: Data("RIFF".utf8)),
              let contentType = request.value(forHTTPHeaderField: "Content-Type")
        else { preconditionFailure("Multipart request has no WAV") }
        let start = riff.lowerBound
        let wav = body.subdata(in: start..<(start + 50))
        precondition(String(data: wav[8..<16], encoding: .utf8) == "WAVEfmt ")
        precondition(Array(wav[24..<28]) == [0x80, 0x3e, 0, 0]) // 16 kHz
        precondition(Array(wav[44..<50]) == [1, 0x80, 0, 0, 0xff, 0x7f]) // clipped PCM16
        let boundary = contentType.components(separatedBy: "boundary=")[1]
        precondition(body.starts(with: Data("--\(boundary)\r\n".utf8)))
        precondition(body.suffix(Data("\r\n--\(boundary)--\r\n".utf8).count) == Data("\r\n--\(boundary)--\r\n".utf8))
        precondition(body.range(of: Data("name=\"model\"".utf8)) == nil)
        precondition(body.range(of: Data("name=\"language\"".utf8)) == nil)

        for samples: [Float] in [[], [.nan], [.infinity], Array(repeating: 0, count: (10_000_000 - 44) / 2 + 1)] {
            do {
                _ = try SixtyDBProvider.request(samples: samples, apiKey: "fixture")
                preconditionFailure("Invalid audio was accepted")
            } catch SixtyDBError.invalidAudio {}
        }
        for key in ["", "  ", "fixture\r\nInjected: header"] {
            do {
                _ = try SixtyDBProvider.request(samples: [0], apiKey: key)
                preconditionFailure("Invalid key was accepted")
            } catch SixtyDBError.missingKey {}
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SixtyDBURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = SixtyDBProvider(session: session, apiKey: { "fixture-key" })
        try await provider.prepare(progressHandler: nil)
        precondition(provider.isReady && provider.modelsExistOnDisk())
        let preview = try await provider.transcribeStreaming([0])
        precondition(preview.text.isEmpty && SixtyDBURLProtocol.requests.isEmpty)
        let result = try await provider.transcribeFinal([0, 0.5])
        precondition(result.text == "Hello from 60db" && SixtyDBURLProtocol.requests.count == 1)
        precondition(SixtyDBURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")

        SixtyDBURLProtocol.responseBody = Data(#"{"text":""}"#.utf8)
        let silence = try await provider.transcribe([0])
        precondition(silence.text.isEmpty && silence.confidence == 0)
        for payload in [#"{"text":123}"#, #"{}"#, #"{"text":"bad","success":false}"#, "invalid"] {
            SixtyDBURLProtocol.responseBody = Data(payload.utf8)
            do {
                _ = try await provider.transcribe([0])
                preconditionFailure("Invalid response was accepted")
            } catch SixtyDBError.invalidResponse {}
        }
        for status in [302, 401, 402, 429, 503] {
            SixtyDBURLProtocol.status = status
            SixtyDBURLProtocol.responseBody = Data("secret server body".utf8)
            let before = SixtyDBURLProtocol.requests.count
            do {
                _ = try await provider.transcribe([0])
                preconditionFailure("HTTP error was accepted")
            } catch let SixtyDBError.http(code) {
                precondition(code == status)
                precondition(!SixtyDBError.http(code).localizedDescription.contains("secret"))
            }
            precondition(SixtyDBURLProtocol.requests.count == before + 1, "Billable request must not auto-retry")
        }
        let missingKey = SixtyDBProvider(session: session, apiKey: { "" })
        do {
            try await missingKey.prepare(progressHandler: nil)
            preconditionFailure("Missing key was accepted")
        } catch SixtyDBError.missingKey {}
        print("PASS: native multipart/WAV, validation, final transcription, no-upload preview, silence, malformed responses and HTTP errors")
    }
}
