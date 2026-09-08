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

    private struct TranscriptionPayload {
        let text: String
        let confidence: Float
        let sampleCount: Int
    }

    private struct OpenAITranscriptionResponse: Encodable {
        let text: String
    }

    private struct OpenAIModel: Encodable {
        let id: String
        let object = "model"
        let created = 0
        let ownedBy = "fluidvoice"

        enum CodingKeys: String, CodingKey {
            case id, object, created
            case ownedBy = "owned_by"
        }
    }

    private struct OpenAIModelListResponse: Encodable {
        let object = "list"
        let data: [OpenAIModel]
    }

    private struct OpenAITranscriptionUpload {
        let data: Data
        let filename: String
        let responseFormat: String
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            return self.openAIModels()
        case ("POST", "/v1/audio/transcriptions"):
            return await self.openAITranscription(request)
        case ("POST", "/v1/transcribe"):
            return await self.transcribe(request)
        case ("POST", "/v1/postprocess"):
            return await self.postprocess(request)
        default:
            return LocalAPI.error("Route not found.", status: 404)
        }
    }

    private func openAIModels() -> LocalAPI.Response {
        LocalAPI.json(OpenAIModelListResponse(data: [OpenAIModel(id: "fluidvoice")]))
    }

    private func openAITranscription(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            let upload = try self.decodeOpenAITranscriptionUpload(from: request)
            let fileURL = try await LocalAPIAudioDecoder.temporaryFile(
                fromAudioData: upload.data,
                suggestedExtension: URL(fileURLWithPath: upload.filename).pathExtension
            )

            do {
                let payload = try await self.transcriptionPayload(for: fileURL)
                await LocalAPIAudioDecoder.removeTemporaryFile(at: fileURL)
                return try self.openAIResponse(text: payload.text, responseFormat: upload.responseFormat)
            } catch {
                await LocalAPIAudioDecoder.removeTemporaryFile(at: fileURL)
                throw error
            }
        } catch {
            return LocalAPI.error(error.localizedDescription, status: 400)
        }
    }

    private func openAIResponse(text: String, responseFormat: String) throws -> LocalAPI.Response {
        switch responseFormat.lowercased() {
        case "", "json":
            return LocalAPI.json(OpenAITranscriptionResponse(text: text))
        case "text":
            return LocalAPI.Response(
                status: 200,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data(text.utf8)
            )
        default:
            throw self.makeError(
                "Unsupported response_format '\(responseFormat)'. FluidVoice currently supports 'json' and 'text'.",
                code: -7
            )
        }
    }

    private func decodeOpenAITranscriptionUpload(from request: LocalAPI.Request) throws -> OpenAITranscriptionUpload {
        guard let contentType = request.headers["content-type"],
              contentType.lowercased().contains("multipart/form-data")
        else {
            throw self.makeError("OpenAI transcription requests must use multipart/form-data.", code: -5)
        }

        let parts = try LocalAPIMultipartFormData.parse(body: request.body, contentType: contentType)
        guard let filePart = parts.first(where: { $0.name == "file" }), !filePart.body.isEmpty else {
            throw self.makeError("Missing multipart 'file' field.", code: -6)
        }

        let filename = filePart.filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeFilename = (filename?.isEmpty == false ? filename : nil) ?? "audio.wav"
        let responseFormat = parts.first(where: { $0.name == "response_format" })?
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "json"

        // OpenAI clients also send a `model` field. FluidVoice intentionally accepts
        // it without routing on it: the active Voice Engine remains the source of truth.
        return OpenAITranscriptionUpload(
            data: filePart.body,
            filename: safeFilename,
            responseFormat: responseFormat
        )
    }

    private func transcribe(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            if let fileURL = try self.decodeFilePath(from: request) {
                return try await self.transcribeFile(fileURL)
            }

            let temporaryFileURL = try await self.decodeUploadedAudioFile(from: request)
            do {
                let response = try await self.transcribeFile(temporaryFileURL)
                await LocalAPIAudioDecoder.removeTemporaryFile(at: temporaryFileURL)
                return response
            } catch {
                await LocalAPIAudioDecoder.removeTemporaryFile(at: temporaryFileURL)
                throw error
            }
        } catch {
            return LocalAPI.error(error.localizedDescription, status: 400)
        }
    }

    private func transcribeFile(_ fileURL: URL) async throws -> LocalAPI.Response {
        let payload = try await self.transcriptionPayload(for: fileURL)
        return LocalAPI.json(
            TranscribeResponse(
                text: payload.text,
                confidence: payload.confidence,
                sampleCount: payload.sampleCount,
                provider: SettingsStore.shared.selectedSpeechModel.displayName
            )
        )
    }

    private func transcriptionPayload(for fileURL: URL) async throws -> TranscriptionPayload {
        let apiResult = try await AppServices.shared.asr.transcribeFileForAPI(fileURL)
        return TranscriptionPayload(
            text: apiResult.result.text,
            confidence: apiResult.result.confidence,
            sampleCount: apiResult.sampleCount
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

    private func decodeUploadedAudioFile(from request: LocalAPI.Request) async throws -> URL {
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

        return try await LocalAPIAudioDecoder.temporaryFile(
            fromAudioData: data,
            suggestedExtension: suggestedExtension
        )
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

enum LocalAPIMultipartFormData {
    struct Part {
        let name: String
        let filename: String?
        let headers: [String: String]
        let body: Data

        var stringValue: String? {
            String(data: self.body, encoding: .utf8)
        }
    }

    static func parse(body: Data, contentType: String) throws -> [Part] {
        let boundary = try self.boundary(from: contentType)
        let delimiter = Data("--\(boundary)".utf8)
        let headerSeparator = Data("\r\n\r\n".utf8)

        var parts: [Part] = []
        var searchStart = body.startIndex

        while let boundaryRange = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            var partStart = boundaryRange.upperBound

            if self.hasBytes([45, 45], at: partStart, in: body) {
                break
            }
            if self.hasBytes([13, 10], at: partStart, in: body) {
                partStart += 2
            }

            guard let nextBoundary = body.range(of: delimiter, in: partStart..<body.endIndex) else {
                throw self.error("Malformed multipart body: missing closing boundary.")
            }

            var partEnd = nextBoundary.lowerBound
            if partEnd >= 2, self.hasBytes([13, 10], at: partEnd - 2, in: body) {
                partEnd -= 2
            }

            guard let headerRange = body.range(of: headerSeparator, in: partStart..<partEnd) else {
                throw self.error("Malformed multipart body: missing part headers.")
            }

            let headers = try self.headers(from: Data(body[partStart..<headerRange.lowerBound]))
            guard let disposition = headers["content-disposition"] else {
                throw self.error("Malformed multipart body: missing Content-Disposition.")
            }

            let parameters = self.dispositionParameters(from: disposition)
            guard let name = parameters["name"], !name.isEmpty else {
                throw self.error("Malformed multipart body: missing part name.")
            }

            let payloadStart = headerRange.upperBound
            parts.append(
                Part(
                    name: name,
                    filename: parameters["filename"],
                    headers: headers,
                    body: Data(body[payloadStart..<partEnd])
                )
            )
            searchStart = nextBoundary.lowerBound
        }

        guard !parts.isEmpty else {
            throw self.error("Malformed multipart body: no parts found.")
        }
        return parts
    }

    private static func boundary(from contentType: String) throws -> String {
        for component in contentType.split(separator: ";", omittingEmptySubsequences: true) {
            let parameter = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = parameter.firstIndex(of: "=") else { continue }

            let key = parameter[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.caseInsensitiveCompare("boundary") == .orderedSame else { continue }

            var value = parameter[parameter.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            guard !value.isEmpty else { break }
            return value
        }
        throw self.error("Missing multipart boundary.")
    }

    private static func headers(from data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw self.error("Multipart headers must be UTF-8.")
        }

        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw self.error("Malformed multipart header.")
            }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private static func dispositionParameters(from disposition: String) -> [String: String] {
        var parameters: [String: String] = [:]
        for component in disposition.split(separator: ";").dropFirst() {
            let parameter = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = parameter.firstIndex(of: "=") else { continue }
            let key = parameter[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            var value = parameter[parameter.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            parameters[key] = value
        }
        return parameters
    }

    private static func hasBytes(_ bytes: [UInt8], at index: Data.Index, in data: Data) -> Bool {
        guard index >= data.startIndex, index + bytes.count <= data.endIndex else { return false }
        return zip(bytes, data[index..<(index + bytes.count)]).allSatisfy(==)
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "LocalAPIMultipartFormData",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
