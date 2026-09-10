import AVFoundation
@testable import FluidVoice_Debug
import XCTest

final class AudioBufferConverterTests: XCTestCase {
    func testStereoDownmixIncludesRightChannel() throws {
        let buffer = try self.makeFloatBuffer(sampleRate: 16_000, channels: 2, frameCount: 16)
        self.fill(buffer, channel: 1, with: 1)

        let samples = try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)

        XCTAssertEqual(samples.count, 16)
        self.assertAllSamples(samples, equalTo: 0.5)
    }

    func testStereoDownmixIncludesLeftChannel() throws {
        let buffer = try self.makeFloatBuffer(sampleRate: 16_000, channels: 2, frameCount: 16)
        self.fill(buffer, channel: 0, with: 1)

        let samples = try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)

        XCTAssertEqual(samples.count, 16)
        self.assertAllSamples(samples, equalTo: 0.5)
    }

    func testStereoDownmixPreservesMatchingChannels() throws {
        let buffer = try self.makeFloatBuffer(sampleRate: 16_000, channels: 2, frameCount: 16)
        self.fill(buffer, channel: 0, with: 1)
        self.fill(buffer, channel: 1, with: 1)

        let samples = try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)

        XCTAssertEqual(samples.count, 16)
        self.assertAllSamples(samples, equalTo: 1)
    }

    func testMonoFloatFastPathPreservesSamples() throws {
        let expected: [Float] = [0.25, -0.5, 0.75, -1]
        let buffer = try self.makeFloatBuffer(
            sampleRate: 16_000,
            channels: 1,
            frameCount: expected.count
        )
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for (index, sample) in expected.enumerated() {
            channelData[0][index] = sample
        }

        let samples = try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)

        XCTAssertEqual(samples, expected)
    }

    func testStereoDownmixAndResampleIncludesRightChannel() throws {
        let buffer = try self.makeFloatBuffer(sampleRate: 48_000, channels: 2, frameCount: 480)
        self.fill(buffer, channel: 1, with: 1)

        let samples = try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: 16_000)

        XCTAssertEqual(samples.count, 160)
        let average = samples.reduce(0, +) / Float(samples.count)
        XCTAssertEqual(average, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.4)
    }

    func testLocalAPIAudioChunkReaderBoundsMemoryAndPreservesFinalChunk() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-api-chunks-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let buffer = try self.makeFloatBuffer(sampleRate: 16_000, channels: 1, frameCount: 4000)
        do {
            let outputFile = try AVAudioFile(forWriting: fileURL, settings: buffer.format.settings)
            try outputFile.write(from: buffer)
        }

        let reader = try LocalAPIAudioDecoder.ChunkReader(
            fileURL: fileURL,
            chunkDurationSeconds: 0.1
        )

        let firstChunk = try await reader.nextSamples()
        let secondChunk = try await reader.nextSamples()
        let finalChunk = try await reader.nextSamples()

        XCTAssertEqual(firstChunk.count, 1600)
        XCTAssertEqual(secondChunk.count, 1600)
        XCTAssertEqual(finalChunk.count, 800)
        let exhaustedChunk = try await reader.nextSamples()
        XCTAssertTrue(exhaustedChunk.isEmpty)
        XCTAssertEqual(LocalAPIAudioDecoder.maxChunkDurationSeconds, 20 * 60)
    }

    func testLocalAPIExtensionlessUploadUsesTemporaryWAVAndCleansUp() async throws {
        let expectedData = Data([0, 1, 2, 3])
        let fileURL = try await LocalAPIAudioDecoder.temporaryFile(
            fromAudioData: expectedData,
            suggestedExtension: ""
        )

        XCTAssertEqual(fileURL.pathExtension, "wav")
        XCTAssertEqual(try Data(contentsOf: fileURL), expectedData)

        await LocalAPIAudioDecoder.removeTemporaryFile(at: fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testLocalAPIAudioDecoderNormalizesUnsupportedFileOpenError() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-api-invalid-audio-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("not audio".utf8).write(to: fileURL)

        XCTAssertThrowsError(try LocalAPIAudioDecoder.estimatedSampleCount(for: fileURL)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "LocalAPIAudioDecoder")
            XCTAssertEqual(nsError.code, -7)
            XCTAssertNotNil(nsError.userInfo[NSUnderlyingErrorKey])
        }
    }

    private func makeFloatBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frameCount: Int
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }

    private func fill(_ buffer: AVAudioPCMBuffer, channel: Int, with value: Float) {
        guard let channelData = buffer.floatChannelData else {
            XCTFail("Expected Float32 channel data")
            return
        }
        for frame in 0..<Int(buffer.frameLength) {
            channelData[channel][frame] = value
        }
    }

    private func assertAllSamples(
        _ samples: [Float],
        equalTo expected: Float,
        accuracy: Float = 0.00_001
    ) {
        for sample in samples {
            XCTAssertEqual(sample, expected, accuracy: accuracy)
        }
    }
}

