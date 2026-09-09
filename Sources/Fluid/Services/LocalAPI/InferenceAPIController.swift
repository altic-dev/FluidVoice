import Foundation

@MainActor
final class InferenceAPIController: LocalAPIRouteHandler {
    struct TranscribeJSONRequest: Decodable {
        let path: String?
        let audioBase64: String?
        let filename: String?
    }

    struct TextRequest: Decodable {
        let text: String
    }

    struct TranscribeResponse: Encodable {
        let text: String
        let confidence: Float
        let sampleCount: Int
        let provider: String
    }

    struct PostprocessResponse: Encodable {
        let text: String
        let provider: String
        let model: String
    }

    private struct AudioUpload {
        let data: Data
        let suggestedExtension: String
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        switch (request.method, request.path) {
        case ("POST", "/v1/transcribe"):
            return await self.transcribe(request)
        case ("POST", "/v1/postprocess"):
            return await self.postprocess(request)
        default:
            return LocalAPI.error("Route not found.", status: 404)
        }
    }

    private func transcribe(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            if let fileURL = try self.decodeFilePath(from: request) {
                return try await self.transcribeFile(fileURL)
            }

            let upload = try self.decodeUploadedAudio(from: request)
            return try await LocalAPIAudioDecoder.withTemporaryAudioFile(
                fromAudioData: upload.data,
                suggestedExtension: upload.suggestedExtension
            ) { fileURL in
                try await self.transcribeFile(fileURL)
            }
        } catch {
            return LocalAPI.error(error.localizedDescription, status: 400)
        }
    }

    private func transcribeFile(_ fileURL: URL) async throws -> LocalAPI.Response {
        let payload = try await LocalAPITranscriptionService.transcribe(fileURL)
        return LocalAPI.json(
            TranscribeResponse(
                text: payload.text,
                confidence: payload.confidence,
                sampleCount: payload.sampleCount,
                provider: SettingsStore.shared.selectedSpeechModel.displayName
            )
        )
    }

    private func decodeFilePath(from request: LocalAPI.Request) throws -> URL? {
        guard self.isJSON(request) else { return nil }
        let payload: TranscribeJSONRequest
        do {
            payload = try LocalAPI.decoder.decode(TranscribeJSONRequest.self, from: request.body)
        } catch {
            throw self.makeError("Invalid JSON audio payload.", code: -3)
        }

        guard let path = payload.path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func postprocess(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            let text = try self.decodeText(from: request)
            let result = try await DictationPostProcessingService.shared.process(text)
            return LocalAPI.json(
                PostprocessResponse(
                    text: result.text,
                    provider: result.providerID,
                    model: result.model
                )
            )
        } catch {
            return LocalAPI.error(error.localizedDescription, status: 400)
        }
    }

    private func decodeUploadedAudio(from request: LocalAPI.Request) throws -> AudioUpload {
        let data: Data
        let suggestedExtension: String

        if self.isJSON(request) {
            let payload: TranscribeJSONRequest
            do {
                payload = try LocalAPI.decoder.decode(TranscribeJSONRequest.self, from: request.body)
            } catch {
                throw self.makeError("Invalid JSON audio payload.", code: -3)
            }

            if let audioBase64 = payload.audioBase64,
               let decodedData = Data(base64Encoded: audioBase64)
            {
                data = decodedData
                suggestedExtension = payload.filename.flatMap { URL(fileURLWithPath: $0).pathExtension } ?? "wav"
            } else {
                throw self.makeError("Missing audio path or audioBase64.", code: -1)
            }
        } else {
            guard !request.body.isEmpty else {
                throw self.makeError("Missing audio body.", code: -1)
            }

            data = request.body
            let filename = request.headers["x-filename"] ?? "audio.wav"
            suggestedExtension = URL(fileURLWithPath: filename).pathExtension
        }

        return AudioUpload(data: data, suggestedExtension: suggestedExtension)
    }

    private func decodeText(from request: LocalAPI.Request) throws -> String {
        if self.isJSON(request) {
            let payload: TextRequest
            do {
                payload = try LocalAPI.decoder.decode(TextRequest.self, from: request.body)
            } catch {
                throw self.makeError("Invalid JSON text payload.", code: -4)
            }
            return payload.text
        }

        guard let text = String(data: request.body, encoding: .utf8) else {
            throw self.makeError("Text body must be UTF-8.", code: -2)
        }
        return text
    }

    private func isJSON(_ request: LocalAPI.Request) -> Bool {
        request.headers["content-type"]?.lowercased().contains("application/json") == true
    }

    private func makeError(_ message: String, code: Int) -> NSError {
        NSError(
            domain: "InferenceAPIController",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
