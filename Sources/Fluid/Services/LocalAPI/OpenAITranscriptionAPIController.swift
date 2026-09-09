import Foundation

@MainActor
final class OpenAITranscriptionAPIController: LocalAPIRouteHandler {
    private struct TranscriptionResponse: Encodable {
        let text: String
    }

    private struct ErrorResponse: Encodable {
        struct ErrorBody: Encodable {
            let message: String
            let type: String
            let param: String?
            let code: String?
        }

        let error: ErrorBody
    }

    private struct RequestError: Error {
        let message: String
        let param: String?
        let code: String
    }

    private enum ResponseFormat: String {
        case json
        case text
    }

    private struct Model: Encodable {
        let id: String
        let object = "model"
        let created = 0
        let ownedBy = "fluidvoice"

        enum CodingKeys: String, CodingKey {
            case id, object, created
            case ownedBy = "owned_by"
        }
    }

    private struct ModelListResponse: Encodable {
        let object = "list"
        let data: [Model]
    }

    private struct TranscriptionUpload {
        let data: Data
        let filename: String
        let responseFormat: ResponseFormat
    }

    private let transcribe: @MainActor (URL) async throws -> LocalAPITranscriptionPayload

    init(
        transcribe: @escaping @MainActor (URL) async throws -> LocalAPITranscriptionPayload = {
            try await LocalAPITranscriptionService.transcribe($0)
        }
    ) {
        self.transcribe = transcribe
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            return self.models()
        case ("POST", "/v1/audio/transcriptions"):
            return await self.createTranscription(request)
        default:
            return LocalAPI.error("Route not found.", status: 404)
        }
    }

    private func models() -> LocalAPI.Response {
        LocalAPI.json(ModelListResponse(data: [Model(id: "fluidvoice")]))
    }

    private func createTranscription(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            let upload = try self.decodeUpload(from: request)
            return try await LocalAPIAudioDecoder.withTemporaryAudioFile(
                fromAudioData: upload.data,
                suggestedExtension: URL(fileURLWithPath: upload.filename).pathExtension
            ) { fileURL in
                let payload = try await self.transcribe(fileURL)
                return self.response(text: payload.text, format: upload.responseFormat)
            }
        } catch {
            return self.errorResponse(for: error)
        }
    }

    private func response(text: String, format: ResponseFormat) -> LocalAPI.Response {
        switch format {
        case .json:
            return LocalAPI.json(TranscriptionResponse(text: text))
        case .text:
            return LocalAPI.Response(
                status: 200,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data(text.utf8)
            )
        }
    }

    private func decodeUpload(from request: LocalAPI.Request) throws -> TranscriptionUpload {
        guard let contentType = request.headers["content-type"],
              contentType.lowercased().contains("multipart/form-data")
        else {
            throw RequestError(
                message: "OpenAI transcription requests must use multipart/form-data.",
                param: nil,
                code: "invalid_content_type"
            )
        }

        let parts: [LocalAPIMultipartFormData.Part]
        do {
            parts = try LocalAPIMultipartFormData.parse(body: request.body, contentType: contentType)
        } catch {
            throw RequestError(
                message: error.localizedDescription,
                param: nil,
                code: "invalid_multipart_body"
            )
        }

        guard let filePart = parts.first(where: { $0.name == "file" }), !filePart.body.isEmpty else {
            throw RequestError(
                message: "Missing multipart 'file' field.",
                param: "file",
                code: "missing_required_parameter"
            )
        }

        let filename = filePart.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeFilename = (filename?.isEmpty == false ? filename : nil) ?? "audio.wav"
        let rawResponseFormat = parts.first(where: { $0.name == "response_format" })?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "json"

        let responseFormat: ResponseFormat
        if rawResponseFormat.isEmpty {
            responseFormat = .json
        } else if let parsedFormat = ResponseFormat(rawValue: rawResponseFormat) {
            responseFormat = parsedFormat
        } else {
            throw RequestError(
                message: "Unsupported response_format '\(rawResponseFormat)'. FluidVoice currently supports 'json' and 'text'.",
                param: "response_format",
                code: "invalid_value"
            )
        }

        // OpenAI clients send a `model` field. FluidVoice accepts it without routing
        // because the active Voice Engine remains the source of truth.
        return TranscriptionUpload(
            data: filePart.body,
            filename: safeFilename,
            responseFormat: responseFormat
        )
    }

    private func errorResponse(for error: Error) -> LocalAPI.Response {
        if let requestError = error as? RequestError {
            return self.error(
                requestError.message,
                status: 400,
                type: "invalid_request_error",
                param: requestError.param,
                code: requestError.code
            )
        }

        let nsError = error as NSError
        if nsError.domain == "ASRService", nsError.code == -2 {
            return self.error(
                nsError.localizedDescription,
                status: 503,
                type: "server_error",
                code: "service_unavailable"
            )
        }
        if nsError.domain == "LocalAPIAudioDecoder" || nsError.domain == NSOSStatusErrorDomain {
            return self.error(
                "The uploaded file could not be decoded as audio.",
                status: 400,
                type: "invalid_request_error",
                param: "file",
                code: "invalid_audio"
            )
        }

        return self.error(
            nsError.localizedDescription,
            status: 500,
            type: "server_error",
            code: "internal_error"
        )
    }

    private func error(
        _ message: String,
        status: Int,
        type: String,
        param: String? = nil,
        code: String? = nil
    ) -> LocalAPI.Response {
        LocalAPI.json(
            ErrorResponse(
                error: .init(message: message, type: type, param: param, code: code)
            ),
            status: status
        )
    }
}