final class LocalAPIMultipartFormDataTests: XCTestCase {
    private struct TranscriptionEnvelope: Decodable {
        let text: String
    }

    private struct ErrorEnvelope: Decodable {
        struct ErrorBody: Decodable {
            let message: String
            let type: String
            let param: String?
            let code: String?
        }

        let error: ErrorBody
    }

    func testParserIgnoresBoundaryBytesInsideFilePayload() throws {
        let boundary = "fluidvoice-test-boundary"
        var fileBody = Data([0, 1, 2])
        fileBody.append(contentsOf: Data("--\(boundary)".utf8))
        fileBody.append(contentsOf: Data("\r\n--\(boundary)X".utf8))
        fileBody.append(255)

        let body = self.multipartBody(
            boundary: boundary,
            fileBody: fileBody,
            responseFormat: "json"
        )
        let parts = try LocalAPIMultipartFormData.parse(
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].name, "file")
        XCTAssertEqual(parts[0].filename, "audio.wav")
        XCTAssertEqual(parts[0].body, fileBody)
        XCTAssertEqual(parts[1].name, "response_format")
        XCTAssertEqual(parts[1].stringValue, "json")
    }

    func testParserPreservesSemicolonsInsideQuotedParameters() throws {
        let boundary = "fluidvoice;test-boundary"
        let fileBody = Data([0, 1, 2, 3])
        let body = self.multipartBody(
            boundary: boundary,
            fileBody: fileBody,
            responseFormat: "json",
            filename: "sample;one.wav"
        )

        let parts = try LocalAPIMultipartFormData.parse(
            body: body,
            contentType: "multipart/form-data; boundary=\"\(boundary)\""
        )

        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].filename, "sample;one.wav")
        XCTAssertEqual(parts[0].body, fileBody)
    }

    func testParserRejectsBodyWithoutClosingBoundary() {
        let boundary = "fluidvoice-test-boundary"
        let body = Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n\r\naudio"
                .utf8
        )

        XCTAssertThrowsError(
            try LocalAPIMultipartFormData.parse(
                body: body,
                contentType: "multipart/form-data; boundary=\(boundary)"
            )
        )
    }

    @MainActor
    func testUnsupportedResponseFormatReturnsOpenAIErrorBeforeAudioDecode() async throws {
        let boundary = "fluidvoice-test-boundary"
        let request = LocalAPI.Request(
            method: "POST",
            path: "/v1/audio/transcriptions",
            query: [:],
            headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
            body: self.multipartBody(
                boundary: boundary,
                fileBody: Data([0, 1, 2]),
                responseFormat: "verbose_json"
            )
        )

        let response = await OpenAITranscriptionAPIController().handle(request)
        let error = try LocalAPI.decoder.decode(ErrorEnvelope.self, from: response.body)

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(error.error.type, "invalid_request_error")
        XCTAssertEqual(error.error.param, "response_format")
        XCTAssertEqual(error.error.code, "invalid_value")
        XCTAssertTrue(error.error.message.contains("verbose_json"))
    }

    @MainActor
    func testJSONResponseUsesOpenAIShape() async throws {
        let controller = OpenAITranscriptionAPIController { _ in
            LocalAPITranscriptionPayload(text: "Hello from FluidVoice", confidence: 0.9, sampleCount: 42)
        }

        let response = await controller.handle(self.transcriptionRequest(responseFormat: "json"))
        let payload = try LocalAPI.decoder.decode(TranscriptionEnvelope.self, from: response.body)

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "application/json; charset=utf-8")
        XCTAssertEqual(payload.text, "Hello from FluidVoice")
    }

    @MainActor
    func testTextResponseUsesPlainTextContentType() async {
        let controller = OpenAITranscriptionAPIController { _ in
            LocalAPITranscriptionPayload(text: "Plain transcript", confidence: 0.9, sampleCount: 42)
        }

        let response = await controller.handle(self.transcriptionRequest(responseFormat: "text"))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/plain; charset=utf-8")
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "Plain transcript")
    }

    @MainActor
    func testUnavailableASRReturnsOpenAI503AndRemovesTemporaryFile() async throws {
        var temporaryFileURL: URL?
        let controller = OpenAITranscriptionAPIController { fileURL in
            temporaryFileURL = fileURL
            throw NSError(
                domain: "ASRService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Transcription provider is not ready."]
            )
        }

        let response = await controller.handle(self.transcriptionRequest(responseFormat: "json"))
        let error = try LocalAPI.decoder.decode(ErrorEnvelope.self, from: response.body)
        let fileURL = try XCTUnwrap(temporaryFileURL)

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(error.error.type, "server_error")
        XCTAssertEqual(error.error.code, "service_unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testAVFoundationDecodeFailureReturnsOpenAI400() async throws {
        let controller = OpenAITranscriptionAPIController { _ in
            throw NSError(
                domain: AVFoundationErrorDomain,
                code: -11_800,
                userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed."]
            )
        }

        let response = await controller.handle(self.transcriptionRequest(responseFormat: "json"))
        let error = try LocalAPI.decoder.decode(ErrorEnvelope.self, from: response.body)

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(error.error.type, "invalid_request_error")
        XCTAssertEqual(error.error.param, "file")
        XCTAssertEqual(error.error.code, "invalid_audio")
    }

    @MainActor
    func testUnexpectedASRFailureReturnsOpenAI500() async throws {
        let controller = OpenAITranscriptionAPIController { _ in
            throw NSError(
                domain: "ASRService",
                code: -99,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected transcription failure."]
            )
        }

        let response = await controller.handle(self.transcriptionRequest(responseFormat: "json"))
        let error = try LocalAPI.decoder.decode(ErrorEnvelope.self, from: response.body)

        XCTAssertEqual(response.status, 500)
        XCTAssertEqual(error.error.type, "server_error")
        XCTAssertEqual(error.error.code, "internal_error")
    }

    private func transcriptionRequest(responseFormat: String) -> LocalAPI.Request {
        let boundary = "fluidvoice-test-boundary"
        return LocalAPI.Request(
            method: "POST",
            path: "/v1/audio/transcriptions",
            query: [:],
            headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
            body: self.multipartBody(
                boundary: boundary,
                fileBody: Data([0, 1, 2]),
                responseFormat: responseFormat
            )
        )
    }

    private func multipartBody(
        boundary: String,
        fileBody: Data,
        responseFormat: String,
        filename: String = "audio.wav"
    ) -> Data {
        var body = Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n"
                .utf8
        )
        body.append(fileBody)
        body.append(contentsOf: Data("\r\n--\(boundary)\r\n".utf8))
        body.append(
            contentsOf: Data(
                "Content-Disposition: form-data; name=\"response_format\"\r\n\r\n\(responseFormat)\r\n"
                    .utf8
            )
        )
        body.append(contentsOf: Data("--\(boundary)--\r\n".utf8))
        return body
    }
}
